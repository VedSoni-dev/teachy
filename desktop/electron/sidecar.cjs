const { spawn } = require('node:child_process');
const path = require('node:path');
const fs = require('node:fs');
const readline = require('node:readline');
const { app } = require('electron');

/**
 * Owns the Teachy.Sidecar child process — the C# layer that does everything
 * Electron cannot: UI Automation, the global push-to-talk hook, screen capture
 * with the model-facing grid, synthesized input, SAPI speech, and DPAPI key
 * storage.
 *
 * Protocol is newline-delimited JSON both ways. Commands get a reply keyed by
 * id; the sidecar also pushes unsolicited events (push-to-talk, transcripts).
 */
class SidecarBridge {
  constructor() {
    this.childProcess = null;
    this.nextRequestId = 1;
    this.pendingRequests = new Map();
    this.eventListeners = new Map();
    /** Set by stop() so a deliberate shutdown is not mistaken for a crash. */
    this.isShuttingDown = false;
    /** Exit timestamps inside the crash window, used to give up on a crash loop. */
    this.recentCrashTimestamps = [];
    this.restartTimer = null;
  }

  /**
   * Resolve the sidecar executable across every context it actually runs in:
   * an explicit override, a packaged install, and dev builds (Release preferred
   * over Debug). The previous version hardcoded only the dev Debug path, so any
   * packaged or Release build could not find the sidecar at all.
   */
  resolveExecutablePath() {
    // 1. Explicit override — CI, custom installs, or a manually-built sidecar.
    if (process.env.TEACHY_SIDECAR_PATH) {
      return process.env.TEACHY_SIDECAR_PATH;
    }

    const executableName = 'Teachy.Sidecar.exe';
    const candidatePaths = [];

    // 2. Packaged app — the sidecar ships as an extraResource under
    //    resources/sidecar (see the electron-builder `extraResources` config).
    if (app.isPackaged) {
      candidatePaths.push(path.join(process.resourcesPath, 'sidecar', executableName));
    }

    // 3. Dev builds — prefer a Release build, fall back to Debug.
    const sidecarBinDir = path.join(__dirname, '..', '..', 'windows', 'Teachy.Sidecar', 'bin');
    candidatePaths.push(path.join(sidecarBinDir, 'Release', 'net8.0-windows', executableName));
    candidatePaths.push(path.join(sidecarBinDir, 'Debug', 'net8.0-windows', executableName));

    // Use the first path that exists; otherwise return the last candidate so a
    // failure surfaces a concrete missing path rather than an empty string.
    return candidatePaths.find((candidate) => fs.existsSync(candidate))
      ?? candidatePaths[candidatePaths.length - 1];
  }

  start() {
    this.isShuttingDown = false;
    const executablePath = this.resolveExecutablePath();

    this.childProcess = spawn(executablePath, [], {
      stdio: ['pipe', 'pipe', 'pipe'],
      windowsHide: true,
    });

    const stdoutLineReader = readline.createInterface({ input: this.childProcess.stdout });
    stdoutLineReader.on('line', (line) => this.handleSidecarLine(line));

    this.childProcess.stderr.on('data', (chunk) => {
      console.error('[sidecar stderr]', String(chunk).trim());
    });

    this.childProcess.on('exit', (exitCode) => {
      console.error(`[sidecar] exited with code ${exitCode}`);
      // Fail any in-flight commands rather than leaving callers hanging forever.
      for (const [, pending] of this.pendingRequests) {
        pending.reject(new Error('Teachy background service stopped.'));
      }
      this.pendingRequests.clear();
      this.childProcess = null;

      if (!this.isShuttingDown) {
        this.scheduleRestartAfterCrash();
      }
    });

    this.childProcess.on('error', (spawnError) => {
      console.error('[sidecar] failed to start:', spawnError.message);
    });
  }

  /**
   * The sidecar owns every OS capability the app has — screen capture, speech,
   * the key store, push-to-talk. When it dies, nothing in the UI works and every
   * command fails with "not running" forever. A native crash in an audio or UI
   * Automation driver is exactly the kind of failure a restart clears, so bring
   * it back rather than leaving the app a shell.
   *
   * Bounded: if it dies repeatedly in a short window the fault is not transient,
   * and respawning becomes a spin loop that buries the real error in log noise.
   */
  scheduleRestartAfterCrash() {
    const crashWindowMs = 60_000;
    const maximumCrashesPerWindow = 3;
    const restartDelayMs = 1_000;

    const now = Date.now();
    this.recentCrashTimestamps = this.recentCrashTimestamps.filter(
      (timestamp) => now - timestamp < crashWindowMs,
    );
    this.recentCrashTimestamps.push(now);

    if (this.recentCrashTimestamps.length > maximumCrashesPerWindow) {
      console.error(
        `[sidecar] crashed ${this.recentCrashTimestamps.length} times in ${crashWindowMs / 1000}s — not restarting again.`,
      );
      return;
    }

    console.error(`[sidecar] restarting in ${restartDelayMs}ms`);
    this.restartTimer = setTimeout(() => {
      this.restartTimer = null;
      if (this.isShuttingDown) {
        return;
      }
      // Event listeners live on the bridge, not the child, so they survive this
      // and keep firing against the new process with no re-subscription.
      this.start();
    }, restartDelayMs);
  }

  handleSidecarLine(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      console.error('[sidecar] unparseable line:', line.slice(0, 200));
      return;
    }

    if (message.event) {
      const listeners = this.eventListeners.get(message.event);
      if (listeners) {
        for (const listener of listeners) {
          listener(message.payload);
        }
      }
      return;
    }

    const pending = this.pendingRequests.get(message.id);
    if (!pending) {
      return;
    }
    this.pendingRequests.delete(message.id);

    if (message.ok) {
      pending.resolve(message.result);
    } else {
      pending.reject(new Error(message.error || 'Sidecar command failed.'));
    }
  }

  /** Sends a command and resolves with its result. */
  send(command, args = {}) {
    return new Promise((resolve, reject) => {
      if (!this.childProcess) {
        reject(new Error('Teachy background service is not running.'));
        return;
      }

      const requestId = String(this.nextRequestId++);
      this.pendingRequests.set(requestId, { resolve, reject });
      this.childProcess.stdin.write(`${JSON.stringify({ id: requestId, command, args })}\n`);
    });
  }

  /** Subscribes to a sidecar event (ptt-pressed, ptt-released, transcript, …). */
  on(eventName, listener) {
    if (!this.eventListeners.has(eventName)) {
      this.eventListeners.set(eventName, new Set());
    }
    this.eventListeners.get(eventName).add(listener);
  }

  stop() {
    this.isShuttingDown = true;
    if (this.restartTimer) {
      clearTimeout(this.restartTimer);
      this.restartTimer = null;
    }
    if (this.childProcess) {
      // Closing stdin is the sidecar's shutdown signal.
      this.childProcess.stdin.end();
      this.childProcess = null;
    }
  }
}

module.exports = { SidecarBridge };
