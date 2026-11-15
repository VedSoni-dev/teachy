// Which fields belong to the person and never to the agent.
//
// classifyField(descriptor) -> null, or
//   { kind: 'password' | 'one_time_code' | 'payment', why: '...' }
//
// The descriptor is a plain object built from the element's attributes and
// label (never its value):
//   { tag, type, autocomplete, name, id, placeholder, ariaLabel, label,
//     maxLength, inputMode, pattern, contentEditable }
//
// The extension refuses to type into these, never reads their value, and
// blurs them in screenshots. This is enforced here, in code, not by asking the
// model nicely. Pure: no DOM.
(function (root) {
  'use strict';

  var NEVER_TEXT_TYPES = {
    hidden: 1, submit: 1, button: 1, reset: 1, image: 1, checkbox: 1, radio: 1,
    file: 1, range: 1, color: 1, date: 1, 'datetime-local': 1, time: 1, week: 1
  };

  function lower(value) {
    return value === undefined || value === null ? '' : String(value).toLowerCase();
  }

  // "cardNumber" / "card_number" / "card-number" -> "card number"
  function words(value) {
    return String(value === undefined || value === null ? '' : value)
      .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
      .toLowerCase()
      .replace(/[_\-.:\[\]/]+/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();
  }

  var PASSWORD_WORDS = /\b(password|passwd|pass word|passphrase|pwd|current pass|new pass)\b/;

  var CARD_WORDS = new RegExp('\\b(' + [
    'card ?number', 'card ?no', 'cardnum', 'cc ?num(ber)?', 'ccn', 'credit ?card', 'debit ?card',
    'card ?holder', 'name on (the )?card', 'cvv2?', 'cvc2?', 'csc', 'card ?(security|verification) ?(code|value|number)?',
    'security code', 'card ?expir\\w*', 'expir(y|ation) ?(date|month|year|mm|yy)?', 'exp ?(date|month|year|mm|yy)',
    'cc ?exp\\w*', 'cc ?(name|csc|cvc|cvv|type|month|year)', 'card ?pin',
    'iban', 'routing ?(number|no)', 'sort ?code', 'bank ?account( ?(number|no))?', 'swift ?code'
  ].join('|') + ')\\b');

  var CODE_WORDS = new RegExp('\\b(' + [
    'otp', 'totp', 'one ?time ?(code|pass\\w*|pin)?', '2fa', 'two ?factor', 'mfa', 'multi ?factor',
    '(verification|verify|security|auth\\w*|login|sign ?in|sms|text|email|confirmation|access|backup|recovery) ?(code|pin)',
    'pass ?code', 'code from (your )?(app|phone|email|sms|text)', 'authenticator', '\\d ?digit code'
  ].join('|') + ')\\b');

  function classifyField(descriptor) {
    if (!descriptor) return null;
    var tag = lower(descriptor.tag);
    var type = lower(descriptor.type);
    var isTextEntry = tag === 'textarea' || (tag === 'input' && !NEVER_TEXT_TYPES[type]) || descriptor.contentEditable === true;
    if (!isTextEntry) return null;

    var autocomplete = lower(descriptor.autocomplete).split(/\s+/).filter(Boolean);
    function hasToken(test) {
      for (var i = 0; i < autocomplete.length; i++) if (test(autocomplete[i])) return true;
      return false;
    }

    // What the page itself calls the field. Identifiers first (they survive translation), then visible words.
    var identity = words([descriptor.name, descriptor.id].join(' '));
    var visible = words([descriptor.label, descriptor.ariaLabel, descriptor.placeholder].join(' '));
    var everything = (identity + ' ' + visible).trim();

    // 1. Passwords.
    if (type === 'password') return { kind: 'password', why: 'password field' };
    if (hasToken(function (t) { return t === 'current-password' || t === 'new-password'; })) {
      return { kind: 'password', why: 'autocomplete says password' };
    }

    // 2. Payment cards and bank details (before codes: "security code" on a card form is the CVV).
    if (hasToken(function (t) { return t.indexOf('cc-') === 0; })) {
      return { kind: 'payment', why: 'autocomplete says payment card' };
    }
    if (CARD_WORDS.test(everything)) {
      var cardMatch = CARD_WORDS.exec(everything)[0];
      var onlySecurityCode = /^security code$/.test(cardMatch);
      // "Security code" alone, on a field with no other card hint, is more likely a sign-in code.
      if (!onlySecurityCode) return { kind: 'payment', why: 'the field is called "' + cardMatch + '"' };
    }

    // 3. One-time codes.
    if (hasToken(function (t) { return t === 'one-time-code'; })) {
      return { kind: 'one_time_code', why: 'autocomplete says one-time code' };
    }
    if (CODE_WORDS.test(everything)) {
      return { kind: 'one_time_code', why: 'the field is called "' + CODE_WORDS.exec(everything)[0] + '"' };
    }
    // Split code boxes: one digit each, numeric, named like a code.
    var maxLength = Number(descriptor.maxLength);
    var numeric = lower(descriptor.inputMode) === 'numeric' || type === 'tel' || type === 'number' || /\\d|\[0-9\]/.test(String(descriptor.pattern || ''));
    if (maxLength === 1 && numeric && /\b(code|digit|pin|otp)\b/.test(everything)) {
      return { kind: 'one_time_code', why: 'single-digit code box' };
    }

    // 4. A password field the page has switched to plain text ("show password").
    if (PASSWORD_WORDS.test(everything) && !/\b(hint|search|strength)\b/.test(everything)) {
      return { kind: 'password', why: 'the field is called "' + PASSWORD_WORDS.exec(everything)[0] + '"' };
    }

    return null;
  }

  function describeKind(kind) {
    if (kind === 'password') return 'password';
    if (kind === 'one_time_code') return 'verification code';
    if (kind === 'payment') return 'card or bank details';
    return 'private';
  }

  // The name to show the person: "Password", "Card number".
  function fieldLabel(descriptor) {
    var candidates = [descriptor.label, descriptor.ariaLabel, descriptor.placeholder, words(descriptor.name), words(descriptor.id)];
    for (var i = 0; i < candidates.length; i++) {
      var text = String(candidates[i] === undefined || candidates[i] === null ? '' : candidates[i]).replace(/\s+/g, ' ').trim();
      if (text) return text.length > 60 ? text.slice(0, 60) + '…' : text;
    }
    return '';
  }

  var api = { classifyField: classifyField, describeKind: describeKind, fieldLabel: fieldLabel, words: words };
  root.TeachySecrets = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
