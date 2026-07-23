//
//  LearnerBrainProvisioner.swift
//  leanring-buddy
//
//  P1 provisioning — the seam that turns the (already-wired) learner-record
//  write path from inert into live. Everything below the writer already exists:
//  `TeachyEngine` mirrors every learning signal into `LearnerBrainWriter`, which
//  speaks to a `GBrainClient`. The one missing piece was *constructing* a real
//  client and handing it to the engine. That is this file's whole job.
//
//  Safe by default: if no gbrain binary is discoverable on this machine, this
//  returns `nil`, the engine's `learnerBrainWriter` stays `nil`, and Teachy
//  behaves EXACTLY as it does today (no record built, nothing broken). The
//  record only comes alive once a bundled/installed gbrain binary is present.
//
//  See learner-brain/README.md for the full design (the "MyChart for education"
//  record) and the phased plan this completes the Swift half of.
//

import Foundation

/// One-time, best-effort setup of the local gbrain sidecar brain, run off the
/// main actor at app start. Produces a ready `GBrainClient`, or `nil` to keep
/// the record disabled. Never throws to the caller — provisioning must never
/// block or crash app launch.
enum LearnerBrainProvisioner {

    // MARK: - Locations

    /// gbrain's on-disk home. We deliberately use gbrain's own default
    /// (`~/.gbrain`) rather than the README's aspirational `~/.teachy/brain`,
    /// because that default is exactly what the validated spike produced —
    /// `~/.gbrain/{config.json, schema-packs/, brain.pglite}` — and gbrain reads
    /// its config from there. Relocating the home is a later change gated on
    /// verifying gbrain's home-override contract (`GBRAIN_HOME`) against a live
    /// binary; the writer above the seam wouldn't change either way.
    private static var brainHomeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gbrain", isDirectory: true)
    }

    /// The PGLite database directory. Its presence is our "already initialized"
    /// signal, so first-run `init` runs at most once.
    private static var brainDatabaseURL: URL {
        brainHomeURL.appendingPathComponent("brain.pglite", isDirectory: true)
    }

    /// Where the education schema-pack must live for gbrain to load it:
    /// `~/.gbrain/schema-packs/teachy-learner-v1/pack.yaml`. The pack contents
    /// are carried in-binary by `TeachyLearnerSchemaPack`, so installing it is a
    /// string write — no bundled resource file to ship or lose.
    private static var schemaPackFileURL: URL {
        brainHomeURL
            .appendingPathComponent("schema-packs", isDirectory: true)
            .appendingPathComponent(TeachyLearnerSchemaPack.name, isDirectory: true)
            .appendingPathComponent("pack.yaml", isDirectory: false)
    }

    // MARK: - Entry point

    /// Resolve a gbrain executable, ensure the brain + pack are provisioned, and
    /// return a client wired to it. Returns `nil` when no binary is available so
    /// the caller leaves `learnerBrainWriter` unset (today's behavior).
    ///
    /// Runs entirely off the main actor (this enum is non-isolated). The caller
    /// hops back to the main actor to build the `@MainActor LearnerBrainWriter`.
    static func provisionClient() async -> GBrainClient? {
        guard let executable = resolveExecutable() else {
            log("no gbrain executable found — learner record stays disabled")
            return nil
        }
        log("gbrain executable: \(executable.binaryURL.path) \(executable.launchPrefixArguments.joined(separator: " "))")

        let client = GBrainCLIClient(
            binaryURL: executable.binaryURL,
            brainDirectoryURL: brainHomeURL,
            launchPrefixArguments: executable.launchPrefixArguments
        )

        // Make the home directory exist before anything tries to write into it.
        ensureDirectoryExists(brainHomeURL)

        // Install the schema-pack (idempotent — only copies when absent). Without
        // the pack, page types don't resolve and writes are untyped.
        installSchemaPackIfNeeded()

        // First-run only: initialize the PGLite brain. The flags mirror the
        // validated spike exactly — the on-disk `config.json` it produced reads
        // `engine: pglite`, `embedding_disabled: true`. `--no-embedding` is
        // correct until the local embedder lands (P1 infra): writes, graph
        // edges, and backlinks all work with zero embedding provider; only
        // semantic search degrades. NOTE: this is the one gbrain CLI contract
        // this file can't re-verify without a live binary in-session — it is
        // taken from what the spike actually ran.
        await initializeBrainIfNeeded(using: client, executable: executable)

        guard await client.isBrainReady() else {
            log("gbrain client reports brain not ready after provisioning — staying disabled")
            return nil
        }
        log("learner record is live")
        return client
    }

    // MARK: - Executable resolution

    /// A gbrain launch descriptor. Either a direct binary (empty prefix) or the
    /// bundled `bun` runtime driving gbrain's `cli.ts` — the two modes
    /// `GBrainCLIClient` already understands (see its `binaryURL` doc comment).
    private struct GBrainExecutable {
        let binaryURL: URL
        let launchPrefixArguments: [String]
    }

    /// Resolution order (first that exists & is executable wins):
    ///   1. Env overrides — the practical path for dev bring-up and this file's
    ///      own verification: `TEACHY_GBRAIN_BINARY` (direct), or the pair
    ///      `TEACHY_GBRAIN_BUN` + `TEACHY_GBRAIN_CLI` (bun runtime).
    ///   2. Bundled in the app — the shipping path: a `gbrain` binary under the
    ///      app's `Resources/gbrain/`, or a bundled `bun` + `cli.ts`.
    ///   3. A user-installed binary at `~/.teachy/bin/gbrain`.
    private static func resolveExecutable() -> GBrainExecutable? {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment

        // 1. Env overrides.
        if let binaryPath = environment["TEACHY_GBRAIN_BINARY"],
           fileManager.isExecutableFile(atPath: binaryPath) {
            return GBrainExecutable(binaryURL: URL(fileURLWithPath: binaryPath), launchPrefixArguments: [])
        }
        if let bunPath = environment["TEACHY_GBRAIN_BUN"],
           let cliPath = environment["TEACHY_GBRAIN_CLI"],
           fileManager.isExecutableFile(atPath: bunPath),
           fileManager.fileExists(atPath: cliPath) {
            return GBrainExecutable(
                binaryURL: URL(fileURLWithPath: bunPath),
                launchPrefixArguments: ["run", cliPath]
            )
        }

        // 2. Bundled in the app.
        if let bundledBinary = Bundle.main.url(forResource: "gbrain", withExtension: nil, subdirectory: "gbrain"),
           fileManager.isExecutableFile(atPath: bundledBinary.path) {
            return GBrainExecutable(binaryURL: bundledBinary, launchPrefixArguments: [])
        }
        if let bundledBun = Bundle.main.url(forResource: "bun", withExtension: nil, subdirectory: "gbrain"),
           let bundledCLI = Bundle.main.url(forResource: "cli", withExtension: "ts", subdirectory: "gbrain/src"),
           fileManager.isExecutableFile(atPath: bundledBun.path) {
            return GBrainExecutable(
                binaryURL: bundledBun,
                launchPrefixArguments: ["run", bundledCLI.path]
            )
        }

        // 3. User-installed binary.
        let userBinaryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".teachy/bin/gbrain", isDirectory: false)
        if fileManager.isExecutableFile(atPath: userBinaryURL.path) {
            return GBrainExecutable(binaryURL: userBinaryURL, launchPrefixArguments: [])
        }

        return nil
    }

    // MARK: - Provisioning steps

    private static func ensureDirectoryExists(_ url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Write the in-binary schema-pack into place when it isn't already
    /// installed. On a machine where the spike already installed it (as here),
    /// this is a no-op. Source of truth is `TeachyLearnerSchemaPack.yaml`, kept
    /// byte-identical to learner-brain/teachy-learner-v1.yaml.
    private static func installSchemaPackIfNeeded() {
        guard !FileManager.default.fileExists(atPath: schemaPackFileURL.path) else { return }
        ensureDirectoryExists(schemaPackFileURL.deletingLastPathComponent())
        do {
            try TeachyLearnerSchemaPack.yaml.write(to: schemaPackFileURL, atomically: true, encoding: .utf8)
            log("installed schema-pack \(TeachyLearnerSchemaPack.name)")
        } catch {
            log("failed to install schema-pack: \(error)")
        }
    }

    private static func initializeBrainIfNeeded(using client: GBrainCLIClient, executable: GBrainExecutable) async {
        guard !FileManager.default.fileExists(atPath: brainDatabaseURL.path) else {
            return   // already initialized on a previous launch
        }
        log("initializing gbrain PGLite brain (first run)")
        do {
            try await runInit(executable: executable)
        } catch {
            log("gbrain init failed: \(error)")
        }
    }

    /// Run `gbrain init --pglite --no-embedding` with the same working directory
    /// the write client uses, so init and writes resolve the same brain home.
    private static func runInit(executable: GBrainExecutable) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = executable.binaryURL
            process.arguments = executable.launchPrefixArguments + ["init", "--pglite", "--no-embedding"]
            process.currentDirectoryURL = brainHomeURL

            let standardErrorPipe = Pipe()
            process.standardError = standardErrorPipe
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
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Logging

    private static func log(_ message: String) {
        #if DEBUG
        print("[LearnerBrain:provision] \(message)")
        #endif
    }
}
