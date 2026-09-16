//
//  extensions.swift
//  Created by Vince B. on 9/15/26.
//  Made with love, not AI. 
//  This file was generated in swift.
//  This code was written with my fingers and brain using a keyboard.
//

import Foundation
import MongoKitten


extension OutputStream {
    func writeString(_ string: String) {
        let data = Data(string.utf8)
        _ = data.withUnsafeBytes { buffer in
            write(buffer.bindMemory(to: UInt8.self).baseAddress!, maxLength: data.count)
            
        }
    }
}

fileprivate let formatter:  DateFormatter = {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.timeZone = TimeZone(secondsFromGMT: 0)
    format.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
    return format
}()

fileprivate func quote(_ string: String) -> String {
    var output = "\""
    for char in string.unicodeScalars {
        switch char {
        case "\"": output += "\\\""
        case "\\": output += "\\\\"
        case "\n": output += "\\n"
        case "\r": output += "\\r"
        case "\t": output += "\\t"
        case let c where c.value < 0x20: output += String(format: "\\u%04x", c.value)
        default: output.unicodeScalars.append(char)
        }
    }
    return output + "\""
}

fileprivate func render(value: Primitive, indent: Int) -> String {
    (value as? ShellRenderable)?.shellJSON(indent: indent)
        ?? quote(String(describing: value))
}

protocol ShellRenderable {
    func shellJSON(indent: Int) -> String
}

extension ShellRenderable {
    func shellJSON() -> String {
        shellJSON(indent: 0)
    }
}

extension ObjectId: ShellRenderable {
    func shellJSON(indent: Int) -> String {
        "ObjectId(\"\(hexString)\")"
    }
}

extension Date: ShellRenderable {
    func shellJSON(indent: Int) -> String {
        "ISODate(\"\(formatter.string(from: self))\")"
    }
}

extension Int32: ShellRenderable {
    func shellJSON(indent: Int) -> String {
        "NumberInt(\(self))"
    }
}

extension Int: ShellRenderable {
    func shellJSON(indent: Int) -> String {
        "NumberLong(\(self))"
    }
}

extension Double: ShellRenderable {
    func shellJSON(indent: Int) -> String {
        "\(self)"
    }
}

extension String: ShellRenderable {
    func shellJSON(indent: Int) -> String {
        quote(self)
    }
}

extension Bool: ShellRenderable {
    func shellJSON(indent: Int) -> String {
        self ? "true": "false"
    }
}

extension Null: ShellRenderable {
    func shellJSON(indent: Int) -> String { "null" }
}

extension Document: ShellRenderable {
    func shellJSON(indent: Int) -> String {
        let pad = String(repeating: " ", count: (indent + 1) * 4)
        let close = String(repeating: " ", count: indent * 4)
        let items: [String]
        if self.isArray {
            items = self.values.map { pad + render(value: $0, indent: indent + 1) }
        } else {
            items = self.keys.map { key in
                pad + quote(key) + " : " + render(value: self[key] ?? Null(), indent: indent + 1)
            }
        }
        let (open, end) = self.isArray ? ("[", "]") : ("{", "}")
        if items.isEmpty { return "\(open) \(end)" }
        return open + "\n" + items.joined(separator: ",\n") + "\n" + close + end
    }
    
}
