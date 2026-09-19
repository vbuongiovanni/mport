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
    
    @Flag(help: "Import all collections from the directory")
    var importAll: Bool = false
    
    @Option(name: .shortAndLong, help: "Comma separated list of collections to import")
    var collectionNames: [String] = []
    
    @Option(name: .long, help: "Collision Resolution Strategy")
    var collisionResolution: String?
    
    func run() async throws {
        
        var connectionURI: String = ""
        var validatedConnectionName: String = ""
        var importDir: String
        var selectedDatabase = ""
        var collectionsToImport: [String] = []
        var collisionStrategy: CollisionResolution = .skip
        
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
        var availableFiles: [(url: URL, db: String, connection: String)] = []
        
        if let files = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
        ) {
            for file in files.allObjects.compactMap({$0 as? URL}) where file.pathExtension == "bson" {
                let db = url.deletingLastPathComponent().lastPathComponent
                let connection = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                availableFiles.append((url, db, connection))
            }
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
        
        // Determine if Collisions are possible
        let db = client.pool[selectedDatabase]
        let availableCollections = try await db.listCollections()
        var requestedCollections: [String] = []
        
        for collectionName in collectionNames {
            requestedCollections += collectionName.split(separator: ",").map{$0.trimmingCharacters(in: .whitespacesAndNewlines)}
        }
        
        if requestedCollections.isEmpty {
            let collections = Noora().multipleChoicePrompt(
                title: "Collections",
                question: "Select collections",
                options: availableCollections.map(\.namespace.collectionName),
                description: "Select collections to import",
                collapseOnSelection: true,
                minLimit: .limited(count: 1, errorMessage: "Please select at least 1 collection"))
            requestedCollections = collections
        }
        
        print(requestedCollections)
        // check for potential collisions
        let potentialCollisions = availableCollections
            .filter { requestedCollections.contains($0.namespace.collectionName)}
        let collisionNames = potentialCollisions.map({$0.namespace.collectionName})
        let hasPotentialCollisions = potentialCollisions.count > 0
        
        if hasPotentialCollisions {
            if let strategy = CollisionResolution(rawValue: collisionResolution ?? "") {
                collisionStrategy = strategy
            } else {
                
                let availableStrategies = CollisionResolution.allCases.map(\.rawValue)
                let selectedStrategy = Noora().singleChoicePrompt(
                    title: "Collision Strategy",
                    question: "Select a Strategy",
                    options: availableStrategies,
                    description: "Select a strategy",
                    collapseOnSelection: true,
                    autoselectSingleChoice: true
                )
                
                if let strategy = CollisionResolution(rawValue: selectedStrategy) {
                    collisionStrategy = strategy
                }
            }
        }
        
        
        var collectionMessage = ""
        var collisionMessage = ""
        for collectionName in requestedCollections {
            let collisionMessage = collisionNames.count(where: {collectionName.contains($0)}) > 0 ? "*" : ""
            collectionMessage += " └──> \(collectionName)\(collisionMessage)\n"
        }
        if (hasPotentialCollisions) {
            collisionMessage += "\n\(collisionStrategyExplanation(collisionStrategy))\n"
        }
        
        Noora().info("""
        ───────────────────────────────
        ────── Preflight Plan ─────────
        ───────────────────────────────
        Connection: \(validatedConnectionName)
        Database: \(selectedDatabase)
        Collections To Import:
        \(collectionMessage)
        \(collisionMessage)
        """
        )
        
        let executePlan = Noora().yesOrNoChoicePrompt(
            title: "Confirm",
            question: "Would you like to create one?",
            collapseOnSelection: true
        )

        if executePlan {
            print("Continuing...")
        }
    }
    
    private func collisionStrategyExplanation(_ strategy: CollisionResolution) -> String {
        switch strategy {
        case .dumpBeforeImport: "Collections marked with an asterisk will be dumped before the import."
        case .clearBeforeImport: "Collections marked with an asterisk will be cleared before the import."
        case .overwrite: "In collections marked with an asterisk, documents with a matching _id will be overwritten."
        case .skip: "In collections marked with an asterisk, documents with a matching _id will be skipped."
        }
    }
}
