//
//  RemoveConnection.swift
//  Created by Claude on 9/29/26, at Vince's request.
//

import ArgumentParser
import Foundation

struct RemoveConnection: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove a saved connection, and its URI from your Keychain"
    )

    @Argument(help: "Name of the saved connection")
    var name: String

    func run() throws {
        var config = try CLIConfig.read()
        try Self.remove(name: name, from: &config, store: KeychainStore.standard)
        try CLIConfig.write(newConfig: config)

        print("Removed '\(name)'.")
    }

    /// Takes the connection out of `config` and its URI out of `store`. The URI goes first, so the config never
    /// loses a name whose URI is still sitting in the Keychain.
    static func remove(name: String, from config: inout CLIConfig, store: SecretStore) throws {
        guard config.connections.contains(where: { $0.name == name }) else {
            throw ConnectionError.notFound(name: name)
        }
        try store.removeURI(forConnection: name)
        config.connections.removeAll { $0.name == name }
    }
}
