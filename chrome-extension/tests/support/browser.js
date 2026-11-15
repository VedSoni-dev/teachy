// Starts a throwaway Chromium for the smoke test: a brand-new profile in a temp
// folder, headless, with the unpacked extension loaded and the native-messaging
// manifest written INTO that temp profile. It never touches a real browser
// profile or the real NativeMessagingHosts folders.
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { spawn } = require('node:child_process');

// A Chromium that still honours --load-extension: Playwright's "Chrome for Testing" / Chromium builds.
// (Branded Google Chrome ignores that switch in current versions, so it is not used.)
function findChromium() {
  if (process.env.TEACHY_TEST_CHROME && fs.existsSync(process.env.TEACHY_TEST_CHROME)) return process.env.TEACHY_TEST_CHROME;
  const cache = path.join(os.homedir(), 'Library', 'Caches', 'ms-playwright');
  let builds = [];
  try {
    builds = fs.readdirSync(cache).filter((name) => /^chromium-\d+$/.test(name)).sort((a, b) => Number(b.split('-')[1]) - Number(a.split('-')[1]));
  } catch (missing) {
    return null;
  }
  for (const build of builds) {
    for (const arch of ['chrome-mac-arm64', 'chrome-mac', 'chrome-mac-x64']) {
      for (const app of ['Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing', 'Chromium.app/Contents/MacOS/Chromium']) {
        const candidate = path.join(cache, build, arch, app);
        if (fs.existsSync(candidate)) return candidate;
      }
    }
  }
  return null;
}

function serveFixtures(directory) {
  const types = { '.html': 'text/html; charset=utf-8', '.png': 'image/png', '.js': 'text/javascript' };
  const server = http.createServer((request, response) => {
    const name = decodeURIComponent(new URL(request.url, 'http://x').pathname).replace(/^\/+/, '') || 'shop.html';
    const file = path.join(directory, path.basename(name));
    fs.readFile(file, (problem, data) => {
      if (problem) { response.writeHead(404); response.end('not found'); return; }
      response.writeHead(200, { 'content-type': types[path.extname(file)] || 'application/octet-stream', 'cache-control': 'no-store' });
      response.end(data);
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ server, origin: 'http://127.0.0.1:' + server.address().port })));
}

// Minimal DevTools-protocol client over the browser's debugging port. Used by the test only to
// look inside (service worker errors, tab groups) and to press a real Escape key like a person would.
class Inspector {
  constructor(socket) {
    this.socket = socket;
    this.nextId = 1;
    this.pending = new Map();
    this.events = [];
    socket.addEventListener('message', (event) => {
      const message = JSON.parse(event.data);
      if (message.id && this.pending.has(message.id)) {
        const { resolve, reject } = this.pending.get(message.id);
        this.pending.delete(message.id);
        if (message.error) reject(new Error(message.error.message)); else resolve(message.result);
      } else if (message.method) {
        this.events.push(message);
        if (this.events.length > 500) this.events.shift();
      }
    });
  }

  static async connect(profileDir, timeoutMs) {
    const portFile = path.join(profileDir, 'DevToolsActivePort');
    const deadline = Date.now() + (timeoutMs || 15000);
    while (!fs.existsSync(portFile)) {
      if (Date.now() > deadline) throw new Error('Chromium did not open its debugging port.');
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    const [port, browserPath] = fs.readFileSync(portFile, 'utf8').trim().split('\n');
    const socket = new WebSocket('ws://127.0.0.1:' + port + browserPath);
    await new Promise((resolve, reject) => { socket.addEventListener('open', resolve); socket.addEventListener('error', () => reject(new Error('debugging socket failed'))); });
    return new Inspector(socket);
  }

  send(method, params, sessionId) {
    const id = this.nextId++;
    const message = { id, method, params: params || {} };
    if (sessionId) message.sessionId = sessionId;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.socket.send(JSON.stringify(message));
    });
  }

  async targets() {
    return (await this.send('Target.getTargets')).targetInfos;
  }

  async attach(targetId) {
    return (await this.send('Target.attachToTarget', { targetId, flatten: true })).sessionId;
  }

  async evaluate(sessionId, expression) {
    const reply = await this.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, sessionId);
    if (reply.exceptionDetails) throw new Error('evaluate failed: ' + (reply.exceptionDetails.exception ? reply.exceptionDetails.exception.description : reply.exceptionDetails.text));
    return reply.result.value;
  }

  close() { try { this.socket.close(); } catch (ignored) { /* closed */ } }
}

async function launch({ chromium, extensionDir, hostBinary, socketPath, extensionId, workDir }) {
  const profileDir = path.join(workDir, 'profile');
  const hostsDir = path.join(profileDir, 'NativeMessagingHosts');
  fs.mkdirSync(hostsDir, { recursive: true });
  // With --user-data-dir, Chromium looks for user-level native hosts inside that folder.
  fs.writeFileSync(path.join(hostsDir, 'com.teachy.browser.json'), JSON.stringify({
    name: 'com.teachy.browser',
    description: 'Teachy test helper',
    path: hostBinary,
    type: 'stdio',
    allowed_origins: ['chrome-extension://' + extensionId + '/']
  }, null, 2));

  const child = spawn(chromium, [
    '--headless=new',
    '--user-data-dir=' + profileDir,
    '--load-extension=' + extensionDir,
    '--disable-extensions-except=' + extensionDir,
    '--remote-debugging-port=0',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-search-engine-choice-screen',
    '--disable-background-networking',
    '--disable-component-update',
    '--disable-sync',
    '--password-store=basic',
    '--use-mock-keychain',
    '--window-size=1100,800',
    'about:blank'
  ], {
    env: Object.assign({}, process.env, { TEACHY_BROWSER_SOCKET: socketPath }),
    stdio: ['ignore', 'ignore', 'pipe']
  });
  let stderr = '';
  child.stderr.on('data', (chunk) => { stderr = (stderr + chunk).slice(-4000); });
  const exited = new Promise((resolve) => child.on('exit', resolve));
  return {
    child, profileDir, exited,
    stderr: () => stderr,
    async stop() {
      try { child.kill('SIGTERM'); } catch (ignored) { /* gone */ }
      await Promise.race([exited, new Promise((resolve) => setTimeout(resolve, 4000))]);
      try { child.kill('SIGKILL'); } catch (ignored) { /* gone */ }
    }
  };
}

module.exports = { findChromium, serveFixtures, launch, Inspector };
