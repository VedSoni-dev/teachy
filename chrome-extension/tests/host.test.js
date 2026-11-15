// The native-messaging helper, tested for real: the built binary, a fake Teachy
// app on a Unix socket in a temp folder, and a fake Chrome on its stdin/stdout.
//   node --test chrome-extension/tests/host.test.js     (run.sh builds the helper first)
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { FakeApp, startHost, hostBinary, tempDir } = require('./support/harness.js');

const binary = hostBinary();
const skip = binary ? false : 'the helper is not built (run chrome-extension/tests/run.sh)';

const isHost = (eventName) => (m) => m.type === 'host' && m.event === eventName;

async function connected(t) {
  const dir = tempDir('h-');
  const socketPath = path.join(dir, 'b.sock');
  const app = new FakeApp(socketPath);
  await app.listen();
  const chrome = startHost(binary, socketPath);
  t.after(async () => { chrome.kill(); await app.close(); fs.rmSync(dir, { recursive: true, force: true }); });
  const link = await app.connection();
  const hello = await link.inbox.next(isHost('hello'), 5000, 'the helper hello');
  await chrome.inbox.next(isHost('app_connected'), 5000, 'app_connected');
  return { app, chrome, link, hello, socketPath, dir };
}

test('helper: says hello to the app and relays both ways', { skip }, async (t) => {
  const { chrome, link, hello } = await connected(t);
  assert.equal(hello.origin, 'chrome-extension://okfgkjagfedglgjgnfbcffnmopbgigem/');
  assert.equal(hello.version, 1);
  assert.equal(typeof hello.browser, 'string');
  assert.ok(hello.pid > 0);

  // app -> Chrome
  link.send({ type: 'request', id: '1', method: 'ping', params: { text: 'héllo ☕' } });
  assert.deepEqual(await chrome.inbox.next((m) => m.id === '1'), { type: 'request', id: '1', method: 'ping', params: { text: 'héllo ☕' } });

  // Chrome -> app
  chrome.send({ type: 'response', id: '1', ok: true, result: { ok: true } });
  assert.deepEqual(await link.inbox.next((m) => m.id === '1'), { type: 'response', id: '1', ok: true, result: { ok: true } });

  // Order is kept under a burst.
  for (let i = 0; i < 200; i++) chrome.send({ type: 'event', event: 'tick', n: i });
  for (let i = 0; i < 200; i++) assert.equal((await link.inbox.next((m) => m.event === 'tick')).n, i);
});

test('helper: large messages', { skip }, async (t) => {
  const { chrome, link } = await connected(t);

  // Chrome -> app: a 3 MB screenshot-sized message arrives whole.
  const big = 'A'.repeat(3 * 1024 * 1024);
  chrome.send({ type: 'response', id: 'shot', ok: true, result: { data: big } });
  const arrived = await link.inbox.next((m) => m.id === 'shot', 10000, 'the 3 MB message');
  assert.equal(arrived.result.data.length, big.length);

  // app -> Chrome: just under Chrome's 1 MB limit goes through…
  const under = 'B'.repeat(900 * 1024);
  link.send({ type: 'request', id: 'ok', method: 'type', params: { text: under } });
  assert.equal((await chrome.inbox.next((m) => m.id === 'ok', 10000)).params.text.length, under.length);

  // …over it is refused back to the app with the request id, and nothing reaches Chrome.
  link.send({ type: 'request', id: 'huge', method: 'type', params: { text: 'C'.repeat(1500 * 1024) } });
  const refusal = await link.inbox.next((m) => m.type === 'host' && m.event === 'error', 10000, 'the size refusal');
  assert.equal(refusal.error, 'message_too_large');
  assert.equal(refusal.id, 'huge');
  assert.equal(refusal.limit, 1024 * 1024);

  // The pipe is still healthy afterwards.
  link.send({ type: 'request', id: 'after', method: 'ping', params: {} });
  assert.equal((await chrome.inbox.next(() => true, 5000)).id, 'after');
});

test('helper: the app is not running, then starts, then quits', { skip }, async (t) => {
  const dir = tempDir('h-');
  const socketPath = path.join(dir, 'b.sock');
  const chrome = startHost(binary, socketPath);
  const app = new FakeApp(socketPath);
  t.after(async () => { chrome.kill(); await app.close(); fs.rmSync(dir, { recursive: true, force: true }); });

  await chrome.inbox.next(isHost('app_not_running'), 5000, 'app_not_running at start');

  // A message for the app while it is away is answered by the helper, with the id.
  chrome.send({ type: 'response', id: '9', ok: true, result: {} });
  const bounced = await chrome.inbox.next((m) => m.id === '9', 5000, 'the bounced message');
  assert.equal(bounced.type, 'host');
  assert.equal(bounced.event, 'app_not_running');

  // The app opens: the helper finds it without Chrome doing anything.
  await app.listen();
  const link = await app.connection(10000);
  await link.inbox.next(isHost('hello'));
  await chrome.inbox.next(isHost('app_connected'), 10000, 'app_connected');
  chrome.send({ type: 'event', event: 'hello', browser: 'Chrome' });
  assert.equal((await link.inbox.next((m) => m.type === 'event')).event, 'hello');

  // The app quits: Chrome is told, and the helper stays up.
  await app.close();
  await chrome.inbox.next(isHost('app_not_running'), 5000, 'app_not_running after quit');
  assert.equal(chrome.child.exitCode, null);

  // And it comes back again.
  await app.listen();
  const again = await app.connection(10000);
  await again.inbox.next(isHost('hello'));
  await chrome.inbox.next(isHost('app_connected'), 10000);
});

test('helper: something that is not a socket at the path counts as "not running"', { skip }, async (t) => {
  const dir = tempDir('h-');
  const socketPath = path.join(dir, 'b.sock');
  fs.writeFileSync(socketPath, 'not a socket');
  const chrome = startHost(binary, socketPath);
  t.after(() => { chrome.kill(); fs.rmSync(dir, { recursive: true, force: true }); });
  await chrome.inbox.next(isHost('app_not_running'), 5000);
  assert.equal(chrome.child.exitCode, null);
});

test('helper: malformed frames', { skip }, async (t) => {
  const { chrome, link } = await connected(t);

  // From Chrome: bytes that are not JSON. Both sides hear about it; the next message is fine.
  const junk = Buffer.from('{"type": oops');
  const header = Buffer.alloc(4);
  header.writeUInt32LE(junk.length, 0);
  chrome.sendRaw(Buffer.concat([header, junk]));
  assert.equal((await chrome.inbox.next((m) => m.type === 'host' && m.event === 'error')).error, 'malformed_frame');
  assert.equal((await link.inbox.next((m) => m.type === 'host' && m.event === 'error')).error, 'malformed_frame');
  chrome.send({ type: 'event', event: 'still_here' });
  assert.equal((await link.inbox.next((m) => m.type === 'event')).event, 'still_here');

  // A JSON array is not a message either.
  const list = Buffer.from('[1,2]');
  header.writeUInt32LE(list.length, 0);
  chrome.sendRaw(Buffer.concat([header, list]));
  assert.equal((await chrome.inbox.next((m) => m.type === 'host' && m.event === 'error')).error, 'malformed_frame');
  await link.inbox.next((m) => m.type === 'host' && m.event === 'error');

  // From the app: same treatment, and Chrome sees nothing of it.
  header.writeUInt32LE(junk.length, 0);
  link.sendRaw(Buffer.concat([header, junk]));
  assert.equal((await link.inbox.next((m) => m.type === 'host' && m.event === 'error')).error, 'malformed_frame');
  link.send({ type: 'request', id: 'fine', method: 'ping', params: {} });
  assert.equal((await chrome.inbox.next(() => true)).id, 'fine');

  // An empty frame is malformed too, not a crash.
  chrome.sendRaw(Buffer.alloc(4));
  assert.equal((await chrome.inbox.next((m) => m.type === 'host' && m.event === 'error')).error, 'malformed_frame');
});

test('helper: an absurd length from Chrome ends it (exit 2); closing stdin ends it cleanly (exit 0)', { skip }, async (t) => {
  const first = await connected(t);
  const header = Buffer.alloc(4);
  header.writeUInt32LE(0x7ffffff0, 0);
  first.chrome.sendRaw(header);
  assert.equal((await first.chrome.exited).code, 2);

  const second = await connected(t);
  // A half-written frame followed by end of input: no hang, clean exit.
  const partial = Buffer.alloc(4);
  partial.writeUInt32LE(50, 0);
  second.chrome.sendRaw(Buffer.concat([partial, Buffer.from('{"half":')]));
  second.chrome.closeInput();
  assert.equal((await second.chrome.exited).code, 0);
});
