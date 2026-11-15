// Starts the throwaway Chromium (temp profile, headless, extension loaded) and the fixture web
// server for a test that plays the APP side itself (scripts/tests/run_chrome_e2e_tests.sh: the
// Swift bridge and agent tools). The caller owns the socket; this only points the helper at it.
//
//   node launch-for-app.js <socket path> <helper binary> <work dir>
//
// Prints one JSON line when ready: {"ready":true,"origin":"http://127.0.0.1:NNNN"}
// Then reads commands on stdin, one per line, and answers each with one JSON line:
//   stop   act like a click on the extension's toolbar button
//   tabs   list the open tabs: [{"url":…,"grouped":true|false}]
//   quit   close everything
'use strict';

const path = require('node:path');
const readline = require('node:readline');
const { findChromium, serveFixtures, launch, Inspector } = require('./browser.js');

const EXTENSION_ID = 'okfgkjagfedglgjgnfbcffnmopbgigem';
const [socketPath, hostBinary, workDir] = process.argv.slice(2);

(async () => {
  const chromium = findChromium();
  if (!chromium) {
    console.log(JSON.stringify({ ready: false, reason: 'no Chromium with --load-extension support found' }));
    process.exit(3);
  }
  const web = await serveFixtures(path.join(__dirname, '..', 'fixtures'));
  const browser = await launch({ chromium, extensionDir: path.resolve(__dirname, '..', '..'), hostBinary, socketPath, extensionId: EXTENSION_ID, workDir });
  let inspector = null;
  let session = null;

  async function inWorker(expression) {
    if (!inspector) inspector = await Inspector.connect(browser.profileDir);
    if (!session) {
      const worker = (await inspector.targets()).find((target) => target.type === 'service_worker' && target.url.includes(EXTENSION_ID));
      if (!worker) throw new Error('the extension service worker is not running');
      session = await inspector.attach(worker.targetId);
    }
    return inspector.evaluate(session, expression);
  }

  async function shutdown(code) {
    if (inspector) inspector.close();
    await browser.stop();
    web.server.close();
    process.exit(code);
  }

  console.log(JSON.stringify({ ready: true, origin: web.origin }));

  const lines = readline.createInterface({ input: process.stdin });
  lines.on('line', async (line) => {
    const command = line.trim();
    try {
      if (command === 'stop') {
        await inWorker('chrome.action.onClicked.dispatch({})');
        console.log(JSON.stringify({ ok: true }));
      } else if (command === 'tabs') {
        const tabs = await inWorker('chrome.tabs.query({}).then((all) => all.map((tab) => ({ url: tab.url, grouped: tab.groupId !== -1 })))');
        console.log(JSON.stringify({ ok: true, tabs }));
      } else if (command === 'quit') {
        await shutdown(0);
      } else {
        console.log(JSON.stringify({ ok: false, error: 'unknown command' }));
      }
    } catch (problem) {
      console.log(JSON.stringify({ ok: false, error: String(problem && problem.message ? problem.message : problem) }));
    }
  });
  lines.on('close', () => { shutdown(0); });
  process.on('SIGTERM', () => { shutdown(0); });
})().catch((problem) => {
  console.log(JSON.stringify({ ready: false, reason: String(problem && problem.message ? problem.message : problem) }));
  process.exit(1);
});
