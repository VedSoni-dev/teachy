// End to end, in a real Chromium, without anybody's real browser:
//
//   this test (plays the Teachy app: a Unix socket in a temp folder)
//     <-> the built native-messaging helper (started by Chromium)
//       <-> the unpacked extension in a headless Chromium with a brand-new temp profile
//         <-> HTML fixtures served from a local temp HTTP server
//
//   node --test chrome-extension/tests/smoke.test.js     (run.sh builds the helper first)
//
// Skipped (and says so) when no suitable Chromium or helper is found.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { FakeApp, hostBinary, tempDir } = require('./support/harness.js');
const { findChromium, serveFixtures, launch, Inspector } = require('./support/browser.js');

const EXTENSION_ID = 'okfgkjagfedglgjgnfbcffnmopbgigem';
const extensionDir = path.resolve(__dirname, '..');
const chromium = findChromium();
const binary = hostBinary();
const skip = !chromium ? 'no Chromium with --load-extension support found (Playwright cache or TEACHY_TEST_CHROME)'
  : !binary ? 'the helper is not built (run chrome-extension/tests/run.sh)' : false;

test('extension smoke test in headless Chromium', { skip, timeout: 180000 }, async (t) => {
  const workDir = tempDir('s-');
  const socketPath = path.join(workDir, 'b.sock');
  const app = new FakeApp(socketPath);
  await app.listen();
  const web = await serveFixtures(path.join(__dirname, 'fixtures'));
  const browser = await launch({ chromium, extensionDir, hostBinary: binary, socketPath, extensionId: EXTENSION_ID, workDir });
  let inspector = null;
  let workerSession = null;

  t.after(async () => {
    if (inspector) inspector.close();
    await browser.stop();
    await app.close();
    web.server.close();
    fs.rmSync(workDir, { recursive: true, force: true });
  });

  let link;
  try {
    link = await app.connection(30000);
  } catch (problem) {
    throw new Error('The extension never reached the fake app through the helper. Chromium said:\n' + browser.stderr());
  }

  let nextId = 1;
  async function call(method, params, timeoutMs) {
    const id = 'r' + nextId++;
    link.send({ type: 'request', id, method, params: params || {} });
    const reply = await link.inbox.next((m) => m.type === 'response' && m.id === id, timeoutMs || 30000, method);
    if (!reply.ok) {
      const failure = new Error(method + ' failed: ' + reply.error.code + ': ' + reply.error.message);
      failure.code = reply.error.code;
      throw failure;
    }
    return reply.result;
  }
  const indexOf = (outline, pattern) => {
    const line = outline.split('\n').find((candidate) => pattern.test(candidate));
    assert.ok(line, 'no line matching ' + pattern + ' in:\n' + outline);
    return Number(/^\[(\d+)\]/.exec(line)[1]);
  };
  // Runs code inside the extension's service worker (to look at tab groups and the badge).
  async function inWorker(expression) {
    if (!inspector) inspector = await Inspector.connect(browser.profileDir);
    if (!workerSession) {
      const worker = (await inspector.targets()).find((target) => target.type === 'service_worker' && target.url.includes(EXTENSION_ID));
      assert.ok(worker, 'the extension service worker is not running');
      workerSession = await inspector.attach(worker.targetId);
    }
    return inspector.evaluate(workerSession, expression);
  }

  const JOB = 'job-smoke-1';
  let tab = 0;
  let outline = '';

  await t.test('the helper and the extension both say hello', async () => {
    const hostHello = await link.inbox.next((m) => m.type === 'host' && m.event === 'hello', 10000, 'helper hello');
    assert.equal(hostHello.origin, 'chrome-extension://' + EXTENSION_ID + '/', 'the extension id derived from the manifest key');
    assert.match(hostHello.browser, /Chrom/);
    const hello = await link.inbox.next((m) => m.type === 'event' && m.event === 'hello', 10000, 'extension hello');
    assert.equal(hello.protocol, 1);
    assert.equal(hello.extensionId, EXTENSION_ID);
    const pong = await call('ping');
    assert.equal(pong.ok, true);
  });

  await t.test('rejects what it should before touching the browser', async () => {
    await assert.rejects(call('open_tab', { job: JOB, url: 'javascript:alert(1)' }), (e) => e.code === 'bad_url');
    await assert.rejects(call('open_tab', { job: JOB, url: 'file:///etc/passwd' }), (e) => e.code === 'bad_url');
    await assert.rejects(call('open_tab', { url: web.origin + '/shop.html' }), (e) => e.code === 'bad_params');
    await assert.rejects(call('read_page', { tab: 999999 }), (e) => e.code === 'not_job_tab');
    link.send({ type: 'request', id: 'bad1', method: 'steal_cookies', params: {} });
    const refused = await link.inbox.next((m) => m.id === 'bad1');
    assert.equal(refused.error.code, 'unknown_method');
    await call('close_job', { job: JOB });
  });

  await t.test('open_tab: a new tab in the job\'s own named, blue group', async () => {
    const opened = await call('open_tab', { job: JOB, name: 'Buy a kettle', url: web.origin + '/shop.html' });
    tab = opened.tab;
    assert.ok(tab > 0);
    assert.equal(opened.title, 'Fixture Shop');
    assert.equal(opened.loaded, true);
    assert.equal(opened.borrowed, false);

    const groups = await inWorker('chrome.tabGroups.query({}).then((g) => g.map((x) => ({ title: x.title, color: x.color })))');
    assert.deepEqual(groups, [{ title: 'Buy a kettle', color: 'blue' }]);
    const grouped = await inWorker('chrome.tabs.get(' + tab + ').then((x) => x.groupId)');
    assert.notEqual(grouped, -1);
    assert.equal(await inWorker('chrome.action.getBadgeText({})'), '1');

    const listed = await call('list_tabs', { job: JOB });
    assert.equal(listed.tabs.length, 1);
    assert.equal(listed.tabs[0].tab, tab);
    assert.equal(listed.tabs[0].opened, true);
  });

  await t.test('read_page: address, title, readable text and numbered controls', async () => {
    const page = await call('read_page', { tab });
    outline = page.outline;
    assert.equal(page.url, web.origin + '/shop.html');
    assert.equal(page.title, 'Fixture Shop');
    assert.match(page.text, /# Blue Kettle/);
    assert.match(page.text, /pours without dripping/);
    assert.ok(!page.text.includes('Fixture Shop Ltd.'), 'the footer is not main content');

    assert.match(outline, /\[\d+\] button "Add to cart"/);
    assert.match(outline, /\[\d+\] link "Journal"/);
    assert.match(outline, /\[\d+\] textbox "Email" value=""/);
    assert.match(outline, /\[\d+\] combobox "Quantity" value="One"/);
    assert.match(outline, /\[\d+\] checkbox "Gift wrap" unchecked/);
    assert.match(outline, /\[\d+\] clickable "See details"/);
    assert.match(outline, /\[\d+\] file input "Photo"/);
    // Shadow DOM and a same-origin iframe are walked.
    assert.match(outline, /\[\d+\] button "Shadow hello"/);
    assert.match(outline, /\[\d+\] button "Frame button"/);
    // Off-screen but reachable by scrolling.
    assert.match(outline, /\[\d+\] button "Far away button" \(off screen\)/);
    // Hidden and disabled controls are not offered.
    assert.ok(!outline.includes('You cannot see me'));
    assert.ok(!outline.includes('Sold out'));
  });

  await t.test('private fields are listed, but their values are never read', async () => {
    assert.match(outline, /\[\d+\] textbox "Password" \(password: the person types this\)/);
    assert.match(outline, /\[\d+\] textbox "Verification code" \(verification code: the person types this\)/);
    assert.match(outline, /\[\d+\] textbox "Card number" \(card or bank details: the person types this\)/);
    const page = await call('read_page', { tab });
    const everything = JSON.stringify(page);
    for (const secret of ['hunter2', '424242', '4111 1111']) assert.ok(!everything.includes(secret), 'leaked ' + secret);
  });

  await t.test('click: trusted input, and a diff of what changed', async () => {
    const clicked = await call('click', { tab, index: indexOf(outline, /button "Add to cart"/) });
    assert.equal(clicked.via, 'pointer');
    assert.equal(clicked.changed, true);
    assert.match(clicked.diff, /Appeared:\n {2}\[\d+\] button "Go to checkout"/);
    const page = await call('read_page', { tab });
    assert.match(page.text, /Cart: 1/);
    assert.match(page.text, /click trusted=true/, 'the page saw a real (trusted) click');
    // Numbers stay put between reads of the same page.
    assert.equal(indexOf(page.outline, /button "Add to cart"/), indexOf(outline, /button "Add to cart"/));
    outline = page.outline;
  });

  await t.test('click inside shadow DOM and inside an iframe', async () => {
    await call('click', { tab, index: indexOf(outline, /button "Shadow hello"/) });
    await call('click', { tab, index: indexOf(outline, /button "Frame button"/) });
    const page = await call('read_page', { tab });
    assert.match(page.text, /shadow clicked/);
    assert.match(page.text, /frame clicked trusted=true/);
  });

  await t.test('type: trusted text into an ordinary field', async () => {
    const email = indexOf(outline, /textbox "Email"/);
    const typed = await call('type', { tab, index: email, text: 'ada@example.com' });
    assert.equal(typed.via, 'keyboard');
    assert.equal(typed.typed, 15);
    assert.match(typed.diff, /Changed:\n {2}\[\d+\] textbox "Email" value="ada@example\.com"/);
    assert.match(typed.diff, /Focus is on \[\d+\] textbox "Email"/);
    const page = await call('read_page', { tab });
    assert.match(page.text, /input trusted=true/, 'the page saw real (trusted) typing');

    // Typing again replaces; clear:false appends.
    await call('type', { tab, index: email, text: 'bob@example.com' });
    const appended = await call('type', { tab, index: email, text: '.uk', clear: false });
    assert.match(appended.diff, /value="bob@example\.com\.uk"/);
  });

  await t.test('secrets rule: password, code and card fields are handed back', async () => {
    for (const [pattern, kind] of [[/textbox "Password"/, 'password'], [/textbox "Verification code"/, 'one_time_code'], [/textbox "Card number"/, 'payment']]) {
      const refused = await call('type', { tab, index: indexOf(outline, pattern), text: 'should-never-arrive' });
      assert.ok(refused.needs_user, 'expected needs_user for ' + kind);
      assert.equal(refused.needs_user.kind, kind);
      assert.ok(refused.needs_user.field.length > 0);
      assert.equal(refused.typed, undefined);
    }
    // Clicking into the password field is allowed; typing it key by key is not.
    await call('click', { tab, index: indexOf(outline, /textbox "Password"/) });
    const keyed = await call('press_key', { tab, combo: 'x' });
    assert.equal(keyed.needs_user.kind, 'password');
    // Non-character keys still work there (Tab moves on).
    const tabbed = await call('press_key', { tab, combo: 'Tab' });
    assert.equal(tabbed.pressed, 'Tab');
    // The page's fields were not changed by any of that.
    const values = await inWorker(
      'chrome.debugger.sendCommand({ tabId: ' + tab + ' }, "Runtime.evaluate", { returnByValue: true, expression: ' +
      JSON.stringify('[document.getElementById("password").value, document.getElementById("otp").value, document.getElementById("card").value].join("|")') +
      ' }).then((r) => r.result.value)');
    assert.equal(values, 'hunter2-do-not-read|424242|4111 1111 1111 1111');
  });

  await t.test('select, press_key and scroll', async () => {
    const picked = await call('select', { tab, index: indexOf(outline, /combobox "Quantity"/), option: 'Three' });
    assert.equal(picked.selected, 'Three');
    assert.match(picked.diff, /combobox "Quantity" value="Three"/);
    await assert.rejects(call('select', { tab, index: indexOf(outline, /combobox "Quantity"/), option: 'Nine' }), (e) => e.code === 'no_such_option' && /One \| Two \| Three/.test(e.message));

    await call('click', { tab, index: indexOf(outline, /textbox "Notes"/) });
    await call('press_key', { tab, combo: 'h' });
    await call('press_key', { tab, combo: 'shift+i' });
    const notes = await call('read_page', { tab });
    assert.match(notes.outline, /textbox "Notes" value="hI"/);
    await assert.rejects(call('press_key', { tab, combo: 'cmd+v' }), (e) => e.code === 'not_allowed');

    const down = await call('scroll', { tab, direction: 'bottom' });
    assert.equal(down.scrolled, true);
    assert.ok(down.position > 500, 'scrolled down: ' + down.position);
    const far = await call('read_page', { tab });
    assert.match(far.outline, /\[\d+\] button "Far away button"$/m, 'now on screen');
    const up = await call('scroll', { tab, index: indexOf(outline, /button "Add to cart"/) });
    assert.equal(up.scrolled, true);
  });

  await t.test('wait_for: text that appears later, and a timeout', async () => {
    await call('click', { tab, index: indexOf(outline, /clickable "See details"/) });
    const waited = await call('wait_for', { tab, condition: { text: 'Details loaded late' }, timeout: 5 });
    assert.equal(waited.met, true);
    const element = await call('wait_for', { tab, condition: { element: 'Go to checkout' }, timeout: 2 });
    assert.equal(element.met, true);
    assert.match(element.found, /button "Go to checkout"/);
    const loaded = await call('wait_for', { tab, condition: { load: 'complete' }, timeout: 2 });
    assert.equal(loaded.met, true);
    const never = await call('wait_for', { tab, condition: { text: 'this never shows up' }, timeout: 0.6 });
    assert.equal(never.met, false);
    assert.ok(never.waited_ms >= 500);
  });

  await t.test('a confirm() box is answered Cancel unless told otherwise', async () => {
    const ask = indexOf(outline, /button "Ask before deleting"/);
    const cancelled = await call('click', { tab, index: ask });
    assert.match(cancelled.diff, /showed a confirm box: "Really delete everything\?" - answered Cancel/);
    assert.match((await call('read_page', { tab })).text, /Answered no/);
    const accepted = await call('click', { tab, index: ask, accept_dialogs: true });
    assert.match(accepted.diff, /answered OK/);
    assert.match((await call('read_page', { tab })).text, /Answered yes/);
  });

  await t.test('screenshot: a JPEG of the page, private fields blurred', async () => {
    const shot = await call('screenshot', { tab });
    assert.equal(shot.mime, 'image/jpeg');
    const bytes = Buffer.from(shot.data, 'base64');
    assert.ok(bytes.length > 3000, 'image has content: ' + bytes.length);
    assert.deepEqual([bytes[0], bytes[1], bytes[2]], [0xff, 0xd8, 0xff]);
    assert.ok(shot.width > 300 && shot.height > 200);
    assert.equal(shot.hidden_fields, 2, 'the code and card fields are blurred (the browser already dots the password)');
    fs.writeFileSync(path.join(path.dirname(workDir), 'last-smoke-screenshot.jpg'), bytes);
  });

  await t.test('upload_file: only with a consent token for that exact file', async () => {
    const photo = indexOf(outline, /file input "Photo"/);
    const file = path.join(workDir, 'photo.txt');
    fs.writeFileSync(file, 'not really a photo');
    await assert.rejects(call('upload_file', { tab, index: photo, path: file }), (e) => e.code === 'upload_not_consented');
    await assert.rejects(call('upload_file', { tab, index: photo, path: file, consent_token: 'made-up-token-0000000' }), (e) => e.code === 'upload_not_consented');
    // A token for a different file does not cover this one.
    await call('grant_upload', { token: 'token-for-another-file-1', path: '/tmp/other.txt' });
    await assert.rejects(call('upload_file', { tab, index: photo, path: file, consent_token: 'token-for-another-file-1' }), (e) => e.code === 'upload_not_consented');
    // Clicking the file control does not open a chooser; it points at upload_file.
    await assert.rejects(call('click', { tab, index: photo }), (e) => e.code === 'needs_upload');

    await call('grant_upload', { token: 'token-for-the-photo-0001', path: file });
    const uploaded = await call('upload_file', { tab, index: photo, path: file, consent_token: 'token-for-the-photo-0001' });
    assert.equal(uploaded.uploaded, 'photo.txt');
    assert.match((await call('read_page', { tab })).text, /Chosen: photo\.txt/);
    // One use only.
    await assert.rejects(call('upload_file', { tab, index: photo, path: file, consent_token: 'token-for-the-photo-0001' }), (e) => e.code === 'upload_not_consented');
  });

  await t.test('navigate, back, forward, reload: a new page gets new numbers', async () => {
    const before = indexOf(outline, /button "Add to cart"/);
    const moved = await call('navigate', { tab, url: web.origin + '/article.html' });
    assert.match(moved.diff, /A new page loaded: "How kettles whistle - Fixture Journal"/);
    assert.equal(moved.url, web.origin + '/article.html');
    const article = await call('read_page', { tab });
    assert.match(article.text, /^# How kettles whistle/);
    assert.match(article.text, /steam is forced through two small holes/);
    for (const unwanted of ['Most read', 'Accept all cookies', 'Copyright', 'Screen-reader only', 'Hidden paragraph', 'never be read']) {
      assert.ok(!article.text.includes(unwanted), 'article text should not contain: ' + unwanted);
    }
    const numbers = article.outline.split('\n').map((line) => Number(/^\[(\d+)\]/.exec(line)[1]));
    assert.ok(Math.min(...numbers) > before, 'numbers on the new page start past the old ones');
    // An old number no longer points at anything.
    await assert.rejects(call('click', { tab, index: before }), (e) => e.code === 'no_such_element');

    const back = await call('back', { tab });
    assert.equal(back.url, web.origin + '/shop.html');
    const forward = await call('forward', { tab });
    assert.equal(forward.url, web.origin + '/article.html');
    const again = await call('reload', { tab });
    assert.equal(again.url, web.origin + '/article.html');
    await assert.rejects(call('navigate', { tab, url: 'chrome://settings' }), (e) => e.code === 'bad_url');
  });

  await t.test('submitting a form with Enter, and a link that opens a new tab', async () => {
    await call('navigate', { tab, url: web.origin + '/shop.html' });
    const shop = await call('read_page', { tab });
    const sent = await call('type', { tab, index: indexOf(shop.outline, /textbox "Email"/), text: 'ada@example.com', submit: true });
    assert.equal(sent.submitted, true);
    assert.match(sent.diff, /A new page loaded: "Thanks"/);
    assert.match(sent.url, /thanks\.html\?email=ada%40example\.com/);

    await call('back', { tab });
    const again = await call('read_page', { tab });
    const link2 = await call('click', { tab, index: indexOf(again.outline, /link "Open the journal in a new tab"/) });
    assert.match(link2.diff, /A new tab opened in this job: tab \d+/);
    const listed = await call('list_tabs', { job: JOB });
    assert.equal(listed.tabs.length, 2);
    const other = listed.tabs.find((entry) => entry.tab !== tab);
    const otherPage = await call('read_page', { tab: other.tab });
    assert.match(otherPage.title, /How kettles whistle/);
    assert.equal(await inWorker('chrome.tabs.get(' + other.tab + ').then((x) => x.groupId)'), await inWorker('chrome.tabs.get(' + tab + ').then((x) => x.groupId)'));
  });

  await t.test('the glow and cursor are on the page, and invisible to clicks', async () => {
    const presence = await inWorker(
      'chrome.debugger.sendCommand({ tabId: ' + tab + ' }, "Runtime.evaluate", { returnByValue: true, expression: ' +
      JSON.stringify('(function () { var p = document.querySelector("teachy-presence"); return p ? getComputedStyle(p).pointerEvents + "|" + getComputedStyle(p).position : "missing"; })()') +
      ' }).then((r) => r.result.value)');
    assert.equal(presence, 'none|fixed');
  });

  await t.test('close_job: the job\'s tabs close, the group and badge go', async () => {
    const summary = await call('close_job', { job: JOB });
    assert.equal(summary.closed, 2);
    assert.equal(summary.returned, 0);
    const left = await inWorker('chrome.tabs.query({}).then((all) => all.map((x) => x.url))');
    assert.ok(!left.some((url) => url.includes('127.0.0.1')), 'job tabs are closed: ' + left.join(', '));
    assert.deepEqual(await inWorker('chrome.tabGroups.query({}).then((g) => g.length)'), 0);
    assert.equal(await inWorker('chrome.action.getBadgeText({})'), '');
    await assert.rejects(call('read_page', { tab }), (e) => e.code === 'not_job_tab');
  });

  await t.test('a borrowed tab goes back where it was, with no trace left on the page', async () => {
    const mine = await inWorker('chrome.tabs.create({ url: ' + JSON.stringify(web.origin + '/thanks.html') + ', active: true }).then((x) => x.id)');
    await new Promise((resolve) => setTimeout(resolve, 800));
    const borrowed = await call('open_tab', { job: 'job-borrow', name: 'Borrowing', borrow: mine });
    assert.equal(borrowed.tab, mine);
    assert.equal(borrowed.borrowed, true);
    assert.notEqual(await inWorker('chrome.tabs.get(' + mine + ').then((x) => x.groupId)'), -1);
    const page = await call('read_page', { tab: mine });
    assert.match(page.text, /Order placed/);

    const summary = await call('close_job', { job: 'job-borrow' });
    assert.deepEqual(summary, { closed: 0, kept: 0, returned: 1 });
    const after = await inWorker('chrome.tabs.get(' + mine + ').then((x) => ({ groupId: x.groupId, url: x.url }))');
    assert.equal(after.groupId, -1, 'back out of the job group');
    assert.match(after.url, /thanks\.html/, 'still open');
    await inWorker('chrome.tabs.remove(' + mine + ')');
  });

  await t.test('stopping from the browser: the toolbar icon, then a real Escape key', async () => {
    const first = await call('open_tab', { job: 'job-stop-1', name: 'Stop me', url: web.origin + '/thanks.html' });
    await inWorker('chrome.action.onClicked.dispatch({ id: ' + first.tab + ' })');
    const stopped = await link.inbox.next((m) => m.type === 'event' && m.event === 'user_stopped', 5000, 'user_stopped from the toolbar');
    assert.deepEqual({ job: stopped.job, reason: stopped.reason }, { job: 'job-stop-1', reason: 'toolbar' });
    await assert.rejects(call('read_page', { tab: first.tab }), (e) => e.code === 'user_stopped');
    // The person took the page over, so close_job leaves it open for them.
    assert.deepEqual(await call('close_job', { job: 'job-stop-1' }), { closed: 0, kept: 1, returned: 0 });
    assert.match(await inWorker('chrome.tabs.get(' + first.tab + ').then((x) => x.url)'), /thanks\.html/);
    await inWorker('chrome.tabs.remove(' + first.tab + ')');

    const second = await call('open_tab', { job: 'job-stop-2', name: 'Escape me', url: web.origin + '/shop.html' });
    // The agent's own Escape key press must NOT stop the job…
    await call('press_key', { tab: second.tab, combo: 'Escape' });
    await new Promise((resolve) => setTimeout(resolve, 1000));
    assert.equal((await call('read_page', { tab: second.tab })).title, 'Fixture Shop');
    // …a person's Escape does. Pressed here through the browser's own debugging port, like a keyboard would.
    const target = (await inspector.targets()).find((candidate) => candidate.type === 'page' && candidate.url.includes('/shop.html'));
    const session = await inspector.attach(target.targetId);
    for (const type of ['rawKeyDown', 'keyUp']) {
      await inspector.send('Input.dispatchKeyEvent', { type, key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27, nativeVirtualKeyCode: 27 }, session);
    }
    const escaped = await link.inbox.next((m) => m.type === 'event' && m.event === 'user_stopped', 5000, 'user_stopped from Escape');
    assert.deepEqual({ job: escaped.job, reason: escaped.reason }, { job: 'job-stop-2', reason: 'escape' });
    await assert.rejects(call('click', { tab: second.tab, index: 1 }), (e) => e.code === 'user_stopped');
    await call('close_job', { job: 'job-stop-2' });
  });

  await t.test('when the app goes away, jobs end and their tabs close; when it returns, work resumes', async () => {
    const opened = await call('open_tab', { job: 'job-orphan', name: 'Orphan', url: web.origin + '/thanks.html' });
    assert.ok(opened.tab > 0);
    await app.close();
    await new Promise((resolve) => setTimeout(resolve, 1500));
    const urls = await inWorker('chrome.tabs.query({}).then((all) => all.map((x) => x.url))');
    assert.ok(!urls.some((url) => url.includes('thanks.html')), 'the orphaned job tab closed: ' + urls.join(', '));

    await app.listen();
    link = await app.connection(15000);
    await link.inbox.next((m) => m.type === 'event' && m.event === 'hello', 10000, 'hello after the app came back');
    assert.equal((await call('ping')).ok, true);
  });
});
