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

func selectConnection(
    config: CLIConfig,
    connectionName: String? = nil,
    title: String = "Connection",
    description: String = "Select a connection to import into",
    store: SecretStore = KeychainStore.standard
) throws -> SavedConnection {
    if connectionName != nil {
        if let selectedConnection = config.connections.first(where: { $0.name == connectionName }) {
            return try savedConnection(selectedConnection, from: store)
        }
    }

    let connectionAlias = Noora().singleChoicePrompt(
        title: TerminalText(stringLiteral: title),
        question: "Select a connection",
        options: config.connections.map(\.name),
        description: TerminalText(stringLiteral: description),
        collapseOnSelection: true,
        autoselectSingleChoice: true
    )

    if let connection = config.connections.first(where: { $0.name == connectionAlias }) {
        return try savedConnection(connection, from: store)
    }

    throw CLIError.missingArgument(argument: "connectionName")
}

/// The connection with its URI read from the Keychain. A name in the config with no URI behind it (the Keychain
/// entry was deleted, say) is an error that says how to fix it, rather than an empty URI.
func savedConnection(_ record: MongoConnectionRecord, from store: SecretStore) throws -> SavedConnection {
    guard let uri = try store.uri(forConnection: record.name) else {
        throw ConnectionError.missingURI(name: record.name)
    }
    return SavedConnection(name: record.name, uri: uri)
}

/// Problems with saved connections, printed as sentences that say what to do.
enum ConnectionError: Error, CustomStringConvertible {
    case missingURI(name: String)
    case notFound(name: String)
    case emptyURI

    var description: String {
        switch self {
        case let .missingURI(name):
            "There's no URI saved in your Keychain for '\(name)'. "
                + "Save it again with `mport register-connection \(name) --overwrite`."
        case let .notFound(name):
            "There's no saved connection called '\(name)'."
        case .emptyURI:
            "No URI was entered, so nothing was saved."
        }
    }
}

func selectDatabase(
    using client: MongoDatabase,
    dbName: String? = nil,
    title: String = "Database",
    description: String = "Select a database"
) async throws -> String {
    var availableDBs: [String]
    var selectedDatabase: String = dbName ?? ""
    
    do {
        availableDBs = try await client.pool.listDatabases().map { $0.name }
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
            title: TerminalText(stringLiteral: title),
            question: "Select a database",
            options: availableDBs,
            description: TerminalText(stringLiteral: description),
            collapseOnSelection: true,
            autoselectSingleChoice: true
        )
    }
    
    return selectedDatabase
}
