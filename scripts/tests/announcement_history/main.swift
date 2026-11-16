import Foundation

var failures = 0
var checks = 0
func expect(_ condition: Bool, _ description: String) {
    checks += 1
    if !condition { failures += 1 }
    print("\(condition ? "PASS" : "FAIL"): \(description)")
}
func announcement(_ id: String, version: String = "1.0") -> TeachyAnnouncement {
    TeachyAnnouncement(id: id, version: version, title: "Fixture", message: "Fixture", symbol: "mic", showsDictationControls: false)
}
MainActor.assumeIsolated {
let suite = "TeachyAnnouncementTests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let history = TeachyAnnouncementHistory(defaults: defaults)
let current = announcement("dictation")
let future = announcement("future", version: "2.0")
defaults.set("keep", forKey: "unrelatedSetting")
history.prepareForLaunch(wasOnboarded: true, version: "1.0", releases: [future, current])
expect(history.shouldPresent(current), "existing onboarded user receives announcement")
expect(history.shouldPresent(current), "eligibility does not acknowledge before dismissal")
history.acknowledge(current)
expect(!history.shouldPresent(current), "dismissal prevents repeat")
let restarted = TeachyAnnouncementHistory(defaults: defaults)
expect(!restarted.shouldPresent(current), "dismissal persists across relaunch")
history.acknowledge(current)
expect(!restarted.shouldPresent(current), "duplicate dismissal is harmless")
expect(defaults.string(forKey: "unrelatedSetting") == "keep", "other preferences are preserved")
expect(history.shouldPresent(announcement("second-feature")), "new announcement in same version can appear")
expect(history.shouldPresent(future), "future announcement remains unseen")
let firstInstall = announcement("fresh")
history.prepareForLaunch(wasOnboarded: false, version: "1.0", releases: [future, firstInstall])
expect(!history.shouldPresent(firstInstall), "fresh install uses onboarding instead of announcement")
expect(history.shouldPresent(future), "fresh install does not acknowledge future releases")
let ninth = announcement("ninth", version: "1.9")
let tenth = announcement("tenth", version: "1.10")
expect(TeachyAnnouncement.latest(for: "1.9", releases: [tenth, ninth]) == ninth, "numeric comparison excludes 1.10 on 1.9")
expect(TeachyAnnouncement.latest(for: "1.10", releases: [tenth, ninth]) == tenth, "numeric comparison includes 1.10")
expect(TeachyAnnouncement.latest(for: "0.9", releases: [current]) == nil, "older app has no eligible announcement")
expect(TeachyAnnouncement.latest(for: "1.0", releases: []) == nil, "empty catalog has no announcement")
print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)

}
