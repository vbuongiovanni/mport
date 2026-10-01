//
//  ProgressBoard.swift
//  Created by Claude on 9/29/26, at Vince's request.
//

import Foundation
import Noora

/// What the terminal shows while `import` or `migrate` works on several collections at once: one live line per
/// collection in progress with its document count, a footer with how many are done, and a permanent line for each
/// one that finishes.
///
/// Noora's per-step spinners can't do this: each one redraws by moving the cursor up over its own last frame, so
/// two at once erase each other. This is an actor because its whole job is to be the one place that writes to the
/// terminal while several tasks report progress at the same time.
///
/// When output isn't a terminal (redirected to a file, say), nothing is redrawn: each finished collection prints
/// one plain line, with no cursor-movement codes.
actor ProgressBoard {
    private struct Line {
        let label: String
        let total: Int?
        var count = 0
    }

    private let total: Int
    private let pipeline: StandardPipelining
    private let isInteractive: Bool
    private let renderer: WrapAwareRenderer
    /// Keyed by plan position, so the frame lists collections in plan order.
    private var inFlight: [Int: Line] = [:]
    private var finished = 0

    /// - Parameters:
    ///   - total: How many items the run has, for the `Completed n of total` footer.
    ///   - pipeline, isInteractive, terminalWidth: Where output goes and how it's drawn. Tests pass their own.
    init(
        total: Int,
        pipeline: StandardPipelining = StandardOutputPipeline(),
        isInteractive: Bool = isatty(STDOUT_FILENO) != 0,
        terminalWidth: @escaping @Sendable () -> Int = WrapAwareRenderer.currentTerminalWidth
    ) {
        self.total = total
        self.pipeline = pipeline
        self.isInteractive = isInteractive
        self.renderer = WrapAwareRenderer(terminalWidth: terminalWidth)
    }

    /// Adds a live line, e.g. `Importing users.bson → users`. With a `total`, counts show as `count/total`.
    func start(index: Int, label: String, total: Int? = nil) {
        inFlight[index] = Line(label: label, total: total)
        redraw()
    }

    func update(index: Int, count: Int) {
        inFlight[index]?.count = count
        redraw()
    }

    /// Leaves `line` on screen, e.g. `✔︎ users.bson → users: 1200 inserted`, and drops the item from the live frame.
    func finish(index: Int, line: String) {
        inFlight[index] = nil
        finished += 1
        if isInteractive {
            renderer.commit(line, standardPipeline: pipeline)
            redraw()
        } else {
            pipeline.write(content: "\(line)\n")
        }
    }

    /// Erases the live frame, so whatever prints next (the summary) starts on a clean line.
    func close() {
        if isInteractive {
            renderer.render("", standardPipeline: pipeline)
        }
    }

    private func redraw() {
        guard isInteractive else {
            return
        }
        var lines = inFlight.keys.sorted().compactMap { inFlight[$0] }.map { line in
            let progress = line.total.map { "\(line.count)/\($0)" } ?? "\(line.count)"
            return "◌ \(line.label) (\(progress) documents)"
        }
        lines.append("Completed \(finished) of \(total)")
        renderer.render(lines.joined(separator: "\n"), standardPipeline: pipeline)
    }
}

/// A single line that redraws in place, for a step that reports running counts (backing up collections, say),
/// instead of printing a line per item. The final text stays on screen.
///
/// When output isn't a terminal, the updates are skipped and only the final text is printed, so a log gets one
/// line rather than one per update.
final class StatusLine {
    private let pipeline: StandardPipelining
    private let isInteractive: Bool
    private let renderer: WrapAwareRenderer

    /// The defaults write to stdout. Tests pass their own pipeline, interactivity, and width.
    init(
        pipeline: StandardPipelining = StandardOutputPipeline(),
        isInteractive: Bool = isatty(STDOUT_FILENO) != 0,
        terminalWidth: @escaping () -> Int = WrapAwareRenderer.currentTerminalWidth
    ) {
        self.pipeline = pipeline
        self.isInteractive = isInteractive
        self.renderer = WrapAwareRenderer(terminalWidth: terminalWidth)
    }

    func update(_ text: String) {
        if isInteractive {
            renderer.render(text, standardPipeline: pipeline)
        }
    }

    func finish(_ text: String) {
        if isInteractive {
            renderer.commit(text, standardPipeline: pipeline)
        } else {
            pipeline.write(content: text.hasSuffix("\n") ? text : "\(text)\n")
        }
    }
}
