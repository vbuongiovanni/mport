//
//  Mport.swift
//  Created by Vince B. on 9/15/26.
//  Made with love, not AI. 
//  This file was generated in swift.
//  This code was written with my fingers and brain using a keyboard.
//

import ArgumentParser
import Foundation

@main
struct Mport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Import and export MongoDB collections using saved connections",
        version: "1.0.0",
        subcommands: [ConfigureDefaults.self, RegisterConnection.self, Export.self, Import.self, Migrate.self]
    )
}
