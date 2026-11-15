//
//  AgentsSection.swift
//  leanring-buddy
//
//  The Home tab's agents lists, wired to the app. Mount it with `AgentsSection()`.
//  The drawing is in AgentsSectionContent.swift.
//

import AppKit
import SwiftUI

struct AgentsSection: View {
    @ObservedObject private var roster = AgentRoster.shared
    @ObservedObject private var scheduler = RoutineScheduler.shared
    @ObservedObject private var center = AgentJobCenter.shared
    @State private var records: [AgentJobRecord] = []

    var body: some View {
        AgentsSectionContent(
            agents: roster.agents,
            routines: scheduler.routines,
            runningRoutineIDs: scheduler.runningIDs,
            routinesProblem: scheduler.storeProblem,
            jobs: records,
            actions: AgentsSectionActions(
                createAgent: { name, role in try roster.create(name: name, role: role) },
                renameAgent: { slug, newName in try roster.rename(slug: slug, to: newName) },
                deleteAgent: { slug in try roster.delete(slug: slug) },
                openAgentFolder: { slug in NSWorkspace.shared.open(roster.folder(for: slug)) },
                addRoutine: { sentence in try await scheduler.createFromText(sentence) },
                setRoutineEnabled: { id, enabled in scheduler.setEnabled(id: id, enabled) },
                runRoutineNow: { id in scheduler.runNow(id: id) },
                deleteRoutine: { id in scheduler.delete(id: id) },
                markRoutineRead: { id in scheduler.markRead(id: id) },
                copy: { text in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            )
        )
        .task {
            roster.reload()
            scheduler.loadIfNeeded()
            reloadRecords()
        }
        .onChange(of: center.historyRevision) { _, _ in reloadRecords() }
    }

    private func reloadRecords() {
        // Reading up to 200 small files: off the main thread.
        Task.detached(priority: .utility) {
            let loaded = AgentHistoryStore.shared.list(limit: 40)
            await MainActor.run { records = loaded }
        }
    }
}
