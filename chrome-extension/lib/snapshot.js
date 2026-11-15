// The interactive-element list the agent reads, in the same shape as the app's
// accessibility snapshots:
//
//     [12] button "Add to cart"
//     [13] textbox "Email" value=""
//     [14] textbox "Password" (password: the person types this)
//
// The page side (content/page-agent.js) walks the DOM and hands this file plain
// descriptors; everything here is pure (no DOM, no chrome.*):
//
//   describe(descriptor)        -> { index, role, name, line, ... }
//   build(descriptors, options) -> { elements, omitted }      (caps the list)
//   diff(before, after)         -> { text, ... }               (what an action changed)
//   outline(snapshot)           -> the numbered lines as one string
//
// A descriptor: { index, tag, type, role, ariaLabel, labelledBy, label, text,
//   value, placeholder, title, alt, name, checked, expanded, selected, pressed,
//   href, contentEditable, inViewport, secret: null | {kind}, multiple, clickableOnly }
(function (root) {
  'use strict';

  var DEFAULT_CAP = 300;
  var NAME_LIMIT = 80;
  var VALUE_LIMIT = 60;

  function clean(value, limit) {
    var text = String(value === undefined || value === null ? '' : value).replace(/\s+/g, ' ').trim();
    if (limit && text.length > limit) return text.slice(0, limit - 1) + '…';
    return text;
  }

  var INPUT_ROLES = {
    button: 'button', submit: 'button', reset: 'button', image: 'button',
    checkbox: 'checkbox', radio: 'radio', range: 'slider', file: 'file input',
    search: 'searchbox', number: 'spinbutton'
  };

  var TAG_ROLES = {
    a: 'link', button: 'button', select: 'combobox', textarea: 'textbox', summary: 'button',
    option: 'option', details: 'group', label: 'label'
  };

  function roleOf(d) {
    var explicit = clean(d.role).toLowerCase().split(' ')[0];
    if (explicit && explicit !== 'presentation' && explicit !== 'none' && explicit !== 'generic') return explicit;
    var tag = clean(d.tag).toLowerCase();
    if (tag === 'input') {
      var type = clean(d.type).toLowerCase() || 'text';
      return INPUT_ROLES[type] || 'textbox';
    }
    if (tag === 'select') return d.multiple ? 'listbox' : 'combobox';
    if (TAG_ROLES[tag]) return TAG_ROLES[tag];
    if (d.contentEditable === true) return 'textbox';
    return 'clickable';
  }

  // Roughly the accessible-name order: labelledby, aria-label, <label>, the
  // control's own words, then the weaker hints.
  function nameOf(d) {
    var tag = clean(d.tag).toLowerCase();
    var type = clean(d.type).toLowerCase();
    var isValueButton = tag === 'input' && (type === 'submit' || type === 'button' || type === 'reset');
    var isField = tag === 'input' || tag === 'textarea' || tag === 'select' || d.contentEditable === true;
    var candidates = [
      d.labelledBy,
      d.ariaLabel,
      d.label,
      isValueButton ? d.value : '',
      tag === 'input' && type === 'image' ? d.alt : '',
      isField ? '' : d.text,
      d.placeholder,
      d.alt,
      d.title,
      isValueButton && !clean(d.value) ? (type === 'submit' ? 'Submit' : type === 'reset' ? 'Reset' : '') : '',
      isField ? clean(d.name).replace(/[_\-.\[\]]+/g, ' ') : ''
    ];
    for (var i = 0; i < candidates.length; i++) {
      var text = clean(candidates[i], NAME_LIMIT);
      if (text) return text;
    }
    return '';
  }

  function quote(text) {
    return '"' + String(text).replace(/"/g, '\'') + '"';
  }

  function describe(d) {
    var role = roleOf(d);
    var name = nameOf(d);
    var parts = ['[' + d.index + ']', role];
    if (name) parts.push(quote(name));

    var secretKind = d.secret && d.secret.kind ? d.secret.kind : null;
    var value = null;
    var takesText = role === 'textbox' || role === 'searchbox' || role === 'spinbutton' || role === 'combobox' || role === 'slider';

    if (secretKind) {
      // The value of a private field is never read, so there is nothing to show.
      var what = secretKind === 'password' ? 'password' : secretKind === 'one_time_code' ? 'verification code' : 'card or bank details';
      parts.push('(' + what + ': the person types this)');
    } else if (takesText && d.value !== undefined && d.value !== null) {
      value = clean(d.value, VALUE_LIMIT);
      parts.push('value=' + quote(value));
    }

    if (role === 'checkbox' || role === 'radio' || role === 'switch' || role === 'menuitemcheckbox' || role === 'menuitemradio') {
      parts.push(d.checked ? 'checked' : 'unchecked');
    }
    if (d.pressed === true) parts.push('pressed');
    if (d.selected === true) parts.push('selected');
    if (d.expanded === true) parts.push('expanded');
    if (d.expanded === false) parts.push('collapsed');
    if (d.inViewport === false) parts.push('(off screen)');

    return {
      index: d.index,
      role: role,
      name: name,
      value: value,
      checked: d.checked === true,
      expanded: d.expanded === true ? true : d.expanded === false ? false : null,
      selected: d.selected === true,
      secret: secretKind,
      inViewport: d.inViewport !== false,
      line: parts.join(' ')
    };
  }

  // Keeps at most `cap` elements: what is on screen first, then the rest in page order.
  function build(descriptors, options) {
    var cap = options && options.cap ? options.cap : DEFAULT_CAP;
    var all = [];
    for (var i = 0; i < descriptors.length; i++) all.push(describe(descriptors[i]));
    if (all.length <= cap) return { elements: all, omitted: 0 };

    var keep = {};
    var kept = 0;
    var pass;
    for (pass = 0; pass < 2 && kept < cap; pass++) {
      for (i = 0; i < all.length && kept < cap; i++) {
        var onScreen = all[i].inViewport;
        if ((pass === 0 && onScreen) || (pass === 1 && !onScreen)) {
          if (!keep[i]) { keep[i] = true; kept++; }
        }
      }
    }
    var elements = [];
    for (i = 0; i < all.length; i++) if (keep[i]) elements.push(all[i]);
    return { elements: elements, omitted: all.length - elements.length };
  }

  function outline(snapshot) {
    var lines = [];
    var elements = snapshot && snapshot.elements ? snapshot.elements : [];
    for (var i = 0; i < elements.length; i++) lines.push(elements[i].line);
    if (snapshot && snapshot.omitted > 0) {
      lines.push('(' + snapshot.omitted + ' more controls not listed: scroll, or ask for a narrower part of the page)');
    }
    return lines.join('\n');
  }

  function byIndex(elements) {
    var map = {};
    for (var i = 0; i < elements.length; i++) map[elements[i].index] = elements[i];
    return map;
  }

  // What changed between two snapshots of the same tab.
  // A snapshot: { documentId, url, title, elements, omitted, focusedIndex }
  function diff(before, after, options) {
    var listLimit = options && options.listLimit ? options.listLimit : 12;
    var result = {
      newPage: false, urlChanged: false, titleChanged: false,
      appeared: [], disappeared: [], changed: [], focused: null, text: ''
    };
    var lines = [];
    before = before || { elements: [] };
    after = after || { elements: [] };

    result.urlChanged = clean(before.url) !== clean(after.url);
    result.titleChanged = clean(before.title) !== clean(after.title);
    result.newPage = !!before.documentId && !!after.documentId && before.documentId !== after.documentId;

    if (result.newPage) {
      lines.push('A new page loaded: ' + quote(clean(after.title, 100)) + ' ' + clean(after.url, 200));
      lines.push('The numbers from the old page are gone. Controls here:');
      var shown = Math.min(after.elements.length, listLimit * 2);
      for (var s = 0; s < shown; s++) lines.push('  ' + after.elements[s].line);
      var rest = after.elements.length - shown + (after.omitted || 0);
      if (rest > 0) lines.push('  (' + rest + ' more: read the page for the full list)');
      result.appeared = after.elements.slice(0, shown).map(function (e) { return e.line; });
    } else {
      if (result.urlChanged) lines.push('Address is now ' + clean(after.url, 200));
      if (result.titleChanged) lines.push('Title is now ' + quote(clean(after.title, 100)));

      var was = byIndex(before.elements);
      var now = byIndex(after.elements);
      var i;
      for (i = 0; i < after.elements.length; i++) {
        var element = after.elements[i];
        var old = was[element.index];
        if (!old) {
          result.appeared.push(element.line);
        } else if (old.line !== element.line && (old.value !== element.value || old.checked !== element.checked ||
                   old.expanded !== element.expanded || old.selected !== element.selected || old.name !== element.name)) {
          result.changed.push(element.line);
        }
      }
      for (i = 0; i < before.elements.length; i++) {
        if (!now[before.elements[i].index]) result.disappeared.push(before.elements[i].line);
      }

      pushList(lines, 'Appeared', result.appeared, listLimit);
      pushList(lines, 'Changed', result.changed, listLimit);
      pushList(lines, 'Gone', result.disappeared, listLimit);
    }

    if (after.focusedIndex !== undefined && after.focusedIndex !== null) {
      var focused = byIndex(after.elements)[after.focusedIndex];
      if (focused) {
        result.focused = focused.line;
        if (result.newPage || before.focusedIndex !== after.focusedIndex) lines.push('Focus is on ' + focused.line);
      }
    }

    if (!lines.length) lines.push('Nothing changed on the page.');
    result.text = lines.join('\n');
    return result;
  }

  function pushList(lines, title, items, limit) {
    if (!items.length) return;
    lines.push(title + ':');
    var shown = Math.min(items.length, limit);
    for (var i = 0; i < shown; i++) lines.push('  ' + items[i]);
    if (items.length > shown) lines.push('  (' + (items.length - shown) + ' more)');
  }

  var api = {
    DEFAULT_CAP: DEFAULT_CAP,
    clean: clean,
    roleOf: roleOf,
    nameOf: nameOf,
    describe: describe,
    build: build,
    outline: outline,
    diff: diff
  };
  root.TeachySnapshot = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
