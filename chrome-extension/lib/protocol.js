// Teachy extension <-> Teachy app messages.
//
// Transport: Chrome native messaging. Every message is one JSON object; on the
// wire (helper <-> Chrome and helper <-> app) it is a 32-bit little-endian
// length followed by that many bytes of UTF-8 JSON. Chrome does the framing on
// the extension's side; encodeFrame / FrameDecoder here are the reference
// implementation used by the tests and mirrored by the Swift side.
//
//   app -> extension   {"type":"request","id":"7","method":"click","params":{...}}
//   extension -> app   {"type":"response","id":"7","ok":true,"result":{...}}
//                      {"type":"response","id":"7","ok":false,"error":{"code":"no_such_element","message":"..."}}
//                      {"type":"event","event":"hello"|"user_stopped"|"tab_closed",...}
//   helper -> either   {"type":"host","event":"app_connected"|"app_not_running"|"hello"|"error",...}
//
// Pure: no chrome.* and no DOM in this file.
(function (root) {
  'use strict';

  var PROTOCOL_VERSION = 1;
  var HOST_NAME = 'com.teachy.browser';
  // Chrome refuses a message from a native host that is larger than this.
  var MAX_BYTES_TO_BROWSER = 1024 * 1024;
  var MAX_FRAME_BYTES = 64 * 1024 * 1024;

  var METHODS = [
    'ping', 'open_tab', 'list_tabs', 'close_tab', 'close_job',
    'read_page', 'describe', 'click', 'type', 'select', 'press_key', 'scroll',
    'navigate', 'back', 'forward', 'reload', 'wait_for', 'screenshot',
    'grant_upload', 'upload_file'
  ];

  function TeachyError(code, message, extra) {
    this.code = code;
    this.message = message || code;
    this.extra = extra || null;
  }
  TeachyError.prototype = Object.create(Error.prototype);
  TeachyError.prototype.name = 'TeachyError';

  function response(id, result) {
    return { type: 'response', id: id, ok: true, result: result === undefined ? {} : result };
  }

  function errorResponse(id, code, message, extra) {
    var error = { code: String(code || 'failed'), message: String(message || code || 'failed') };
    if (extra && typeof extra === 'object') {
      for (var key in extra) if (Object.prototype.hasOwnProperty.call(extra, key)) error[key] = extra[key];
    }
    return { type: 'response', id: id, ok: false, error: error };
  }

  function event(name, fields) {
    var message = { type: 'event', event: name };
    if (fields) for (var key in fields) if (Object.prototype.hasOwnProperty.call(fields, key)) message[key] = fields[key];
    return message;
  }

  // Returns {ok:true, request} or {ok:false, id, code, message}.
  function validateRequest(message) {
    if (!message || typeof message !== 'object' || Array.isArray(message)) {
      return { ok: false, id: null, code: 'bad_request', message: 'The message is not a JSON object.' };
    }
    var id = (typeof message.id === 'string' || typeof message.id === 'number') ? message.id : null;
    if (message.type !== 'request') {
      return { ok: false, id: id, code: 'bad_request', message: 'Expected type "request".' };
    }
    if (id === null) {
      return { ok: false, id: null, code: 'bad_request', message: 'A request needs an id.' };
    }
    if (typeof message.method !== 'string' || METHODS.indexOf(message.method) === -1) {
      return { ok: false, id: id, code: 'unknown_method', message: 'Unknown method: ' + String(message.method) };
    }
    var params = message.params;
    if (params === undefined || params === null) params = {};
    if (typeof params !== 'object' || Array.isArray(params)) {
      return { ok: false, id: id, code: 'bad_params', message: 'params must be an object.' };
    }
    return { ok: true, request: { id: id, method: message.method, params: params } };
  }

  // Only web pages. No javascript:, file:, chrome:, data: and friends.
  function isAllowedURL(url) {
    if (typeof url !== 'string') return false;
    var trimmed = url.trim();
    if (trimmed === 'about:blank') return true;
    return /^https?:\/\/[^\s/?#]+/i.test(trimmed);
  }

  function hostOf(url) {
    var match = /^[a-z][a-z0-9+.-]*:\/\/([^/?#]*)/i.exec(String(url || ''));
    if (!match) return '';
    var authority = match[1];
    var at = authority.lastIndexOf('@');
    if (at !== -1) authority = authority.slice(at + 1);
    if (authority.charAt(0) === '[') {
      var close = authority.indexOf(']');
      return close === -1 ? authority.toLowerCase() : authority.slice(0, close + 1).toLowerCase();
    }
    return authority.replace(/:\d+$/, '').toLowerCase();
  }

  // --- Framing (bytes are Uint8Array / Node Buffer) ---

  function utf8Encode(text) {
    return new TextEncoder().encode(text);
  }

  function utf8Decode(bytes) {
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  }

  function encodeFrame(message) {
    var body = utf8Encode(JSON.stringify(message));
    if (body.length > MAX_FRAME_BYTES) throw new TeachyError('frame_too_large', 'Message of ' + body.length + ' bytes is too large.');
    var out = new Uint8Array(4 + body.length);
    new DataView(out.buffer).setUint32(0, body.length, true);
    out.set(body, 4);
    return out;
  }

  // Feed it bytes as they arrive; it hands back whole messages.
  // push() returns [{message}] or [{error:'malformed_frame'}] entries; after
  // an oversize length it throws frame_too_large (the stream cannot be resynchronised).
  function FrameDecoder(maxBytes) {
    this.max = maxBytes || MAX_FRAME_BYTES;
    this.buffer = new Uint8Array(0);
  }

  FrameDecoder.prototype.push = function (chunk) {
    if (chunk && chunk.length) {
      var joined = new Uint8Array(this.buffer.length + chunk.length);
      joined.set(this.buffer, 0);
      joined.set(chunk, this.buffer.length);
      this.buffer = joined;
    }
    var out = [];
    while (this.buffer.length >= 4) {
      var view = new DataView(this.buffer.buffer, this.buffer.byteOffset, this.buffer.byteLength);
      var length = view.getUint32(0, true);
      if (length > this.max) throw new TeachyError('frame_too_large', 'Frame of ' + length + ' bytes is over the limit.');
      if (this.buffer.length < 4 + length) break;
      var body = this.buffer.subarray(4, 4 + length);
      this.buffer = this.buffer.slice(4 + length);
      try {
        var parsed = JSON.parse(utf8Decode(body));
        if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('not an object');
        out.push({ message: parsed });
      } catch (problem) {
        out.push({ error: 'malformed_frame' });
      }
    }
    return out;
  };

  FrameDecoder.prototype.pendingBytes = function () { return this.buffer.length; };

  var api = {
    PROTOCOL_VERSION: PROTOCOL_VERSION,
    HOST_NAME: HOST_NAME,
    MAX_BYTES_TO_BROWSER: MAX_BYTES_TO_BROWSER,
    MAX_FRAME_BYTES: MAX_FRAME_BYTES,
    METHODS: METHODS,
    TeachyError: TeachyError,
    response: response,
    errorResponse: errorResponse,
    event: event,
    validateRequest: validateRequest,
    isAllowedURL: isAllowedURL,
    hostOf: hostOf,
    encodeFrame: encodeFrame,
    FrameDecoder: FrameDecoder
  };

  root.TeachyProtocol = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
