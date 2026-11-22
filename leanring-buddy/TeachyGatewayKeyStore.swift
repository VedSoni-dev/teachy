//
//  TeachyGatewayKeyStore.swift
//  leanring-buddy
//
//  The person's own Vercel AI Gateway key. One key covers two things:
//    - Jev (typesafe-ai/jev), the fast yes/no and pick-one model Teachy uses to
//      route follow-ups about a live 3D drawing without a full model turn;
//    - chat models on the "Use my own key" path, in place of OpenRouter.
//
//  Jev is also on OpenRouter (its Decisions API), and Google's Gemini Decision 1
//  answers the same questions, so an OpenRouter or Gemini key can be saved here
//  for Jev alone. Each is a separate Keychain item from the sign-in
//  "own key" (TeachyAPIKeyStore), so saving it never changes how chat is routed.
//
//  Keychain only (no UserDefaults copy). AI_GATEWAY_API_KEY in the environment
//  overrides it, for development. Never print or log the key.
//

import Foundation
import Security

enum TeachyGatewayKeyStore {
    private static let service = "com.teachy.apikey"
    private static let account = "vercel-ai-gateway"
    private static let openRouterJevAccount = "openrouter-jev"
    private static let geminiJevAccount = "gemini-jev"
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

    /// A key used only for Jev (never for chat): OpenRouter or Gemini. Gateway keys use `apiKey`.
    static func jevOnlyKey(for provider: TeachyJevProvider) -> String? {
        guard let jevOnlyAccount = jevOnlyAccount(for: provider) else { return nil }
        return loadFromKeychain(account: jevOnlyAccount)
    }

    /// Jev can run: a gateway key, or an OpenRouter or Gemini key saved for Jev.
    static var isJevConfigured: Bool { jevRoute != nil }

    /// The key Jev uses and its service: the gateway key first, then Gemini, then OpenRouter.
    static var jevRoute: (apiKey: String, provider: TeachyJevProvider)? {
        for provider in [TeachyJevProvider.vercelGateway, .gemini, .openRouter] {
            if let key = savedKey(for: provider), !key.isEmpty { return (key, provider) }
        }
        return nil
    }

    static func saveJevOnlyKey(_ key: String, for provider: TeachyJevProvider) {
        guard let jevOnlyAccount = jevOnlyAccount(for: provider) else { return }
        save(key, account: jevOnlyAccount)
    }

    /// The saved key for one service (the gateway key for Vercel).
    static func savedKey(for provider: TeachyJevProvider) -> String? {
        provider == .vercelGateway ? apiKey : jevOnlyKey(for: provider)
    }

    static func saveKey(_ key: String, for provider: TeachyJevProvider) {
        if provider == .vercelGateway { save(key) } else { saveJevOnlyKey(key, for: provider) }
    }

    static func removeKey(for provider: TeachyJevProvider) {
        if provider == .vercelGateway {
            remove()
        } else if let jevOnlyAccount = jevOnlyAccount(for: provider) {
            remove(account: jevOnlyAccount)
        }
    }

    static func removeJevOnlyKeys() {
        remove(account: openRouterJevAccount)
        remove(account: geminiJevAccount)
    }

    private static func jevOnlyAccount(for provider: TeachyJevProvider) -> String? {
        switch provider {
        case .vercelGateway: return nil
        case .openRouter: return openRouterJevAccount
        case .gemini: return geminiJevAccount
        }
    }

    /// Whether the key comes from the environment (Settings can't remove that one).
    static var isFromEnvironment: Bool {
        !(ProcessInfo.processInfo.environment[environmentVariableName] ?? "").isEmpty
    }

    static func save(_ key: String) {
        save(key, account: account)
    }

    static func remove() {
        remove(account: account)
    }

    private static func save(_ key: String, account: String) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, let keyData = trimmedKey.data(using: .utf8) else { return }
        remove(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func remove(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func loadFromKeychain(account: String = TeachyGatewayKeyStore.account) -> String? {
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
