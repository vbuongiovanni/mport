//
//  CollisionPlanTests.swift
//  Created by Claude on 9/18/26, at Vince's request.
//
//  What happens to target collections that already exist. Only the non-interactive paths are covered:
//  an invalid or missing --collision-resolution falls through to a Noora prompt.
//

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
