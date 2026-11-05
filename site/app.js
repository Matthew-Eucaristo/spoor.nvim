/* spoor.nvim site. No dependencies, no network requests beyond this site's own files. */
(() => {
  "use strict";
  const $ = (s, el = document) => el.querySelector(s);
  const $$ = (s, el = document) => [...el.querySelectorAll(s)];
  const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---------- recording: video, GIF fallback, pause ---------- */
  const video = $("#demo-video"), toggle = $("#rec-toggle");
  if (video) {
    const fallback = () => {
      const img = Object.assign(new Image(1100, 620), { src: "demo.gif", alt: video.getAttribute("aria-label") });
      video.replaceWith(img);
      if (toggle) toggle.hidden = true;
    };
    const srcs = $$("source", video);
    if (!srcs.length || !video.canPlayType("video/mp4")) fallback();
    else srcs[srcs.length - 1].addEventListener("error", fallback);
    if (reduced) video.removeAttribute("autoplay"), video.pause();
    const sync = () => {
      const paused = video.paused;
      toggle.textContent = paused ? "Play" : "Pause";
      toggle.setAttribute("aria-pressed", String(paused));
    };
    let userPaused = reduced;
    if (toggle) {
      toggle.addEventListener("click", () => {
        userPaused = !video.paused;
        if (video.paused) video.play().catch(() => {});
        else video.pause();
      });
      video.addEventListener("play", sync);
      video.addEventListener("pause", sync);
      sync();
    }
    document.addEventListener("visibilitychange", () => {
      if (document.hidden) video.pause();
      else if (!userPaused) video.play().catch(() => {});
    });
  }

  /* ---------- copy buttons ---------- */
  const copyText = async (text) => {
    try { await navigator.clipboard.writeText(text); return true; } catch { /* fall through */ }
    const ta = Object.assign(document.createElement("textarea"), { value: text });
    ta.setAttribute("readonly", ""); ta.style.position = "fixed"; ta.style.opacity = "0";
    document.body.append(ta); ta.select();
    let ok = false;
    try { ok = document.execCommand("copy"); } catch { ok = false; }
    ta.remove();
    return ok;
  };
  $$(".copy").forEach((b) => b.addEventListener("click", async () => {
    const ok = await copyText($("#" + b.dataset.copy).textContent);
    b.textContent = ok ? "Copied" : "Select and copy";
    b.classList.toggle("done", ok);
    setTimeout(() => { b.textContent = "Copy"; b.classList.remove("done"); }, 1600);
  }));

  /* ---------- install tabs ---------- */
  const tabs = $$(".tabs [role=tab]");
  const select = (t) => {
    tabs.forEach((x) => {
      const on = x === t;
      x.setAttribute("aria-selected", String(on));
      x.tabIndex = on ? 0 : -1;
      $("#" + x.getAttribute("aria-controls")).hidden = !on;
    });
  };
  tabs.forEach((t, i) => {
    t.addEventListener("click", () => select(t));
    t.addEventListener("keydown", (e) => {
      const d = e.key === "ArrowRight" ? 1 : e.key === "ArrowLeft" ? -1 : 0;
      if (!d) return;
      const n = tabs[(i + d + tabs.length) % tabs.length];
      select(n); n.focus(); e.preventDefault();
    });
  });
  if (tabs.length) select(tabs[0]);

  /* ---------- stages ---------- */
  const range = $("#stage-range"), stages = $$(".stage"), names = $$(".stage-names li");
  const labels = ["Pick a focus", "Look at its neighbours", "Follow one path", "Write down what you learn"];
  if (range) {
    const show = () => {
      const v = +range.value;
      stages.forEach((s, i) => s.classList.toggle("is-on", i === v));
      names.forEach((s, i) => s.classList.toggle("is-on", i === v));
      range.setAttribute("aria-valuetext", labels[v]);
      range.parentElement.style.setProperty("--pct", (v / 3) * 100 + "%");
    };
    range.addEventListener("input", show);
    names.forEach((n, i) => n.addEventListener("click", () => { range.value = i; show(); }));
    show();
  }

  /* ---------- entrances ----------
     Content is never hidden: a part plays its rise only when it scrolls into view later.
     Whatever is on screen at load (or already scrolled past) simply stays put. */
  const reveal = $$("[data-reveal]");
  if ("IntersectionObserver" in window && !reduced) {
    const first = new WeakSet();
    const io = new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        const initial = !first.has(e.target);
        first.add(e.target);
        if (initial && (e.isIntersecting || e.boundingClientRect.bottom <= 0)) return io.unobserve(e.target);
        if (!e.isIntersecting) return;
        e.target.classList.add("in");
        io.unobserve(e.target);
      });
    }, { rootMargin: "0px 0px 6% 0px" });
    // stagger siblings that enter together
    const groups = new Map();
    reveal.forEach((el) => {
      const p = el.parentElement;
      const i = groups.get(p) || 0;
      el.style.setProperty("--i", String(Math.min(i, 6)));
      groups.set(p, i + 1);
      io.observe(el);
    });
  }

  /* ---------- the bow-tie explorer ---------- */
  const data = window.SPOOR_BOWTIE;
  const pre = $("#bt-pre"), box = $("#bt"), cur = $("#bt-cursor");
  if (!data || !pre || !box) return;

  // Nerd Font icons need that font; show the function icon as ƒ (LazyVim's statusline glyph).
  const ICON = { "\u{f0295}": "ƒ", "\u{f0668}": "t" };
  const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
  // Box drawing stays inline (system monospace fonts carry it); every other non-ASCII glyph
  // gets a fixed 1ch cell so columns line up whatever font draws it.
  const cell = (text) => {
    let out = "";
    for (const ch of text) {
      const c = ch.codePointAt(0);
      if (c < 0x80 || (c >= 0x2500 && c <= 0x257f)) out += esc(ch);
      else if (c === 0x2691 || c === 0x26a0) out += '<span class="g">' + ch + "\uFE0E</span>"; // ⚑ ⚠ as text, not emoji (taste-skill-ignore: spoor's literal labels)
      else out += '<span class="g">' + esc(ICON[ch] || ((c >= 0xe000 && c <= 0xf8ff) || c >= 0xf0000 ? "•" : ch)) + "</span>";
    }
    return out;
  };

  let focus = data.start, history = [], row = 0, side = "focus", width = null, layout = null;
  const view = () => data.views[focus];
  const nameEl = $("#focus-name"), titleEl = $("#bt-title"), legendEl = $("#bt-legend");
  const back = $("#bt-back"), copyBtn = $("#bt-copy"), status = $("#bt-status"), live = $("#bt-live");
  const codePath = $("#code-path"), codePre = $("#code-pre");

  const charWidth = () => {
    const probe = document.createElement("span");
    probe.textContent = "0".repeat(100);
    probe.style.cssText = "position:absolute;visibility:hidden;white-space:pre";
    pre.append(probe);
    const w = probe.getBoundingClientRect().width / 100;
    probe.remove();
    return w || 8;
  };
  const pickWidth = () => {
    const room = (pre.parentElement.clientWidth - 16) / charWidth();
    const ws = [...data.widths].sort((a, b) => b - a);
    return ws.find((w) => w + 1 <= room) || ws[ws.length - 1];
  };

  const rowsOf = () => layout.rows;
  const idAt = (r, s) => {
    const m = rowsOf()[r];
    if (!m) return null;
    if (s === "left") return m.l;
    if (s === "right") return m.r;
    return m.f ? focus : null;
  };

  const highlight = (code) => esc(code)
    .replace(/^(\s*)(\/\/.*)$/gm, '$1<span class="cm">$2</span>')
    .replace(/\b(func|return|if|for|range|var|type|struct|interface|package|import|defer|err != nil)\b/g, '<span class="kw">$1</span>');

  const preview = () => {
    const id = idAt(row, side) || focus;
    const n = data.nodes[id];
    if (!n) return;
    codePath.textContent = n.path + ":" + n.line;
    codePre.innerHTML = highlight(n.code.join("\n"));
  };

  const placeCursor = () => {
    const lh = parseFloat(getComputedStyle(pre).lineHeight);
    const ch = charWidth();
    let from = 0, to = width;
    if (side === "left") to = layout.left_end;
    else if (side === "right") from = layout.right_start;
    else { from = layout.left_end; to = layout.right_start; }
    Object.assign(cur.style, {
      top: pre.offsetTop + row * lh + "px",
      left: pre.offsetLeft + from * ch + "px",
      width: (to - from) * ch + "px",
      height: lh + "px",
    });
    cur.hidden = false;
  };

  const draw = () => {
    width = pickWidth();
    layout = view().widths[String(width)];
    pre.innerHTML = layout.lines.map((segs) => segs.map(([t, g]) => g ? '<span class="hl-' + g + '">' + cell(t) + "</span>" : cell(t)).join("")).join("\n");
    titleEl.textContent = view().name;
    nameEl.textContent = view().name;
    legendEl.textContent = view().legend.map((c) => c[0]).join("").replace(/[\u2691\u26a0]/g, "$&\uFE0E");
    back.disabled = history.length === 0;
    if (row >= layout.rows.length || !idAt(row, side)) {
      // land on the focus row
      const fr = layout.rows.findIndex((m) => m.f);
      row = fr < 0 ? 0 : fr; side = "focus";
    }
    placeCursor();
    preview();
  };

  const say = (msg) => { live.textContent = msg; };
  const describe = () => {
    const id = idAt(row, side);
    const n = id && data.nodes[id];
    return n ? n.name + ", " + (side === "left" ? "caller" : side === "right" ? "callee" : "focus") + ", " + n.path + ":" + n.line : "";
  };

  const reroot = (id) => {
    if (!id || !data.views[id]) {
      status.textContent = id && data.nodes[id] ? "A value use: nothing to re-root on." : "";
      return;
    }
    if (id === focus) return;
    history.push(focus);
    focus = id; row = 0; side = "focus";
    status.textContent = "";
    draw();
    say("Re-rooted on " + view().name);
  };
  const goBack = () => {
    if (!history.length) return;
    focus = history.pop(); row = 0; side = "focus";
    draw();
    say("Back to " + view().name);
  };

  const move = (dr, newSide) => {
    const rows = rowsOf();
    if (newSide) {
      // h/l: jump to the nearest row with a node on that side (or the focus)
      const order = [...rows.keys()].sort((a, b) => Math.abs(a - row) - Math.abs(b - row));
      const target = newSide === "focus" ? rows.findIndex((m) => m.f) : order.find((r) => idAt(r, newSide));
      if (target != null && target >= 0) { row = target; side = newSide; }
    } else {
      for (let r = row + dr; r >= 0 && r < rows.length; r += dr) {
        if (idAt(r, side)) { row = r; break; }
      }
    }
    placeCursor(); preview(); say(describe());
  };

  box.addEventListener("keydown", (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    const k = e.key;
    const sides = ["left", "focus", "right"];
    let handled = true;
    if (k === "j" || k === "ArrowDown") move(1);
    else if (k === "k" || k === "ArrowUp") move(-1);
    else if (k === "h" || k === "ArrowLeft") move(0, sides[Math.max(0, sides.indexOf(side) - 1)]);
    else if (k === "l" || k === "ArrowRight") move(0, sides[Math.min(2, sides.indexOf(side) + 1)]);
    else if (k === "." || k === "Enter") reroot(idAt(row, side));
    else if (k === "Backspace") goBack();
    else if (k === "y") doCopy();
    else handled = false;
    if (handled) e.preventDefault();
  });

  const hit = (ev) => {
    const rect = pre.getBoundingClientRect();
    const lh = parseFloat(getComputedStyle(pre).lineHeight);
    const r = Math.floor((ev.clientY - rect.top) / lh);
    const col = Math.floor((ev.clientX - rect.left) / charWidth());
    const s = col < layout.left_end ? "left" : col >= layout.right_start ? "right" : "focus";
    return { r, s, id: idAt(r, s) };
  };
  pre.addEventListener("click", (ev) => {
    const h = hit(ev);
    if (!h.id) return;
    row = h.r; side = h.s;
    if (h.id === focus) { placeCursor(); preview(); return; }
    reroot(h.id);
    if (!data.views[h.id]) { placeCursor(); preview(); }
  });
  pre.addEventListener("mousemove", (ev) => {
    const h = hit(ev);
    pre.style.cursor = h.id && (data.views[h.id] || h.id === focus) ? "pointer" : "default";
    if (h.id && (h.r !== row || h.s !== side)) { row = h.r; side = h.s; placeCursor(); preview(); }
  });

  const doCopy = async () => {
    const ok = await copyText(view().mermaid);
    status.textContent = ok ? "Copied the Mermaid for " + view().name + "." : "Copy failed.";
  };
  back.addEventListener("click", goBack);
  copyBtn.addEventListener("click", doCopy);

  let t;
  addEventListener("resize", () => { clearTimeout(t); t = setTimeout(draw, 120); });
  draw();
})();
