//
//  ProgressBoardTests.swift
//  Created by Claude on 9/29/26, at Vince's request.
//

import Testing

@Suite("Progress board")
struct ProgressBoardTests {

    private let eraseSequence = #/\e\[\d+A\e\[1G\e\[0J/#

    /// What's on screen now: everything the board wrote, with each erased frame removed. Simulates the terminal.
    private func screen(_ output: String) -> String {
        var lines: [String] = []
        var remaining = Substring(output)
        while let match = remaining.firstMatch(of: eraseSequence) {
            lines.append(contentsOf: remaining[..<match.range.lowerBound].split(separator: "\n").map(String.init))
            let rows = Int(match.output.dropFirst(2).prefix { $0.isNumber }) ?? 0
            lines.removeLast(min(rows, lines.count))
            remaining = remaining[match.range.upperBound...]
        }
        lines.append(contentsOf: remaining.split(separator: "\n").map(String.init))
        return lines.joined(separator: "\n")
    }

    /// Catches: finished collections staying in the live frame, or in-flight ones missing from it.
    @Test("The live frame lists only in-flight items, in plan order, with a footer")
    func liveFrame() async {
        let pipeline = RecordingPipeline()
        let board = ProgressBoard(total: 3, pipeline: pipeline, isInteractive: true) { 200 }

        await board.start(index: 1, label: "Importing b.bson → b")
        await board.start(index: 0, label: "Importing a.bson → a")
        await board.update(index: 0, count: 1000)

        #expect(screen(pipeline.output) == """
        ◌ Importing a.bson → a (1000 documents)
        ◌ Importing b.bson → b (0 documents)
        Completed 0 of 3
        """)
    }

    /// Catches: a finished line being erased by the next redraw, or the item lingering in the frame.
    @Test("finish leaves a permanent line above the frame and drops the item from it")
    func finishCommitsLine() async {
        let pipeline = RecordingPipeline()
        let board = ProgressBoard(total: 2, pipeline: pipeline, isInteractive: true) { 200 }

        await board.start(index: 0, label: "Migrating a → a", total: 10)
        await board.start(index: 1, label: "Migrating b → b", total: 20)
        await board.update(index: 1, count: 5)
        await board.finish(index: 0, line: "✔︎ a → a: 10 inserted")
        await board.update(index: 1, count: 20)

        #expect(screen(pipeline.output) == """
        ✔︎ a → a: 10 inserted
        ◌ Migrating b → b (20/20 documents)
        Completed 1 of 2
        """)

        await board.finish(index: 1, line: "✔︎ b → b: 20 inserted")
        await board.close()

        #expect(screen(pipeline.output) == """
        ✔︎ a → a: 10 inserted
        ✔︎ b → b: 20 inserted
        """)
    }

    /// Catches: cursor-movement codes ending up in a log file when output is redirected.
    @Test("When output isn't a terminal, only one plain line per finished item is written")
    func nonInteractive() async {
        let pipeline = RecordingPipeline()
        let board = ProgressBoard(total: 2, pipeline: pipeline, isInteractive: false) { 80 }

        await board.start(index: 0, label: "Importing a.bson → a")
        await board.update(index: 0, count: 500)
        await board.start(index: 1, label: "Importing b.bson → b")
        await board.finish(index: 1, line: "✔︎ b.bson → b: 3 inserted")
        await board.finish(index: 0, line: "✖ a.bson → a: failed")
        await board.close()

        #expect(!pipeline.output.contains("\u{1B}"))
        #expect(pipeline.output == "✔︎ b.bson → b: 3 inserted\n✖ a.bson → a: failed\n")
    }
}

@Suite("Status line")
struct StatusLineTests {

    /// Catches: every update staying on screen, which is the wall of text the status line replaces.
    @Test("In a terminal, updates redraw one line and only the final text stays")
    func redrawsInPlace() {
        let pipeline = RecordingPipeline()
        let status = StatusLine(pipeline: pipeline, isInteractive: true) { 200 }

        status.update("◌ 1/3")
        status.update("◌ 2/3")
        status.finish("✔︎ 3/3\n  done")

        let erase = "\u{1B}[1A\u{1B}[1G\u{1B}[0J"
        #expect(pipeline.output == "◌ 1/3\n" + erase + "◌ 2/3\n" + erase + "✔︎ 3/3\n  done\n")
    }

    /// Catches: a log file getting one line per update, or cursor codes.
    @Test("When output isn't a terminal, only the final text is written")
    func finalOnlyWhenRedirected() {
        let pipeline = RecordingPipeline()
        let status = StatusLine(pipeline: pipeline, isInteractive: false) { 80 }

        status.update("◌ 1/3")
        status.update("◌ 2/3")
        status.finish("✔︎ 3/3")

        #expect(pipeline.output == "✔︎ 3/3\n")
    }
}
