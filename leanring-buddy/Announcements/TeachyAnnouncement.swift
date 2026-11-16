import Foundation

nonisolated struct TeachyAnnouncement: Equatable, Identifiable, Sendable {
    let id: String
    let version: String
    let title: String
    let message: String
    let symbol: String
    let showsDictationControls: Bool

    // Keep IDs stable when editing copy. Add a new entry for a new announcement;
    // build-number changes alone must never interrupt the user again.
    static let releases: [TeachyAnnouncement] = [
        TeachyAnnouncement(
            id: "1.0-dictation",
            version: "1.0",
            title: "Introducing dictation in Teachy",
            message: "Hold your shortcut, speak, then release. Teachy types your words into the text field you’re using.",
            symbol: "mic.fill",
            showsDictationControls: true
        )
    ]

    static func latest(for version: String, releases: [TeachyAnnouncement] = releases) -> TeachyAnnouncement? {
        releases.first { $0.version.compare(version, options: .numeric) != .orderedDescending }
    }
}

@MainActor
final class TeachyAnnouncementHistory {
    private let defaults: UserDefaults
    private let storageKey = "teachy.announcements.acknowledgedIDs"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func shouldPresent(_ announcement: TeachyAnnouncement) -> Bool {
        !(defaults.stringArray(forKey: storageKey) ?? []).contains(announcement.id)
    }

    func acknowledge(_ announcement: TeachyAnnouncement) {
        var identifiers = Set(defaults.stringArray(forKey: storageKey) ?? [])
        identifiers.insert(announcement.id)
        defaults.set(identifiers.sorted(), forKey: storageKey)
    }

    func prepareForLaunch(wasOnboarded: Bool, version: String, releases: [TeachyAnnouncement] = TeachyAnnouncement.releases) {
        // New installs already have onboarding. Baseline only announcements the
        // installed version contains, so a later update can still announce itself.
        guard !wasOnboarded else { return }
        for announcement in releases where announcement.version.compare(version, options: .numeric) != .orderedDescending {
            acknowledge(announcement)
        }
    }
}
