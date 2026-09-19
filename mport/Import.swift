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

    func run() async throws {

        var connectionURI: String = ""
        var validatedConnectionName: String = ""
        var importDir: String

        let config = try CLIConfig.read()

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

        guard let connection = try? selectConnection(config: config, connectionName: connectionName) else {
            throw CLIError.missingArgument(argument: "connectionName")
        }
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
        let collisions = try await CollisionPlan.resolve(
            for: plan.map(\.collectionName),
            in: db,
            flagValue: collisionResolution,
            backupDirectory: backupDirectory(
                under: url,
                connection: validatedConnectionName,
                database: selectedDatabase
            )
        )

        let executePlan = confirmPlan(
            details: ["Connection: \(validatedConnectionName)", "Database: \(selectedDatabase)"],
            heading: "Collections To Import:",
            items: plan,
            collisions: collisions,
            action: "import"
        )

        guard executePlan else {
            print("Import cancelled, nothing was changed.")
            return
        }

        try await collisions.prepare(in: db)

        var takeaways: [TerminalText] = []
        var totalWritten = 0

        for item in plan {
            let result = try await Noora().progressStep(
                message: "Importing \(item.displayName) → \(item.collectionName)",
                successMessage: nil,
                errorMessage: "Failed to import \(item.displayName)",
                showSpinner: true,
                renderer: WrapAwareRenderer()
            ) { updateMessage in
                try await writeDocuments(
                    BSONFileReader(url: item.file),
                    into: db[item.collectionName],
                    replacingDuplicates: collisions.replacesDuplicates
                ) { count in
                    updateMessage("Importing \(item.displayName) → \(item.collectionName) (\(count) documents)")
                }
            }

            totalWritten += result.written
            takeaways.append("\(item.displayName) → \(item.collectionName): \(result.summary)")
        }

        Noora().success(.alert("Imported \(totalWritten) documents into \(selectedDatabase)", takeaways: takeaways))
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
struct ImportItem: CollectionMapping {
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
