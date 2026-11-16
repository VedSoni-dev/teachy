import AppKit
import Combine
import Foundation

// MARK: - Session (gate + account state for the UI)

/// Runs publik's sign-in gate at launch and holds the account state the panel shows.
@MainActor
final class TeachyPublikSession: ObservableObject {
    static let shared = TeachyPublikSession()

    let gate = GateModel()

    @Published private(set) var isReady = false
    @Published private(set) var wallet: Publik.Wallet?
    @Published private(set) var choice: String?
    @Published private(set) var billingNotice: TeachyAIBillingError?

    @Published private(set) var accountError: String?
    @Published private(set) var isSwitchingAccount = false

    var onLogOut: (() -> Void)?
    private let credentialURL: URL
    private let hasEnvironmentKey: Bool
    private var generation = UUID()

    var canLogOut: Bool { !hasEnvironmentKey }

    private var gateTask: Task<Void, Never>?
    private var activeSessionTask: Task<Void, Never>?

    init(
        credentialURL: URL? = nil,
        environmentKey: String? = ProcessInfo.processInfo.environment["PUBLIK_API_KEY"]
    ) {
        self.credentialURL = credentialURL ?? Publik.credentialURL
        self.hasEnvironmentKey = !(environmentKey ?? "").isEmpty
    }

    /// Starts the gate. `PUBLIK_SELF_TEST=1` makes the gate print its line and exit here.
    func start() {
        guard gateTask == nil else { return }
        let expectedGeneration = generation
        gateTask = Task { [weak self] in
            guard let self else { return }
            let result = await Publik.ensureSignedIn(self.gate)
            guard !Task.isCancelled, self.generation == expectedGeneration else { return }
            self.isSwitchingAccount = false
            self.wallet = result.wallet
            self.choice = result.choice
            self.isReady = true
            self.gate.screen = nil
            self.startHubBeacons()
        }
    }

    /// Settings → "Change": ask again how to pay for AI.
    func changePaymentChoice() {
        Publik.setChoice(nil)
        restartGate()
    }

    func logOut() {
        guard isReady else { return }
        guard canLogOut else {
            accountError = "Remove PUBLIK_API_KEY from the launch environment and restart Teachy to switch accounts."
            return
        }
        do {
            if FileManager.default.fileExists(atPath: credentialURL.path) {
                let values = try credentialURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { throw CocoaError(.fileReadCorruptFile) }
                try FileManager.default.removeItem(at: credentialURL)
            }
        } catch {
            accountError = "Teachy couldn’t clear the saved login. Try logging out again."
            return
        }
        accountError = nil
        isSwitchingAccount = true
        activeSessionTask?.cancel()
        activeSessionTask = nil
        // The successful gate has finished. Invalidate account state before any new work starts.
        isReady = false
        wallet = nil
        choice = nil
        billingNotice = nil
        onLogOut?()
        restartGate()
    }

    func restartGate() {
        generation = UUID()
        gateTask?.cancel()
        gateTask = nil
        isReady = false
        gate.screen = nil
        start()
    }

    func refreshWallet() async {
        let expectedGeneration = generation
        guard isReady, let credential = Publik.readCredential(),
              let (_, freshWallet, _) = try? await Publik.readWallet(credential.key),
              let freshWallet
        else { return }
        guard isReady, generation == expectedGeneration,
              Publik.readCredential()?.key == credential.key else { return }
        wallet = freshWallet
        if freshWallet.planKind != "none" || freshWallet.balanceMicros > 0 {
            billingNotice = nil
        }
    }

    func reportBilling(_ error: TeachyAIBillingError) {
        guard isReady else { return }
        billingNotice = error
    }

    func openTopUp() {
        let url = billingNotice?.topUpURL ?? wallet.flatMap { URL(string: $0.topUpURL) }
        if let url { NSWorkspace.shared.open(url) }
    }

    private func startHubBeacons() {
        guard activeSessionTask == nil else { return }
        TeachyHubBeacon.send(event: "app_opened", usingPublik: TeachyAIRouter.isUsingPublik)
        activeSessionTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_800 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                TeachyHubBeacon.send(event: "active_session", usingPublik: TeachyAIRouter.isUsingPublik)
            }
        }
    }
}
