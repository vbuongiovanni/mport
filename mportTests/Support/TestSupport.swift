//
//  TestSupport.swift
//  Created by Claude on 9/18/26, at Vince's request.
//
//  Shared helpers for the test suite. The mportTests target compiles the app's own sources, so everything
//  internal in `mport/` is directly visible here without `@testable import`.
//

import Foundation
import MongoKitten
import Noora
import Synchronization

// MARK: - Files

/// Creates a fresh, empty directory, runs `body` with it, and deletes it afterwards, even if `body` throws.
func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async rethrows -> T {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "mportTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

/// Writes `documents` end to end, the same layout `export --format bson` and `mongodump` produce.
func writeBSONFile(_ documents: [Document], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = documents.reduce(into: Data()) { $0.append($1.makeData()) }
    try data.write(to: url)
}

/// Writes raw bytes, for the corrupt-file cases.
func writeBytes(_ bytes: [UInt8], to url: URL) throws {
    try Data(bytes).write(to: url)
}

/// Reads every document from a BSON dump.
func readBSONFile(at url: URL) throws -> [Document] {
    let reader = try BSONFileReader(url: url)
    var documents: [Document] = []
    while let document = try reader.next() {
        documents.append(document)
    }
    return documents
}

// MARK: - Documents

enum SampleDocuments {
    /// One document per `_id`, covering every BSON type mport has to carry through untouched.
    static func mixedTypes(count: Int) -> [Document] {
        (1...count).map(mixedTypeDocument)
    }

    /// Built one field at a time: a single literal this varied is too much for the type checker.
    private static func mixedTypeDocument(id: Int) -> Document {
        let tags: Document = ["a", "b"]
        let nested: Document = ["depth": Int32(2), "tags": tags]
        let list: Document = [Int32(1), "two", 3.0]

        var document = Document()
        document["_id"] = id
        document["name"] = "user-\(id)"
        document["int32"] = Int32(id)
        document["int64"] = id * 1_000_000_000
        document["double"] = Double(id) + 0.25
        document["bool"] = id.isMultiple(of: 2)
        document["null"] = Null()
        document["date"] = Date(timeIntervalSince1970: 1_600_000_000 + Double(id))
        document["objectId"] = ObjectId()
        document["binary"] = Binary(buffer: ByteBuffer(bytes: [0x01, 0x02, UInt8(id % 256)]))
        document["nested"] = nested
        document["list"] = list
        return document
    }

    /// Small documents, for tests that only care about how many get written.
    static func numbered(_ range: ClosedRange<Int>) -> [Document] {
        range.map { ["_id": $0, "n": $0] }
    }
}

/// Wraps an array as an `AsyncSequence`, the shape `writeDocuments` consumes.
func asyncSequence(_ documents: [Document]) -> AsyncStream<Document> {
    AsyncStream { continuation in
        documents.forEach { continuation.yield($0) }
        continuation.finish()
    }
}

// MARK: - Terminal output

/// Records everything a Noora renderer writes, instead of printing it.
///
/// `StandardPipelining` requires `Sendable`, so the recorded text lives in a `Mutex`: that makes the class
/// genuinely thread-safe, rather than silencing the compiler with `@unchecked Sendable`.
final class RecordingPipeline: StandardPipelining {
    private let recorded = Mutex<[String]>([])

    var output: String {
        recorded.withLock { $0.joined() }
    }

    func write(content: String) {
        recorded.withLock { $0.append(content) }
    }

    func reset() {
        recorded.withLock { $0.removeAll() }
    }
}

// MARK: - MongoDB

/// The MongoDB the integration tests run against. Override with `MPORT_TEST_MONGO_URI`.
enum TestMongo {
    static let uri = ProcessInfo.processInfo.environment["MPORT_TEST_MONGO_URI"]
        ?? "mongodb://root:password@localhost:27017/admin?authSource=admin"

    /// Integration suites are skipped, not failed, when nothing is listening, so the unit tests still run
    /// on a machine without Docker. Checked once per test run with a plain TCP connect.
    static let isAvailable: Bool = {
        let components = URLComponents(string: uri)
        return isAcceptingConnections(host: components?.host ?? "localhost", port: components?.port ?? 27017)
    }()

    /// Runs `body` against a brand-new database with a unique name, then drops it, even if `body` throws.
    /// Every test gets its own database, so the suites can safely run in parallel.
    static func withTemporaryDatabase(_ body: (MongoDatabase) async throws -> Void) async throws {
        let client = try await MongoDatabase.connect(to: uri)
        let database = client.pool["mport_test_\(UUID().uuidString.prefix(8).lowercased())"]

        do {
            try await body(database)
        } catch {
            try? await database.drop()
            await (client.pool as? MongoCluster)?.disconnect()
            throw error
        }
        try await database.drop()
        await (client.pool as? MongoCluster)?.disconnect()
    }

    private static func isAcceptingConnections(host: String, port: Int) -> Bool {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var addresses: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &addresses) == 0 else {
            return false
        }
        defer { freeaddrinfo(addresses) }

        var candidate = addresses
        while let address = candidate {
            let info = address.pointee
            let socketDescriptor = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            if socketDescriptor >= 0 {
                defer { close(socketDescriptor) }
                if connect(socketDescriptor, info.ai_addr, info.ai_addrlen) == 0 {
                    return true
                }
            }
            candidate = info.ai_next
        }
        return false
    }
}

extension MongoCollection {
    /// Every document, in `_id` order, so results can be compared against the input.
    func allDocuments() async throws -> [Document] {
        try await find().sort(["_id": 1]).drain()
    }
}
