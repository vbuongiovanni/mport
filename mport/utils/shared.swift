//
//  shared.swift
//  Created by Vince B. on 9/17/26.
//  Made with love, not AI. 
//  This file was generated in swift.
//  This code was written with my fingers and brain using a keyboard.
//

import Foundation
import MongoKitten
import Noora

func selectConnection(config: CLIConfig, connectionName: String? = nil) throws -> MongoConnectionRecord {
    if connectionName != nil {
        if let selectedConnection = config.connections.first(where: { $0.name == connectionName }) {
            return selectedConnection
        }
    }
    
    let connectionAlias = Noora().singleChoicePrompt(
        title: "Connection",
        question: "Select a connection",
        options: config.connections.map(\.name),
        description: "Select a connection to import into",
        collapseOnSelection: true,
        autoselectSingleChoice: true
    )
    
    if let connection = config.connections.first(where: { $0.name == connectionAlias }) {
        return connection
    }
    
    throw CLIError.missingArgument(argument: "connectionName")
}

func selectDatabase(using client: MongoDatabase, dbName: String? = nil) async throws -> String {
    var availableDBs: [String]
    var selectedDatabase: String = dbName ?? ""
    
    do {
        availableDBs = try await client.pool.listDatabases().map() { $0.name }
    } catch {
        throw CLIError.connectionFailed
    }
    
    if !selectedDatabase.isEmpty {
        if let database = availableDBs.first(where: {$0 == dbName}) {
            selectedDatabase = database
        } else {
            if let dbName = dbName {
                Noora().warning("Database '\(dbName)' not found.")
            }
            selectedDatabase = ""
        }
    }
    
    if selectedDatabase.isEmpty {
        selectedDatabase = Noora().singleChoicePrompt(
            title: "Database",
            question: "Select a database",
            options: availableDBs,
            description: "Select an output format",
            collapseOnSelection: true,
            autoselectSingleChoice: true
        )
    }
    
    return selectedDatabase
}
