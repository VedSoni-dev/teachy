import AppKit
import Combine
import Foundation

// This service only reads the test's temporary directory. It never calls Publik.
enum Publik {
    struct Credential: Codable { let key: String }
    struct Wallet {
        var handle: String
        var planKind = "none"
        var balanceMicros = 0
        var topUpURL = "https://example.invalid/wallet"
    }
    static var credentialURL = URL(fileURLWithPath: "/unused-test-credential")
    static var pendingLogin: CheckedContinuation<(wallet: Wallet, choice: String?), Never>?
    static var pendingWallet: CheckedContinuation<(Int, Wallet?, String?), Never>?
    static var delayWallet = false
    static var loginCount = 0

    static func readCredential() -> Credential? {
        guard let data = try? Data(contentsOf: credentialURL) else { return nil }
        return try? JSONDecoder().decode(Credential.self, from: data)
    }
    static func ensureSignedIn(_ gate: GateModel) async -> (wallet: Wallet, choice: String?) {
        loginCount += 1
        gate.screen = "Sign in with publik"
        return await withCheckedContinuation { pendingLogin = $0 }
    }
    static func completeLogin(_ handle: String) throws {
        try JSONEncoder().encode(Credential(key: "fake-\(handle)")).write(to: credentialURL)
        pendingLogin?.resume(returning: (Wallet(handle: handle), "publik"))
        pendingLogin = nil
    }
    static func setChoice(_ choice: String?) {}
    static func readWallet(_ key: String) async throws -> (Int, Wallet?, String?) {
        if delayWallet { return await withCheckedContinuation { pendingWallet = $0 } }
        return (200, Wallet(handle: "current"), nil)
    }
}
final class GateModel: ObservableObject { @Published var screen: String? }
struct TeachyAIBillingError: Error { let message: String; let topUpURL: URL? }
enum TeachyAIRouter { static let isUsingPublik = true }
enum TeachyHubBeacon { static func send(event: String, usingPublik: Bool) {} }

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}
func settle(until condition: () -> Bool) async {
    for _ in 0..<200 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    fatalError("Timed out waiting for fake service")
}
func signedInSession(at url: URL, environmentKey: String? = nil) async throws -> TeachyPublikSession {
    Publik.credentialURL = url
    let session = TeachyPublikSession(credentialURL: url, environmentKey: environmentKey)
    session.start()
    await settle { Publik.pendingLogin != nil }
    try Publik.completeLogin("old-account")
    await settle { session.isReady }
    return session
}

Task { @MainActor in
    do {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credential = directory.appendingPathComponent("account.json")
        let unrelated = directory.appendingPathComponent("own-provider-key.json")
        try Data("preserve-me".utf8).write(to: unrelated)
        let session = try await signedInSession(at: credential)
        var stoppedWork = 0
        session.onLogOut = {
            expect(!session.isReady, "AI must be gated before stopping work")
            stoppedWork += 1
        }
        session.reportBilling(TeachyAIBillingError(message: "old billing notice", topUpURL: nil))

        // A wallet response from the old account must not overwrite the next account.
        Publik.delayWallet = true
        let walletTask = Task { await session.refreshWallet() }
        await settle { Publik.pendingWallet != nil }
        let previousLoginCount = Publik.loginCount
        session.logOut()
        expect(!FileManager.default.fileExists(atPath: credential.path), "saved credential must be removed")
        expect(!session.isReady && session.wallet == nil && session.choice == nil, "old account state must be cleared")
        expect(session.billingNotice == nil && session.isSwitchingAccount, "old billing must be cleared and switching explained")
        expect(stoppedWork == 1, "active work must be stopped once")
        let preserved = try Data(contentsOf: unrelated)
        expect(preserved == Data("preserve-me".utf8), "unrelated credentials must survive logout")
        session.logOut()
        expect(stoppedWork == 1, "repeated logout must not create another gate")
        await settle { Publik.loginCount == previousLoginCount + 1 }
        expect(session.gate.screen == "Sign in with publik", "logout must return to sign-in")
        try Publik.completeLogin("new-account")
        await settle { session.isReady }
        Publik.pendingWallet?.resume(returning: (200, Publik.Wallet(handle: "old-account", balanceMicros: 100), nil))
        Publik.pendingWallet = nil
        await walletTask.value
        Publik.delayWallet = false
        expect(session.wallet?.handle == "new-account", "late wallet response must not restore old account")
        expect(!session.isSwitchingAccount, "switch notice must clear after sign-in")
        print("PASS: logout, fresh sign-in, duplicate clicks, unrelated credentials, stale wallet response")

        let locked = try await signedInSession(at: directory.appendingPathComponent("environment.json"), environmentKey: "fake-env-key")
        locked.logOut()
        expect(locked.isReady && !locked.canLogOut && locked.accountError != nil, "environment override must explain why switching is unavailable")
        expect(FileManager.default.fileExists(atPath: Publik.credentialURL.path), "environment override must preserve credentials")
        print("PASS: environment-key override")

        let invalidPath = directory.appendingPathComponent("invalid.json")
        let invalid = try await signedInSession(at: invalidPath)
        try FileManager.default.removeItem(at: invalidPath)
        try FileManager.default.createDirectory(at: invalidPath, withIntermediateDirectories: true)
        let nested = invalidPath.appendingPathComponent("preserve.txt")
        try Data("keep".utf8).write(to: nested)
        invalid.logOut()
        expect(invalid.isReady && invalid.accountError != nil, "failed removal must preserve signed-in state")
        expect(FileManager.default.fileExists(atPath: nested.path), "logout must never recursively delete a directory")
        print("PASS: credential deletion failure")

        let absentPath = directory.appendingPathComponent("missing.json")
        let absent = try await signedInSession(at: absentPath)
        try FileManager.default.removeItem(at: absentPath)
        absent.logOut()
        expect(!absent.isReady && absent.accountError == nil, "already-missing credential should still log out")
        print("PASS: already-missing credential")
        print("ALL PUBLIK SESSION TESTS PASSED")
        exit(0)
    } catch {
        print("FAIL: \(error)")
        exit(1)
    }
}
RunLoop.main.run()
