//
//  CollectionWriting.swift
//  Created by Claude on 9/18/26, at Vince's request.
//
//  The machinery shared by `import` (BSON files → collections) and `migrate` (collections → collections):
//  choosing target collection names, detecting and handling collisions, the preflight plan, and streaming
//  documents into a collection in batches.
//

import Foundation
import MongoKitten
import Noora

/// Something whose documents end up in a named collection: a BSON file for `import`, a source collection
/// for `migrate`. Lets the naming prompts and the preflight plan work with either.
protocol CollectionMapping {
    /// Where the documents come from, as shown in prompts and the plan (a file path, or a collection name).
    var displayName: String { get }
    /// The collection the documents are written into. Starts as a default that the user can rename.
    var collectionName: String { get set }
}

/// Splits `--collection-names a,b --collection-names c` into `["a", "b", "c"]`.
func parseNameList(_ values: [String]) -> [String] {
    values
        .flatMap { $0.split(separator: ",") }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

// MARK: - Naming

/// Offers to rename target collections. Only the items the user picks get a text prompt, so accepting the
/// defaults is a single keypress. `defaultNaming` explains what the defaults are.
func nameCollections<Item: CollectionMapping>(for items: [Item], defaultNaming: String) -> [Item] {
    let wantsRename = Noora().yesOrNoChoicePrompt(
        title: "Collection Names",
        question: "Rename any of the target collections?",
        defaultAnswer: false,
        description: TerminalText(stringLiteral: defaultNaming),
        collapseOnSelection: true,
        renderer: WrapAwareRenderer()
    )
    guard wantsRename else {
        return items
    }

    let namesToChange = items.count == 1 ? items.map(\.displayName) : Noora().multipleChoicePrompt(
        title: "Rename",
        question: "Which ones should go into a differently named collection?",
        options: items.map(\.displayName),
        collapseOnSelection: true,
        filterMode: .toggleable,
        minLimit: .limited(count: 1, errorMessage: "Please select at least 1"),
        renderer: WrapAwareRenderer()
    )

    let collectionNameRule = RegexValidationRule(
        pattern: #"^(?!system\.)[^$\s][^$]*$"#,
        error: CollectionNameError(
            message: "Collection names can't be empty, start with a space or 'system.', or contain '$'"
        )
    )

    var renamed = items
    for index in renamed.indices where namesToChange.contains(renamed[index].displayName) {
        renamed[index].collectionName = Noora().textPrompt(
            title: "Collection Name",
            prompt: "Collection for \(renamed[index].displayName):",
            defaultValue: renamed[index].collectionName,
            collapseOnAnswer: true,
            renderer: WrapAwareRenderer(),
            validationRules: [collectionNameRule]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return renamed
}

private struct CollectionNameError: ValidatableError {
    let message: String
}

// MARK: - Collisions

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

    /// Runs the strategy's preparation step on each colliding collection: back it up and/or clear it.
    /// Done once per collection before anything is written, so two sources renamed into the same
    /// collection can't clear each other's documents.
    func prepare(in db: MongoDatabase) async throws {
        for name in collectionNames.sorted() {
            let collection = db[name]
            switch strategy {
            case .dumpBeforeImport:
                let backupFile = try await backUp(collection, to: backupDirectory)
                print("Backed up '\(name)' to \(backupFile.path)")
                try await collection.deleteAll(where: [:])
            case .clearBeforeImport:
                try await collection.deleteAll(where: [:])
            case .overwrite, .skip:
                break
            }
        }
    }

    fileprivate var explanation: String {
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

/// Writes every document in `collection` to `<directory>/<name>.bson`, in the same layout `export` produces,
/// so a backup can be restored with `mport import <backup folder>`.
private func backUp(_ collection: MongoCollection, to directory: URL) async throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(component: "\(collection.name).bson")

    guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
        throw CLIError.outputSteamFailure
    }
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }

    for try await document in collection.find() {
        try handle.write(contentsOf: document.makeData())
    }
    return file
}

// MARK: - Preflight plan

/// Prints the preflight plan and asks the user to confirm it.
/// - Parameters:
///   - details: Header lines, such as the connection and database being written to.
///   - heading: The line above the list of items, e.g. "Collections To Import:".
///   - action: The noun used in the confirmation question, e.g. "import".
func confirmPlan<Item: CollectionMapping>(
    details: [String],
    heading: String,
    items: [Item],
    collisions: CollisionPlan,
    action: String
) -> Bool {
    var collectionMessage = ""
    var collisionMessage = ""
    for item in items {
        let marker = collisions.collectionNames.contains(item.collectionName) ? "*" : ""
        collectionMessage += " └──> \(item.displayName) → \(item.collectionName)\(marker)\n"
    }
    if !collisions.collectionNames.isEmpty {
        collisionMessage += "\n\(collisions.explanation)\n"
        if collisions.strategy == .dumpBeforeImport {
            collisionMessage += "Backups will be written to \(collisions.backupDirectory.path)\n"
        }
    }

    Noora().info("""
    ───────────────────────────────
    ────── Preflight Plan ─────────
    ───────────────────────────────
    \(details.joined(separator: "\n"))
    \(heading)
    \(collectionMessage)
    \(collisionMessage)
    """
    )

    return Noora().yesOrNoChoicePrompt(
        title: "Confirm",
        question: "Proceed with the \(action)?",
        collapseOnSelection: true,
        renderer: WrapAwareRenderer()
    )
}

// MARK: - Writing documents

/// Documents are sent to MongoDB in batches; a batch is flushed when it hits either limit.
/// The byte cap keeps a batch of large documents well under MongoDB's 48MB message limit.
private let batchSize = 1_000
private let maxBatchBytes = 8 * 1024 * 1024
private let duplicateKeyErrorCode = 11000

struct WriteResult {
    var inserted = 0
    var replaced = 0
    var skipped = 0

    /// Documents that ended up in the target collection, whether newly inserted or replacing an old one.
    var written: Int {
        inserted + replaced
    }

    var summary: String {
        var parts = ["\(inserted) inserted"]
        if replaced > 0 { parts.append("\(replaced) replaced") }
        if skipped > 0 { parts.append("\(skipped) skipped (duplicate _id)") }
        return parts.joined(separator: ", ")
    }

    static func += (lhs: inout WriteResult, rhs: WriteResult) {
        lhs.inserted += rhs.inserted
        lhs.replaced += rhs.replaced
        lhs.skipped += rhs.skipped
    }
}

/// Streams `documents` into `collection` in batches, calling `progress` with the running count after each one.
///
/// Any async sequence of documents works, which is what lets `import` and `migrate` share this: import
/// passes a `BSONFileReader`, and migrate passes a `find()` cursor on the source collection.
func writeDocuments<Documents: AsyncSequence>(
    _ documents: Documents,
    into collection: MongoCollection,
    replacingDuplicates: Bool,
    progress: (Int) -> Void
) async throws -> WriteResult where Documents.Element == Document {
    var result = WriteResult()
    var batch: [Document] = []
    var batchBytes = 0
    var documentsRead = 0

    for try await document in documents {
        batch.append(document)
        batchBytes += document.makeByteBuffer().readableBytes
        documentsRead += 1

        if batch.count >= batchSize || batchBytes >= maxBatchBytes {
            result += try await insertBatch(batch, into: collection, replacingDuplicates: replacingDuplicates)
            batch.removeAll(keepingCapacity: true)
            batchBytes = 0
            progress(documentsRead)
        }
    }

    if !batch.isEmpty {
        result += try await insertBatch(batch, into: collection, replacingDuplicates: replacingDuplicates)
        progress(documentsRead)
    }
    return result
}

private func insertBatch(
    _ batch: [Document],
    into collection: MongoCollection,
    replacingDuplicates: Bool
) async throws -> WriteResult {
    let reply = try await collection.insertManyUnordered(batch)
    var result = WriteResult(inserted: reply.insertCount)

    for writeError in reply.writeErrors ?? [] {
        guard writeError.code == duplicateKeyErrorCode else {
            throw CLIError.importFailed(collection: collection.name, reason: writeError.message)
        }

        let document = batch[writeError.index]
        guard replacingDuplicates, let id = document["_id"] else {
            result.skipped += 1
            continue
        }

        // A full document with no $-operators replaces whatever currently has this _id.
        let upsertReply = try await collection.upsert(document, where: ["_id": id])
        if let upsertError = upsertReply.writeErrors?.first {
            throw CLIError.importFailed(collection: collection.name, reason: upsertError.message)
        }
        result.replaced += 1
    }
    return result
}
