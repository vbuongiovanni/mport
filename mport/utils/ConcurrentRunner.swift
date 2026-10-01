//
//  ConcurrentRunner.swift
//  Created by Claude on 9/29/26, at Vince's request.
//
//  The scheduler behind `--concurrency`: runs a plan's items a few at a time, keeps items that write to the same
//  place in order, and stops starting new ones after a failure. Shared by `export`, `import` and `migrate`.
//

import Noora

/// What happened to one item of a plan.
enum ItemOutcome<Output: Sendable>: Sendable {
    case completed(Output)
    case failed(any Error)
    case notStarted
}

/// Groups plan positions into lanes by destination. Items in one lane write to the same place (a target
/// collection), so they run one at a time, in plan order. Lanes are ordered by where their first item is in the plan.
func makeLanes(destinationKeys: [String]) -> [[Int]] {
    var laneForKey: [String: Int] = [:]
    var lanes: [[Int]] = []
    for (index, key) in destinationKeys.enumerated() {
        if let lane = laneForKey[key] {
            lanes[lane].append(index)
        } else {
            laneForKey[key] = lanes.count
            lanes.append([index])
        }
    }
    return lanes
}

/// Runs `operation` on every item, at most `limit` at a time, and returns each item's outcome by plan position.
///
/// - Items in the same lane never overlap, and run in plan order.
/// - Once an item fails, nothing new starts. Items already running are left to finish: MongoKitten doesn't
///   promise to stop at a cancellation check, and stopping a healthy copy halfway through would only leave
///   another half-written collection. Everything never started comes back as `.notStarted`.
/// - `slot` is in `0..<min(limit, lanes.count)`, and no two running items share one, so the caller can give each
///   slot its own connection.
///
/// Each child task runs one item and reports back, and only this function's own task decides what starts next.
/// That keeps all the bookkeeping in plain local variables, with nothing shared between tasks.
func runConcurrently<Item: Sendable, Output: Sendable>(
    items: [Item],
    lanes: [[Int]],
    limit: Int,
    operation: @escaping @Sendable (_ index: Int, _ item: Item, _ slot: Int) async throws -> Output
) async -> [ItemOutcome<Output>] {
    var outcomes = [ItemOutcome<Output>](repeating: .notStarted, count: items.count)
    var remaining = lanes
    var busyLanes = Set<Int>()
    var freeSlots = Array((0..<min(limit, lanes.count)).reversed())
    var stopped = false

    /// The free lane whose next item comes first in the plan, so items start in plan order when they can.
    func nextLane() -> Int? {
        remaining.indices
            .filter { !busyLanes.contains($0) && !remaining[$0].isEmpty }
            .min { remaining[$0][0] < remaining[$1][0] }
    }

    await withTaskGroup(of: FinishedItem<Output>.self) { group in
        func startNext() -> Bool {
            guard !stopped, let lane = nextLane(), let slot = freeSlots.popLast() else {
                return false
            }
            let index = remaining[lane].removeFirst()
            let item = items[index]
            busyLanes.insert(lane)
            group.addTask {
                do {
                    let output = try await operation(index, item, slot)
                    return FinishedItem(index: index, lane: lane, slot: slot, outcome: .completed(output))
                } catch {
                    return FinishedItem(index: index, lane: lane, slot: slot, outcome: .failed(error))
                }
            }
            return true
        }

        while startNext() {}

        while let finished = await group.next() {
            outcomes[finished.index] = finished.outcome
            busyLanes.remove(finished.lane)
            freeSlots.append(finished.slot)
            if case .failed = finished.outcome {
                stopped = true
            }
            while startNext() {}
        }
    }
    return outcomes
}

/// What a child task in `runConcurrently` reports back: which item it ran, the lane and slot it held, and how it went.
private struct FinishedItem<Output: Sendable>: Sendable {
    let index: Int
    let lane: Int
    let slot: Int
    let outcome: ItemOutcome<Output>
}

/// After a run: when everything completed, returns the outputs in plan order. Otherwise prints what completed, what
/// failed and why, and what never started, then throws the first failure in plan order, so the command exits
/// non-zero as it always has on a failure.
/// - Parameters:
///   - labels: How each item is named in the report, e.g. `users.bson → users`.
///   - summary: How a completed item's result is described, e.g. `1200 inserted`.
func completedOutputs<Output>(
    of outcomes: [ItemOutcome<Output>],
    labels: [String],
    summary: (Output) -> String
) throws -> [Output] {
    var outputs: [Output] = []
    var completed: [TerminalText] = []
    var failed: [TerminalText] = []
    var notStarted: [String] = []
    var firstError: (any Error)?

    for (outcome, label) in zip(outcomes, labels) {
        switch outcome {
        case let .completed(output):
            outputs.append(output)
            completed.append("Completed: \(label): \(summary(output))")
        case let .failed(error):
            failed.append("Failed: \(label): \(String(describing: error))")
            firstError = firstError ?? error
        case .notStarted:
            notStarted.append(label)
        }
    }

    guard let firstError else {
        return outputs
    }

    var takeaways = failed + completed
    if !notStarted.isEmpty {
        takeaways.append("Not started: \(notStarted.joined(separator: ", "))")
    }
    Noora().error(.alert("\(failed.count) of \(labels.count) failed, so nothing new was started", takeaways: takeaways))
    throw firstError
}
