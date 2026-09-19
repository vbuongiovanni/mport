//
//  CLIError.swift
//  Created by Vince B. on 9/15/26.
//  Made with love, not AI. 
//  This file was generated in swift.
//  This code was written with my fingers and brain using a keyboard.
//

import Foundation

enum CLIError: Error {
    case missingArgument(argument: String, help: String? = nil)
    case missingConfig
    case emptyConfig
    case connectionFailed
    case outputSteamFailure
    case invalidExportFormat
    case directoryDoesNotExist
    case noBSONFiles(directory: String)
    case malformedBSON(file: String)
    case importFailed(collection: String, reason: String)
    case noCollections(database: String)
    case migrationOverlap(collections: [String])
}
