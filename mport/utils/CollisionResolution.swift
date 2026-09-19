//
//  CollisionResolution.swift
//  Created by Vince B. on 9/17/26.
//  Made with love, not AI. 
//  This file was generated in swift.
//  This code was written with my fingers and brain using a keyboard.
//

import Foundation

enum CollisionResolution: String, Codable, CaseIterable {
    case dumpBeforeImport = "dump-before-import"
    case clearBeforeImport = "clear-before-import"
    case overwrite = "overwrite"
    case skip = "skip"
}
