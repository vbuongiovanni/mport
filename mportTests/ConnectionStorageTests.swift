//
//  ConnectionStorageTests.swift
//  Created by Claude on 9/29/26, at Vince's request.
//
//  Connection URIs live in the Keychain, and the config file holds only names. These tests use an in-memory store
//  and temporary files, except the last suite, which round-trips through the real Keychain under its own service.
//

import ArgumentParser
import Foundation
import Testing

@Suite("Connection storage")
struct ConnectionStorageTests {

    private let fileName = ".mport-config.json"

    private let olderConfig = """
    {
      "connections": [
        { "name": "local", "uri": "mongodb://root:hunter2@localhost:27017/admin" },
        { "name": "staging", "uri": "mongodb+srv://app:s3cret@staging.example.net/app" }
      ],
      "defaultExportPath": "/exports"
    }
    """

    // MARK: Moving URIs out of the config file

    /// Catches: credentials staying in a file people commit with their dotfiles.
    @Test("URIs in an older config are moved into the Keychain, and the file keeps only the names")
    func migratesURIsToStore() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appending(path: fileName)
            try Data(olderConfig.utf8).write(to: url)
            let store = InMemorySecretStore()

            let config = try CLIConfig.read(from: url, store: store)

            #expect(config.connections.map(\.name) == ["local", "staging"])
            #expect(store.all == [
                "local": "mongodb://root:hunter2@localhost:27017/admin",
                "staging": "mongodb+srv://app:s3cret@staging.example.net/app"
            ])
            let written = try String(contentsOf: url, encoding: .utf8)
            #expect(!written.contains("uri"))
            #expect(!written.contains("hunter2"))
            #expect(!written.contains("s3cret"))
            #expect(written.contains("/exports"))
            #expect(try CLIConfig.read(from: url, store: store).connections.map(\.name) == ["local", "staging"])
        }
    }

    /// Catches: the file being rewritten without its URIs before they were safely in the Keychain.
    @Test("If the Keychain can't take the URIs, the config file is left exactly as it was")
    func failedMigrationLosesNothing() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appending(path: fileName)
            try Data(olderConfig.utf8).write(to: url)

            #expect(throws: FailingSecretStore.Failure.self) {
                try CLIConfig.read(from: url, store: FailingSecretStore())
            }
            #expect(try String(contentsOf: url, encoding: .utf8) == olderConfig)
        }
    }

    /// Catches: `uri` being written back out, which would undo the move on the next save.
    @Test("A connection is written with only its name")
    func recordEncodesNameOnly() throws {
        let json = try String(decoding: JSONEncoder().encode(MongoConnectionRecord(name: "local")), as: UTF8.self)
        #expect(json == #"{"name":"local"}"#)
    }

    // MARK: Permissions

    /// Catches: the config being readable by other accounts on the Mac.
    @Test("A new config file is readable only by its owner")
    func newFileIsOwnerOnly() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appending(path: fileName)

            _ = try CLIConfig.read(from: url, store: InMemorySecretStore())

            #expect(try permissions(of: url) == 0o600)
        }
    }

    /// Catches: a config written by an older mport (mode 644) staying world-readable.
    @Test("An existing config with looser permissions is tightened when it's read, and stays tight when written")
    func existingFileIsTightened() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appending(path: fileName)
            try Data(#"{"connections": []}"#.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

            var config = try CLIConfig.read(from: url, store: InMemorySecretStore())
            #expect(try permissions(of: url) == 0o600)

            config.defaultExportPath = "/exports"
            try CLIConfig.write(config, to: url)
            #expect(try permissions(of: url) == 0o600)
        }
    }

    /// Catches: the backup of a broken config, which may hold an older file's URIs, being world-readable.
    @Test("The backup of an undecodable config is readable only by its owner")
    func brokenBackupIsOwnerOnly() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appending(path: fileName)
            try Data(#"{"connections": ["#.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

            _ = try CLIConfig.read(from: url, store: InMemorySecretStore())

            let backupName = try #require(
                FileManager.default.contentsOfDirectory(atPath: directory.path).first { $0.contains(".broken-") }
            )
            #expect(try permissions(of: directory.appending(path: backupName)) == 0o600)
            #expect(try permissions(of: url) == 0o600)
        }
    }

    // MARK: Registering and removing

    /// Catches: the URI going into the config file, or surrounding whitespace from a paste being kept.
    @Test("register-connection saves the URI in the store and only the name in the config")
    func registerSavesToStore() throws {
        var config = CLIConfig()
        let store = InMemorySecretStore()

        try RegisterConnection.save(
            name: "local", uri: "  mongodb://localhost:27017\n", overwrite: false, into: &config, store: store
        )

        #expect(config.connections.map(\.name) == ["local"])
        #expect(config.connections.allSatisfy { $0.legacyURI == nil })
        #expect(store.all == ["local": "mongodb://localhost:27017"])
    }

    /// Catches: an existing connection being silently replaced without --overwrite.
    @Test("register-connection refuses an existing name unless told to overwrite it")
    func registerRespectsOverwrite() throws {
        var config = CLIConfig()
        let store = InMemorySecretStore()
        try RegisterConnection.save(name: "local", uri: "mongodb://a", overwrite: false, into: &config, store: store)

        #expect(throws: ValidationError.self) {
            try RegisterConnection.save(name: "local", uri: "mongodb://b", overwrite: false, into: &config, store: store)
        }
        #expect(store.all == ["local": "mongodb://a"])

        try RegisterConnection.save(name: "local", uri: "mongodb://b", overwrite: true, into: &config, store: store)
        #expect(store.all == ["local": "mongodb://b"])
        #expect(config.connections.map(\.name) == ["local"])
    }

    /// Catches: pressing Enter at the hidden prompt saving an empty URI.
    @Test("An empty URI isn't saved")
    func emptyURIRejected() {
        var config = CLIConfig()
        let store = InMemorySecretStore()

        #expect(throws: ConnectionError.self) {
            try RegisterConnection.save(name: "local", uri: "  \n", overwrite: false, into: &config, store: store)
        }
        #expect(store.all.isEmpty)
        #expect(config.connections.isEmpty)
    }

    /// Catches: removing a connection leaving its credentials behind in the Keychain.
    @Test("remove-connection removes the name from the config and the URI from the store")
    func removeClearsBoth() throws {
        var config = CLIConfig()
        let store = InMemorySecretStore()
        try RegisterConnection.save(name: "local", uri: "mongodb://a", overwrite: false, into: &config, store: store)
        try RegisterConnection.save(name: "staging", uri: "mongodb://b", overwrite: false, into: &config, store: store)

        try RemoveConnection.remove(name: "local", from: &config, store: store)

        #expect(config.connections.map(\.name) == ["staging"])
        #expect(store.all == ["staging": "mongodb://b"])
    }

    /// Catches: a typo in the name "succeeding" without removing anything.
    @Test("remove-connection with an unknown name is an error")
    func removeUnknownName() {
        var config = CLIConfig()

        #expect(throws: ConnectionError.self) {
            try RemoveConnection.remove(name: "nope", from: &config, store: InMemorySecretStore())
        }
    }

    // MARK: Looking up a URI

    /// Catches: commands connecting with something other than the URI saved for that name.
    @Test("Selecting a connection by name returns the URI from the store")
    func selectsURIFromStore() throws {
        var config = CLIConfig()
        config.connections = [MongoConnectionRecord(name: "local"), MongoConnectionRecord(name: "staging")]
        let store = InMemorySecretStore(["local": "mongodb://a", "staging": "mongodb://b"])

        let connection = try selectConnection(config: config, connectionName: "staging", store: store)

        #expect(connection.name == "staging")
        #expect(connection.uri == "mongodb://b")
    }

    /// Catches: a name with no Keychain entry (deleted in Keychain Access, say) connecting with an empty URI.
    @Test("A saved name with no URI behind it says how to fix it")
    func missingURIExplains() throws {
        var config = CLIConfig()
        config.connections = [MongoConnectionRecord(name: "local")]

        let error = #expect(throws: ConnectionError.self) {
            try selectConnection(config: config, connectionName: "local", store: InMemorySecretStore())
        }
        #expect(error.map { "\($0)" }?.contains("mport register-connection local --overwrite") == true)
    }
}

/// The only tests that touch the real Keychain, under a throwaway service name. Skipped in CI, where the runner's
/// Keychain may be locked.
@Suite(
    "Keychain",
    .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil, "Skipped in CI, where the Keychain may be locked")
)
struct KeychainStoreTests {

    /// Catches: saving, updating, reading or deleting a Keychain entry not working.
    @Test("A URI can be saved, replaced, read back and removed")
    func roundTrip() throws {
        let store = KeychainStore(service: "mport-tests-\(UUID().uuidString)")
        defer { try? store.removeURI(forConnection: "local") }

        #expect(try store.uri(forConnection: "local") == nil)

        try store.setURI("mongodb://first", forConnection: "local")
        #expect(try store.uri(forConnection: "local") == "mongodb://first")

        try store.setURI("mongodb://second", forConnection: "local")
        #expect(try store.uri(forConnection: "local") == "mongodb://second")

        try store.removeURI(forConnection: "local")
        #expect(try store.uri(forConnection: "local") == nil)
        try store.removeURI(forConnection: "local")
    }
}
