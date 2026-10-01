//
//  ClientSlotsTests.swift
//  Created by Claude on 9/29/26, at Vince's request.
//

import Foundation
import MongoKitten
import Testing

@Suite(
    "Client slots",
    .tags(.integration),
    .enabled(if: TestMongo.isAvailable, "Needs a MongoDB at MPORT_TEST_MONGO_URI (default localhost:27017)"),
    .timeLimit(.minutes(1))
)
struct ClientSlotsTests {

    /// Catches: slots sharing one client, which would put every concurrent collection on a single connection.
    @Test("Each slot gets its own client, and each one can query the database")
    func opensDistinctClients() async throws {
        try await TestMongo.withTemporaryDatabase { db in
            try await db["items"].insert(["_id": 1])

            let slots = try await ClientSlots.open(count: 3, reusing: db, uri: TestMongo.uri)
            let databases = (0..<slots.count).map { slots.database(named: db.name, slot: $0) }

            #expect(slots.count == 3)
            #expect(Set(databases.map { ObjectIdentifier($0.pool as AnyObject) }).count == 3)
            for database in databases {
                #expect(try await database["items"].count() == 1)
            }
            await slots.disconnect()
        }
    }

    /// Catches: a refused connection surfacing later, halfway through a run, instead of before anything is written.
    @Test("A connection that can't be opened fails straight away with connectionFailed")
    func refusedConnectionFails() async throws {
        try await TestMongo.withTemporaryDatabase { db in
            let error = await #expect(throws: CLIError.self) {
                let refused = "mongodb://localhost:1/admin?connectTimeoutMS=500"
                return try await ClientSlots.open(count: 2, reusing: db, uri: refused)
            }
            guard case .connectionFailed = error else {
                Issue.record("Expected .connectionFailed, got \(String(describing: error))")
                return
            }
        }
    }
}
