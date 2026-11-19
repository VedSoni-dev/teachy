//
//  TeachyDemoDriver.swift
//  leanring-buddy
//
//  Lets a script drive the real app for screen recordings (launch videos, reels)
//  without anyone at the keyboard or hovering the notch:
//
//    open "teachy://demo/ask?q=show%20me%20how%20a%20jet%20engine%20works%20in%203D"
//    open "teachy://demo/dictate?file=/absolute/path/to/speech.wav"
//    open "teachy://demo/job?task=find%20the%20cheapest%20flight%20to%20SF"
//
//  Every route runs the normal feature end to end (screen capture, model, drawing,
//  speech, dictation insertion, agent job with its permission gate); only the input
//  is scripted. `ask` is a typed question, `dictate` feeds a WAV file in place of
//  the microphone, `job` starts an agent job directly.
//
//  Off unless switched on locally, because any web page can open a teachy:// link:
//    defaults write app.teachy.mac teachy.demo.driver -bool YES
//

import AppKit
import Foundation

@MainActor
enum TeachyDemoDriver {
    static let enabledDefaultsKey = "teachy.demo.driver"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    /// Returns true when the URL was a demo route (handled or refused), so the
    /// caller doesn't also open the notch for it.
    static func handle(_ url: URL, companionManager: CompanionManager) -> Bool {
        guard url.scheme?.lowercased() == "teachy", url.host?.lowercased() == "demo" else { return false }
        guard isEnabled else {
            print("⚠️ Demo: teachy://demo links are off (set \(enabledDefaultsKey) to use them)")
            return true
        }

        let route = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func queryValue(_ name: String) -> String? {
            queryItems.first(where: { $0.name == name })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        switch route {
        case "ask":
            guard let question = queryValue("q"), !question.isEmpty else { return true }
            companionManager.submitSyntheticCompanionRequest(question)
        case "dictate":
            guard let path = queryValue("file"), path.hasPrefix("/") else { return true }
            DictationController.shared.runDemoDictation(audioFileURL: URL(fileURLWithPath: path))
        case "job":
            guard let task = queryValue("task"), !task.isEmpty else { return true }
            companionManager.backgroundAgentManager.runTask(transcript: task)
        default:
            print("⚠️ Demo: unknown route \(route)")
        }
        return true
    }
}
