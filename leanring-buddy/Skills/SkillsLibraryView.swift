import AppKit
import SwiftUI

/// One row of the Skills Library: a Skill Market listing, a skill the person added
/// themselves, or a skill waiting for them to confirm (from a link or a file).
struct SkillsLibraryEntry: Identifiable, Equatable {
    enum Source: Equatable {
        case market(SkillMarketListing)
        case mine(Skill)
        case pending(SkillStore.PendingInstall)
    }

    var source: Source

    var id: String {
        switch source {
        case .market(let listing): return "market:" + listing.id
        case .mine(let skill): return "mine:" + (skill.fileURL?.lastPathComponent ?? skill.name)
        case .pending(let pending): return "pending:" + pending.id.uuidString
        }
    }

    private var skill: Skill? {
        switch source {
        case .market: return nil
        case .mine(let skill): return skill
        case .pending(let pending): return pending.file.skill
        }
    }

    var name: String {
        if case .market(let listing) = source { return listing.name }
        return skill?.name ?? ""
    }
    var author: String {
        if case .market(let listing) = source { return listing.author }
        return skill?.author ?? "You"
    }
    var icon: String? {
        if case .market(let listing) = source { return listing.icon }
        return skill?.icon
    }
    var category: String? {
        if case .market(let listing) = source { return listing.category }
        return skill?.category
    }
    var headline: String {
        if case .market(let listing) = source { return listing.headline ?? listing.summary }
        return skill?.headline ?? skill?.summary ?? ""
    }
    var details: String? {
        if case .market(let listing) = source { return listing.description ?? (listing.headline == nil ? nil : listing.summary) }
        guard let skill else { return nil }
        return skill.details ?? (skill.headline == nil ? nil : (skill.summary.isEmpty ? nil : skill.summary))
    }
    var goodFor: [String] {
        if case .market(let listing) = source { return listing.goodFor ?? listing.apps ?? [] }
        guard let skill else { return [] }
        if !skill.goodFor.isEmpty { return skill.goodFor }
        return [skill.name] + skill.sites.prefix(2).map { String($0.split(separator: "/").first ?? "") }
    }
    /// What the detail pane lists under Inside this skill: the author's highlights, or the file's headings.
    var highlights: [String] {
        if case .market(let listing) = source { return listing.highlights ?? [] }
        guard let skill else { return [] }
        if !skill.highlights.isEmpty { return skill.highlights }
        return skill.sections.map(\.title).filter { !$0.isEmpty }
    }
    var version: String? {
        if case .market(let listing) = source { return listing.version }
        return skill?.version
    }
    var isNew: Bool {
        if case .market(let listing) = source { return listing.isNew() }
        return false
    }
}

/// Which skills the left column shows.
enum SkillsLibraryFilter: Hashable {
    case all, mine
    case category(String)

    var title: String {
        switch self {
        case .all: return "All"
        case .mine: return "My skills"
        case .category(let name): return name
        }
    }

    var symbol: String {
        switch self {
        case .all: return "sparkles"
        case .mine: return "person.crop.circle"
        case .category(let name): return SkillsLibraryFilter.symbol(forCategory: name)
        }
    }

    static func symbol(forCategory category: String) -> String {
        switch category.lowercased() {
        case "work": return "briefcase"
        case "design": return "paintpalette"
        case "notes": return "note.text"
        case "social": return "bubble.left.and.bubble.right"
        case "meetings": return "video"
        case "coding": return "chevron.left.forwardslash.chevron.right"
        case "writing": return "pencil"
        case "video": return "film"
        case "marketing": return "megaphone"
        default: return "square.grid.2x2"
        }
    }
}

/// The Skills Library: browse the Skill Market and your own skills, read what a skill covers,
/// and add it. Shown in its own window (`SkillsLibraryWindowController`).
struct SkillsLibraryView: View {
    @ObservedObject var store: SkillStore = .shared
    /// Off in the off-screen renders, which have no network.
    var loadsMarketOnAppear = true
    @State private var filter: SkillsLibraryFilter
    @State private var search = ""
    @State private var selectedEntryID: String?

    @MainActor init(store: SkillStore = .shared, loadsMarketOnAppear: Bool = true, filter: SkillsLibraryFilter = .all, selectedEntryID: String? = nil) {
        self.store = store
        self.loadsMarketOnAppear = loadsMarketOnAppear
        _filter = State(initialValue: filter)
        _selectedEntryID = State(initialValue: selectedEntryID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            TeachyRule()
            HStack(spacing: 0) {
                listColumn.frame(width: 380)
                Rectangle().fill(DS.Colors.hairline).frame(width: 1)
                detailColumn.frame(maxWidth: .infinity)
            }
        }
        .background(DS.Colors.surface1)
        .environment(\.colorScheme, .dark)
        .task {
            store.refreshInstalledSkills()
            if loadsMarketOnAppear { await store.loadMarketIfNeeded() }
        }
        .onChange(of: store.pendingInstall) { previous, pending in
            // A skill link or a chosen file jumps straight to the skill waiting for confirmation.
            if let pending {
                filter = .all
                selectedEntryID = SkillsLibraryEntry(source: .pending(pending)).id
            } else if let previous {
                // Once it's added (or dropped), stay on that skill instead of jumping to the top.
                selectedEntryID = entryID(afterResolving: previous)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Skills Library")
                    .font(DS.Fonts.sans(28, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("A skill teaches Teachy its way around an app. Teachy uses it whenever you're in that app, when it answers and when it runs agents for you.")
                    .font(DS.Fonts.sans(14))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button { store.createNewSkill() } label: {
                        Label("Create a skill", systemImage: "plus.circle.fill")
                    }
                    .teachyButton(.prominent, size: .regular)
                    Button("Add from file…") { store.chooseFileToAdd() }
                        .teachyButton(.secondary, size: .regular)
                }
                .padding(.top, 8)
            }
            Spacer(minLength: 24)
            VStack(alignment: .trailing, spacing: 8) {
                Button { NSWorkspace.shared.open(SkillMarketConfiguration.submitURL) } label: {
                    HStack(spacing: 4) { Text("Publish a skill"); Image(systemName: "arrow.up.right") }
                }.teachyLinkButton(font: DS.Fonts.body)
                Button { NSWorkspace.shared.open(SkillMarketConfiguration.pageURL) } label: {
                    HStack(spacing: 4) { Text("Open on the web"); Image(systemName: "arrow.up.right") }
                }.teachyLinkButton(color: DS.Colors.textSecondary, font: DS.Fonts.body)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 44)
        .padding(.bottom, 24)
    }

    // MARK: List

    private var entries: [SkillsLibraryEntry] {
        var result: [SkillsLibraryEntry] = []
        if let pending = store.pendingInstall { result.append(SkillsLibraryEntry(source: .pending(pending))) }
        let marketIDs = Set(store.listings.map(\.id))
        switch filter {
        case .mine:
            // Market skills you added show their listing (it has the full detail); your own files show themselves.
            result += store.listings.filter { store.installState(of: $0) != .notInstalled }.map { SkillsLibraryEntry(source: .market($0)) }
            result += store.userSkills.filter { $0.marketID.map { !marketIDs.contains($0) } ?? true }.map { SkillsLibraryEntry(source: .mine($0)) }
        case .all, .category:
            result += store.listings.map { SkillsLibraryEntry(source: .market($0)) }
            result += store.userSkills.filter { $0.marketID.map { !marketIDs.contains($0) } ?? true }.map { SkillsLibraryEntry(source: .mine($0)) }
        }
        if case .category(let name) = filter {
            result = result.filter { $0.category?.lowercased() == name.lowercased() }
        }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            result = result.filter { entry in
                ([entry.name, entry.author, entry.headline, entry.category ?? ""] + entry.goodFor).joined(separator: " ").lowercased().contains(query)
            }
        }
        return result
    }

    private var filters: [SkillsLibraryFilter] {
        let categories = Set((store.listings.compactMap(\.category) + store.userSkills.compactMap(\.category)))
        return [.all, .mine] + categories.sorted().map { .category($0) }
    }

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(filters, id: \.self) { option in
                        SkillsLibraryChip(title: option.title, symbol: option.symbol, isSelected: filter == option) { filter = option }
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 16)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(DS.Colors.textTertiary)
                TextField("Search skills", text: $search).textFieldStyle(.plain).font(DS.Fonts.body)
            }
            .padding(9).teachyWell(cornerRadius: 9)
            .padding(.horizontal, 20).padding(.vertical, 12)
            TeachyRule()
            ScrollView {
                LazyVStack(spacing: 4) {
                    listStatus
                    ForEach(entries) { entry in
                        SkillsLibraryRow(entry: entry, isSelected: entry.id == currentEntry?.id, isAdded: isAdded(entry)) {
                            selectedEntryID = entry.id
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder private var listStatus: some View {
        switch store.marketLoadState {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading the Skill Market…").font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
            }.padding(12)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                Button("Try again") { Task { await store.loadMarket() } }.teachyButton(.secondary, size: .compact)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        case .loaded:
            if entries.isEmpty {
                Text(emptyMessage).font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        }
    }

    private var emptyMessage: String {
        if !search.isEmpty { return "No skills match \"\(search)\"." }
        if filter == .mine { return "You haven't added a skill yet. Pick one from All, or create your own." }
        return "No skills here yet."
    }

    private func isAdded(_ entry: SkillsLibraryEntry) -> Bool {
        switch entry.source {
        case .market(let listing): return store.installState(of: listing) != .notInstalled
        case .mine: return true
        case .pending: return false
        }
    }

    /// The row that shows a skill once it is no longer waiting: its market listing, or the file it was saved as.
    private func entryID(afterResolving pending: SkillStore.PendingInstall) -> String? {
        if let marketID = pending.file.skill.marketID, store.listings.contains(where: { $0.id == marketID }) {
            return "market:" + marketID
        }
        if store.userSkills.contains(where: { $0.fileURL?.lastPathComponent == pending.file.fileName }) {
            return "mine:" + pending.file.fileName
        }
        return nil
    }

    private var currentEntry: SkillsLibraryEntry? {
        let visible = entries
        return visible.first { $0.id == selectedEntryID } ?? visible.first
    }

    // MARK: Detail

    @ViewBuilder private var detailColumn: some View {
        if let entry = currentEntry {
            SkillsLibraryDetail(entry: entry, store: store)
                .id(entry.id)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "book.closed").font(DS.Fonts.sans(28)).foregroundColor(DS.Colors.textTertiary)
                Text("Pick a skill to see what's inside.").font(DS.Fonts.body).foregroundColor(DS.Colors.textSecondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Pieces

/// The rounded tile with the skill's emoji (or a book when it has none).
struct SkillsLibraryIconTile: View {
    let icon: String?
    var sideLength: CGFloat = 52

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: sideLength * 0.24, style: .continuous)
                .fill(DS.Colors.fillSecondary)
            RoundedRectangle(cornerRadius: sideLength * 0.24, style: .continuous)
                .strokeBorder(DS.Colors.hairline, lineWidth: 1)
            if let icon, !icon.isEmpty {
                Text(icon).font(.system(size: sideLength * 0.5))
            } else {
                Image(systemName: "book.closed")
                    .font(DS.Fonts.sans(sideLength * 0.38, weight: .medium))
                    .foregroundColor(DS.Colors.pointer)
            }
        }
        .frame(width: sideLength, height: sideLength)
        .accessibilityHidden(true)
    }
}

private struct SkillsLibraryChip: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(DS.Fonts.sans(11, weight: .semibold))
                Text(title).font(DS.Fonts.sans(12.5, weight: .semibold))
            }
            .foregroundColor(isSelected ? DS.Colors.onProminent : (isHovered ? DS.Colors.textPrimary : DS.Colors.textSecondary))
            .padding(.horizontal, 12).frame(height: 30)
            .background(Capsule().fill(isSelected ? DS.Colors.prominentFill : (isHovered ? DS.Colors.fillTertiary : DS.Colors.fillQuaternary)))
            .overlay(Capsule().strokeBorder(isSelected ? Color.clear : DS.Colors.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).pointerCursor().onHover { isHovered = $0 }
        .animation(DS.Motion.hover, value: isHovered)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SkillsLibraryRow: View {
    let entry: SkillsLibraryEntry
    let isSelected: Bool
    let isAdded: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                SkillsLibraryIconTile(icon: entry.icon)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).font(DS.Fonts.sans(15, weight: .semibold)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                    Text(subtitle).font(DS.Fonts.sans(12)).foregroundColor(DS.Colors.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if case .pending = entry.source {
                    Text("Waiting").font(DS.Fonts.sans(10.5, weight: .semibold)).foregroundColor(DS.Colors.warning)
                } else if isAdded {
                    TeachyStatusMark(kind: .done, sideLength: 14)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? DS.Colors.fillSecondary : (isHovered ? DS.Colors.fillQuaternary : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? DS.Colors.hairline : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain).pointerCursor().onHover { isHovered = $0 }
        .animation(DS.Motion.hover, value: isHovered)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var subtitle: String {
        switch entry.source {
        case .pending(let pending): return "From \(pending.sourceDescription)"
        case .mine(let skill) where skill.author == nil: return "Yours"
        default: return "by \(entry.author)"
        }
    }
}

private struct SkillsLibraryDetail: View {
    let entry: SkillsLibraryEntry
    @ObservedObject var store: SkillStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Before anything else: where this came from, and that it changes what Teachy reads.
                    if case .pending(let pending) = entry.source {
                        pendingNote(pending)
                    }
                    titleBlock
                    VStack(alignment: .leading, spacing: 10) {
                        Text(entry.headline)
                            .font(DS.Fonts.sans(19, weight: .bold))
                            .foregroundColor(DS.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let details = entry.details {
                            Text(details)
                                .font(DS.Fonts.sans(14))
                                .foregroundColor(DS.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !entry.highlights.isEmpty {
                        TeachyRule()
                        VStack(alignment: .leading, spacing: 11) {
                            detailHeading("INSIDE THIS SKILL")
                            ForEach(entry.highlights, id: \.self) { highlight in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Image(systemName: "sparkle").font(DS.Fonts.sans(10, weight: .semibold)).foregroundColor(DS.Colors.textTertiary)
                                    Text(highlight).font(DS.Fonts.sans(14)).foregroundColor(DS.Colors.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 32).padding(.top, 26).padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            TeachyRule()
            footer
        }
    }

    private var titleBlock: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text(entry.name + ".md")
                        .font(DS.Fonts.sans(24, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    if entry.isNew {
                        HStack(spacing: 3) {
                            Image(systemName: "sparkle").font(DS.Fonts.sans(9, weight: .bold))
                            Text("New").font(DS.Fonts.sans(11, weight: .semibold))
                        }
                        .foregroundColor(DS.Colors.success)
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Capsule().fill(DS.Colors.success.opacity(0.14)))
                    }
                }
                if !entry.goodFor.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        detailHeading("GOOD FOR")
                        FlowLayout(spacing: 6) {
                            ForEach(entry.goodFor, id: \.self) { tag in
                                Text(tag).font(DS.Fonts.sans(12.5, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                                    .padding(.horizontal, 11).frame(height: 28)
                                    .background(Capsule().fill(DS.Colors.fillQuaternary))
                                    .overlay(Capsule().strokeBorder(DS.Colors.hairline, lineWidth: 1))
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            SkillsLibraryIconTile(icon: entry.icon, sideLength: 76)
        }
    }

    private func pendingNote(_ pending: SkillStore.PendingInstall) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield").foregroundColor(DS.Colors.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text("From \(pending.sourceDescription)").font(DS.Fonts.bodyEmphasized).foregroundColor(DS.Colors.textPrimary)
                Text(pendingCaption(pending)).font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .teachyWell(cornerRadius: 10)
    }

    private func pendingCaption(_ pending: SkillStore.PendingInstall) -> String {
        var caption = "Teachy reads this when you're in that app. Only add skills from people you trust."
        if let replaced = pending.replacesBuiltInSkillNamed { caption += " It replaces Teachy's built-in \(replaced) notes." }
        return caption
    }

    private func detailHeading(_ text: String) -> some View {
        Text(text).font(DS.Fonts.sans(10.5, weight: .bold)).tracking(1.4).foregroundColor(DS.Colors.textTertiary)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    if downloadCount != nil {
                        Image(systemName: "arrow.down.circle.fill").font(DS.Fonts.sans(13)).foregroundColor(DS.Colors.textTertiary)
                    }
                    Text(footerCaption).font(DS.Fonts.sans(13, weight: .semibold))
                        .foregroundColor(downloadCount != nil ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                }
                Spacer(minLength: 8)
                Text("Created by").font(DS.Fonts.sans(12.5)).foregroundColor(DS.Colors.textTertiary)
                HStack(spacing: 6) {
                    Text(String(entry.author.prefix(1)).uppercased())
                        .font(DS.Fonts.sans(10.5, weight: .bold)).foregroundColor(DS.Colors.onPointer)
                        .frame(width: 20, height: 20).background(Circle().fill(DS.Colors.pointer))
                    Text(entry.author).font(DS.Fonts.sans(13, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                }
                .padding(.leading, 4).padding(.trailing, 10).frame(height: 28)
                .background(Capsule().fill(DS.Colors.fillQuaternary))
            }
            actionButtons
            if let error = store.lastError {
                Text(error).font(DS.Fonts.caption).foregroundColor(DS.Colors.destructiveText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 32).padding(.vertical, 20)
    }

    private var footerCaption: String {
        if let downloads = SkillDownloadCounts.label(for: downloadCount) {
            return [downloads, entry.version.map { "v\($0)" }].compactMap { $0 }.joined(separator: " · ")
        }
        var parts: [String] = []
        if let version = entry.version { parts.append("Version \(version)") }
        if case .mine = entry.source { parts.append("On this Mac") }
        return parts.joined(separator: " · ")
    }

    /// Only market listings have a count, and only once the counter has answered.
    private var downloadCount: Int? {
        guard case .market(let listing) = entry.source, let counts = store.downloadCounts else { return nil }
        return counts[listing.id] ?? 0
    }

    @ViewBuilder private var actionButtons: some View {
        switch entry.source {
        case .market(let listing):
            switch store.installState(of: listing) {
            case .notInstalled:
                if store.installingListingIDs.contains(listing.id) {
                    ProgressView().controlSize(.small).frame(height: 44)
                } else {
                    bigButton("Add skill", symbol: "plus.circle.fill") { Task { await store.install(listing) } }
                }
            case .updateAvailable(let installedVersion):
                bigButton("Update from \(installedVersion) to \(listing.version)", symbol: "arrow.down.circle.fill") { Task { await store.install(listing) } }
                removeLink(for: store.userSkills.first { $0.marketID == listing.id })
            case .installed:
                addedBadge
                removeLink(for: store.userSkills.first { $0.marketID == listing.id })
            }
        case .mine(let skill):
            bigButton("Edit in text editor", symbol: "pencil.circle.fill") { store.openInEditor(skill) }
            removeLink(for: skill)
        case .pending:
            bigButton("Add skill", symbol: "plus.circle.fill") { store.confirmPendingInstall() }
            Button("Don't add") { store.cancelPendingInstall() }.teachyLinkButton(color: DS.Colors.textSecondary, font: DS.Fonts.body)
        }
    }

    private func bigButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol) }
            .teachyButton(.prominent, size: .large, isFullWidth: true)
    }

    private var addedBadge: some View {
        HStack(spacing: 7) {
            TeachyStatusMark(kind: .done, sideLength: 16)
            Text("Added. Teachy uses it in \(entry.goodFor.first ?? entry.name).")
                .font(DS.Fonts.sans(14, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
        }
        .frame(maxWidth: .infinity).frame(height: 44)
        .background(Capsule().fill(DS.Colors.fillQuaternary))
        .overlay(Capsule().strokeBorder(DS.Colors.hairline, lineWidth: 1))
    }

    @ViewBuilder private func removeLink(for skill: Skill?) -> some View {
        if let skill {
            HStack(spacing: 16) {
                Button("Show in Finder") { store.revealInFinder(skill) }.teachyLinkButton(color: DS.Colors.textSecondary, font: DS.Fonts.caption)
                Button("Remove") { store.remove(skill) }.teachyLinkButton(color: DS.Colors.destructiveText, font: DS.Fonts.caption)
            }
        }
    }
}
