// Run: scripts/tests/render_agents2_shots.sh
// Renders the job cards (one, stacked, finished, folded), the Home tab's agents cards and the
// connectors "Popular" strip to PNG files, without launching Teachy and without touching
// ~/.teachy. Nothing is put on screen. Output: $TMPDIR/agents2-shots/
import AppKit
import SwiftUI

@MainActor
func runShots() {
    let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agents2-shots", isDirectory: true)
    try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    var failures = 0

    func writePNG(_ view: NSView, name: String) {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { failures += 1; print("FAIL no bitmap for \(name)"); return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { failures += 1; print("FAIL no PNG for \(name)"); return }
        let url = outputDirectory.appendingPathComponent(name + ".png")
        try? data.write(to: url)
        print("wrote \(url.path) (\(Int(view.bounds.width))x\(Int(view.bounds.height)))")
    }

    /// Hosts a SwiftUI view in a window that is never shown.
    func render<V: View>(_ view: V, width: CGFloat?, name: String) {
        let sized = width.map { AnyView(view.frame(width: $0)) } ?? AnyView(view.fixedSize())
        let hosting = NSHostingView(rootView: sized.environment(\.colorScheme, .dark))
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        if size.width < 10 || size.height < 10 { failures += 1; print("FAIL \(name) has no size") }
        writePNG(hosting, name: name)
    }

    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)

    /// What is behind the cards under the notch: someone's desktop. A mid grey shows the card edges.
    func underNotch<V: View>(_ view: V) -> some View {
        view.padding(16).background(Color(white: 0.32))
    }
    /// The notch panel is black.
    func onNotch<V: View>(_ view: V) -> some View {
        view.padding(8).background(Color.black)
    }
    let homeWidth: CGFloat = 640 - 2 * 12 - 2 * 8

    // MARK: Job cards

    func plan(_ steps: [String], current: Int) -> AgentPlan {
        AgentPlan.parse(arguments: ["steps": steps, "current_step": current])!.plan
    }
    let running = AgentJobCardModel(
        id: "1", title: "Umbrella Check", status: .running,
        plan: plan(["Find tomorrow's forecast", "Read the calendar", "Compare plans and rain"], current: 2),
        activity: "Reading a file"
    )
    let asAgent = AgentJobCardModel(
        id: "2", title: "Laptop Prices", agentName: "Research buddy", status: .running,
        plan: plan(["Search for the Framework 13", "Search for the MacBook Air", "Compare and report"], current: 1),
        activity: "Searching the web"
    )
    let planning = AgentJobCardModel(id: "3", title: "Tidy Notes", status: .planning, activity: "Thinking")
    let queued = AgentJobCardModel(id: "4", title: "Weekly Report", agentName: "Builder", status: .queued, activity: "Waiting for another job to finish")
    let waiting = AgentJobCardModel(
        id: "5", title: "Crop Photo", status: .waitingForConsent,
        plan: plan(["Open the photo in Preview", "Crop to a square", "Save a copy"], current: 2),
        activity: "Pressing a control"
    )
    let done = AgentJobCardModel(
        id: "6", title: "Umbrella Check", status: .done,
        plan: plan(["Find tomorrow's forecast", "Read the calendar", "Compare plans and rain"], current: 4),
        answer: "Take an umbrella to your 5 p.m. football game at the riverfront: thunderstorms are likely from 4 to 7 p.m. Your online standup and dinner at home don't call for one.",
        elapsed: "7s"
    )
    let failed = AgentJobCardModel(id: "7", title: "Inbox Hunter", status: .failed("The job ran past 10 minutes before it could finish."), elapsed: "10m 2s")
    let stopped = AgentJobCardModel(id: "8", title: "Rename Files", status: .stopped("you pressed Stop"), answer: "Okay, I've stopped.", elapsed: "12s")
    let longTitle = AgentJobCardModel(
        id: "9", title: "Quarterly Subscription Reconciliation", agentName: "Research buddy with a long name", status: .running,
        plan: plan(["Collect every subscription charge from the last three months of statements", "Group by merchant"], current: 1),
        activity: "Reading a signed-in page"
    )

    render(underNotch(AgentJobCard(model: running)), width: nil, name: "01-card-running")
    render(underNotch(AgentJobCardStack(front: asAgent, index: 2, count: 3)), width: nil, name: "02-stack-three-jobs")
    render(underNotch(AgentJobCardStack(front: running, index: 1, count: 2)), width: nil, name: "03-stack-two-jobs")
    render(underNotch(AgentJobCard(model: planning)), width: nil, name: "04-card-planning")
    render(underNotch(AgentJobCardStack(front: queued, index: 5, count: 5)), width: nil, name: "05-card-queued-fifth")
    render(underNotch(AgentJobCard(model: waiting)), width: nil, name: "06-card-waiting-for-answer")
    render(underNotch(AgentJobCard(model: done)), width: nil, name: "07-card-done-answer-copy")
    render(underNotch(AgentJobCard(model: done, didCopy: true)), width: nil, name: "08-card-done-copied")
    render(underNotch(AgentJobCardStack(front: done, index: 1, count: 2, isCollapsed: true)), width: nil, name: "09-card-done-folded")
    render(underNotch(AgentJobCard(model: failed)), width: nil, name: "10-card-failed")
    render(underNotch(AgentJobCard(model: stopped)), width: nil, name: "11-card-stopped")
    render(underNotch(AgentJobCardStack(front: longTitle, index: 2, count: 4)), width: nil, name: "12-card-long-text")

    // MARK: Home tab cards

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 15, minute: 20))!
    func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    let agents = [
        AgentProfile(slug: "builder", name: "Builder", role: "Builds small apps, scripts and sites on this Mac."),
        AgentProfile(slug: "research-buddy", name: "Research buddy", role: "Finds things out and tells you what matters."),
        AgentProfile(slug: "inbox-helper", name: "Inbox helper", role: "")
    ]

    var github = Routine(id: "r1", task: "Check my GitHub notifications and tell me which ones need me.", schedule: .weekdays(hour: 9, minute: 0), createdAt: ago(5_000))
    github.lastRun = ago(380)
    github.lastResult = "Three need you: a review request on teachy#212 from Kabir, a failing check on your branch agents2, and a mention in the Publik HQ discussion about pricing."
    github.lastStatus = "ok"
    github.hasUnreadResult = true
    var news = Routine(id: "r2", agentSlug: "research-buddy", task: "Look at the Hacker News front page and tell me if anything about Swift shows up.", schedule: .every(minutes: 30), createdAt: ago(900))
    news.lastRun = ago(12)
    news.lastResult = "Nothing about Swift on the front page right now."
    news.lastStatus = "ok"
    var mail = Routine(id: "r3", task: "Reply to anyone who asked about the fellowship with the standard answer.", schedule: .daily(hour: 18, minute: 0), createdAt: ago(3_000))
    mail.lastRun = ago(1_280)
    mail.lastResult = "Two people asked. I drafted nothing.\nCould not use gmail send message: it needs your yes. Run it yourself once and choose Always allow if you want routines to do this."
    mail.lastStatus = "needs you"
    var broken = Routine(id: "r4", task: "Check whether teachy.app is up.", schedule: .every(minutes: 60), enabled: false, createdAt: ago(9_000))
    broken.lastRun = ago(2_900)
    broken.lastResult = "The request timed out."
    broken.lastStatus = "failed"
    broken.consecutiveFailures = 3
    broken.pausedReason = "Paused after 3 failed runs in a row."

    func record(_ id: String, title: String, status: String, minutesAgo: Double, agent: String? = nil, routine: String? = nil, answer: String, detail: String = "", refusals: [String] = [], steps: [AgentJobRecord.Step] = [], followUps: [String] = []) -> AgentJobRecord {
        AgentJobRecord(
            id: id, title: title, request: "Look up the weather in Ahmedabad for tomorrow, then read my calendar and tell me whether I need an umbrella for anything on it.",
            agentSlug: agent.map { AgentRoster.slug(for: $0) }, agentName: agent, routineID: routine,
            plan: [], steps: steps, answer: answer, status: status, statusDetail: detail, refusals: refusals, followUps: followUps,
            startedAt: ago(minutesAgo + 1), finishedAt: ago(minutesAgo)
        )
    }
    let jobs = [
        record("j1", title: "Umbrella Check", status: "done", minutesAgo: 3,
               answer: "Take an umbrella to your 5 p.m. football game at the riverfront: thunderstorms are likely from 4 to 7 p.m. Your online standup and dinner at home don't call for one.",
               steps: [
                .init(tool: "web_search", result: "Ahmedabad forecast for tomorrow: 31°C high, 22°C low. Thunderstorms likely between 4 pm and 7 pm (70% chance of rain). Dry in the morning.", seconds: 0.8),
                .init(tool: "read_file", result: "Tomorrow: 09:30 Standup (online) 17:00 Football with Kabir at the riverfront ground 20:30 Dinner at home", seconds: 0.1)
               ], followUps: ["and what about Sunday?"]),
        record("j2", title: "Laptop Prices", status: "done", minutesAgo: 48, agent: "Research buddy", answer: "The Framework Laptop 13 is cheaper: it starts at 899 dollars, the MacBook Air M4 at 999."),
        record("j3", title: "GitHub Check", status: "done", minutesAgo: 380, routine: "r1", answer: "Three need you."),
        record("j4", title: "Fellowship Replies", status: "done", minutesAgo: 1_280, routine: "r3", answer: "Two people asked. I drafted nothing.", refusals: ["Could not use gmail send message: it needs your yes."]),
        record("j5", title: "Inbox Hunter", status: "failed", minutesAgo: 1_500, answer: "", detail: "The job ran past 10 minutes before it could finish."),
        record("j6", title: "Rename Files", status: "stopped", minutesAgo: 2_900, agent: "Builder", answer: "Okay, I've stopped.", detail: "you pressed Stop"),
        record("j7", title: "Older Job", status: "done", minutesAgo: 4_400, answer: "Done."),
        record("j8", title: "Oldest Job", status: "done", minutesAgo: 9_000, answer: "Done.")
    ]

    render(onNotch(AgentsSectionContent(agents: agents, routines: [github, news, mail, broken], runningRoutineIDs: ["r2"], jobs: jobs, now: now, calendar: calendar)), width: homeWidth, name: "20-home-agents-routines-jobs")
    render(onNotch(AgentsSectionContent(agents: agents, routines: [github, mail], jobs: jobs, initiallyExpandedJobID: "j1", initiallyExpandedRoutineID: "r3", now: now, calendar: calendar)), width: homeWidth, name: "21-home-job-and-result-opened")
    render(onNotch(AgentsSectionContent(agents: [], routines: [], jobs: [], now: now, calendar: calendar)), width: homeWidth, name: "22-home-empty")

    // MARK: Connectors: Popular

    struct StripHost: View {
        var busyID: String?
        var keyEntry: ConnectorCatalogEntry?
        var error: String?
        @State private var key = ""
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("Connectors").font(.system(size: 12, weight: .bold)).foregroundColor(DS.Colors.textPrimary)
                Text("Give Teachy tools from your other apps. Add an MCP server by its URL, or a command that runs one on this Mac.")
                    .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary).fixedSize(horizontal: false, vertical: true)
                ConnectorPopularStrip(
                    entries: ConnectorCatalog.entries,
                    addedURLs: ["https://mcp.notion.com/mcp"],
                    busyID: busyID,
                    keyEntry: keyEntry,
                    key: $key,
                    error: error
                )
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
        }
    }
    let githubEntry = ConnectorCatalog.entries.first { $0.id == "github" }
    render(onNotch(StripHost()), width: homeWidth, name: "30-connectors-popular")
    render(onNotch(StripHost(busyID: "linear", keyEntry: githubEntry, error: "Linear did not answer. Try again in a moment.")), width: homeWidth, name: "31-connectors-popular-key-and-error")

    print(failures == 0 ? "all shots rendered" : "\(failures) shot(s) failed")
    exit(failures == 0 ? 0 : 1)
}

MainActor.assumeIsolated { runShots() }
