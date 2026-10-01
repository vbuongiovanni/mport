//
//  Concurrency.swift
//  Created by Claude on 9/29/26, at Vince's request.
//
//  How many collections `export`, `import` and `migrate` work on at once: the default, the allowed range,
//  and the `--concurrency` / `-j` option they share.
//

import ArgumentParser

enum Concurrency {
    /// The same default as MongoDB's own `mongodump` and `mongorestore`.
    static let defaultLimit = 4
    /// Each collection in flight opens its own connection per endpoint, so the cap keeps a run (up to 64
    /// connections for `migrate`) well below a server's connection limit.
    static let allowedRange = 1...32

    static var rangeDescription: String {
        "between \(allowedRange.lowerBound) and \(allowedRange.upperBound)"
    }

    /// The limit for this run: `--concurrency` if given, else the saved default if it's valid, else `defaultLimit`.
    /// A saved value outside `allowedRange` (hand-edited, say) is reported through `warn` rather than failing the
    /// run. An out-of-range flag never gets here: `ConcurrencyOptions.validate()` rejects it while parsing.
    static func resolve(flag: Int?, saved: Int?, warn: (String) -> Void) -> Int {
        if let flag {
            return flag
        }
        guard let saved else {
            return defaultLimit
        }
        guard allowedRange.contains(saved) else {
            warn(
                "The saved concurrency (\(saved)) isn't \(rangeDescription), so \(defaultLimit) is being used. "
                    + "Fix it with `mport configure-defaults --concurrency <n>`."
            )
            return defaultLimit
        }
        return saved
    }

    /// Throws the error ArgumentParser shows for an out-of-range `--concurrency`.
    static func validate(_ value: Int?) throws {
        if let value, !allowedRange.contains(value) {
            throw ValidationError("Concurrency must be \(rangeDescription), not \(value).")
        }
    }
}

/// `--concurrency` / `-j`, shared by `export`, `import` and `migrate` through `@OptionGroup`.
struct ConcurrencyOptions: ParsableArguments {
    @Option(
        name: [.customShort("j"), .long],
        help: ArgumentHelp(
            "Collections to work on at once, 1-32 (default 4, or your saved default)",
            discussion: "Each one opens its own connection and holds up to 8 MB of documents in memory."
        )
    )
    var concurrency: Int?

    func validate() throws {
        try Concurrency.validate(concurrency)
    }
}
