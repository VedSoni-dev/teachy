//
//  ChatSessionList.swift
//  leanring-buddy
//
//  The chat window's list of saved chats, and the sidebar that shows it:
//  New chat, every past chat grouped by when it was last used, a search across
//  all of them, and Rename / Delete on right-click.
//
//  The list talks to storage only through the closures it is built with, so it
//  can be rendered and tested without the Brain. The app's one list is
//  `ChatSessionList.shared` (ChatSessionList+Shared.swift).
//

import AppKit
import Combine
import SwiftUI

/// What the sidebar shows for one chat.
nonisolated struct ChatSessionListItem: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var updatedAt: Date
    var messageCount: Int
}

/// A message in another chat that matches the sidebar search.
nonisolated struct ChatSessionSearchResult: Identifiable, Equatable, Sendable {
    var id: String { sessionID + "|" + snippet }
    var sessionID: String
    var sessionTitle: String
    var snippet: String
    var date: Date
}

@MainActor
final class ChatSessionList: ObservableObject {
    @Published private(set) var items: [ChatSessionListItem] = []
    @Published private(set) var currentSessionID: String?

    struct Actions {
        var load: () -> (items: [ChatSessionListItem], currentSessionID: String?)
        var startNew: () -> Void
        var open: (String) -> Void
        var rename: (String, String) -> Void
        var delete: (String) -> Void
        var search: (String) -> [ChatSessionSearchResult]
    }

    private let actions: Actions
    private let changeNotification: Notification.Name?
    private var observer: NSObjectProtocol?
    /// Told after the open chat changes, so the thread reloads at once.
    var onOpenChatChanged: (() -> Void)?

    init(actions: Actions, changeNotification: Notification.Name? = nil) {
        self.actions = actions
        self.changeNotification = changeNotification
        reload()
        if let changeNotification {
            observer = NotificationCenter.default.addObserver(forName: changeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
    }

    func reload() {
        let loaded = actions.load()
        if loaded.items != items { items = loaded.items }
        if loaded.currentSessionID != currentSessionID { currentSessionID = loaded.currentSessionID }
    }

    func startNewChat() {
        actions.startNew()
        reload()
        onOpenChatChanged?()
    }

    func open(_ sessionID: String) {
        guard sessionID != currentSessionID else { return }
        actions.open(sessionID)
        reload()
        onOpenChatChanged?()
    }

    func rename(_ sessionID: String, to title: String) {
        actions.rename(sessionID, title)
        reload()
    }

    func delete(_ sessionID: String) {
        let wasOpen = sessionID == currentSessionID
        actions.delete(sessionID)
        reload()
        if wasOpen { onOpenChatChanged?() }
    }

    func search(_ query: String) -> [ChatSessionSearchResult] {
        actions.search(query)
    }

    /// The chats grouped the way a chat app's sidebar does it.
    static func groups(_ items: [ChatSessionListItem], now: Date = Date(), calendar: Calendar = .current) -> [(label: String, items: [ChatSessionListItem])] {
        let startOfToday = calendar.startOfDay(for: now)
        func label(for date: Date) -> String {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: startOfToday).day ?? 0
            switch days {
            case ..<1: return "Today"
            case 1: return "Yesterday"
            case 2...6: return "Previous 7 days"
            case 7...29: return "Previous 30 days"
            default: return "Older"
            }
        }
        var groups: [(label: String, items: [ChatSessionListItem])] = []
        for item in items.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let groupLabel = label(for: item.updatedAt)
            if groups.last?.label == groupLabel {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append((groupLabel, [item]))
            }
        }
        return groups
    }
}

// MARK: - Sidebar

struct ChatSessionSidebarList: View {
    @ObservedObject var sessionList: ChatSessionList
    @State private var filterText = ""
    @State private var hoveredSessionID: String?
    @State private var newChatHovered = false
    @State private var renamingSessionID: String?
    @State private var renameDraft = ""
    @State private var searchResults: [ChatSessionSearchResult] = []

    private var isFiltering: Bool { !filterText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            newChatButton
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.bottom, DS.Spacing.xs)
            filterField
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.bottom, DS.Spacing.sm)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if isFiltering {
                        searchResultRows
                    } else {
                        ForEach(ChatSessionList.groups(sessionList.items), id: \.label) { group in
                            Text(group.label)
                                .font(DS.Fonts.caption)
                                .foregroundStyle(ChatSurfacePalette.mutedInk)
                                .padding(.horizontal, DS.Spacing.md)
                                .padding(.top, DS.Spacing.md)
                                .padding(.bottom, DS.Spacing.xs)
                            ForEach(group.items) { item in
                                sessionRow(item)
                            }
                        }
                    }
                }
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.bottom, DS.Spacing.md)
            }
        }
        .onChange(of: filterText) { _, query in
            searchResults = query.trimmingCharacters(in: .whitespaces).count >= 2 ? sessionList.search(query) : []
        }
        .alert("Rename chat", isPresented: Binding(get: { renamingSessionID != nil }, set: { if !$0 { renamingSessionID = nil } })) {
            TextField("Title", text: $renameDraft)
            Button("Rename") {
                if let renamingSessionID { sessionList.rename(renamingSessionID, to: renameDraft) }
                renamingSessionID = nil
            }
            Button("Cancel", role: .cancel) { renamingSessionID = nil }
        }
    }

    private var newChatButton: some View {
        Button(action: sessionList.startNewChat) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "square.and.pencil").font(DS.Fonts.body)
                Text("New chat").font(DS.Fonts.itemTitle)
                Spacer(minLength: 0)
                Text("⌘N").font(DS.Fonts.data).foregroundStyle(ChatSurfacePalette.mutedInk)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
            .background(newChatHovered ? ChatSurfacePalette.canvas : ChatSurfacePalette.glossTop, in: RoundedRectangle(cornerRadius: DS.CornerRadius.small))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(ChatSurfacePalette.ink)
        .pointerCursor()
        .onHover { newChatHovered = $0 }
        .keyboardShortcut("n", modifiers: .command)
        .help("Start a new chat. Past chats stay here and in Teachy's memory.")
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(DS.Fonts.caption)
                .foregroundStyle(ChatSurfacePalette.mutedInk)
            TextField("Search all chats", text: $filterText, prompt: Text("Search all chats").foregroundColor(ChatSurfacePalette.mutedInk))
                .textFieldStyle(.plain)
                .font(DS.Fonts.caption)
                .foregroundStyle(ChatSurfacePalette.ink)
            if isFiltering {
                Button { filterText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(ChatSurfacePalette.mutedInk)
                    .pointerCursor()
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .frame(height: 26)
        .background(ChatSurfacePalette.field, in: RoundedRectangle(cornerRadius: DS.CornerRadius.well))
    }

    @ViewBuilder
    private var searchResultRows: some View {
        let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        let titleMatches = sessionList.items.filter { $0.title.lowercased().contains(query) }
        ForEach(titleMatches) { item in sessionRow(item) }
        if !searchResults.isEmpty {
            Text("In messages")
                .font(DS.Fonts.caption)
                .foregroundStyle(ChatSurfacePalette.mutedInk)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.top, DS.Spacing.md)
                .padding(.bottom, DS.Spacing.xs)
            ForEach(searchResults) { result in
                Button { sessionList.open(result.sessionID) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.sessionTitle).font(DS.Fonts.caption).foregroundStyle(ChatSurfacePalette.ink).lineLimit(1)
                        Text(result.snippet).font(DS.Fonts.data).foregroundStyle(ChatSurfacePalette.mutedInk).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, 6)
                    .background(hoveredSessionID == result.id ? ChatSurfacePalette.canvas.opacity(0.7) : Color.clear, in: RoundedRectangle(cornerRadius: DS.CornerRadius.small))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .onHover { hoveredSessionID = $0 ? result.id : nil }
            }
        }
        if titleMatches.isEmpty && searchResults.isEmpty {
            Text("No chats match")
                .font(DS.Fonts.caption)
                .foregroundStyle(ChatSurfacePalette.mutedInk)
                .padding(DS.Spacing.md)
        }
    }

    private func sessionRow(_ item: ChatSessionListItem) -> some View {
        let isOpen = item.id == sessionList.currentSessionID
        let isHovered = hoveredSessionID == item.id
        return Button { sessionList.open(item.id) } label: {
            Text(item.title)
                .font(DS.Fonts.caption)
                .foregroundStyle(ChatSurfacePalette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, 6)
                .background(
                    isOpen ? ChatSurfacePalette.canvas : (isHovered ? ChatSurfacePalette.canvas.opacity(0.55) : Color.clear),
                    in: RoundedRectangle(cornerRadius: DS.CornerRadius.small)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hoveredSessionID = $0 ? item.id : (hoveredSessionID == item.id ? nil : hoveredSessionID) }
        .help(item.title)
        .contextMenu {
            Button("Rename…") {
                renameDraft = item.title
                renamingSessionID = item.id
            }
            Button("Delete", role: .destructive) { sessionList.delete(item.id) }
        }
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }
}
