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
        abstract: "Register a default output path",
        version: "1.0.0"
    )
    
    @Argument(help: "Default path for output files")
    var outputPath: String?
    
    @Argument(help: "Default format of output files")
    var format: String?
    
    func run() throws {
        
        var config = try CLIConfig.read()
        var didChange = false
        
        if let outputPath = outputPath {
            let url = URL(filePath: outputPath)
            
            if let _ = try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) {
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
        
        if didChange {
            try CLIConfig.write(newConfig: config)
        }
    }
}
