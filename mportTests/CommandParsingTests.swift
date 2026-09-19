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
        RoutingCase(subcommand: "register-connection", expectedType: "RegisterConnection")
    ]

    /// Catches: a new command written but never added to `Mport.configuration.subcommands`.
    @Test("Each subcommand name reaches its command", arguments: routingCases)
    func routesSubcommands(_ routingCase: RoutingCase) throws {
        var arguments = [routingCase.subcommand]
        if routingCase.subcommand == "register-connection" {
            arguments += ["name", "mongodb://localhost"]
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
            "--collision-resolution", "overwrite"
        ])

        #expect(command.directory == "/exports")
        #expect(command.connectionName == "local")
        #expect(command.dbName == "shop")
        #expect(command.importAll)
        #expect(command.collectionNames == ["users,orders"])
        #expect(command.collisionResolution == "overwrite")
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

    /// Catches: register-connection accepting a missing URI and saving a broken connection.
    @Test("register-connection: the URI is required")
    func registerConnectionRequiresURI() {
        #expect(throws: (any Error).self) {
            try RegisterConnection.parse(["local"])
        }
    }

    /// Catches: configure-defaults' optional positional arguments swapping order.
    @Test("configure-defaults: output path then format")
    func configureDefaultsParses() throws {
        let command = try ConfigureDefaults.parse(["/exports", "bson"])

        #expect(command.outputPath == "/exports")
        #expect(command.format == "bson")
    }
}
