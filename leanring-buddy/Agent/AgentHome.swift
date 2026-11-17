//
//  AgentHome.swift
//  leanring-buddy
//
//  Where agents keep things on this Mac, and the app's shared instances of the
//  stores that live there. (The stores themselves take their folder as a
//  parameter, so tests never touch these.)
//
//      ~/.teachy/agents/
//          <slug>/            a named agent: AGENT.md, MEMORY.md, files/
//          history/           one JSON file per finished job
//          notes/             notes of long jobs
//          routines.json      schedules
//

import Foundation

enum AgentHome {
    nonisolated static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".teachy/agents", isDirectory: true)
    }
    nonisolated static var historyDirectory: URL { root.appendingPathComponent("history", isDirectory: true) }
    nonisolated static var notesDirectory: URL { root.appendingPathComponent("notes", isDirectory: true) }
    nonisolated static var routinesFile: URL { root.appendingPathComponent("routines.json") }
}

extension AgentRoster {
    /// The person's agents. Deleting one moves its folder to the Trash.
    static let shared = AgentRoster(root: AgentHome.root, trash: { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    })
}

extension AgentHistoryStore {
    nonisolated static let shared = AgentHistoryStore(directory: AgentHome.historyDirectory)
}

extension AgentProjectStore {
    static let shared = AgentProjectStore(file: AgentHome.root.appendingPathComponent("projects.json"))
}
