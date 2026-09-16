//
//  RegisterConnection.swift
//  Created by Vince B. on 9/15/26.
//  Made with love, not AI. 
//  This file was generated in swift.
//  This code was written with my fingers and brain using a keyboard.
//

import Foundation
import ArgumentParser

struct RegisterConnection: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Register MongoDB URI",
        version: "1.0.0"
    )
    
    @Argument(help: "Name/Label of MongoDB URI")
    var name: String
    
    @Argument(help: "Mongo Connection URI")
    var uri: String
    
    @Flag(name: .shortAndLong, help: "Overwrite existing")
    var overwrite: Bool = false
    
    func run() throws {
        
        var config = try CLIConfig.read()
        
        if !overwrite {
            let doesExist = config.connections.count { $0.name == name }
            if doesExist > 0 {
                throw ValidationError("An existing connection already exists with that name")
            }
        }
        
        config.connections = config.connections.filter {$0.name != name}
        
        config.connections.append(MongoConnectionRecord(name: name, uri: uri))
        
        try CLIConfig.write(newConfig: config)
        
        print("Successfully saved new URI Connection Details")
    }
    
}
