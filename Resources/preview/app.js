(function () {
  'use strict';

  const content = document.getElementById('content');
  const darkQuery = window.matchMedia('(prefers-color-scheme: dark)');

  const post = (msg) => {
    try { window.webkit.messageHandlers.inkwell.postMessage(msg); } catch (_) { /* not hosted */ }
  };
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  // Diagram / math sources live here rather than in HTML attributes, which the sanitizer may rewrite.
  let blockSources = [];
  const stash = (text) => blockSources.push(text) - 1;
  const source = (el) => blockSources[Number(el.dataset.block)] || '';

  // ---------- Math ($inline$ and $$display$$) ----------
  const mathBlock = {
    name: 'mathBlock',
    level: 'block',
    start(src) { const m = src.match(/^\$\$/m); return m ? m.index : undefined; },
    tokenizer(src) {
      const m = /^\$\$([\s\S]+?)\$\$[ \t]*(?:\n+|$)/.exec(src);
      if (m) return { type: 'mathBlock', raw: m[0], text: m[1].trim() };
    },
    renderer(t) { return `<div class="math math-display" data-block="${stash(t.text)}"></div>\n`; },
  };
  const mathInline = {
    name: 'mathInline',
    level: 'inline',
    start(src) { const i = src.indexOf('$'); return i < 0 ? undefined : i; },
    tokenizer(src) {
      const m = /^\$(?!\s)((?:\\.|[^\\$\n])+?)(?<!\s)\$(?!\d)/.exec(src);
      if (m) return { type: 'mathInline', raw: m[0], text: m[1] };
    },
    renderer(t) { return `<span class="math math-inline" data-block="${stash(t.text)}"></span>`; },
  };

  // ==highlight==
  const markInline = {
    name: 'mark',
    level: 'inline',
    start(src) { const i = src.indexOf('=='); return i < 0 ? undefined : i; },
    tokenizer(src) {
      const m = /^==(?=\S)([\s\S]*?\S)==(?!=)/.exec(src);
      if (m) return { type: 'mark', raw: m[0], tokens: this.lexer.inlineTokens(m[1]) };
    },
    renderer(t) { return `<mark>${this.parser.parseInline(t.tokens)}</mark>`; },
  };

  // ---------- Markdown engine ----------
  const md = new marked.Marked({ gfm: true });
  md.use(markedGfmHeadingId.gfmHeadingId());
  md.use(markedFootnote());
  md.use(markedAlert());
  md.use({ extensions: [mathBlock, mathInline, markInline] });
  md.use({
    renderer: {
      code({ text, lang }) {
        const language = (lang || '').trim().split(/\s+/)[0].toLowerCase();
        if (language === 'mermaid') return `<div class="mermaid-block" data-block="${stash(text)}"></div>\n`;
        if (language === 'math' || language === 'katex') return `<div class="math math-display" data-block="${stash(text)}"></div>\n`;
        let body;
        if (language && window.hljs && hljs.getLanguage(language)) {
          try { body = hljs.highlight(text, { language, ignoreIllegals: true }).value; } catch (_) { body = esc(text); }
        } else {
          body = esc(text);
        }
        const label = language ? `<span class="code-lang">${esc(language)}</span>` : '';
        return `<div class="code-block">${label}<button class="code-copy" type="button">Copy</button><pre><code class="hljs${language ? ' language-' + esc(language) : ''}">${body}</code></pre></div>\n`;
      },
      checkbox({ checked }) {
        return `<input type="checkbox" class="task"${checked ? ' checked' : ''}> `;
      },
    },
  });

  // ---------- Front matter ----------
  function splitFrontMatter(src) {
    const m = /^---[ \t]*\r?\n([\s\S]*?)\r?\n(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/.exec(src);
    if (!m) return [null, src, 0];
    return [m[1], src.slice(m[0].length), m[0].length];
  }
  function renderFrontMatter(fm) {
    const lines = fm.split(/\r?\n/).filter((l) => l.trim());
    const simple = lines.every((l) => /^[\w.-]+\s*:/.test(l));
    if (simple && lines.length) {
      const rows = lines.map((l) => {
        const i = l.indexOf(':');
        return `<tr><td>${esc(l.slice(0, i).trim())}</td><td>${esc(l.slice(i + 1).trim().replace(/^["']|["']$/g, ''))}</td></tr>`;
      }).join('');
      return `<div class="front-matter"><table>${rows}</table></div>`;
    }
    return `<div class="front-matter"><pre>${esc(fm)}</pre></div>`;
  }

  // ---------- Lazy-loaded heavy libraries ----------
  const loaders = {};
  function loadScript(src) {
    return new Promise((resolve, reject) => {
      const s = document.createElement('script');
      s.src = src; s.onload = resolve; s.onerror = reject;
      document.head.appendChild(s);
    });
  }
  function loadCSS(href) {
    return new Promise((resolve) => {
      const l = document.createElement('link');
      l.rel = 'stylesheet'; l.href = href; l.onload = resolve; l.onerror = resolve;
      document.head.appendChild(l);
    });
  }
  function initMermaid() {
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: 'strict',
      theme: darkQuery.matches ? 'dark' : 'default',
      fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif',
    });
  }
  function ensure(name) {
    if (!loaders[name]) {
      loaders[name] = name === 'katex'
        ? Promise.all([loadCSS('vendor/katex/katex.min.css'), loadScript('vendor/katex/katex.min.js')])
        : loadScript('vendor/mermaid.js').then(initMermaid);
    }
    return loaders[name];
  }

  const mathCache = new Map();
  function renderMath(nodes) {
    nodes.forEach((el) => {
      const display = el.classList.contains('math-display');
      const tex = source(el);
      const key = (display ? 'D' : 'I') + tex;
      let html = mathCache.get(key);
      if (html === undefined) {
        try {
          html = katex.renderToString(tex, { displayMode: display, throwOnError: false, output: 'htmlAndMathml' });
        } catch (e) {
          html = `<span class="render-error">${esc(e.message || e)}</span>`;
        }
        if (mathCache.size > 500) mathCache.clear();
        mathCache.set(key, html);
      }
      el.innerHTML = html;
    });
  }

  const mermaidCache = new Map();
  let mermaidSeq = 0;
  let lastMermaid = [];
  async function renderMermaid(nodes) {
    const list = Array.from(nodes);
    const sources = list.map(source);
    list.forEach((el, i) => {
      const cached = mermaidCache.get(sources[i]);
      if (cached) el.innerHTML = cached;
      else if (lastMermaid[i]) { el.innerHTML = lastMermaid[i]; el.style.opacity = '0.55'; }
    });
    for (let i = 0; i < list.length; i++) {
      const el = list[i];
      const src = sources[i];
      let svg = mermaidCache.get(src);
      if (!svg) {
        const id = 'inkwell-mermaid-' + (++mermaidSeq);
        try {
          svg = (await mermaid.render(id, src)).svg;
        } catch (e) {
          svg = `<pre class="render-error">Mermaid: ${esc((e && e.message) || e)}</pre>`;
          const stray = document.getElementById('d' + id);
          if (stray) stray.remove();
        }
        if (mermaidCache.size > 100) mermaidCache.clear();
        mermaidCache.set(src, svg);
      }
      if (el.isConnected) { el.innerHTML = svg; el.style.opacity = ''; }
    }
    lastMermaid = sources.map((src) => mermaidCache.get(src) || '');
  }

  // ---------- Rendering ----------
  let base = '';
  let lastSource = '';
  const isAbsolute = (u) => /^[a-z][a-z0-9+.-]*:/i.test(u) || u.startsWith('//');
  function resolve(u) {
    if (!u || isAbsolute(u) || u.startsWith('#') || !base) return u;
    try { return new URL(u, base).href; } catch (_) { return u; }
  }

  // The document is rendered one top-level "group" at a time so every block in the preview knows
  // which slice of the Markdown source it came from. Editing a block rewrites only that slice.
  let groups = [];      // { start, end, type, editable, bullet, delimiter } in `norm` offsets
  let snapshot = [];    // top-level elements: { el, lo, hi } = the group range each one renders
  let norm = '';        // the source with \n line endings
  let crlf = false;

  const EDITABLE_TYPES = new Set(['paragraph', 'heading', 'list', 'blockquote', 'table', 'hr', 'code', 'alert', 'text']);
  const INVISIBLE_TYPES = new Set(['footnote', 'def', 'footnotes']);
  const VOID_TAGS = /^(area|base|br|col|embed|hr|img|input|link|meta|source|track|wbr)$/i;
  function htmlDepth(html) {
    let depth = 0;
    const re = /<(\/?)([a-zA-Z][\w-]*)\b[^>]*?(\/?)>/g;
    let m;
    while ((m = re.exec(html))) {
      if (VOID_TAGS.test(m[2]) || m[3]) continue;
      depth += m[1] ? -1 : 1;
    }
    return depth;
  }

  // Splits `body` into top-level groups. Raw HTML that spans several tokens (e.g. <details>) stays one group.
  function lexGroups(body, offset) {
    markedGfmHeadingId.resetHeadings();
    // The footnote extension numbers references with a counter that only its renderer resets.
    try { md.parser([{ type: 'footnoteRef', raw: '', index: 0, id: '', label: '' }]); } catch (_) { /* ignore */ }
    const tokens = md.lexer(body);
    md.walkTokens(tokens, md.defaults.walkTokens);
    const out = [];
    let cursor = 0;
    let open = null;
    let depth = 0;
    // The footnotes extension parks an empty "footnotes" token at the front when there are none.
    const list = tokens.filter((t) => t.type !== 'footnotes' || (t.items && t.items.length));
    for (const t of list) {
      let start = -1;
      if (t.raw && t.type !== 'footnotes') {
        start = body.indexOf(t.raw, cursor);
        if (start >= 0) cursor = start + t.raw.length;
      }
      if (t.type === 'space') { if (open) open.tokens.push(t); continue; }
      const s = start >= 0 ? start : (t.type === 'footnotes' ? body.length : cursor);
      const e = start >= 0 ? start + t.raw.replace(/\s+$/, '').length : s;
      if (open) {
        open.tokens.push(t);
        open.end = Math.max(open.end, e);
        if (t.type === 'html') depth += htmlDepth(t.raw);
        if (depth <= 0) { out.push(open); open = null; }
        continue;
      }
      if (t.type === 'html' && (depth = htmlDepth(t.raw)) > 0) {
        open = { tokens: [t], start: s, end: e, type: 'html' };
        continue;
      }
      out.push({ tokens: [t], start: s, end: e, type: t.type });
    }
    if (open) out.push(open);
    for (const g of out) {
      g.start += offset;
      g.end += offset;
      const first = g.tokens[0];
      g.editable = EDITABLE_TYPES.has(g.type) &&
        !(g.type === 'code' && /^(mermaid|math|katex)\b/i.test((first.lang || '').trim()));
      if (g.type === 'list') {
        const m = /^\s*(?:([*+-])|\d+([.)]))/.exec(first.raw);
        if (m) { g.bullet = m[1]; g.delimiter = m[2]; }
      }
    }
    return out;
  }

  function buildGroups(text) {
    const [fm, body, fmLen] = splitFrontMatter(text);
    const list = [];
    if (fm !== null) list.push({ start: 0, end: text.slice(0, fmLen).trimEnd().length, type: 'frontmatter', editable: false, fm });
    return list.concat(lexGroups(body, fmLen));
  }

  function unwrapGroups() {
    for (const w of Array.from(content.children)) {
      if (!w.classList.contains('ink-b')) continue;
      const g = groups[Number(w.dataset.b)];
      let hi = Number(w.dataset.b);
      w.querySelectorAll('.ink-b').forEach((inner) => {
        hi = Math.max(hi, Number(inner.dataset.b));
        inner.replaceWith(...inner.childNodes);
      });
      for (const n of Array.from(w.childNodes)) {
        if (n.nodeType === 3 && !n.nodeValue.trim()) { n.remove(); continue; }
        let el = n;
        if (n.nodeType !== 1) {
          el = document.createElement('div');
          n.replaceWith(el);
          el.appendChild(n);
        }
        el.dataset.b = w.dataset.b;
        if (hi !== Number(w.dataset.b)) el.dataset.hi = String(hi);
        if (!g || !g.editable || hi !== Number(w.dataset.b)) el.contentEditable = 'false';
      }
      w.replaceWith(...w.childNodes);
    }
  }

  const READ_ONLY = '.code-copy, .code-lang, .math, .mermaid-block, .markdown-alert-title, input.task, ' +
    'sup:has(> a[data-footnote-ref]), section[data-footnotes], hr[data-footnotes], .front-matter';

  function render(src, baseURL) {
    const caret = isEditing() ? saveCaret() : null;
    cancelSync();
    lastSource = src;
    base = baseURL || '';
    crlf = src.includes('\r\n');
    norm = src.replace(/\r\n?/g, '\n');
    blockSources = [];
    let html = '';
    renderOK = true;
    try {
      groups = buildGroups(norm);
      groups.forEach((g, i) => {
        const part = g.type === 'frontmatter' ? renderFrontMatter(g.fm) : md.parser(g.tokens);
        html += `<div class="ink-b" data-b="${i}">${part}</div>`;
        delete g.tokens;
      });
    } catch (e) {
      renderOK = false;
      groups = [];
      html = `<pre class="render-error">${esc(e.message || e)}</pre>`;
    }
    html = DOMPurify.sanitize(html, {
      ADD_ATTR: ['data-footnote-ref', 'data-footnote-backref', 'data-footnotes'],
    });
    suppress = true;
    content.innerHTML = html;
    unwrapGroups();

    content.querySelectorAll('img[src], video[src], source[src]').forEach((el) => {
      const s = el.getAttribute('src');
      if (!isAbsolute(s)) { el.dataset.src = s; el.setAttribute('src', resolve(s)); }
    });
    content.querySelectorAll(READ_ONLY).forEach((el) => { el.contentEditable = 'false'; });
    snapshot = Array.from(content.children).map((el) => {
      const lo = Number(el.dataset.b);
      return { el, lo, hi: el.dataset.hi ? Number(el.dataset.hi) : lo };
    });
    observer.takeRecords();
    suppress = false;
    touched.clear();
    structural = false;
    dirtyDOM = false;
    applyEditable();
    if (caret) restoreCaret(caret);

    const maths = content.querySelectorAll('.math');
    if (maths.length) ensure('katex').then(() => renderMath(content.querySelectorAll('.math')));
    const diagrams = content.querySelectorAll('.mermaid-block');
    if (diagrams.length) ensure('mermaid').then(() => renderMermaid(content.querySelectorAll('.mermaid-block')));
    else lastMermaid = [];
  }

  // ---------- Editing in the preview ----------
  const toMarkdown = InkwellToMarkdown({ source });
  let editable = false;
  let renderOK = true;
  const touched = new Set();
  let structural = false;
  let suppress = false;
  let dirtyDOM = false;
  let composing = false;
  let syncTimer = null;
  let savedRange = null;

  const isEditing = () => editable && document.activeElement === content;
  const topLevel = (n) => { while (n && n.parentNode !== content) n = n.parentNode; return n; };

  function applyEditable() {
    const on = editable && renderOK;
    content.contentEditable = on ? 'true' : 'false';
    document.body.classList.toggle('editable', on);
  }

  function noteMutations(records) {
    if (suppress) return false;
    let user = false;
    for (const r of records) {
      if (r.target === content) { structural = true; user = true; continue; }
      const el = r.target.nodeType === 1 ? r.target : r.target.parentElement;
      if (el && el.closest('.math, .mermaid-block, .code-copy')) continue;
      const top = topLevel(r.target);
      if (top) { touched.add(top); user = true; }
    }
    if (user && editable) dirtyDOM = true;
    return user && editable;
  }
  const observer = new MutationObserver((records) => {
    if (noteMutations(records)) scheduleSync();
  });
  observer.observe(content, { childList: true, characterData: true, subtree: true });

  function scheduleSync() {
    clearTimeout(syncTimer);
    syncTimer = setTimeout(syncEdits, 200);
  }
  function cancelSync() {
    clearTimeout(syncTimer);
    syncTimer = null;
  }

  // Wraps stray top-level text / inline nodes (typed into an empty document, say) in a paragraph.
  function normalizeTopLevel() {
    const sel = window.getSelection();
    const anchor = sel.rangeCount ? [sel.anchorNode, sel.anchorOffset] : null;
    let p = null;
    for (const n of Array.from(content.childNodes)) {
      const blank = n.nodeType === 3 && !n.nodeValue.trim();
      const inline = (n.nodeType === 3 && !blank) || (n.nodeType === 1 && !toMarkdown.isBlock(n));
      if (blank) { if (p) p.appendChild(n); continue; }
      if (inline) {
        if (!p) { p = document.createElement('p'); content.insertBefore(p, n); touched.add(p); }
        p.appendChild(n);
      } else {
        p = null;
      }
    }
    if (anchor && anchor[0] && anchor[0].isConnected) {
      try { sel.collapse(anchor[0], anchor[1]); } catch (_) { /* ignore */ }
    }
  }

  const same = (x, y) => x.lo === y.lo && x.hi === y.hi;
  const DEF_LINE = /^ {0,3}\[(?!\^)[^\]]+\]:\s*\S/;

  // Turns the changed top-level blocks back into Markdown and sends the new source to the app.
  function syncEdits() {
    cancelSync();
    noteMutations(observer.takeRecords());
    if (composing || !editable || !renderOK || (!touched.size && !structural)) return;
    normalizeTopLevel();
    observer.takeRecords();
    const dirty = new Set(touched);
    touched.clear();
    structural = false;

    const cur = Array.from(content.children);
    const snap = snapshot;
    const entries = new Map(snap.map((s) => [s.el, s]));
    let i = 0;
    while (i < cur.length && i < snap.length && cur[i] === snap[i].el && !dirty.has(cur[i])) i++;
    let a = cur.length;
    let b = snap.length;
    while (a > i && b > i && cur[a - 1] === snap[b - 1].el && !dirty.has(cur[a - 1])) { a--; b--; }
    if (i === a && i === b) return;
    // Never split the elements of one source group across the edit boundary.
    for (;;) {
      let changed = false;
      if (i > 0 && i < snap.length && same(snap[i - 1], snap[i])) { i--; changed = true; }
      if (b > 0 && b < snap.length && a < cur.length && same(snap[b - 1], snap[b])) { b++; a++; changed = true; }
      if (!changed) break;
    }

    // The old group range being replaced: [LO, HI]. HI < LO means a pure insertion before group LO.
    let LO, HI;
    if (b > i) {
      LO = Math.min(...snap.slice(i, b).map((s) => s.lo));
      HI = Math.max(...snap.slice(i, b).map((s) => s.hi));
    } else {
      LO = i > 0 ? snap[i - 1].hi + 1 : (groups[0] && groups[0].type === 'frontmatter' ? 1 : 0);
      HI = LO - 1;
    }

    const pieces = [];
    const units = [];       // per new element: how many visible groups it should produce (null = unknown)
    const reused = new Set();
    for (let k = i; k < a; k++) {
      const el = cur[k];
      const e = entries.get(el);
      const pristine = e && !dirty.has(el) && e.hi >= e.lo &&
        snap.filter((s) => same(s, e)).every((s) => !dirty.has(s.el) && s.el.parentNode === content);
      if (pristine) {
        if (!reused.has(e.lo)) {
          for (let g = e.lo; g <= e.hi; g++) reused.add(g);
          pieces.push(norm.slice(groups[e.lo].start, groups[e.hi].end));
          let visible = 0;
          for (let g = e.lo; g <= e.hi; g++) if (!INVISIBLE_TYPES.has(groups[g].type)) visible++;
          units.push({ els: snap.filter((s) => same(s, e)).map((s) => s.el), count: visible });
        }
        continue;
      }
      const g = e && e.lo === e.hi ? groups[e.lo] : null;
      const out = toMarkdown.block(el, {
        bullet: g && g.bullet, delimiter: g && g.delimiter, raw: g ? norm.slice(g.start, g.end) : '',
      });
      if (out.trim()) pieces.push(out);
      units.push({ els: [el], count: out.trim() ? 1 : 0 });
    }
    // Keep link / footnote definitions that lived inside the replaced range.
    for (let g = LO; g <= HI; g++) {
      if (reused.has(g)) continue;
      const grp = groups[g];
      const raw = norm.slice(grp.start, grp.end);
      if (grp.type === 'footnote' || grp.type === 'def') { if (raw.trim()) pieces.push(raw); }
      else if (grp.type === 'paragraph') {
        const defs = raw.split('\n').filter((l) => DEF_LINE.test(l));
        if (defs.length) pieces.push(defs.join('\n'));
      }
    }

    let text = pieces.join('\n\n');
    let start;
    let end;
    const real = (g) => g && g.type !== 'footnotes';
    if (HI >= LO) {
      start = groups[LO].start;
      end = groups[HI].end;
      if (!text) {
        const next = groups.slice(HI + 1).find(real);
        if (next) {
          end = next.start;
        } else {
          const prev = LO > 0 ? groups[LO - 1] : null;
          start = prev ? prev.end : 0;
          end = norm.length;
          text = start > 0 && norm.endsWith('\n') ? '\n' : '';
        }
      }
    } else if (!text) {
      return;
    } else if (real(groups[LO])) {
      start = end = groups[LO].start;
      text += '\n\n';
    } else {
      const last = groups.slice(0, LO).reverse().find(real);
      if (last) { start = end = last.end; text = '\n\n' + text; }
      else { start = 0; end = norm.length; text += '\n'; }
    }

    const oldGroups = groups;
    const oldNorm = norm;
    norm = norm.slice(0, start) + text + norm.slice(end);
    lastSource = crlf ? norm.replace(/\n/g, '\r\n') : norm;
    post({ type: 'edit', text: lastSource });

    // Re-map the DOM to the new source without re-rendering, so the caret and any empty
    // paragraph the user is typing into stay put.
    try {
      groups = buildGroups(norm);
    } catch (_) {
      render(lastSource, base);
      return;
    }
    const delta = groups.length - oldGroups.length;
    const rawOf = (list, src, g) => (list[g] ? src.slice(list[g].start, list[g].end) : null);
    const stable = (LO === 0 || rawOf(oldGroups, oldNorm, LO - 1) === rawOf(groups, norm, LO - 1)) &&
      (HI + 1 >= oldGroups.length || rawOf(oldGroups, oldNorm, HI + 1) === rawOf(groups, norm, HI + 1 + delta));
    if (!stable) { render(lastSource, base); return; }

    const nLo = LO;
    const nHi = HI + delta;
    const visible = [];
    for (let g = nLo; g <= nHi; g++) if (!INVISIBLE_TYPES.has(groups[g].type)) visible.push(g);
    const expected = units.reduce((n, u) => n + u.count, 0);
    const middle = [];
    if (expected === visible.length) {
      let v = 0;
      for (const u of units) {
        if (u.count === 0) {
          const at = v < visible.length ? visible[v] : nHi + 1;
          u.els.forEach((el) => middle.push({ el, lo: at, hi: at - 1 }));
        } else {
          const lo = visible[v];
          const hi = visible[v + u.count - 1];
          u.els.forEach((el) => middle.push({ el, lo, hi }));
          v += u.count;
        }
      }
    } else {
      units.forEach((u) => u.els.forEach((el) => middle.push({ el, lo: nLo, hi: nHi })));
    }
    const order = new Map(cur.map((el, k) => [el, k]));
    middle.sort((x, y) => order.get(x.el) - order.get(y.el));
    snapshot = snap.slice(0, i)
      .concat(middle)
      .concat(snap.slice(b).map((s) => ({ el: s.el, lo: s.lo + delta, hi: s.hi + delta })));
  }

  // Flushes edits and re-renders, so the preview shows exactly what the Markdown produces.
  function commit() {
    syncEdits();
    if (dirtyDOM) render(lastSource, base);
  }

  // Caret position as (top-level block, number of non-space characters before it).
  function saveCaret() {
    const sel = window.getSelection();
    if (!sel.rangeCount || !content.contains(sel.focusNode)) return null;
    const top = topLevel(sel.focusNode);
    const k = Array.from(content.children).indexOf(top);
    if (k < 0) return null;
    const r = document.createRange();
    r.setStart(top, 0);
    r.setEnd(sel.focusNode, sel.focusOffset);
    const text = r.toString();
    return { k, count: text.replace(/\s/g, '').length, trailing: /[^\S\n]*$/.exec(text)[0].length };
  }
  function restoreCaret(c) {
    const kids = content.children;
    if (!kids.length) return;
    const top = kids[Math.min(c.k, kids.length - 1)];
    const walker = document.createTreeWalker(top, NodeFilter.SHOW_TEXT);
    let remaining = c.count;
    let node = null;
    let offset = 0;
    let n;
    while ((n = walker.nextNode())) {
      if (!node) { node = n; offset = 0; }
      if (remaining === 0) break;
      const s = n.nodeValue;
      for (let i = 0; i < s.length; i++) {
        if (!/\s/.test(s[i]) && --remaining === 0) { node = n; offset = i + 1; break; }
      }
      if (remaining === 0) break;
      node = n; offset = s.length;
    }
    if (node) {
      let t = c.trailing;
      while (t > 0 && offset < node.nodeValue.length && /[^\S\n]/.test(node.nodeValue[offset])) { offset++; t--; }
    }
    const sel = window.getSelection();
    try {
      if (node) sel.collapse(node, offset); else sel.collapse(top, 0);
    } catch (_) { /* ignore */ }
  }

  // ---------- Formatting commands (from the app's Format menu and toolbar) ----------
  const exec = (cmd, arg) => document.execCommand(cmd, false, arg);
  function selectionInside(selector) {
    const sel = window.getSelection();
    if (!sel.rangeCount) return null;
    let n = sel.anchorNode;
    const el = n && (n.nodeType === 1 ? n : n.parentElement);
    const hit = el && el.closest(selector);
    return hit && content.contains(hit) && hit !== content ? hit : null;
  }
  const unwrap = (el) => el.replaceWith(...el.childNodes);

  function toggleInline(tag, placeholder) {
    const existing = selectionInside(tag);
    if (existing) { unwrap(existing); return; }
    const sel = window.getSelection();
    if (!sel.rangeCount) return;
    const range = sel.getRangeAt(0);
    const el = document.createElement(tag);
    if (range.collapsed) el.textContent = placeholder;
    else el.appendChild(range.extractContents());
    range.insertNode(el);
    const r = document.createRange();
    r.selectNodeContents(el);
    sel.removeAllRanges();
    sel.addRange(r);
  }

  function toggleTask() {
    let li = selectionInside('li');
    if (!li) { exec('insertUnorderedList'); li = selectionInside('li'); }
    if (!li) return;
    const box = li.querySelector(':scope > input.task');
    if (box) { box.remove(); return; }
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.className = 'task';
    input.contentEditable = 'false';
    li.insertBefore(input, li.firstChild);
  }

  function command(name, arg) {
    if (!editable || !renderOK) return;
    content.focus();
    if (savedRange) {
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(savedRange);
      savedRange = null;
    }
    switch (name) {
      case 'bold': exec('bold'); break;
      case 'italic': exec('italic'); break;
      case 'strike': exec('strikeThrough'); break;
      case 'mark': toggleInline('mark', 'text'); break;
      case 'code': toggleInline('code', 'code'); break;
      case 'heading': exec('formatBlock', arg ? 'h' + arg : 'p'); break;
      case 'ul': exec('insertUnorderedList'); break;
      case 'ol': exec('insertOrderedList'); break;
      case 'task': toggleTask(); break;
      case 'quote': {
        const q = selectionInside('blockquote');
        if (q) unwrap(q); else exec('formatBlock', 'blockquote');
        break;
      }
      case 'codeblock': exec('formatBlock', 'pre'); break;
      case 'hr': exec('insertHorizontalRule'); break;
      case 'table':
        exec('insertHTML', '<table><thead><tr><th>Column</th><th>Column</th></tr></thead>' +
          '<tbody><tr><td>Cell</td><td>Cell</td></tr></tbody></table><p><br></p>');
        break;
      case 'link': {
        if (!arg) break;
        const sel = window.getSelection();
        if (sel.isCollapsed) exec('insertHTML', `<a href="${esc(arg)}">${esc(arg)}</a>`);
        else exec('createLink', arg);
        break;
      }
      case 'image':
        if (arg) exec('insertHTML', `<img src="${esc(resolve(arg))}" data-src="${esc(arg)}" alt="">`);
        break;
    }
  }

  function saveSelection() {
    const sel = window.getSelection();
    savedRange = sel.rangeCount && content.contains(sel.anchorNode) ? sel.getRangeAt(0).cloneRange() : null;
    return savedRange ? sel.toString() : null;
  }

  content.addEventListener('compositionstart', () => { composing = true; });
  content.addEventListener('compositionend', () => { composing = false; scheduleSync(); });

  content.addEventListener('beforeinput', (e) => {
    if (!editable) return;
    if (e.inputType === 'historyUndo' || e.inputType === 'historyRedo') {
      e.preventDefault();
      syncEdits();
      post({ type: e.inputType === 'historyUndo' ? 'undo' : 'redo' });
    }
  });

  content.addEventListener('keydown', (e) => {
    if (!editable || e.isComposing) return;
    if (e.key === 'Enter' && !e.metaKey) {
      if (selectionInside('pre')) { e.preventDefault(); exec('insertLineBreak'); return; }
      if (selectionInside('td, th')) { e.preventDefault(); return; }
    }
    if (e.key === 'Tab' && !e.metaKey && !e.ctrlKey && !e.altKey) {
      if (selectionInside('pre')) { e.preventDefault(); exec('insertText', '    '); return; }
      if (selectionInside('li')) { e.preventDefault(); exec(e.shiftKey ? 'outdent' : 'indent'); }
    }
  });

  content.addEventListener('paste', (e) => {
    if (!editable) return;
    e.preventDefault();
    const text = e.clipboardData ? e.clipboardData.getData('text/plain') : '';
    if (text) exec('insertText', text);
  });

  content.addEventListener('drop', (e) => {
    if (editable && e.dataTransfer && Array.from(e.dataTransfer.types).includes('Files')) e.preventDefault();
  });

  darkQuery.addEventListener('change', () => {
    if (window.mermaid) { initMermaid(); mermaidCache.clear(); lastMermaid = []; render(lastSource, base); }
  });

  // ---------- Interaction ----------
  document.addEventListener('click', (e) => {
    const copy = e.target.closest('.code-copy');
    if (copy) {
      e.preventDefault();
      const code = copy.parentElement.querySelector('code');
      post({ type: 'copy', text: code ? code.innerText : '' });
      copy.textContent = 'Copied';
      setTimeout(() => { copy.textContent = 'Copy'; }, 1200);
      return;
    }
    const a = e.target.closest('a[href]');
    if (a) {
      e.preventDefault();
      if (editable && !e.metaKey) return;
      const href = a.getAttribute('href');
      if (href.startsWith('#')) {
        const target = document.getElementById(decodeURIComponent(href.slice(1)));
        if (target) target.scrollIntoView({ behavior: 'smooth', block: 'start' });
        return;
      }
      post({ type: 'open', href: resolve(href) });
    }
  });

  content.addEventListener('change', (e) => {
    if (e.target.matches('input.task')) {
      if (editable) {
        // Flush pending edits against the box's previous state, then toggle just this task.
        e.target.checked = !e.target.checked;
        syncEdits();
        e.target.checked = !e.target.checked;
      }
      const all = Array.from(content.querySelectorAll('input.task'));
      post({ type: 'task', index: all.indexOf(e.target), checked: e.target.checked });
    }
  });

  // ---------- Scrolling ----------
  function headings() {
    return Array.from(content.querySelectorAll('h1, h2, h3, h4, h5, h6'))
      .filter((h) => !h.classList.contains('sr-only') && !h.closest('blockquote, li, .footnotes, .markdown-alert, details'));
  }
  const docTop = (el) => el.getBoundingClientRect().top + window.scrollY;
  function maxScroll() { return document.documentElement.scrollHeight - window.innerHeight; }

  function syncScroll(topLine, totalLines, headingLines, atBottom) {
    const H = maxScroll();
    if (H <= 0) return;
    if (atBottom) { window.scrollTo(0, H); return; }
    if (topLine <= 0) { window.scrollTo(0, 0); return; }
    const pts = [[0, 0]];
    const hs = headings();
    if (hs.length === headingLines.length) {
      hs.forEach((h, i) => {
        const y = docTop(h) - 24;
        const prev = pts[pts.length - 1];
        if (headingLines[i] > prev[0] && y >= prev[1]) pts.push([headingLines[i], y]);
      });
    }
    pts.push([Math.max(totalLines, 1), document.documentElement.scrollHeight - window.innerHeight * 0.5]);
    let y = 0;
    for (let i = 0; i < pts.length - 1; i++) {
      const [l0, y0] = pts[i];
      const [l1, y1] = pts[i + 1];
      if (topLine >= l0 && topLine <= l1) { y = y0 + ((topLine - l0) / Math.max(l1 - l0, 1)) * (y1 - y0); break; }
      if (i === pts.length - 2) y = y1;
    }
    window.scrollTo(0, Math.max(0, Math.min(H, y)));
  }

  function scrollToHeading(index, line, totalLines) {
    const hs = headings();
    if (hs[index]) { window.scrollTo({ top: Math.max(0, docTop(hs[index]) - 24), behavior: 'smooth' }); return; }
    window.scrollTo({ top: maxScroll() * (line / Math.max(totalLines, 1)), behavior: 'smooth' });
  }

  function setOptions(o) {
    const root = document.documentElement.style;
    if (o.width) root.setProperty('--content-width', o.width + 'px');
    if (o.fontSize) root.setProperty('--font-size', o.fontSize + 'px');
    if (o.font) document.body.dataset.font = o.font;
    if (typeof o.editable === 'boolean' && o.editable !== editable) {
      if (!o.editable) commit();
      editable = o.editable;
      applyEditable();
    }
  }

  function countMatches(query) {
    if (!query) return 0;
    const hay = content.innerText.toLocaleLowerCase();
    const needle = query.toLocaleLowerCase();
    let n = 0;
    for (let i = hay.indexOf(needle); i >= 0; i = hay.indexOf(needle, i + needle.length)) n++;
    return n;
  }

  // Export / copy without the editing attributes.
  function exportHTML() {
    const clone = content.cloneNode(true);
    clone.querySelectorAll('[contenteditable]').forEach((el) => el.removeAttribute('contenteditable'));
    clone.querySelectorAll('[data-b], [data-hi]').forEach((el) => { el.removeAttribute('data-b'); el.removeAttribute('data-hi'); });
    clone.querySelectorAll('[data-src]').forEach((el) => el.removeAttribute('data-src'));
    return clone.innerHTML;
  }

  window.Inkwell = {
    render,
    syncScroll,
    scrollToHeading,
    setOptions,
    commit,
    command,
    saveSelection,
    countMatches,
    html: () => exportHTML(),
    title: () => { const h = content.querySelector('h1'); return h ? h.textContent.trim() : ''; },
  };

  post({ type: 'ready' });
})();
