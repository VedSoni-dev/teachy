import AppKit
import SwiftUI

/// Settings → Skills: the skills on this Mac (yours and the built-in ones), adding one from a
/// file or a blank template, and the Skill Market. A skill tells Teachy where things are in
/// one app or site; the one for the app you're in goes into what Teachy reads.
struct TeachySkillsSettingsPage: View {
    /// The shared store in the app; the off-screen renders pass one backed by temp folders.
    @ObservedObject var store: SkillStore = .shared
    @State private var showsBuiltInSkills = false
    /// Off in the off-screen renders, which have no network.
    var loadsMarketOnAppear = true

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            libraryGroup
            yourSkillsGroup
            builtInGroup
        }
        .task {
            store.refreshInstalledSkills()
            if loadsMarketOnAppear { await store.loadMarketIfNeeded() }
        }
    }

    // MARK: Yours

    private var yourSkillsGroup: some View {
        SettingsPageGroup(title: "Your skills") {
            if store.userSkills.isEmpty {
                SettingsPageLabel(title: "No skills added yet", caption: "Add one from the Skills Library, or write your own: a short Markdown file on where things are in an app.")
            } else {
                ForEach(Array(store.userSkills.enumerated()), id: \.offset) { position, skill in
                    if position > 0 { TeachyRule() }
                    userSkillRow(skill)
                }
            }
            TeachyRule()
            HStack(spacing: 8) {
                Button("Create a skill") { store.createNewSkill() }.teachyButton(.secondary, size: .compact)
                Button("Add from file…") { store.chooseFileToAdd() }.teachyButton(.secondary, size: .compact)
                Spacer()
                Button("Open skills folder") { store.openSkillsFolder() }.teachyLinkButton()
            }
            if let error = store.lastError {
                Text(error).font(DS.Fonts.caption).foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func userSkillRow(_ skill: Skill) -> some View {
        HStack(alignment: .center, spacing: 12) {
            SkillsLibraryIconTile(icon: skill.icon, sideLength: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(skill.name).font(DS.Fonts.bodyEmphasized).foregroundColor(DS.Colors.textPrimary)
                Text(userSkillCaption(skill)).font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Menu {
                Button("Edit") { store.openInEditor(skill) }
                Button("Show in Finder") { store.revealInFinder(skill) }
                Divider()
                Button("Remove", role: .destructive) { store.remove(skill) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .teachyIconButton()
            .pointerCursor()
            .accessibilityLabel("Options for \(skill.name)")
        }
    }

    private func userSkillCaption(_ skill: Skill) -> String {
        var parts: [String] = []
        if skill.marketID != nil {
            parts.append(skill.author.map { "Skill Market · \($0)" } ?? "Skill Market")
        } else {
            parts.append("Yours")
        }
        let target = targetsDescription(skill)
        if !target.isEmpty { parts.append(target) }
        if store.bundledSkills.contains(where: { $0.name.lowercased() == skill.name.lowercased() }) {
            parts.append("replaces the built-in one")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Library

    private var libraryGroup: some View {
        SettingsPageGroup(title: "Skills Library") {
            HStack(spacing: 14) {
                HStack(spacing: -10) {
                    ForEach(Array(store.listings.prefix(4).enumerated()), id: \.element.id) { _, listing in
                        SkillsLibraryIconTile(icon: listing.icon, sideLength: 38)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DS.Colors.surface2))
                    }
                }
                SettingsPageLabel(title: "Skills from the community", caption: libraryCaption)
                Spacer(minLength: 8)
                Button("Open Skills Library") { SkillsLibraryWindowController.shared.show() }
                    .teachyButton(.primary, size: .regular)
            }
            if updatesAvailable > 0 {
                TeachyRule()
                HStack(spacing: 8) {
                    TeachyStatusMark(kind: .needsYou, sideLength: 13)
                    Text(updatesAvailable == 1 ? "1 of your skills has an update." : "\(updatesAvailable) of your skills have updates.")
                        .font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                }
            }
        }
    }

    private var libraryCaption: String {
        switch store.marketLoadState {
        case .loaded: return "\(store.listings.count) skills shared by people who use Teachy. Add one in a click, or publish your own."
        case .failed: return "Couldn't reach the Skill Market right now. Your skills still work."
        case .idle, .loading: return "Skills shared by people who use Teachy."
        }
    }

    private var updatesAvailable: Int {
        store.listings.filter { if case .updateAvailable = store.installState(of: $0) { return true } else { return false } }.count
    }

    // MARK: Built in

    private var builtInGroup: some View {
        SettingsPageGroup(title: "Built in") {
            Button { withAnimation(DS.Motion.standard) { showsBuiltInSkills.toggle() } } label: {
                HStack {
                    SettingsPageLabel(title: "\(store.bundledSkills.count) apps Teachy already knows", caption: "Add a skill with the same name to replace one.")
                    Spacer()
                    Image(systemName: showsBuiltInSkills ? "chevron.up" : "chevron.down").foregroundColor(DS.Colors.textTertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).pointerCursor()
            if showsBuiltInSkills {
                FlowLayout(spacing: 6) {
                    ForEach(store.bundledSkills.map(\.name), id: \.self) { name in
                        Text(name).font(DS.Fonts.sans(11, weight: .medium)).foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(DS.Colors.fillQuaternary, in: Capsule())
                    }
                }
            }
        }
    }

    // MARK: Pieces

    private func targetsDescription(_ skill: Skill) -> String {
        // A Mac app reads better than a URL fragment; site-only skills show their main host.
        if !skill.bundleIDs.isEmpty { return "the \(skill.name) app" }
        guard let site = skill.sites.first else { return "" }
        return site.split(separator: "/").first.map(String.init) ?? site
    }
}
