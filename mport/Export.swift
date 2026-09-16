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

struct Export: AsyncParsableCommand {
    
    @Argument(help: "Directory to export to")
    var exportPath: String = ""
    
    @Argument(help: "Aliased name of MongoDB connection")
    var connectionName: String?
    
    @Argument(help: "Name of Database")
    var dbName: String?
    
    @Argument(help: "Format of exported files")
    var format: String = ""
    
    @Flag(name: .shortAndLong, help: "Export all collections from database")
    var exportAll: Bool = false
        
    func run() async throws {
        
        var connectionURI: String = ""
        var validatedConnectionName: String = ""
        var exportDir: String
        var exportFormat = OutputFormat.pending
        var selectedDatabase = ""
        var collectionToExport: String
        
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
            let selectedOutputFormat = try promptUserFromList(options: availableFormats, message: "Select an output format", instructionPrefix: validatedConnectionName)
            
            if let selectedFormat = OutputFormat(rawValue: availableFormats[selectedOutputFormat]) {
                exportFormat = selectedFormat
            } else {
                throw CLIError.outputSteamFailure
            }
        }
        
        // Selecting Connection
        
        if connectionName != nil {
            if let selectedConnection = config.connections.first(where: {$0.name == connectionName}) {
                connectionURI = selectedConnection.uri
                validatedConnectionName = selectedConnection.name
            }
        }
        
        if connectionURI.isEmpty || connectionURI.isEmpty {
            if config.connections.count == 1 {
                connectionURI = config.connections[0].uri
                validatedConnectionName = config.connections[0].name
            } else {
                let selectedConnectionIndex = try promptUserFromList(options: config.connections.map(\.name), message: "Select a connection")
                connectionURI = config.connections[selectedConnectionIndex].uri
                validatedConnectionName = config.connections[selectedConnectionIndex].name
            }
        }
        print("Connecting to \(validatedConnectionName)...")
        
        // Selecting DB
        var availableDBs: [String]
        var client: MongoDatabase
        
        do {
            client = try await MongoDatabase.connect(to: connectionURI)
            availableDBs = try await client.pool.listDatabases().map { $0.name }
        } catch {
            throw CLIError.connectionFailed
        }
        
        
        
        if dbName != nil {
            if let database = availableDBs.first(where: {$0 == dbName}) {
                selectedDatabase = database
            }
        }
        
        if selectedDatabase.isEmpty {
            let selectedDatabaseIndex = try promptUserFromList(options: availableDBs, message: "Select a Database", instructionPrefix: validatedConnectionName)
            selectedDatabase = availableDBs[selectedDatabaseIndex]
        }
        
        exportDir = "\(exportDir)/\(selectedDatabase)"
        
        // Selecting Collection(s)
        var availableCollections: [MongoCollection]
        
        let db = client.pool[selectedDatabase]
        availableCollections = try await db.listCollections()
        
        if exportAll {
            for collection in availableCollections {
                try await exportCollection(savePath: exportDir, collection: collection, format: exportFormat)
            }
        } else {
            let availableCollectionNames = availableCollections.map {$0.namespace.collectionName}
            let selectedCollectionIndex = try promptUserFromList(options: availableCollectionNames, message: "Select a Collection", instructionPrefix: validatedConnectionName)
            collectionToExport = availableCollectionNames[selectedCollectionIndex]
            if let collection = availableCollections.filter({$0.namespace.collectionName == collectionToExport}).first {
                try await exportCollection(savePath: exportDir, collection: collection, format: exportFormat)
            }
        }
    }
    
    private func exportCollection(savePath: String, collection: MongoCollection, format: OutputFormat) async throws {
        
        let directoryURL = URL(filePath: "\(savePath)")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        let url = directoryURL.appending(component: "\(collection.namespace.collectionName).json")
        
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
    
    
    private func promptUserFromList(options: [String], message: String, instructionPrefix: String? = nil) throws -> Int {
        print("\n----- \(message) -----\n")
        var index = 0
        let padding = 8
        for option in options {
            let indexLabel = "[\(index + 1)]:"
            let paddingCount = padding - indexLabel.count
            let paddingString = String(repeating: " ", count: paddingCount)
            print("\(indexLabel)\(paddingString)\(option)")
            index += 1
        }
        let selectedIndex = try promptUserForChoice(maxIndex: options.count, instructionPrefix: instructionPrefix)
        return selectedIndex
    }
    
    
    private func promptUserForChoice(maxIndex: Int, instructionPrefix: String? = nil) throws -> Int {
        var instructions = instructionPrefix.map { "\n[\($0)]:" } ?? "\n"
        instructions += "Enter number (1-\(maxIndex)) > "
        while true {
            print(instructions, terminator: "")
            fflush(stdout)
            guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), let choice = Int(input), choice >= 1 && choice <= maxIndex else {
                print("Invalid input, please try again\n")
                continue
            }
            return choice - 1
        }
    }
    
}
