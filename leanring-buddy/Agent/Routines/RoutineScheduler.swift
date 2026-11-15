//
//  RoutineScheduler.swift
//  leanring-buddy
//
//  Runs routines while Teachy is open. Start it once:
//
//      RoutineScheduler.shared.start(using: backgroundAgentManager)
//
//  - Checks every 30 seconds for routines that are due and runs each as an
//    unattended job (no card, no speech, nobody to ask: see AgentToolGate).
//  - After sleep or a relaunch a routine that missed slots runs ONCE, not once
//    per missed slot (the maths is in RoutineSchedule / RoutineBook).
//  - Waits for the Mac to be awake and online before running anything.
//  - Three failed runs in a row pause a routine.
//  - Results land in `routines` with `hasUnreadResult` set. Nothing is spoken.
//

import AppKit
import Combine
import Foundation
import Network

@MainActor
final class RoutineScheduler: ObservableObject {
    static let shared = RoutineScheduler(store: RoutineStore(fileURL: AgentHome.routinesFile))

    static let checkInterval: TimeInterval = 30
    /// After waking, give the network a moment before running anything.
    static let settleAfterWake: TimeInterval = 12

    @Published private(set) var routines: [Routine] = []
    @Published private(set) var runningIDs: Set<String> = []
    /// Set when routines.json could not be read or written.
    @Published private(set) var storeProblem: String?

    private let store: RoutineStore
    private var book = RoutineBook()
    private var hasLoaded = false
    private var hasStarted = false
    private weak var manager: BackgroundAgentManager?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var isOnline = true
    private var notBefore = Date.distantPast
    private var loadedFileWasUnreadable = false

    /// How one run is carried out. Replaced in tests; the app runs an unattended agent job.
    var runner: ((Routine) async -> RoutineRunOutcome)?

    init(store: RoutineStore) {
        self.store = store
    }

    var unreadCount: Int { book.unreadCount }

    // MARK: Starting

    /// The one call the app makes. Safe to call again.
    func start(using manager: BackgroundAgentManager) {
        self.manager = manager
        loadIfNeeded()
        guard !hasStarted else { return }
        hasStarted = true

        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkNow() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.didWake() }
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(isOnline: online) }
        }
        monitor.start(queue: DispatchQueue(label: "teachy.routines.network"))
        pathMonitor = monitor

        // A relaunch is like a wake: whatever was missed while Teachy was closed runs once.
        notBefore = Date().addingTimeInterval(Self.settleAfterWake)
        scheduleCheck(after: Self.settleAfterWake + 0.5)
    }

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        let loaded = store.load()
        book = loaded.book
        storeProblem = loaded.problem
        loadedFileWasUnreadable = loaded.problem != nil
        routines = book.routines
    }

    private func didWake() {
        notBefore = Date().addingTimeInterval(Self.settleAfterWake)
        scheduleCheck(after: Self.settleAfterWake + 0.5)
    }

    private func networkChanged(isOnline: Bool) {
        let cameBack = isOnline && !self.isOnline
        self.isOnline = isOnline
        if cameBack { scheduleCheck(after: 2) }
    }

    private func scheduleCheck(after seconds: TimeInterval) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            self?.checkNow()
        }
    }

    // MARK: The check

    /// Runs whatever is due, if the Mac is awake, settled and online.
    func checkNow(now: Date = Date()) {
        guard hasStarted, isOnline, now >= notBefore else { return }
        for routine in book.due(now: now, calendar: .autoupdatingCurrent, running: runningIDs) {
            run(routine, now: now)
        }
    }

    private func run(_ routine: Routine, now: Date) {
        guard !runningIDs.contains(routine.id) else { return }
        runningIDs.insert(routine.id)
        // The slot is spent as soon as the run starts, so quitting mid-run cannot make it fire in a loop.
        book.markStarted(id: routine.id, now: now)
        persist()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.carryOut(routine)
            self.book.record(outcome, id: routine.id, now: Date())
            self.runningIDs.remove(routine.id)
            self.persist()
        }
    }

    private func carryOut(_ routine: Routine) async -> RoutineRunOutcome {
        if let runner { return await runner(routine) }
        guard let manager else { return .failed(reason: "Teachy's agent was not ready.") }
        return await manager.runRoutine(routine)
    }

    // MARK: Changing the list

    @discardableResult
    func create(task: String, schedule: RoutineSchedule, agentSlug: String?, now: Date = Date()) throws -> Routine {
        loadIfNeeded()
        let cleanTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanTask.count >= 3 else { throw RoutineScheduleError(message: "Say what the routine should do each time.") }
        guard book.routines.count < 50 else { throw RoutineScheduleError(message: "That is a lot of routines. Delete one first.") }
        let routine = Routine(agentSlug: agentSlug, task: String(cleanTask.prefix(1_000)), schedule: schedule, createdAt: now)
        book.routines.append(routine)
        persist()
        if let storeProblem { throw RoutineScheduleError(message: storeProblem) }
        return routine
    }

    /// "every weekday at 9 check my GitHub notifications" → a saved routine. One small model call.
    @discardableResult
    func createFromText(_ sentence: String) async throws -> Routine {
        let agents = AgentRoster.shared.reload()
        let draft = try await RoutineInterpreter.interpret(sentence, agentNames: agents.map(\.name))
        // Only an agent the person actually named, and only one that exists.
        let named = draft.agentName.flatMap { AgentRoster.bestMatch(for: $0, among: agents) } ?? AgentRoster.bestMatch(for: sentence, among: agents)
        return try create(task: draft.task, schedule: draft.schedule, agentSlug: named?.slug)
    }

    func setEnabled(id: String, _ enabled: Bool) {
        loadIfNeeded()
        book.setEnabled(enabled, id: id, now: Date())
        persist()
    }

    func delete(id: String) {
        loadIfNeeded()
        book.remove(id: id)
        persist()
    }

    /// Runs it now, whatever its schedule says. Still unattended: it cannot ask for anything.
    func runNow(id: String) {
        loadIfNeeded()
        guard let routine = book.routines.first(where: { $0.id == id }) else { return }
        run(routine, now: Date())
    }

    func markRead(id: String) {
        loadIfNeeded()
        guard book.routines.contains(where: { $0.id == id && $0.hasUnreadResult }) else { return }
        book.markRead(id: id)
        persist()
    }

    /// A routine by its id or the first characters of it (what the model is shown).
    func routine(matching idOrPrefix: String) -> Routine? {
        loadIfNeeded()
        let wanted = idOrPrefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard wanted.count >= 4 else { return nil }
        let matches = book.routines.filter { $0.id.lowercased().hasPrefix(wanted) }
        return matches.count == 1 ? matches[0] : nil
    }

    private func persist() {
        routines = book.routines
        do {
            if loadedFileWasUnreadable {
                // Keep the file that could not be read instead of writing over it.
                let aside = store.fileURL.deletingLastPathComponent().appendingPathComponent("routines.unreadable.json")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: store.fileURL, to: aside)
                loadedFileWasUnreadable = false
            }
            try store.save(book)
            storeProblem = nil
        } catch {
            storeProblem = "Couldn't save routines: \(error.localizedDescription)"
        }
    }
}
