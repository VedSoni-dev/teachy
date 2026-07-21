const { spawn } = require('node:child_process');
const path = require('node:path');
const readline = require('node:readline');

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
  }

  /** Resolves the sidecar executable for both dev (bin/Debug) and packaged builds. */
  resolveExecutablePath() {
    if (process.env.TEACHY_SIDECAR_PATH) {
      return process.env.TEACHY_SIDECAR_PATH;
    }
    return path.join(
      __dirname,
      '..',
      '..',
      'windows',
      'Teachy.Sidecar',
      'bin',
      'Debug',
      'net8.0-windows',
      'Teachy.Sidecar.exe',
    );
  }

  start() {
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
    });

    this.childProcess.on('error', (spawnError) => {
      console.error('[sidecar] failed to start:', spawnError.message);
    });
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
    if (this.childProcess) {
      // Closing stdin is the sidecar's shutdown signal.
      this.childProcess.stdin.end();
      this.childProcess = null;
    }
  }
}

module.exports = { SidecarBridge };
