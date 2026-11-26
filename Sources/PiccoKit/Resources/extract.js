// Picco Sync article extraction. Runs in an isolated WKContentWorld, after defuddle.js.
// Defuddle finds the article; this file then reduces it to a small, safe XHTML subset
// and marks images for the Mac side to download.
(function () {
  "use strict";

  // Elements kept as-is, with the attributes each may keep. `id` is allowed everywhere (footnotes).
  const ALLOWED = {
    h1: [], h2: [], h3: [], h4: [], h5: [], h6: [],
    p: [], br: [], hr: [], div: [], span: [],
    blockquote: [], q: [], cite: [],
    ul: [], ol: ["start"], li: [], dl: [], dt: [], dd: [],
    em: [], i: [], strong: [], b: [], u: [], s: [], del: [], ins: [],
    sub: [], sup: [], small: [], mark: [], abbr: ["title"], time: [],
    a: ["href"], img: ["alt"],
    figure: [], figcaption: [],
    pre: [], code: [], kbd: [], samp: [],
    table: [], caption: [], thead: [], tbody: [], tfoot: [], tr: [],
    th: ["colspan", "rowspan"], td: ["colspan", "rowspan"],
  };
  // Elements renamed to a plain div.
  const RENAME_TO_DIV = new Set(["section", "article", "main", "header", "footer", "aside", "details", "center"]);
  // Elements dropped with everything inside them.
  const DROP = new Set([
    "script", "style", "noscript", "iframe", "frame", "frameset", "object", "embed", "applet",
    "form", "input", "button", "select", "textarea", "label", "option",
    "svg", "math", "canvas", "video", "audio", "source", "track", "map", "area",
    "template", "link", "meta", "base", "nav", "dialog", "head", "title",
  ]);
  const VOID = new Set(["br", "hr", "img"]);
  const MAX_IMAGES = 60;
  const ID_RE = /^[A-Za-z][\w\-.:]*$/;

  function absolute(url) {
    try { return new URL(url, document.baseURI).href; } catch (e) { return null; }
  }

  // Picks the best source for an <img>, looking through lazy-loading attributes and srcset.
  function imageSource(img) {
    const sets = [img.getAttribute("srcset"), img.getAttribute("data-srcset")];
    const picture = img.parentElement && img.parentElement.tagName.toLowerCase() === "picture" ? img.parentElement : null;
    if (picture) {
      for (const s of picture.querySelectorAll("source")) sets.push(s.getAttribute("srcset"), s.getAttribute("data-srcset"));
    }
    let best = null, bestW = 0;
    for (const set of sets) {
      if (!set) continue;
      for (const part of set.split(/,\s+/)) {
        const [u, d] = part.trim().split(/\s+/);
        if (!u) continue;
        const w = d && d.endsWith("w") ? parseInt(d, 10) : (d && d.endsWith("x") ? parseFloat(d) * 500 : 500);
        // Prefer the smallest candidate that is still at least ~2x the screen width, else the largest.
        const score = w >= 960 ? 100000 - w : w;
        if (score > bestW) { bestW = score; best = u; }
      }
    }
    const candidates = [
      img.getAttribute("data-src"), img.getAttribute("data-lazy-src"), img.getAttribute("data-original"),
      img.getAttribute("data-url"), best, img.getAttribute("src"),
    ];
    for (const c of candidates) {
      if (!c) continue;
      const trimmed = c.trim();
      if (trimmed.startsWith("data:")) {
        // Tiny data: URIs are lazy-loading placeholders; large ones are real images.
        if (trimmed.length > 2000 && trimmed.startsWith("data:image/") && !trimmed.startsWith("data:image/svg")) return trimmed;
        continue;
      }
      const abs = absolute(trimmed);
      if (!abs || !/^https?:/i.test(abs)) continue;
      if (/\.svg(\?|#|$)/i.test(abs)) continue;
      return abs;
    }
    return null;
  }

  function unwrap(el) {
    const parent = el.parentNode;
    while (el.firstChild) parent.insertBefore(el.firstChild, el);
    parent.removeChild(el);
  }

  function rename(el, tag) {
    const repl = el.ownerDocument.createElement(tag);
    while (el.firstChild) repl.appendChild(el.firstChild);
    if (el.id) repl.id = el.id;
    el.parentNode.replaceChild(repl, el);
    return repl;
  }

  const BLOCK = new Set([
    "p", "div", "blockquote", "ul", "ol", "dl", "pre", "table", "figure", "hr",
    "h1", "h2", "h3", "h4", "h5", "h6",
  ]);

  function isBr(node) { return node.nodeType === 1 && node.tagName.toLowerCase() === "br"; }
  function isBlank(node) { return node.nodeType === 3 && node.textContent.trim() === ""; }

  // Old-style pages separate paragraphs with <br><br> instead of <p>. Rebuild real paragraphs
  // wherever a container holds loose text and a double line break.
  function paragraphize(root) {
    const containers = [root, ...root.querySelectorAll("div, blockquote")];
    for (const el of containers) {
      const kids = Array.from(el.childNodes);
      const hasLooseText = kids.some((n) => n.nodeType === 3 && n.textContent.trim() !== "");
      if (!hasLooseText) continue;
      let doubleBr = false;
      for (let i = 0, run = 0; i < kids.length; i++) {
        if (isBr(kids[i])) { run++; if (run >= 2) { doubleBr = true; break; } }
        else if (!isBlank(kids[i])) run = 0;
      }
      if (!doubleBr) continue;

      const doc = el.ownerDocument;
      let para = null;
      let pendingBr = null;
      const flush = () => {
        if (para && para.textContent.trim() !== "") el.insertBefore(para, marker);
        para = null;
        pendingBr = null;
      };
      const marker = doc.createComment("picco");
      el.insertBefore(marker, el.firstChild);
      for (const node of kids) {
        if (node.nodeType === 1 && BLOCK.has(node.tagName.toLowerCase())) {
          flush();
          el.insertBefore(node, marker);
          continue;
        }
        if (isBr(node)) {
          if (pendingBr) { flush(); node.remove(); continue; }  // second <br>: paragraph break
          pendingBr = node;
          node.remove();
          continue;
        }
        if (isBlank(node) && pendingBr) { node.remove(); continue; }
        if (pendingBr && para) { para.appendChild(doc.createElement("br")); }
        pendingBr = null;
        if (!para) para = doc.createElement("p");
        para.appendChild(node);
      }
      flush();
      marker.remove();
    }
  }

  function sanitize(root, includeImages) {
    let imageCount = 0;

    // Images first, while <picture>/<source> context still exists.
    for (const img of Array.from(root.querySelectorAll("img"))) {
      const src = includeImages && imageCount < MAX_IMAGES ? imageSource(img) : null;
      if (!src) { img.remove(); continue; }
      imageCount++;
      for (const attr of Array.from(img.attributes)) {
        if (attr.name !== "alt") img.removeAttribute(attr.name);
      }
      img.setAttribute("data-picco-src", src);
      if (img.parentElement && img.parentElement.tagName.toLowerCase() === "picture") unwrap(img.parentElement);
    }

    // Walk every element (copy the list: we mutate as we go). Children come after parents,
    // so a dropped parent's children are already detached when we reach them.
    for (const el of Array.from(root.querySelectorAll("*"))) {
      if (!root.contains(el)) continue;
      let tag = el.tagName.toLowerCase();
      if (DROP.has(tag)) { el.remove(); continue; }
      let node = el;
      if (RENAME_TO_DIV.has(tag)) { node = rename(el, "div"); tag = "div"; }
      else if (tag === "picture") { unwrap(el); continue; }
      else if (!(tag in ALLOWED)) { unwrap(el); continue; }

      const keep = ALLOWED[tag];
      for (const attr of Array.from(node.attributes)) {
        const name = attr.name.toLowerCase();
        if (name === "data-picco-src" && tag === "img") continue;
        if (name === "id" && ID_RE.test(attr.value)) continue;
        if (keep.includes(name)) continue;
        node.removeAttribute(attr.name);
      }
      if (tag === "a") {
        const href = node.getAttribute("href");
        if (href && href.startsWith("#")) continue;
        const abs = href ? absolute(href) : null;
        if (abs && /^(https?|mailto):/i.test(abs)) node.setAttribute("href", abs);
        else node.removeAttribute("href");
      }
      if ((tag === "th" || tag === "td")) {
        for (const a of ["colspan", "rowspan"]) {
          const v = node.getAttribute(a);
          if (v !== null && !/^\d{1,3}$/.test(v)) node.removeAttribute(a);
        }
      }
      if (tag === "ol") {
        const v = node.getAttribute("start");
        if (v !== null && !/^-?\d{1,6}$/.test(v)) node.removeAttribute("start");
      }
    }

    paragraphize(root);

    // Remove empty elements, deepest first, so nothing serializes as a self-closed <p/>.
    const all = Array.from(root.querySelectorAll("*")).reverse();
    for (const el of all) {
      const tag = el.tagName.toLowerCase();
      if (VOID.has(tag) || tag === "td" || tag === "th") continue;
      if (el.textContent.trim() !== "") continue;
      if (el.querySelector("img, br, hr")) continue;
      el.remove();
    }
    return imageCount;
  }

  window.__piccoExtract = function (opts) {
    const includeImages = !!(opts && opts.includeImages);
    const result = new Defuddle(document, { url: document.URL }).parse();

    // DOMParser documents are inert: scripts don't run and images don't load.
    const doc = new DOMParser().parseFromString(result.content || "", "text/html");
    const container = doc.createElement("div");
    while (doc.body.firstChild) container.appendChild(doc.body.firstChild);
    const imageCount = sanitize(container, includeImages);

    let html = new XMLSerializer().serializeToString(container);
    // XML 1.0 forbids most control characters.
    html = html.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F￾￿]/g, "");

    return JSON.stringify({
      url: document.URL,
      title: (result.title || document.title || "").trim(),
      author: (result.author || "").trim(),
      site: (result.site || "").trim(),
      domain: (result.domain || location.hostname || "").trim(),
      published: (result.published || "").trim(),
      language: (result.language || document.documentElement.lang || "").trim(),
      description: (result.description || "").trim(),
      wordCount: result.wordCount || 0,
      // The page's main image (og:image etc.), used for the EPUB cover.
      image: (function () {
        const raw = (result.image || "").trim();
        const abs = raw ? absolute(raw) : null;
        return abs && /^https?:/i.test(abs) && !/\.svg(\?|#|$)/i.test(abs) ? abs : "";
      })(),
      imageCount: imageCount,
      html: html,
    });
  };
})();
true;
