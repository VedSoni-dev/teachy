//
//  ConsentLedger.swift
//  leanring-buddy
//
//  Remembers what the user said yes and no to. Pure bookkeeping: the clock and
//  the persistent store are injected, so it is unit-tested without the app.
//
//  Scopes:
//  - allow once        nothing is remembered
//  - allow for the job remembered per tool + app until that job ends
//  - always allow      remembered per tool + app in the store (UserDefaults)
//  - not now           that exact request is not asked again for 30 minutes
//
//  A request classed alwaysAsk is never covered by a remembered yes.
//

import Foundation

enum ConsentChoice: String, Equatable {
    case allowOnce
    case allowForJob
    case alwaysAllow
    case notNow
}

/// Where "always allow" lives. UserDefaults in the app, a dictionary in tests.
protocol ConsentStore: AnyObject {
    func consentStrings(forKey key: String) -> [String]
    func setConsentStrings(_ values: [String], forKey key: String)
}

final class InMemoryConsentStore: ConsentStore {
    private var storage: [String: [String]] = [:]
    func consentStrings(forKey key: String) -> [String] { storage[key] ?? [] }
    func setConsentStrings(_ values: [String], forKey key: String) { storage[key] = values }
}

extension UserDefaults: ConsentStore {
    func consentStrings(forKey key: String) -> [String] { stringArray(forKey: key) ?? [] }
    func setConsentStrings(_ values: [String], forKey key: String) { set(values, forKey: key) }
}

final class ConsentLedger {
    enum Resolution: Equatable {
        /// Run it without asking.
        case allowed(because: String)
        /// Put the question to the user.
        case ask
        /// Do not run and do not ask.
        case refused(because: String)
    }

    static let alwaysAllowStoreKey = "teachy.agent.alwaysAllow.v1"
    static let notNowWindow: TimeInterval = 30 * 60

    private let store: ConsentStore
    private let now: () -> Date
    private let lock = NSLock()
    private var jobGrants: [String: Set<String>] = [:]
    private var notNowUntil: [String: Date] = [:]

    init(store: ConsentStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    /// Decides what to do with a classified tool call, before anything is shown.
    func resolve(_ decision: ToolPolicyDecision, jobID: String) -> Resolution {
        lock.lock(); defer { lock.unlock() }
        switch decision.risk {
        case .safe:
            return .allowed(because: "safe")
        case .blocked:
            return .refused(because: decision.reason)
        case .needsConsent, .alwaysAsk:
            if let until = notNowUntil[decision.requestKey] {
                if now() < until {
                    return .refused(because: "you said not now to this a little while ago")
                }
                notNowUntil.removeValue(forKey: decision.requestKey)
            }
            if decision.risk == .alwaysAsk { return .ask }
            if jobGrants[jobID]?.contains(decision.grantKey) == true {
                return .allowed(because: "allowed for this job")
            }
            if store.consentStrings(forKey: Self.alwaysAllowStoreKey).contains(decision.grantKey) {
                return .allowed(because: "always allowed")
            }
            return .ask
        }
    }

    /// For a run nobody is watching (a routine). There is no one to ask, so nothing is asked:
    /// safe calls run, a call the person already chose "always allow" for (that exact tool + app)
    /// runs, and everything else is refused. Delete / send / pay / credentials are always refused.
    /// "Allow for this job" grants are never consulted: an unattended job cannot have been given one.
    func resolveUnattended(_ decision: ToolPolicyDecision) -> Resolution {
        lock.lock(); defer { lock.unlock() }
        switch decision.risk {
        case .safe:
            return .allowed(because: "safe")
        case .blocked:
            return .refused(because: decision.reason)
        case .alwaysAsk:
            return .refused(because: "this needs your yes every time, and nobody is here to give it")
        case .needsConsent:
            if store.consentStrings(forKey: Self.alwaysAllowStoreKey).contains(decision.grantKey) {
                return .allowed(because: "always allowed")
            }
            return .refused(because: "this needs your yes, and nobody is here to give it")
        }
    }

    /// What a routine's result says about a call it could not make.
    static func unattendedRefusalNote(for decision: ToolPolicyDecision) -> String {
        let scope = decision.appScope.isEmpty ? "" : " in \(decision.appScope)"
        return "Could not \(decision.summary)\(scope): it needs your yes. Run it yourself once and choose Always allow if you want routines to do this."
    }

    /// Records the user's answer. Returns whether the call may run now.
    @discardableResult
    func record(_ choice: ConsentChoice, for decision: ToolPolicyDecision, jobID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard decision.risk != .blocked else { return false }
        switch choice {
        case .notNow:
            notNowUntil[decision.requestKey] = now().addingTimeInterval(Self.notNowWindow)
            return false
        case .allowOnce:
            return true
        case .allowForJob:
            // A yes to something that must always be asked covers this one call only.
            if decision.risk == .needsConsent {
                jobGrants[jobID, default: []].insert(decision.grantKey)
            }
            return true
        case .alwaysAllow:
            if decision.risk == .needsConsent {
                var stored = store.consentStrings(forKey: Self.alwaysAllowStoreKey)
                if !stored.contains(decision.grantKey) {
                    stored.append(decision.grantKey)
                    store.setConsentStrings(stored, forKey: Self.alwaysAllowStoreKey)
                }
            }
            return true
        }
    }

    /// Forget "allow for this job" once the job is over.
    func endJob(_ jobID: String) {
        lock.lock(); defer { lock.unlock() }
        jobGrants.removeValue(forKey: jobID)
    }

    var alwaysAllowedKeys: [String] {
        store.consentStrings(forKey: Self.alwaysAllowStoreKey)
    }

    func revokeAlwaysAllow(_ grantKey: String) {
        lock.lock(); defer { lock.unlock() }
        let remaining = store.consentStrings(forKey: Self.alwaysAllowStoreKey).filter { $0 != grantKey }
        store.setConsentStrings(remaining, forKey: Self.alwaysAllowStoreKey)
    }

    func revokeAll() {
        lock.lock(); defer { lock.unlock() }
        store.setConsentStrings([], forKey: Self.alwaysAllowStoreKey)
        jobGrants.removeAll()
        notNowUntil.removeAll()
    }
}

// MARK: - Wording

/// The sentence on the consent card.
enum ConsentWording {
    static func headline(for decision: ToolPolicyDecision, currentPlanStep: String?) -> String {
        if decision.toolName == "drive" {
            let app = decision.appScope.isEmpty ? "this app" : decision.appScope
            var sentence = "Want me to drive \(app)"
            if let step = currentPlanStep?.trimmingCharacters(in: .whitespacesAndNewlines), !step.isEmpty {
                sentence += " and \(lowercasedFirst(strippingFinalStop(step)))"
            }
            return sentence + "? You watch. Esc takes it back."
        }
        return "Want me to \(decision.summary)?"
    }

    static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        // "Open Mail" → "open Mail", but leave "PDF export" and "I…" alone.
        let second = text.dropFirst().first
        if first.isUppercase, second?.isUppercase != true, text.prefix(2) != "I " {
            return first.lowercased() + text.dropFirst()
        }
        return text
    }

    static func strippingFinalStop(_ text: String) -> String {
        var result = text
        while let last = result.last, ".!?".contains(last) { result.removeLast() }
        return result
    }
}
