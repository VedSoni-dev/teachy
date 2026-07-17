//
//  TeachyAPIKeyStore.swift
//  leanring-buddy
//
//  Secure storage for the user's API key. Uses Keychain for production,
//  with UserDefaults fallback for development.
//

import Foundation
import Security

enum TeachyAPIKeyStore {
    private static let service = "com.teachy.apikey"
    private static let account = "openrouter"

    /// The user's OpenRouter API key, or nil if not set.
    static var apiKey: String? {
        get {
            // Try Keychain first
            if let keychainKey = loadFromKeychain() {
                return keychainKey
            }
            // Fallback to UserDefaults (dev convenience)
            return UserDefaults.standard.string(forKey: "teachy_openrouter_api_key")
        }
        set {
            if let newValue, !newValue.isEmpty {
                saveToKeychain(newValue)
                UserDefaults.standard.set(newValue, forKey: "teachy_openrouter_api_key")
            } else {
                deleteFromKeychain()
                UserDefaults.standard.removeObject(forKey: "teachy_openrouter_api_key")
            }
        }
    }

    /// Whether the user has configured an API key.
    static var isConfigured: Bool {
        (apiKey ?? "").isEmpty == false
    }

    // MARK: - Keychain

    private static func saveToKeychain(_ key: String) {
        guard let data = key.data(using: .utf8) else { return }

        // Delete any existing item first
        deleteFromKeychain()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func loadFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return key
    }

    private static func deleteFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
