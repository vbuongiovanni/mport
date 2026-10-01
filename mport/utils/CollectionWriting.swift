//
//  CollectionWriting.swift
//  Created by Claude on 9/18/26, at Vince's request.
//
//  The machinery shared by `import` (BSON files → collections) and `migrate` (collections → collections):
//  choosing target collection names, the preflight plan, and streaming documents into a collection in batches.
//  Collisions live in CollisionPlan.swift.
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

/// Documents are sent to MongoDB in batches of up to `batchSize` documents and `maxBatchBytes` bytes. MongoKitten sends
/// a batch inside the insert command itself, and MongoDB rejects a command over 16MB, so the byte cap keeps every
/// batch well under that. A single document over the cap (up to MongoDB's own 16MB limit) is sent on its own.
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
    progress: (Int) async -> Void
) async throws -> WriteResult where Documents.Element == Document {
    var result = WriteResult()
    var batch: [Document] = []
    var batchBytes = 0
    var documentsWritten = 0

    func sendBatch() async throws {
        result += try await insertBatch(batch, into: collection, replacingDuplicates: replacingDuplicates)
        documentsWritten += batch.count
        batch.removeAll(keepingCapacity: true)
        batchBytes = 0
        await progress(documentsWritten)
    }

    for try await document in documents {
        let documentBytes = document.makeByteBuffer().readableBytes
        // Send what's collected before this document would take the batch past the byte cap, rather than after:
        // one big document added to an almost-full batch is how an insert ends up over MongoDB's 16MB limit.
        if !batch.isEmpty && batchBytes + documentBytes > maxBatchBytes {
            try await sendBatch()
        }
        batch.append(document)
        batchBytes += documentBytes

        if batch.count >= batchSize {
            try await sendBatch()
        }
    }

    if !batch.isEmpty {
        try await sendBatch()
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
