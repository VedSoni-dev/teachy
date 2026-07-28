import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { existsSync } from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

/**
 * Boots the REAL C# sidecar and speaks the real newline-JSON protocol to it.
 *
 * This is the layer nothing else covered, and it is where the app actually broke
 * in the wild: the sidecar died and every command failed with "Teachy background
 * service is not running" forever, so the UI was a shell. Unit tests over the
 * renderer cannot see that — only talking to the process can.
 *
 * Deliberately read-only. `click-point`, `type-text` and `press-key` synthesise
 * real input on whoever is running the suite, and `speak` talks out loud, so
 * none of them belong in an automated run.
 */

const sidecarExecutablePath = path.join(
  __dirname,
  '..',
  '..',
  'windows',
  'Teachy.Sidecar',
  'bin',
  'Release',
  'net8.0-windows',
  'Teachy.Sidecar.exe',
);

const sidecarIsBuilt = existsSync(sidecarExecutablePath);
const describeWithSidecar = sidecarIsBuilt ? describe : describe.skip;

class SidecarTestClient {
  private readonly childProcess: ChildProcessWithoutNullStreams;
  private nextRequestId = 1;
  private readonly pendingRequests = new Map<
    string,
    { resolve: (value: unknown) => void; reject: (error: Error) => void }
  >();
  readonly stderrOutput: string[] = [];
  exitCode: number | null = null;

  constructor() {
    this.childProcess = spawn(sidecarExecutablePath, [], {
      stdio: ['pipe', 'pipe', 'pipe'],
      windowsHide: true,
    }) as ChildProcessWithoutNullStreams;

    readline.createInterface({ input: this.childProcess.stdout }).on('line', (line) => {
      let message: { id?: string; ok?: boolean; result?: unknown; error?: string; event?: string };
      try {
        message = JSON.parse(line);
      } catch {
        return;
      }
      if (message.event || !message.id) {
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
        pending.reject(new Error(message.error ?? 'sidecar command failed'));
      }
    });

    this.childProcess.stderr.on('data', (chunk) => this.stderrOutput.push(String(chunk)));
    this.childProcess.on('exit', (code) => {
      this.exitCode = code;
      for (const [, pending] of this.pendingRequests) {
        pending.reject(new Error(`sidecar exited with code ${code}`));
      }
      this.pendingRequests.clear();
    });
  }

  get isAlive(): boolean {
    return this.exitCode === null;
  }

  send(command: string, args: Record<string, unknown> = {}, timeoutMs = 15_000): Promise<unknown> {
    return new Promise((resolve, reject) => {
      if (!this.isAlive) {
        reject(new Error('sidecar is not running'));
        return;
      }
      const requestId = String(this.nextRequestId++);
      const timeoutHandle = setTimeout(() => {
        this.pendingRequests.delete(requestId);
        reject(new Error(`sidecar did not answer "${command}" within ${timeoutMs}ms`));
      }, timeoutMs);

      this.pendingRequests.set(requestId, {
        resolve: (value) => {
          clearTimeout(timeoutHandle);
          resolve(value);
        },
        reject: (error) => {
          clearTimeout(timeoutHandle);
          reject(error);
        },
      });
      this.childProcess.stdin.write(`${JSON.stringify({ id: requestId, command, args })}\n`);
    });
  }

  shutdown(): void {
    this.childProcess.stdin.end();
  }
}

describeWithSidecar('sidecar protocol', () => {
  let sidecar: SidecarTestClient;

  beforeAll(() => {
    sidecar = new SidecarTestClient();
  });

  afterAll(() => {
    sidecar?.shutdown();
  });

  it('answers get-config with the shape the renderer destructures', async () => {
    const config = (await sidecar.send('get-config')) as Record<string, unknown>;
    expect(config).toBeTypeOf('object');
    expect(config).toHaveProperty('hasApiKey');
    expect(config).toHaveProperty('chatModel');
    expect(config).toHaveProperty('showTeachyCursor');
    expect(config).toHaveProperty('notchPlacement');
    expect(typeof config.hasApiKey).toBe('boolean');
  });

  it('reports a real primary screen size', async () => {
    const screenInfo = (await sidecar.send('get-screen-info')) as { width: number; height: number };
    expect(screenInfo.width).toBeGreaterThan(0);
    expect(screenInfo.height).toBeGreaterThan(0);
  });

  it('returns progress as an object keyed by course id', async () => {
    const progress = (await sidecar.send('get-progress')) as Record<string, unknown>;
    expect(progress).toBeTypeOf('object');
    expect(Array.isArray(progress)).toBe(false);
  });

  it('captures a screenshot with usable dimensions and JPEG payload', async () => {
    const captured = (await sidecar.send('capture-screen', { includeElements: false })) as {
      width: number;
      height: number;
      jpegBase64: string;
    };
    expect(captured.width).toBeGreaterThan(0);
    expect(captured.height).toBeGreaterThan(0);
    expect(captured.jpegBase64.length).toBeGreaterThan(1000);
    // /9j/ is the base64 prefix of the JPEG SOI marker — proves it is really an image.
    expect(captured.jpegBase64.startsWith('/9j/')).toBe(true);
  });

  it('captures with UI Automation elements without falling over', async () => {
    const captured = (await sidecar.send('capture-screen', { includeElements: true })) as {
      elements?: Array<{ id: number; line: string; centerX: number; centerY: number }> | null;
    };
    // An empty list is legitimate (no inspectable foreground window in CI); a
    // malformed entry is not, because the renderer points a cursor at these.
    for (const element of captured.elements ?? []) {
      expect(typeof element.id).toBe('number');
      expect(typeof element.line).toBe('string');
      expect(Number.isFinite(element.centerX)).toBe(true);
      expect(Number.isFinite(element.centerY)).toBe(true);
    }
  });

  it('rejects an unknown command instead of dying on it', async () => {
    await expect(sidecar.send('command-that-does-not-exist')).rejects.toThrow(/Unknown command/i);
    expect(sidecar.isAlive).toBe(true);
  });

  it('survives a bad-argument command that the renderer could plausibly send', async () => {
    await expect(sidecar.send('click-element', { elementId: 999_999 })).rejects.toThrow();
    expect(sidecar.isAlive).toBe(true);
  });

  it('is still alive after the whole run — a dead sidecar is a dead app', async () => {
    await sidecar.send('get-config');
    expect(sidecar.isAlive).toBe(true);
    expect(sidecar.stderrOutput.join('')).not.toMatch(/AccessViolationException|Fatal error/);
  });
});

describe('sidecar build', () => {
  it('has a Release build to test against', () => {
    // Guard rather than silent skip: a green run that tested nothing is worse
    // than a red one. Build with:
    //   dotnet build windows/Teachy.Sidecar/Teachy.Sidecar.csproj -c Release
    expect(sidecarIsBuilt, `no sidecar at ${sidecarExecutablePath}`).toBe(true);
  });
});
