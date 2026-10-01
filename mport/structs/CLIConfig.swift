//
//  CLIConfig.swift
//  Created by Vince B. on 9/15/26.
//  Made with love, not AI.
//  This file was generated in swift.
//  This code was written with my fingers and brain using a keyboard.
//

import Foundation
import Noora

struct CLIConfig: Codable {
    var connections: [MongoConnectionRecord]
    var defaultExportPath: String?
    var defaultFormat: OutputFormat?
    /// Optional, so config files written before it existed still decode.
    var defaultConcurrency: Int?
    private static let configFileName: String = ".mport-config.json"

    /// `~/.mport-config.json`
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(component: configFileName)
    }

    init() {
        self.connections = [MongoConnectionRecord]()
    }

    static func read() throws -> CLIConfig {
        try read(from: defaultURL)
    }

    /// Reads the config at `url`.
    /// - A missing file is created, empty.
    /// - A file that can't be decoded is moved aside to a `.broken-<timestamp>` backup and replaced with an empty
    ///   config, with a warning that links the backup, so a bad edit never silently loses the saved connections.
    /// - Anything else (the file can't be read, or the backup can't be made) throws and leaves the file untouched.
    /// - URIs left in the file by an older mport are moved into `store` (the Keychain), and the file is rewritten
    ///   without them.
    ///
    /// The file (and any backup) is kept readable only by its owner.
    static func read(from url: URL, store: SecretStore = KeychainStore.standard) throws -> CLIConfig {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            let config = CLIConfig()
            try save(config, to: url)
            return config
        } catch {
            throw ConfigError.unreadable(path: url.path, reason: error.localizedDescription)
        }
        restrictToOwner(url)

        let config: CLIConfig
        do {
            config = try JSONDecoder().decode(CLIConfig.self, from: data)
        } catch {
            let backup = try moveAside(url)
            restrictToOwner(backup)
            let freshConfig = CLIConfig()
            try save(freshConfig, to: url)
            Noora().warning(.alert(brokenConfigWarning(backup: backup)))
            return freshConfig
        }
        return try movingURIsToKeychain(config, at: url, store: store)
    }

    /// Configs written before URIs moved to the Keychain still have them in the file. Each one is saved in the
    /// Keychain first, and only then is the file rewritten without them, so a Keychain failure loses nothing.
    private static func movingURIsToKeychain(_ config: CLIConfig, at url: URL, store: SecretStore) throws -> CLIConfig {
        var movedCount = 0
        for record in config.connections {
            if let uri = record.legacyURI {
                try store.setURI(uri, forConnection: record.name)
                movedCount += 1
            }
        }
        guard movedCount > 0 else {
            return config
        }

        var migrated = config
        migrated.connections = config.connections.map { MongoConnectionRecord(name: $0.name) }
        try save(migrated, to: url)
        Noora().info(.alert(
            "Moved \(movedCount) saved connection URI(s) out of \(url.path) and into your Keychain",
            takeaways: ["The config file no longer holds any credentials."]
        ))
        return migrated
    }

    static func write(newConfig: CLIConfig) throws {
        try write(newConfig, to: defaultURL)
    }

    static func write(_ config: CLIConfig, to url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.missingConfig
        }
        try save(config, to: url)
    }

    /// The warning shown after an undecodable config was moved aside. The backup's full path is the link's title,
    /// so terminals that don't support links still show where it is.
    /// - Parameter asLink: Whether to make the path clickable. Only when output is a terminal: Noora decides
    ///   "interactive" from stdin, so `mport … > log` would otherwise write the link's escape codes into the file.
    static func brokenConfigWarning(backup: URL, asLink: Bool = isatty(STDOUT_FILENO) != 0) -> TerminalText {
        let location: TerminalText.Component = asLink
            ? .link(title: backup.path, href: backup.absoluteString)
            : .raw(backup.path)
        return """
        Your config file couldn't be read, so a fresh one was started. \
        The old one is saved at \(location). \
        Fix it and move it back to keep your saved connections.
        """
    }

    /// Writes the config readable only by its owner (mode 600), and atomically: the new contents go to a temporary
    /// file created with those permissions, which is then renamed over the old one. The file is never, even
    /// briefly, readable by anyone else.
    private static func save(_ config: CLIConfig, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(config)

        let temporaryName = "\(url.lastPathComponent).tmp-\(UUID().uuidString)"
        let temporary = url.deletingLastPathComponent().appending(component: temporaryName)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, url.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Tightens a file mport wrote with looser permissions (an older version did) to owner-only. Best effort:
    /// a file mport doesn't own is left as it is.
    private static func restrictToOwner(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Renames `url` to `<name>.broken-<timestamp>` next to it. A rename is atomic, so there's never a moment when
    /// the original is gone and the backup incomplete, and it fails rather than replace an existing backup.
    private static func moveAside(_ url: URL) throws -> URL {
        let timestamp = Date.now.formatted(.iso8601.timeSeparator(.omitted))
        let backupName = "\(url.lastPathComponent).broken-\(timestamp)"
        let backup = url.deletingLastPathComponent().appending(component: backupName)
        do {
            try FileManager.default.moveItem(at: url, to: backup)
        } catch {
            throw ConfigError.backupFailed(path: url.path, reason: error.localizedDescription)
        }
        return backup
    }
}

/// Problems with the config file itself. Unlike `CLIError`, these print as sentences, since each one leaves the
/// user something to fix by hand.
enum ConfigError: Error, CustomStringConvertible {
    case unreadable(path: String, reason: String)
    case backupFailed(path: String, reason: String)

    var description: String {
        switch self {
        case let .unreadable(path, reason):
            "Couldn't read the config file at \(path): \(reason) It hasn't been changed."
        case let .backupFailed(path, reason):
            "The config file at \(path) couldn't be decoded, and backing it up failed: \(reason) "
                + "It hasn't been changed. Fix or move it, then try again."
        }
    }
}
