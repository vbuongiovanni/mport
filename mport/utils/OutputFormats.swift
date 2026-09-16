//
//  OutputFormats.swift
//  Created by Vince B. on 9/15/26.
//  Made with love, not AI. 
//  This file was generated in swift.
//  This code was written with my fingers and brain using a keyboard.
//

import Foundation

enum OutputFormat: String, Codable, CaseIterable {
    case pending = ""
    case json = "json"
    case bson =  "bson"
    case mongoShellSyntax = "mongo-shell-syntax"
}
