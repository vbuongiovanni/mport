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

    @OptionGroup var concurrencyOptions: ConcurrencyOptions

    func run() async throws {
        let config = try CLIConfig.read()
        guard !config.connections.isEmpty else {
            throw CLIError.emptyConfig
        }
        let limit = Concurrency.resolve(flag: concurrencyOptions.concurrency, saved: config.defaultConcurrency) {
            Noora().warning(.alert(TerminalText(stringLiteral: $0)))
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

        try await copyCollections(plan, from: source, to: target, collisions: collisions, limit: limit)
    }

    // MARK: - Steps

    /// Picks a connection, connects to it, and picks a database on it: one side of the migration.
    private func selectEndpoint(
        _ side: Endpoint.Side,
        config: CLIConfig,
        connectionName: String?,
        dbName: String?
    ) async throws -> Endpoint {
        let connection = try selectConnection(
            config: config,
            connectionName: connectionName,
            title: "\(side.title) Connection",
            description: "Select the connection to \(side.verb)"
        )

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

    /// Everything after the plan is confirmed: open a client per slot on both sides (so a refused connection fails
    /// before anything changes), prepare the collisions, copy, and print the summary in plan order.
    private func copyCollections(
        _ plan: [MigrationItem],
        from source: Endpoint,
        to target: Endpoint,
        collisions: CollisionPlan,
        limit: Int
    ) async throws {
        let slotCount = min(limit, makeLanes(destinationKeys: plan.map(\.collectionName)).count)
        let sourceSlots = try await ClientSlots.open(
            count: slotCount, reusing: source.database, uri: source.connection.uri
        )
        let targetSlots: ClientSlots
        do {
            targetSlots = try await ClientSlots.open(
                count: slotCount, reusing: target.database, uri: target.connection.uri
            )
        } catch {
            await sourceSlots.disconnect()
            throw error
        }

        let outcomes: [ItemOutcome<WriteResult>]
        do {
            try await collisions.prepare(in: (slots: targetSlots, database: target.databaseName))
            outcomes = await Self.copyItems(
                plan,
                from: (slots: sourceSlots, database: source.databaseName),
                to: (slots: targetSlots, database: target.databaseName),
                replacingDuplicates: collisions.replacesDuplicates,
                board: ProgressBoard(total: plan.count)
            )
        } catch {
            await sourceSlots.disconnect()
            await targetSlots.disconnect()
            throw error
        }
        await sourceSlots.disconnect()
        await targetSlots.disconnect()

        let labels = plan.map { "\($0.displayName) → \($0.collectionName)" }
        let results = try completedOutputs(of: outcomes, labels: labels, summary: \.summary)
        let takeaways = zip(labels, results).map { label, result in
            TerminalText(stringLiteral: "\(label): \(result.summary)")
        }
        let totalWritten = results.reduce(0) { $0 + $1.written }
        Noora().success(.alert(
            "Migrated \(totalWritten) documents from \(source.label) to \(target.label)",
            takeaways: takeaways
        ))
    }

    /// Copies every item, one per slot at a time. Each slot reads through its own source client and writes through
    /// its own target client, and progress goes to `board`. Sources going into the same collection run one after
    /// another, in plan order. It doesn't prompt, so tests can run it directly.
    static func copyItems(
        _ plan: [MigrationItem],
        from source: (slots: ClientSlots, database: String),
        to target: (slots: ClientSlots, database: String),
        replacingDuplicates: Bool,
        board: ProgressBoard
    ) async -> [ItemOutcome<WriteResult>] {
        let lanes = makeLanes(destinationKeys: plan.map(\.collectionName))
        let limit = min(source.slots.count, target.slots.count)
        let outcomes = await runConcurrently(items: plan, lanes: lanes, limit: limit) { index, item, slot in
            let label = "\(item.displayName) → \(item.collectionName)"
            let sourceCollection = source.slots.database(named: source.database, slot: slot)[item.sourceName]
            let targetCollection = target.slots.database(named: target.database, slot: slot)[item.collectionName]
            do {
                let documentCount = try await sourceCollection.count()
                await board.start(index: index, label: "Migrating \(label)", total: documentCount)
                let result = try await writeDocuments(
                    sourceCollection.find(),
                    into: targetCollection,
                    replacingDuplicates: replacingDuplicates
                ) { count in
                    await board.update(index: index, count: count)
                }
                await board.finish(index: index, line: "✔︎ \(label): \(result.summary)")
                return result
            } catch {
                await board.finish(index: index, line: "✖ \(label): \(error)")
                throw error
            }
        }
        await board.close()
        return outcomes
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

    let connection: SavedConnection
    let databaseName: String
    let database: MongoDatabase

    var label: String {
        "\(connection.name) / \(databaseName)"
    }
}

/// One source collection, and the collection it will be copied into on the target.
struct MigrationItem: CollectionMapping, Sendable {
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
