// Readable text of a page: find the main content, drop the navigation, ads,
// scripts and form chrome around it, and turn what is left into plain text
// with light structure ("# Heading", "- item").
//
//   extract(rootNode, options) -> { text, truncated, source }
//
// It works on anything shaped like a DOM node, so the same code runs on the
// real page and, in the tests, on plain objects:
//
//   node.nodeType   1 = element, 3 = text
//   node.tagName    element name (any case)
//   node.childNodes array-like of nodes
//   node.nodeValue  the text of a text node
//   node.getAttribute(name)
//
// options.childrenOf(node) can replace childNodes (the page uses it to walk
// into shadow roots, slots and same-origin iframes); options.isHidden(node)
// can add a computed-style check. No DOM globals are touched here.
(function (root) {
  'use strict';

  var SKIP = {
    script: 1, style: 1, noscript: 1, template: 1, svg: 1, canvas: 1, video: 1, audio: 1,
    object: 1, embed: 1, head: 1, link: 1, meta: 1, map: 1,
    button: 1, select: 1, input: 1, textarea: 1, datalist: 1, dialog: 0
  };
  // Page furniture: skipped unless it is all there is.
  var FURNITURE_TAGS = { nav: 1, aside: 1, footer: 1, header: 1, form: 0 };
  var FURNITURE_ROLES = { navigation: 1, banner: 1, contentinfo: 1, complementary: 1, search: 1, menu: 1, menubar: 1, toolbar: 1, dialog: 0 };
  var FURNITURE_HINT = /(^|[\s_-])(nav|navbar|menu|sidebar|footer|cookie|consent|banner|advert|ads?|promo|breadcrumbs?|share|social|related|newsletter)([\s_-]|$)/i;

  var BLOCK = {
    address: 1, article: 1, aside: 1, blockquote: 1, body: 1, dd: 1, details: 1, div: 1, dl: 1, dt: 1,
    fieldset: 1, figcaption: 1, figure: 1, footer: 1, form: 1, h1: 1, h2: 1, h3: 1, h4: 1, h5: 1, h6: 1,
    header: 1, hr: 1, li: 1, main: 1, nav: 1, ol: 1, p: 1, pre: 1, section: 1, summary: 1, table: 1,
    tbody: 1, thead: 1, tfoot: 1, tr: 1, ul: 1
  };
  var CANDIDATE = { div: 1, section: 1, article: 1, main: 1, td: 1, body: 1 };

  function tagOf(node) {
    return node && node.nodeType === 1 && node.tagName ? String(node.tagName).toLowerCase() : '';
  }

  function attr(node, name) {
    if (!node || typeof node.getAttribute !== 'function') return '';
    var value = node.getAttribute(name);
    return value === null || value === undefined ? '' : String(value);
  }

  function makeWalker(options) {
    var childrenOf = options && options.childrenOf;
    var extraHidden = options && options.isHidden;
    return {
      children: function (node) {
        var list = childrenOf ? childrenOf(node) : node.childNodes;
        return list || [];
      },
      hidden: function (node) {
        if (node.nodeType !== 1) return false;
        if (typeof node.hasAttribute === 'function' && node.hasAttribute('hidden')) return true;
        if (attr(node, 'aria-hidden') === 'true') return true;
        var style = attr(node, 'style').toLowerCase().replace(/\s+/g, '');
        if (style.indexOf('display:none') !== -1 || style.indexOf('visibility:hidden') !== -1) return true;
        return extraHidden ? !!extraHidden(node) : false;
      }
    };
  }

  // insideContent: we are already inside <main> / <article>, where a <header>
  // or <footer> is the piece's own headline or byline, not the site's.
  function isFurniture(node, insideContent) {
    var tag = tagOf(node);
    if (insideContent && (tag === 'header' || tag === 'footer')) return false;
    if (FURNITURE_TAGS[tag]) return true;
    var role = attr(node, 'role').toLowerCase();
    if (role && FURNITURE_ROLES[role]) return true;
    var hint = attr(node, 'class') + ' ' + attr(node, 'id');
    return hint.length > 1 && FURNITURE_HINT.test(hint);
  }

  function isContentRoot(node) {
    var tag = tagOf(node);
    return tag === 'main' || tag === 'article' || attr(node, 'role').toLowerCase() === 'main';
  }

  // Characters of text under a node, and how many of them sit inside links.
  function measure(node, walker, insideLink, totals) {
    if (node.nodeType === 3) {
      var length = String(node.nodeValue || '').replace(/\s+/g, ' ').trim().length;
      totals.text += length;
      if (insideLink) totals.link += length;
      return;
    }
    if (node.nodeType !== 1) return;
    var tag = tagOf(node);
    if (SKIP[tag] || walker.hidden(node)) return;
    var children = walker.children(node);
    var linked = insideLink || tag === 'a';
    for (var i = 0; i < children.length; i++) measure(children[i], walker, linked, totals);
  }

  // Picks the element that holds the article / main content.
  function findMain(rootNode, walker) {
    var explicit = [];
    var best = null;

    (function visit(node, depth, inFurniture, insideContent) {
      if (node.nodeType !== 1 || depth > 60) return;
      var tag = tagOf(node);
      if (SKIP[tag] || walker.hidden(node)) return;
      var furniture = inFurniture || isFurniture(node, insideContent);
      var content = insideContent || isContentRoot(node);

      if (!furniture) {
        if (tag === 'main' || attr(node, 'role').toLowerCase() === 'main' || tag === 'article') {
          var totals = { text: 0, link: 0 };
          measure(node, walker, false, totals);
          explicit.push({ node: node, text: totals.text, isMain: tag !== 'article' });
        } else if (CANDIDATE[tag]) {
          // Score = text in this element's own paragraphs, penalised by link density.
          var own = { text: 0, link: 0 };
          var paragraphs = 0;
          var children = walker.children(node);
          for (var i = 0; i < children.length; i++) {
            var child = children[i];
            var childTag = tagOf(child);
            if (child.nodeType === 3 || childTag === 'p' || childTag === 'pre' || childTag === 'blockquote' ||
                childTag === 'ul' || childTag === 'ol' || /^h[1-6]$/.test(childTag) || childTag === 'br' || !BLOCK[childTag]) {
              var before = own.text;
              measure(child, walker, false, own);
              if (childTag === 'p' && own.text - before > 40) paragraphs++;
            }
          }
          var density = own.text ? own.link / own.text : 1;
          var score = own.text * (1 - density) + paragraphs * 60;
          if (own.text >= 140 && density < 0.5 && (!best || score > best.score)) best = { node: node, score: score };
        }
      }

      var kids = walker.children(node);
      for (var k = 0; k < kids.length; k++) visit(kids[k], depth + 1, furniture, content);
    })(rootNode, 0, false, false);

    // <main> (or role=main) wins; then the largest <article>; then the best scoring block.
    var mains = explicit.filter(function (e) { return e.isMain && e.text >= 80; });
    if (mains.length) {
      mains.sort(function (a, b) { return b.text - a.text; });
      return { node: mains[0].node, source: 'main' };
    }
    var articles = explicit.filter(function (e) { return !e.isMain && e.text >= 200; });
    if (articles.length === 1) return { node: articles[0].node, source: 'article' };
    if (articles.length > 1) return { node: null, source: 'page' }; // a feed: keep the whole page
    if (best) return { node: best.node, source: 'content' };
    return { node: null, source: 'page' };
  }

  function render(rootNode, walker, skipFurniture) {
    var out = [];
    var listDepth = 0;

    function text(value) { out.push(value); }
    function breakLine() { out.push('\n'); }

    (function visit(node, depth, isRoot, insideContent) {
      if (node.nodeType === 3) {
        var value = String(node.nodeValue || '').replace(/\s+/g, ' ');
        if (value) text(value);
        return;
      }
      if (node.nodeType !== 1 || depth > 80) return;
      var tag = tagOf(node);
      if (SKIP[tag] || walker.hidden(node)) return;
      if (!isRoot && skipFurniture && isFurniture(node, insideContent)) return;
      var content = insideContent || isContentRoot(node);

      if (tag === 'br') { breakLine(); return; }
      if (tag === 'hr') { breakLine(); text('---'); breakLine(); return; }
      if (tag === 'img') {
        var alt = attr(node, 'alt').replace(/\s+/g, ' ').trim();
        if (alt) text('[image: ' + alt + ']');
        return;
      }

      var block = !!BLOCK[tag];
      var heading = /^h[1-6]$/.test(tag) ? Number(tag.charAt(1)) : 0;
      if (block) breakLine();
      if (heading) text(new Array(heading + 1).join('#') + ' ');
      if (tag === 'li') text(new Array(listDepth).join('  ') + '- ');
      if (tag === 'ul' || tag === 'ol') listDepth++;

      var children = walker.children(node);
      for (var i = 0; i < children.length; i++) {
        visit(children[i], depth + 1, false, content);
        var childTag = tagOf(children[i]);
        if ((childTag === 'td' || childTag === 'th') && i < children.length - 1) text(' | ');
      }

      if (tag === 'ul' || tag === 'ol') listDepth--;
      if (block) breakLine();
      if (heading || tag === 'p') breakLine();
    })(rootNode, 0, true, false);

    return tidy(out.join(''));
  }

  function tidy(raw) {
    var lines = raw.split('\n');
    var result = [];
    var blank = 0;
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].replace(/[ \t ]+/g, ' ').trim();
      if (!line) {
        blank++;
        if (blank === 1 && result.length) result.push('');
        continue;
      }
      blank = 0;
      result.push(line);
    }
    while (result.length && result[result.length - 1] === '') result.pop();
    return result.join('\n');
  }

  function extract(rootNode, options) {
    options = options || {};
    var maxChars = options.maxChars || 12000;
    if (!rootNode) return { text: '', truncated: 0, source: 'empty' };
    var walker = makeWalker(options);

    var main = findMain(rootNode, walker);
    var source = main.source;
    var text = main.node ? render(main.node, walker, true) : '';

    if (text.length < 200) {
      // No clear main block, or a tiny one: the whole page without its furniture…
      var whole = render(rootNode, walker, true);
      if (whole.length > text.length) { text = whole; source = 'page'; }
    }
    if (text.length < 80) {
      // …and if the page is nothing but furniture (a menu page, a sign-in box), take it all.
      var everything = render(rootNode, walker, false);
      if (everything.length > text.length) { text = everything; source = 'everything'; }
    }

    var truncated = 0;
    if (text.length > maxChars) {
      truncated = text.length - maxChars;
      var cut = text.lastIndexOf('\n', maxChars);
      if (cut < maxChars * 0.8) cut = maxChars;
      truncated = text.length - cut;
      text = text.slice(0, cut) + '\n… (' + truncated + ' more characters; scroll and read again for the rest)';
    }
    return { text: text, truncated: truncated, source: source };
  }

  var api = { extract: extract, findMain: findMain, tidy: tidy };
  root.TeachyReadable = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
