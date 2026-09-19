//
//  WrapAwareRendererTests.swift
//  Created by Claude on 9/18/26, at Vince's request.
//

import Foundation
import Noora
import Testing

@Suite("WrapAwareRenderer")
struct WrapAwareRendererTests {

    /// The escape sequence that erases the previous frame: up `rows` rows, column 1, clear to end of screen.
    private func erase(rows: Int) -> String {
        "\u{1B}[\(rows)A\u{1B}[1G\u{1B}[0J"
    }

    /// Renders `firstFrame`, then a second frame, and returns what the second render wrote. Its erase
    /// sequence reveals how many rows the renderer believed the first frame took up.
    private func secondFrameOutput(after firstFrame: String, width: Int) -> String {
        let renderer = WrapAwareRenderer(terminalWidth: { width })
        let pipeline = RecordingPipeline()
        renderer.render(firstFrame, standardPipeline: pipeline)
        pipeline.reset()
        renderer.render("next", standardPipeline: pipeline)
        return pipeline.output
    }

    /// Catches: a first frame erasing lines above it that belong to earlier output.
    @Test("The first frame is printed without erasing anything")
    func firstFrameDoesNotErase() {
        let renderer = WrapAwareRenderer(terminalWidth: { 80 })
        let pipeline = RecordingPipeline()

        renderer.render("◉ Title\n  Question?", standardPipeline: pipeline)

        #expect(pipeline.output == "◉ Title\n  Question?\n")
    }

    struct RowCase: CustomTestStringConvertible, Sendable {
        let description: String
        let frame: String
        let width: Int
        let expectedRows: Int

        var testDescription: String { description }
    }

    static let rowCases: [RowCase] = [
        RowCase(description: "short lines take one row each", frame: "a\nb\nc", width: 80, expectedRows: 3),
        RowCase(description: "a line one character too wide wraps to two rows",
                frame: String(repeating: "x", count: 81), width: 80, expectedRows: 2),
        RowCase(description: "a line exactly as wide as the terminal stays on one row",
                frame: String(repeating: "x", count: 80), width: 80, expectedRows: 1),
        RowCase(description: "a very long line wraps onto several rows",
                frame: String(repeating: "x", count: 201), width: 50, expectedRows: 5),
        RowCase(description: "color codes take up no space",
                frame: "\u{1B}[38;2;255;0;0m" + String(repeating: "x", count: 80) + "\u{1B}[0m",
                width: 80, expectedRows: 1),
        RowCase(description: "the wrapping yes/no prompt from the original bug report",
                frame: "◉ Collection Names\n  Rename any of the target collections?  Yes (y)  /  No (n)\n"
                    + "  By default each file is imported into a collection with the same name, minus .bson\n"
                    + "  ←/→/h/l left/right • enter confirm",
                width: 80, expectedRows: 5),
        RowCase(description: "no terminal attached means nothing wraps",
                frame: String(repeating: "x", count: 10_000), width: .max, expectedRows: 1)
    ]

    /// Catches: the stale-line bug coming back, where wrapped rows were never erased on redraw.
    @Test("Erases exactly the rows the previous frame occupied", arguments: rowCases)
    func erasesWrappedRows(_ rowCase: RowCase) {
        let output = secondFrameOutput(after: rowCase.frame, width: rowCase.width)
        #expect(output.hasPrefix(erase(rows: rowCase.expectedRows)))
    }

    /// Catches: the terminal being resized mid-prompt leaving stale rows, since width is re-read every frame.
    @Test("Uses the terminal width at the time each frame is drawn")
    func rereadsWidthEachFrame() {
        final class Terminal {
            var width = 80
        }
        let terminal = Terminal()
        let renderer = WrapAwareRenderer(terminalWidth: { terminal.width })
        let pipeline = RecordingPipeline()

        renderer.render(String(repeating: "x", count: 100), standardPipeline: pipeline)
        terminal.width = 40
        renderer.render(String(repeating: "x", count: 100), standardPipeline: pipeline)
        pipeline.reset()
        renderer.render("done", standardPipeline: pipeline)

        #expect(pipeline.output.hasPrefix(erase(rows: 3)))
    }
}
