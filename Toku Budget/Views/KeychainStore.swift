//
//  Untitled.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/23/25.
//

import Foundation
import Security

enum KeychainError: LocalizedError {
    case status(OSStatus)
    var errorDescription: String? {
        (SecCopyErrorMessageString((self.statusCode), nil) as String?) ?? "Keychain error"
    }
    private var statusCode: OSStatus {
        switch self { case .status(let s): return s }
    }
}

enum KeychainStore {
    private static let service = "com.tokubudget"
    private static let account = "openai.api.key"

    static func set(_ value: String) throws {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)           // replace if exists
        var add = base
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func get() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8)
        else { throw KeychainError.status(status) }
        return str
    }

    static func delete() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(q as CFDictionary)
    }
}
