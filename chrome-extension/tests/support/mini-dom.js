// A very small HTML parser for the tests: turns a fixture into plain objects
// shaped like DOM nodes (nodeType, tagName, childNodes, nodeValue,
// getAttribute, hasAttribute). No browser, no dependencies. It handles what
// the fixtures use: nested elements, attributes, void elements, comments,
// and raw-text elements (script, style).
'use strict';

const VOID = new Set(['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'source', 'track', 'wbr']);
const RAW = new Set(['script', 'style', 'textarea', 'title']);
const ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: '\'', nbsp: ' ' };

function decode(text) {
  return text.replace(/&(#\d+|#x[0-9a-f]+|[a-z]+);/gi, (whole, name) => {
    if (name[0] === '#') return String.fromCodePoint(name[1].toLowerCase() === 'x' ? parseInt(name.slice(2), 16) : parseInt(name.slice(1), 10));
    return Object.prototype.hasOwnProperty.call(ENTITIES, name.toLowerCase()) ? ENTITIES[name.toLowerCase()] : whole;
  });
}

function element(tag, attributes) {
  return {
    nodeType: 1,
    tagName: tag.toUpperCase(),
    attributes,
    childNodes: [],
    parentNode: null,
    getAttribute(name) { return Object.prototype.hasOwnProperty.call(this.attributes, name) ? this.attributes[name] : null; },
    hasAttribute(name) { return Object.prototype.hasOwnProperty.call(this.attributes, name); }
  };
}

function textNode(value) {
  return { nodeType: 3, nodeValue: value, childNodes: [], parentNode: null };
}

function parseAttributes(source) {
  const attributes = {};
  const pattern = /([^\s=\/>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g;
  let match;
  while ((match = pattern.exec(source))) {
    const value = match[2] !== undefined ? match[2] : match[3] !== undefined ? match[3] : match[4] !== undefined ? match[4] : '';
    attributes[match[1].toLowerCase()] = decode(value);
  }
  return attributes;
}

function parse(html) {
  const root = element('#document', {});
  const stack = [root];
  let position = 0;

  function append(node) {
    const parent = stack[stack.length - 1];
    node.parentNode = parent;
    parent.childNodes.push(node);
  }

  while (position < html.length) {
    const open = html.indexOf('<', position);
    if (open === -1) { append(textNode(decode(html.slice(position)))); break; }
    if (open > position) append(textNode(decode(html.slice(position, open))));

    if (html.startsWith('<!--', open)) {
      const end = html.indexOf('-->', open + 4);
      position = end === -1 ? html.length : end + 3;
      continue;
    }
    if (html[open + 1] === '!' || html[open + 1] === '?') {
      const end = html.indexOf('>', open);
      position = end === -1 ? html.length : end + 1;
      continue;
    }
    const close = html.indexOf('>', open);
    if (close === -1) { append(textNode(html.slice(open))); break; }
    const inner = html.slice(open + 1, close);

    if (inner[0] === '/') {
      const name = inner.slice(1).trim().toLowerCase();
      for (let i = stack.length - 1; i > 0; i--) {
        if (stack[i].tagName.toLowerCase() === name) { stack.length = i; break; }
      }
      position = close + 1;
      continue;
    }

    const nameMatch = /^([a-zA-Z][^\s\/>]*)/.exec(inner);
    if (!nameMatch) { append(textNode('<')); position = open + 1; continue; }
    const tag = nameMatch[1].toLowerCase();
    const selfClosing = /\/\s*$/.test(inner);
    const node = element(tag, parseAttributes(inner.slice(nameMatch[1].length).replace(/\/\s*$/, '')));
    append(node);
    position = close + 1;

    if (RAW.has(tag)) {
      const endTag = html.toLowerCase().indexOf('</' + tag, position);
      const raw = html.slice(position, endTag === -1 ? html.length : endTag);
      if (raw) { const child = textNode(tag === 'script' || tag === 'style' ? raw : decode(raw)); child.parentNode = node; node.childNodes.push(child); }
      const after = endTag === -1 ? html.length : html.indexOf('>', endTag) + 1;
      position = after === 0 ? html.length : after;
      continue;
    }
    if (!VOID.has(tag) && !selfClosing) stack.push(node);
  }
  return root;
}

function find(node, test) {
  if (node.nodeType === 1 && test(node)) return node;
  for (const child of node.childNodes) {
    const hit = find(child, test);
    if (hit) return hit;
  }
  return null;
}

function findAll(node, test, out) {
  out = out || [];
  if (node.nodeType === 1 && test(node)) out.push(node);
  for (const child of node.childNodes) findAll(child, test, out);
  return out;
}

function textOf(node) {
  if (node.nodeType === 3) return node.nodeValue;
  return node.childNodes.map(textOf).join('');
}

module.exports = { parse, find, findAll, textOf };
