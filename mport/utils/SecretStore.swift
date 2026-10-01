//
//  SecretStore.swift
//  Created by Claude on 9/29/26, at Vince's request.
//
//  Where saved connection URIs live. They carry credentials, so they go in the macOS Keychain rather than
//  ~/.mport-config.json, which only keeps each connection's name and is safe to commit with a dotfiles repo.
//

import Foundation
import Security

/// Keeps each saved connection's URI, by connection name.
protocol SecretStore: Sendable {
    func uri(forConnection name: String) throws -> String?
    func setURI(_ uri: String, forConnection name: String) throws
    func removeURI(forConnection name: String) throws
}

/// The login Keychain: one generic password per connection, under the service `mport` with the connection's
/// name as the account. It shows up in Keychain Access as "mport connection: <name>".
///
/// macOS remembers which program saved an entry. A signed mport keeps access across updates; an unsigned build
/// (compiled from source, say) makes macOS ask once per rebuild, and "Always Allow" stops it asking.
struct KeychainStore: SecretStore {
    /// The store every command uses.
    static let standard = KeychainStore(service: "mport")

    /// Tests use their own service name, so they never touch real connections.
    let service: String

    func uri(forConnection name: String) throws -> String? {
        var query = baseQuery(for: name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data, let uri = String(data: data, encoding: .utf8) else {
            throw KeychainError(operation: "read the URI for '\(name)'", status: status)
        }
        return uri
    }

    func setURI(_ uri: String, forConnection name: String) throws {
        let data = Data(uri.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery(for: name) as CFDictionary, [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(operation: "save the URI for '\(name)'", status: updateStatus)
        }

        var item = baseQuery(for: name)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "mport connection: \(name)"
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError(operation: "save the URI for '\(name)'", status: addStatus)
        }
    }

    func removeURI(forConnection name: String) throws {
        let status = SecItemDelete(baseQuery(for: name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(operation: "remove the URI for '\(name)'", status: status)
        }
    }

    private func baseQuery(for name: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name
        ]
    }
}

struct KeychainError: Error, CustomStringConvertible {
    let operation: String
    let status: OSStatus

    var description: String {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return "Couldn't \(operation) in your Keychain: \(reason)"
    }
}
