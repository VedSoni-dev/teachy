//
//  DrawingsSection.swift
//  leanring-buddy / Scene
//
//  The "Drawings" card for the notch panel's Home tab: a grid of the drawings
//  Teachy has made, each with Replay and Save video. Mount it with
//  `DrawingsSection()`. It reads and writes `SceneHistory.shared` and needs
//  nothing else from the app but the design tokens.
//
//  Looks like the settings cards (SettingsDisclosureCard): a glass card that
//  starts collapsed with a one-line summary.
//

import AppKit
import SwiftUI

struct DrawingsSection: View {
    @ObservedObject private var history: SceneHistory
    @State private var isExpanded: Bool
    @State private var showsAll = false
    @State private var problem: String?

    /// How many drawings are shown before "Show all".
    private let previewCount = 4

    init(history: SceneHistory? = nil, startsExpanded: Bool = false) {
        self.history = history ?? SceneHistory.shared
        self._isExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.smooth(duration: 0.22)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "scribble.variable")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.learnAccent)
                        .frame(width: 16)
                    Text("Drawings")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Spacer(minLength: 8)
                    if !isExpanded {
                        Text(summary)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    content
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .onAppear { history.reload() }
    }

    private var summary: String {
        switch history.entries.count {
        case 0: return "None yet"
        case 1: return "1 saved"
        default: return "\(history.entries.count) saved"
        }
    }

    @ViewBuilder
    private var content: some View {
        if history.entries.isEmpty {
            Text("Ask Teachy to show you something, like “show me how a jet engine works”. Each drawing is kept here so you can play it again or save it as a video.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let shown = showsAll ? history.entries : Array(history.entries.prefix(previewCount))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], alignment: .leading, spacing: 12) {
                ForEach(shown) { entry in
                    DrawingTile(entry: entry, thumbnail: history.thumbnail(for: entry.id), progress: history.exportProgress[entry.id],
                                onReplay: { history.replay(entry.id) },
                                onSaveVideo: { saveVideo(entry) },
                                onDelete: { history.delete(entry.id) })
                }
            }
            if let problem {
                Text(problem)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if history.entries.count > previewCount {
                Button {
                    withAnimation(.smooth(duration: 0.2)) { showsAll.toggle() }
                } label: {
                    Text(showsAll ? "Show fewer" : "Show all \(history.entries.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Color.white.opacity(0.06)
                            Image(systemName: "scribble.variable")
                                .font(.system(size: 18))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                .contentShape(Rectangle())
                .onTapGesture(perform: onReplay)

                if isHovered {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .padding(5)
                    .help("Remove this drawing")
                    .transition(.opacity)
                }
            }

            Text(entry.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("\(Self.dayText(entry.date)) · \(entry.kind)")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)

            HStack(spacing: 10) {
                Button(action: onReplay) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill").font(.system(size: 8, weight: .bold))
                        Text("Replay").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    }
                    .fixedSize()
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .pointerCursor()

                if let progress {
                    Text("Saving \(Int((progress * 100).rounded()))%")
                        .lineLimit(1)
                        .fixedSize()
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .monospacedDigit()
                } else {
                    Button(action: onSaveVideo) {
                        Text("Save video")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help(entry.hasNarration ? "Save as a video with the voice" : "Save as a video (no sound)")
                }
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: DS.Animation.fast)) { isHovered = hovering }
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
