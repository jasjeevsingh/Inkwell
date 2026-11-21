// Converts edited preview DOM back into Markdown.
// Only blocks the user actually changed are serialized; everything else keeps its original source.
(function () {
  'use strict';

  const BLOCK_TAGS = new Set([
    'P', 'DIV', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'UL', 'OL', 'LI', 'BLOCKQUOTE', 'PRE', 'TABLE',
    'HR', 'SECTION', 'DETAILS', 'FIGURE', 'DL', 'ARTICLE', 'ASIDE', 'HEADER', 'FOOTER', 'NAV',
  ]);
  const BR = '\u0001';

  const isBlock = (n) => n.nodeType === 1 && BLOCK_TAGS.has(n.tagName);
  const longestRun = (s, ch) => {
    let max = 0, cur = 0;
    for (const c of s) { cur = c === ch ? cur + 1 : 0; if (cur > max) max = cur; }
    return max;
  };
  const isWordChar = (c) => !!c && /[\p{L}\p{N}]/u.test(c);

  function create(opts) {
    const source = opts.source;       // (el) => original math / diagram source

    // ---------- Text escaping ----------
    function escapeText(s, ctx) {
      let out = '';
      for (let i = 0; i < s.length; i++) {
        const c = s[i];
        const next = s[i + 1];
        switch (c) {
          case '\\': case '`': case '*': case '[': case ']': case '$': case '~':
            out += '\\' + c; break;
          case '_':
            out += isWordChar(s[i - 1]) && isWordChar(next) ? '_' : '\\_'; break;
          case '<':
            out += next && /[A-Za-z\/!?]/.test(next) ? '\\<' : '<'; break;
          case '&':
            out += /^&(#\d+|#x[0-9a-f]+|\w+);/i.test(s.slice(i)) ? '\\&' : '&'; break;
          case '=':
            out += next === '=' || s[i - 1] === '=' ? '\\=' : '='; break;
          case '|':
            out += ctx.table ? '\\|' : '|'; break;
          default:
            out += c;
        }
      }
      return out;
    }

    // Escapes characters that would start a block construct at the beginning of a line.
    function escapeLineStarts(text) {
      return text.split('\n').map((line) => {
        line = line.replace(/^[ \t]+/, '');
        if (/^#{1,6}(\s|$)/.test(line)) return '\\' + line;
        if (/^>/.test(line)) return '\\' + line;
        if (/^[-+](\s|$)/.test(line)) return '\\' + line;
        if (/^=+\s*$/.test(line)) return '\\' + line;
        const m = /^(\d{1,9})([.)])(\s|$)/.exec(line);
        if (m) return m[1] + '\\' + line.slice(m[1].length);
        return line;
      }).join('\n');
    }

    // ---------- Inline ----------
    function inline(nodes, ctx) {
      let s = '';
      for (const n of nodes) s += inlineNode(n, ctx);
      return s;
    }

    function wrap(el, marker, ctx) {
      const inner = inline(el.childNodes, ctx);
      const m = new RegExp(`^([\\s${BR}]*)([\\s\\S]*?)([\\s${BR}]*)$`).exec(inner);
      if (!m[2]) return inner;
      return m[1] + marker + m[2] + marker + m[3];
    }

    function codeSpan(text) {
      text = text.replace(/\n/g, ' ');
      if (!text) return '';
      const fence = '`'.repeat(longestRun(text, '`') + 1);
      const pad = /^[` ]|[` ]$/.test(text) ? ' ' : '';
      return fence + pad + text + pad + fence;
    }

    const linkDest = (url) => (/[\s()<>]/.test(url) ? '<' + url.replace(/>/g, '%3E') + '>' : url);
    const linkTitle = (t) => (t ? ' "' + t.replace(/"/g, '\\"') + '"' : '');

    function inlineNode(n, ctx) {
      if (n.nodeType === 3) {
        let t = n.nodeValue.replace(/ /g, ' ').replace(/​/g, '');
        t = ctx.singleLine ? t.replace(/\s+/g, ' ') : t.replace(/[ \t\r\f]+/g, ' ');
        return escapeText(t, ctx);
      }
      if (n.nodeType !== 1) return '';
      const el = n;
      if (el.matches('input.task, .code-copy, .code-lang')) return '';
      if (el.classList.contains('math-inline')) return '$' + source(el) + '$';
      switch (el.tagName) {
        case 'STRONG': case 'B': return wrap(el, '**', ctx);
        case 'EM': case 'I': return wrap(el, '*', ctx);
        case 'DEL': case 'S': case 'STRIKE': return wrap(el, '~~', ctx);
        case 'MARK': return wrap(el, '==', ctx);
        case 'CODE': return codeSpan(el.textContent);
        case 'BR': return ctx.singleLine ? ' ' : BR;
        case 'IMG': {
          const src = el.dataset.src || el.getAttribute('src') || '';
          const alt = (el.getAttribute('alt') || '').replace(/[\[\]]/g, '\\$&');
          return `![${alt}](${linkDest(src)}${linkTitle(el.getAttribute('title'))})`;
        }
        case 'A': {
          if (el.hasAttribute('data-footnote-ref')) {
            const href = el.getAttribute('href') || '';
            return '[^' + decodeURIComponent(href.replace(/^#footnote-/, '')) + ']';
          }
          if (el.hasAttribute('data-footnote-backref')) return '';
          const href = el.getAttribute('href') || '';
          const text = inline(el.childNodes, ctx);
          if (!href) return text;
          if (el.textContent === href && /^(https?:\/\/|www\.)\S+$/.test(href)) return href;
          if (el.textContent === href.replace(/^mailto:/, '') && /^mailto:/.test(href)) return '<' + el.textContent + '>';
          return `[${text}](${linkDest(href)}${linkTitle(el.getAttribute('title'))})`;
        }
        case 'SUP': case 'SUB': case 'U': case 'KBD': case 'ABBR': case 'SMALL': case 'INS': {
          const inner = inline(el.childNodes, ctx);
          if (el.tagName === 'SUP' && el.querySelector('a[data-footnote-ref]')) return inner;
          const tag = el.tagName.toLowerCase();
          return inner ? `<${tag}>${inner}</${tag}>` : '';
        }
        default:
          return inline(el.childNodes, ctx);
      }
    }

    // Collapses an inline run into paragraph text: hard breaks, soft breaks, no blank lines.
    function finishInline(s, blockStarts = true) {
      s = s.replace(new RegExp(`^[\\s${BR}]+|[\\s${BR}]+$`, 'g'), '');
      s = s.replace(/[ \t]*\n[ \t\n]*/g, '\n');
      s = s.replace(new RegExp(`[ \\t]*${BR}[ \\t\\n]*`, 'g'), '\\\n');
      return blockStarts ? escapeLineStarts(s) : s;
    }

    // ---------- Blocks ----------
    function blockList(container, ctx) {
      const out = [];
      let run = [];
      const flush = () => {
        if (!run.length) return;
        const text = finishInline(inline(run, ctx));
        if (text) out.push(text);
        run = [];
      };
      for (const n of container.childNodes) {
        if (isBlock(n)) {
          flush();
          const s = block(n, ctx);
          if (s) out.push(s);
        } else {
          run.push(n);
        }
      }
      flush();
      return out;
    }

    const prefixLines = (text, first, rest) =>
      text.split('\n').map((l, i) => {
        const p = i === 0 ? first : rest;
        return l ? p + l : p.trimEnd();
      }).join('\n');

    function fence(code, lang) {
      code = code.replace(/\n$/, '');
      const f = '`'.repeat(Math.max(3, longestRun(code, '`') + 1));
      return f + (lang || '') + '\n' + code + '\n' + f;
    }

    function list(el, ctx) {
      const ordered = el.tagName === 'OL';
      const start = ordered ? parseInt(el.getAttribute('start') || '1', 10) || 1 : 0;
      const items = [];
      for (const child of el.children) {
        if (child.tagName === 'LI') items.push({ li: child, extra: [] });
        else if (child.tagName === 'UL' || child.tagName === 'OL') {
          if (!items.length) items.push({ li: null, extra: [] });
          items[items.length - 1].extra.push(child);
        }
      }
      const loose = items.some((it) => it.li && Array.from(it.li.children).some((c) => c.tagName === 'P'));
      const lines = items.map((it, i) => {
        const marker = ordered ? `${start + i}${ctx.delimiter || '.'}` : (ctx.bullet || '-');
        let task = '';
        if (it.li) {
          const cb = it.li.querySelector(':scope > input.task, :scope > p:first-child > input.task');
          if (cb) task = cb.checked ? '[x] ' : '[ ] ';
        }
        const parts = (it.li ? blockList(it.li, ctx) : []).concat(it.extra.map((x) => block(x, ctx)).filter(Boolean));
        const body = task + parts.join(loose ? '\n\n' : '\n');
        const pad = ' '.repeat(marker.length + 1);
        return body ? prefixLines(body, marker + ' ', pad) : marker;
      });
      return lines.join(loose ? '\n\n' : '\n');
    }

    const tableCells = (line) => line.trim().replace(/^\|/, '').replace(/(?<!\\)\|$/, '').split(/(?<!\\)\|/);

    function table(el, ctx) {
      const rows = Array.from(el.querySelectorAll('tr'));
      if (!rows.length) return '';
      const cellText = (c) => finishInline(inline(c.childNodes, { table: true, singleLine: true }), false).replace(/\n/g, ' ') || ' ';
      const header = Array.from(rows[0].children);
      const width = Math.max(...rows.map((r) => r.children.length));
      const aligns = [];
      for (let i = 0; i < width; i++) {
        const c = header[i];
        const a = c ? (c.getAttribute('align') || c.style.textAlign || '') : '';
        aligns.push(a === 'center' ? ':---:' : a === 'right' ? '---:' : a === 'left' ? ':---' : '---');
      }
      const line = (cells) => {
        const arr = Array.from(cells).map(cellText);
        while (arr.length < width) arr.push(' ');
        return '| ' + arr.join(' | ') + ' |';
      };
      // Keep the original delimiter row (its dashes and alignment) when the columns haven't changed.
      const oldDelimiter = ctx.raw ? (ctx.raw.split('\n')[1] || '') : '';
      const delimiter = /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/.test(oldDelimiter) &&
        tableCells(oldDelimiter).length === width
        ? oldDelimiter.trim()
        : '| ' + aligns.join(' | ') + ' |';
      return [line(header), delimiter, ...rows.slice(1).map((r) => line(r.children))].join('\n');
    }

    function block(el, ctx) {
      const tag = el.tagName;
      if (/^H[1-6]$/.test(tag)) {
        const text = finishInline(inline(el.childNodes, { ...ctx, singleLine: true }), false);
        return text ? '#'.repeat(Number(tag[1])) + ' ' + text : '';
      }
      switch (tag) {
        case 'P': return finishInline(inline(el.childNodes, ctx));
        case 'HR': return el.hasAttribute('data-footnotes') ? '' : '---';
        case 'BLOCKQUOTE': {
          const body = blockList(el, ctx).join('\n\n');
          return body ? prefixLines(body, '> ', '> ') : '';
        }
        case 'UL': case 'OL': return list(el, ctx);
        case 'LI': return blockList(el, ctx).join('\n');
        case 'PRE': {
          const code = el.querySelector('code') || el;
          const m = /language-([\w+#.-]+)/.exec(code.className || '');
          return fence(code.innerText, m ? m[1] : '');
        }
        case 'TABLE': return table(el, ctx);
        case 'SECTION': return el.hasAttribute('data-footnotes') ? '' : blockList(el, ctx).join('\n\n');
      }
      if (el.classList.contains('code-block')) {
        const code = el.querySelector('code');
        const label = el.querySelector('.code-lang');
        return fence(code ? code.innerText : '', label ? label.textContent.trim() : '');
      }
      if (el.classList.contains('mermaid-block')) return fence(source(el), 'mermaid');
      if (el.classList.contains('math-display')) return '$$\n' + source(el).trim() + '\n$$';
      if (el.classList.contains('markdown-alert')) {
        const m = /markdown-alert-(\w+)/.exec(Array.from(el.classList).find((c) => c !== 'markdown-alert') || '');
        const type = (m ? m[1] : 'note').toUpperCase();
        const clone = el.cloneNode(true);
        clone.querySelectorAll('.markdown-alert-title').forEach((t) => t.remove());
        const body = blockList(clone, ctx).join('\n\n');
        return prefixLines(`[!${type}]` + (body ? '\n' + body : ''), '> ', '> ');
      }
      if (el.classList.contains('front-matter')) return '';
      if (tag === 'DIV') return blockList(el, ctx).join('\n\n');
      return el.outerHTML;
    }

    return {
      block: (el, ctx) => block(el, ctx || {}),
      isBlock,
    };
  }

  window.InkwellToMarkdown = create;
})();
