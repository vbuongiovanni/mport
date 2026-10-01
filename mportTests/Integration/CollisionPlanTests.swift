//
//  CollisionPlanTests.swift
//  Created by Claude on 9/18/26, at Vince's request.
//
//  What happens to target collections that already exist. Only the non-interactive paths are covered:
//  an invalid or missing --collision-resolution falls through to a Noora prompt.
//

import ArgumentParser
import Foundation
import MongoKitten
import Testing

@Suite(
    "Collision handling",
    .tags(.integration),
    .enabled(if: TestMongo.isAvailable, "Needs a MongoDB at MPORT_TEST_MONGO_URI (default localhost:27017)"),
    .timeLimit(.minutes(1))
)
struct CollisionPlanTests {

    private let unusedBackupDirectory = URL(filePath: "/nonexistent")

    // MARK: resolve

    /// Catches: asking for a collision strategy when nothing collides. Without a terminal that prompt
    /// would crash this test, so passing at all proves no prompt was shown.
    @Test("With no existing target collections, there's nothing to resolve")
    func noCollisions() async throws {
        try await TestMongo.withTemporaryDatabase { db in
            try await db["unrelated"].insert(["_id": 1])

            let plan = try await CollisionPlan.resolve(
                for: ["users", "orders"], in: db, flagValue: nil, backupDirectory: unusedBackupDirectory
            )

            #expect(plan.collectionNames.isEmpty)
            #expect(plan.strategy == .skip)
        }
    }

    /// Catches: --collision-resolution being ignored, or non-colliding collections being marked with an asterisk.
    @Test(
        "--collision-resolution is used as-is, and only existing names count",
        arguments: CollisionResolution.allCases
    )
    func usesFlag(_ strategy: CollisionResolution) async throws {
        try await TestMongo.withTemporaryDatabase { db in
            try await db["users"].insert(["_id": 1])

            let plan = try await CollisionPlan.resolve(
                for: ["users", "orders"], in: db, flagValue: strategy.rawValue, backupDirectory: unusedBackupDirectory
            )

            #expect(plan.collectionNames == ["users"])
            #expect(plan.strategy == strategy)
        }
    }

    // MARK: prepare

    struct PrepareCase: CustomTestStringConvertible, Sendable {
        let strategy: CollisionResolution
        let usersLeft: Int
        let writesBackup: Bool

        var testDescription: String { strategy.rawValue }
    }

    static let prepareCases: [PrepareCase] = [
        PrepareCase(strategy: .dumpBeforeImport, usersLeft: 0, writesBackup: true),
        PrepareCase(strategy: .clearBeforeImport, usersLeft: 0, writesBackup: false),
        PrepareCase(strategy: .overwrite, usersLeft: 3, writesBackup: false),
        PrepareCase(strategy: .skip, usersLeft: 3, writesBackup: false)
    ]

    /// Catches: a strategy clearing data it shouldn't, clearing the wrong collection, or skipping its backup.
    @Test("Each strategy prepares only the colliding collections", arguments: prepareCases)
    func prepares(_ prepareCase: PrepareCase) async throws {
        try await withTemporaryDirectory { backupDirectory in
            try await TestMongo.withTemporaryDatabase { db in
                let users = SampleDocuments.mixedTypes(count: 3)
                try await db["users"].insertMany(users)
                try await db["untouched"].insertMany(SampleDocuments.numbered(1...2))
                let plan = CollisionPlan(
                    collectionNames: ["users"], strategy: prepareCase.strategy, backupDirectory: backupDirectory
                )

                try await plan.prepare(in: db)

                #expect(try await db["users"].count() == prepareCase.usersLeft)
                #expect(try await db["untouched"].count() == 2)

                let backupFile = backupDirectory.appending(path: "users.bson")
                #expect(FileManager.default.fileExists(atPath: backupFile.path) == prepareCase.writesBackup)
                if prepareCase.writesBackup {
                    #expect(try readBSONFile(at: backupFile) == users)
                }
            }
        }
    }

    /// Catches: --skip-backup still writing a backup, or no longer clearing the colliding collection.
    @Test("With --skip-backup, dump-before-import clears without writing a backup")
    func skipBackupClearsWithoutBackup() async throws {
        try await withTemporaryDirectory { backupDirectory in
            try await TestMongo.withTemporaryDatabase { db in
                try await db["users"].insertMany(SampleDocuments.mixedTypes(count: 3))
                let plan = CollisionPlan(
                    collectionNames: ["users"], strategy: .dumpBeforeImport, backupDirectory: backupDirectory
                ).skippingBackup()

                try await plan.prepare(in: db)

                #expect(try await db["users"].count() == 0)
                #expect(try FileManager.default.contentsOfDirectory(atPath: backupDirectory.path).isEmpty)
            }
        }
    }

    /// Catches: a backup that can't be restored, which would make dump-before-import no safer than clear.
    @Test("A dump-before-import backup restores the original collection exactly")
    func backupRestores() async throws {
        try await withTemporaryDirectory { backupDirectory in
            try await TestMongo.withTemporaryDatabase { db in
                let original = SampleDocuments.mixedTypes(count: 50)
                try await db["users"].insertMany(original)
                let plan = CollisionPlan(
                    collectionNames: ["users"], strategy: .dumpBeforeImport, backupDirectory: backupDirectory
                )

                try await plan.prepare(in: db)
                #expect(try await db["users"].count() == 0)

                let backup = try BSONFileReader(url: backupDirectory.appending(path: "users.bson"))
                _ = try await writeDocuments(backup, into: db["users"], replacingDuplicates: false) { _ in }
                #expect(try await db["users"].allDocuments() == original)
            }
        }
    }
}

@Suite("--skip-backup")
struct SkipBackupTests {

    /// Catches: --skip-backup changing a strategy that never backs anything up, or dropping the collisions.
    @Test(
        "Only dump-before-import changes, and it becomes clear-before-import",
        arguments: CollisionResolution.allCases
    )
    func skippingBackup(_ strategy: CollisionResolution) {
        let backupDirectory = URL(filePath: "/backups")
        let plan = CollisionPlan(collectionNames: ["users"], strategy: strategy, backupDirectory: backupDirectory)

        let skipped = plan.skippingBackup()

        #expect(skipped.strategy == (strategy == .dumpBeforeImport ? .clearBeforeImport : strategy))
        #expect(skipped.collectionNames == ["users"])
        #expect(skipped.backupDirectory == backupDirectory)
    }
}

@Suite("Comparing files")
struct FileComparisonTests {

    /// Catches: identical dumps being re-imported anyway, or different ones being treated as the same.
    @Test("Files match only when their bytes are identical")
    func matchesIdenticalBytes() async throws {
        try await withTemporaryDirectory { directory in
            let original = directory.appending(path: "a.bson")
            let copy = directory.appending(path: "b.bson")
            let sameSizeDifferent = directory.appending(path: "c.bson")
            let longer = directory.appending(path: "d.bson")
            try writeBSONFile(SampleDocuments.numbered(1...100), to: original)
            try writeBSONFile(SampleDocuments.numbered(1...100), to: copy)
            try writeBSONFile(SampleDocuments.numbered(2...101), to: sameSizeDifferent)
            try writeBSONFile(SampleDocuments.numbered(1...101), to: longer)

            #expect(try filesMatch(original, copy))
            #expect(try !filesMatch(original, sameSizeDifferent))
            #expect(try !filesMatch(original, longer))
        }
    }
}

@Suite(
    "Import: leaving unchanged collections alone",
    .tags(.integration),
    .enabled(if: TestMongo.isAvailable, "Needs a MongoDB at MPORT_TEST_MONGO_URI (default localhost:27017)"),
    .timeLimit(.minutes(1))
)
struct UnchangedImportTests {

    /// Catches: a collection that already holds exactly the file's documents being cleared and re-imported, or (worse)
    /// cleared and then skipped, which would lose its data.
    @Test("With dump-before-import, a collection identical to its file isn't cleared, and its import is skipped")
    func identicalCollectionLeftAlone() async throws {
        try await withTemporaryDirectory { directory in
            try await TestMongo.withTemporaryDatabase { db in
                let users = SampleDocuments.mixedTypes(count: 40)
                let oldOrders = SampleDocuments.numbered(1...20)
                try await db["users"].insertMany(users)
                try await db["orders"].insertMany(oldOrders)

                let usersFile = directory.appending(path: "files/users.bson")
                let ordersFile = directory.appending(path: "files/orders.bson")
                try writeBSONFile(users, to: usersFile)
                try writeBSONFile(SampleDocuments.numbered(100...130), to: ordersFile)
                let plan = [
                    ImportItem(file: usersFile, displayName: "users.bson"),
                    ImportItem(file: ordersFile, displayName: "orders.bson")
                ]
                let backupDirectory = directory.appending(path: "backups")
                let collisions = CollisionPlan(
                    collectionNames: ["users", "orders"], strategy: .dumpBeforeImport, backupDirectory: backupDirectory
                )

                let target = (slots: ClientSlots.single(db), database: db.name)
                let split = try await Import.prepare(plan, collisions: collisions, in: target)

                #expect(split.unchanged.map(\.collectionName) == ["users"])
                #expect(split.toImport.map(\.collectionName) == ["orders"])
                #expect(try await db["users"].allDocuments() == users)
                #expect(try await db["orders"].count() == 0)
                #expect(try readBSONFile(at: backupDirectory.appending(path: "users.bson")) == users)
                #expect(try readBSONFile(at: backupDirectory.appending(path: "orders.bson")) == oldOrders)
            }
        }
    }

    /// Catches: comparing one of several files against a collection they all go into, which could skip the others.
    @Test("A collection that several files go into is never treated as unchanged")
    func sharedTargetAlwaysImported() async throws {
        try await withTemporaryDirectory { directory in
            try await TestMongo.withTemporaryDatabase { db in
                let users = SampleDocuments.numbered(1...10)
                try await db["users"].insertMany(users)

                let sameFile = directory.appending(path: "a.bson")
                let otherFile = directory.appending(path: "b.bson")
                try writeBSONFile(users, to: sameFile)
                try writeBSONFile(SampleDocuments.numbered(11...20), to: otherFile)
                var plan = [
                    ImportItem(file: sameFile, displayName: "a.bson"),
                    ImportItem(file: otherFile, displayName: "b.bson")
                ]
                for index in plan.indices {
                    plan[index].collectionName = "users"
                }
                let collisions = CollisionPlan(
                    collectionNames: ["users"],
                    strategy: .dumpBeforeImport,
                    backupDirectory: directory.appending(path: "backups")
                )

                let target = (slots: ClientSlots.single(db), database: db.name)
                let split = try await Import.prepare(plan, collisions: collisions, in: target)

                #expect(split.unchanged.isEmpty)
                #expect(split.toImport.count == 2)
                #expect(try await db["users"].count() == 0)
            }
        }
    }

    /// Catches: the comparison running when there's no backup, e.g. under --skip-backup.
    @Test("Without a backup (clear-before-import), nothing is compared or left alone")
    func noBackupNoComparison() async throws {
        try await withTemporaryDirectory { directory in
            try await TestMongo.withTemporaryDatabase { db in
                let users = SampleDocuments.numbered(1...10)
                try await db["users"].insertMany(users)
                let file = directory.appending(path: "users.bson")
                try writeBSONFile(users, to: file)
                let collisions = CollisionPlan(
                    collectionNames: ["users"],
                    strategy: .dumpBeforeImport,
                    backupDirectory: directory.appending(path: "backups")
                ).skippingBackup()

                let plan = [ImportItem(file: file, displayName: "users.bson")]
                let target = (slots: ClientSlots.single(db), database: db.name)
                let split = try await Import.prepare(plan, collisions: collisions, in: target)

                #expect(split.unchanged.isEmpty)
                #expect(try await db["users"].count() == 0)
            }
        }
    }
}

@Suite(
    "Backups: running concurrently, with one status line",
    .tags(.integration),
    .enabled(if: TestMongo.isAvailable, "Needs a MongoDB at MPORT_TEST_MONGO_URI (default localhost:27017)"),
    .timeLimit(.minutes(1))
)
struct ConcurrentBackupTests {

    /// Catches: the per-collection "Backed up …" lines coming back, or the counts being wrong.
    @Test("Backups report one line of counts, then where the backups are")
    func reportsCounts() async throws {
        try await withTemporaryDirectory { directory in
            try await TestMongo.withTemporaryDatabase { db in
                let names = ["a", "b", "c", "d"]
                for name in names {
                    try await db[name].insertMany(SampleDocuments.numbered(1...20))
                }
                let identical = directory.appending(path: "files/a.bson")
                let different = directory.appending(path: "files/b.bson")
                try writeBSONFile(SampleDocuments.numbered(1...20), to: identical)
                try writeBSONFile(SampleDocuments.numbered(1...5), to: different)
                let backupDirectory = directory.appending(path: "backups")
                let plan = CollisionPlan(
                    collectionNames: Set(names), strategy: .dumpBeforeImport, backupDirectory: backupDirectory
                )
                let pipeline = RecordingPipeline()
                let slots = try await ClientSlots.open(count: 4, reusing: db, uri: TestMongo.uri)

                let unchanged = try await plan.prepare(
                    in: (slots: slots, database: db.name),
                    skippingIfIdenticalTo: ["a": identical, "b": different],
                    status: StatusLine(pipeline: pipeline, isInteractive: false)
                )
                await slots.disconnect()

                #expect(unchanged == ["a"])
                #expect(pipeline.output == """
                ✔︎ 4/4 collections completed | 4 backed up | 1 skipped
                  Backups are in \(backupDirectory.path)

                """)
                #expect(try await db["a"].count() == 20)
                for name in ["b", "c", "d"] {
                    #expect(try await db[name].count() == 0)
                    #expect(try readBSONFile(at: backupDirectory.appending(path: "\(name).bson")).count == 20)
                }
            }
        }
    }

    /// Catches: "skipped" showing for migrate, where there's never a file to compare against.
    @Test("Without files to compare, the line leaves out skipped")
    func noSkippedWithoutFiles() async throws {
        try await withTemporaryDirectory { directory in
            try await TestMongo.withTemporaryDatabase { db in
                try await db["a"].insert(["_id": 1])
                let pipeline = RecordingPipeline()
                let plan = CollisionPlan(
                    collectionNames: ["a"], strategy: .dumpBeforeImport, backupDirectory: directory
                )

                try await plan.prepare(in: db, status: StatusLine(pipeline: pipeline, isInteractive: false))

                #expect(pipeline.output.hasPrefix("✔︎ 1/1 collections completed | 1 backed up\n"))
            }
        }
    }

    /// Catches: `Users` and `users` sharing one backup file on this disk, so the second backup replaces the first
    /// just before that collection is cleared, losing it.
    @Test(
        "Collections that differ only by case each get their own backup, and restore under their own names",
        .enabled(
            if: !isCaseSensitiveVolume(at: FileManager.default.temporaryDirectory),
            "Only applies where the disk doesn't tell upper and lower case apart"
        )
    )
    func caseClashBackupsKeptApart() async throws {
        try await withTemporaryDirectory { directory in
            try await TestMongo.withTemporaryDatabase { db in
                try await db["Users"].insertMany(SampleDocuments.numbered(1...500))
                try await db["users"].insertMany(SampleDocuments.numbered(1...300))
                let plan = CollisionPlan(
                    collectionNames: ["Users", "users"], strategy: .dumpBeforeImport, backupDirectory: directory
                )
                let slots = try await ClientSlots.open(count: 2, reusing: db, uri: TestMongo.uri)

                try await plan.prepare(
                    in: (slots: slots, database: db.name), status: StatusLine(pipeline: RecordingPipeline())
                )
                await slots.disconnect()

                #expect(try readBSONFile(at: directory.appending(path: "Users.bson")).count == 500)
                #expect(try readBSONFile(at: directory.appending(path: "case-2/users.bson")).count == 300)

                // What `mport import <backup folder>` would offer: both files, each going back to its own collection.
                let restorable = try Import.parse([]).findBSONFiles(in: directory)
                #expect(Set(restorable.map(\.collectionName)) == ["Users", "users"])
            }
        }
    }
}

@Suite("Backups: file names")
struct BackupFileNameTests {

    private let directory = URL(filePath: "/backups", directoryHint: .isDirectory)

    /// Catches: names that differ only by case sharing a file where the disk can't tell them apart.
    @Test("On a case-insensitive disk, later names in a case-only clash go into their own subfolders")
    func clashesGetSubfolders() {
        let files = backupFiles(for: ["USERS", "Users", "orders", "users"], in: directory, caseSensitive: false)

        #expect(files["USERS"]?.path == "/backups/USERS.bson")
        #expect(files["Users"]?.path == "/backups/case-2/Users.bson")
        #expect(files["orders"]?.path == "/backups/orders.bson")
        #expect(files["users"]?.path == "/backups/case-3/users.bson")
    }

    /// Catches: subfolders being used where the disk already keeps `Users.bson` and `users.bson` apart.
    @Test("On a case-sensitive disk, every backup sits directly in the folder")
    func noSubfoldersWhenCaseSensitive() {
        let files = backupFiles(for: ["Users", "users"], in: directory, caseSensitive: true)

        #expect(files["Users"]?.path == "/backups/Users.bson")
        #expect(files["users"]?.path == "/backups/users.bson")
    }
}
