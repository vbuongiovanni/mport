//
//  Import.swift
//  Created by Vince B. on 9/17/26.
//  Made with love, not AI.
//  This file was generated in swift.
//  This code was written with my fingers and brain using a keyboard.
//

import Foundation
import ArgumentParser
import MongoKitten
import Noora

struct Import: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        .init(commandName: "import",
              abstract: "Import a Collection into a Mongo DB",
              discussion: "Import a file into a project")
    }

    @Argument(help: "Directory containing BSON files to import")
    var directory = ""

    @Argument(help: "Alias name of connection to use")
    var connectionName: String?

    @Option(name: .shortAndLong, help: "Name of Database to import to")
    var dbName: String?

    @Flag(help: "Import every BSON file found in the directory")
    var importAll: Bool = false

    @Option(name: .shortAndLong, help: "Comma separated list of BSON files to import, without the .bson extension")
    var collectionNames: [String] = []

    @Option(name: .long, help: "Collision Resolution Strategy")
    var collisionResolution: String?

    @Flag(name: .long, help: "Don't back up colliding collections: dump-before-import clears them without a backup")
    var skipBackup: Bool = false

    @OptionGroup var concurrencyOptions: ConcurrencyOptions

    func run() async throws {

        var connectionURI: String = ""
        var validatedConnectionName: String = ""
        var importDir: String

        let config = try CLIConfig.read()
        let limit = Concurrency.resolve(flag: concurrencyOptions.concurrency, saved: config.defaultConcurrency) {
            Noora().warning(.alert(TerminalText(stringLiteral: $0)))
        }

        if directory.isEmpty {
            importDir = config.defaultExportPath ?? ""
            guard !importDir.isEmpty else {
                throw CLIError.missingArgument(argument: "directory")
            }
        } else {
            importDir = directory
        }

        let url = URL(filePath: importDir)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.directoryDoesNotExist
        }

        let availableFiles = findBSONFiles(in: url)
        guard !availableFiles.isEmpty else {
            throw CLIError.noBSONFiles(directory: importDir)
        }

        // Select Connection

        let connection = try selectConnection(config: config, connectionName: connectionName)
        connectionURI = connection.uri
        validatedConnectionName = connection.name

        print("Connecting to \(validatedConnectionName)...")

        // Select DB
        var client: MongoDatabase

        do {
            client = try await MongoDatabase.connect(to: connectionURI)
        } catch {
            throw CLIError.connectionFailed
        }

        guard let selectedDatabase = try? await selectDatabase(using: client, dbName: dbName) else {
            throw CLIError.missingArgument(argument: "dbName")
        }

        // Select files, then decide which collection each one lands in
        let plan = nameCollections(
            for: selectFiles(from: availableFiles),
            defaultNaming: "By default each file goes into a collection named after it, minus .bson"
        )

        // Determine if Collisions are possible
        let db = client.pool[selectedDatabase]
        let resolvedCollisions = try await CollisionPlan.resolve(
            for: plan.map(\.collectionName),
            in: db,
            flagValue: collisionResolution,
            backupDirectory: backupDirectory(
                under: url,
                connection: validatedConnectionName,
                database: selectedDatabase
            )
        )
        let collisions = skipBackup ? resolvedCollisions.skippingBackup() : resolvedCollisions

        var details = ["Connection: \(validatedConnectionName)", "Database: \(selectedDatabase)"]
        if skipBackup && resolvedCollisions.strategy == .dumpBeforeImport {
            details.append("Backups: skipped (--skip-backup)")
        }
        if collisions.strategy == .dumpBeforeImport {
            details.append("Unchanged: a collection whose backup is identical to its file is left as it is")
        }

        let executePlan = confirmPlan(
            details: details,
            heading: "Collections To Import:",
            items: plan,
            collisions: collisions,
            action: "import"
        )

        guard executePlan else {
            print("Import cancelled, nothing was changed.")
            return
        }

        try await execute(
            plan,
            collisions: collisions,
            limit: limit,
            connection: (client, connectionURI),
            databaseName: selectedDatabase
        )
    }

    /// Everything after the plan is confirmed: open a client per slot (so a refused connection fails before
    /// anything changes), prepare the collisions, import, and print the summary in plan order.
    private func execute(
        _ plan: [ImportItem],
        collisions: CollisionPlan,
        limit: Int,
        connection: (client: MongoDatabase, uri: String),
        databaseName: String
    ) async throws {
        let laneCount = makeLanes(destinationKeys: plan.map(\.collectionName)).count
        let slots = try await ClientSlots.open(
            count: min(limit, laneCount), reusing: connection.client, uri: connection.uri
        )

        let split: (toImport: [ImportItem], unchanged: [ImportItem])
        let outcomes: [ItemOutcome<WriteResult>]
        do {
            split = try await Self.prepare(plan, collisions: collisions, in: (slots: slots, database: databaseName))
            outcomes = await Self.importItems(
                split.toImport,
                into: (slots: slots, database: databaseName),
                replacingDuplicates: collisions.replacesDuplicates,
                board: ProgressBoard(total: split.toImport.count)
            )
        } catch {
            await slots.disconnect()
            throw error
        }
        await slots.disconnect()

        let label = { (item: ImportItem) in "\(item.displayName) → \(item.collectionName)" }
        let results = try completedOutputs(of: outcomes, labels: split.toImport.map(label), summary: \.summary)
        var summaries: [URL: String] = [:]
        for (item, result) in zip(split.toImport, results) {
            summaries[item.file] = result.summary
        }
        for item in split.unchanged {
            summaries[item.file] = "unchanged, skipped"
        }
        let takeaways = plan.map { TerminalText(stringLiteral: "\(label($0)): \(summaries[$0.file] ?? "")") }
        let totalWritten = results.reduce(0) { $0 + $1.written }
        Noora().success(.alert("Imported \(totalWritten) documents into \(databaseName)", takeaways: takeaways))
    }

    /// Runs the collision preparation, then splits the plan: files to import, and files left out because their
    /// target collection's `dump-before-import` backup came out identical to them (the collection already holds
    /// exactly that file, so it was left as it is). Only a collection with a single file going into it is compared.
    static func prepare(
        _ plan: [ImportItem],
        collisions: CollisionPlan,
        in target: (slots: ClientSlots, database: String)
    ) async throws -> (toImport: [ImportItem], unchanged: [ImportItem]) {
        let singleSourceFiles = Dictionary(grouping: plan, by: \.collectionName)
            .compactMapValues { items in items.count == 1 ? items[0].file : nil }
        let unchangedNames = try await collisions.prepare(in: target, skippingIfIdenticalTo: singleSourceFiles)
        return (
            toImport: plan.filter { !unchangedNames.contains($0.collectionName) },
            unchanged: plan.filter { unchangedNames.contains($0.collectionName) }
        )
    }

    /// Imports every item into `target.database`, one per slot at a time, each through its slot's own client, and
    /// reports progress on `board`. Files going into the same collection run one after another, in plan order.
    /// It doesn't prompt, so tests can run it directly.
    static func importItems(
        _ plan: [ImportItem],
        into target: (slots: ClientSlots, database: String),
        replacingDuplicates: Bool,
        board: ProgressBoard
    ) async -> [ItemOutcome<WriteResult>] {
        let lanes = makeLanes(destinationKeys: plan.map(\.collectionName))
        let outcomes = await runConcurrently(
            items: plan, lanes: lanes, limit: target.slots.count
        ) { index, item, slot in
            let label = "\(item.displayName) → \(item.collectionName)"
            await board.start(index: index, label: "Importing \(label)")
            do {
                let result = try await writeDocuments(
                    try BSONFileReader(url: item.file),
                    into: target.slots.database(named: target.database, slot: slot)[item.collectionName],
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

    // MARK: - Choosing files

    /// Every `.bson` file under `directory`, including subfolders (e.g. the `<connection>/<db>/` layout that
    /// `export` writes). Hidden folders are skipped, which keeps `.mport-backups` out of the list.
    func findBSONFiles(in directory: URL) -> [ImportItem] {
        // .producesRelativePathURLs makes each URL's `relativePath` the path below `directory`
        // (e.g. "local/shop/users.bson"), while the URL itself still points at the real file.
        guard let files = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .producesRelativePathURLs]
        ) else {
            return []
        }

        return files.allObjects
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "bson" }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { ImportItem(file: $0, displayName: $0.relativePath) }
            .sorted { $0.displayName < $1.displayName }
    }

    /// `--import-all` takes everything, `--collection-names` picks by file name, otherwise the user chooses.
    func selectFiles(from availableFiles: [ImportItem]) -> [ImportItem] {
        if importAll {
            return availableFiles
        }

        let requestedNames = parseNameList(collectionNames)

        if !requestedNames.isEmpty {
            let matchedFiles = availableFiles.filter { requestedNames.contains($0.defaultCollectionName) }
            let unmatchedNames = requestedNames.filter { name in
                !availableFiles.contains { $0.defaultCollectionName == name }
            }
            if !unmatchedNames.isEmpty {
                Noora().warning("No BSON file found for: \(unmatchedNames.joined(separator: ", "))")
            }
            if !matchedFiles.isEmpty {
                return matchedFiles
            }
        }

        let selectedNames = Noora().multipleChoicePrompt(
            title: "Files",
            question: "Select the BSON files to import",
            options: availableFiles.map(\.displayName),
            description: "Found \(availableFiles.count) BSON file(s). Press / to filter.",
            collapseOnSelection: true,
            filterMode: .toggleable,
            minLimit: .limited(count: 1, errorMessage: "Please select at least 1 file"),
            renderer: WrapAwareRenderer()
        )
        return availableFiles.filter { selectedNames.contains($0.displayName) }
    }
}

/// One BSON file on disk, and the collection it will be imported into.
struct ImportItem: CollectionMapping, Sendable {
    let file: URL
    /// Path relative to the import directory (e.g. `local/shop/users.bson`), so files with the same
    /// name in different folders can still be told apart in the prompts.
    let displayName: String
    var collectionName: String

    var defaultCollectionName: String {
        file.deletingPathExtension().lastPathComponent
    }

    init(file: URL, displayName: String) {
        self.file = file
        self.displayName = displayName
        self.collectionName = file.deletingPathExtension().lastPathComponent
    }
}
