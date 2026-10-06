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
    if (!m) return [null, src];
    return [m[1], src.slice(m[0].length)];
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

  function render(src, baseURL) {
    lastSource = src;
    base = baseURL || '';
    const [fm, body] = splitFrontMatter(src);
    blockSources = [];
    let html;
    try {
      html = md.parse(body);
    } catch (e) {
      html = `<pre class="render-error">${esc(e.message || e)}</pre>`;
    }
    html = DOMPurify.sanitize((fm !== null ? renderFrontMatter(fm) : '') + html, {
      ADD_ATTR: ['data-footnote-ref', 'data-footnote-backref', 'data-footnotes'],
    });
    content.innerHTML = html;

    content.querySelectorAll('img[src], video[src], source[src]').forEach((el) => {
      const s = el.getAttribute('src');
      if (!isAbsolute(s)) el.setAttribute('src', resolve(s));
    });

    const maths = content.querySelectorAll('.math');
    if (maths.length) ensure('katex').then(() => renderMath(content.querySelectorAll('.math')));
    const diagrams = content.querySelectorAll('.mermaid-block');
    if (diagrams.length) ensure('mermaid').then(() => renderMermaid(content.querySelectorAll('.mermaid-block')));
    else lastMermaid = [];
  }

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
  }

  window.Inkwell = {
    render,
    syncScroll,
    scrollToHeading,
    setOptions,
    html: () => content.innerHTML,
    title: () => { const h = content.querySelector('h1'); return h ? h.textContent.trim() : ''; },
  };

  post({ type: 'ready' });
})();
