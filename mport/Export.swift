//
//  Export.swift
//  Created by Vince B. on 9/15/26.
//  Made with love, not AI. 
//  This file was generated in swift.
//  This code was written with my fingers and brain using a keyboard.
//

import Foundation
import ArgumentParser
import MongoKitten
import Noora

struct Export: AsyncParsableCommand {
    
    @Argument(help: "Directory to export to")
    var exportPath: String = ""
    
    @Argument(help: "Aliased name of MongoDB connection")
    var connectionName: String?
    
    @Argument(help: "Name of Database")
    var dbName: String?
    
    @Option(help: "Format of exported files")
    var format: String = ""
    
    @Flag(name: .shortAndLong, help: "Export all collections from database")
    var exportAll: Bool = false

    @OptionGroup var concurrencyOptions: ConcurrencyOptions

    func run() async throws {
        
        var connectionURI: String = ""
        var validatedConnectionName: String = ""
        var exportDir: String
        var exportFormat = OutputFormat.pending
        var selectedDatabase = ""
        
        let config = try CLIConfig.read()
        let limit = Concurrency.resolve(flag: concurrencyOptions.concurrency, saved: config.defaultConcurrency) {
            Noora().warning(.alert(TerminalText(stringLiteral: $0)))
        }

        // Getting default path, if not proivided
        if exportPath.isEmpty {
            exportDir = config.defaultExportPath ?? ""
            guard !exportDir.isEmpty else {
                throw CLIError.missingConfig
            }
        } else {
            exportDir = exportPath
        }
                
        guard config.connections.isEmpty == false else {
            throw CLIError.emptyConfig
        }
        
        // Getting default format, if not proivided
        if format.isEmpty && config.defaultFormat != nil {
            if let defaultFormat = config.defaultFormat {
                exportFormat = defaultFormat
            }
        } else if !format.isEmpty {
            if let selectedFormat = OutputFormat(rawValue: format.lowercased()) {
                exportFormat = selectedFormat
            }
        }
        
        if exportFormat == OutputFormat.pending {
            let availableFormats = OutputFormat.allCases.map(\.rawValue).filter {$0 != ""}
            let selectedOutputFormat = Noora().singleChoicePrompt(
                title: "Output Format",
                question: "Select an output format",
                options: availableFormats,
                description: "Select an output format",
                collapseOnSelection: true,
                autoselectSingleChoice: true
            )
            
            if let selectedFormat = OutputFormat(rawValue: selectedOutputFormat) {
                exportFormat = selectedFormat
            } else {
                throw CLIError.outputSteamFailure
            }
        }
        
        // Select Connection
        
        let connection = try selectConnection(config: config, connectionName: connectionName)
        connectionURI = connection.uri
        validatedConnectionName = connection.name
        
        print("Connecting to \(validatedConnectionName)...")
        
        // Selecting DB
        var client: MongoDatabase
        
        do {
            client = try await MongoDatabase.connect(to: connectionURI)
        } catch {
            throw CLIError.connectionFailed
        }
        
        guard let selectedDatabase = try? await selectDatabase(using: client, dbName: dbName) else {
            throw CLIError.missingArgument(argument: "dbName")
        }
        
        exportDir = "\(exportDir)/\(validatedConnectionName)/\(selectedDatabase)"

        // Selecting Collection(s)
        let db = client.pool[selectedDatabase]
        let availableNames = try await db.listCollections().map(\.name)
        let selectedNames = try selectCollections(from: availableNames, in: selectedDatabase)

        let directory = URL(filePath: exportDir)
        try Self.refuseCaseClashes(in: selectedNames, exportingTo: directory)

        let slots = try await ClientSlots.open(
            count: min(limit, selectedNames.count), reusing: client, uri: connectionURI
        )
        do {
            try await Self.export(
                selectedNames, from: (slots: slots, database: selectedDatabase), to: directory, format: exportFormat
            )
        } catch {
            await slots.disconnect()
            throw error
        }
        await slots.disconnect()
    }

    /// Drops `system.*` collections, as `migrate` does, then `--export-all` takes the rest and otherwise the user
    /// picks. Throws when there's nothing left to export, rather than showing an empty picker.
    func selectCollections(from availableNames: [String], in databaseName: String) throws -> [String] {
        let exportableNames = availableNames.filter { !$0.hasPrefix("system.") }
        guard !exportableNames.isEmpty else {
            throw CLIError.noCollections(database: databaseName)
        }
        if exportAll {
            return exportableNames
        }

        let selectedNames = Noora().multipleChoicePrompt(
            title: "Collection(s)",
            question: "Select one more more collection",
            options: exportableNames,
            description: "Select an output format",
            collapseOnSelection: true,
            minLimit: .limited(count: 1, errorMessage: "Please select at least 1 collection"),
        )
        return exportableNames.filter { selectedNames.contains($0) }
    }

    /// On a disk that doesn't tell upper and lower case apart, `Users` and `users` would export to the same file, so
    /// that's refused before any connection is opened or anything is written.
    static func refuseCaseClashes(in collectionNames: [String], exportingTo directory: URL) throws {
        let clashes = caseClashes(in: collectionNames)
        if !clashes.isEmpty && !isCaseSensitiveVolume(at: directory) {
            throw ExportNameClashError(groups: clashes)
        }
    }

    /// Exports every collection into `directory`, one per slot at a time, each through its slot's own client.
    /// It doesn't prompt, so tests can run it directly.
    static func export(
        _ collectionNames: [String],
        from source: (slots: ClientSlots, database: String),
        to directory: URL,
        format: OutputFormat
    ) async throws {
        let lanes = makeLanes(destinationKeys: collectionNames)
        let outcomes = await runConcurrently(
            items: collectionNames, lanes: lanes, limit: source.slots.count
        ) { _, name, slot in
            try await exportCollection(
                savePath: directory.path,
                collection: source.slots.database(named: source.database, slot: slot)[name],
                format: format
            )
        }
        _ = try completedOutputs(of: outcomes, labels: collectionNames) { _ in "exported" }
    }

    private static func getPath(from collectionName: String, format: OutputFormat) throws -> String {
        switch format {
        case .json:
            return collectionName.appending(".json")
        case .bson:
            return collectionName.appending(".bson")
        case .mongoShellSyntax:
            return collectionName.appending(".json")
        default:
            throw CLIError.invalidExportFormat
        }
    }
    
    static func exportCollection(savePath: String, collection: MongoCollection, format: OutputFormat) async throws {
        
        let directoryURL = URL(filePath: "\(savePath)")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        let fileName = try getPath(from: collection.namespace.collectionName, format: format)
        let url = directoryURL.appending(component: fileName)
        
        guard let coordinator = OutputStream(url: url, append: false) else {
            throw CLIError.outputSteamFailure
        }
        
        coordinator.open()
        defer { coordinator.close() }
        
        let documents = collection.find()
        
        if format == OutputFormat.bson {
            for try await document in documents {
                let buffer = document.makeByteBuffer()
                if let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes) {
                    _ = bytes.withUnsafeBytes { rawBuffer in
                        coordinator.write(rawBuffer.bindMemory(to: UInt8.self).baseAddress!, maxLength: rawBuffer.count)
                        
                    }
                }
            }
        } else if format == OutputFormat.json {
            coordinator.writeString("[\n")
            var isFirst = true
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            
            for try await document in documents {
                if !isFirst { coordinator.writeString(",\n") }
                
                let jsonData = try encoder.encode(document)
                if let jsonString = String(data: jsonData, encoding: .utf8) {
                    coordinator.writeString(jsonString)

                }
                isFirst = false
            }
            coordinator.writeString("\n]")
        } else if format == OutputFormat.mongoShellSyntax {
            for try await document in documents {
                coordinator.writeString(document.shellJSON(indent: 0) + "\n")
            }
        } else {
            print("Invalid format: \(format.rawValue)")
            throw CLIError.invalidExportFormat
        }
        print("exported '\(collection.namespace.collectionName)'")
    }
    
}
