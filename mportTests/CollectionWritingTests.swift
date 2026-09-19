//
//  CollectionWritingTests.swift
//  Created by Claude on 9/18/26, at Vince's request.
//
//  The pure parts of CollectionWriting.swift. The parts that talk to MongoDB are in Integration/.
//

import Foundation
import Testing

@Suite("Collection name lists")
struct ParseNameListTests {

    struct Case: CustomTestStringConvertible, Sendable {
        let values: [String]
        let expected: [String]

        var testDescription: String { values.debugDescription }
    }

    static let cases: [Case] = [
        Case(values: [], expected: []),
        Case(values: ["users"], expected: ["users"]),
        Case(values: ["users,orders"], expected: ["users", "orders"]),
        Case(values: [" users , orders "], expected: ["users", "orders"]),
        Case(values: ["users", "orders,items"], expected: ["users", "orders", "items"]),
        Case(values: ["users,,orders,"], expected: ["users", "orders"]),
        Case(values: [" , "], expected: [])
    ]

    /// Catches: `-c "a, b"` looking for a collection called " b", or an empty name matching nothing and prompting.
    @Test("Splits on commas, trims, and drops empties", arguments: cases)
    func parses(_ testCase: Case) {
        #expect(parseNameList(testCase.values) == testCase.expected)
    }
}

@Suite("WriteResult")
struct WriteResultTests {

    /// Catches: the success message's totals double-counting or dropping replaced documents.
    @Test("written counts inserted and replaced, not skipped")
    func writtenExcludesSkipped() {
        let result = WriteResult(inserted: 5, replaced: 2, skipped: 3)
        #expect(result.written == 7)
    }

    /// Catches: per-batch counts being lost when results are combined across batches.
    @Test("+= adds every counter")
    func addsResults() {
        var total = WriteResult(inserted: 1, replaced: 2, skipped: 3)
        total += WriteResult(inserted: 10, replaced: 20, skipped: 30)

        #expect(total.inserted == 11)
        #expect(total.replaced == 22)
        #expect(total.skipped == 33)
    }

    struct SummaryCase: CustomTestStringConvertible, Sendable {
        let result: WriteResult
        let expected: String

        var testDescription: String { expected }
    }

    static let summaryCases: [SummaryCase] = [
        SummaryCase(result: WriteResult(), expected: "0 inserted"),
        SummaryCase(result: WriteResult(inserted: 5), expected: "5 inserted"),
        SummaryCase(result: WriteResult(inserted: 4, skipped: 1), expected: "4 inserted, 1 skipped (duplicate _id)"),
        SummaryCase(result: WriteResult(replaced: 5), expected: "0 inserted, 5 replaced"),
        SummaryCase(
            result: WriteResult(inserted: 1, replaced: 2, skipped: 3),
            expected: "1 inserted, 2 replaced, 3 skipped (duplicate _id)"
        )
    ]

    /// Catches: the takeaway lines hiding skipped or replaced documents from the user.
    @Test("summary only mentions counters that happened", arguments: summaryCases)
    func summarizes(_ summaryCase: SummaryCase) {
        #expect(summaryCase.result.summary == summaryCase.expected)
    }
}

@Suite("Backup location")
struct BackupDirectoryTests {

    /// Catches: backups landing somewhere `import` would then offer as files to import.
    @Test("Backups go in a hidden folder, grouped by connection and database")
    func layout() {
        let root = URL(filePath: "/exports")
        let directory = backupDirectory(under: root, connection: "local", database: "shop")
        let components = directory.pathComponents

        #expect(Array(components.prefix(5)) == ["/", "exports", ".mport-backups", "local", "shop"])
        #expect(components.count == 6)
    }

    /// Catches: a timestamp with ":" in it, which Finder shows as "/" and some tools can't handle.
    @Test("The timestamp folder is an ISO 8601 time with no colons")
    func timestampHasNoColons() throws {
        let directory = backupDirectory(under: URL(filePath: "/exports"), connection: "local", database: "shop")
        let timestamp = directory.lastPathComponent

        #expect(!timestamp.contains(":"))
        #expect(try #/^\d{4}-\d{2}-\d{2}T\d{6}Z$/#.wholeMatch(in: timestamp) != nil)
    }
}

@Suite("Collision strategies")
struct CollisionStrategyTests {

    /// Catches: `skip`, `clear` or `dump` silently overwriting existing documents that share an `_id`.
    @Test("Only overwrite replaces duplicate _ids", arguments: CollisionResolution.allCases)
    func onlyOverwriteReplaces(_ strategy: CollisionResolution) {
        let plan = CollisionPlan(collectionNames: ["users"], strategy: strategy, backupDirectory: URL(filePath: "/tmp"))
        #expect(plan.replacesDuplicates == (strategy == .overwrite))
    }

    /// Catches: a renamed raw value breaking `--collision-resolution` values that scripts already pass.
    @Test("Command-line values stay stable")
    func rawValues() {
        #expect(CollisionResolution.allCases.map(\.rawValue) == [
            "dump-before-import", "clear-before-import", "overwrite", "skip"
        ])
    }
}
