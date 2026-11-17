//
//  DrawingsSection.swift
//  leanring-buddy / Scene
//
//  The "Drawings" section for the notch panel's Home tab: a grid of the drawings
//  Teachy has made, each with Replay and Save video. Mount it with
//  `DrawingsSection()`. It reads and writes `SceneHistory.shared` and needs
//  nothing else from the app but the design tokens.
//
//  A standalone section, like the others on Home: a heading with the count
//  beside it, then one grouped container. The heading opens and closes the
//  section, and it starts closed so Home stays short.
//

import AppKit
import SwiftUI

struct DrawingsSection: View {
    @ObservedObject private var history: SceneHistory
    @State private var isExpanded: Bool
    @State private var isHeaderHovered = false
    @State private var showsAll = false
    @State private var problem: String?
    @Environment(\.accessibilityReduceMotion) private var isReduceMotionEnabled

    /// How many drawings are shown before "Show all".
    private let projectOptions: [(id: String, name: String)]
    private let previewCount = 4

    init(history: SceneHistory? = nil, startsExpanded: Bool = false, projectOptions: [(id: String, name: String)] = []) {
        self.projectOptions = projectOptions
        self.history = history ?? SceneHistory.shared
        self._isExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                withAnimation(isReduceMotionEnabled ? DS.Motion.reduced : DS.Motion.standard) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TeachySectionTitle(title: "Drawings", detail: summary)
                    Image(systemName: "chevron.right")
                        .font(DS.Fonts.sans(10, weight: .semibold))
                        .foregroundColor(isHeaderHovered ? DS.Colors.textSecondary : DS.Colors.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .onHover { hovering in
                withAnimation(DS.Motion.hover) { isHeaderHovered = hovering }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                .teachyGroup()
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { history.reload() }
    }

    private var summary: String {
        switch history.entries.count {
        case 0: return "None yet"
        case 1: return "1 saved"
        default: return "\(history.entries.count) saved"
        }
    }

    /// The rows of the group: the drawings, then "Show all" under a divider.
    @ViewBuilder
    private var content: some View {
        if history.entries.isEmpty {
            Text("Ask Teachy to show you something, like “show me how a jet engine works”. Each drawing is kept here so you can play it again or save it as a video.")
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 12)
        } else {
            let shown = showsAll ? history.entries : Array(history.entries.prefix(previewCount))
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], alignment: .leading, spacing: 18) {
                    ForEach(shown) { entry in
                        DrawingTile(entry: entry, thumbnail: history.thumbnail(for: entry.id), progress: history.exportProgress[entry.id],
                                    onReplay: { history.replay(entry.id) },
                                    onSaveVideo: { saveVideo(entry) },
                                    onDelete: { history.delete(entry.id) })
                            .contextMenu {
                                if !projectOptions.isEmpty {
                                    Menu("Move to project") {
                                        ForEach(projectOptions, id: \.id) { option in
                                            Button(option.name) { move(entry, to: option.id) }
                                                .disabled(entry.projectID == option.id)
                                        }
                                        Divider()
                                        Button("Unassigned") { move(entry, to: nil) }
                                            .disabled(entry.projectID == nil)
                                    }
                                }
                            }
                    }
                }
                if let problem {
                    Text(problem)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.destructiveText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 14)

            if history.entries.count > previewCount {
                TeachyRule()
                Button(showsAll ? "Show fewer" : "Show all \(history.entries.count)") {
                    withAnimation(isReduceMotionEnabled ? DS.Motion.reduced : DS.Motion.standard) { showsAll.toggle() }
                }
                .teachyLinkButton(font: DS.Fonts.body)
                .padding(.vertical, 10)
            }
        }
    }

    private func move(_ entry: SceneHistoryEntry, to projectID: String?) {
        problem = history.assign(entryID: entry.id, toProjectID: projectID) ? nil : "Couldn’t move this drawing."
    }

    private func saveVideo(_ entry: SceneHistoryEntry) {
        problem = nil
        Task {
            do {
                let url = try await history.export(entry.id)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// One saved drawing: its picture, what it is, and the two things you can do with it.
struct DrawingTile: View {
    let entry: SceneHistoryEntry
    let thumbnail: NSImage?
    /// 0–1 while the video is being made.
    let progress: Double?
    var onReplay: () -> Void
    var onSaveVideo: () -> Void
    var onDelete: () -> Void

    @State private var isHovered = false

    private var pictureShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            DS.Colors.fillTertiary
                            Image(systemName: "scribble.variable")
                                .font(DS.Fonts.sans(16))
                                .foregroundColor(DS.Colors.textQuaternary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(pictureShape)
                .overlay(pictureShape.strokeBorder(isHovered ? DS.Colors.hairlineStrong : DS.Colors.hairline, lineWidth: 1))
                .contentShape(Rectangle())
                .onTapGesture(perform: onReplay)
                .pointerCursor()

                if isHovered {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundColor(DS.Colors.destructiveText)
                    }
                    .teachyIconButton(sideLength: 22)
                    // A disc of notch black under the symbol, so it reads over any picture.
                    .background(Circle().fill(DS.Colors.notchBlack))
                    .padding(5)
                    .help("Remove this drawing")
                    .transition(.opacity)
                }
            }
            .padding(.bottom, 4)

            Text(entry.title)
                .font(DS.Fonts.itemTitle)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("\(Self.dayText(entry.date)) · \(entry.kind)")
                .font(DS.Fonts.data)
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)

            HStack(spacing: 12) {
                Button(action: onReplay) {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                            .font(DS.Fonts.sans(8, weight: .bold))
                        Text("Replay")
                    }
                    .fixedSize()
                }
                .teachyButton(.secondary, size: .compact)

                if let progress {
                    // The video is being made right now: the live mark.
                    HStack(spacing: 5) {
                        TeachyStatusMark(kind: .live, sideLength: 11)
                        Text("Saving \(Int((progress * 100).rounded()))%")
                            .font(DS.Fonts.data)
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                    }
                    .fixedSize()
                } else {
                    Button("Save video", action: onSaveVideo)
                        .teachyLinkButton()
                        .fixedSize()
                        .help(entry.hasNarration ? "Save as a video with the voice" : "Save as a video (no sound)")
                }
            }
            .padding(.top, 4)
        }
        .onHover { hovering in
            withAnimation(DS.Motion.hover) { isHovered = hovering }
        }
    }

    static func dayText(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate(calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "d MMM" : "d MMM yyyy")
        return formatter.string(from: date)
    }
}
