/* ==========================================================================
   MdReader — rendering engine
   Receives Markdown from the native side, renders it with marked (GFM),
   runs mermaid on ```mermaid fences, highlights code with highlight.js, and
   rewrites local image links onto the custom `mdimg://` scheme so the Swift
   URL-scheme handler can serve files from disk.

   Also builds a heading outline (table of contents) and pushes it to the
   native sidebar, and exposes __scrollToHeading(id) so the sidebar can scroll
   a heading to the top of the view.
   ========================================================================== */
(function () {
  "use strict";

  // --- utilities ------------------------------------------------------------
  function b64ToUtf8(b64) {
    if (!b64) return "";
    const bin = atob(b64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return new TextDecoder("utf-8").decode(bytes);
  }

  // Resolve "." and ".." against an absolute POSIX base directory.
  function normalizePath(p) {
    const isAbs = p.startsWith("/");
    const out = [];
    for (const seg of p.split("/")) {
      if (seg === "" || seg === ".") continue;
      if (seg === "..") { if (out.length) out.pop(); }
      else out.push(seg);
    }
    return (isAbs ? "/" : "") + out.join("/");
  }

  // Map an <img> src to a scheme the native side can serve.
  // Returns null to leave the src untouched (remote / data / already mapped).
  function mapImageSrc(src, baseDir) {
    if (!src) return null;
    if (/^(https?:|data:|blob:|mdimg:)/i.test(src)) return null;

    let path;
    if (/^file:\/\//i.test(src)) {
      path = decodeURI(src.replace(/^file:\/\//i, ""));
    } else if (src.startsWith("/")) {
      path = src;
    } else if (baseDir) {
      path = normalizePath(baseDir + "/" + src);
    } else {
      return null;
    }
    // Drop a trailing anchor if present (rare for local files).
    const hash = path.indexOf("#");
    if (hash > 0) path = path.slice(0, hash);
    return "mdimg://local/" + encodeURIComponent(path);
  }

  // --- table of contents ----------------------------------------------------
  function slugify(text) {
    const base = text.toLowerCase().trim()
      .replace(/[^\w\s-]/g, "")
      .replace(/[\s_]+/g, "-")
      .replace(/-+/g, "-")
      .replace(/^-+|-+$/g, "");
    return base || "section";
  }

  // Assign a unique id to every h1–h3 and return the outline entries.
  function buildTOC(container) {
    const used = Object.create(null);
    const toc = [];
    container.querySelectorAll("h1, h2, h3").forEach((h) => {
      const text = (h.textContent || "").trim();
      if (!text) return;
      const slug = slugify(text);
      let id = slug, n = 1;
      while (used[id]) { id = slug + "-" + (++n); }
      used[id] = true;
      h.id = id;
      h.classList.add("md-heading");
      toc.push({ id: id, level: parseInt(h.tagName.substring(1), 10) || 1, text: text });
    });
    return toc;
  }

  // --- find in page ---------------------------------------------------------
  // Uses the CSS Custom Highlight API to mark matches without modifying the DOM
  // (and therefore never the file). Falls back to window.find() if unavailable.
  const HAS_HIGHLIGHT = typeof Highlight !== "undefined" && window.CSS && CSS.highlights;

  function findableTextNodes(root) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        if (!node.nodeValue) return NodeFilter.FILTER_REJECT;
        const p = node.parentElement;
        if (!p) return NodeFilter.FILTER_REJECT;
        // Skip diagram internals (SVG text) and the injected copy buttons.
        if (p.closest(".mermaid")) return NodeFilter.FILTER_REJECT;
        if (p.closest(".copy-btn")) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      },
    });
    const nodes = [];
    let n;
    while ((n = walker.nextNode())) nodes.push(n);
    return nodes;
  }

  // Build Range objects for every case-insensitive occurrence of `query`.
  function computeRanges(query) {
    const content = document.getElementById("content");
    if (!content || !query) return [];
    const nodes = findableTextNodes(content);
    let full = "";
    const map = []; // { node, start, end } spans into `full`
    for (const node of nodes) {
      const start = full.length;
      full += node.nodeValue;
      map.push({ node: node, start: start, end: full.length });
    }
    const hay = full.toLowerCase();
    const needle = query.toLowerCase();
    const ranges = [];
    if (!needle) return ranges;

    function locate(idx) {
      let lo = 0, hi = map.length - 1;
      while (lo <= hi) {
        const mid = (lo + hi) >> 1;
        if (idx < map[mid].start) hi = mid - 1;
        else if (idx >= map[mid].end) lo = mid + 1;
        else return mid;
      }
      return -1;
    }

    let from = 0;
    while (true) {
      const at = hay.indexOf(needle, from);
      if (at === -1) break;
      const endAt = at + needle.length;
      const si = locate(at);
      const ei = locate(endAt - 1);
      if (si !== -1 && ei !== -1) {
        try {
          const r = document.createRange();
          r.setStart(map[si].node, at - map[si].start);
          r.setEnd(map[ei].node, endAt - map[ei].start);
          ranges.push(r);
        } catch (e) { /* skip malformed range */ }
      }
      from = endAt;
    }
    return ranges;
  }

  function applyHighlights(ranges, index) {
    if (!HAS_HIGHLIGHT) return;
    CSS.highlights.delete("md-find");
    CSS.highlights.delete("md-find-current");
    if (!ranges.length) return;
    const base = new Highlight();
    ranges.forEach((r) => base.add(r));
    CSS.highlights.set("md-find", base);
    if (index >= 0 && index < ranges.length) {
      const cur = new Highlight();
      cur.add(ranges[index]);
      cur.priority = 1; // draw current match over the base style
      CSS.highlights.set("md-find-current", cur);
    }
  }

  function scrollRangeToView(range) {
    const rect = range.getBoundingClientRect();
    if (!rect || (rect.width === 0 && rect.height === 0)) {
      if (range.startContainer.parentElement) {
        range.startContainer.parentElement.scrollIntoView({ block: "center", behavior: "smooth" });
      }
      return;
    }
    const y = rect.top + window.scrollY - 90; // put the match near the top
    window.scrollTo({ top: y < 0 ? 0 : y, behavior: "smooth" });
  }

  // --- marked configuration -------------------------------------------------
  if (window.marked && typeof window.marked.setOptions === "function") {
    window.marked.setOptions({ gfm: true, breaks: false });
  }
  // KaTeX math, rendered at parse time so markdown can't mangle the LaTeX.
  // We reuse KaTeX's renderer but supply our own marked tokenizer: the standard
  // $-boundary rules are kept (so prose like "$5 and $10" is left alone), but the
  // opening boundary also accepts a '$' after a newline — otherwise inline math at
  // the start of a soft-wrapped line is dropped.
  function katexMarkedExtension() {
    const inlineRule = /^(\${1,2})(?!\$)((?:\\.|[^\\\n])*?(?:\\.|[^\\\n$]))\1(?=[\s?!.,:？！。，、；：]|$)/;
    const blockRule = /^(\${2})\n((?:\\[^]|[^\\])+?)\n\1(?:\n|$)/;
    const render = (text, display) => {
      try { return window.katex.renderToString(text, { throwOnError: false, displayMode: display }); }
      catch (e) { return display ? "$$" + text + "$$" : "$" + text + "$"; }
    };
    return {
      extensions: [
        {
          name: "inlineKatex", level: "inline",
          start(src) {
            let i = 0;
            while (true) {
              const at = src.indexOf("$", i);
              if (at < 0) return undefined;
              if (at === 0 || /\s/.test(src.charAt(at - 1))) return at;
              i = at + 1;
            }
          },
          tokenizer(src) {
            const m = inlineRule.exec(src);
            if (!m) return undefined;
            return { type: "inlineKatex", raw: m[0], text: m[2].trim(), displayMode: m[1].length === 2 };
          },
          renderer(token) { return render(token.text, token.displayMode); },
        },
        {
          name: "blockKatex", level: "block",
          start(src) { const m = src.match(/(?:^|\n)\$\$\n/); return m ? m.index : undefined; },
          tokenizer(src) {
            const m = blockRule.exec(src);
            if (!m) return undefined;
            return { type: "blockKatex", raw: m[0], text: m[2].trim(), displayMode: true };
          },
          renderer(token) { return '<p class="katex-block">' + render(token.text, true) + "</p>"; },
        },
      ],
    };
  }
  if (window.marked && window.katex) {
    try { window.marked.use(katexMarkedExtension()); } catch (e) { /* katex unavailable */ }
  }

  // Footnotes ([^1] references + definitions), reusing marked-footnote.
  if (window.marked && window.markedFootnote) {
    try { window.marked.use(window.markedFootnote({ description: "Footnotes" })); }
    catch (e) { /* footnotes unavailable */ }
  }

  // Emoji shortcodes (:rocket:) via the bundled shortcode→char map. Runs during
  // inline tokenizing, so it never touches code spans/blocks.
  function emojiMarkedExtension() {
    return {
      extensions: [{
        name: "emoji",
        level: "inline",
        start(src) { const i = src.indexOf(":"); return i < 0 ? undefined : i; },
        tokenizer(src) {
          const m = /^:([a-z0-9_+\-]+):/.exec(src);
          if (!m) return undefined;
          const ch = window.__EMOJI[m[1]];
          if (!ch) return undefined;
          return { type: "emoji", raw: m[0], ch: ch };
        },
        renderer(token) { return token.ch; },
      }],
    };
  }
  if (window.marked && window.__EMOJI) {
    try { window.marked.use(emojiMarkedExtension()); } catch (e) { /* emoji unavailable */ }
  }

  // --- YAML front matter ----------------------------------------------------
  // Strip a leading `---\n…\n---` block and render it as a tidy metadata header
  // instead of the stray rule + text marked would otherwise produce.
  function escapeHTML(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }
  function stripQuotes(s) { return s.replace(/^['"]|['"]$/g, ""); }

  function parseFrontMatter(text) {
    const rows = [];
    const lines = text.split(/\r?\n/);
    let i = 0;
    while (i < lines.length) {
      const line = lines[i];
      if (!line.trim() || /^\s*#/.test(line)) { i++; continue; }
      const km = /^([A-Za-z0-9_.\- ]+):\s*(.*)$/.exec(line);
      if (!km) { i++; continue; }
      const key = km[1].trim();
      let val = km[2].trim();
      if (val === "") {
        const items = [];
        let j = i + 1;
        while (j < lines.length && /^\s*-\s+/.test(lines[j])) {
          items.push(stripQuotes(lines[j].replace(/^\s*-\s+/, "").trim()));
          j++;
        }
        rows.push([key, items.length ? items : ""]);
        i = items.length ? j : i + 1;
        continue;
      }
      if (/^\[.*\]$/.test(val)) {
        rows.push([key, val.slice(1, -1).split(",").map((s) => stripQuotes(s.trim())).filter(Boolean)]);
      } else {
        rows.push([key, stripQuotes(val)]);
      }
      i++;
    }
    return rows;
  }

  function frontMatterHTML(rows) {
    if (!rows || !rows.length) return "";
    let title = null;
    const meta = [];
    for (const [k, v] of rows) {
      if (k.toLowerCase() === "title" && typeof v === "string") title = v;
      else meta.push([k, v]);
    }
    let html = '<div class="frontmatter">';
    if (title) html += '<div class="fm-title">' + escapeHTML(title) + "</div>";
    if (meta.length) {
      html += '<dl class="fm-meta">';
      for (const [k, v] of meta) {
        html += "<dt>" + escapeHTML(k) + "</dt><dd>";
        if (Array.isArray(v)) {
          html += v.map((x) => '<span class="fm-tag">' + escapeHTML(x) + "</span>").join(" ");
        } else {
          html += escapeHTML(v);
        }
        html += "</dd>";
      }
      html += "</dl>";
    }
    return html + "</div>";
  }

  function splitFrontMatter(md) {
    const m = /^﻿?---[ \t]*\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/.exec(md);
    if (!m) return { headerHTML: "", body: md };
    return { headerHTML: frontMatterHTML(parseFrontMatter(m[1])), body: md.slice(m[0].length) };
  }

  // --- admonitions / callouts ------------------------------------------------
  // GitHub-style > [!NOTE] / [!TIP] / [!IMPORTANT] / [!WARNING] / [!CAUTION].
  const ADMONITIONS = {
    NOTE:      { cls: "note",      label: "Note" },
    TIP:       { cls: "tip",       label: "Tip" },
    IMPORTANT: { cls: "important", label: "Important" },
    WARNING:   { cls: "warning",   label: "Warning" },
    CAUTION:   { cls: "caution",   label: "Caution" },
  };
  const ADMONITION_ICON = {
    NOTE: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm8-6.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM6.5 7.75A.75.75 0 0 1 7.25 7h1a.75.75 0 0 1 .75.75v2.75h.25a.75.75 0 0 1 0 1.5h-2a.75.75 0 0 1 0-1.5h.25v-2h-.25a.75.75 0 0 1-.75-.75ZM8 6a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z"/></svg>',
    TIP: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 1.5c-2.363 0-4 1.69-4 3.75 0 .984.424 1.625.984 2.304l.214.253c.223.264.47.556.673.848.284.411.537.896.621 1.49a.75.75 0 0 1-1.484.211c-.04-.282-.163-.547-.37-.847a8.456 8.456 0 0 0-.542-.68c-.084-.1-.173-.205-.268-.32C3.201 7.75 2.5 6.766 2.5 5.25 2.5 2.31 4.863.5 8 .5s5.5 1.81 5.5 4.75c0 1.516-.701 2.5-1.328 3.259-.095.115-.184.22-.268.319-.207.245-.383.453-.541.681-.208.3-.33.565-.37.847a.751.751 0 0 1-1.485-.212c.084-.593.337-1.078.621-1.489.203-.292.45-.584.673-.848.075-.088.147-.173.213-.253.561-.679.985-1.32.985-2.304 0-2.06-1.637-3.75-4-3.75ZM5.75 12h4.5a.75.75 0 0 1 0 1.5h-4.5a.75.75 0 0 1 0-1.5ZM6 15.25a.75.75 0 0 1 .75-.75h2.5a.75.75 0 0 1 0 1.5h-2.5a.75.75 0 0 1-.75-.75Z"/></svg>',
    IMPORTANT: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M0 1.75C0 .784.784 0 1.75 0h12.5C15.216 0 16 .784 16 1.75v9.5A1.75 1.75 0 0 1 14.25 13H8.06l-2.573 2.573A1.458 1.458 0 0 1 3 14.543V13H1.75A1.75 1.75 0 0 1 0 11.25Zm1.75-.25a.25.25 0 0 0-.25.25v9.5c0 .138.112.25.25.25h2a.75.75 0 0 1 .75.75v2.19l2.72-2.72a.749.749 0 0 1 .53-.22h6.5a.25.25 0 0 0 .25-.25v-9.5a.25.25 0 0 0-.25-.25Zm7 2.25v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM8 9a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z"/></svg>',
    WARNING: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M6.457 1.047c.659-1.234 2.427-1.234 3.086 0l6.082 11.378A1.75 1.75 0 0 1 14.082 15H1.918a1.75 1.75 0 0 1-1.543-2.575Zm1.763.707a.25.25 0 0 0-.44 0L1.698 13.132a.25.25 0 0 0 .22.368h12.164a.25.25 0 0 0 .22-.368Zm.53 3.996v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 11a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z"/></svg>',
    CAUTION: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4.47.22A.749.749 0 0 1 5 0h6c.199 0 .389.079.53.22l4.25 4.25c.141.14.22.331.22.53v6a.749.749 0 0 1-.22.53l-4.25 4.25A.749.749 0 0 1 11 16H5a.749.749 0 0 1-.53-.22L.22 11.53A.749.749 0 0 1 0 11V5c0-.199.079-.389.22-.53Zm.84 1.28L1.5 5.31v5.38l3.81 3.81h5.38l3.81-3.81V5.31L10.69 1.5ZM8 4a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 8 4Zm0 8a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z"/></svg>',
  };
  function processAdmonitions(container) {
    container.querySelectorAll("blockquote").forEach((bq) => {
      const first = bq.firstElementChild;
      if (!first || first.tagName !== "P") return;
      const m = /^\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]/i.exec(first.textContent || "");
      if (!m) return;
      const type = m[1].toUpperCase();
      const info = ADMONITIONS[type];
      first.innerHTML = first.innerHTML.replace(
        /^\s*\[!(?:NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*(<br\s*\/?>)?\s*/i, "");
      if (!first.textContent.trim() && !first.querySelector("img,code")) first.remove();
      bq.classList.add("admonition", "admonition-" + info.cls);
      const title = document.createElement("div");
      title.className = "admonition-title";
      title.innerHTML = ADMONITION_ICON[type] + "<span>" + info.label + "</span>";
      bq.insertBefore(title, bq.firstChild);
    });
  }

  // Copy a code block's text — via the native pasteboard when hosted, else the
  // Clipboard API. (WKWebView's clipboard access is unreliable, so prefer native.)
  function copyText(text) {
    try {
      const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.copy;
      if (h) { h.postMessage(String(text)); return; }
    } catch (e) { /* fall through */ }
    try { if (navigator.clipboard) navigator.clipboard.writeText(String(text)); } catch (e) { /* ignore */ }
  }

  // --- rendering ------------------------------------------------------------
  function renderInto(container, md, baseDir) {
    const fm = splitFrontMatter(md);
    const body = window.marked ? window.marked.parse(fm.body) : fm.body;
    const html = fm.headerHTML + body;

    // Build detached so images/scripts don't load until we've rewritten them.
    const tpl = document.createElement("template");
    tpl.innerHTML = html;

    // Extract ```mermaid fences into <div class="mermaid"> blocks.
    tpl.content.querySelectorAll("code.language-mermaid").forEach((code) => {
      const host = code.closest("pre") || code;
      const div = document.createElement("div");
      div.className = "mermaid";
      const source = code.textContent;
      div.textContent = source;
      div.dataset.src = source;
      host.replaceWith(div);
    });

    // Rewrite local image links onto the mdimg scheme.
    tpl.content.querySelectorAll("img").forEach((img) => {
      const mapped = mapImageSrc(img.getAttribute("src") || "", baseDir);
      if (mapped !== null) img.setAttribute("src", mapped);
      img.addEventListener("error", function () {
        if (img.classList.contains("broken")) return;
        img.classList.add("broken");
        img.removeAttribute("src");
        img.textContent = "⚠ image not found: " + (img.getAttribute("alt") || "");
      });
    });

    container.replaceChildren(tpl.content);

    processAdmonitions(container);

    // Syntax-highlight everything except mermaid fences.
    if (window.hljs) {
      container.querySelectorAll("pre code").forEach((code) => {
        if (code.classList.contains("language-mermaid")) return;
        try { window.hljs.highlightElement(code); } catch (e) { /* ignore */ }
      });
    }

    // Add a hover "Copy" button to each code block.
    container.querySelectorAll("pre").forEach((pre) => {
      if (pre.querySelector("code.language-mermaid")) return;
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "copy-btn";
      btn.textContent = "Copy";
      btn.addEventListener("click", (e) => {
        e.preventDefault();
        const code = pre.querySelector("code");
        copyText(code ? code.textContent : pre.textContent);
        btn.textContent = "Copied";
        btn.classList.add("copied");
        setTimeout(() => { btn.textContent = "Copy"; btn.classList.remove("copied"); }, 1200);
      });
      pre.appendChild(btn);
    });

    const toc = buildTOC(container);
    return { mermaidNodes: Array.from(container.querySelectorAll(".mermaid")), toc: toc };
  }

  // --- controller -----------------------------------------------------------
  const MD = {
    md: "",
    baseDir: "",
    printing: false,
    loaded: false,
    toc: [],
    findState: { query: "", ranges: [], index: -1 },

    isDark() {
      return window.matchMedia("(prefers-color-scheme: dark)").matches;
    },

    applyTheme(dark) {
      document.documentElement.classList.toggle("theme-dark", dark);
      const l = document.getElementById("hl-light");
      const d = document.getElementById("hl-dark");
      if (l) l.disabled = dark;
      if (d) d.disabled = !dark;
    },

    postTOC() {
      try {
        const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.toc;
        if (h) h.postMessage(this.toc || []);
      } catch (e) { /* not running in the native host */ }
    },

    // Find next/previous occurrence of `query`. Returns { count, index }.
    find(query, forward) {
      const q = (query || "").trim();
      if (!q) { this.clearFind(); return { count: 0, index: -1 }; }

      if (!HAS_HIGHLIGHT) {
        // Degraded: native selection-based find (still scrolls & highlights).
        const ok = window.find ? window.find(q, false, !forward, true, false, false, false) : false;
        return { count: ok ? 1 : 0, index: ok ? 0 : -1 };
      }

      const st = this.findState;
      if (q !== st.query || !st.ranges.length) {
        st.query = q;
        st.ranges = computeRanges(q);
        st.index = st.ranges.length ? (forward ? 0 : st.ranges.length - 1) : -1;
      } else {
        st.index = (st.index + (forward ? 1 : -1) + st.ranges.length) % st.ranges.length;
      }
      applyHighlights(st.ranges, st.index);
      if (st.index >= 0) scrollRangeToView(st.ranges[st.index]);
      return { count: st.ranges.length, index: st.index };
    },

    clearFind() {
      this.findState = { query: "", ranges: [], index: -1 };
      if (HAS_HIGHLIGHT) {
        CSS.highlights.delete("md-find");
        CSS.highlights.delete("md-find-current");
      }
    },

    async renderAll(dark) {
      const el = document.getElementById("content");
      if (!el) return;
      const y = window.scrollY;
      this.clearFind(); // ranges reference old nodes once we re-render
      this.applyTheme(dark);

      if (!this.md || !this.md.trim()) {
        el.innerHTML =
          '<div class="placeholder"><div class="placeholder-mark">M<span>&#8595;</span></div><p>This document is empty.</p></div>';
        this.toc = [];
        this.postTOC();
        return;
      }

      if (window.mermaid) {
        try {
          window.mermaid.initialize({
            startOnLoad: false,
            theme: dark ? "dark" : "default",
            securityLevel: "strict",
            fontFamily: "inherit",
            flowchart: { htmlLabels: true, useMaxWidth: true },
          });
        } catch (e) { /* ignore */ }
      }

      const result = renderInto(el, this.md, this.baseDir);
      this.toc = result.toc;
      this.postTOC();

      const nodes = result.mermaidNodes;
      if (nodes.length && window.mermaid) {
        try {
          await window.mermaid.run({ nodes });
        } catch (e) {
          // mermaid.run throws on the first bad diagram; render each on its own
          for (const node of nodes) {
            if (node.getAttribute("data-processed")) continue;
            try {
              node.textContent = node.dataset.src;
              node.removeAttribute("data-processed");
              await window.mermaid.run({ nodes: [node] });
            } catch (err) {
              const box = document.createElement("div");
              box.className = "mermaid-error";
              box.textContent = "Mermaid error:\n" + (err && err.message ? err.message : String(err));
              node.replaceWith(box);
            }
          }
        }
      }
      window.scrollTo(0, y);
      postActive(true);
      postLayout();
    },

    async setContent(b64md, b64base) {
      this.md = b64ToUtf8(b64md);
      this.baseDir = b64ToUtf8(b64base);
      this.loaded = true;
      await this.renderAll(this.isDark());
    },

    async prepareForPrint() {
      this.printing = true;
      await this.renderAll(false); // force light for legible print / PDF
      // Let layout & mermaid SVG settle before the native side captures. Resolve on
      // a paint tick when visible, but always resolve via a timeout fallback — an
      // occluded/minimized window throttles requestAnimationFrame, which would
      // otherwise hang printing/export.
      await new Promise((resolve) => {
        let done = false;
        const finish = () => { if (!done) { done = true; resolve(); } };
        requestAnimationFrame(() => requestAnimationFrame(finish));
        setTimeout(finish, 250);
      });
    },

    async endPrint() {
      this.printing = false;
      await this.renderAll(this.isDark());
    },
  };

  // --- scroll: sidebar -> document, and scroll-spy for the active heading ----
  function headingEls() {
    const el = document.getElementById("content");
    return el ? Array.from(el.querySelectorAll(".md-heading")) : [];
  }

  // Scroll so the given heading sits just under the top edge of the view.
  window.__scrollToHeading = function (id) {
    const el = document.getElementById(id);
    if (!el) return;
    const top = el.getBoundingClientRect().top + window.scrollY - 12;
    window.scrollTo({ top: top < 0 ? 0 : top, behavior: "smooth" });
  };

  let lastActiveId = null;
  function postActive(force) {
    const hs = headingEls();
    if (!hs.length) { lastActiveId = null; return; }
    const threshold = 96; // a heading counts as "current" once its top passes this
    let current = hs[0].id;
    for (const h of hs) {
      if (h.getBoundingClientRect().top <= threshold) current = h.id;
      else break;
    }
    if (force || current !== lastActiveId) {
      lastActiveId = current;
      try {
        const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.activeHeading;
        if (handler) handler.postMessage(current);
      } catch (e) { /* not running in the native host */ }
    }
  }

  // Report the widest un-wrappable block so the native side can auto-orient the
  // page (switch to Landscape) when content is wider than the current page prints.
  function measureMaxBlock() {
    const el = document.getElementById("content");
    if (!el) return 0;
    let max = 0;
    el.querySelectorAll("table, pre, .katex-display").forEach((n) => {
      // Measure the block's *intrinsic* width (how wide it wants to be), not its
      // current box width — otherwise a block that merely fills the column reports
      // the column width and would wrongly trigger a wider page.
      const pw = n.style.width, pm = n.style.maxWidth;
      n.style.maxWidth = "none";
      n.style.width = "max-content";
      const w = n.scrollWidth;
      n.style.width = pw;
      n.style.maxWidth = pm;
      if (w > max) max = w;
    });
    return Math.round(max);
  }
  function postLayout() {
    try {
      const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.layout;
      if (h) h.postMessage({ maxBlockWidth: measureMaxBlock() });
    } catch (e) { /* not hosted */ }
  }

  let ticking = false;
  window.addEventListener("scroll", function () {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(function () { ticking = false; postActive(false); });
  }, { passive: true });

  // Native bridge -------------------------------------------------------------
  // __setContent is fire-and-forget from the native side, so don't return the
  // promise (evaluateJavaScript can't serialize it). prepare/endPrint DO return
  // promises — the native side awaits them via callAsyncJavaScript.
  window.__setContent = (a, b) => { MD.setContent(a, b); };
  window.__prepareForPrint = () => MD.prepareForPrint();
  window.__endPrint = () => { MD.endPrint(); };
  // Find returns { count, index }; the native side reads it via JSON.stringify.
  window.__find = (query, forward) => MD.find(query, forward);
  window.__clearFind = () => { MD.clearFind(); };
  // Text zoom: scales the whole page (text reflows), set on <html> so it persists
  // across content re-renders. The native side stores/steps the factor.
  window.__setZoom = (z) => { document.documentElement.style.zoom = String(z); };
  // Page format: set the content width (printable width of the page) and the prose
  // measure. Persist on <html> so it survives content re-renders.
  window.__applyFormat = (contentWidthPx, proseWidthPx) => {
    const s = document.documentElement.style;
    s.setProperty("--content-width", contentWidthPx + "px");
    s.setProperty("--prose-width", proseWidthPx + "px");
  };

  // Follow the system appearance while reading (unless mid-print).
  window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", (e) => {
    if (MD.loaded && !MD.printing) MD.renderAll(e.matches);
  });

  // Apply initial theme to the placeholder.
  MD.applyTheme(MD.isDark());
})();
