//
//  WriteDocumentsTests.swift
//  Created by Claude on 9/18/26, at Vince's request.
//
//  `writeDocuments` and `insertManyUnordered` against a real MongoDB: the engine both `import` and `migrate` use.
//

import Foundation
import MongoKitten
import Testing

extension Tag {
    /// Tests that need a running MongoDB. Filter them in or out in Xcode's test navigator.
    @Tag static var integration: Self
}

@Suite(
    "Writing documents to MongoDB",
    .tags(.integration),
    .enabled(if: TestMongo.isAvailable, "Needs a MongoDB at MPORT_TEST_MONGO_URI (default localhost:27017)"),
    .timeLimit(.minutes(1))
)
struct WriteDocumentsTests {

    // MARK: insertManyUnordered

    /// Catches: going back to MongoKitten's ordered `insertMany`, which stops at the first duplicate
    /// and silently drops every document after it in the batch.
    @Test("An unordered insert keeps going past a duplicate _id")
    func unorderedInsertContinuesPastDuplicates() async throws {
        try await TestMongo.withTemporaryDatabase { db in
            let collection = db["items"]
            try await collection.insertMany(SampleDocuments.numbered(1...2))

            let reply = try await collection.insertManyUnordered(SampleDocuments.numbered(2...4))

            #expect(reply.insertCount == 2)
            #expect(reply.writeErrors?.map(\.code) == [11000])
            #expect(reply.writeErrors?.map(\.index) == [0])
            #expect(try await collection.count() == 4)
        }
    }

    // MARK: Batching

    /// Catches: documents lost at a batch boundary, or progress stopping before the final partial batch.
    @Test("Writes in batches of 1,000 and reports progress after each")
    func batchesByCount() async throws {
        try await TestMongo.withTemporaryDatabase { db in
            var progress: [Int] = []

            let result = try await writeDocuments(
                asyncSequence(SampleDocuments.numbered(1...2_501)),
                into: db["items"],
                replacingDuplicates: false
            ) { progress.append($0) }

            #expect(progress == [1_000, 2_000, 2_501])
            #expect(result.inserted == 2_501)
            #expect(try await db["items"].count() == 2_501)
        }
    }

    /// Catches: large documents piling into one batch past MongoDB's 48MB message limit.
    @Test("Flushes early once a batch reaches 8MB")
    func batchesByBytes() async throws {
        try await TestMongo.withTemporaryDatabase { db in
            let megabyte = String(repeating: "x", count: 1 << 20)
            let documents: [Document] = (1...12).map { ["_id": $0, "payload": megabyte] }
            var progress: [Int] = []

            let result = try await writeDocuments(
                asyncSequence(documents), into: db["large"], replacingDuplicates: false
            ) { progress.append($0) }

            #expect(progress == [8, 12])
            #expect(result.inserted == 12)
        }
    }

    /// Catches: an empty file sending an empty insert (which MongoDB rejects) or creating an empty collection.
    @Test("An empty source writes nothing and creates no collection")
    func emptySource() async throws {
        try await TestMongo.withTemporaryDatabase { db in
            var progressCalls = 0

            let result = try await writeDocuments(
                asyncSequence([]), into: db["nothing"], replacingDuplicates: false
            ) { _ in progressCalls += 1 }

            #expect(result.written == 0)
            #expect(progressCalls == 0)
            #expect(try await db.listCollections().isEmpty)
        }
    }

    // MARK: Duplicates

    /// Catches: `skip`, `clear` and `dump` overwriting a document that already exists.
    @Test("Without replacing, an existing _id keeps its old document")
    func skipsExistingDuplicates() async throws {
        try await TestMongo.withTemporaryDatabase { db in
            let collection = db["users"]
            try await collection.insert(["_id": 1, "name": "old"])

            let result = try await writeDocuments(
                asyncSequence([["_id": 1, "name": "new"], ["_id": 2, "name": "fresh"]]),
                into: collection,
                replacingDuplicates: false
            ) { _ in }

            #expect(result.inserted == 1)
            #expect(result.skipped == 1)
            #expect(try await collection.findOne(["_id": 1])?["name"] as? String == "old")
        }
    }

    /// Catches: `overwrite` skipping documents instead of replacing them.
    @Test("When replacing, an existing _id gets the new document")
    func replacesExistingDuplicates() async throws {
        try await TestMongo.withTemporaryDatabase { db in
            let collection = db["users"]
            try await collection.insert(["_id": 1, "name": "old", "stale": true])

            let result = try await writeDocuments(
                asyncSequence([["_id": 1, "name": "new"], ["_id": 2, "name": "fresh"]]),
                into: collection,
                replacingDuplicates: true
            ) { _ in }

            #expect(result.inserted == 1)
            #expect(result.replaced == 1)
            let replaced = try #require(try await collection.findOne(["_id": 1]))
            #expect(replaced == ["_id": 1, "name": "new"])
        }
    }

    /// Catches: repeated _ids inside one source behaving differently from repeated _ids across sources.
    /// Skipping keeps the first copy; replacing keeps the last, as if the source were replayed in order.
    @Test("A duplicate within the same source", arguments: [(false, "first"), (true, "second")])
    func duplicateWithinSource(replacing: Bool, survivor: String) async throws {
        try await TestMongo.withTemporaryDatabase { db in
            let collection = db["users"]

            _ = try await writeDocuments(
                asyncSequence([["_id": 1, "copy": "first"], ["_id": 1, "copy": "second"]]),
                into: collection,
                replacingDuplicates: replacing
            ) { _ in }

            #expect(try await collection.count() == 1)
            #expect(try await collection.findOne(["_id": 1])?["copy"] as? String == survivor)
        }
    }

    // MARK: Errors

    /// Catches: write errors other than duplicates being counted as skips instead of stopping the import.
    @Test("A write error that isn't a duplicate stops with importFailed")
    func nonDuplicateErrorThrows() async throws {
        try await TestMongo.withTemporaryDatabase { db in
            let invalidID: Document = [1, 2]
            let error = await #expect(throws: CLIError.self) {
                try await writeDocuments(
                    asyncSequence([["_id": invalidID]]), into: db["items"], replacingDuplicates: false
                ) { _ in }
            }

            guard case .importFailed(let collection, let reason)? = error else {
                Issue.record("Expected importFailed, got \(String(describing: error))")
                return
            }
            #expect(collection == "items")
            #expect(!reason.isEmpty)
        }
    }

    // MARK: End to end

    /// Catches: any BSON type being changed between a dump file and the collection (the import path).
    @Test("A BSON file imports with every document and type intact")
    func importsBSONFile() async throws {
        try await withTemporaryDirectory { directory in
            try await TestMongo.withTemporaryDatabase { db in
                let documents = SampleDocuments.mixedTypes(count: 40)
                let file = directory.appending(path: "users.bson")
                try writeBSONFile(documents, to: file)

                let result = try await writeDocuments(
                    try BSONFileReader(url: file), into: db["users"], replacingDuplicates: false
                ) { _ in }

                #expect(result.inserted == 40)
                #expect(try await db["users"].allDocuments() == documents)
            }
        }
    }

    /// Catches: any BSON type being changed when streaming from one collection into another (the migrate path).
    @Test("A find() cursor copies a collection between databases intact")
    func copiesCursorBetweenDatabases() async throws {
        try await TestMongo.withTemporaryDatabase { source in
            try await TestMongo.withTemporaryDatabase { target in
                let documents = SampleDocuments.mixedTypes(count: 1_200)
                try await source["users"].insertMany(documents)

                let result = try await writeDocuments(
                    source["users"].find(), into: target["users_copy"], replacingDuplicates: false
                ) { _ in }

                #expect(result.inserted == 1_200)
                #expect(try await target["users_copy"].allDocuments() == documents)
            }
        }
    }
}
