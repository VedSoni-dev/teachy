// The part of Teachy that runs inside a page a job is working on.
//
// The service worker evaluates lib/secrets.js, lib/snapshot.js, lib/readable.js
// and then this file in an isolated world of the tab (through the debugger), so
// the page's own scripts cannot see or change any of it. Everything is reached
// through one function:
//
//     __teachyAgent.call(method, params) -> plain JSON
//
// What lives here: walking the DOM into the numbered element list, reading the
// main text, finding where to click, focusing fields, the DOM fallbacks for
// input, the glow and the agent cursor, and the Escape key that stops a job.
//
// Rules this file enforces by itself:
//   - password, one-time-code and card fields: never typed into, value never read;
//   - nothing here talks to the network.
(function () {
  'use strict';
  if (globalThis.__teachyAgent) return;

  var Secrets = globalThis.TeachySecrets;
  var Snapshot = globalThis.TeachySnapshot;
  var Readable = globalThis.TeachyReadable;

  var INTERACTIVE_ROLES = {
    button: 1, link: 1, checkbox: 1, radio: 1, tab: 1, menuitem: 1, menuitemcheckbox: 1, menuitemradio: 1,
    option: 1, switch: 1, textbox: 1, combobox: 1, searchbox: 1, slider: 1, spinbutton: 1, treeitem: 1, listbox: 0
  };
  var MAX_ELEMENTS_WALKED = 6000;

  var state = {
    documentId: Math.random().toString(36).slice(2, 10) + Date.now().toString(36),
    nextIndex: Number(globalThis.__teachyIndexBase) > 0 ? Number(globalThis.__teachyIndexBase) : 1,
    indexOf: new WeakMap(),
    elementAt: new Map(),
    lastMutation: Date.now(),
    ignoreEscapeUntil: 0,
    presence: null,
    masked: []
  };

  // ---------------------------------------------------------------- helpers

  function text(value, limit) {
    var result = String(value === undefined || value === null ? '' : value).replace(/\s+/g, ' ').trim();
    return limit && result.length > limit ? result.slice(0, limit - 1) + '…' : result;
  }

  function viewOf(element) {
    return element.ownerDocument && element.ownerDocument.defaultView ? element.ownerDocument.defaultView : window;
  }

  // The element's rectangle in the top page's viewport, through any same-origin iframes.
  function topRect(element) {
    var rect = element.getBoundingClientRect();
    var left = rect.left, top = rect.top;
    var view = viewOf(element);
    var guard = 0;
    while (view && view !== window && guard++ < 10) {
      var frame;
      try { frame = view.frameElement; } catch (denied) { frame = null; }
      if (!frame) break;
      var frameRect = frame.getBoundingClientRect();
      left += frameRect.left + frame.clientLeft;
      top += frameRect.top + frame.clientTop;
      view = viewOf(frame);
    }
    return { left: left, top: top, width: rect.width, height: rect.height, right: left + rect.width, bottom: top + rect.height };
  }

  function childrenForText(node) {
    if (node.nodeType !== 1) return node.childNodes;
    if (node.shadowRoot) return node.shadowRoot.childNodes;
    var tag = node.tagName;
    if (tag === 'SLOT' && typeof node.assignedNodes === 'function') {
      var assigned = node.assignedNodes();
      if (assigned.length) return assigned;
    }
    return node.childNodes;
  }

  function isHiddenForText(node) {
    if (node.nodeType !== 1) return false;
    var style;
    try { style = viewOf(node).getComputedStyle(node); } catch (problem) { return false; }
    return !style || style.display === 'none' || style.visibility === 'hidden';
  }

  function attribute(element, name) {
    var value = element.getAttribute(name);
    return value === null ? '' : value;
  }

  function labelText(element) {
    var parts = [];
    try {
      if (element.labels && element.labels.length) {
        for (var i = 0; i < element.labels.length && i < 2; i++) parts.push(visibleText(element.labels[i], element));
      }
    } catch (ignored) { /* not a labelable element */ }
    if (!parts.length && element.closest) {
      var wrapping = element.closest('label');
      if (wrapping) parts.push(visibleText(wrapping, element));
    }
    return text(parts.join(' '), 120);
  }

  function labelledByText(element) {
    var ids = attribute(element, 'aria-labelledby').split(/\s+/).filter(Boolean);
    if (!ids.length) return '';
    var rootNode = element.getRootNode ? element.getRootNode() : element.ownerDocument;
    var parts = [];
    for (var i = 0; i < ids.length; i++) {
      var target = rootNode.getElementById ? rootNode.getElementById(ids[i]) : element.ownerDocument.getElementById(ids[i]);
      if (target) parts.push(visibleText(target, null));
    }
    return text(parts.join(' '), 120);
  }

  // The words a person sees on an element, without the values of form fields inside it.
  function visibleText(element, except) {
    var out = [];
    (function visit(node, depth) {
      if (out.length > 60 || depth > 12) return;
      if (node.nodeType === 3) { out.push(node.nodeValue); return; }
      if (node.nodeType !== 1 || node === except) return;
      var tag = node.tagName;
      if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'SELECT' || tag === 'TEXTAREA' || tag === 'INPUT' || tag === 'NOSCRIPT') return;
      if (tag === 'IMG') { out.push(attribute(node, 'alt')); return; }
      if (tag === 'svg' || tag === 'SVG') { out.push(attribute(node, 'aria-label')); return; }
      var children = childrenForText(node);
      for (var i = 0; i < children.length; i++) visit(children[i], depth + 1);
    })(element, 0);
    return text(out.join(' '), 160);
  }

  // The attributes that decide whether a field is private. Never includes the value.
  function fieldIdentity(element) {
    var tag = element.tagName.toLowerCase();
    return {
      tag: tag,
      type: tag === 'input' ? (attribute(element, 'type') || 'text').toLowerCase() : '',
      autocomplete: attribute(element, 'autocomplete'),
      name: attribute(element, 'name'),
      id: attribute(element, 'id'),
      placeholder: attribute(element, 'placeholder'),
      ariaLabel: attribute(element, 'aria-label'),
      label: labelText(element) || labelledByText(element),
      maxLength: attribute(element, 'maxlength'),
      inputMode: attribute(element, 'inputmode'),
      pattern: attribute(element, 'pattern'),
      contentEditable: element.isContentEditable === true && tag !== 'input' && tag !== 'textarea'
    };
  }

  function secretOf(element) {
    if (!element || element.nodeType !== 1) return null;
    var tag = element.tagName;
    if (tag !== 'INPUT' && tag !== 'TEXTAREA' && element.isContentEditable !== true) return null;
    var identity = fieldIdentity(element);
    var verdict = Secrets.classifyField(identity);
    if (!verdict) return null;
    return { kind: verdict.kind, why: verdict.why, field: Secrets.fieldLabel(identity) };
  }

  function isInteractive(element, style, parentIsPointer) {
    var tag = element.tagName;
    switch (tag) {
      case 'A': return element.hasAttribute('href') || element.hasAttribute('onclick') || !!attribute(element, 'role');
      case 'BUTTON': case 'SELECT': case 'TEXTAREA': case 'SUMMARY': return true;
      case 'INPUT': return (attribute(element, 'type') || 'text').toLowerCase() !== 'hidden';
      case 'LABEL': return false;
      default: break;
    }
    var role = attribute(element, 'role').toLowerCase().split(' ')[0];
    if (role && INTERACTIVE_ROLES[role]) return true;
    if (element.isContentEditable === true && !(element.parentElement && element.parentElement.isContentEditable === true)) return true;
    if (element.hasAttribute('onclick')) return true;
    var tabindex = element.getAttribute('tabindex');
    if (tabindex !== null && tabindex !== '-1' && tag !== 'BODY' && tag !== 'HTML' && tag !== 'IFRAME') return true;
    // Styled like something you click, and the outermost such element.
    if (style && style.cursor === 'pointer' && !parentIsPointer && tag !== 'HTML' && tag !== 'BODY') return true;
    return false;
  }

  function isDisabled(element) {
    if (element.disabled === true) return true;
    if (attribute(element, 'aria-disabled') === 'true') return true;
    try { if (element.matches && element.matches(':disabled')) return true; } catch (ignored) { /* old engine */ }
    return false;
  }

  function indexFor(element) {
    var index = state.indexOf.get(element);
    if (!index) {
      index = state.nextIndex++;
      state.indexOf.set(element, index);
      state.elementAt.set(index, new WeakRef(element));
    }
    return index;
  }

  function elementFor(index) {
    var reference = state.elementAt.get(Number(index));
    var element = reference ? reference.deref() : null;
    if (!element || !element.isConnected) return null;
    return element;
  }

  function deepActiveElement() {
    var active = document.activeElement;
    var guard = 0;
    while (active && guard++ < 20) {
      if (active.shadowRoot && active.shadowRoot.activeElement) { active = active.shadowRoot.activeElement; continue; }
      if (active.tagName === 'IFRAME') {
        var inner = null;
        try { inner = active.contentDocument ? active.contentDocument.activeElement : null; } catch (denied) { inner = null; }
        if (inner && inner !== active.contentDocument.body) { active = inner; continue; }
      }
      break;
    }
    return active && active !== document.body && active !== document.documentElement ? active : null;
  }

  // ------------------------------------------------------------- collecting

  function collect() {
    var found = [];
    var walked = 0;
    var viewportWidth = window.innerWidth, viewportHeight = window.innerHeight;

    function walk(rootNode, parentIsPointer, insideInteractive) {
      var children = rootNode.children || [];
      for (var i = 0; i < children.length; i++) {
        var element = children[i];
        if (walked++ > MAX_ELEMENTS_WALKED) return;
        var tag = element.tagName;
        if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT' || tag === 'TEMPLATE' || tag === 'HEAD' || tag === 'TEACHY-PRESENCE') continue;
        if (element.inert === true) continue;

        var style = null;
        try { style = viewOf(element).getComputedStyle(element); } catch (problem) { style = null; }
        if (style && style.display === 'none') continue;
        var pointer = !!style && style.cursor === 'pointer';

        var formControl = tag === 'INPUT' || tag === 'SELECT' || tag === 'TEXTAREA' || tag === 'BUTTON';
        var interactive = false;
        if (!insideInteractive || formControl) {
          interactive = isInteractive(element, style, parentIsPointer) && !isDisabled(element);
        }
        if (interactive) {
          var rect = topRect(element);
          var visible = rect.width > 0 && rect.height > 0 && (!style || (style.visibility !== 'hidden' && style.visibility !== 'collapse'));
          // Parked far off the top or left edge: there is no scrolling to it.
          var reachable = rect.bottom + window.scrollY > -1 && rect.right + window.scrollX > -1;
          if (visible && reachable) {
            found.push({ element: element, rect: rect, inViewport: rect.bottom > 0 && rect.right > 0 && rect.top < viewportHeight && rect.left < viewportWidth });
          } else {
            interactive = false;
          }
        }

        var blocksChildren = interactive && (tag === 'A' || tag === 'BUTTON' || tag === 'SUMMARY' || attribute(element, 'role') === 'button' || attribute(element, 'role') === 'link');
        if (element.shadowRoot) walk(element.shadowRoot, pointer, insideInteractive || blocksChildren);
        if (tag === 'IFRAME') {
          var inner = null;
          try { inner = element.contentDocument; } catch (denied) { inner = null; }
          if (inner && inner.documentElement) walk(inner, false, false);
        } else if (tag !== 'SELECT' && tag !== 'TEXTAREA') {
          walk(element, pointer, insideInteractive || blocksChildren);
        }
      }
    }

    walk(document, false, false);
    return found;
  }

  function descriptorFor(entry) {
    var element = entry.element;
    var tag = element.tagName.toLowerCase();
    var type = tag === 'input' ? (attribute(element, 'type') || 'text').toLowerCase() : '';
    var secret = secretOf(element);
    var descriptor = {
      index: indexFor(element),
      tag: tag,
      type: type,
      role: attribute(element, 'role'),
      ariaLabel: attribute(element, 'aria-label'),
      labelledBy: labelledByText(element),
      label: tag === 'input' || tag === 'select' || tag === 'textarea' || tag === 'button' ? labelText(element) : '',
      text: '',
      placeholder: attribute(element, 'placeholder'),
      title: attribute(element, 'title'),
      alt: attribute(element, 'alt'),
      name: attribute(element, 'name'),
      contentEditable: element.isContentEditable === true && tag !== 'input' && tag !== 'textarea',
      inViewport: entry.inViewport,
      multiple: element.multiple === true,
      secret: secret ? { kind: secret.kind } : null
    };

    if (tag === 'input' || tag === 'textarea') {
      var isValueButton = type === 'submit' || type === 'button' || type === 'reset';
      if (type === 'checkbox' || type === 'radio') {
        descriptor.checked = element.checked === true;
      } else if (type === 'file') {
        descriptor.value = element.files && element.files.length ? element.files.length + ' file(s) chosen' : '';
      } else if (!secret) {
        // The one place a field's value is read, and never for a private field.
        descriptor.value = isValueButton ? element.value : text(element.value, 80);
      }
    } else if (tag === 'select') {
      var chosen = element.selectedOptions && element.selectedOptions.length ? element.selectedOptions[0] : null;
      descriptor.value = chosen ? text(chosen.textContent, 80) : '';
    } else if (descriptor.contentEditable) {
      if (!secret) descriptor.value = text(element.innerText || element.textContent, 80);
    } else {
      descriptor.text = visibleText(element, null);
    }

    var ariaChecked = attribute(element, 'aria-checked');
    if (ariaChecked) descriptor.checked = ariaChecked === 'true';
    var expanded = attribute(element, 'aria-expanded');
    if (expanded === 'true') descriptor.expanded = true; else if (expanded === 'false') descriptor.expanded = false;
    if (attribute(element, 'aria-selected') === 'true') descriptor.selected = true;
    if (attribute(element, 'aria-pressed') === 'true') descriptor.pressed = true;
    if (tag === 'summary' && element.parentElement && element.parentElement.tagName === 'DETAILS') {
      descriptor.expanded = element.parentElement.open === true;
    }
    return descriptor;
  }

  function snapshot(params) {
    var entries = collect();
    var descriptors = [];
    for (var i = 0; i < entries.length; i++) descriptors.push(descriptorFor(entries[i]));
    var built = Snapshot.build(descriptors, { cap: params && params.cap ? params.cap : Snapshot.DEFAULT_CAP });
    var active = deepActiveElement();
    var result = {
      documentId: state.documentId,
      url: location.href,
      title: document.title,
      readyState: document.readyState,
      elements: built.elements,
      omitted: built.omitted,
      focusedIndex: active && state.indexOf.get(active) ? state.indexOf.get(active) : null,
      maxIndex: state.nextIndex - 1,
      scroll: {
        y: Math.round(window.scrollY),
        height: Math.round(Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)),
        viewport: Math.round(window.innerHeight)
      }
    };
    if (params && params.text) {
      var readable = Readable.extract(document.body || document.documentElement, {
        maxChars: params.maxChars || 12000,
        childrenOf: function (node) {
          if (node.nodeType === 1 && node.tagName === 'IFRAME') {
            try { return node.contentDocument && node.contentDocument.body ? [node.contentDocument.body] : []; } catch (denied) { return []; }
          }
          return childrenForText(node);
        },
        isHidden: isHiddenForText
      });
      result.text = readable.text;
      result.textSource = readable.source;
    }
    return result;
  }

  // --------------------------------------------------------------- locating

  function describeElement(element) {
    var entry = { element: element, rect: topRect(element), inViewport: true };
    var described = Snapshot.describe(descriptorFor(entry));
    return { index: described.index, role: described.role, name: described.name, line: described.line };
  }

  function submitLabelFor(element) {
    var form = element && element.form ? element.form : (element && element.closest ? element.closest('form') : null);
    if (!form) return '';
    var submit = form.querySelector('button[type=submit], input[type=submit], button:not([type])');
    if (!submit) return '';
    return Snapshot.nameOf({
      tag: submit.tagName.toLowerCase(), type: attribute(submit, 'type'), ariaLabel: attribute(submit, 'aria-label'),
      text: visibleText(submit, null), value: submit.tagName === 'INPUT' ? submit.value : '', title: attribute(submit, 'title')
    });
  }

  function missing(index) {
    return { error: { code: 'no_such_element', message: 'There is no control [' + index + '] on this page now. Read the page again for the current numbers.' } };
  }

  // Facts about a control for the app's permission question. Changes nothing.
  function describe(params) {
    var result = { url: location.href, title: document.title };
    var element = null;
    if (params && params.index !== undefined && params.index !== null) {
      element = elementFor(params.index);
      if (!element) return Object.assign(result, { found: false });
    } else {
      element = deepActiveElement();
    }
    if (!element) return Object.assign(result, { found: false });
    var info = describeElement(element);
    var secret = secretOf(element);
    var tag = element.tagName.toLowerCase();
    var type = (attribute(element, 'type') || '').toLowerCase();
    return Object.assign(result, {
      found: true,
      element: info,
      tag: tag,
      type: type,
      secret: secret ? secret.kind : null,
      isSubmit: (tag === 'button' && (type === 'submit' || (type === '' && !!element.form))) || (tag === 'input' && (type === 'submit' || type === 'image')),
      submitLabel: submitLabelFor(element),
      isFileInput: tag === 'input' && type === 'file',
      href: tag === 'a' ? String(element.href || '') : ''
    });
  }

  function pointInside(rect) {
    var width = window.innerWidth, height = window.innerHeight;
    var left = Math.max(rect.left, 0), right = Math.min(rect.right, width);
    var top = Math.max(rect.top, 0), bottom = Math.min(rect.bottom, height);
    if (right <= left || bottom <= top) return null;
    return { x: Math.round((left + right) / 2), y: Math.round((top + bottom) / 2) };
  }

  function deepElementFromPoint(x, y) {
    var scope = document, offsetX = 0, offsetY = 0, hit = null;
    for (var guard = 0; guard < 20; guard++) {
      var candidate = scope.elementFromPoint(x - offsetX, y - offsetY);
      if (!candidate || candidate === hit) break;
      hit = candidate;
      if (candidate.shadowRoot) { scope = candidate.shadowRoot; continue; }
      if (candidate.tagName === 'IFRAME') {
        var innerDocument = null;
        try { innerDocument = candidate.contentDocument; } catch (denied) { innerDocument = null; }
        if (!innerDocument) break;
        var frameRect = candidate.getBoundingClientRect();
        offsetX += frameRect.left + candidate.clientLeft;
        offsetY += frameRect.top + candidate.clientTop;
        scope = innerDocument;
        continue;
      }
      break;
    }
    return hit;
  }

  function composedContains(ancestor, node) {
    var current = node, guard = 0;
    while (current && guard++ < 200) {
      if (current === ancestor) return true;
      if (current.parentNode) { current = current.parentNode; continue; }
      if (current.host) { current = current.host; continue; }
      if (current.nodeType === 9 && current.defaultView && current.defaultView !== window) {
        try { current = current.defaultView.frameElement; } catch (denied) { return false; }
        continue;
      }
      return false;
    }
    return false;
  }

  // Scrolls the control into view and says where to click it.
  function locate(params) {
    var element = elementFor(params.index);
    if (!element) return missing(params.index);
    if (isDisabled(element)) return { error: { code: 'disabled', message: 'Control [' + params.index + '] is disabled.' } };
    try { element.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); } catch (problem) { element.scrollIntoView(); }
    var rect = topRect(element);
    var point = pointInside(rect);
    var info = describe({ index: params.index });
    info.point = point;
    info.obscured = true;
    if (point) {
      var hit = deepElementFromPoint(point.x, point.y);
      // The click lands on the control, on something inside it, or on its own label.
      info.obscured = !(hit && (composedContains(element, hit) || composedContains(hit, element) && hit.tagName === 'LABEL'));
    }
    return info;
  }

  function domClick(params) {
    var element = elementFor(params.index);
    if (!element) return missing(params.index);
    element.click();
    return { ok: true };
  }

  // ------------------------------------------------------------------ typing

  function isTextEntry(element) {
    var tag = element.tagName;
    if (tag === 'TEXTAREA') return true;
    if (tag === 'INPUT') {
      var type = (attribute(element, 'type') || 'text').toLowerCase();
      return ['text', 'email', 'search', 'tel', 'url', 'number', 'password', 'date', 'datetime-local', 'month', 'time', 'week'].indexOf(type) !== -1;
    }
    return element.isContentEditable === true;
  }

  function needsUser(index, secret) {
    return {
      needs_user: {
        kind: secret.kind,
        what: Secrets.describeKind(secret.kind),
        field: secret.field,
        index: index,
        why: secret.why
      }
    };
  }

  // Focuses a field ready for typing. Refuses private fields.
  function prepareType(params) {
    var element = elementFor(params.index);
    if (!element) return missing(params.index);
    var secret = secretOf(element);
    if (secret) return needsUser(params.index, secret);
    if (!isTextEntry(element)) {
      return { error: { code: 'not_editable', message: 'Control [' + params.index + '] is not a text field.' } };
    }
    if (isDisabled(element) || element.readOnly === true) {
      return { error: { code: 'disabled', message: 'Field [' + params.index + '] is read-only or disabled.' } };
    }
    try { element.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); } catch (problem) { element.scrollIntoView(); }
    element.focus();
    var hadText = false;
    if (element.tagName === 'INPUT' || element.tagName === 'TEXTAREA') {
      hadText = element.value.length > 0;
      if (params.clear !== false) {
        try { element.select(); } catch (problem) { /* number / date inputs have no selection */ }
      } else {
        try { element.setSelectionRange(element.value.length, element.value.length); } catch (problem) { /* same */ }
      }
    } else {
      hadText = (element.textContent || '').length > 0;
      var selection = viewOf(element).getSelection();
      var range = element.ownerDocument.createRange();
      range.selectNodeContents(element);
      if (params.clear === false) range.collapse(false);
      selection.removeAllRanges();
      selection.addRange(range);
    }
    var point = pointInside(topRect(element));
    return { ok: true, point: point, hadText: hadText, focused: deepActiveElement() === element };
  }

  // Did the text arrive? Compares against the field without returning its content.
  function verifyTyped(params) {
    var element = elementFor(params.index);
    if (!element) return { ok: false };
    if (secretOf(element)) return { ok: false };
    var current = element.tagName === 'INPUT' || element.tagName === 'TEXTAREA' ? element.value : (element.innerText || element.textContent || '');
    var expected = String(params.text);
    var normal = function (value) { return String(value).replace(/\s+/g, ' ').trim(); };
    return { ok: expected === '' ? normal(current) === '' : normal(current).indexOf(normal(expected)) !== -1 };
  }

  // Used only when trusted input did not land: sets the value the way frameworks notice.
  function domType(params) {
    var element = elementFor(params.index);
    if (!element) return missing(params.index);
    var secret = secretOf(element);
    if (secret) return needsUser(params.index, secret);
    if (!isTextEntry(element)) return { error: { code: 'not_editable', message: 'Control [' + params.index + '] is not a text field.' } };
    element.focus();
    var value = String(params.text);
    if (element.tagName === 'INPUT' || element.tagName === 'TEXTAREA') {
      var proto = element.tagName === 'INPUT' ? viewOf(element).HTMLInputElement.prototype : viewOf(element).HTMLTextAreaElement.prototype;
      var setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
      setter.call(element, params.clear === false ? element.value + value : value);
    } else {
      if (params.clear === false) element.textContent += value; else element.textContent = value;
    }
    element.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    element.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
    return { ok: true };
  }

  function select(params) {
    var element = elementFor(params.index);
    if (!element) return missing(params.index);
    if (element.tagName !== 'SELECT') {
      return { error: { code: 'not_a_select', message: 'Control [' + params.index + '] is not a drop-down list. Click it and then click the option you want.' } };
    }
    var wanted = text(params.option).toLowerCase();
    var options = Array.prototype.slice.call(element.options);
    var labels = options.map(function (option) { return text(option.textContent); });
    var match = -1, i;
    for (i = 0; i < options.length && match === -1; i++) if (labels[i].toLowerCase() === wanted) match = i;
    for (i = 0; i < options.length && match === -1; i++) if (String(options[i].value).toLowerCase() === wanted) match = i;
    for (i = 0; i < options.length && match === -1; i++) if (wanted && labels[i].toLowerCase().indexOf(wanted) !== -1) match = i;
    if (match === -1 || options[match].disabled) {
      return { error: { code: 'no_such_option', message: 'No option "' + text(params.option, 60) + '". Options: ' + labels.slice(0, 40).join(' | ') } };
    }
    element.focus();
    if (element.multiple) options[match].selected = true; else element.selectedIndex = match;
    element.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    element.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
    return { ok: true, chosen: labels[match] };
  }

  // What has the keyboard right now (for the key-press rules).
  function focusInfo() {
    var element = deepActiveElement();
    if (!element) return { focused: false };
    var secret = secretOf(element);
    return {
      focused: true,
      index: indexFor(element),
      secret: secret ? needsUser(indexFor(element), secret).needs_user : null,
      editable: isTextEntry(element)
    };
  }

  function domKey(params) {
    var target = deepActiveElement() || document.body;
    var init = {
      key: params.key, code: params.code, keyCode: params.keyCode, which: params.keyCode, bubbles: true, cancelable: true, composed: true,
      altKey: !!params.alt, ctrlKey: !!params.ctrl, metaKey: !!params.meta, shiftKey: !!params.shift
    };
    var proceed = target.dispatchEvent(new KeyboardEvent('keydown', init));
    target.dispatchEvent(new KeyboardEvent('keyup', init));
    if (proceed && params.key === 'Enter' && target.form && typeof target.form.requestSubmit === 'function' && target.tagName === 'INPUT') {
      target.form.requestSubmit();
    }
    return { ok: true };
  }

  // --------------------------------------------------------------- scrolling

  function scrollableAncestor(element) {
    var current = element;
    while (current && current !== document.body && current !== document.documentElement) {
      var style = viewOf(current).getComputedStyle(current);
      var scrollsY = /(auto|scroll|overlay)/.test(style.overflowY) && current.scrollHeight > current.clientHeight + 4;
      var scrollsX = /(auto|scroll|overlay)/.test(style.overflowX) && current.scrollWidth > current.clientWidth + 4;
      if (scrollsY || scrollsX) return current;
      current = current.parentElement || (current.getRootNode && current.getRootNode().host) || null;
    }
    return document.scrollingElement || document.documentElement;
  }

  function scroll(params) {
    var direction = String(params.direction || '').toLowerCase();
    var element = null;
    if (params.index !== undefined && params.index !== null) {
      element = elementFor(params.index);
      if (!element) return missing(params.index);
      if (!direction) {
        try { element.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); } catch (problem) { element.scrollIntoView(); }
        return { ok: true, y: Math.round(window.scrollY) };
      }
    }
    var scroller = element ? scrollableAncestor(element) : (document.scrollingElement || document.documentElement);
    var pageY = Math.max(120, Math.round((scroller === document.scrollingElement ? window.innerHeight : scroller.clientHeight) * 0.85));
    var pageX = Math.max(120, Math.round((scroller === document.scrollingElement ? window.innerWidth : scroller.clientWidth) * 0.85));
    var amount = Number(params.amount) > 0 ? Number(params.amount) : 1;
    var before = { top: scroller.scrollTop, left: scroller.scrollLeft };
    switch (direction) {
      case 'down': scroller.scrollBy({ top: pageY * amount, behavior: 'instant' }); break;
      case 'up': scroller.scrollBy({ top: -pageY * amount, behavior: 'instant' }); break;
      case 'right': scroller.scrollBy({ left: pageX * amount, behavior: 'instant' }); break;
      case 'left': scroller.scrollBy({ left: -pageX * amount, behavior: 'instant' }); break;
      case 'top': scroller.scrollTo({ top: 0, behavior: 'instant' }); break;
      case 'bottom': scroller.scrollTo({ top: scroller.scrollHeight, behavior: 'instant' }); break;
      default:
        return { error: { code: 'bad_params', message: 'direction must be up, down, left, right, top or bottom.' } };
    }
    return {
      ok: true,
      moved: scroller.scrollTop !== before.top || scroller.scrollLeft !== before.left,
      y: Math.round(scroller.scrollTop),
      atEnd: scroller.scrollTop + scroller.clientHeight >= scroller.scrollHeight - 2
    };
  }

  // ----------------------------------------------------------------- waiting

  function check(params) {
    var result = { readyState: document.readyState, url: location.href };
    if (params.load) {
      var want = String(params.load);
      result.met = want === 'interactive' ? document.readyState !== 'loading' : document.readyState === 'complete';
      return result;
    }
    if (params.text) {
      var haystack = (document.body ? document.body.innerText : '') || '';
      result.met = haystack.toLowerCase().indexOf(String(params.text).toLowerCase()) !== -1;
      return result;
    }
    if (params.selector) {
      try {
        var match = document.querySelector(String(params.selector));
        result.met = !!match && match.getClientRects().length > 0;
      } catch (problem) {
        result.error = { code: 'bad_params', message: 'Not a valid CSS selector: ' + text(params.selector, 80) };
      }
      return result;
    }
    if (params.element) {
      var wanted = String(params.element).toLowerCase();
      var entries = collect();
      result.met = false;
      for (var i = 0; i < entries.length; i++) {
        var described = Snapshot.describe(descriptorFor(entries[i]));
        if (described.name.toLowerCase().indexOf(wanted) !== -1) { result.met = true; result.index = described.index; result.line = described.line; break; }
      }
      return result;
    }
    if (params.url_contains) {
      result.met = location.href.toLowerCase().indexOf(String(params.url_contains).toLowerCase()) !== -1;
      return result;
    }
    result.error = { code: 'bad_params', message: 'Give one of: load, text, selector, element, url_contains.' };
    return result;
  }

  function settled() {
    return { quietFor: Date.now() - state.lastMutation, readyState: document.readyState, documentId: state.documentId };
  }

  // ---------------------------------------------------------------- presence

  var BLUE = '10, 132, 255';

  function showPresence(params) {
    var stale = document.querySelectorAll('teachy-presence');
    for (var i = 0; i < stale.length; i++) if (!state.presence || stale[i] !== state.presence.host) stale[i].remove();
    if (state.presence && state.presence.host.isConnected) return { ok: true };

    var host = document.createElement('teachy-presence');
    host.setAttribute('aria-hidden', 'true');
    host.style.cssText = 'all: initial; position: fixed; inset: 0; pointer-events: none; z-index: 2147483647; display: block;';
    var shadow = host.attachShadow({ mode: 'closed' });

    var glow = document.createElement('div');
    glow.style.cssText = 'position: fixed; inset: 0; pointer-events: none; border-radius: 0;' +
      'box-shadow: inset 0 0 0 2px rgba(' + BLUE + ', 0.55), inset 0 0 26px 4px rgba(' + BLUE + ', 0.32);';
    shadow.appendChild(glow);
    var reduceMotion = false;
    try { reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches; } catch (ignored) { /* no matchMedia */ }
    if (!reduceMotion && glow.animate) {
      glow.animate([{ opacity: 0.55 }, { opacity: 1 }, { opacity: 0.55 }], { duration: 2600, iterations: Infinity, easing: 'ease-in-out' });
    }

    var cursor = document.createElement('div');
    cursor.style.cssText = 'position: fixed; left: 0; top: 0; width: 22px; height: 22px; pointer-events: none; opacity: 0;' +
      'transform: translate(' + Math.round(window.innerWidth / 2) + 'px, ' + Math.round(window.innerHeight / 2) + 'px);' +
      'transition: transform 220ms cubic-bezier(0.2, 0.8, 0.2, 1), opacity 160ms ease;' +
      'filter: drop-shadow(0 1px 2px rgba(0, 0, 0, 0.35));';
    var svgNamespace = 'http://www.w3.org/2000/svg';
    var svg = document.createElementNS(svgNamespace, 'svg');
    svg.setAttribute('viewBox', '0 0 22 22');
    svg.setAttribute('width', '22');
    svg.setAttribute('height', '22');
    var arrow = document.createElementNS(svgNamespace, 'path');
    arrow.setAttribute('d', 'M3 2 L3 17 L7.2 13.2 L10 19.5 L12.6 18.3 L9.8 12.2 L15.5 12 Z');
    arrow.setAttribute('fill', 'rgb(' + BLUE + ')');
    arrow.setAttribute('stroke', 'white');
    arrow.setAttribute('stroke-width', '1.4');
    arrow.setAttribute('stroke-linejoin', 'round');
    svg.appendChild(arrow);
    cursor.appendChild(svg);
    shadow.appendChild(cursor);

    (document.documentElement || document.body).appendChild(host);
    state.presence = { host: host, glow: glow, cursor: cursor, showCursor: !(params && params.cursor === false) };
    return { ok: true };
  }

  function moveCursor(params) {
    if (!state.presence || !state.presence.host.isConnected) showPresence({});
    var presence = state.presence;
    if (!presence.showCursor) return { ok: true, shown: false };
    presence.cursor.style.opacity = '1';
    // The arrow's tip is at (3, 2) of its box.
    presence.cursor.style.transform = 'translate(' + (Math.round(params.x) - 3) + 'px, ' + (Math.round(params.y) - 2) + 'px)';
    if (params.press && presence.cursor.animate) {
      presence.cursor.animate([{ scale: '1' }, { scale: '0.82' }, { scale: '1' }], { duration: 220, delay: 200 });
    }
    return { ok: true, shown: true };
  }

  function hidePresence() {
    var all = document.querySelectorAll('teachy-presence');
    for (var i = 0; i < all.length; i++) all[i].remove();
    if (state.presence) state.presence.host.remove();
    state.presence = null;
    return { ok: true };
  }

  // Before a screenshot: hide our own glow and blur private fields. After: undo.
  function mask(params) {
    if (params.on) {
      if (state.presence) state.presence.host.style.display = 'none';
      var entries = collect();
      for (var i = 0; i < entries.length; i++) {
        var element = entries[i].element;
        var secret = secretOf(element);
        if (secret && secret.kind !== 'password') {
          state.masked.push({ element: element, filter: element.style.getPropertyValue('filter'), priority: element.style.getPropertyPriority('filter') });
          element.style.setProperty('filter', 'blur(7px)', 'important');
        }
      }
      return { ok: true, masked: state.masked.length, width: window.innerWidth, height: window.innerHeight, scale: window.devicePixelRatio || 1 };
    }
    for (var m = 0; m < state.masked.length; m++) {
      var saved = state.masked[m];
      if (saved.filter) saved.element.style.setProperty('filter', saved.filter, saved.priority); else saved.element.style.removeProperty('filter');
    }
    state.masked = [];
    if (state.presence) state.presence.host.style.display = 'block';
    return { ok: true };
  }

  function expectEscape() {
    state.ignoreEscapeUntil = Date.now() + 800;
    return { ok: true };
  }

  // ------------------------------------------------------------------ wiring

  function notify(message) {
    try {
      if (typeof globalThis.__teachyNotify === 'function') globalThis.__teachyNotify(JSON.stringify(message));
    } catch (ignored) { /* the binding went away with the debugger */ }
  }

  // Escape on the page takes it back from the job.
  function onKeyDown(keyEvent) {
    if (keyEvent.key !== 'Escape' || !keyEvent.isTrusted) return;
    if (Date.now() < state.ignoreEscapeUntil) return;
    if (!state.presence) return;
    notify({ event: 'escape' });
  }
  window.addEventListener('keydown', onKeyDown, true);

  try {
    new MutationObserver(function () { state.lastMutation = Date.now(); })
      .observe(document.documentElement, { childList: true, subtree: true, attributes: true, characterData: true });
  } catch (ignored) { /* no document element yet */ }

  var methods = {
    snapshot: snapshot, describe: describe, locate: locate, domClick: domClick,
    prepareType: prepareType, verifyTyped: verifyTyped, domType: domType, select: select,
    focusInfo: focusInfo, domKey: domKey, scroll: scroll, check: check, settled: settled,
    showPresence: showPresence, moveCursor: moveCursor, hidePresence: hidePresence, mask: mask,
    expectEscape: expectEscape,
    ping: function () { return { ok: true, documentId: state.documentId }; }
  };

  globalThis.__teachyAgent = {
    call: function (method, params) {
      var handler = methods[method];
      if (!handler) return { error: { code: 'unknown_method', message: 'No page method ' + method } };
      try {
        return handler(params || {});
      } catch (problem) {
        return { error: { code: 'page_error', message: String(problem && problem.message ? problem.message : problem) } };
      }
    },
    // For DOM.setFileInputFiles: the service worker asks for the element itself.
    element: function (index) { return elementFor(index); }
  };
})();
