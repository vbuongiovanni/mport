//
//  ConcurrencyTests.swift
//  Created by Claude on 9/29/26, at Vince's request.
//

import Testing

@Suite("Concurrency limit")
struct ConcurrencyTests {

    /// Catches: the default drifting from 4, the value mongodump and mongorestore use.
    @Test("With no flag and nothing saved, the limit is 4")
    func defaultsToFour() {
        #expect(Concurrency.resolve(flag: nil, saved: nil) { _ in Issue.record("unexpected warning") } == 4)
    }

    /// Catches: the saved default being ignored.
    @Test("A saved default is used when there's no flag")
    func usesSavedDefault() {
        #expect(Concurrency.resolve(flag: nil, saved: 8) { _ in Issue.record("unexpected warning") } == 8)
    }

    /// Catches: the saved default winning over --concurrency.
    @Test("The flag beats the saved default")
    func flagWins() {
        #expect(Concurrency.resolve(flag: 2, saved: 8) { _ in Issue.record("unexpected warning") } == 2)
    }

    /// Catches: a hand-edited, out-of-range saved value failing the run, or being used anyway.
    @Test("An out-of-range saved default warns and falls back to 4", arguments: [0, 33, -1])
    func invalidSavedDefault(_ saved: Int) {
        var warnings: [String] = []

        let limit = Concurrency.resolve(flag: nil, saved: saved) { warnings.append($0) }

        #expect(limit == 4)
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("between 1 and 32") == true)
    }
}
