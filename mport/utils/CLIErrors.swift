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
}
