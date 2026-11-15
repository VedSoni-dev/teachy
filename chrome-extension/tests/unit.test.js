// Unit tests for the extension's pure modules. No browser needed:
//   node --test chrome-extension/tests/unit.test.js
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const Protocol = require('../lib/protocol.js');
const Secrets = require('../lib/secrets.js');
const Snapshot = require('../lib/snapshot.js');
const Readable = require('../lib/readable.js');
const Keys = require('../lib/keys.js');
const dom = require('./support/mini-dom.js');

const fixture = (name) => fs.readFileSync(path.join(__dirname, 'fixtures', name), 'utf8');

// ------------------------------------------------------------------- framing

test('framing: a message survives encode and decode', () => {
  const message = { type: 'request', id: '1', method: 'ping', params: { note: 'héllo ☕' } };
  const decoder = new Protocol.FrameDecoder();
  const out = decoder.push(Protocol.encodeFrame(message));
  assert.deepEqual(out, [{ message }]);
  assert.equal(decoder.pendingBytes(), 0);
});

test('framing: the length prefix is 4 bytes, little-endian, counting UTF-8 bytes', () => {
  const frame = Protocol.encodeFrame({ a: 'é' });
  const body = Buffer.from(JSON.stringify({ a: 'é' }), 'utf8');
  assert.equal(frame.length, 4 + body.length);
  assert.deepEqual(Array.from(frame.slice(0, 4)), [body.length, 0, 0, 0]);
});

test('framing: messages split across chunks, and several in one chunk', () => {
  const first = Protocol.encodeFrame({ n: 1 });
  const second = Protocol.encodeFrame({ n: 2, text: 'x'.repeat(5000) });
  const third = Protocol.encodeFrame({ n: 3 });
  const all = Buffer.concat([first, second, third]);
  const decoder = new Protocol.FrameDecoder();
  const seen = [];
  for (let offset = 0; offset < all.length; offset += 7) {
    for (const item of decoder.push(all.subarray(offset, Math.min(all.length, offset + 7)))) seen.push(item.message.n);
  }
  assert.deepEqual(seen, [1, 2, 3]);

  const together = new Protocol.FrameDecoder().push(all);
  assert.deepEqual(together.map((item) => item.message.n), [1, 2, 3]);
});

test('framing: a frame that is not JSON is reported and the stream carries on', () => {
  const junk = Buffer.from('this is not json');
  const header = Buffer.alloc(4);
  header.writeUInt32LE(junk.length, 0);
  const decoder = new Protocol.FrameDecoder();
  const out = decoder.push(Buffer.concat([header, junk, Buffer.from(Protocol.encodeFrame({ ok: true }))]));
  assert.deepEqual(out, [{ error: 'malformed_frame' }, { message: { ok: true } }]);
});

test('framing: a JSON value that is not an object is malformed', () => {
  const body = Buffer.from('[1,2,3]');
  const header = Buffer.alloc(4);
  header.writeUInt32LE(body.length, 0);
  assert.deepEqual(new Protocol.FrameDecoder().push(Buffer.concat([header, body])), [{ error: 'malformed_frame' }]);
});

test('framing: an absurd length stops the stream', () => {
  const header = Buffer.alloc(4);
  header.writeUInt32LE(0x7fffffff, 0);
  assert.throws(() => new Protocol.FrameDecoder().push(header), (problem) => problem.code === 'frame_too_large');
});

test('protocol: requests are validated', () => {
  assert.equal(Protocol.validateRequest({ type: 'request', id: '1', method: 'click', params: { tab: 1 } }).ok, true);
  assert.equal(Protocol.validateRequest({ type: 'request', id: 2, method: 'ping' }).request.params.constructor, Object);
  assert.equal(Protocol.validateRequest({ type: 'request', id: '1', method: 'eval' }).code, 'unknown_method');
  assert.equal(Protocol.validateRequest({ type: 'request', method: 'ping' }).code, 'bad_request');
  assert.equal(Protocol.validateRequest({ type: 'request', id: '1', method: 'ping', params: [1] }).code, 'bad_params');
  assert.equal(Protocol.validateRequest('ping').code, 'bad_request');
  assert.equal(Protocol.validateRequest({ type: 'request', id: '1', method: 'constructor' }).code, 'unknown_method');
});

test('protocol: only web addresses may be opened', () => {
  for (const good of ['https://example.com', 'http://127.0.0.1:8080/a?b=c', 'HTTPS://Example.com/x', 'about:blank']) {
    assert.equal(Protocol.isAllowedURL(good), true, good);
  }
  for (const bad of ['javascript:alert(1)', 'file:///etc/passwd', 'chrome://settings', 'data:text/html,hi', 'example.com', '', null, 'https://', ' javascript:1', 'view-source:https://a.com', 'chrome-extension://abc/x.html']) {
    assert.equal(Protocol.isAllowedURL(bad), false, String(bad));
  }
  assert.equal(Protocol.hostOf('https://user:pw@Shop.Example.com:8443/x'), 'shop.example.com');
  assert.equal(Protocol.hostOf('nonsense'), '');
});

test('protocol: responses and errors have the documented shape', () => {
  assert.deepEqual(Protocol.response('7', { a: 1 }), { type: 'response', id: '7', ok: true, result: { a: 1 } });
  assert.deepEqual(Protocol.errorResponse('7', 'no_such_element', 'gone'), {
    type: 'response', id: '7', ok: false, error: { code: 'no_such_element', message: 'gone' }
  });
  assert.deepEqual(Protocol.event('user_stopped', { job: 'j', reason: 'escape' }), { type: 'event', event: 'user_stopped', job: 'j', reason: 'escape' });
});

// ------------------------------------------------------------------- secrets

test('secrets: passwords', () => {
  const kind = (d) => (Secrets.classifyField(d) || {}).kind || null;
  assert.equal(kind({ tag: 'input', type: 'password' }), 'password');
  assert.equal(kind({ tag: 'input', type: 'text', autocomplete: 'current-password' }), 'password');
  assert.equal(kind({ tag: 'input', type: 'text', autocomplete: 'section-a new-password' }), 'password');
  // "Show password" turns the field into type=text; it is still a password.
  assert.equal(kind({ tag: 'input', type: 'text', name: 'user_password' }), 'password');
  assert.equal(kind({ tag: 'input', type: 'text', id: 'loginPwd' }), 'password');
  assert.equal(kind({ tag: 'input', type: 'text', label: 'Passphrase' }), 'password');
});

test('secrets: one-time codes', () => {
  const kind = (d) => (Secrets.classifyField(d) || {}).kind || null;
  assert.equal(kind({ tag: 'input', type: 'text', autocomplete: 'one-time-code' }), 'one_time_code');
  assert.equal(kind({ tag: 'input', type: 'tel', name: 'otp' }), 'one_time_code');
  assert.equal(kind({ tag: 'input', type: 'text', label: 'Verification code' }), 'one_time_code');
  assert.equal(kind({ tag: 'input', type: 'text', placeholder: 'Enter the 6-digit code' }), 'one_time_code');
  assert.equal(kind({ tag: 'input', type: 'text', id: 'twoFactorToken', label: 'Two-factor token' }), 'one_time_code');
  assert.equal(kind({ tag: 'input', type: 'text', name: 'mfa_code' }), 'one_time_code');
  assert.equal(kind({ tag: 'input', type: 'text', maxLength: '1', inputMode: 'numeric', ariaLabel: 'Digit 1 of code' }), 'one_time_code');
  assert.equal(kind({ tag: 'input', type: 'text', label: 'Security code' }), 'one_time_code');
});

test('secrets: payment cards and bank details', () => {
  const kind = (d) => (Secrets.classifyField(d) || {}).kind || null;
  assert.equal(kind({ tag: 'input', type: 'text', autocomplete: 'cc-number' }), 'payment');
  assert.equal(kind({ tag: 'input', type: 'text', autocomplete: 'billing cc-exp' }), 'payment');
  assert.equal(kind({ tag: 'input', type: 'text', autocomplete: 'cc-name' }), 'payment');
  assert.equal(kind({ tag: 'input', type: 'tel', name: 'cardnumber' }), 'payment');
  assert.equal(kind({ tag: 'input', type: 'text', id: 'creditCardNumber' }), 'payment');
  assert.equal(kind({ tag: 'input', type: 'text', name: 'cvv' }), 'payment');
  assert.equal(kind({ tag: 'input', type: 'text', label: 'CVC' }), 'payment');
  assert.equal(kind({ tag: 'input', type: 'text', placeholder: 'Card security code' }), 'payment');
  assert.equal(kind({ tag: 'input', type: 'text', label: 'Expiry date' }), 'payment');
  assert.equal(kind({ tag: 'input', type: 'text', name: 'exp-month' }), 'payment');
  assert.equal(kind({ tag: 'input', type: 'text', label: 'IBAN' }), 'payment');
  assert.equal(kind({ tag: 'input', type: 'text', label: 'Routing number' }), 'payment');
});

test('secrets: ordinary fields are left alone', () => {
  const ordinary = [
    { tag: 'input', type: 'email', name: 'email', label: 'Email' },
    { tag: 'input', type: 'text', name: 'q', placeholder: 'Search' },
    { tag: 'input', type: 'text', name: 'first_name', label: 'First name' },
    { tag: 'textarea', name: 'notes', label: 'Notes' },
    { tag: 'input', type: 'text', name: 'postcode', label: 'Postcode' },
    { tag: 'input', type: 'text', name: 'promo_code', label: 'Promo code' },
    { tag: 'input', type: 'text', name: 'passenger_name', label: 'Passenger name' },
    { tag: 'input', type: 'text', label: 'Company' },
    { tag: 'input', type: 'number', name: 'quantity' },
    { tag: 'input', type: 'text', name: 'cid', label: 'Customer id' },
    { tag: 'input', type: 'text', name: 'discount', label: 'Gift card' },
    { tag: 'input', type: 'checkbox', name: 'remember_password' },
    { tag: 'button', type: 'submit', name: 'password' },
    { tag: 'select', name: 'card_type' },
    { tag: 'input', type: 'hidden', name: 'password' }
  ];
  for (const d of ordinary) assert.equal(Secrets.classifyField(d), null, JSON.stringify(d));
});

test('secrets: the field is named for the person without its value', () => {
  assert.equal(Secrets.fieldLabel({ label: 'Card number', name: 'cc' }), 'Card number');
  assert.equal(Secrets.fieldLabel({ name: 'user_password' }), 'user password');
  assert.equal(Secrets.describeKind('one_time_code'), 'verification code');
});

// ---------------------------------------------------------- element indexing

// Builds descriptors from a parsed fixture, the way the page agent does from the live DOM
// (minus what needs a real browser: layout, computed style, shadow roots).
function descriptorsFrom(document) {
  const labelFor = {};
  for (const label of dom.findAll(document, (n) => n.tagName === 'LABEL')) {
    const target = label.getAttribute('for');
    if (target) labelFor[target] = dom.textOf(label).replace(/\s+/g, ' ').trim();
  }
  const interesting = dom.findAll(document, (n) => {
    const tag = n.tagName.toLowerCase();
    if (n.hasAttribute('disabled') || (n.getAttribute('class') || '').includes('gone')) return false;
    if (tag === 'a') return n.hasAttribute('href');
    if (tag === 'input') return n.getAttribute('type') !== 'hidden';
    return tag === 'button' || tag === 'select' || tag === 'textarea' || (n.getAttribute('class') || '').includes('card-like');
  });
  let next = 1;
  return interesting.map((n) => {
    const tag = n.tagName.toLowerCase();
    const identity = {
      tag, type: tag === 'input' ? (n.getAttribute('type') || 'text') : '', autocomplete: n.getAttribute('autocomplete') || '',
      name: n.getAttribute('name') || '', id: n.getAttribute('id') || '', placeholder: n.getAttribute('placeholder') || '',
      ariaLabel: n.getAttribute('aria-label') || '', label: labelFor[n.getAttribute('id')] || '',
      maxLength: n.getAttribute('maxlength') || '', inputMode: n.getAttribute('inputmode') || ''
    };
    const secret = Secrets.classifyField(identity);
    const descriptor = Object.assign({}, identity, {
      index: next++, role: n.getAttribute('role') || '', title: n.getAttribute('title') || '', alt: '',
      text: tag === 'input' || tag === 'select' || tag === 'textarea' ? '' : dom.textOf(n),
      secret: secret ? { kind: secret.kind } : null, inViewport: true
    });
    if ((tag === 'input' || tag === 'textarea') && !secret && identity.type !== 'checkbox' && identity.type !== 'file') {
      descriptor.value = n.getAttribute('value') || '';
    }
    if (identity.type === 'checkbox') descriptor.checked = n.hasAttribute('checked');
    return descriptor;
  });
}

test('indexing: the shop fixture becomes numbered, readable lines', () => {
  const snapshot = Snapshot.build(descriptorsFrom(dom.parse(fixture('shop.html'))));
  const outline = Snapshot.outline(snapshot);
  const lines = outline.split('\n');

  assert.ok(lines.includes('[3] button "Add to cart"'), outline);
  assert.ok(lines.some((line) => /^\[\d+\] link "Journal"$/.test(line)), outline);
  assert.ok(lines.some((line) => /^\[\d+\] textbox "Email" value=""$/.test(line)), outline);
  assert.ok(lines.some((line) => /^\[\d+\] combobox "quantity"/.test(line)), outline);
  assert.ok(lines.some((line) => /^\[\d+\] checkbox "gift" unchecked$/.test(line)), outline);
  assert.ok(lines.some((line) => /^\[\d+\] button "Place order"$/.test(line)), outline);
  assert.ok(lines.some((line) => /^\[\d+\] clickable "See details"$/.test(line)), outline);
  assert.ok(lines.some((line) => /^\[\d+\] file input "Photo"/.test(line)), outline);

  // Hidden and disabled controls are not offered.
  assert.ok(!outline.includes('You cannot see me'));
  assert.ok(!outline.includes('Sold out'));

  // Numbers are unique and in page order.
  const numbers = snapshot.elements.map((e) => e.index);
  assert.deepEqual(numbers, [...numbers].sort((a, b) => a - b));
  assert.equal(new Set(numbers).size, numbers.length);
});

test('indexing: private fields are listed without their values', () => {
  const outline = Snapshot.outline(Snapshot.build(descriptorsFrom(dom.parse(fixture('shop.html')))));
  assert.match(outline, /\[\d+\] textbox "Password" \(password: the person types this\)/);
  assert.match(outline, /\[\d+\] textbox "Verification code" \(verification code: the person types this\)/);
  assert.match(outline, /\[\d+\] textbox "Card number" \(card or bank details: the person types this\)/);
  for (const secret of ['hunter2', '424242', '4111']) assert.ok(!outline.includes(secret), secret);
});

test('indexing: roles and names', () => {
  const line = (d) => Snapshot.describe(Object.assign({ index: 1 }, d)).line;
  assert.equal(line({ tag: 'a', text: '  Read\n more ' }), '[1] link "Read more"');
  assert.equal(line({ tag: 'input', type: 'submit', value: 'Send' }), '[1] button "Send"');
  assert.equal(line({ tag: 'input', type: 'submit' }), '[1] button "Submit"');
  assert.equal(line({ tag: 'input', type: 'search', placeholder: 'Search products', value: 'kettle' }), '[1] searchbox "Search products" value="kettle"');
  assert.equal(line({ tag: 'div', role: 'button', ariaLabel: 'Close', text: '×' }), '[1] button "Close"');
  assert.equal(line({ tag: 'div', role: 'tab', text: 'Reviews', selected: true }), '[1] tab "Reviews" selected');
  assert.equal(line({ tag: 'input', type: 'radio', label: 'Express', checked: true }), '[1] radio "Express" checked');
  assert.equal(line({ tag: 'select', label: 'Country', value: 'France' }), '[1] combobox "Country" value="France"');
  assert.equal(line({ tag: 'button', text: 'Menu', expanded: false }), '[1] button "Menu" collapsed');
  assert.equal(line({ tag: 'div', contentEditable: true, ariaLabel: 'Message', value: 'hi' }), '[1] textbox "Message" value="hi"');
  assert.equal(line({ tag: 'button', text: 'Say "hi"' }), '[1] button "Say \'hi\'"');
  assert.equal(line({ tag: 'button', text: 'Later', inViewport: false }), '[1] button "Later" (off screen)');
  assert.equal(line({ tag: 'button', labelledBy: 'Delete draft', ariaLabel: 'x', text: 'y' }), '[1] button "Delete draft"');
  assert.ok(line({ tag: 'button', text: 'x'.repeat(300) }).length < 100);
});

test('indexing: the list is capped, keeping what is on screen', () => {
  const descriptors = [];
  for (let i = 1; i <= 500; i++) descriptors.push({ index: i, tag: 'button', text: 'Button ' + i, inViewport: i > 400 });
  const snapshot = Snapshot.build(descriptors, { cap: 300 });
  assert.equal(snapshot.elements.length, 300);
  assert.equal(snapshot.omitted, 200);
  const kept = new Set(snapshot.elements.map((e) => e.index));
  for (let i = 401; i <= 500; i++) assert.ok(kept.has(i), 'on-screen control ' + i + ' was dropped');
  assert.match(Snapshot.outline(snapshot), /200 more controls not listed/);
  assert.equal(Snapshot.build(descriptors.slice(0, 10)).omitted, 0);
});

test('diff: what an action changed', () => {
  const before = {
    documentId: 'a', url: 'https://shop.test/', title: 'Shop', focusedIndex: null,
    elements: Snapshot.build([
      { index: 1, tag: 'button', text: 'Add to cart' },
      { index: 2, tag: 'input', type: 'text', label: 'Email', value: '' },
      { index: 3, tag: 'button', text: 'Old banner' },
      { index: 4, tag: 'input', type: 'checkbox', label: 'Gift wrap', checked: false }
    ]).elements
  };
  const after = {
    documentId: 'a', url: 'https://shop.test/#cart', title: 'Shop', focusedIndex: 2,
    elements: Snapshot.build([
      { index: 1, tag: 'button', text: 'Add to cart' },
      { index: 2, tag: 'input', type: 'text', label: 'Email', value: 'ada@example.com' },
      { index: 4, tag: 'input', type: 'checkbox', label: 'Gift wrap', checked: true },
      { index: 5, tag: 'button', text: 'Go to checkout' }
    ]).elements
  };
  const change = Snapshot.diff(before, after);
  assert.equal(change.urlChanged, true);
  assert.equal(change.titleChanged, false);
  assert.equal(change.newPage, false);
  assert.deepEqual(change.appeared, ['[5] button "Go to checkout"']);
  assert.deepEqual(change.disappeared, ['[3] button "Old banner"']);
  assert.deepEqual(change.changed, ['[2] textbox "Email" value="ada@example.com"', '[4] checkbox "Gift wrap" checked']);
  assert.equal(change.focused, '[2] textbox "Email" value="ada@example.com"');
  assert.match(change.text, /Address is now https:\/\/shop\.test\/#cart/);
  assert.match(change.text, /Appeared:\n  \[5\] button "Go to checkout"/);
  assert.match(change.text, /Gone:\n  \[3\] button "Old banner"/);
  assert.match(change.text, /Focus is on \[2\]/);
});

test('diff: nothing changed, and a whole new page', () => {
  const page = { documentId: 'a', url: 'u', title: 't', focusedIndex: null, elements: Snapshot.build([{ index: 1, tag: 'button', text: 'Go' }]).elements };
  assert.equal(Snapshot.diff(page, page).text, 'Nothing changed on the page.');

  const next = { documentId: 'b', url: 'https://x.test/thanks', title: 'Thanks', focusedIndex: null, elements: Snapshot.build([{ index: 101, tag: 'a', text: 'Back' }]).elements };
  const change = Snapshot.diff(page, next);
  assert.equal(change.newPage, true);
  assert.match(change.text, /A new page loaded: "Thanks" https:\/\/x\.test\/thanks/);
  assert.match(change.text, /\[101\] link "Back"/);
});

test('diff: long lists are cut short', () => {
  const many = [];
  for (let i = 1; i <= 40; i++) many.push({ index: i, tag: 'button', text: 'B' + i });
  const change = Snapshot.diff({ documentId: 'a', elements: [] }, { documentId: 'a', elements: Snapshot.build(many).elements });
  assert.equal(change.appeared.length, 40);
  assert.match(change.text, /\(28 more\)/);
});

// ------------------------------------------------------------- readable text

test('readable: the article, without the site around it', () => {
  const document = dom.parse(fixture('article.html'));
  const body = dom.find(document, (n) => n.tagName === 'BODY');
  const result = Readable.extract(body, { isHidden: (n) => (n.getAttribute('class') || '') === 'sr' });

  assert.equal(result.source, 'article');
  assert.match(result.text, /^# How kettles whistle\n/);
  assert.match(result.text, /By Ada Fixture/);
  assert.match(result.text, /steam is forced through two small holes/);
  assert.match(result.text, /## What you can try at home/);
  assert.match(result.text, /- Fill the kettle half way/);
  assert.match(result.text, /Read more in our shop notes/);
  assert.match(result.text, /\[image: diagram of a spout cap\]/);
  assert.match(result.text, /Fill \| Note/);
  assert.match(result.text, /Published 3 March\./);

  for (const unwanted of ['Accept all cookies', 'Most read', 'Ten teapots', 'About us', 'Terms', 'Copyright', 'tracking', 'never be read', 'Hidden paragraph', 'Screen-reader only', 'display: none']) {
    assert.ok(!result.text.includes(unwanted), 'should not contain: ' + unwanted + '\n' + result.text);
  }
});

test('readable: <main> wins, and form controls are left to the element list', () => {
  const document = dom.parse(fixture('shop.html'));
  const body = dom.find(document, (n) => n.tagName === 'BODY');
  const result = Readable.extract(body, { isHidden: (n) => (n.getAttribute('class') || '').includes('gone') });
  assert.equal(result.source, 'main');
  assert.match(result.text, /# Blue Kettle/);
  assert.match(result.text, /pours without dripping/);
  assert.ok(!result.text.includes('Fixture Shop Ltd.'));
  assert.ok(!result.text.includes('customElements'));
  assert.ok(!result.text.includes('hunter2'));
  assert.ok(!result.text.includes('4111'));
});

test('readable: a page with no clear article still gives its text', () => {
  const document = dom.parse('<body><nav><a href="/a">Home</a></nav><div><p>Short note.</p></div><footer>Bye</footer></body>');
  const result = Readable.extract(dom.find(document, (n) => n.tagName === 'BODY'));
  assert.equal(result.text, 'Home\n\nShort note.\n\nBye');
});

test('readable: long pages are cut with a note', () => {
  const paragraphs = [];
  for (let i = 0; i < 400; i++) paragraphs.push('<p>Paragraph ' + i + ' has several plain words in it to make it long enough.</p>');
  const document = dom.parse('<body><main>' + paragraphs.join('') + '</main></body>');
  const result = Readable.extract(dom.find(document, (n) => n.tagName === 'BODY'), { maxChars: 2000 });
  assert.ok(result.truncated > 0);
  assert.ok(result.text.length < 2200);
  assert.match(result.text, /more characters; scroll and read again/);
});

test('readable: custom child lookup is honoured (shadow roots, iframes)', () => {
  const document = dom.parse('<body><main><p>Outside text that is long enough to count as the content of this page for sure.</p><x-box></x-box></main></body>');
  const shadow = dom.parse('<p>Inside the shadow root.</p>');
  const result = Readable.extract(dom.find(document, (n) => n.tagName === 'BODY'), {
    childrenOf: (node) => (node.tagName === 'X-BOX' ? shadow.childNodes : node.childNodes)
  });
  assert.match(result.text, /Inside the shadow root\./);
});

// ---------------------------------------------------------------------- keys

test('keys: names, letters and shortcuts', () => {
  assert.deepEqual(pick(Keys.parse('Enter')), { key: 'Enter', code: 'Enter', keyCode: 13, modifiers: 0, text: '\r', printable: false });
  assert.deepEqual(pick(Keys.parse('a')), { key: 'a', code: 'KeyA', keyCode: 65, modifiers: 0, text: 'a', printable: true });
  assert.deepEqual(pick(Keys.parse('A')), { key: 'A', code: 'KeyA', keyCode: 65, modifiers: Keys.SHIFT, text: 'A', printable: true });
  assert.deepEqual(pick(Keys.parse('shift+tab')), { key: 'Tab', code: 'Tab', keyCode: 9, modifiers: Keys.SHIFT, text: '', printable: false });
  assert.deepEqual(pick(Keys.parse('7')), { key: '7', code: 'Digit7', keyCode: 55, modifiers: 0, text: '7', printable: true });
  assert.equal(Keys.parse('cmd+a').commands[0], 'selectAll');
  assert.equal(Keys.parse('cmd+a').printable, false);
  assert.equal(Keys.parse('Cmd+Shift+Z').commands[0], 'redo');
  assert.equal(Keys.parse('escape').key, 'Escape');
  assert.equal(Keys.parse('ArrowDown').keyCode, 40);
  assert.equal(Keys.parse('F5').keyCode, 116);
  assert.equal(Keys.parse('space').printable, true);
  assert.equal(Keys.parse('ctrl+alt+shift+cmd+k').label, 'ctrl+alt+shift+cmd+K');
  assert.equal(Keys.parse('+').key, '+');
  assert.equal(Keys.parse('shift++').key, '+');
});

test('keys: mistakes and the paste rule', () => {
  assert.ok(Keys.parse('').error);
  assert.ok(Keys.parse('hyper+k').error);
  assert.ok(Keys.parse('cmd+banana').error);
  assert.ok(Keys.parse('cmd+v').blocked);
  assert.ok(Keys.parse('ctrl+V').blocked);
  assert.equal(Keys.parse('v').blocked, undefined);
});

function pick(parsed) {
  return { key: parsed.key, code: parsed.code, keyCode: parsed.keyCode, modifiers: parsed.modifiers, text: parsed.text, printable: parsed.printable };
}
