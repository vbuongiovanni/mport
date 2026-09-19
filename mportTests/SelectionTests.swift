//
//  SelectionTests.swift
//  Created by Claude on 9/18/26, at Vince's request.
//
//  Deciding *what* to import or migrate. Only the non-interactive paths are covered: when nothing matches,
//  these functions fall through to a Noora prompt, and Noora calls fatalError without a terminal.
//

import ArgumentParser
import Foundation
import MongoKitten
import Testing

@Suite("Import: finding and selecting BSON files")
struct ImportFileSelectionTests {

    /// Lays out a directory like a real `export` folder, plus the things `import` must ignore.
    private func makeExportTree(in root: URL) throws {
        let document: [Document] = [["_id": 1]]
        try writeBSONFile(document, to: root.appending(path: "root.bson"))
        try writeBSONFile(document, to: root.appending(path: "local/shop/users.bson"))
        try writeBSONFile(document, to: root.appending(path: "local/shop/orders.BSON"))
        try writeBSONFile(document, to: root.appending(path: "archive/users.bson"))
        try writeBSONFile(document, to: root.appending(path: ".mport-backups/local/shop/2026-01-01T000000Z/users.bson"))
        try Data("{}".utf8).write(to: root.appending(path: "local/shop/users.metadata.json"))
        let folderNamedLikeAFile = root.appending(path: "weird.bson")
        try FileManager.default.createDirectory(at: folderNamedLikeAFile, withIntermediateDirectories: true)
    }

    /// Catches: backups, metadata files or folders showing up as importable, or labels losing their folder.
    @Test("Finds .bson files in subfolders, skipping hidden folders, other files and directories")
    func findsImportableFiles() async throws {
        try await withTemporaryDirectory { root in
            try makeExportTree(in: root)

            let files = try Import.parse([]).findBSONFiles(in: root)

            #expect(files.map(\.displayName) == [
                "archive/users.bson", "local/shop/orders.BSON", "local/shop/users.bson", "root.bson"
            ])
            #expect(files.map(\.collectionName) == ["users", "orders", "users", "root"])
        }
    }

    /// Catches: the relative-path URLs pointing somewhere other than the real file (the /private/tmp bug).
    @Test("Each file's URL opens the real file, even though its label is relative")
    func urlsResolveToRealFiles() async throws {
        try await withTemporaryDirectory { root in
            try makeExportTree(in: root)

            for file in try Import.parse([]).findBSONFiles(in: root) {
                #expect(FileManager.default.fileExists(atPath: file.file.path), "\(file.displayName)")
                #expect(try readBSONFile(at: file.file).count == 1)
            }
        }
    }

    /// Catches: an empty folder crashing or prompting instead of producing the noBSONFiles error upstream.
    @Test("An empty directory has no files")
    func emptyDirectory() async throws {
        let command = try Import.parse([])
        await withTemporaryDirectory { root in
            #expect(command.findBSONFiles(in: root).isEmpty)
        }
    }

    struct SelectionCase: CustomTestStringConvertible, Sendable {
        let arguments: [String]
        let expected: [String]

        var testDescription: String { arguments.joined(separator: " ") }
    }

    static let selectionCases: [SelectionCase] = [
        SelectionCase(
            arguments: ["--import-all"],
            expected: ["archive/users.bson", "local/shop/orders.BSON", "local/shop/users.bson", "root.bson"]
        ),
        SelectionCase(arguments: ["-c", "users"], expected: ["archive/users.bson", "local/shop/users.bson"]),
        SelectionCase(arguments: ["-c", "orders,root"], expected: ["local/shop/orders.BSON", "root.bson"]),
        SelectionCase(arguments: ["-c", "orders", "-c", "missing"], expected: ["local/shop/orders.BSON"])
    ]

    /// Catches: --import-all or -c selecting the wrong files, or unknown names wiping out the known ones.
    @Test("--import-all and -c pick files without prompting", arguments: selectionCases)
    func selectsFromFlags(_ selectionCase: SelectionCase) async throws {
        try await withTemporaryDirectory { root in
            try makeExportTree(in: root)
            let command = try Import.parse(selectionCase.arguments)

            let selected = command.selectFiles(from: command.findBSONFiles(in: root))

            #expect(selected.map(\.displayName) == selectionCase.expected)
        }
    }
}

@Suite("Migrate: selecting collections")
struct MigrateCollectionSelectionTests {

    static let available = ["items", "orders", "users"]

    /// Catches: --migrate-all skipping collections.
    @Test("--migrate-all takes every collection")
    func migrateAll() throws {
        let command = try Migrate.parse(["-m"])
        #expect(command.selectCollections(from: Self.available, in: "shop") == Self.available)
    }

    /// Catches: -c returning collections in the typed order instead of the listed order, or keeping unknown names.
    @Test("-c keeps known names, in the source's order", arguments: [
        (["-c", "users,orders"], ["orders", "users"]),
        (["-c", "users", "-c", "missing"], ["users"])
    ])
    func selectsNamed(_ arguments: [String], _ expected: [String]) throws {
        let command = try Migrate.parse(arguments)
        #expect(command.selectCollections(from: Self.available, in: "shop") == expected)
    }
}

@Suite("Migrate: refusing to copy a collection onto itself")
struct RejectSelfCopiesTests {

    struct Case: CustomTestStringConvertible, Sendable {
        let description: String
        let targetAlias: String
        let targetURI: String
        let targetDatabase: String
        let mappings: [(source: String, target: String)]
        /// `nil` means the migration is allowed.
        let expectedOverlap: [String]?

        var testDescription: String { description }
    }

    static let sourceURI = "mongodb://localhost:27017/admin"

    static let cases: [Case] = [
        Case(
            description: "same database, same name",
            targetAlias: "local", targetURI: sourceURI, targetDatabase: "shop",
            mappings: [("users", "users")], expectedOverlap: ["users"]
        ),
        Case(
            description: "same database, renamed",
            targetAlias: "local", targetURI: sourceURI, targetDatabase: "shop",
            mappings: [("users", "users_copy")], expectedOverlap: nil
        ),
        Case(
            description: "same database, a chain that reads a collection it also clears",
            targetAlias: "local", targetURI: sourceURI, targetDatabase: "shop",
            mappings: [("a", "b"), ("b", "c")], expectedOverlap: ["b"]
        ),
        Case(
            description: "a different alias for the same server counts as the same database",
            targetAlias: "second-local", targetURI: sourceURI, targetDatabase: "shop",
            mappings: [("users", "users")], expectedOverlap: ["users"]
        ),
        Case(
            description: "a different database on the same server",
            targetAlias: "local", targetURI: sourceURI, targetDatabase: "shop_copy",
            mappings: [("users", "users")], expectedOverlap: nil
        ),
        Case(
            description: "a different server",
            targetAlias: "remote", targetURI: "mongodb://db.example.com:27017/admin", targetDatabase: "shop",
            mappings: [("users", "users")], expectedOverlap: nil
        )
    ]

    /// `lazyConnect` builds a database handle without touching the network, so this needs no MongoDB.
    private func endpoint(alias: String, uri: String, database: String) throws -> Endpoint {
        let client = try MongoDatabase.lazyConnect(to: uri)
        return Endpoint(
            connection: MongoConnectionRecord(name: alias, uri: uri),
            databaseName: database,
            database: client.pool[database]
        )
    }

    /// Catches: `clear-before-import` being allowed to wipe a source collection before it's copied.
    @Test("Blocks exactly the plans that would read and write the same collection", arguments: cases)
    func rejectsOverlaps(_ testCase: Case) throws {
        let source = try endpoint(alias: "local", uri: Self.sourceURI, database: "shop")
        let target = try endpoint(
            alias: testCase.targetAlias, uri: testCase.targetURI, database: testCase.targetDatabase
        )
        let plan = testCase.mappings.map { mapping in
            var item = MigrationItem(sourceName: mapping.source)
            item.collectionName = mapping.target
            return item
        }
        let command = try Migrate.parse([])

        guard let expectedOverlap = testCase.expectedOverlap else {
            #expect(throws: Never.self) { try command.rejectSelfCopies(in: plan, from: source, to: target) }
            return
        }
        let error = #expect(throws: CLIError.self) {
            try command.rejectSelfCopies(in: plan, from: source, to: target)
        }
        guard case .migrationOverlap(let collections)? = error else {
            Issue.record("Expected migrationOverlap, got \(String(describing: error))")
            return
        }
        #expect(collections == expectedOverlap)
    }
}
