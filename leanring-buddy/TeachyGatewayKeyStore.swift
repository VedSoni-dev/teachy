//
//  TeachyGatewayKeyStore.swift
//  leanring-buddy
//
//  The person's own Vercel AI Gateway key. One key covers two things:
//    - Jev (typesafe-ai/jev), the fast yes/no and pick-one model Teachy uses to
//      route follow-ups about a live 3D drawing without a full model turn;
//    - chat models on the "Use my own key" path, in place of OpenRouter.
//
//  Keychain only (no UserDefaults copy). AI_GATEWAY_API_KEY in the environment
//  overrides it, for development. Never print or log the key.
//

import Foundation
import Security

enum TeachyGatewayKeyStore {
    private static let service = "com.teachy.apikey"
    private static let account = "vercel-ai-gateway"
    static let environmentVariableName = "AI_GATEWAY_API_KEY"

    /// The key in use: the environment override first, then the Keychain.
    static var apiKey: String? {
        if let environmentKey = ProcessInfo.processInfo.environment[environmentVariableName]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !environmentKey.isEmpty {
            return environmentKey
        }
        return loadFromKeychain()
    }

    static var isConfigured: Bool { !(apiKey ?? "").isEmpty }

    /// Whether the key comes from the environment (Settings can't remove that one).
    static var isFromEnvironment: Bool {
        !(ProcessInfo.processInfo.environment[environmentVariableName] ?? "").isEmpty
    }

    static func save(_ key: String) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, let keyData = trimmedKey.data(using: .utf8) else { return }
        remove()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func remove() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
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
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let keyData = item as? Data,
              let key = String(data: keyData, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }
}
