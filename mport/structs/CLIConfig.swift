//
//  CLIConfig.swift
//  Created by Vince B. on 9/15/26.
//  Made with love, not AI. 
//  This file was generated in swift.
//  This code was written with my fingers and brain using a keyboard.
//

import Foundation

struct CLIConfig: Codable {
    var connections: [MongoConnectionRecord]
    var defaultExportPath: String?
    var defaultFormat: OutputFormat?
    private static let configFileName: String = ".mport-config.json"
    
    init() {
        self.connections = [MongoConnectionRecord]()
    }
    
    static func read() throws -> CLIConfig {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let configFileUrl = homeDir.appending(component: configFileName)
        
        var config: CLIConfig
        
        do {
            let existingData = try Data(contentsOf: configFileUrl)
            config = try JSONDecoder().decode(CLIConfig.self, from: existingData)
        } catch {
            print("Warning - existing config file is malformed, will create a new one")
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            
            config = CLIConfig()
            let data = try encoder.encode(config)
            try data.write(to: configFileUrl, options: .atomic)
        }
        
        return config
    }
    
    static func write(newConfig: CLIConfig) throws {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let configFileUrl = homeDir.appending(component: configFileName)
        
        guard FileManager.default.fileExists(atPath: configFileUrl.path) else {
            throw CLIError.missingConfig
        }
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        
        let data = try encoder.encode(newConfig)
        try data.write(to: configFileUrl, options: .atomic)

    }
}
