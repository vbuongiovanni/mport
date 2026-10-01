//
//  CommandParsingTests.swift
//  Created by Claude on 9/18/26, at Vince's request.
//
//  The command-line interface is a contract with anyone who has typed or scripted it. These tests fail if a
//  property rename (like `to` → `targetConnection`) quietly changes a flag.
//

import ArgumentParser
import Foundation
import Testing

@Suite("Command-line parsing")
struct CommandParsingTests {

    // MARK: Routing

    struct RoutingCase: CustomTestStringConvertible, Sendable {
        let subcommand: String
        let expectedType: String

        var testDescription: String { subcommand }
    }

    static let routingCases: [RoutingCase] = [
        RoutingCase(subcommand: "import", expectedType: "Import"),
        RoutingCase(subcommand: "migrate", expectedType: "Migrate"),
        RoutingCase(subcommand: "export", expectedType: "Export"),
        RoutingCase(subcommand: "configure-defaults", expectedType: "ConfigureDefaults"),
        RoutingCase(subcommand: "register-connection", expectedType: "RegisterConnection"),
        RoutingCase(subcommand: "remove-connection", expectedType: "RemoveConnection")
    ]

    /// Catches: a new command written but never added to `Mport.configuration.subcommands`.
    @Test("Each subcommand name reaches its command", arguments: routingCases)
    func routesSubcommands(_ routingCase: RoutingCase) throws {
        var arguments = [routingCase.subcommand]
        if routingCase.subcommand == "register-connection" {
            arguments += ["name", "mongodb://localhost"]
        } else if routingCase.subcommand == "remove-connection" {
            arguments += ["name"]
        }
        let command = try Mport.parseAsRoot(arguments)
        #expect(String(describing: type(of: command)) == routingCase.expectedType)
    }

    // MARK: Import

    /// Catches: a changed short flag or option name breaking existing `mport import` invocations.
    @Test("import: every argument and flag")
    func importParsesEverything() throws {
        let command = try Import.parse([
            "/exports", "local",
            "-d", "shop",
            "--import-all",
            "-c", "users,orders",
            "--collision-resolution", "overwrite",
            "--skip-backup"
        ])

        #expect(command.directory == "/exports")
        #expect(command.connectionName == "local")
        #expect(command.dbName == "shop")
        #expect(command.importAll)
        #expect(command.collectionNames == ["users,orders"])
        #expect(command.collisionResolution == "overwrite")
        #expect(command.skipBackup)
    }

    /// Catches: an argument becoming required, which would stop the interactive prompts from ever running.
    @Test("import: everything is optional")
    func importDefaults() throws {
        let command = try Import.parse([])

        #expect(command.directory.isEmpty)
        #expect(command.connectionName == nil)
        #expect(command.dbName == nil)
        #expect(!command.importAll)
        #expect(command.collectionNames.isEmpty)
        #expect(command.collisionResolution == nil)
        #expect(!command.skipBackup)
    }

    // MARK: Migrate

    /// Catches: the source/target flags drifting from --from, --from-db, --to, --to-db.
    @Test("migrate: every flag, long form")
    func migrateParsesLongFlags() throws {
        let command = try Migrate.parse([
            "--from", "local", "--from-db", "shop",
            "--to", "backup", "--to-db", "shop_copy",
            "--migrate-all",
            "--collection-names", "users",
            "--collision-resolution", "skip"
        ])

        #expect(command.sourceConnection == "local")
        #expect(command.sourceDatabase == "shop")
        #expect(command.targetConnection == "backup")
        #expect(command.targetDatabase == "shop_copy")
        #expect(command.migrateAll)
        #expect(command.collectionNames == ["users"])
        #expect(command.collisionResolution == "skip")
    }

    /// Catches: the short forms -m and -c disappearing.
    @Test("migrate: short flags, repeated -c")
    func migrateParsesShortFlags() throws {
        let command = try Migrate.parse(["-m", "-c", "users", "-c", "orders"])

        #expect(command.migrateAll)
        #expect(command.collectionNames == ["users", "orders"])
    }

    /// Catches: the property names leaking into the CLI as --source-connection etc. if `.customLong` is removed.
    @Test("migrate: property names are not flags", arguments: [
        "--source-connection", "--source-database", "--target-connection", "--target-database"
    ])
    func migrateRejectsPropertyNames(_ flag: String) {
        #expect(throws: (any Error).self) {
            try Migrate.parse([flag, "value"])
        }
    }

    // MARK: Export

    /// Catches: the positional order of `mport export <path> <connection> <db>` changing.
    @Test("export: positional arguments, format, and -e")
    func exportParses() throws {
        let command = try Export.parse(["/exports", "local", "shop", "--format", "json", "-e"])

        #expect(command.exportPath == "/exports")
        #expect(command.connectionName == "local")
        #expect(command.dbName == "shop")
        #expect(command.format == "json")
        #expect(command.exportAll)
    }

    // MARK: Setup commands

    /// Catches: register-connection's required arguments or --overwrite flag changing.
    @Test("register-connection: name, uri and -o")
    func registerConnectionParses() throws {
        let command = try RegisterConnection.parse(["local", "mongodb://localhost:27017", "-o"])

        #expect(command.name == "local")
        #expect(command.uri == "mongodb://localhost:27017")
        #expect(command.overwrite)
    }

    /// Catches: the URI becoming required again, which would force it onto the command line and into shell history.
    @Test("register-connection: the URI can be left out, to be typed hidden")
    func registerConnectionURIOptional() throws {
        let command = try RegisterConnection.parse(["local"])
        #expect(command.name == "local")
        #expect(command.uri == nil)
    }

    /// Catches: a connection being saved without a name.
    @Test("register-connection and remove-connection: the name is required")
    func connectionNameRequired() {
        #expect(throws: (any Error).self) {
            try RegisterConnection.parse([])
        }
        #expect(throws: (any Error).self) {
            try RemoveConnection.parse([])
        }
    }

    /// Catches: configure-defaults' optional positional arguments swapping order.
    @Test("configure-defaults: output path then format")
    func configureDefaultsParses() throws {
        let command = try ConfigureDefaults.parse(["/exports", "bson"])

        #expect(command.outputPath == "/exports")
        #expect(command.format == "bson")
        #expect(command.concurrency == nil)
    }

    /// Catches: --concurrency only working alongside the positional arguments, or not at all.
    @Test("configure-defaults: --concurrency alone and alongside the other defaults", arguments: [
        ["--concurrency", "8"],
        ["/exports", "bson", "--concurrency", "8"]
    ])
    func configureDefaultsParsesConcurrency(_ arguments: [String]) throws {
        #expect(try ConfigureDefaults.parse(arguments).concurrency == 8)
    }

    /// Catches: saving a default that every later run would have to warn about.
    @Test("configure-defaults: an out-of-range --concurrency is rejected", arguments: ["0", "33", "100"])
    func configureDefaultsRejectsConcurrency(_ value: String) {
        #expect(throws: (any Error).self) {
            try ConfigureDefaults.parse(["--concurrency", value])
        }
    }

    /// Catches: setting the concurrency default wiping or changing the other saved settings.
    @Test("configure-defaults --concurrency changes only defaultConcurrency")
    func configureDefaultsKeepsOtherSettings() throws {
        var config = CLIConfig()
        config.connections = [MongoConnectionRecord(name: "local")]
        config.defaultExportPath = "/exports"
        config.defaultFormat = .bson

        let changed = try ConfigureDefaults.parse(["--concurrency", "8"]).apply(to: &config)

        #expect(changed)
        #expect(config.defaultConcurrency == 8)
        #expect(config.connections.map(\.name) == ["local"])
        #expect(config.defaultExportPath == "/exports")
        #expect(config.defaultFormat == .bson)
    }

    // MARK: --concurrency on export, import and migrate

    struct ConcurrencyCase: CustomTestStringConvertible, Sendable {
        let arguments: [String]
        let expected: Int?

        var testDescription: String { arguments.joined(separator: " ") }
    }

    static let concurrencyCases: [ConcurrencyCase] = [
        ConcurrencyCase(arguments: ["-j", "2"], expected: 2),
        ConcurrencyCase(arguments: ["--concurrency", "8"], expected: 8),
        ConcurrencyCase(arguments: [], expected: nil)
    ]

    /// Catches: one command missing the shared option, or -j and --concurrency parsing differently.
    @Test("export, import and migrate all take -j / --concurrency", arguments: concurrencyCases)
    func parsesConcurrency(_ concurrencyCase: ConcurrencyCase) throws {
        #expect(try Export.parse(concurrencyCase.arguments).concurrencyOptions.concurrency == concurrencyCase.expected)
        #expect(try Import.parse(concurrencyCase.arguments).concurrencyOptions.concurrency == concurrencyCase.expected)
        #expect(try Migrate.parse(concurrencyCase.arguments).concurrencyOptions.concurrency == concurrencyCase.expected)
    }

    /// Catches: an out-of-range value reaching a run, where it would open 0 or dozens of connections.
    @Test("An out-of-range --concurrency is rejected with the valid range", arguments: ["0", "33"])
    func rejectsOutOfRangeConcurrency(_ value: String) {
        for command in [Export.self, Import.self, Migrate.self] as [any ParsableCommand.Type] {
            do {
                _ = try command.parse(["-j", value])
                Issue.record("\(command) accepted -j \(value)")
            } catch {
                #expect(command.message(for: error).contains("between 1 and 32"))
            }
        }
    }

    /// Catches: a non-number being accepted as a concurrency.
    @Test("A non-numeric --concurrency is rejected")
    func rejectsNonNumericConcurrency() {
        #expect(throws: (any Error).self) {
            try Export.parse(["--concurrency", "abc"])
        }
    }
}
