//
//  FrontDocumentReader.swift
//  leanring-buddy
//
//  "Read the whole thing in front of me." Finds the app the person is looking
//  at and reads its document in full, not just the visible part:
//
//    1. A window that has a file behind it (Preview, a PDF viewer, an editor:
//       the window's AXDocument attribute is a file URL) → DocumentReader.
//    2. A browser or any app showing web content → the text of the page's
//       Accessibility tree (AXWebArea), which includes what is scrolled out
//       of view. If that gives almost nothing, the page URL is fetched and
//       its readable text extracted.
//    3. An editor with unsaved text → the largest text area in the window.
//
//  Read-only: never clicks, types or scrolls. Needs the Accessibility
//  permission Teachy already has; returns nil without it. Password fields
//  are never read.
//

import AppKit
import ApplicationServices
import Foundation

nonisolated enum FrontDocumentReader {
    static let maximumCharacters = 300_000
    static let maximumVisitedElements = 40_000
    static let timeBudget: TimeInterval = 2.5
    /// Below this much text from the Accessibility tree, the page URL is fetched instead.
    static let minimumUsefulCharacters = 400

    /// The app the person is looking at. When Teachy's own window is in front (they
    /// are typing in the chat window), this is the app right behind it.
    static func targetApplication() -> NSRunningApplication? {
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownProcess {
            return front
        }
        // Windows front to back. Owner process IDs need no screen-recording permission.
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let owner = window[kCGWindowOwnerPID as String] as? Int32, owner != ownProcess,
                  let application = NSRunningApplication(processIdentifier: owner),
                  application.activationPolicy == .regular else { continue }
            return application
        }
        return nil
    }

    static func readFrontmost() async -> ReadDocument? {
        guard AXIsProcessTrusted(), let application = targetApplication() else { return nil }
        let processIdentifier = application.processIdentifier
        let bundleIdentifier = application.bundleIdentifier ?? ""
        let applicationName = application.localizedName ?? "the app"

        let found = await Task.detached(priority: .userInitiated) {
            inspect(processIdentifier: processIdentifier, bundleIdentifier: bundleIdentifier)
        }.value

        if let fileURL = found.fileURL, let document = try? await DocumentReader.read(url: fileURL) {
            return document
        }

        let pageTitle = found.title.isEmpty ? applicationName : found.title
        if found.webText.count >= minimumUsefulCharacters {
            return webDocument(title: pageTitle, url: found.pageURL, text: found.webText, wasCutShort: found.wasCutShort)
        }
        if let pageURL = found.pageURL, let fetched = await fetchReadableText(from: pageURL),
           fetched.count > found.webText.count {
            return webDocument(title: pageTitle, url: pageURL, text: fetched, wasCutShort: false)
        }
        if !found.webText.isEmpty {
            return webDocument(title: pageTitle, url: found.pageURL, text: found.webText, wasCutShort: found.wasCutShort)
        }
        if found.editorText.count >= 200 {
            let sections = DocumentTextTools.lineRangeSections(found.editorText)
            guard !sections.isEmpty else { return nil }
            return ReadDocument(title: pageTitle, kind: .text, sections: sections)
        }
        return nil
    }

    private static func webDocument(title: String, url: URL?, text: String, wasCutShort: Bool) -> ReadDocument? {
        let sections = DocumentTextTools.plainSections(DocumentTextTools.tidy(text))
        guard !sections.isEmpty else { return nil }
        return ReadDocument(
            title: title, kind: .webPage, sourceURL: url, sections: sections,
            isTruncated: wasCutShort,
            truncationNote: wasCutShort ? "The page is very long; only its first \(maximumCharacters) characters were read." : nil
        )
    }

    // MARK: - Accessibility

    struct Found: Sendable {
        var title = ""
        var fileURL: URL?
        var pageURL: URL?
        var webText = ""
        var editorText = ""
        var wasCutShort = false
    }

    /// Synchronous cross-process calls: run off the main thread.
    static func inspect(processIdentifier: pid_t, bundleIdentifier: String) -> Found {
        var found = Found()
        let appElement = AXUIElementCreateApplication(processIdentifier)
        AXSnapshotWalker.prepare(appElement: appElement, bundleID: bundleIdentifier)
        guard let window = AXSnapshotWalker.focusedWindow(of: appElement) else { return found }
        found.title = AXRead.string(window, kAXTitleAttribute as String)

        let documentString = AXRead.string(window, kAXDocumentAttribute as String)
        if !documentString.isEmpty, let documentURL = URL(string: documentString) ?? URL(string: documentString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") {
            if documentURL.isFileURL {
                if FileManager.default.fileExists(atPath: documentURL.path) { found.fileURL = documentURL }
            } else if documentURL.scheme == "http" || documentURL.scheme == "https" {
                found.pageURL = documentURL
            }
        } else if documentString.hasPrefix("/"), FileManager.default.fileExists(atPath: documentString) {
            found.fileURL = URL(fileURLWithPath: documentString)
        }
        if found.fileURL != nil { return found }

        // Depth-first, in reading order, so the text comes out the way the page reads.
        let deadline = Date().addingTimeInterval(timeBudget)
        var stack: [(element: AXUIElement, insideWeb: Bool)] = [(window, false)]
        var visited = 0
        var webPieces: [String] = []
        var webCharacters = 0

        while let (element, insideWeb) = stack.popLast() {
            visited += 1
            if visited > maximumVisitedElements || Date() > deadline || webCharacters > maximumCharacters {
                found.wasCutShort = insideWeb || webCharacters > 0
                break
            }
            let role = AXRead.string(element, kAXRoleAttribute as String)
            if role == "AXSecureTextField" { continue }
            let subrole = AXRead.string(element, kAXSubroleAttribute as String)
            if subrole == "AXSecureTextField" { continue }

            var nowInsideWeb = insideWeb
            if role == "AXWebArea" {
                nowInsideWeb = true
                if found.pageURL == nil, let url = AXRead.value(element, kAXURLAttribute as String) as? URL,
                   url.scheme == "http" || url.scheme == "https" {
                    found.pageURL = url
                }
                let webTitle = AXRead.string(element, kAXTitleAttribute as String)
                if !webTitle.isEmpty { found.title = webTitle }
            }

            if nowInsideWeb {
                if role == "AXStaticText" {
                    let text = AXRead.string(element, kAXValueAttribute as String)
                    if !text.isEmpty {
                        webPieces.append(text)
                        webCharacters += text.count + 1
                    }
                    // Its children are only the same words again, line by line.
                    continue
                }
                if role == "AXHeading" || role == "AXRow" || role == "AXListMarker" || subrole == "AXLandmarkMain" {
                    webPieces.append("\n")
                } else if role == "AXGroup" || role == "AXList" || role == "AXTable" || role == "AXCell" {
                    if webPieces.last != "\n" { webPieces.append("\n") }
                }
                if role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" || role == "AXMenu" || role == "AXMenuBar" {
                    continue
                }
            } else if role == "AXTextArea" {
                let text = AXRead.string(element, kAXValueAttribute as String)
                if text.count > found.editorText.count { found.editorText = String(text.prefix(maximumCharacters)) }
                continue
            } else if role == "AXMenuBar" || role == "AXMenu" || role == "AXToolbar" {
                continue
            }

            let children = AXRead.elements(element, kAXChildrenAttribute as String)
            for child in children.reversed() {
                stack.append((child, nowInsideWeb))
            }
        }

        found.webText = assemble(webPieces)
        return found
    }

    /// Joins the page's text runs: runs in the same block with a space, blocks with a line break.
    static func assemble(_ pieces: [String]) -> String {
        var text = ""
        for piece in pieces {
            if piece == "\n" {
                if !text.hasSuffix("\n") { text += "\n" }
            } else {
                if let last = text.last, last != "\n", last != " ", piece.first != " " { text += " " }
                text += piece
            }
        }
        return DocumentTextTools.tidy(text)
    }

    // MARK: - Fetch fallback

    /// The page as anyone on the web sees it (no cookies or sign-in are sent).
    private static func fetchReadableText(from url: URL) async -> String? {
        guard url.scheme == "http" || url.scheme == "https" else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Mozilla/5.0 (Macintosh) Teachy", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status),
              data.count < 8 * 1024 * 1024 else { return nil }
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let text = WebFetchTool.readableText(fromHTML: html)
        return text.isEmpty ? nil : String(text.prefix(maximumCharacters))
    }
}
