//
//  WrapAwareRenderer.swift
//  Created by Claude on 9/18/26, at Vince's request.
//

import Foundation
import Noora

/// A drop-in replacement for Noora's `Renderer` that copes with lines wider than the terminal.
///
/// Noora animates a prompt (or spinner) by erasing what it printed last time and printing the new version.
/// Its built-in `Renderer` assumes every `\n`-separated line took exactly one row on screen, but the terminal
/// wraps a line that's wider than the window onto extra rows. Those extra rows never get erased, so every
/// redraw leaves a stale copy behind. This renderer counts the rows each line actually occupies instead.
///
/// Pass a fresh one to each Noora call, e.g. `Noora().textPrompt(..., renderer: WrapAwareRenderer())`.
final class WrapAwareRenderer: Rendering {
    /// How many terminal rows the previous frame took up, i.e. how far up to go to erase it.
    private var rowsOnScreen = 0
    private let terminalWidth: () -> Int

    /// - Parameter terminalWidth: Reports the width lines wrap at. Defaults to the real terminal;
    ///   tests pass a fixed width, since a test run has no terminal attached.
    init(terminalWidth: @escaping () -> Int = WrapAwareRenderer.currentTerminalWidth) {
        self.terminalWidth = terminalWidth
    }

    func render(_ input: String, standardPipeline: StandardPipelining) {
        if rowsOnScreen > 0 {
            // Move up to the first row of the previous frame, back to column 1, and clear everything below.
            standardPipeline.write(content: "\u{1B}[\(rowsOnScreen)A\u{1B}[1G\u{1B}[0J")
        }

        let lines = input.split(separator: "\n")
        for line in lines {
            standardPipeline.write(content: "\(line)\n")
        }

        let width = terminalWidth()
        rowsOnScreen = lines.reduce(0) { total, line in total + Self.rows(for: line, width: width) }
    }

    /// Rows a line fills once the terminal wraps it. Color codes take up no space, so they're stripped first.
    private static func rows(for line: Substring, width: Int) -> Int {
        let visibleCharacters = line.replacing(#/\e\[[0-9;?]*[ -/]*[@-~]/#, with: "").count
        guard visibleCharacters > width else {
            return 1
        }
        return (visibleCharacters + width - 1) / width
    }

    /// The terminal's width in columns, or `.max` (meaning "never wraps") when output isn't a terminal.
    static func currentTerminalWidth() -> Int {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else {
            return .max
        }
        return Int(size.ws_col)
    }
}
