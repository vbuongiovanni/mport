//
//  CLIConfigTests.swift
//  Created by Claude on 9/29/26, at Vince's request.
//
//  Every test works on a config file in a temporary directory, never the real ~/.mport-config.json.
//

import Foundation
import Noora
import Testing

@Suite("Config file")
struct CLIConfigTests {

    private let fileName = ".mport-config.json"

    private let savedConfig = """
    {
      "connections": [{ "name": "local", "uri": "mongodb://localhost:27017" }],
      "defaultExportPath": "/exports",
      "defaultFormat": "bson"
    }
    """

    /// Files in `directory` other than the config itself, i.e. any backups.
    private func backups(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0 != fileName }
    }

    // MARK: Decoding

    /// Catches: `defaultConcurrency` becoming required, which would send every existing config down the
    /// "can't be decoded" path.
    @Test("A config saved before defaultConcurrency existed still decodes, with everything intact")
    func decodesOlderConfig() throws {
        let config = try JSONDecoder().decode(CLIConfig.self, from: Data(savedConfig.utf8))

        #expect(config.connections.map(\.name) == ["local"])
        #expect(config.connections.map(\.legacyURI) == ["mongodb://localhost:27017"])
        #expect(config.defaultExportPath == "/exports")
        #expect(config.defaultFormat == .bson)
        #expect(config.defaultConcurrency == nil)
    }

    /// Catches: the key name drifting, which would silently drop a saved default.
    @Test("defaultConcurrency decodes and round-trips")
    func concurrencyRoundTrips() throws {
        let json = #"{"connections": [], "defaultConcurrency": 8}"#
        let decoded = try JSONDecoder().decode(CLIConfig.self, from: Data(json.utf8))
        #expect(decoded.defaultConcurrency == 8)

        let reencoded = try JSONDecoder().decode(CLIConfig.self, from: JSONEncoder().encode(decoded))
        #expect(reencoded.defaultConcurrency == 8)
    }

    // MARK: Missing file

    /// Catches: a first run failing, or warning that a file that doesn't exist is malformed.
    @Test("A missing file is created empty, with no backup")
    func createsMissingFile() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appending(path: fileName)

            let config = try CLIConfig.read(from: url, store: InMemorySecretStore())

            #expect(config.connections.isEmpty)
            #expect(try CLIConfig.read(from: url, store: InMemorySecretStore()).connections.isEmpty)
            #expect(try backups(in: directory).isEmpty)
        }
    }

    // MARK: Undecodable file

    /// Catches: a damaged or hand-edited config being overwritten, which loses every saved connection.
    @Test("An undecodable file is moved to a backup, byte for byte, and a fresh config is started", arguments: [
        #"{"connections": ["#,
        #"{"connections": [], "defaultConcurrency": "four"}"#
    ])
    func backsUpUndecodableFile(_ contents: String) async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appending(path: fileName)
            try Data(contents.utf8).write(to: url)

            let config = try CLIConfig.read(from: url, store: InMemorySecretStore())

            #expect(config.connections.isEmpty)
            #expect(try JSONDecoder().decode(CLIConfig.self, from: Data(contentsOf: url)).connections.isEmpty)

            let backupNames = try backups(in: directory)
            #expect(backupNames.count == 1)
            let backupName = try #require(backupNames.first)
            #expect(backupName.hasPrefix("\(fileName).broken-"))
            #expect(try Data(contentsOf: directory.appending(path: backupName)) == Data(contents.utf8))
        }
    }

    /// Catches: the warning losing the backup's location, or the link not pointing at the backup file.
    @Test("In a terminal, the warning links the backup's full path")
    func warningLinksBackup() {
        let backup = URL(filePath: "/Users/me/.mport-config.json.broken-2026-09-29T221108Z")
        let warning = CLIConfig.brokenConfigWarning(backup: backup, asLink: true)

        let rendered = warning.formatted(
            theme: .default, terminal: Terminal(isInteractive: true, isColored: false, signalBehavior: .none)
        )

        #expect(warning.plain().contains(backup.path))
        #expect(rendered.contains("\u{1B}]8;;\(backup.absoluteString)\u{1B}\\\(backup.path)"))
    }

    /// Catches: link escape codes ending up in a log file. Noora judges "interactive" by stdin, so `mport … > log`
    /// from a terminal would still render a link if the warning asked for one.
    @Test("With output redirected, the warning shows the path as plain text, even if stdin is a terminal")
    func warningPlainWhenRedirected() {
        let backup = URL(filePath: "/Users/me/.mport-config.json.broken-2026-09-29T221108Z")
        let warning = CLIConfig.brokenConfigWarning(backup: backup, asLink: false)

        let rendered = warning.formatted(
            theme: .default, terminal: Terminal(isInteractive: true, isColored: false, signalBehavior: .none)
        )

        #expect(rendered.contains(backup.path))
        #expect(!rendered.contains("\u{1B}"))
    }

    // MARK: Never losing the original

    /// Catches: a failed backup still overwriting the original with an empty config.
    @Test("If the backup can't be made, the original is left exactly as it was")
    func backupFailureLeavesOriginal() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appending(path: fileName)
            let contents = Data(#"{"connections": ["#.utf8)
            try contents.write(to: url)

            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

            let error = #expect(throws: ConfigError.self) {
                try CLIConfig.read(from: url, store: InMemorySecretStore())
            }
            guard case .backupFailed(let path, _) = error else {
                Issue.record("Expected .backupFailed, got \(String(describing: error))")
                return
            }
            #expect(path == url.path)
            #expect(try Data(contentsOf: url) == contents)
            #expect(try backups(in: directory).isEmpty)
        }
    }

    /// Catches: an unreadable file being treated as missing or malformed, and replaced.
    @Test("A file that can't be read is left alone")
    func unreadableFileLeftAlone() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appending(path: fileName)
            try Data(savedConfig.utf8).write(to: url)

            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

            let error = #expect(throws: ConfigError.self) {
                try CLIConfig.read(from: url, store: InMemorySecretStore())
            }
            guard case .unreadable(let path, _) = error else {
                Issue.record("Expected .unreadable, got \(String(describing: error))")
                return
            }
            #expect(path == url.path)
            #expect(try backups(in: directory).isEmpty)

            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            #expect(try Data(contentsOf: url) == Data(savedConfig.utf8))
        }
    }
}
