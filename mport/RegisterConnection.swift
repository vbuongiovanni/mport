//
//  RegisterConnection.swift
//  Created by Vince B. on 9/15/26.
//  Made with love, not AI. 
//  This file was generated in swift.
//  This code was written with my fingers and brain using a keyboard.
//

import Foundation
import ArgumentParser

struct RegisterConnection: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Save a MongoDB connection. Its URI goes in your Keychain, not the config file",
        discussion: """
        Leave out the URI to type it without it showing on screen or landing in your shell history. \
        It can also be piped in, e.g. from a password manager: `op read "op://…" | mport register-connection prod`.
        """,
        version: "1.0.0"
    )

    @Argument(help: "Name/Label of MongoDB URI")
    var name: String

    @Argument(help: "Mongo Connection URI. Leave it out to be asked for it, which keeps it out of your shell history")
    var uri: String?

    @Flag(name: .shortAndLong, help: "Overwrite existing")
    var overwrite: Bool = false

    func run() throws {
        var config = try CLIConfig.read()
        let connectionURI = try uri ?? readURI()

        try Self.save(
            name: name, uri: connectionURI, overwrite: overwrite, into: &config, store: KeychainStore.standard
        )
        try CLIConfig.write(newConfig: config)

        print("Saved '\(name)'. Its URI is in your Keychain; the config file only has the name.")
    }

    /// Adds the connection (or, with `overwrite`, replaces it): the URI goes into `store`, and only the name into
    /// `config`. The URI is saved first, so a failed save leaves the config as it was.
    static func save(
        name: String,
        uri: String,
        overwrite: Bool,
        into config: inout CLIConfig,
        store: SecretStore
    ) throws {
        let uri = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uri.isEmpty else {
            throw ConnectionError.emptyURI
        }
        if !overwrite && config.connections.contains(where: { $0.name == name }) {
            throw ValidationError("An existing connection already exists with that name")
        }

        try store.setURI(uri, forConnection: name)
        config.connections = config.connections.filter { $0.name != name }
        config.connections.append(MongoConnectionRecord(name: name))
    }

    /// The URI, typed with echo turned off when there's a terminal, or read from stdin when it's piped in.
    private func readURI() throws -> String {
        guard isatty(STDIN_FILENO) != 0 else {
            return readLine() ?? ""
        }
        print("URI for '\(name)' (hidden as you type): ", terminator: "")
        fflush(stdout)

        tcgetattr(STDIN_FILENO, &savedTerminalSettings)
        var hidden = savedTerminalSettings
        hidden.c_lflag &= ~tcflag_t(ECHO)
        // Ctrl-C while typing must not leave the shell with echo turned off.
        signal(SIGINT) { _ in
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &savedTerminalSettings)
            _exit(130)
        }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &hidden)
        defer {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &savedTerminalSettings)
            signal(SIGINT, SIG_DFL)
            print()
        }
        return readLine() ?? ""
    }
}

/// The terminal settings to restore after reading a hidden URI. Global so the SIGINT handler, which can't capture
/// anything, can reach it. Only touched on the main thread, around a single blocking `readLine()`.
nonisolated(unsafe) private var savedTerminalSettings = termios()
