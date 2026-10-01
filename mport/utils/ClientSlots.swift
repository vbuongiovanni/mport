//
//  ClientSlots.swift
//  Created by Claude on 9/29/26, at Vince's request.
//

import MongoClient
import MongoKitten

/// One MongoDB client per concurrency slot, all connected to the same server.
///
/// A MongoKitten client sends every operation over a single connection (the `?maxConnections=` URI option is
/// parsed but never used), and MongoDB runs one operation per connection at a time. Slots sharing a client would
/// mostly wait on each other, so each slot gets its own.
struct ClientSlots: Sendable {
    private let clients: [MongoDatabase]

    var count: Int {
        clients.count
    }

    /// Slot 0 is `existing`, the client the command already opened to list databases and collections. The other
    /// `count - 1` are opened here, all at once. If any of them can't connect, the ones that did are closed and
    /// this throws `CLIError.connectionFailed`, before anything has been written.
    static func open(count: Int, reusing existing: MongoDatabase, uri: String) async throws -> ClientSlots {
        let extraCount = max(count, 1) - 1
        let extras = try await withThrowingTaskGroup(of: MongoDatabase.self) { group in
            for _ in 0..<extraCount {
                group.addTask {
                    try await MongoDatabase.connect(to: uri)
                }
            }

            var opened: [MongoDatabase] = []
            do {
                for try await client in group {
                    opened.append(client)
                }
            } catch {
                group.cancelAll()
                for client in opened {
                    await Self.disconnect(client)
                }
                throw CLIError.connectionFailed
            }
            return opened
        }
        return ClientSlots(clients: [existing] + extras)
    }

    /// One slot on a client that's already open: for work that runs one collection at a time, and for tests.
    static func single(_ client: MongoDatabase) -> ClientSlots {
        ClientSlots(clients: [client])
    }

    /// The database called `name`, reached through `slot`'s own client.
    func database(named name: String, slot: Int) -> MongoDatabase {
        clients[slot].pool[name]
    }

    /// Closes the clients this opened. Slot 0 belongs to the command, which closes it (or exits) itself.
    func disconnect() async {
        for client in clients.dropFirst() {
            await Self.disconnect(client)
        }
    }

    private static func disconnect(_ client: MongoDatabase) async {
        await (client.pool as? MongoCluster)?.disconnect()
    }
}
