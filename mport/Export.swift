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
        
    func run() async throws {
        
        var connectionURI: String = ""
        var validatedConnectionName: String = ""
        var exportDir: String
        var exportFormat = OutputFormat.pending
        var selectedDatabase = ""
        
        let config = try CLIConfig.read()
        
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
        
        guard let connection = try? selectConnection(config: config, connectionName: connectionName) else {
            throw CLIError.missingArgument(argument: "connectionName")
        }
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
        let availableCollections = try await db.listCollections()
        
        if exportAll {
            for collection in availableCollections {
                try await exportCollection(savePath: exportDir, collection: collection, format: exportFormat)
            }
        } else {
            let availableCollectionNames = availableCollections.map {$0.namespace.collectionName}
            
            let selectedCollections = Noora().multipleChoicePrompt(
                title: "Collection(s)",
                question: "Select one more more collection",
                options: availableCollectionNames,
                description: "Select an output format",
                collapseOnSelection: true,
                minLimit: .limited(count: 1, errorMessage: "Please select at least 1 collection"),
                
            )
            
            let targetCollections = availableCollections.filter {selectedCollections.contains($0.namespace.collectionName) }
            
            for collection in targetCollections {
                try await exportCollection(savePath: exportDir, collection: collection, format: exportFormat)
            }
        }
    }
    
    private func getPath(from collectionName: String, format: OutputFormat) throws -> String {
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
    
    private func exportCollection(savePath: String, collection: MongoCollection, format: OutputFormat) async throws {
        
        let directoryURL = URL(filePath: "\(savePath)")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        let url = try directoryURL.appending(component: getPath(from: collection.namespace.collectionName, format: format))
        
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
