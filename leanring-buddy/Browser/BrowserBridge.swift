//
//  BrowserBridge.swift
//  leanring-buddy
//
//  Teachy's line to its Chrome extension. The extension lets agent jobs work in
//  the person's own browser, on the sites they are signed in to, inside a tab
//  group named after the job.
//
//      BrowserBridge (this file, main actor, what the app talks to)
//        -> BrowserLink (socket, routing, request/answer pairing)
//          -> ~/Library/Application Support/Teachy/browser.sock
//            -> teachy-browser-host (the helper Chrome starts; native-host/)
//              -> the extension (chrome-extension/)
//
//  `BrowserBridge.shared.start()` once at launch. Tools call `call(...)`. The
//  permission gate calls `policyContext(...)` before a browser tool runs, and
//  the job runner calls `jobEnded(jobID:)` when a job finishes.
//
//  Nothing here reads a page by itself: every request comes from an agent tool
//  that has already been through the permission gate.
//

import AppKit
import Combine
import Foundation

struct BrowserToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

@MainActor
final class BrowserBridge: ObservableObject {
    static let shared = BrowserBridge()

    @Published private(set) var state: BrowserConnectionState = .notInstalled

    /// True when Teachy's own extension is live, so the browser_* tools can work.
    var isExtensionConnected: Bool {
        if case .connected = state { return true }
        return false
    }
    /// Browsers that have the helper's manifest ("Chrome", "Arc", …).
    @Published private(set) var browsersWithHelper: [String] = []
    /// Why the bridge could not listen, if it could not. Shown in settings.
    @Published private(set) var problem: String?

    private let supportRoot: URL
    private var link: BrowserLink?

    private struct JobRecord {
        var peer: String
        var title: String
        var currentTab: Int?
        var urlForTab: [Int: String] = [:]
        var stoppedReason: String?
        var closed = false
    }
    private var jobs: [String: JobRecord] = [:]

    /// Tests point this at a temp folder BEFORE first touching `shared`, so they never use the real
    /// ~/Library/Application Support. The app leaves it nil.
    static var supportRootForTesting: URL?

    /// One bridge per app: the socket path is fixed, and the helper looks for it there.
    private init() {
        self.supportRoot = Self.supportRootForTesting ?? BrowserHostManifest.defaultSupportRoot()
    }

    // MARK: Lifecycle

    /// Starts listening for the helper. Safe to call more than once.
    func start() {
        refreshInstallState()
        guard link == nil else { return }
        let created = BrowserLink(
            socketPath: BrowserHostManifest.socketURL(root: supportRoot).path,
            onChange: { Task { @MainActor in BrowserBridge.shared.refreshState() } },
            onEvent: { peer, name, fields in
                Task { @MainActor in BrowserBridge.shared.handleEvent(name: name, fields: fields.object, peer: peer) }
            }
        )
        do {
            try created.start()
            link = created
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        refreshState()
    }

    func stop() {
        link?.stop()
        link = nil
        jobs.removeAll()
        refreshState()
    }

    /// Looks at the disk again (after an install, or when settings opens).
    func refreshInstallState() {
        browsersWithHelper = BrowserHostManifest.installation(root: supportRoot).browsersWithManifest
        refreshState()
    }

    private func refreshState() {
        if let ready = link?.readyPeers.first {
            state = .connected(browserName: BrowserLink.displayName(forBrowser: ready.browser))
        } else if BrowserHostManifest.installation(root: supportRoot).isInstalled {
            state = .waitingForChrome
        } else {
            state = .notInstalled
        }
    }

    /// One sentence for the model about why browser tools cannot run right now.
    var unavailableExplanation: String {
        switch state {
        case .connected:
            return ""
        case .notInstalled:
            return "Teachy's browser helper is not installed on this Mac. Tell the person they can set it up in Teachy's settings under Browser, and carry on another way (web_fetch for public pages, or drive the browser window)."
        case .waitingForChrome:
            return "Teachy's browser extension is not connected: the browser may be closed, or the Teachy extension is not added or switched off. Tell the person, and carry on another way (web_fetch for public pages, or drive the browser window)."
        }
    }

    // MARK: Requests

    /// Sends one request for a job and returns the extension's result.
    func call(_ method: String, params: [String: Any] = [:], jobID: String, jobTitle: String, timeout: TimeInterval = 30) async throws -> [String: Any] {
        guard let link else { throw BrowserToolError(unavailableExplanation.isEmpty ? "The browser bridge is not running." : unavailableExplanation) }
        if let reason = jobs[jobID]?.stoppedReason {
            throw BrowserToolError("The person took the browser back (\(reason)). Stop here and tell them what is left to do.")
        }

        var full = params
        full["job"] = jobID
        if jobs[jobID] == nil || method == "open_tab" { full["name"] = jobTitle }
        if full["tab"] == nil, let current = jobs[jobID]?.currentTab, method != "open_tab", method != "close_job", method != "list_tabs" {
            full["tab"] = current
        }

        let answer: (result: [String: Any], peer: String)
        do {
            answer = try await link.request(method: method, params: full, preferredPeer: jobs[jobID]?.peer, timeout: timeout)
        } catch let error as BrowserWireError {
            throw BrowserToolError(Self.explain(error, state: state, fallback: unavailableExplanation))
        }

        var record = jobs[jobID] ?? JobRecord(peer: answer.peer, title: jobTitle)
        if let tab = Self.integer(answer.result["tab"]) {
            if method != "close_tab" { record.currentTab = tab }
            if let url = answer.result["url"] as? String, !url.isEmpty { record.urlForTab[tab] = url }
        }
        if method == "close_job" { record.closed = true }
        jobs[jobID] = record
        return answer.result
    }

    static func explain(_ error: BrowserWireError, state: BrowserConnectionState, fallback: String) -> String {
        switch error {
        case .notConnected:
            return fallback.isEmpty ? "The browser this job was working in is no longer connected. Tell the person and stop the browser part of the job." : fallback
        case .remote(let code, let message):
            switch code {
            case "user_stopped":
                return "The person took the browser back (Escape, the Teachy toolbar button, or Chrome's debugging bar). Stop here and tell them what is left to do."
            case "not_job_tab":
                return "\(message) Use browser_open first; Teachy only works in tabs that belong to the job."
            case "debugger_failed", "no_such_element", "disabled", "not_editable", "not_a_select", "no_such_option", "needs_upload", "bad_url", "bad_params", "incognito", "not_allowed":
                return message
            default:
                return "The browser could not do that (\(code)): \(message)"
            }
        default:
            return error.errorDescription ?? "The browser did not answer."
        }
    }

    static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    // MARK: Permission gate

    /// Facts for the permission question: which site the job's tab is on, and what the call's target says.
    /// Asks the extension about the one control involved (it changes nothing on the page).
    func policyContext(toolName: String, arguments: [String: Any], jobID: String) async -> BrowserRiskContext {
        var context = BrowserRiskContext()
        guard let record = jobs[jobID] else { return context }
        let tab = Self.integer(arguments["tab"]) ?? record.currentTab
        if let tab, let url = record.urlForTab[tab] { context.siteHost = BrowserRiskClassifier.host(of: url) }

        let needsControl: Set<String> = ["browser_click", "browser_type", "browser_select", "browser_key", "browser_upload"]
        guard needsControl.contains(toolName), let link, record.stoppedReason == nil else { return context }

        var params: [String: Any] = ["job": jobID]
        if let tab { params["tab"] = tab }
        if let index = Self.integer(arguments["index"]) { params["index"] = index }
        guard let info = try? await link.request(method: "describe", params: params, preferredPeer: record.peer, timeout: 4).result else {
            return context
        }
        if let host = info["host"] as? String, !host.isEmpty { context.siteHost = host }
        if let element = info["element"] as? [String: Any] {
            let role = element["role"] as? String ?? ""
            let name = element["name"] as? String ?? ""
            context.elementLabel = name.isEmpty ? role : "\(role) \"\(name)\""
        }
        context.submitLabel = info["submitLabel"] as? String ?? ""
        context.isSubmit = info["isSubmit"] as? Bool ?? false
        if let tab, let url = info["url"] as? String { jobs[jobID]?.urlForTab[tab] = url }
        return context
    }

    // MARK: Job endings

    /// The job finished (done, failed or stopped). Its working tabs close; the page it ended on stays
    /// open for the person, out of the group. A tab it borrowed goes back where it was.
    func jobEnded(jobID: String) {
        guard let record = jobs[jobID] else { return }
        jobs.removeValue(forKey: jobID)
        guard !record.closed, let link else { return }
        var params: [String: Any] = ["job": jobID]
        if let keep = record.currentTab { params["keep"] = [keep] }
        let peer = record.peer
        let payload = BrowserPayload(params)
        Task.detached {
            _ = try? await link.request(method: "close_job", params: payload.object, preferredPeer: peer, timeout: 10)
        }
    }

    var hasWorkingJobs: Bool { jobs.values.contains { !$0.closed } }

    private func handleEvent(name: String, fields: [String: Any], peer: String) {
        switch name {
        case "user_stopped":
            guard let jobID = fields["job"] as? String, jobs[jobID] != nil else { return }
            let how: String
            switch fields["reason"] as? String {
            case "escape": how = "you pressed Escape in the browser"
            case "toolbar": how = "you clicked the Teachy button in the browser"
            case "debugger_bar": how = "you cancelled Chrome's debugging bar"
            default: how = "you stopped it in the browser"
            }
            jobs[jobID]?.stoppedReason = how
            AgentJobCenter.shared.job(withID: jobID)?.stop(reason: .userTookOver(how))

        case "tab_closed":
            guard let jobID = fields["job"] as? String, let tab = Self.integer(fields["tab"]) else { return }
            guard var record = jobs[jobID] else { return }
            record.urlForTab.removeValue(forKey: tab)
            if record.currentTab == tab { record.currentTab = record.urlForTab.keys.max() }
            jobs[jobID] = record

        case "peer_closed":
            // That browser quit or the extension was switched off: its jobs have nothing to work in.
            for (jobID, record) in jobs where record.peer == peer {
                jobs[jobID]?.closed = true
                jobs[jobID]?.stoppedReason = "the browser closed"
            }
            refreshState()

        default:
            break
        }
    }

    // MARK: Installing the helper

    struct InstallOutcome: Equatable {
        var succeeded: Bool
        var message: String
    }

    /// The steps to show when the app cannot install the helper by itself (a development build without it bundled).
    static let manualInstallSteps: [String] = [
        "In Terminal, from the Teachy folder, run: scripts/install-chrome-host.sh",
        "In Chrome, open chrome://extensions and turn on Developer mode (top right).",
        "Click “Load unpacked” and choose the chrome-extension folder.",
        "Come back here: this row shows Connected when Chrome finds Teachy."
    ]

    /// The install script and the prebuilt helper inside the app bundle, when the build put them there.
    static func bundledInstaller(in bundle: Bundle = .main) -> (script: URL, helper: URL?)? {
        guard let script = bundle.url(forResource: "install-chrome-host", withExtension: "sh") else { return nil }
        let helper = bundle.url(forResource: BrowserHostManifest.helperFileName, withExtension: nil)
            ?? bundle.url(forAuxiliaryExecutable: BrowserHostManifest.helperFileName)
        return (script, helper)
    }

    /// The installer in the Teachy source folder this build came from, for development builds
    /// that do not bundle it. `#filePath` is this file's path at build time; on any other Mac
    /// the folder is not there and this returns nil.
    static func sourceFolderInstaller() -> URL? {
        // Read here, not as a default argument: a default #filePath would be the caller's file.
        let thisSourceFilePath: String = #filePath
        let repositoryRoot = URL(fileURLWithPath: thisSourceFilePath)
            .deletingLastPathComponent()   // Browser/
            .deletingLastPathComponent()   // leanring-buddy/
            .deletingLastPathComponent()   // the repository
        let script = repositoryRoot.appendingPathComponent("scripts", isDirectory: true).appendingPathComponent("install-chrome-host.sh")
        return FileManager.default.isReadableFile(atPath: script.path) ? script : nil
    }

    /// The unpacked extension next to the source-folder installer, for "Load unpacked".
    static func sourceFolderExtension() -> URL? {
        guard let script = sourceFolderInstaller() else { return nil }
        let folder = script.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("chrome-extension", isDirectory: true)
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) ? folder : nil
    }

    var canInstallFromBundle: Bool { Self.bundledInstaller() != nil || Self.sourceFolderInstaller() != nil }

    /// Set once at launch: hands a request to Teachy's normal voice turn, exactly as if the person
    /// had asked it. The install button uses it so Teachy talks the person through the install.
    var askTeachy: ((String) -> Void)?

    private var installWatchTask: Task<Void, Never>?

    /// Wraps a value in single quotes for /bin/sh (a ' inside becomes '\'').
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The text of the `.command` file Terminal runs: the install script, then a plain last line.
    static func terminalInstallScript(installerScriptPath: String, helperBinaryPath: String?, extensionIDs: [String]) -> String {
        var lines = [
            "#!/bin/sh",
            "# Written by Teachy when you clicked Install the browser helper. Safe to delete.",
            "clear",
            "echo 'Installing the Teachy browser helper. Teachy will talk you through it.'",
            "echo",
            "export TEACHY_EXTENSION_IDS=\(shellQuoted(extensionIDs.joined(separator: " ")))"
        ]
        if let helperBinaryPath {
            lines.append("export TEACHY_HOST_BINARY=\(shellQuoted(helperBinaryPath))")
        }
        lines += [
            "/bin/sh \(shellQuoted(installerScriptPath))",
            "install_status=$?",
            "echo",
            "if [ \"$install_status\" -eq 0 ]; then",
            "  echo 'The browser helper is installed. You can close this window.'",
            "else",
            "  echo \"The install stopped (exit $install_status). Ask Teachy what went wrong.\"",
            "fi",
            "exit \"$install_status\"",
            ""
        ]
        return lines.joined(separator: "\n")
    }

    /// What Teachy is asked when the install starts, so it watches Terminal and walks the person through the rest.
    static func installGuidanceRequest(extensionFolderPath: String?) -> String {
        let loadStep: String
        if let extensionFolderPath {
            loadStep = "turn on Developer mode, click Load unpacked and choose the folder \(extensionFolderPath)"
        } else {
            loadStep = "add the Teachy extension and leave it switched on"
        }
        return "I'm trying to install Teachy's browser helper. Teachy just opened Terminal and started the installer there. Install it for me and guide me through it: watch the Terminal window and tell me what's happening, and if it fails, read the error on screen and fix it for me. When it says the helper is installed, help me open chrome://extensions, \(loadStep), and check that the Browser row in Teachy's settings says Connected."
    }

    /// Opens Terminal running the install script, and asks Teachy to guide the person through it.
    /// A `.command` file opened with Terminal runs without Teachy needing Automation access to Terminal.
    func installHelper() async -> InstallOutcome {
        let installerScript: URL
        let helperBinary: URL?
        if let bundled = Self.bundledInstaller() {
            installerScript = bundled.script
            helperBinary = bundled.helper
        } else if let sourceScript = Self.sourceFolderInstaller() {
            installerScript = sourceScript
            helperBinary = nil
        } else {
            return InstallOutcome(succeeded: false, message: "This build of Teachy does not include the browser helper. Follow the steps below.")
        }

        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            return InstallOutcome(succeeded: false, message: "Terminal was not found on this Mac. Follow the steps below.")
        }

        let commandFolder = BrowserHostManifest.teachyFolder(root: supportRoot).appendingPathComponent("browser-host", isDirectory: true)
        let commandFile = commandFolder.appendingPathComponent("Install Browser Helper.command")
        let commandText = Self.terminalInstallScript(
            installerScriptPath: installerScript.path,
            helperBinaryPath: helperBinary?.path,
            extensionIDs: BrowserHostManifest.allowedExtensionIDs
        )
        do {
            try FileManager.default.createDirectory(at: commandFolder, withIntermediateDirectories: true)
            try commandText.write(to: commandFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: commandFile.path)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.open([commandFile], withApplicationAt: terminal, configuration: configuration)
        } catch {
            return InstallOutcome(succeeded: false, message: "Terminal could not start the installer: \(error.localizedDescription)")
        }

        askTeachy?(Self.installGuidanceRequest(extensionFolderPath: Self.sourceFolderExtension()?.path))
        watchForInstallToFinish()
        return InstallOutcome(succeeded: true, message: "Installing in Terminal. Teachy is talking you through it.")
    }

    /// The script runs outside the app, so look at the disk every couple of seconds until the
    /// helper and its manifests appear (or five minutes pass), then update the Browser row.
    private func watchForInstallToFinish() {
        installWatchTask?.cancel()
        installWatchTask = Task { @MainActor [weak self] in
            for _ in 0..<150 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.refreshInstallState()
                if self.state != .notInstalled { return }
            }
        }
    }

    /// Opens chrome://extensions in the browser (browsers only accept that address from themselves or `open -a`).
    static func openExtensionsPage() {
        let candidates = ["com.google.Chrome", "com.google.Chrome.beta", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi"]
        guard let url = URL(string: "chrome://extensions"),
              let app = candidates.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}
