//
//  GBrainClient.swift
//  leanring-buddy
//
//  Transport seam between Teachy (Swift) and the gbrain learner-brain sidecar
//  ("MyChart for education" — see learner-brain/README.md). The writer above
//  this seam speaks in learner-record terms (write a typed page, add a typed
//  edge); the client below it speaks whatever protocol the sidecar exposes.
//
//  P1 provisioning supplies a concrete client (`GBrainCLIClient`). Until the
//  binary is bundled, `NoOpGBrainClient` keeps the app running with the record
//  simply disabled — no learner action ever blocks on a cold brain.
//

import Foundation

// MARK: - The seam

/// The deterministic subset of gbrain operations the writer needs. Everything
/// else (search, `think`, the dream-cycle) is read-side and lives elsewhere.
///
/// Intentionally tiny: a learner record is built from exactly two moves —
/// writing a typed page and drawing a typed edge between pages. That is what
/// makes a skill's proficiency *backed by* the moments that earned it rather
/// than merely asserted.
protocol GBrainClient: Sendable {
    /// Create or overwrite a page. `pageType` is the schema-pack type
    /// (e.g. "skill", "teachback"); `frontmatter` becomes the page's YAML
    /// frontmatter; `bodyMarkdown` is the page body.
    func writePage(
        slug: String,
        pageType: String,
        frontmatter: [String: String],
        bodyMarkdown: String
    ) async throws

    /// Draw a typed edge between two pages (e.g. a teachback `demonstrates` a
    /// skill). The gbrain side is idempotent, so re-issuing a link is safe.
    func addLink(
        fromSlug: String,
        toSlug: String,
        linkType: String
    ) async throws

    /// Whether the sidecar brain is provisioned and reachable. The writer skips
    /// all work when this is false, so a learner using Teachy before the brain
    /// is set up simply builds no record yet — nothing breaks.
    func isBrainReady() async -> Bool
}

enum GBrainClientError: Error {
    case binaryMissing(path: String)
    case commandFailed(status: Int32, message: String)
    case encodingFailed
}

// MARK: - No-op (pre-provisioning / disabled)

/// Records nothing. Used before P1 provisioning lands or when the learner has
/// opted out. Logs in DEBUG so the event wiring can be verified without a brain.
struct NoOpGBrainClient: GBrainClient {
    func writePage(slug: String, pageType: String, frontmatter: [String: String], bodyMarkdown: String) async throws {
        #if DEBUG
        print("[LearnerBrain:noop] writePage \(pageType) → \(slug)")
        #endif
    }

    func addLink(fromSlug: String, toSlug: String, linkType: String) async throws {
        #if DEBUG
        print("[LearnerBrain:noop] link \(fromSlug) --\(linkType)--> \(toSlug)")
        #endif
    }

    func isBrainReady() async -> Bool { false }
}

// MARK: - CLI transport (the P1 client)

/// Drives the bundled `gbrain` sidecar over its CLI against a local PGLite
/// brain. Point `binaryURL` at the pinned gbrain binary and `brainDirectoryURL`
/// at `~/.teachy/brain`.
///
/// Writes go through `gbrain put <slug>` with the composed markdown on stdin;
/// edges through `gbrain link <from> <to> --link-type <type>`.
///
/// NOTE: `Process` requires the app to be un-sandboxed (Teachy ships that way
/// today). If the App Sandbox is ever enabled, switch this for the
/// MCP-over-stdio transport instead — the writer above the seam won't change.
struct GBrainCLIClient: GBrainClient {
    /// The executable to launch. Either the gbrain binary directly, or — because
    /// `bun --compile` can't extract PGLite's WASM payload from its read-only
    /// VFS (gbrain #1340) — the bundled `bun` runtime, in which case
    /// `launchPrefixArguments` carries `["run", "<gbrain>/src/cli.ts"]`.
    let binaryURL: URL
    /// Arguments prepended to every command (empty for a direct binary; the
    /// `bun run <cli>` prefix for the runtime path).
    let launchPrefixArguments: [String]
    let brainDirectoryURL: URL

    init(binaryURL: URL, brainDirectoryURL: URL, launchPrefixArguments: [String] = []) {
        self.binaryURL = binaryURL
        self.brainDirectoryURL = brainDirectoryURL
        self.launchPrefixArguments = launchPrefixArguments
    }

    func isBrainReady() async -> Bool {
        let fileManager = FileManager.default
        return fileManager.isExecutableFile(atPath: binaryURL.path)
            && fileManager.fileExists(atPath: brainDirectoryURL.path)
    }

    func writePage(slug: String, pageType: String, frontmatter: [String: String], bodyMarkdown: String) async throws {
        var document = "---\ntype: \(yamlScalar(pageType))\n"
        // Deterministic key order so a re-write of the same page produces
        // byte-identical frontmatter (keeps gbrain's version history quiet).
        for key in frontmatter.keys.sorted() {
            document += "\(key): \(yamlScalar(frontmatter[key] ?? ""))\n"
        }
        document += "---\n\n\(bodyMarkdown)\n"
        try await runGBrain(arguments: ["put", slug], standardInput: document)
    }

    func addLink(fromSlug: String, toSlug: String, linkType: String) async throws {
        try await runGBrain(
            arguments: ["link", fromSlug, toSlug, "--link-type", linkType],
            standardInput: nil
        )
    }

    // MARK: Process plumbing

    /// Quote a frontmatter scalar when it contains anything the gbrain mini-YAML
    /// parser could misread (colons, quotes, leading markers). Plain words are
    /// left bare to match the hand-authored packs.
    private func yamlScalar(_ raw: String) -> String {
        let needsQuoting = raw.isEmpty
            || raw.contains(where: { ":#\"'[]{}".contains($0) })
            || raw.first == " " || raw.last == " "
        guard needsQuoting else { return raw }
        let escaped = raw.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func runGBrain(arguments: [String], standardInput: String?) async throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw GBrainClientError.binaryMissing(path: binaryURL.path)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = binaryURL
            process.arguments = launchPrefixArguments + arguments
            process.currentDirectoryURL = brainDirectoryURL

            let standardInputPipe = Pipe()
            let standardErrorPipe = Pipe()
            process.standardInput = standardInputPipe
            process.standardError = standardErrorPipe
            // Discard stdout (put/link emit a small JSON ack we don't need) so a
            // chatty command can never fill a pipe buffer and block termination.
            process.standardOutput = FileHandle.nullDevice

            process.terminationHandler = { finishedProcess in
                if finishedProcess.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let errorData = standardErrorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorMessage = String(data: errorData, encoding: .utf8) ?? "unknown error"
                    continuation.resume(throwing: GBrainClientError.commandFailed(
                        status: finishedProcess.terminationStatus,
                        message: errorMessage
                    ))
                }
            }

            do {
                try process.run()
                if let standardInput, let inputData = standardInput.data(using: .utf8) {
                    standardInputPipe.fileHandleForWriting.write(inputData)
                }
                standardInputPipe.fileHandleForWriting.closeFile()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
