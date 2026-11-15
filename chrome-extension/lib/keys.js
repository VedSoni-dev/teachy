// Turns "cmd+shift+k", "Enter", "ArrowDown" or "a" into what the debugger's
// Input.dispatchKeyEvent needs. Pure: no DOM, no chrome.*.
//
//   parse(combo) -> { key, code, keyCode, modifiers, text, printable, commands, label }
//                or { error: '...' }  or  { blocked: '...' }
(function (root) {
  'use strict';

  var ALT = 1, CTRL = 2, META = 4, SHIFT = 8;

  var MODIFIERS = {
    alt: ALT, option: ALT, opt: ALT,
    ctrl: CTRL, control: CTRL,
    cmd: META, command: META, meta: META, win: META, super: META,
    shift: SHIFT
  };

  var NAMED = {
    enter: { key: 'Enter', code: 'Enter', keyCode: 13, text: '\r' },
    return: { key: 'Enter', code: 'Enter', keyCode: 13, text: '\r' },
    tab: { key: 'Tab', code: 'Tab', keyCode: 9 },
    escape: { key: 'Escape', code: 'Escape', keyCode: 27 },
    esc: { key: 'Escape', code: 'Escape', keyCode: 27 },
    space: { key: ' ', code: 'Space', keyCode: 32, text: ' ' },
    spacebar: { key: ' ', code: 'Space', keyCode: 32, text: ' ' },
    backspace: { key: 'Backspace', code: 'Backspace', keyCode: 8 },
    delete: { key: 'Delete', code: 'Delete', keyCode: 46 },
    del: { key: 'Delete', code: 'Delete', keyCode: 46 },
    forwarddelete: { key: 'Delete', code: 'Delete', keyCode: 46 },
    arrowup: { key: 'ArrowUp', code: 'ArrowUp', keyCode: 38 },
    up: { key: 'ArrowUp', code: 'ArrowUp', keyCode: 38 },
    arrowdown: { key: 'ArrowDown', code: 'ArrowDown', keyCode: 40 },
    down: { key: 'ArrowDown', code: 'ArrowDown', keyCode: 40 },
    arrowleft: { key: 'ArrowLeft', code: 'ArrowLeft', keyCode: 37 },
    left: { key: 'ArrowLeft', code: 'ArrowLeft', keyCode: 37 },
    arrowright: { key: 'ArrowRight', code: 'ArrowRight', keyCode: 39 },
    right: { key: 'ArrowRight', code: 'ArrowRight', keyCode: 39 },
    home: { key: 'Home', code: 'Home', keyCode: 36 },
    end: { key: 'End', code: 'End', keyCode: 35 },
    pageup: { key: 'PageUp', code: 'PageUp', keyCode: 33 },
    pagedown: { key: 'PageDown', code: 'PageDown', keyCode: 34 }
  };

  var PUNCTUATION_CODES = {
    '-': ['Minus', 189], '=': ['Equal', 187], '[': ['BracketLeft', 219], ']': ['BracketRight', 221],
    '\\': ['Backslash', 220], ';': ['Semicolon', 186], '\'': ['Quote', 222], ',': ['Comma', 188],
    '.': ['Period', 190], '/': ['Slash', 191], '`': ['Backquote', 192]
  };

  // Editing shortcuts need the matching editor command to do anything through the debugger.
  var EDIT_COMMANDS = { a: 'selectAll', c: 'copy', x: 'cut', z: 'undo' };

  function parse(combo) {
    var raw = String(combo === undefined || combo === null ? '' : combo).trim();
    if (!raw) return { error: 'Give a key, like "Enter" or "cmd+a".' };

    // "+" itself can be the key: "shift++" or just "+".
    var pieces;
    if (raw === '+') {
      pieces = ['+'];
    } else {
      pieces = raw.replace(/\+\+$/, '+plus').split('+').map(function (piece) { return piece.trim(); });
      if (pieces[pieces.length - 1] === 'plus') pieces[pieces.length - 1] = '+';
    }

    var modifiers = 0;
    var keyName = null;
    for (var i = 0; i < pieces.length; i++) {
      var piece = pieces[i];
      var lowered = piece.toLowerCase();
      if (i < pieces.length - 1) {
        if (!MODIFIERS[lowered]) return { error: 'Unknown modifier "' + piece + '". Use cmd, ctrl, alt or shift.' };
        modifiers |= MODIFIERS[lowered];
      } else {
        keyName = piece;
      }
    }
    if (!keyName) return { error: 'No key in "' + raw + '".' };

    var result;
    var lower = keyName.toLowerCase();
    if (NAMED[lower]) {
      var named = NAMED[lower];
      result = { key: named.key, code: named.code, keyCode: named.keyCode, text: named.text || '' };
    } else if (/^f([1-9]|1[0-2])$/.test(lower)) {
      var number = Number(lower.slice(1));
      result = { key: 'F' + number, code: 'F' + number, keyCode: 111 + number, text: '' };
    } else if (keyName.length === 1) {
      var character = keyName;
      if (/[a-z]/i.test(character)) {
        var shifted = (modifiers & SHIFT) !== 0 || (character !== character.toLowerCase());
        if (character !== character.toLowerCase()) modifiers |= SHIFT;
        var letter = shifted ? character.toUpperCase() : character.toLowerCase();
        result = { key: letter, code: 'Key' + character.toUpperCase(), keyCode: character.toUpperCase().charCodeAt(0), text: letter };
      } else if (/[0-9]/.test(character)) {
        result = { key: character, code: 'Digit' + character, keyCode: character.charCodeAt(0), text: character };
      } else {
        var punctuation = PUNCTUATION_CODES[character];
        result = { key: character, code: punctuation ? punctuation[0] : '', keyCode: punctuation ? punctuation[1] : 0, text: character };
      }
    } else {
      return { error: 'Unknown key "' + keyName + '". Use names like Enter, Tab, Escape, ArrowDown, Backspace, or one character.' };
    }

    var commandOrControl = (modifiers & (META | CTRL)) !== 0;
    var simpleLetter = result.key.length === 1 ? result.key.toLowerCase() : '';

    // Pasting would put whatever is on the person's clipboard into the page.
    if (commandOrControl && simpleLetter === 'v') {
      return { blocked: 'Pasting from the clipboard is not available. Type the text instead.' };
    }

    result.modifiers = modifiers;
    result.commands = [];
    if (commandOrControl && (modifiers & ALT) === 0 && EDIT_COMMANDS[simpleLetter]) {
      result.commands = [simpleLetter === 'z' && (modifiers & SHIFT) ? 'redo' : EDIT_COMMANDS[simpleLetter]];
    }
    // With cmd / ctrl / alt held the key is a shortcut, not a character.
    if (commandOrControl || (modifiers & ALT) !== 0) result.text = '';
    // "Printable" = this key press would put a character into a field.
    result.printable = result.text !== '' && result.text !== '\r';
    result.label = labelFor(modifiers, result.key);
    return result;
  }

  function labelFor(modifiers, key) {
    var parts = [];
    if (modifiers & CTRL) parts.push('ctrl');
    if (modifiers & ALT) parts.push('alt');
    if (modifiers & SHIFT) parts.push('shift');
    if (modifiers & META) parts.push('cmd');
    parts.push(key === ' ' ? 'Space' : key);
    return parts.join('+');
  }

  var api = { parse: parse, ALT: ALT, CTRL: CTRL, META: META, SHIFT: SHIFT };
  root.TeachyKeys = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
