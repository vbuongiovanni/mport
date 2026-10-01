//
//  MongoConnection.swift
//  Created by Vince B. on 9/15/26.
//  Made with love, not AI.
//  This file was generated in swift.
//  This code was written with my fingers and brain using a keyboard.
//

import Foundation

/// A saved connection as it appears in ~/.mport-config.json: just its name. The URI, which carries credentials,
/// lives in the Keychain (see `SecretStore`).
struct MongoConnectionRecord: Codable {
    let name: String
    /// Only set in configs written before URIs moved to the Keychain. `CLIConfig.read()` moves it there and
    /// rewrites the file without it, so it's never written back.
    var legacyURI: String?

    enum CodingKeys: String, CodingKey {
        case name
        case legacyURI = "uri"
    }

    init(name: String, legacyURI: String? = nil) {
        self.name = name
        self.legacyURI = legacyURI
    }
}

/// A saved connection with its URI, read from the Keychain: what the commands connect with.
struct SavedConnection: Sendable {
    let name: String
    let uri: String
}
