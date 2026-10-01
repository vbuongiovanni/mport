//
//  ConcurrentRunnerTests.swift
//  Created by Claude on 9/29/26, at Vince's request.
//

import Testing

/// Stands in for the real work in `runConcurrently`. Every item blocks inside `enter` until the test releases it,
/// so a test decides exactly when each item finishes, instead of sleeping and hoping.
private actor Gatekeeper {
    struct Start: Equatable {
        let index: Int
        let slot: Int
    }

    private(set) var starts: [Start] = []
    private(set) var maxRunning = 0
    private(set) var slotConflicts: [Int] = []
    private var runningSlots = Set<Int>()
    private var finished = Set<Int>()
    private var released = Set<Int>()
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var finishWaiters: [(index: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(releasing preReleased: Set<Int> = []) {
        released = preReleased
    }

    /// Called by the fake operation: records the start, then waits for `release(index)`.
    func enter(_ index: Int, slot: Int) async {
        starts.append(Start(index: index, slot: slot))
        if !runningSlots.insert(slot).inserted {
            slotConflicts.append(slot)
        }
        maxRunning = max(maxRunning, runningSlots.count)
        resumeStartWaiters()

        if !released.contains(index) {
            await withCheckedContinuation { gates[index] = $0 }
        }

        runningSlots.remove(slot)
        finished.insert(index)
        resumeFinishWaiters()
    }

    func release(_ index: Int) {
        released.insert(index)
        gates.removeValue(forKey: index)?.resume()
    }

    var startedIndices: [Int] {
        starts.map(\.index)
    }

    /// Suspends until at least `count` items have started.
    func waitForStarts(_ count: Int) async {
        guard starts.count < count else {
            return
        }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    /// Suspends until item `index` has finished its work.
    func waitForFinish(_ index: Int) async {
        guard !finished.contains(index) else {
            return
        }
        await withCheckedContinuation { finishWaiters.append((index, $0)) }
    }

    private func resumeStartWaiters() {
        startWaiters.removeAll { waiter in
            guard starts.count >= waiter.count else {
                return false
            }
            waiter.continuation.resume()
            return true
        }
    }

    private func resumeFinishWaiters() {
        finishWaiters.removeAll { waiter in
            guard finished.contains(waiter.index) else {
                return false
            }
            waiter.continuation.resume()
            return true
        }
    }
}

private struct Boom: Error {}

@Suite("Concurrent runner", .timeLimit(.minutes(1)))
struct ConcurrentRunnerTests {

    private func completedIndices(_ outcomes: [ItemOutcome<Int>]) -> [Int] {
        outcomes.enumerated().compactMap { index, outcome -> Int? in
            guard case .completed = outcome else {
                return nil
            }
            return index
        }
    }

    // MARK: Lanes

    /// Catches: items sharing a destination landing in different lanes, or lanes coming out of plan order.
    @Test("Lanes group items by destination, ordered by first appearance")
    func lanes() {
        #expect(makeLanes(destinationKeys: ["a", "b", "c"]) == [[0], [1], [2]])
        #expect(makeLanes(destinationKeys: ["a", "b", "a", "c", "b"]) == [[0, 2], [1, 4], [3]])
        #expect(makeLanes(destinationKeys: []).isEmpty)
    }

    // MARK: Scheduling

    /// Catches: the window overfilling (too many connections at once), or slots being handed out twice.
    @Test("Never more than the limit in flight, and never two items on one slot")
    func respectsLimit() async {
        let gate = Gatekeeper()
        let lanes = makeLanes(destinationKeys: (0..<6).map(String.init))
        let run = Task {
            await runConcurrently(items: Array(0..<6), lanes: lanes, limit: 2) { index, _, slot in
                await gate.enter(index, slot: slot)
                return index
            }
        }

        await gate.waitForStarts(2)
        // Items 0 and 1 start together, so either can reach the gate first.
        #expect(Set(await gate.startedIndices) == [0, 1])
        for index in 0..<6 {
            await gate.release(index)
            await gate.waitForStarts(min(index + 3, 6))
        }
        let outcomes = await run.value

        #expect(completedIndices(outcomes) == Array(0..<6))
        #expect(await gate.maxRunning == 2)
        #expect(await gate.slotConflicts.isEmpty)
        #expect(await gate.starts.allSatisfy { (0..<2).contains($0.slot) })
    }

    /// Catches: a limit of 1 not being a plain sequential run.
    @Test("A limit of 1 runs strictly in plan order")
    func limitOfOneIsSequential() async {
        let gate = Gatekeeper(releasing: Set(0..<5))
        let lanes = [[0], [1], [2], [3], [4]]
        let outcomes = await runConcurrently(items: Array(0..<5), lanes: lanes, limit: 1) { index, _, slot in
            await gate.enter(index, slot: slot)
            return index
        }

        #expect(completedIndices(outcomes) == Array(0..<5))
        #expect(await gate.startedIndices == Array(0..<5))
        #expect(await gate.maxRunning == 1)
    }

    /// Catches: two files renamed into one collection being written at the same time, or out of order.
    @Test("Items in the same lane never overlap, and run in plan order")
    func lanesRunInOrder() async {
        let gate = Gatekeeper()
        let run = Task {
            await runConcurrently(items: Array(0..<4), lanes: [[0, 2], [1, 3]], limit: 4) { index, _, slot in
                await gate.enter(index, slot: slot)
                return index
            }
        }

        await gate.waitForStarts(2)
        // The heads of both lanes start together, in either order.
        #expect(Set(await gate.startedIndices) == [0, 1])

        await gate.release(0)
        await gate.waitForStarts(3)
        #expect(await gate.startedIndices.last == 2)

        await gate.release(1)
        await gate.waitForStarts(4)
        #expect(await gate.startedIndices.last == 3)
        #expect(await gate.startedIndices.count == 4)

        await gate.release(2)
        await gate.release(3)
        let outcomes = await run.value

        #expect(completedIndices(outcomes) == [0, 1, 2, 3])
        #expect(await gate.maxRunning == 2)
    }

    /// Catches: opening more connections than there are lanes to use them.
    @Test("With fewer lanes than the limit, only that many slots are used")
    func slotsCappedByLanes() async {
        let gate = Gatekeeper(releasing: Set(0..<4))
        _ = await runConcurrently(items: Array(0..<4), lanes: [[0, 2], [1, 3]], limit: 8) { index, _, slot in
            await gate.enter(index, slot: slot)
            return index
        }

        #expect(Set(await gate.starts.map(\.slot)).isSubset(of: [0, 1]))
    }

    /// Catches: an empty plan hanging, or crashing on an empty slot list.
    @Test("An empty plan finishes with no outcomes")
    func emptyPlan() async {
        let outcomes = await runConcurrently(items: [Int](), lanes: [], limit: 4) { _, item, _ in item }
        #expect(outcomes.isEmpty)
    }

    // MARK: Failure

    /// Catches: a failure cancelling healthy copies halfway through, or new items starting after one failed.
    @Test("After a failure nothing new starts, and items already running finish")
    func failureStopsNewWork() async throws {
        // Item 1 fails as soon as it starts, item 0 is held open, and items 2-5 would finish immediately if the
        // runner (wrongly) started them.
        let gate = Gatekeeper(releasing: Set([1, 2, 3, 4, 5]))
        let run = Task {
            await runConcurrently(items: Array(0..<6), lanes: (0..<6).map { [$0] }, limit: 2) { index, _, slot in
                await gate.enter(index, slot: slot)
                if index == 1 {
                    throw Boom()
                }
                return index
            }
        }

        await gate.waitForFinish(1)
        // The runner learns about item 1's failure only when it collects that result, so give it a moment before
        // letting item 0 finish. Without the pause, item 0 could finish first and legitimately start item 2.
        try await Task.sleep(for: .milliseconds(200))
        await gate.release(0)
        let outcomes = await run.value

        #expect(await gate.startedIndices.sorted() == [0, 1])
        guard case .completed(0) = outcomes[0] else {
            Issue.record("Item 0 should have finished, got \(outcomes[0])")
            return
        }
        guard case .failed(let error) = outcomes[1] else {
            Issue.record("Item 1 should have failed, got \(outcomes[1])")
            return
        }
        #expect(error is Boom)
        for outcome in outcomes[2...] {
            guard case .notStarted = outcome else {
                Issue.record("Expected .notStarted, got \(outcome)")
                continue
            }
        }
    }

    /// Catches: a failed run returning normally, or the report throwing something other than the real failure.
    @Test("completedOutputs returns outputs when all succeed, and throws the first failure otherwise")
    func completedOutputsReportsFailures() throws {
        let allGood: [ItemOutcome<Int>] = [.completed(1), .completed(2)]
        #expect(try completedOutputs(of: allGood, labels: ["a", "b"]) { "\($0)" } == [1, 2])

        let mixed: [ItemOutcome<Int>] = [.completed(1), .failed(Boom()), .notStarted]
        #expect(throws: Boom.self) {
            try completedOutputs(of: mixed, labels: ["a", "b", "c"]) { "\($0)" }
        }
    }
}
