//
//  Migrate.swift
//  Created by Claude on 9/18/26, at Vince's request.
//

import Foundation
import ArgumentParser
import MongoKitten
import Noora

struct Migrate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Copy collections from one connection/database directly into another",
        discussion: """
        Documents are streamed from the source straight into the target, so nothing is written to disk \
        (except the backup, if you pick the dump-before-import collision strategy).
        """
    )

    @Option(name: .customLong("from"), help: "Alias of the connection to copy from")
    var sourceConnection: String?

    @Option(name: .customLong("from-db"), help: "Name of the database to copy from")
    var sourceDatabase: String?

    @Option(name: .customLong("to"), help: "Alias of the connection to copy into")
    var targetConnection: String?

    @Option(name: .customLong("to-db"), help: "Name of the database to copy into")
    var targetDatabase: String?

    @Flag(name: .shortAndLong, help: "Migrate every collection in the source database")
    var migrateAll: Bool = false

    @Option(name: .shortAndLong, help: "Comma separated list of collections to migrate")
    var collectionNames: [String] = []

    @Option(name: .long, help: "Collision Resolution Strategy")
    var collisionResolution: String?

    func run() async throws {
        let config = try CLIConfig.read()
        guard !config.connections.isEmpty else {
            throw CLIError.emptyConfig
        }

        let source = try await selectEndpoint(
            .source, config: config, connectionName: sourceConnection, dbName: sourceDatabase
        )
        let target = try await selectEndpoint(
            .target, config: config, connectionName: targetConnection, dbName: targetDatabase
        )

        let plan = try await planCollections(from: source)
        try rejectSelfCopies(in: plan, from: source, to: target)

        // Determine if Collisions are possible
        let backupRoot = URL(filePath: config.defaultExportPath ?? FileManager.default.currentDirectoryPath)
        let collisions = try await CollisionPlan.resolve(
            for: plan.map(\.collectionName),
            in: target.database,
            flagValue: collisionResolution,
            backupDirectory: backupDirectory(
                under: backupRoot,
                connection: target.connection.name,
                database: target.databaseName
            )
        )

        let executePlan = confirmPlan(
            details: ["From: \(source.label)", "To:   \(target.label)"],
            heading: "Collections To Migrate:",
            items: plan,
            collisions: collisions,
            action: "migration"
        )

        guard executePlan else {
            print("Migration cancelled, nothing was changed.")
            return
        }

        try await collisions.prepare(in: target.database)
        try await copyCollections(plan, from: source, to: target, replacingDuplicates: collisions.replacesDuplicates)
    }

    // MARK: - Steps

    /// Picks a connection, connects to it, and picks a database on it: one side of the migration.
    private func selectEndpoint(
        _ side: Endpoint.Side,
        config: CLIConfig,
        connectionName: String?,
        dbName: String?
    ) async throws -> Endpoint {
        guard let connection = try? selectConnection(
            config: config,
            connectionName: connectionName,
            title: "\(side.title) Connection",
            description: "Select the connection to \(side.verb)"
        ) else {
            throw CLIError.missingArgument(argument: side.connectionFlag)
        }

        print("Connecting to \(connection.name)...")
        let client: MongoDatabase
        do {
            client = try await MongoDatabase.connect(to: connection.uri)
        } catch {
            throw CLIError.connectionFailed
        }

        guard let databaseName = try? await selectDatabase(
            using: client,
            dbName: dbName,
            title: "\(side.title) Database",
            description: "Select the database to \(side.verb)"
        ) else {
            throw CLIError.missingArgument(argument: "\(side.connectionFlag)-db")
        }

        return Endpoint(connection: connection, databaseName: databaseName, database: client.pool[databaseName])
    }

    /// Lists the source's collections, lets the user pick which to migrate, and offers to rename their targets.
    private func planCollections(from source: Endpoint) async throws -> [MigrationItem] {
        let availableCollections = try await source.database.listCollections()
            .map(\.name)
            .filter { !$0.hasPrefix("system.") }
            .sorted()
        guard !availableCollections.isEmpty else {
            throw CLIError.noCollections(database: source.databaseName)
        }

        return nameCollections(
            for: selectCollections(from: availableCollections, in: source.databaseName).map(MigrationItem.init),
            defaultNaming: "By default each collection keeps its name in the target database"
        )
    }

    /// `--migrate-all` takes everything, `--collection-names` picks by name, otherwise the user chooses.
    func selectCollections(from availableCollections: [String], in databaseName: String) -> [String] {
        if migrateAll {
            return availableCollections
        }

        let requestedNames = parseNameList(collectionNames)

        if !requestedNames.isEmpty {
            let unmatchedNames = requestedNames.filter { !availableCollections.contains($0) }
            if !unmatchedNames.isEmpty {
                Noora().warning("Not found in \(databaseName): \(unmatchedNames.joined(separator: ", "))")
            }
            let matchedNames = availableCollections.filter { requestedNames.contains($0) }
            if !matchedNames.isEmpty {
                return matchedNames
            }
        }

        return Noora().multipleChoicePrompt(
            title: "Collections",
            question: "Select the collections to migrate",
            options: availableCollections,
            description: "Found \(availableCollections.count) collection(s) in \(databaseName). Press / to filter.",
            collapseOnSelection: true,
            filterMode: .toggleable,
            minLimit: .limited(count: 1, errorMessage: "Please select at least 1 collection"),
            renderer: WrapAwareRenderer()
        )
    }

    /// Copying a collection onto itself (or onto another collection that's also being read) would let
    /// `clear-before-import` wipe a source before it's read, so that's refused up front.
    func rejectSelfCopies(in plan: [MigrationItem], from source: Endpoint, to target: Endpoint) throws {
        guard source.connection.uri == target.connection.uri, source.databaseName == target.databaseName else {
            return
        }

        let sourceNames = Set(plan.map(\.sourceName))
        let overlapping = plan.map(\.collectionName).filter { sourceNames.contains($0) }
        guard overlapping.isEmpty else {
            throw CLIError.migrationOverlap(collections: overlapping)
        }
    }

    private func copyCollections(
        _ plan: [MigrationItem],
        from source: Endpoint,
        to target: Endpoint,
        replacingDuplicates: Bool
    ) async throws {
        var takeaways: [TerminalText] = []
        var totalWritten = 0

        for item in plan {
            let sourceCollection = source.database[item.sourceName]
            let targetCollection = target.database[item.collectionName]
            let documentCount = try await sourceCollection.count()
            let message = "Migrating \(item.displayName) → \(item.collectionName)"

            let result = try await Noora().progressStep(
                message: message,
                successMessage: nil,
                errorMessage: "Failed to migrate \(item.displayName)",
                showSpinner: true,
                renderer: WrapAwareRenderer()
            ) { updateMessage in
                try await writeDocuments(
                    sourceCollection.find(),
                    into: targetCollection,
                    replacingDuplicates: replacingDuplicates
                ) { count in
                    updateMessage("\(message) (\(count)/\(documentCount) documents)")
                }
            }

            totalWritten += result.written
            takeaways.append("\(item.displayName) → \(item.collectionName): \(result.summary)")
        }

        Noora().success(.alert(
            "Migrated \(totalWritten) documents from \(source.label) to \(target.label)",
            takeaways: takeaways
        ))
    }
}

/// One side of a migration: a saved connection, and a database on it.
struct Endpoint {
    enum Side {
        case source
        case target

        var title: String {
            switch self {
            case .source: "Source"
            case .target: "Target"
            }
        }

        var verb: String {
            switch self {
            case .source: "copy from"
            case .target: "copy into"
            }
        }

        /// The command-line flag for this side's connection, used in "missing argument" errors.
        var connectionFlag: String {
            switch self {
            case .source: "from"
            case .target: "to"
            }
        }
    }

    let connection: MongoConnectionRecord
    let databaseName: String
    let database: MongoDatabase

    var label: String {
        "\(connection.name) / \(databaseName)"
    }
}

/// One source collection, and the collection it will be copied into on the target.
struct MigrationItem: CollectionMapping {
    let sourceName: String
    var collectionName: String

    var displayName: String {
        sourceName
    }

    init(sourceName: String) {
        self.sourceName = sourceName
        self.collectionName = sourceName
    }
}
