//
//  BSONFileReader.swift
//  Created by Claude on 9/18/26, at Vince's request.
//

import Foundation
import MongoKitten

/// Reads a `.bson` dump one document at a time, so a large file never has to fit in memory.
///
/// A dump (from `mport export --format bson` or `mongodump`) is just BSON documents laid end to end.
/// Every document begins with its own total size as a little-endian `Int32`, which includes those 4 bytes,
/// so reading is: take 4 bytes, learn the size, take the rest, repeat until the file ends.
///
/// It's an `AsyncSequence`, like a MongoKitten `find()` cursor, so `writeDocuments` can take either one.
/// The sequence is its own iterator, and the plain throwing `next()` below satisfies the protocol's
/// `async throws` requirement: a synchronous function is allowed to stand in for an async one.
struct BSONFileReader: AsyncSequence, AsyncIteratorProtocol {
    let url: URL
    private let handle: FileHandle

    init(url: URL) throws {
        self.url = url
        self.handle = try FileHandle(forReadingFrom: url)
    }

    func makeAsyncIterator() -> BSONFileReader {
        self
    }

    /// Returns the next document, or `nil` once the whole file has been read.
    func next() throws -> Document? {
        guard let prefix = try handle.read(upToCount: 4), !prefix.isEmpty else {
            try handle.close()
            return nil
        }
        guard prefix.count == 4 else {
            throw CLIError.malformedBSON(file: url.lastPathComponent)
        }

        let length = Int(prefix.withUnsafeBytes { Int32(littleEndian: $0.loadUnaligned(as: Int32.self)) })
        // 5 bytes is the smallest legal document: the length prefix plus the trailing null byte.
        guard length >= 5 else {
            throw CLIError.malformedBSON(file: url.lastPathComponent)
        }

        guard let body = try handle.read(upToCount: length - 4), body.count == length - 4 else {
            throw CLIError.malformedBSON(file: url.lastPathComponent)
        }

        let document = Document(data: prefix + body)
        guard document.validate().isValid else {
            throw CLIError.malformedBSON(file: url.lastPathComponent)
        }
        return document
    }
}
