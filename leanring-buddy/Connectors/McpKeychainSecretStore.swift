//
//  McpKeychainSecretStore.swift
//  leanring-buddy
//
//  Connector secrets in the login Keychain: one generic-password item per
//  reference, all under the service "app.teachy.mac.connectors".
//  Values are never printed or logged.
//

import Foundation
import Security

nonisolated struct KeychainMcpSecretStore: McpSecretStore {
    static let serviceName = "app.teachy.mac.connectors"

    private func baseQuery(for reference: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: reference,
        ]
    }

    func secret(for reference: String) -> String? {
        var query = baseQuery(for: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setSecret(_ value: String, for reference: String) throws {
        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(baseQuery(for: reference) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }

        var newItem = baseQuery(for: reference)
        newItem[kSecValueData as String] = data
        newItem[kSecAttrLabel as String] = "Teachy connector"
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw McpError.invalidConfiguration("Couldn't save to the Keychain (error \(addStatus)).")
        }
    }

    func removeSecret(for reference: String) {
        SecItemDelete(baseQuery(for: reference) as CFDictionary)
    }
}
