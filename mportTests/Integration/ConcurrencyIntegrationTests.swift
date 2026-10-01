//
//  ConcurrencyIntegrationTests.swift
//  Created by Claude on 9/29/26, at Vince's request.
//
//  The spec's scenarios for running several collections at once, against a real MongoDB.
//

import ArgumentParser
import Foundation
import MongoKitten
import Testing

extension MongoDatabase {
    /// Runs a raw database command, for setup MongoKitten has no helper for (views, validators).
    fileprivate func runSetupCommand(_ command: Document) async throws {
        let connection = try await pool.next(for: .writable)
        let reply = try await connection.execute(command, namespace: commandNamespace)
        guard try reply.isOK() else {
            throw CLIError.importFailed(collection: name, reason: "setup command failed: \(command)")
        }
    }
}

@Suite(
    "Running collections concurrently",
    .tags(.integration),
    .enabled(if: TestMongo.isAvailable, "Needs a MongoDB at MPORT_TEST_MONGO_URI (default localhost:27017)"),
    .timeLimit(.minutes(2))
)
struct ConcurrencyIntegrationTests {

    /// A board that prints nothing, so test output stays readable.
    private func quietBoard(total: Int) -> ProgressBoard {
        ProgressBoard(total: total, pipeline: RecordingPipeline(), isInteractive: false)
    }

    /// The import flow after the plan is confirmed, minus the prompts: open slots, import, close them.
    private func importPlan(
        _ plan: [ImportItem],
        into db: MongoDatabase,
        limit: Int,
        replacingDuplicates: Bool = false
    ) async throws -> [ItemOutcome<WriteResult>] {
        let laneCount = makeLanes(destinationKeys: plan.map(\.collectionName)).count
        let slots = try await ClientSlots.open(count: min(limit, laneCount), reusing: db, uri: TestMongo.uri)
        let outcomes = await Import.importItems(
            plan,
            into: (slots: slots, database: db.name),
            replacingDuplicates: replacingDuplicates,
            board: quietBoard(total: plan.count)
        )
        await slots.disconnect()
        return outcomes
    }

    private func results(_ outcomes: [ItemOutcome<WriteResult>]) -> [[Int]] {
        outcomes.map { outcome in
            guard case let .completed(result) = outcome else {
                return []
            }
            return [result.inserted, result.replaced, result.skipped]
        }
    }

    // MARK: Results match a sequential run

    /// Catches: concurrency changing what gets written, e.g. documents lost or duplicated between batches.
    @Test("Importing at limit 4 gives exactly what limit 1 gives")
    func sameResultsAtEveryLimit() async throws {
        try await withTemporaryDirectory { directory in
            var plan: [ImportItem] = []
            for number in 1...6 {
                let file = directory.appending(path: "c\(number).bson")
                try writeBSONFile(SampleDocuments.mixedTypes(count: number * 400), to: file)
                plan.append(ImportItem(file: file, displayName: file.lastPathComponent))
            }

            try await TestMongo.withTemporaryDatabase { sequential in
                try await TestMongo.withTemporaryDatabase { concurrent in
                    let sequentialOutcomes = try await importPlan(plan, into: sequential, limit: 1)
                    let concurrentOutcomes = try await importPlan(plan, into: concurrent, limit: 4)

                    #expect(results(concurrentOutcomes) == results(sequentialOutcomes))
                    #expect(results(concurrentOutcomes).allSatisfy { !$0.isEmpty })
                    for item in plan {
                        let expected = try await sequential[item.collectionName].allDocuments()
                        #expect(try await concurrent[item.collectionName].allDocuments() == expected)
                    }
                }
            }
        }
    }

    // MARK: Items sharing a target collection

    /// Catches: two files renamed into one collection racing each other, so "last file wins" stops being true.
    @Test("Two files into one collection: the later file's version wins, as in a sequential run")
    func sharedTargetKeepsPlanOrder() async throws {
        try await withTemporaryDirectory { directory in
            let first = directory.appending(path: "a.bson")
            let second = directory.appending(path: "b.bson")
            try writeBSONFile((1...3000).map { id -> Document in ["_id": id, "from": "a"] }, to: first)
            try writeBSONFile((2001...5000).map { id -> Document in ["_id": id, "from": "b"] }, to: second)

            var plan = [ImportItem(file: first, displayName: "a.bson"), ImportItem(file: second, displayName: "b.bson")]
            for index in plan.indices {
                plan[index].collectionName = "users"
            }

            try await TestMongo.withTemporaryDatabase { db in
                _ = try await importPlan(plan, into: db, limit: 4, replacingDuplicates: true)

                let documents = try await db["users"].allDocuments()
                #expect(documents.count == 5000)
                let overlap = documents.filter { ($0["_id"] as? Int).map { (2001...3000).contains($0) } ?? false }
                #expect(overlap.count == 1000)
                #expect(overlap.allSatisfy { $0["from"] as? String == "b" })
            }
        }
    }

    // MARK: Failure stops new work

    /// Catches: a failure cancelling copies already underway, or the run carrying on to start more.
    @Test("When one migration fails, running ones finish and nothing new starts")
    func failureStopsNewWork() async throws {
        try await TestMongo.withTemporaryDatabase { source in
            try await TestMongo.withTemporaryDatabase { target in
                // Kept small: inserts from a Debug test build run at about 2 ms per document.
                let names = (1...6).map { "c\($0)" }
                for name in names {
                    try await source[name].insertMany(SampleDocuments.numbered(name == "c3" ? 1...10 : 1...1500))
                }
                // Every insert into c3 is rejected by the validator: a real write error, not a duplicate _id.
                let required: Document = ["neverPresent"]
                let schema: Document = ["required": required]
                let validator: Document = ["$jsonSchema": schema]
                try await target.runSetupCommand(["create": "c3", "validator": validator])

                let plan = names.map(MigrationItem.init)
                let sourceSlots = try await ClientSlots.open(count: 2, reusing: source, uri: TestMongo.uri)
                let targetSlots = try await ClientSlots.open(count: 2, reusing: target, uri: TestMongo.uri)
                let outcomes = await Migrate.copyItems(
                    plan,
                    from: (slots: sourceSlots, database: source.name),
                    to: (slots: targetSlots, database: target.name),
                    replacingDuplicates: false,
                    board: quietBoard(total: plan.count)
                )
                await sourceSlots.disconnect()
                await targetSlots.disconnect()

                guard case .failed = outcomes[2] else {
                    Issue.record("c3 should have failed, got \(outcomes[2])")
                    return
                }
                // c1 and c2 start first. c3 starts when the first of them finishes, and c4 when the second does,
                // so c3 always starts first, and it fails on its only batch while c4 still has two to go.
                // c4 may or may not have started by then; c5 and c6 can't have.
                for index in [0, 1] {
                    guard case let .completed(result) = outcomes[index] else {
                        Issue.record("\(names[index]) should have completed, got \(outcomes[index])")
                        continue
                    }
                    #expect(result.inserted == 1500)
                }
                if case let .completed(result) = outcomes[3] {
                    #expect(result.inserted == 1500)
                }
                let existing = Set(try await target.listCollections().map(\.name))
                for index in [4, 5] {
                    guard case .notStarted = outcomes[index] else {
                        Issue.record("\(names[index]) shouldn't have started, got \(outcomes[index])")
                        continue
                    }
                    #expect(!existing.contains(names[index]))
                }
                #expect(throws: CLIError.self) {
                    try completedOutputs(of: outcomes, labels: names, summary: \.summary)
                }
            }
        }
    }

    // MARK: Backups before writing

    /// Catches: imported documents ending up in a dump-before-import backup, or old documents surviving the clear.
    @Test("With dump-before-import, backups hold only the old documents and targets only the new ones")
    func backupsBeforeWriting() async throws {
        try await withTemporaryDirectory { directory in
            try await TestMongo.withTemporaryDatabase { db in
                let original = SampleDocuments.numbered(1...50)
                let imported = SampleDocuments.numbered(1000...1300)
                var plan: [ImportItem] = []
                for name in ["c1", "c2", "c3", "c4"] {
                    let file = directory.appending(path: "files/\(name).bson")
                    try writeBSONFile(imported, to: file)
                    plan.append(ImportItem(file: file, displayName: file.lastPathComponent))
                }
                for name in ["c1", "c2", "c3"] {
                    try await db[name].insertMany(original)
                }
                let backupDirectory = directory.appending(path: "backups")
                let collisions = CollisionPlan(
                    collectionNames: ["c1", "c2", "c3"], strategy: .dumpBeforeImport, backupDirectory: backupDirectory
                )

                let slots = try await ClientSlots.open(count: 4, reusing: db, uri: TestMongo.uri)
                try await collisions.prepare(in: (slots: slots, database: db.name))
                await slots.disconnect()
                _ = try await importPlan(plan, into: db, limit: 4)

                for name in ["c1", "c2", "c3"] {
                    #expect(try readBSONFile(at: backupDirectory.appending(path: "\(name).bson")) == original)
                }
                for name in ["c1", "c2", "c3", "c4"] {
                    #expect(try await db[name].allDocuments() == imported)
                }
            }
        }
    }

    // MARK: Export

    /// Catches: `Users` and `users` both being written to one file on the default macOS disk.
    @Test(
        "Exporting collections that differ only by case is refused before anything is written",
        .enabled(
            if: !isCaseSensitiveVolume(at: FileManager.default.temporaryDirectory),
            "Only applies where the disk doesn't tell upper and lower case apart"
        )
    )
    func exportCaseClashRefused() async throws {
        try await withTemporaryDirectory { directory in
            try await TestMongo.withTemporaryDatabase { db in
                for name in ["Users", "users", "orders"] {
                    try await db[name].insert(["_id": 1])
                }
                let available = try await db.listCollections().map(\.name)
                let selected = try Export.parse(["-e"]).selectCollections(from: available, in: db.name)

                let error = #expect(throws: ExportNameClashError.self) {
                    try Export.refuseCaseClashes(in: selected, exportingTo: directory)
                }
                #expect(error.map { Set($0.groups.flatMap { $0 }) } == ["Users", "users"])
                #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
            }
        }
    }

    /// Catches: `system.views` (created by any view) being exported as if it held data.
    @Test("--export-all skips system collections")
    func exportSkipsSystemCollections() async throws {
        try await withTemporaryDirectory { directory in
            try await TestMongo.withTemporaryDatabase { db in
                try await db["users"].insertMany(SampleDocuments.numbered(1...10))
                let emptyPipeline: Document = []
                try await db.runSetupCommand(["create": "activeUsers", "viewOn": "users", "pipeline": emptyPipeline])

                let available = try await db.listCollections().map(\.name)
                #expect(available.contains("system.views"))
                let selected = try Export.parse(["-e"]).selectCollections(from: available, in: db.name)
                try Export.refuseCaseClashes(in: selected, exportingTo: directory)
                let slots = try await ClientSlots.open(count: min(4, selected.count), reusing: db, uri: TestMongo.uri)
                try await Export.export(selected, from: (slots: slots, database: db.name), to: directory, format: .bson)
                await slots.disconnect()

                #expect(try readBSONFile(at: directory.appending(path: "users.bson")).count == 10)
                #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "system.views.bson").path))
            }
        }
    }
}
