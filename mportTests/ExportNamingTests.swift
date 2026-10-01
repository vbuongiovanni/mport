//
//  ExportNamingTests.swift
//  Created by Claude on 9/29/26, at Vince's request.
//

import ArgumentParser
import Foundation
import Testing

@Suite("Export: selecting collections")
struct ExportCollectionSelectionTests {

    /// Catches: system collections being exported, which `migrate` has always skipped.
    @Test("--export-all skips system.* collections")
    func skipsSystemCollections() throws {
        let command = try Export.parse(["-e"])
        let selected = try command.selectCollections(from: ["users", "system.views", "orders"], in: "shop")
        #expect(selected == ["users", "orders"])
    }

    /// Catches: an empty picker being shown, or --export-all "succeeding" with nothing written.
    @Test("With nothing but system collections, or none at all, there's nothing to export", arguments: [
        ["system.views", "system.profile"],
        []
    ])
    func nothingToExport(_ available: [String]) throws {
        let command = try Export.parse(["-e"])
        let error = #expect(throws: CLIError.self) {
            try command.selectCollections(from: available, in: "shop")
        }
        guard case .noCollections(let database) = error else {
            Issue.record("Expected .noCollections, got \(String(describing: error))")
            return
        }
        #expect(database == "shop")
    }
}

@Suite("Export: case-only name clashes")
struct ExportNamingTests {

    /// Catches: two collections that would share a file on a case-insensitive disk going unnoticed.
    @Test("Names that differ only by case are grouped, in the order they appear")
    func findsClashes() {
        #expect(caseClashes(in: ["Users", "orders", "users", "USERS"]) == [["Users", "users", "USERS"]])
        #expect(caseClashes(in: ["a", "B", "b", "A"]) == [["a", "A"], ["B", "b"]])
    }

    /// Catches: distinct names being reported as clashes.
    @Test("Distinct names don't clash")
    func noClashes() {
        #expect(caseClashes(in: ["users", "orders", "user"]).isEmpty)
        #expect(caseClashes(in: []).isEmpty)
    }

    /// Catches: the volume check failing (and so refusing) just because the export folder doesn't exist yet.
    @Test("The volume check works for a folder that doesn't exist yet")
    func checksNearestExistingFolder() async {
        await withTemporaryDirectory { directory in
            let notYetCreated = directory.appending(path: "local/shop", directoryHint: .isDirectory)
            #expect(isCaseSensitiveVolume(at: notYetCreated) == isCaseSensitiveVolume(at: directory))
        }
    }

    /// Catches: the error hiding which collections clash, or not saying how to get them exported.
    @Test("The clash error names every collection and suggests separate runs")
    func errorDescription() {
        let error = ExportNameClashError(groups: [["Users", "users"], ["A", "a"]])

        for name in ["'Users'", "'users'", "'A'", "'a'"] {
            #expect(error.description.contains(name))
        }
        #expect(error.description.contains("separate runs"))
    }

    /// Catches: the clash check being skipped, or refusing on a disk where the files wouldn't collide.
    @Test("Export refuses a clash only where the disk would merge the files")
    func refusesOnlyOnCaseInsensitiveDisks() async {
        await withTemporaryDirectory { directory in
            let refuses = (try? Export.refuseCaseClashes(in: ["Users", "users"], exportingTo: directory)) == nil
            #expect(refuses == !isCaseSensitiveVolume(at: directory))
            #expect(throws: Never.self) {
                try Export.refuseCaseClashes(in: ["users", "orders"], exportingTo: directory)
            }
        }
    }
}
