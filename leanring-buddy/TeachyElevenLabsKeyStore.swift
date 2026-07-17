//
//  TeachyElevenLabsKeyStore.swift
//  leanring-buddy
//
//  Secure storage for the user's own ElevenLabs API key + voice ID, so
//  self-hosted voice usage never lands on the developer's ElevenLabs bill.
//  Mirrors TeachyAPIKeyStore.swift's Keychain wrapper exactly (same
//  Keychain service, sibling account). Voice ID is not a secret, so it is
//  stored in UserDefaults rather than the Keychain.
//

import Foundation
import Security

enum TeachyElevenLabsKeyStore {
    private static let service = "com.teachy.apikey"
    private static let account = "elevenlabs"
    private static let voiceIDDefaultsKey = "teachy_elevenlabs_voice_id"

    /// The user's own ElevenLabs API key, or nil if not set.
    static var apiKey: String? {
        get {
            // Try Keychain first
            if let keychainKey = loadFromKeychain() {
                return keychainKey
            }
            // Fallback to UserDefaults (dev convenience)
            return UserDefaults.standard.string(forKey: "teachy_elevenlabs_api_key")
        }
        set {
            if let newValue, !newValue.isEmpty {
                saveToKeychain(newValue)
                UserDefaults.standard.set(newValue, forKey: "teachy_elevenlabs_api_key")
            } else {
                deleteFromKeychain()
                UserDefaults.standard.removeObject(forKey: "teachy_elevenlabs_api_key")
            }
        }
    }

    /// The ElevenLabs voice ID to use for the user's own key. Not a secret,
    /// so UserDefaults is sufficient (no need for Keychain).
    static var voiceID: String? {
        get { UserDefaults.standard.string(forKey: voiceIDDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: voiceIDDefaultsKey) }
    }

    /// Whether the user has configured both an API key and a voice ID.
    static var isConfigured: Bool {
        !(apiKey ?? "").isEmpty && !(voiceID ?? "").isEmpty
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
