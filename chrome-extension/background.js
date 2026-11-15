// Teachy extension: service worker.
//
// It talks to exactly one thing: the Teachy app on this Mac, through Chrome's
// native messaging (the small helper `com.teachy.browser`). It never opens a
// network connection of its own.
//
// What it does for the app, one request at a time (see lib/protocol.js):
//   - opens tabs for a job in that job's own named, blue tab group, and closes
//     the tabs the job opened when the job ends; a tab the job borrowed goes
//     back where it was;
//   - reads a page (address, title, readable text, numbered controls);
//   - clicks, types, picks options, presses keys, scrolls, navigates, waits,
//     takes screenshots, attaches a file - all through the debugger, so the
//     page sees real input - and reports what changed after each action;
//   - refuses password, verification-code and card fields (lib/secrets.js) and
//     hands those back to the person;
//   - shows a glow and a cursor on the page being worked on, and stops the job
//     when the person presses Escape there, clicks the toolbar icon, or
//     cancels Chrome's "is debugging this browser" bar.
//
// It only ever touches tabs that belong to a job. Your other tabs are not read.

importScripts('lib/protocol.js', 'lib/secrets.js', 'lib/snapshot.js', 'lib/readable.js', 'lib/keys.js');

const P = self.TeachyProtocol;
const Snap = self.TeachySnapshot;
const Keys = self.TeachyKeys;
const TeachyError = P.TeachyError;

const WORLD = 'teachy_agent';
const BINDING = '__teachyNotify';
const GROUP_COLOR = 'blue';
const AGENT_FILES = ['lib/secrets.js', 'lib/snapshot.js', 'lib/readable.js', 'content/page-agent.js'];

/** jobId -> { id, name, groupId, tabs: Map(tabId -> { opened, origin }), stopped, lastTabId } */
const jobs = new Map();
/** tabId -> { jobId, attached, contextId, maxIndex, queue, dialogs, newTabs, fileChooser, acceptDialogs } */
const tabs = new Map();
/** token -> { path, expires } : file uploads the person said yes to in the app. */
const uploadGrants = new Map();

let port = null;
let appConnected = false;
let reconnectAttempt = 0;
let reconnectTimer = null;
let lastWakeAttempt = 0;
let agentSource = null;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function withTimeout(promise, ms, code, message) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new TeachyError(code || 'timeout', message || 'Timed out.')), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

// ------------------------------------------------------------ native messaging

function browserName() {
  try {
    const brands = (navigator.userAgentData && navigator.userAgentData.brands) || [];
    const names = brands.map((brand) => brand.brand);
    if (names.includes('Microsoft Edge')) return 'Edge';
    if (names.includes('Brave') || navigator.brave) return 'Brave';
    if (names.includes('Vivaldi')) return 'Vivaldi';
    if (names.includes('Google Chrome')) return 'Chrome';
    if (names.includes('Chromium')) return 'Chromium';
  } catch (ignored) { /* fall through */ }
  return 'Chrome';
}

function send(message) {
  if (!port) return false;
  try {
    port.postMessage(message);
    return true;
  } catch (problem) {
    return false;
  }
}

function connect() {
  if (port) return;
  clearTimeout(reconnectTimer);
  reconnectTimer = null;
  let opened;
  try {
    opened = chrome.runtime.connectNative(P.HOST_NAME);
  } catch (problem) {
    scheduleReconnect();
    return;
  }
  port = opened;
  opened.onMessage.addListener((message) => { onNativeMessage(message); });
  opened.onDisconnect.addListener(() => {
    // Reading lastError marks it as handled ("host not found" when the helper is not installed).
    void chrome.runtime.lastError;
    if (port === opened) port = null;
    appConnected = false;
    endAllJobs('helper_gone');
    scheduleReconnect();
  });
}

function scheduleReconnect() {
  if (reconnectTimer || port) return;
  const delays = [1000, 2000, 5000, 10000, 20000];
  if (reconnectAttempt >= delays.length) return; // a tab switch, the toolbar icon or a browser start tries again
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, delays[reconnectAttempt++]);
}

function wake() {
  if (port) return;
  const now = Date.now();
  if (now - lastWakeAttempt < 30000) return;
  lastWakeAttempt = now;
  reconnectAttempt = 0;
  connect();
}

function onNativeMessage(message) {
  if (!message || typeof message !== 'object') return;
  if (message.type === 'host') {
    if (message.event === 'app_connected') {
      appConnected = true;
      reconnectAttempt = 0;
      send(P.event('hello', {
        protocol: P.PROTOCOL_VERSION,
        browser: browserName(),
        extensionVersion: chrome.runtime.getManifest().version,
        extensionId: chrome.runtime.id
      }));
    } else if (message.event === 'app_not_running') {
      appConnected = false;
      endAllJobs('app_gone');
    }
    return;
  }
  if (message.type === 'request') handleRequest(message);
}

async function handleRequest(message) {
  const checked = P.validateRequest(message);
  if (!checked.ok) {
    if (checked.id !== null) send(P.errorResponse(checked.id, checked.code, checked.message));
    return;
  }
  const request = checked.request;
  try {
    const result = await handlers[request.method](request.params);
    send(P.response(request.id, result));
  } catch (problem) {
    const code = problem && problem.code ? problem.code : 'failed';
    const text = problem && problem.message ? problem.message : String(problem);
    send(P.errorResponse(request.id, code, text, problem && problem.extra));
  }
}

// ------------------------------------------------------------------- debugger

function cdp(tabId, method, params) {
  return chrome.debugger.sendCommand({ tabId }, method, params || {});
}

async function ensureAttached(tabId) {
  const tab = tabs.get(tabId);
  if (!tab) throw new TeachyError('not_job_tab', 'That tab does not belong to a Teachy job.');
  if (tab.attached) return;
  try {
    await chrome.debugger.attach({ tabId }, '1.3');
  } catch (problem) {
    const text = String(problem && problem.message ? problem.message : problem);
    if (!/already attached/i.test(text) || /another debugger/i.test(text)) {
      throw new TeachyError('debugger_failed', /another debugger/i.test(text)
        ? 'Chrome DevTools is open on that tab. Close DevTools there and try again.'
        : 'Chrome would not let Teachy work in that tab: ' + text);
    }
  }
  tab.attached = true;
  tab.contextId = null;
  // Each of these is a nicety; none is required for the basics.
  const setup = [
    ['Page.enable', {}],
    ['Page.setInterceptFileChooserDialog', { enabled: true }],
    ['Emulation.setFocusEmulationEnabled', { enabled: true }]
  ];
  for (const [method, params] of setup) {
    try { await cdp(tabId, method, params); } catch (ignored) { /* older browser */ }
  }
}

async function detach(tabId) {
  const tab = tabs.get(tabId);
  if (tab) { tab.attached = false; tab.contextId = null; }
  try { await chrome.debugger.detach({ tabId }); } catch (ignored) { /* already detached */ }
}

async function loadAgentSource() {
  if (agentSource) return agentSource;
  const parts = [];
  for (const file of AGENT_FILES) {
    const reply = await fetch(chrome.runtime.getURL(file));
    parts.push(await reply.text());
  }
  agentSource = parts.join('\n;\n');
  return agentSource;
}

async function ensureContext(tabId) {
  const tab = tabs.get(tabId);
  const tree = await cdp(tabId, 'Page.getFrameTree');
  const world = await cdp(tabId, 'Page.createIsolatedWorld', { frameId: tree.frameTree.frame.id, worldName: WORLD });
  tab.contextId = world.executionContextId;
  // The page agent's one line out (Escape pressed). Only our own world gets it, and it has to be
  // added once that world exists.
  try {
    await cdp(tabId, 'Runtime.addBinding', { name: BINDING, executionContextName: WORLD });
  } catch (byName) {
    await cdp(tabId, 'Runtime.addBinding', { name: BINDING, executionContextId: tab.contextId }).catch(() => {});
  }
}

async function evaluate(tabId, expression, byValue) {
  const tab = tabs.get(tabId);
  const reply = await withTimeout(cdp(tabId, 'Runtime.evaluate', {
    expression, contextId: tab.contextId, returnByValue: byValue !== false, awaitPromise: true
  }), 10000, 'page_busy', 'The page did not answer in time.');
  if (reply.exceptionDetails) {
    const details = reply.exceptionDetails;
    const text = (details.exception && details.exception.description) || details.text || 'script error';
    throw new TeachyError('page_error', String(text).split('\n')[0]);
  }
  return reply.result;
}

async function inject(tabId) {
  const tab = tabs.get(tabId);
  const source = await loadAgentSource();
  // A new document gets numbers past every number used before, so an old [12] can never point at something new.
  const base = Math.ceil((tab.maxIndex + 1) / 100) * 100 + 1;
  await evaluate(tabId, 'globalThis.__teachyIndexBase = ' + (tab.maxIndex ? base : 1) + ';\n' + source + '\n;"ok"');
  const job = jobs.get(tab.jobId);
  if (job && !job.stopped) {
    await evaluate(tabId, 'globalThis.__teachyAgent.call("showPresence", {})').catch(() => {});
  }
}

// Runs one method of content/page-agent.js in the tab and returns its plain result.
async function agentCall(tabId, method, params, attempt) {
  const tab = tabs.get(tabId);
  if (!tab) throw new TeachyError('not_job_tab', 'That tab does not belong to a Teachy job.');
  await ensureAttached(tabId);
  const expression = 'globalThis.__teachyAgent ? globalThis.__teachyAgent.call(' + JSON.stringify(method) + ', ' +
    JSON.stringify(params || {}) + ') : "__teachy_missing__"';
  let result;
  try {
    if (!tab.contextId) await ensureContext(tabId);
    result = await evaluate(tabId, expression);
    if (result.value === '__teachy_missing__') {
      await inject(tabId);
      result = await evaluate(tabId, expression);
    }
  } catch (problem) {
    // The page navigated under us: its old world is gone. Build a new one, once.
    if ((attempt || 0) < 2 && tabs.has(tabId) && tab.attached && problem.code !== 'page_busy') {
      tab.contextId = null;
      await sleep(120);
      return agentCall(tabId, method, params, (attempt || 0) + 1);
    }
    throw problem;
  }
  return result.value;
}

function raise(pageError) {
  throw new TeachyError(pageError.code || 'page_error', pageError.message || 'The page refused.');
}

// ----------------------------------------------------------------- jobs, tabs

function jobFor(params) {
  const id = typeof params.job === 'string' ? params.job.trim() : '';
  if (!id) throw new TeachyError('bad_params', 'A job id is required.');
  let job = jobs.get(id);
  if (!job) {
    job = { id, name: 'Teachy', groupId: null, tabs: new Map(), stopped: null, lastTabId: null, actingTabId: null, expectNewTabUntil: 0 };
    jobs.set(id, job);
    updateBadge();
  }
  if (typeof params.name === 'string' && params.name.trim()) job.name = params.name.trim().slice(0, 48);
  return job;
}

// The tab a request is about: its own id, or the job's most recent tab.
function requireTab(params) {
  let tabId = Number(params.tab);
  if (!Number.isInteger(tabId) || tabId <= 0) {
    const job = typeof params.job === 'string' ? jobs.get(params.job) : null;
    tabId = job && job.lastTabId ? job.lastTabId : NaN;
  }
  const tab = tabs.get(tabId);
  if (!tab) {
    throw new TeachyError('not_job_tab', 'That tab does not belong to a Teachy job. Open a tab for the job first.');
  }
  const job = jobs.get(tab.jobId);
  if (!job) throw new TeachyError('not_job_tab', 'That job has ended.');
  if (typeof params.job === 'string' && params.job && params.job !== job.id) {
    throw new TeachyError('not_job_tab', 'That tab belongs to a different job.');
  }
  if (job.stopped) {
    throw new TeachyError('user_stopped', 'The person stopped this job in the browser (' + job.stopped + ').');
  }
  job.lastTabId = tabId;
  return { tabId, tab, job };
}

function needIndex(params) {
  const index = Number(params.index);
  if (!Number.isInteger(index) || index <= 0) throw new TeachyError('bad_params', 'index must be the [number] of a control.');
  return index;
}

function track(tabId, job, record) {
  tabs.set(tabId, {
    jobId: job.id, attached: false, contextId: null, maxIndex: 0, queue: Promise.resolve(),
    dialogs: [], newTabs: [], fileChooser: null, acceptDialogs: false
  });
  job.tabs.set(tabId, record);
  job.lastTabId = tabId;
}

async function pickWindow(job) {
  if (job.groupId !== null) {
    try {
      const group = await chrome.tabGroups.get(job.groupId);
      return group.windowId;
    } catch (gone) {
      job.groupId = null;
    }
  }
  try {
    const focused = await chrome.windows.getLastFocused({ windowTypes: ['normal'] });
    if (focused && !focused.incognito && focused.type === 'normal') return focused.id;
  } catch (ignored) { /* no window */ }
  const all = await chrome.windows.getAll({ windowTypes: ['normal'] });
  const usable = all.find((candidate) => !candidate.incognito);
  return usable ? usable.id : null;
}

async function addToGroup(job, tabId, windowId) {
  if (job.groupId !== null) {
    try {
      await chrome.tabs.group({ tabIds: [tabId], groupId: job.groupId });
      return;
    } catch (gone) {
      job.groupId = null;
    }
  }
  const options = { tabIds: [tabId] };
  if (windowId !== null && windowId !== undefined) options.createProperties = { windowId };
  job.groupId = await chrome.tabs.group(options);
  await chrome.tabGroups.update(job.groupId, { title: job.name, color: GROUP_COLOR, collapsed: false });
}

function waitForLoad(tabId, timeoutMs) {
  return new Promise((resolve) => {
    let finished = false;
    const done = (loaded) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      chrome.tabs.onUpdated.removeListener(listener);
      resolve(loaded);
    };
    const listener = (updatedId, change) => {
      if (updatedId === tabId && change.status === 'complete') done(true);
    };
    const timer = setTimeout(() => done(false), timeoutMs);
    chrome.tabs.onUpdated.addListener(listener);
    chrome.tabs.get(tabId).then((tab) => {
      if (tab.status === 'complete' && tab.url && tab.url !== 'about:blank' && !tab.pendingUrl) done(true);
    }).catch(() => done(false));
  });
}

async function restoreBorrowed(tabId, origin) {
  try {
    let regrouped = false;
    if (origin && origin.groupId !== undefined && origin.groupId !== -1) {
      try {
        await chrome.tabGroups.get(origin.groupId);
        await chrome.tabs.group({ tabIds: [tabId], groupId: origin.groupId });
        regrouped = true;
      } catch (gone) { /* its old group no longer exists */ }
    }
    if (!regrouped) await chrome.tabs.ungroup([tabId]);
    if (origin) {
      await chrome.tabs.move(tabId, { windowId: origin.windowId, index: origin.index }).catch(() => {});
      if (origin.pinned) await chrome.tabs.update(tabId, { pinned: true }).catch(() => {});
    }
  } catch (ignored) { /* the tab is gone */ }
}

async function releaseTab(tabId, mode) {
  const tab = tabs.get(tabId);
  if (!tab) return;
  const job = jobs.get(tab.jobId);
  const record = job ? job.tabs.get(tabId) : null;
  if (tab.attached) {
    try { await withTimeout(agentCall(tabId, 'hidePresence', {}), 1500); } catch (ignored) { /* page busy or gone */ }
  }
  await detach(tabId);
  tabs.delete(tabId);
  if (job) {
    job.tabs.delete(tabId);
    if (job.lastTabId === tabId) job.lastTabId = job.tabs.size ? Array.from(job.tabs.keys()).pop() : null;
  }
  if (!record) return;
  if (!record.opened) {
    await restoreBorrowed(tabId, record.origin);
  } else if (mode === 'close') {
    await chrome.tabs.remove(tabId).catch(() => {});
  } else {
    await chrome.tabs.ungroup([tabId]).catch(() => {});
  }
}

// Ends a job: its own tabs close (unless kept, or the person took the job over), borrowed tabs go home.
async function closeJob(job, keep) {
  const kept = new Set((keep || []).map(Number));
  const summary = { closed: 0, kept: 0, returned: 0 };
  for (const [tabId, record] of Array.from(job.tabs.entries())) {
    if (!record.opened) {
      summary.returned++;
      await releaseTab(tabId, 'keep');
    } else if (kept.has(tabId) || job.stopped === 'escape' || job.stopped === 'toolbar' || job.stopped === 'debugger_bar') {
      summary.kept++;
      await releaseTab(tabId, 'keep');
    } else {
      summary.closed++;
      await releaseTab(tabId, 'close');
    }
  }
  jobs.delete(job.id);
  updateBadge();
  return summary;
}

function endAllJobs(reason) {
  for (const job of Array.from(jobs.values())) {
    closeJob(job, []).catch(() => {});
  }
  uploadGrants.clear();
  void reason;
}

// The person took the page back.
async function stopJob(job, reason) {
  if (!job || job.stopped) return;
  job.stopped = reason;
  send(P.event('user_stopped', { job: job.id, reason }));
  for (const tabId of Array.from(job.tabs.keys())) {
    const tab = tabs.get(tabId);
    if (tab && tab.attached) {
      try { await withTimeout(agentCall(tabId, 'hidePresence', {}), 1500); } catch (ignored) { /* gone */ }
    }
    await detach(tabId);
  }
  updateBadge();
}

function updateBadge() {
  let active = 0;
  for (const job of jobs.values()) if (!job.stopped) active++;
  chrome.action.setBadgeText({ text: active ? String(active) : '' }).catch(() => {});
  chrome.action.setBadgeBackgroundColor({ color: '#0A84FF' }).catch(() => {});
  chrome.action.setTitle({
    title: active ? 'Teachy is working in this browser. Click to stop.' : 'Teachy'
  }).catch(() => {});
}

// --------------------------------------------------------------- page actions

async function takeSnapshot(tabId, options) {
  const tab = tabs.get(tabId);
  const result = await agentCall(tabId, 'snapshot', options || {});
  if (result && result.error) raise(result.error);
  if (tab && result.maxIndex > tab.maxIndex) tab.maxIndex = result.maxIndex;
  return result;
}

// Waits for the page to stop loading and stop changing, for a short while.
async function settle(tabId, maxMs) {
  const started = Date.now();
  await sleep(100);
  while (Date.now() - started < (maxMs || 3500)) {
    let info;
    try { info = await chrome.tabs.get(tabId); } catch (gone) { return; }
    if (info.status === 'complete') {
      let state = null;
      try { state = await agentCall(tabId, 'settled', {}); } catch (ignored) { state = null; }
      if (state && state.readyState === 'complete' && state.quietFor >= 220) return;
    }
    await sleep(110);
  }
}

// Does something to the page, then reports what changed - the same contract as the app's Drive tools.
async function act(tabId, perform, options) {
  const tab = tabs.get(tabId);
  tab.dialogs = [];
  tab.newTabs = [];
  tab.fileChooser = null;
  const job = jobs.get(tab.jobId);
  if (job) { job.actingTabId = tabId; job.expectNewTabUntil = Date.now() + 4000; }
  const before = await takeSnapshot(tabId);
  let outcome;
  try {
    outcome = (await perform(before)) || {};
  } finally {
    tab.acceptDialogs = false;
  }
  if (outcome.needs_user) return outcome;

  if (options && options.load) await waitForLoad(tabId, options.load);
  await settle(tabId, options && options.settle);

  const notes = [];
  let after = null;
  if (!tabs.has(tabId)) {
    notes.push('The tab closed.');
  } else {
    try {
      after = await takeSnapshot(tabId);
    } catch (problem) {
      notes.push('The page could not be read after that (' + problem.message + ').');
    }
  }
  const change = after ? Snap.diff(before, after) : null;
  if (change) notes.unshift(change.text);
  for (const dialog of tab.dialogs) {
    notes.push('The page showed a ' + dialog.type + ' box: "' + Snap.clean(dialog.message, 200) + '" - answered ' +
      (dialog.accepted ? 'OK.' : 'Cancel. To answer OK, do it again with accept_dialogs.'));
  }
  for (const opened of tab.newTabs) notes.push('A new tab opened in this job: tab ' + opened + '.');
  if (tab.fileChooser) notes.push('The page asked for a file. Use upload_file with the path of the file.');

  outcome.diff = notes.join('\n');
  outcome.changed = !!change && change.text !== 'Nothing changed on the page.';
  if (after) { outcome.url = after.url; outcome.title = after.title; }
  outcome.tab = tabId;
  return outcome;
}

async function showCursor(tabId, point) {
  if (!point) return;
  try {
    const shown = await agentCall(tabId, 'moveCursor', { x: point.x, y: point.y, press: true });
    if (shown && shown.shown) await sleep(230);
  } catch (ignored) { /* the cursor is decoration */ }
}

async function mouseClick(tabId, point) {
  const base = { x: point.x, y: point.y, button: 'left', clickCount: 1, pointerType: 'mouse' };
  await cdp(tabId, 'Input.dispatchMouseEvent', { type: 'mouseMoved', x: point.x, y: point.y, button: 'none', pointerType: 'mouse' });
  await cdp(tabId, 'Input.dispatchMouseEvent', Object.assign({ type: 'mousePressed', buttons: 1 }, base));
  await cdp(tabId, 'Input.dispatchMouseEvent', Object.assign({ type: 'mouseReleased', buttons: 0 }, base));
}

async function dispatchKey(tabId, combo) {
  const down = {
    type: combo.text ? 'keyDown' : 'rawKeyDown',
    key: combo.key, code: combo.code, modifiers: combo.modifiers,
    windowsVirtualKeyCode: combo.keyCode, nativeVirtualKeyCode: combo.keyCode
  };
  if (combo.text) { down.text = combo.text; down.unmodifiedText = combo.text; }
  if (combo.commands && combo.commands.length) down.commands = combo.commands;
  await cdp(tabId, 'Input.dispatchKeyEvent', down);
  await cdp(tabId, 'Input.dispatchKeyEvent', {
    type: 'keyUp', key: combo.key, code: combo.code, modifiers: combo.modifiers,
    windowsVirtualKeyCode: combo.keyCode, nativeVirtualKeyCode: combo.keyCode
  });
}

async function pressKey(tabId, combo) {
  if (combo.key === 'Escape') await agentCall(tabId, 'expectEscape', {});
  try {
    await withTimeout(dispatchKey(tabId, combo), 3000);
    return 'keyboard';
  } catch (problem) {
    await agentCall(tabId, 'domKey', {
      key: combo.key, code: combo.code, keyCode: combo.keyCode,
      alt: !!(combo.modifiers & Keys.ALT), ctrl: !!(combo.modifiers & Keys.CTRL),
      meta: !!(combo.modifiers & Keys.META), shift: !!(combo.modifiers & Keys.SHIFT)
    });
    return 'dom';
  }
}

// Each tab does one thing at a time.
function queued(tabId, work) {
  const tab = tabs.get(tabId);
  const run = tab.queue.then(work, work);
  tab.queue = run.then(() => {}, () => {});
  return run;
}

function historyStep(method) {
  return async (params) => {
    const { tabId } = requireTab(params);
    return queued(tabId, () => act(tabId, async () => {
      try {
        if (method === 'back') await chrome.tabs.goBack(tabId);
        else if (method === 'forward') await chrome.tabs.goForward(tabId);
        else await chrome.tabs.reload(tabId);
      } catch (problem) {
        throw new TeachyError('cannot_go', method === 'reload' ? 'Could not reload.' : 'There is no page to go ' + method + ' to.');
      }
      await sleep(150);
      return { went: method };
    }, { load: 15000 }));
  };
}

// ------------------------------------------------------------------- handlers

const handlers = {
  async ping() {
    return { ok: true, protocol: P.PROTOCOL_VERSION, browser: browserName(), jobs: jobs.size };
  },

  // open_tab(url, job, name?)            a new tab in the job's group
  // open_tab(borrow: "active" | tabId)   bring one of the person's tabs into the job
  async open_tab(params) {
    const job = jobFor(params);
    if (job.stopped) throw new TeachyError('user_stopped', 'The person stopped this job in the browser.');

    if (params.borrow !== undefined && params.borrow !== null && params.borrow !== false) {
      let target;
      if (params.borrow === 'active' || params.borrow === true) {
        const windowId = await pickWindow({ groupId: null });
        const found = windowId === null ? [] : await chrome.tabs.query({ active: true, windowId });
        target = found[0];
      } else {
        target = await chrome.tabs.get(Number(params.borrow)).catch(() => null);
      }
      if (!target) throw new TeachyError('no_such_tab', 'There is no such tab.');
      if (target.incognito) throw new TeachyError('incognito', 'Teachy does not work in Incognito windows.');
      if (!P.isAllowedURL(target.url || '')) throw new TeachyError('bad_url', 'Teachy only works on web pages (http and https).');
      if (tabs.has(target.id)) {
        const owner = tabs.get(target.id);
        if (owner.jobId !== job.id) throw new TeachyError('not_job_tab', 'Another job is using that tab.');
      } else {
        track(target.id, job, {
          opened: false,
          origin: { windowId: target.windowId, index: target.index, groupId: target.groupId, pinned: target.pinned }
        });
        await addToGroup(job, target.id, target.windowId);
      }
      await ensureAttached(target.id);
      const borrowed = await takeSnapshot(target.id).catch(() => null);
      return { tab: target.id, url: borrowed ? borrowed.url : target.url, title: borrowed ? borrowed.title : target.title, borrowed: true, loaded: true, group: job.name };
    }

    const url = typeof params.url === 'string' ? params.url.trim() : '';
    if (!P.isAllowedURL(url)) throw new TeachyError('bad_url', 'Teachy only opens web addresses that start with http:// or https://.');
    let windowId = await pickWindow(job);
    let created;
    if (windowId === null) {
      const fresh = await chrome.windows.create({ url, focused: false });
      windowId = fresh.id;
      created = fresh.tabs[0];
    } else {
      created = await chrome.tabs.create({ windowId, url, active: params.active === true });
    }
    if (created.incognito) {
      await chrome.tabs.remove(created.id).catch(() => {});
      throw new TeachyError('incognito', 'Teachy does not work in Incognito windows.');
    }
    track(created.id, job, { opened: true, origin: null });
    await addToGroup(job, created.id, windowId);
    const loaded = await waitForLoad(created.id, 15000);
    let page = null;
    try {
      await ensureAttached(created.id);
      await settle(created.id, 2500);
      page = await takeSnapshot(created.id);
    } catch (problem) {
      if (problem.code === 'debugger_failed') throw problem;
    }
    const info = await chrome.tabs.get(created.id).catch(() => created);
    return { tab: created.id, url: page ? page.url : info.url, title: page ? page.title : info.title, borrowed: false, loaded, group: job.name };
  },

  async list_tabs(params) {
    const job = typeof params.job === 'string' ? jobs.get(params.job) : null;
    if (!job) return { tabs: [] };
    const list = [];
    for (const [tabId, record] of job.tabs.entries()) {
      const info = await chrome.tabs.get(tabId).catch(() => null);
      if (!info) continue;
      list.push({ tab: tabId, url: info.url || '', title: info.title || '', opened: record.opened, borrowed: !record.opened, current: job.lastTabId === tabId });
    }
    return { tabs: list, group: job.name, stopped: job.stopped };
  },

  async close_tab(params) {
    const tabId = Number(params.tab);
    const tab = tabs.get(tabId);
    if (!tab) throw new TeachyError('not_job_tab', 'That tab does not belong to a Teachy job.');
    const job = jobs.get(tab.jobId);
    const record = job ? job.tabs.get(tabId) : null;
    await releaseTab(tabId, 'close');
    return { closed: !!(record && record.opened), returned: !!(record && !record.opened) };
  },

  async close_job(params) {
    const job = typeof params.job === 'string' ? jobs.get(params.job) : null;
    if (!job) return { closed: 0, kept: 0, returned: 0 };
    return closeJob(job, Array.isArray(params.keep) ? params.keep : []);
  },

  async read_page(params) {
    const { tabId } = requireTab(params);
    return queued(tabId, async () => {
      const page = await takeSnapshot(tabId, { text: true, maxChars: Number(params.max_chars) > 0 ? Number(params.max_chars) : 12000 });
      return {
        tab: tabId,
        url: page.url,
        title: page.title,
        text: page.text || '',
        outline: Snap.outline(page),
        count: page.elements.length,
        omitted: page.omitted,
        scroll: page.scroll,
        ready: page.readyState
      };
    });
  },

  // Facts for the app's permission question: what control is this, on which site. Changes nothing.
  async describe(params) {
    const { tabId } = requireTab(params);
    const info = await agentCall(tabId, 'describe', { index: params.index === undefined ? null : params.index });
    info.host = P.hostOf(info.url);
    info.tab = tabId;
    return info;
  },

  async click(params) {
    const { tabId, tab } = requireTab(params);
    const index = needIndex(params);
    return queued(tabId, () => act(tabId, async () => {
      const target = await agentCall(tabId, 'locate', { index });
      if (target.error) raise(target.error);
      if (target.isFileInput) {
        throw new TeachyError('needs_upload', 'Control [' + index + '] chooses a file. Use upload_file with the path of the file instead of clicking it.');
      }
      tab.acceptDialogs = params.accept_dialogs === true;
      let via = 'pointer';
      if (target.point && !target.obscured) {
        await showCursor(tabId, target.point);
        try {
          await withTimeout(mouseClick(tabId, target.point), 3000);
        } catch (problem) {
          via = 'dom';
        }
      } else {
        via = 'dom';
      }
      if (via === 'dom') {
        const clicked = await agentCall(tabId, 'domClick', { index });
        if (clicked.error) raise(clicked.error);
      }
      return { clicked: target.element ? target.element.line : '[' + index + ']', via };
    }));
  },

  async type(params) {
    const { tabId } = requireTab(params);
    const index = needIndex(params);
    if (typeof params.text !== 'string') throw new TeachyError('bad_params', 'text must be a string.');
    const text = params.text;
    const clear = params.clear !== false;
    return queued(tabId, () => act(tabId, async () => {
      const ready = await agentCall(tabId, 'prepareType', { index, clear });
      if (ready.needs_user) return { needs_user: ready.needs_user };
      if (ready.error) raise(ready.error);
      await showCursor(tabId, ready.point);

      let via = 'keyboard';
      try {
        if (text === '') {
          if (clear && ready.hadText) await withTimeout(dispatchKey(tabId, Keys.parse('Backspace')), 3000);
        } else {
          await withTimeout(cdp(tabId, 'Input.insertText', { text }), 4000);
        }
      } catch (problem) {
        via = 'dom';
      }
      const landed = via === 'keyboard' ? await agentCall(tabId, 'verifyTyped', { index, text }) : { ok: false };
      if (!landed.ok) {
        via = 'dom';
        const typed = await agentCall(tabId, 'domType', { index, text, clear });
        if (typed.needs_user) return { needs_user: typed.needs_user };
        if (typed.error) raise(typed.error);
      }
      let submitted = false;
      if (params.submit === true) {
        await pressKey(tabId, Keys.parse('Enter'));
        submitted = true;
      }
      return { typed: text.length, via, submitted };
    }));
  },

  async select(params) {
    const { tabId } = requireTab(params);
    const index = needIndex(params);
    if (typeof params.option !== 'string' && typeof params.option !== 'number') throw new TeachyError('bad_params', 'option must be the text of the option to pick.');
    return queued(tabId, () => act(tabId, async () => {
      const picked = await agentCall(tabId, 'select', { index, option: String(params.option) });
      if (picked.error) raise(picked.error);
      return { selected: picked.chosen };
    }));
  },

  async press_key(params) {
    const { tabId } = requireTab(params);
    const combo = Keys.parse(params.combo);
    if (combo.error) throw new TeachyError('bad_params', combo.error);
    if (combo.blocked) throw new TeachyError('not_allowed', combo.blocked);
    return queued(tabId, () => act(tabId, async () => {
      // Typing a private field one key at a time is still typing it.
      const focus = await agentCall(tabId, 'focusInfo', {});
      if (focus && focus.secret && combo.printable) return { needs_user: focus.secret };
      const via = await pressKey(tabId, combo);
      return { pressed: combo.label, via };
    }));
  },

  async scroll(params) {
    const { tabId } = requireTab(params);
    return queued(tabId, () => act(tabId, async () => {
      const moved = await agentCall(tabId, 'scroll', {
        direction: params.direction, index: params.index === undefined ? null : params.index, amount: params.amount
      });
      if (moved.error) raise(moved.error);
      return { scrolled: true, moved: moved.moved !== false, position: moved.y, at_end: moved.atEnd === true };
    }, { settle: 1500 }));
  },

  async navigate(params) {
    const { tabId } = requireTab(params);
    const url = typeof params.url === 'string' ? params.url.trim() : '';
    if (!P.isAllowedURL(url)) throw new TeachyError('bad_url', 'Teachy only opens web addresses that start with http:// or https://.');
    return queued(tabId, () => act(tabId, async () => {
      await chrome.tabs.update(tabId, { url });
      await sleep(150);
      return { navigated: url };
    }, { load: 15000 }));
  },

  back: historyStep('back'),
  forward: historyStep('forward'),
  reload: historyStep('reload'),

  // wait_for(tab, condition, timeout): condition is one of
  //   { load: "complete" | "interactive" } { text } { selector } { element } { url_contains }
  async wait_for(params) {
    const { tabId } = requireTab(params);
    const condition = params.condition && typeof params.condition === 'object' ? params.condition : null;
    if (!condition) throw new TeachyError('bad_params', 'condition must be an object, e.g. {"text": "Order placed"}.');
    const timeoutMs = Math.min(30000, Math.max(250, Number(params.timeout) > 0 ? Number(params.timeout) * 1000 : 10000));
    const started = Date.now();
    let last = null;
    while (true) {
      if (!tabs.has(tabId)) throw new TeachyError('tab_closed', 'The tab closed while waiting.');
      const job = jobs.get(tabs.get(tabId).jobId);
      if (job && job.stopped) throw new TeachyError('user_stopped', 'The person stopped this job in the browser.');
      try {
        last = await agentCall(tabId, 'check', condition);
      } catch (problem) {
        last = null; // mid-navigation: try again
      }
      if (last && last.error) raise(last.error);
      if (last && last.met) break;
      if (Date.now() - started >= timeoutMs) break;
      await sleep(250);
    }
    const info = await chrome.tabs.get(tabId).catch(() => null);
    return {
      tab: tabId, met: !!(last && last.met), waited_ms: Date.now() - started,
      url: info ? info.url : '', title: info ? info.title : '',
      found: last && last.line ? last.line : null
    };
  },

  // The debugger's Page.captureScreenshot rather than tabs.captureVisibleTab: it works for a tab
  // that is not the one in front, needs no extra permission, and never captures the browser's own UI.
  async screenshot(params) {
    const { tabId } = requireTab(params);
    return queued(tabId, async () => {
      const view = await agentCall(tabId, 'mask', { on: true });
      try {
        const widthInPixels = (view.width || 1280) * (view.scale || 1);
        const maxWidth = Number(params.max_width) > 0 ? Number(params.max_width) : 1400;
        const shrink = widthInPixels > maxWidth ? maxWidth / widthInPixels : 1;
        const request = { format: 'jpeg', quality: 70, captureBeyondViewport: false };
        if (shrink < 1 && view.width && view.height) {
          request.clip = { x: 0, y: 0, width: view.width, height: view.height, scale: shrink };
        }
        let shot;
        try {
          shot = await withTimeout(cdp(tabId, 'Page.captureScreenshot', request), 6000);
        } catch (stalled) {
          // A tab that is not showing may not paint. Bring it to the front of its own window and try once more.
          await chrome.tabs.update(tabId, { active: true }).catch(() => {});
          await sleep(300);
          shot = await withTimeout(cdp(tabId, 'Page.captureScreenshot', request), 6000, 'screenshot_failed', 'Chrome did not produce a picture of that tab.');
        }
        const info = await chrome.tabs.get(tabId).catch(() => null);
        return {
          tab: tabId, mime: 'image/jpeg', data: shot.data,
          width: Math.round((view.width || 0) * (view.scale || 1) * shrink),
          height: Math.round((view.height || 0) * (view.scale || 1) * shrink),
          url: info ? info.url : '', title: info ? info.title : '', hidden_fields: view.masked || 0
        };
      } finally {
        await agentCall(tabId, 'mask', { on: false }).catch(() => {});
      }
    });
  },

  // The app sends this only after the person said yes to sending that exact file.
  async grant_upload(params) {
    if (typeof params.token !== 'string' || params.token.length < 16 || typeof params.path !== 'string' || !params.path.startsWith('/')) {
      throw new TeachyError('bad_params', 'grant_upload needs a token and an absolute path.');
    }
    const seconds = Math.min(300, Math.max(5, Number(params.ttl) > 0 ? Number(params.ttl) : 120));
    for (const [token, grant] of uploadGrants) if (grant.expires < Date.now()) uploadGrants.delete(token);
    uploadGrants.set(params.token, { path: params.path, expires: Date.now() + seconds * 1000 });
    return { granted: true };
  },

  async upload_file(params) {
    const { tabId, tab } = requireTab(params);
    const path = typeof params.path === 'string' ? params.path : '';
    const grant = typeof params.consent_token === 'string' ? uploadGrants.get(params.consent_token) : null;
    if (!grant || grant.path !== path || grant.expires < Date.now()) {
      throw new TeachyError('upload_not_consented', 'No file leaves this Mac without the person saying yes to that exact file first.');
    }
    uploadGrants.delete(params.consent_token); // one use
    const hasIndex = params.index !== undefined && params.index !== null;
    const waiting = tab.fileChooser;
    return queued(tabId, () => act(tabId, async () => {
      const target = {};
      if (hasIndex) {
        const index = needIndex(params);
        const info = await agentCall(tabId, 'describe', { index });
        if (!info.found) raise({ code: 'no_such_element', message: 'There is no control [' + index + '] on this page now.' });
        if (!info.isFileInput) throw new TeachyError('not_a_file_input', 'Control [' + index + '] does not take a file.');
        const handle = await evaluate(tabId, 'globalThis.__teachyAgent.element(' + index + ')', false);
        if (!handle.objectId) throw new TeachyError('no_such_element', 'That control is gone.');
        target.objectId = handle.objectId;
      } else if (waiting && waiting.backendNodeId) {
        target.backendNodeId = waiting.backendNodeId;
      } else {
        throw new TeachyError('bad_params', 'Say which control takes the file (index), or click the page\'s upload button first.');
      }
      await cdp(tabId, 'DOM.setFileInputFiles', Object.assign({ files: [path] }, target));
      return { uploaded: path.split('/').pop() };
    }));
  }
};

// --------------------------------------------------------------------- events

chrome.debugger.onEvent.addListener((source, method, params) => {
  const tabId = source.tabId;
  const tab = tabs.get(tabId);
  if (!tab) return;

  if (method === 'Runtime.bindingCalled' && params.name === BINDING) {
    let payload = null;
    try { payload = JSON.parse(params.payload); } catch (ignored) { payload = null; }
    if (payload && payload.event === 'escape') stopJob(jobs.get(tab.jobId), 'escape');
    return;
  }

  if (method === 'Page.javascriptDialogOpening') {
    // alert / leaving the page: OK. A question: Cancel, unless this click was told to accept.
    const accept = params.type === 'alert' || params.type === 'beforeunload' || tab.acceptDialogs === true;
    tab.dialogs.push({ type: params.type, message: params.message || '', accepted: accept });
    cdp(tabId, 'Page.handleJavaScriptDialog', { accept }).catch(() => {});
    return;
  }

  if (method === 'Page.fileChooserOpened') {
    tab.fileChooser = { backendNodeId: params.backendNodeId || null, mode: params.mode };
    return;
  }
});

chrome.debugger.onDetach.addListener((source, reason) => {
  const tab = tabs.get(source.tabId);
  if (!tab) return;
  tab.attached = false;
  tab.contextId = null;
  // The person pressed Cancel on Chrome's "is debugging this browser" bar: that stops the job too.
  if (reason === 'canceled_by_user') stopJob(jobs.get(tab.jobId), 'debugger_bar');
});

chrome.tabs.onRemoved.addListener((tabId) => {
  const tab = tabs.get(tabId);
  if (!tab) return;
  const job = jobs.get(tab.jobId);
  tabs.delete(tabId);
  if (job) {
    job.tabs.delete(tabId);
    if (job.lastTabId === tabId) job.lastTabId = job.tabs.size ? Array.from(job.tabs.keys()).pop() : null;
    send(P.event('tab_closed', { job: job.id, tab: tabId }));
  }
});

// A page in a job opened another tab (a link with target=_blank): it joins the job.
// Chrome names the opener for most of these. For the rest we go by the group: Chrome puts a tab
// opened from a grouped tab into the same group, so a brand-new tab that lands in a job's group
// right after that job acted is the job's.
const recentlyCreated = new Map();

function adoptIfOpenedByJob(info) {
  if (!info || tabs.has(info.id) || info.incognito) return;
  let job = null;
  let source = null;
  if (info.openerTabId !== undefined && tabs.has(info.openerTabId)) {
    source = tabs.get(info.openerTabId);
    job = jobs.get(source.jobId);
  } else if (info.groupId !== undefined && info.groupId !== -1 && Date.now() - (recentlyCreated.get(info.id) || 0) < 3000) {
    for (const candidate of jobs.values()) {
      if (candidate.groupId === info.groupId && Date.now() < candidate.expectNewTabUntil) job = candidate;
    }
    source = job ? tabs.get(job.actingTabId) : null;
  }
  if (!job || job.stopped) return;
  const current = job.lastTabId;
  track(info.id, job, { opened: true, origin: null });
  job.lastTabId = current;
  if (source) source.newTabs.push(info.id);
  addToGroup(job, info.id, info.windowId).catch(() => {});
}

chrome.tabs.onCreated.addListener((created) => {
  wake();
  recentlyCreated.set(created.id, Date.now());
  for (const [id, at] of recentlyCreated) if (Date.now() - at > 10000) recentlyCreated.delete(id);
  adoptIfOpenedByJob(created);
});

chrome.tabs.onUpdated.addListener((tabId, change, info) => {
  if (change.groupId !== undefined) adoptIfOpenedByJob(info);
});

chrome.tabs.onActivated.addListener(() => { wake(); });

// Clicking the toolbar icon while a job runs stops it; otherwise it looks for the app again.
chrome.action.onClicked.addListener(() => {
  const active = Array.from(jobs.values()).filter((job) => !job.stopped);
  if (active.length) {
    for (const job of active) stopJob(job, 'toolbar');
    return;
  }
  lastWakeAttempt = 0;
  wake();
});

chrome.runtime.onStartup.addListener(() => { connect(); });
chrome.runtime.onInstalled.addListener(() => { connect(); });

updateBadge();
connect();
