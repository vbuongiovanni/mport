//
//  CollisionPlan.swift
//  Created by Claude on 9/18/26, at Vince's request.
//
//  Target collections that already exist, and what to do about them: backing them up (concurrently, with one
//  status line), clearing them, and leaving alone any whose backup is identical to the file being imported.
//  Moved out of CollectionWriting.swift on 9/29/26.
//

import CryptoKit
import Foundation
import MongoKitten
import Noora

/// Which target collections already exist, and what to do about them.
struct CollisionPlan {
    let collectionNames: Set<String>
    let strategy: CollisionResolution
    /// Only used by `dump-before-import`.
    let backupDirectory: URL

    /// Duplicate `_id`s are replaced under `overwrite`, and skipped under every other strategy.
    var replacesDuplicates: Bool {
        strategy == .overwrite
    }

    /// Looks for target names that already exist in `db`. Only when some do does it use `flagValue`
    /// (`--collision-resolution`) or, if that's missing or invalid, ask the user for a strategy.
    static func resolve(
        for targetNames: [String],
        in db: MongoDatabase,
        flagValue: String?,
        backupDirectory: URL
    ) async throws -> CollisionPlan {
        let existingNames = Set(try await db.listCollections().map(\.name))
        let collisions = Set(targetNames).intersection(existingNames)

        guard !collisions.isEmpty else {
            return CollisionPlan(collectionNames: [], strategy: .skip, backupDirectory: backupDirectory)
        }

        if let strategy = CollisionResolution(rawValue: flagValue ?? "") {
            return CollisionPlan(collectionNames: collisions, strategy: strategy, backupDirectory: backupDirectory)
        }

        let selectedStrategy = Noora().singleChoicePrompt(
            title: "Collision Strategy",
            question: "Select a Strategy",
            options: CollisionResolution.allCases.map(\.rawValue),
            description: "\(collisions.count) target collection(s) already exist",
            collapseOnSelection: true,
            autoselectSingleChoice: true,
            renderer: WrapAwareRenderer()
        )
        return CollisionPlan(
            collectionNames: collisions,
            strategy: CollisionResolution(rawValue: selectedStrategy) ?? .skip,
            backupDirectory: backupDirectory
        )
    }

    /// The same plan without its backup step, for `--skip-backup`: `dump-before-import` becomes
    /// `clear-before-import`. Every other strategy is returned unchanged, since none of them back anything up.
    func skippingBackup() -> CollisionPlan {
        guard strategy == .dumpBeforeImport else {
            return self
        }
        return CollisionPlan(
            collectionNames: collectionNames,
            strategy: .clearBeforeImport,
            backupDirectory: backupDirectory
        )
    }

    /// Runs the strategy's preparation step on each colliding collection: back it up and/or clear it.
    /// Done once per collection before anything is written, so two sources renamed into the same
    /// collection can't clear each other's documents.
    ///
    /// Under `dump-before-import`, a collection whose backup comes out byte-for-byte identical to the file about to
    /// be imported into it (`sourceFiles`, by collection name) already holds exactly that file's documents. It's
    /// left as it is rather than cleared, and its name is returned so the caller can skip that import.
    ///
    /// Collections are prepared `target.slots.count` at a time, each through its slot's own client, like the rest of
    /// the run. Backups are reported on one `status` line with running counts, e.g.
    /// `4/10 collections completed | 4 backed up | 1 skipped`, followed by where the backups were written. If one
    /// fails, nothing new starts, the ones underway finish, and this throws before anything is imported.
    @discardableResult
    func prepare(
        in target: (slots: ClientSlots, database: String),
        skippingIfIdenticalTo sourceFiles: [String: URL] = [:],
        status: StatusLine = StatusLine()
    ) async throws -> Set<String> {
        let names = collectionNames.sorted()
        guard strategy == .dumpBeforeImport || strategy == .clearBeforeImport, !names.isEmpty else {
            return []
        }
        let backupDirectory = backupDirectory
        let isBackingUp = strategy == .dumpBeforeImport
        var files: [String: URL] = [:]
        if isBackingUp {
            try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            files = backupFiles(
                for: names, in: backupDirectory, caseSensitive: isCaseSensitiveVolume(at: backupDirectory)
            )
        }
        let backupFileForName = files

        // Every collection has its own backup file (case clashes go in subfolders), so none of them have to wait on
        // another. Keying lanes by file path, compared without case, keeps that true even if two paths ever matched.
        let lanes = makeLanes(destinationKeys: names.map { (backupFileForName[$0]?.path ?? $0).lowercased() })
        let tally = BackupTally(total: names.count, countsSkipped: !sourceFiles.isEmpty, status: status)
        if isBackingUp {
            await tally.start()
        }

        let outcomes = await runConcurrently(items: names, lanes: lanes, limit: target.slots.count) { _, name, slot in
            let collection = target.slots.database(named: target.database, slot: slot)[name]
            guard let backupFile = backupFileForName[name] else {
                try await collection.deleteAll(where: [:])
                return false
            }
            try await backUp(collection, to: backupFile)
            let isUnchanged = try sourceFiles[name].map { try filesMatch($0, backupFile) } ?? false
            if !isUnchanged {
                try await collection.deleteAll(where: [:])
            }
            await tally.record(unchanged: isUnchanged)
            return isUnchanged
        }

        let unchangedFlags = try completedOutputs(of: outcomes, labels: names) { $0 ? "unchanged" : "prepared" }
        if isBackingUp {
            await tally.finish(backupDirectory: backupDirectory)
        }
        return Set(zip(names, unchangedFlags).filter(\.1).map(\.0))
    }

    /// `prepare` one collection at a time on a client that's already open.
    @discardableResult
    func prepare(
        in db: MongoDatabase,
        skippingIfIdenticalTo sourceFiles: [String: URL] = [:],
        status: StatusLine = StatusLine()
    ) async throws -> Set<String> {
        try await prepare(
            in: (slots: .single(db), database: db.name), skippingIfIdenticalTo: sourceFiles, status: status
        )
    }

    var explanation: String {
        switch strategy {
        case .dumpBeforeImport:
            "Collections marked with an asterisk will be backed up, then cleared, before anything is written."
        case .clearBeforeImport: "Collections marked with an asterisk will be cleared before anything is written."
        case .overwrite: "In collections marked with an asterisk, documents with a matching _id will be overwritten."
        case .skip: "In collections marked with an asterisk, documents with a matching _id will be skipped."
        }
    }
}

/// Where `dump-before-import` writes backups: `<root>/.mport-backups/<connection>/<database>/<timestamp>/`.
/// The leading dot keeps the folder out of `import`'s file list.
func backupDirectory(under root: URL, connection: String, database: String) -> URL {
    root
        .appending(path: ".mport-backups")
        .appending(path: connection)
        .appending(path: database)
        .appending(path: Date.now.formatted(.iso8601.timeSeparator(.omitted)))
}

/// The running counts on the backup status line. Backups run concurrently, so the counts live in an actor, which is
/// also the one place that redraws the line.
private actor BackupTally {
    private let total: Int
    /// "skipped" only means something when there are files to compare against, i.e. for `import`.
    private let countsSkipped: Bool
    private let status: StatusLine
    private var backedUp = 0
    private var skipped = 0

    init(total: Int, countsSkipped: Bool, status: StatusLine) {
        self.total = total
        self.countsSkipped = countsSkipped
        self.status = status
    }

    func start() {
        status.update("◌ \(counts)")
    }

    func record(unchanged: Bool) {
        backedUp += 1
        if unchanged {
            skipped += 1
        }
        status.update("◌ \(counts)")
    }

    func finish(backupDirectory: URL) {
        status.finish("✔︎ \(counts)\n  Backups are in \(backupDirectory.path)")
    }

    private var counts: String {
        var parts = ["\(backedUp)/\(total) collections completed", "\(backedUp) backed up"]
        if countsSkipped {
            parts.append("\(skipped) skipped")
        }
        return parts.joined(separator: " | ")
    }
}

/// Where each collection's backup goes: normally `<directory>/<name>.bson`.
///
/// A disk that doesn't tell upper and lower case apart (the macOS default) would treat `Users.bson` and
/// `users.bson` as one file, so one backup would replace the other. There, every name after the first in such a
/// group goes into its own subfolder: `<directory>/case-2/users.bson`, then `case-3/…`. File names keep each
/// collection's exact name, and `mport import` finds files in subfolders, so `mport import <backup folder>` still
/// restores every collection under its own name.
func backupFiles(for names: [String], in directory: URL, caseSensitive: Bool) -> [String: URL] {
    var files: [String: URL] = [:]
    var countForKey: [String: Int] = [:]
    for name in names {
        let key = caseSensitive ? name : name.lowercased()
        let occurrence = (countForKey[key] ?? 0) + 1
        countForKey[key] = occurrence
        let folder = occurrence == 1
            ? directory
            : directory.appending(path: "case-\(occurrence)", directoryHint: .isDirectory)
        files[name] = folder.appending(component: "\(name).bson")
    }
    return files
}

/// Writes every document in `collection` to `file`, in the same layout `export` produces, so a backup can be
/// restored with `mport import <backup folder>`.
private func backUp(_ collection: MongoCollection, to file: URL) async throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)

    guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
        throw CLIError.outputSteamFailure
    }
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }

    // Documents are collected into chunks of about 1 MB and each chunk written at once, rather than one write per
    // document, which is what made backing up a collection of many small documents slow.
    var chunk = Data()
    chunk.reserveCapacity(backupChunkSize + 64 * 1024)
    for try await document in collection.find() {
        chunk.append(document.makeData())
        if chunk.count >= backupChunkSize {
            try handle.write(contentsOf: chunk)
            chunk.removeAll(keepingCapacity: true)
        }
    }
    if !chunk.isEmpty {
        try handle.write(contentsOf: chunk)
    }
}

private let backupChunkSize = 1 << 20

/// Whether two files hold exactly the same bytes. Sizes are compared first, and only files of equal size are hashed
/// (SHA-256, read 1 MB at a time, so a large dump never has to fit in memory).
///
/// It's a byte comparison, so the same documents in a different order count as different. That errs on the safe
/// side: the import simply goes ahead as it would have anyway.
func filesMatch(_ first: URL, _ second: URL) throws -> Bool {
    func size(of url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
    }
    guard try size(of: first) == size(of: second) else {
        return false
    }
    return try sha256(of: first) == sha256(of: second)
}

private func sha256(of url: URL) throws -> SHA256.Digest {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize()
}
