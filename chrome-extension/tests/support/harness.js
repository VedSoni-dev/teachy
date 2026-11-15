// Shared test plumbing: a framed-message reader, a fake Teachy app (the Unix
// socket the helper connects to) and a fake Chrome (the helper's stdin/stdout).
'use strict';

const net = require('node:net');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const Protocol = require('../../lib/protocol.js');

// Collects framed messages from a stream and lets a test wait for the one it wants.
class Inbox {
  constructor(stream) {
    this.decoder = new Protocol.FrameDecoder();
    this.messages = [];
    this.waiters = [];
    this.closed = false;
    stream.on('data', (chunk) => {
      let items;
      try { items = this.decoder.push(chunk); } catch (problem) { items = [{ error: problem.code }]; }
      for (const item of items) this.messages.push(item.message || { __error: item.error });
      this.flush();
    });
    stream.on('close', () => { this.closed = true; this.flush(); });
    stream.on('error', () => { this.closed = true; this.flush(); });
  }

  flush() {
    for (const waiter of [...this.waiters]) {
      const at = this.messages.findIndex(waiter.test);
      if (at !== -1) {
        const [found] = this.messages.splice(at, 1);
        this.waiters.splice(this.waiters.indexOf(waiter), 1);
        clearTimeout(waiter.timer);
        waiter.resolve(found);
      }
    }
  }

  // Resolves with the first message matching `test` (default: any), removing it from the inbox.
  next(test, timeoutMs, what) {
    const matcher = test || (() => true);
    return new Promise((resolve, reject) => {
      const waiter = { test: matcher, resolve };
      waiter.timer = setTimeout(() => {
        this.waiters.splice(this.waiters.indexOf(waiter), 1);
        reject(new Error('Timed out waiting for ' + (what || 'a message') + '. Inbox: ' + JSON.stringify(this.messages).slice(0, 600)));
      }, timeoutMs || 5000);
      this.waiters.push(waiter);
      this.flush();
    });
  }
}

function tempDir(prefix) {
  const base = path.join(os.tmpdir(), 'teachy-chrome');
  fs.mkdirSync(base, { recursive: true });
  return fs.mkdtempSync(path.join(base, prefix || 't-'));
}

// The Teachy app's side of the socket.
class FakeApp {
  constructor(socketPath) {
    this.socketPath = socketPath;
    this.server = null;
    this.connections = [];
    this.waiting = [];
  }

  listen() {
    return new Promise((resolve, reject) => {
      try { fs.unlinkSync(this.socketPath); } catch (ignored) { /* nothing there */ }
      this.server = net.createServer((socket) => {
        const connection = { socket, inbox: new Inbox(socket), send: (message) => socket.write(Buffer.from(Protocol.encodeFrame(message))), sendRaw: (bytes) => socket.write(bytes) };
        this.connections.push(connection);
        const waiter = this.waiting.shift();
        if (waiter) waiter(connection);
      });
      this.server.on('error', reject);
      this.server.listen(this.socketPath, () => {
        fs.chmodSync(this.socketPath, 0o600);
        resolve();
      });
    });
  }

  // The next helper to connect (or one that already did and was not yet claimed).
  connection(timeoutMs) {
    const unclaimed = this.connections.find((c) => !c.claimed);
    if (unclaimed) { unclaimed.claimed = true; return Promise.resolve(unclaimed); }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('No helper connected to the fake app.')), timeoutMs || 8000);
      this.waiting.push((connection) => { clearTimeout(timer); connection.claimed = true; resolve(connection); });
    });
  }

  close() {
    return new Promise((resolve) => {
      for (const connection of this.connections) connection.socket.destroy();
      this.connections = [];
      if (!this.server) return resolve();
      this.server.close(() => resolve());
      this.server = null;
      try { fs.unlinkSync(this.socketPath); } catch (ignored) { /* already gone */ }
    });
  }
}

// Chrome's side: starts the helper the way Chrome does and speaks its framing.
function startHost(binary, socketPath, extensionId) {
  const child = spawn(binary, ['chrome-extension://' + (extensionId || 'okfgkjagfedglgjgnfbcffnmopbgigem') + '/'], {
    env: Object.assign({}, process.env, { TEACHY_BROWSER_SOCKET: socketPath }),
    stdio: ['pipe', 'pipe', 'inherit']
  });
  const exited = new Promise((resolve) => child.on('exit', (code, signal) => resolve({ code, signal })));
  return {
    child,
    inbox: new Inbox(child.stdout),
    send: (message) => child.stdin.write(Buffer.from(Protocol.encodeFrame(message))),
    sendRaw: (bytes) => child.stdin.write(bytes),
    closeInput: () => child.stdin.end(),
    exited,
    kill: () => { try { child.kill('SIGKILL'); } catch (ignored) { /* gone */ } }
  };
}

function hostBinary() {
  const candidates = [
    process.env.TEACHY_HOST_BINARY,
    path.join(os.tmpdir(), 'teachy-chrome', 'host', 'teachy-browser-host'),
    path.join(__dirname, '..', '..', '..', 'native-host', '.build', 'out', 'teachy-browser-host')
  ].filter(Boolean);
  return candidates.find((candidate) => fs.existsSync(candidate)) || null;
}

module.exports = { Inbox, FakeApp, startHost, hostBinary, tempDir, Protocol };
