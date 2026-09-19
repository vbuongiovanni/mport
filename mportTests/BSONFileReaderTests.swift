//
//  BSONFileReaderTests.swift
//  Created by Claude on 9/18/26, at Vince's request.
//

import Foundation
import MongoKitten
import Testing

@Suite("BSONFileReader")
struct BSONFileReaderTests {

    /// Catches: any drift in how documents are split apart, or any BSON type being altered on the way through.
    @Test("Reads back exactly the documents that were written, every BSON type intact")
    func roundTripsMixedTypes() async throws {
        try await withTemporaryDirectory { directory in
            let file = directory.appending(path: "users.bson")
            let documents = SampleDocuments.mixedTypes(count: 25)
            try writeBSONFile(documents, to: file)

            #expect(try readBSONFile(at: file) == documents)
        }
    }

    /// Catches: the `AsyncSequence` conformance that `writeDocuments` relies on breaking or skipping documents.
    @Test("Works as an AsyncSequence with for-try-await")
    func iteratesAsAsyncSequence() async throws {
        try await withTemporaryDirectory { directory in
            let file = directory.appending(path: "orders.bson")
            try writeBSONFile(SampleDocuments.numbered(1...300), to: file)

            var ids: [Int] = []
            for try await document in try BSONFileReader(url: file) {
                ids.append(try #require(document["_id"] as? Int))
            }
            #expect(ids == Array(1...300))
        }
    }

    /// Catches: an empty collection's dump (mongodump writes a 0-byte file) being treated as corrupt.
    @Test("An empty file yields no documents")
    func emptyFileYieldsNothing() async throws {
        try await withTemporaryDirectory { directory in
            let file = directory.appending(path: "empty.bson")
            try writeBytes([], to: file)

            #expect(try readBSONFile(at: file).isEmpty)
        }
    }

    struct CorruptFile: CustomTestStringConvertible, Sendable {
        let description: String
        let bytes: @Sendable ([UInt8]) -> [UInt8]

        var testDescription: String { description }
    }

    static let corruptFiles: [CorruptFile] = [
        CorruptFile(description: "cut off inside the length prefix") { Array($0.prefix(2)) },
        CorruptFile(description: "cut off inside the document body") { Array($0.dropLast(3)) },
        CorruptFile(description: "a length prefix smaller than any legal document") { _ in [4, 0, 0, 0, 0] },
        CorruptFile(description: "a valid length around garbage contents") { _ in [9, 0, 0, 0, 0xEE, 0x61, 0, 1, 0] },
        CorruptFile(description: "a good document followed by a truncated one") { $0 + Array($0.prefix(6)) }
    ]

    /// Catches: a damaged file being silently half-imported, or crashing the process, instead of a clear error.
    @Test("Corrupt files throw malformedBSON naming the file", arguments: corruptFiles)
    func corruptFilesThrow(_ corruption: CorruptFile) async throws {
        try await withTemporaryDirectory { directory in
            let file = directory.appending(path: "broken.bson")
            let valid = [UInt8](SampleDocuments.mixedTypes(count: 1)[0].makeData())
            try writeBytes(corruption.bytes(valid), to: file)

            let error = #expect(throws: CLIError.self) {
                try readBSONFile(at: file)
            }
            guard case .malformedBSON(let fileName)? = error else {
                Issue.record("Expected malformedBSON, got \(String(describing: error))")
                return
            }
            #expect(fileName == "broken.bson")
        }
    }

    /// Catches: a missing file being reported as an empty import rather than an error.
    @Test("A missing file throws when the reader is created")
    func missingFileThrows() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "does-not-exist-\(UUID()).bson")
        #expect(throws: (any Error).self) {
            try BSONFileReader(url: missing)
        }
    }
}
