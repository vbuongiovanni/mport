//
//  ConfigureDefaults.swift
//  Created by Vince B. on 9/15/26.
//  Made with love, not AI. 
//  This file was generated in swift.
//  This code was written with my fingers and brain using a keyboard.
//

import Foundation
import ArgumentParser

struct ConfigureDefaults: ParsableCommand {
    
    static let configuration = CommandConfiguration(
        abstract: "Save defaults: output path, output format, and how many collections to work on at once",
        version: "1.0.0"
    )

    @Argument(help: "Default path for output files")
    var outputPath: String?

    @Argument(help: "Default format of output files")
    var format: String?

    @Option(help: "Default number of collections to work on at once, 1-32 (4 if never set)")
    var concurrency: Int?

    func validate() throws {
        try Concurrency.validate(concurrency)
    }

    func run() throws {
        var config = try CLIConfig.read()
        if try apply(to: &config) {
            try CLIConfig.write(newConfig: config)
        }
    }

    /// Applies the given arguments to `config`, and returns whether anything changed.
    /// Only an output path touches the disk (its directory is created), so the rest can be tested without it.
    func apply(to config: inout CLIConfig) throws -> Bool {
        var didChange = false

        if let outputPath = outputPath {
            let url = URL(filePath: outputPath)
            
            if (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw CLIError.missingConfig
                }
                config.defaultExportPath = outputPath.trimmingCharacters(in: .whitespacesAndNewlines)
                didChange = true
            }
        }
        
        if let format = format {
            if let matchedFormat = OutputFormat(rawValue: format.lowercased()) {
                config.defaultFormat = matchedFormat
                didChange = true
            } else {
                throw CLIError.invalidExportFormat
            }
        }

        if let concurrency = concurrency {
            config.defaultConcurrency = concurrency
            didChange = true
        }

        return didChange
    }
}
