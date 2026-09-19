//
//  ExportRoundTripTests.swift
//  Created by Claude on 9/18/26, at Vince's request.
//
//  The promise at the heart of mport: what `export` writes, `import` can read back.
//

import ArgumentParser
import Foundation
import MongoKitten
import Testing

@Suite(
    "Export formats and round trips",
    .tags(.integration),
    .enabled(if: TestMongo.isAvailable, "Needs a MongoDB at MPORT_TEST_MONGO_URI (default localhost:27017)"),
    .timeLimit(.minutes(1))
)
struct ExportRoundTripTests {

    private let exporter: Export

    init() throws {
        exporter = try Export.parse(["/unused", "local", "unused"])
    }

    /// Catches: export and import disagreeing about the BSON file layout.
    @Test("A BSON export imports back into another database unchanged")
    func bsonRoundTrip() async throws {
        try await withTemporaryDirectory { directory in
            try await TestMongo.withTemporaryDatabase { source in
                try await TestMongo.withTemporaryDatabase { target in
                    let documents = SampleDocuments.mixedTypes(count: 150)
                    try await source["users"].insertMany(documents)

                    try await exporter.exportCollection(
                        savePath: directory.path, collection: source["users"], format: .bson
                    )
                    let file = directory.appending(path: "users.bson")
                    #expect(try readBSONFile(at: file) == documents)

                    _ = try await writeDocuments(
                        try BSONFileReader(url: file), into: target["users"], replacingDuplicates: false
                    ) { _ in }
                    #expect(try await target["users"].allDocuments() == documents)
                }
            }
        }
    }

    /// Catches: a missing comma or bracket making the JSON export unparseable.
    @Test("A JSON export is one valid JSON array with every document")
    func jsonExportIsValid() async throws {
        try await withTemporaryDirectory { directory in
            try await TestMongo.withTemporaryDatabase { db in
                try await db["orders"].insertMany(SampleDocuments.numbered(1...25))

                try await exporter.exportCollection(savePath: directory.path, collection: db["orders"], format: .json)

                let data = try Data(contentsOf: directory.appending(path: "orders.json"))
                let array = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
                #expect(array.count == 25)
            }
        }
    }

    /// Catches: an empty collection exporting invalid JSON, since the comma logic has a first-item special case.
    @Test("An empty collection exports as an empty JSON array")
    func emptyJSONExport() async throws {
        try await withTemporaryDirectory { directory in
            try await TestMongo.withTemporaryDatabase { db in
                try await exporter.exportCollection(savePath: directory.path, collection: db["empty"], format: .json)

                let data = try Data(contentsOf: directory.appending(path: "empty.json"))
                let array = try #require(try JSONSerialization.jsonObject(with: data) as? [Any])
                #expect(array.isEmpty)
            }
        }
    }

    /// Catches: the shell export's framing between documents changing.
    @Test("A mongo shell export is each document's shell syntax, one after another")
    func shellExport() async throws {
        try await withTemporaryDirectory { directory in
            try await TestMongo.withTemporaryDatabase { db in
                try await db["users"].insertMany(SampleDocuments.numbered(1...5))

                try await exporter.exportCollection(
                    savePath: directory.path, collection: db["users"], format: .mongoShellSyntax
                )

                let written = try String(contentsOf: directory.appending(path: "users.json"), encoding: .utf8)
                let expected = try await db["users"].find().drain().map { $0.shellJSON(indent: 0) + "\n" }.joined()
                #expect(written == expected)
            }
        }
    }
}
