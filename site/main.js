(() => {
  'use strict';

  document.documentElement.classList.add('js');
  const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;

  // ---------- Pixel scene ----------
  // The demo is drawn at 192×120 and scaled up with `image-rendering: pixelated`.
  // Every coordinate below is in those logical pixels.

  const C = {
    wallpaper: '#171724',
    dither: '#1e1e30',
    menubar: '#0c0c14',
    window: '#262639',
    titlebar: '#30304a',
    sidebar: '#1f1f31',
    strip: '#2b2b42',
    code: '#1e1e2e',
    line: '#3a3a5c',
    textHi: '#e0e0ee',
    textLo: '#9a9ab4',
    textDim: '#5c5c78',
    accent: '#6b5cfa',      // Palette.accent
    hint: '#ffd147',        // Palette.hintLeaf
    cyan: '#61d6f5',
    pink: '#fa85b3',
    green: '#85e68f',
    violet: '#cca8ff',
    red: '#ff5a5a',
    chrome: '#0e0e16',
    ink: '#12121a',
  };

  // 3×5 pixel font, rows top to bottom.
  const GLYPHS = {
    A: '010101111101101', C: '011100100100011', D: '110101101101110', E: '111100110100111',
    F: '111100110100100', I: '111010010010111', L: '100100100100111', M: '101111111101101',
    N: '110101101101101', O: '010101101101010', P: '110101110100100', S: '011100010001110',
    T: '111010010010010', W: '101101111111101', '!': '010010010000010',
  };

  const W1 = { x: 6, y: 9, w: 100, h: 104 };    // chat
  const W2 = { x: 112, y: 9, w: 74, h: 54 };    // code editor, focused when the picker opens
  const W3 = { x: 112, y: 68, w: 74, h: 45 };   // browser

  const M0 = { x: 28, y: 23, w: 78, h: 16 };
  const M1 = { x: 28, y: 39, w: 78, h: 38 };    // the message with the chart: what gets captured
  const M2 = { x: 28, y: 77, w: 78, h: 16 };
  const M3 = { x: 28, y: 93, w: 78, h: 10 };

  // Hint labels in the chat window. Containers get an outline in their label's color, like the app.
  const HINTS = [
    { label: 'AS', rect: { x: 6, y: 15, w: 22, h: 98 }, color: C.cyan, outline: true },
    { label: 'AD', rect: { x: 28, y: 15, w: 78, h: 8 }, color: C.hint },
    { label: 'SA', rect: M0, color: C.hint },
    { label: 'SD', rect: M1, color: C.pink, outline: true },
    { label: 'SF', rect: M2, color: C.hint },
    { label: 'DA', rect: M3, color: C.hint },
    { label: 'DS', rect: { x: 28, y: 103, w: 78, h: 10 }, color: C.hint },
  ];

  const CENTER = { x: M1.x + Math.floor(M1.w / 2), y: M1.y + Math.floor(M1.h / 2) };

  // The script. Each event changes the state at its time; `seg` is the feature it illustrates.
  const EVENTS = [
    { at: 0, keys: [], text: 'Any app, any desktop.', seg: 0, run: s => { s.mode = 'desktop'; } },
    { at: 1000, keys: ['⇧⌘S'], text: 'opens the picker on the focused window', seg: 0,
      run: (s, at) => { s.mode = 'window'; select(s, W2, at, true); } },
    { at: 2400, keys: ['j'], text: 'jumps to the window below', seg: 1, run: (s, at) => select(s, W3, at) },
    { at: 3500, keys: ['h'], text: 'and to the one on the left', seg: 1, run: (s, at) => select(s, W1, at) },
    { at: 4800, keys: ['f'], text: 'labels every element in it', seg: 2, run: s => { s.mode = 'hints'; s.typed = ''; } },
    { at: 5900, keys: ['s'], text: 'type a label…', seg: 2, run: s => { s.typed = 'S'; } },
    { at: 6500, keys: ['d'], text: '…and that element is selected', seg: 2,
      run: (s, at) => { s.typed = 'SD'; s.mode = 'element'; select(s, M1, at); } },
    { at: 8000, keys: ['⇧↵'], text: 'freezes it in the editor', seg: 3,
      run: (s, at) => { s.mode = 'editor'; glide(s, CENTER, at, 0); } },
    { at: 9000, keys: ['l'], text: 'moves the cursor', seg: 3, run: (s, at) => glide(s, { x: 95, y: 63 }, at, 200) },
    { at: 9700, keys: ['a'], text: 'starts an arrow', seg: 3, run: (s, at) => { s.arrow = { start: cursorAt(s, at), end: null }; } },
    { at: 10300, keys: ['k', 'h'], text: 'held together, glides', seg: 3, run: (s, at) => glide(s, { x: 72, y: 51 }, at, 900) },
    { at: 11500, keys: ['a'], text: 'finishes it', seg: 3, run: (s, at) => { s.arrow.end = cursorAt(s, at); } },
    { at: 12600, keys: ['y'], text: 'copies it. s saves a PNG instead.', seg: 4, run: (s, at) => { s.mode = 'copied'; s.copiedAt = at; } },
  ];
  const LOOP = 16000;
  const SEG_START = [0, 1, 2, 3, 4].map(i => EVENTS.find(e => e.seg === i).at);
  const segEnd = i => (i + 1 < SEG_START.length ? SEG_START[i + 1] : LOOP);

  const clamp01 = v => Math.max(0, Math.min(1, v));
  const ease = p => 1 - Math.pow(1 - p, 3);
  const lerp = (a, b, p) => Math.round(a + (b - a) * p);

  function select(s, rect, at, instant) {
    const from = instant || !s.sel ? rect : selAt(s, at);
    s.sel = { from, to: rect, at };
  }
  function selAt(s, t) {
    const { from, to, at } = s.sel;
    const p = ease(clamp01((t - at) / 180));
    return { x: lerp(from.x, to.x, p), y: lerp(from.y, to.y, p), w: lerp(from.w, to.w, p), h: lerp(from.h, to.h, p) };
  }
  function glide(s, to, at, dur) {
    const from = s.cursor ? cursorAt(s, at) : to;
    s.cursor = { from, to, at, dur };
  }
  function cursorAt(s, t) {
    const { from, to, at, dur } = s.cursor;
    const p = dur ? clamp01((t - at) / dur) : 1;
    return { x: lerp(from.x, to.x, p), y: lerp(from.y, to.y, p) };
  }

  function stateAt(t) {
    const s = { mode: 'desktop', sel: null, typed: '', cursor: null, arrow: null, copiedAt: 0, event: EVENTS[0] };
    for (const e of EVENTS) {
      if (e.at > t) break;
      e.run(s, e.at);
      s.event = e;
    }
    return s;
  }

  // ---------- Drawing ----------

  function painter(ctx) {
    const rect = (x, y, w, h, color) => { ctx.fillStyle = color; ctx.fillRect(x, y, w, h); };
    const px = (x, y, color) => rect(x, y, 1, 1, color);
    const outline = (r, color, inset = 0) => {
      const x = r.x + inset, y = r.y + inset, w = r.w - inset * 2, h = r.h - inset * 2;
      // Corner pixels left out, so the border reads as rounded.
      rect(x + 1, y, w - 2, 1, color);
      rect(x + 1, y + h - 1, w - 2, 1, color);
      rect(x, y + 1, 1, h - 2, color);
      rect(x + w - 1, y + 1, 1, h - 2, color);
    };
    const text = (str, x, y, color) => {
      for (const ch of str) {
        const g = GLYPHS[ch];
        if (g) for (let i = 0; i < 15; i++) if (g[i] === '1') px(x + (i % 3), y + Math.floor(i / 3), color);
        x += 4;
      }
    };
    const line = (x0, y0, x1, y1, color, size = 1) => {
      // Bresenham, so the line stays one crisp pixel wide.
      const dx = Math.abs(x1 - x0), dy = -Math.abs(y1 - y0);
      const sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1;
      let err = dx + dy;
      for (;;) {
        rect(x0, y0, size, size, color);
        if (x0 === x1 && y0 === y1) break;
        const e2 = 2 * err;
        if (e2 >= dy) { err += dy; x0 += sx; }
        if (e2 <= dx) { err += dx; y0 += sy; }
      }
    };
    return { ctx, rect, px, outline, text, line };
  }

  function drawWindow(p, w) {
    p.rect(w.x, w.y, w.w, w.h, C.window);
    p.rect(w.x, w.y, w.w, 6, C.titlebar);
    p.rect(w.x + 3, w.y + 2, 2, 2, '#ff6b6b');
    p.rect(w.x + 6, w.y + 2, 2, 2, C.hint);
    p.rect(w.x + 9, w.y + 2, 2, 2, C.green);
    for (const [cx, cy] of [[w.x, w.y], [w.x + w.w - 1, w.y], [w.x, w.y + w.h - 1], [w.x + w.w - 1, w.y + w.h - 1]]) {
      p.px(cx, cy, C.wallpaper);
    }
  }

  function message(p, m, avatar, nameW, lines) {
    p.rect(m.x + 3, m.y + 2, 6, 6, avatar);
    p.rect(m.x + 12, m.y + 2, nameW, 1, C.textHi);
    p.rect(m.x + 14 + nameW, m.y + 2, 7, 1, C.textDim);
    lines.forEach((len, i) => p.rect(m.x + 12, m.y + 5 + i * 3, len, 1, C.textLo));
  }

  function drawDesktop(p) {
    p.rect(0, 0, 192, 120, C.wallpaper);
    for (let y = 6; y < 120; y += 2) {
      for (let x = (y % 4 === 0 ? 0 : 2); x < 192; x += 4) p.px(x, y, C.dither);
    }

    // Menu bar, with Vishot's own icon on the right.
    p.rect(0, 0, 192, 5, C.menubar);
    p.rect(3, 1, 3, 3, '#c8c8da');
    [[9, 8], [20, 6], [29, 7], [39, 5]].forEach(([x, w]) => p.rect(x, 2, w, 1, '#8a8aa6'));
    p.outline({ x: 157, y: 1, w: 5, h: 3 }, C.accent);
    p.rect(166, 2, 10, 1, '#8a8aa6');
    p.rect(179, 2, 9, 1, '#c8c8da');

    // W1: chat.
    drawWindow(p, W1);
    p.rect(6, 15, 22, 97, C.sidebar);
    p.rect(9, 18, 5, 5, C.accent);
    for (let i = 0; i < 7; i++) {
      if (i === 2) p.rect(7, 26 + i * 6, 20, 3, '#3b3570');
      p.rect(9, 27 + i * 6, 9 + (i % 3) * 3, 1, i === 2 ? '#d6d2ff' : '#6c6c8a');
    }
    p.rect(28, 15, 78, 8, C.strip);
    p.rect(31, 18, 18, 1, C.textHi);
    p.rect(93, 18, 10, 1, C.textDim);
    message(p, M0, C.cyan, 16, [52, 40]);
    message(p, M1, C.pink, 14, [46]);
    message(p, M2, C.green, 12, [48, 30]);
    message(p, M3, C.violet, 18, [36]);
    p.rect(30, 104, 74, 7, C.strip);
    p.rect(33, 106, 1, 3, C.textLo);

    // The chart inside M1, with the spike the arrow will point at.
    const box = { x: 39, y: 47, w: 64, h: 27 };
    p.rect(box.x, box.y, box.w, box.h, '#1a1a2a');
    p.outline(box, C.line);
    [54, 61, 67].forEach(y => { for (let x = box.x + 2; x < box.x + box.w - 2; x += 2) p.px(x, y, '#26263a'); });
    [5, 8, 6, 18, 9, 7, 10].forEach((h, i) => p.rect(43 + i * 8, 71 - h, 4, h, i === 3 ? C.red : C.cyan));
    p.rect(41, 71, 60, 1, '#4a4a6a');

    // W2: code editor.
    drawWindow(p, W2);
    p.rect(W2.x, W2.y + 6, W2.w, W2.h - 7, C.code);
    const code = [
      [[C.pink, 6], [C.textHi, 18]],
      [[C.textHi, 4], [C.violet, 10], [C.textHi, 8]],
      [[C.pink, 4], [C.green, 22]],
      [[C.textHi, 12], [C.cyan, 8]],
      [],
      [[C.pink, 6], [C.textHi, 14], [C.green, 10]],
      [[C.textHi, 8], [C.cyan, 12]],
      [[C.pink, 4], [C.textHi, 6]],
      [[C.textHi, 3]],
    ];
    code.forEach((segments, i) => {
      const y = W2.y + 10 + i * 5;
      p.rect(W2.x + 3, y, 3, 1, '#44445e');
      let x = W2.x + 10 + (i % 3 === 1 ? 4 : i % 3 === 2 ? 8 : 0);
      for (const [color, len] of segments) { p.rect(x, y, len, 1, color); x += len + 2; }
    });

    // W3: browser.
    drawWindow(p, W3);
    p.rect(W3.x + 4, W3.y + 8, W3.w - 8, 4, C.strip);
    p.rect(W3.x + 7, W3.y + 9, 20, 2, C.textDim);
    p.rect(116, 83, 30, 25, '#24305a');
    p.rect(138, 86, 3, 3, C.hint);
    for (let i = 0; i < 12; i++) p.rect(118 + i, 101 - Math.min(i, 11 - i) * 2, 1, 7 + Math.min(i, 11 - i) * 2, '#3d5a99');
    for (let i = 0; i < 10; i++) p.rect(132 + i, 104 - Math.min(i, 9 - i), 1, 4 + Math.min(i, 9 - i), '#5878c2');
    p.rect(150, 84, 28, 2, C.textHi);
    [30, 26, 28].forEach((w, i) => p.rect(150, 89 + i * 3, w, 1, C.textLo));
    p.rect(150, 100, 16, 5, C.green);
  }

  function drawHUD(p, label) {
    const w = label.length * 4 + 9;
    const x = 96 - Math.floor(w / 2);
    p.rect(x, 112, w, 8, C.chrome);
    p.rect(x + 2, 114, 3, 3, C.accent);
    p.text(label, x + 7, 113, C.textHi);
  }

  function drawHints(p, typed) {
    for (const h of HINTS) {
      if (!h.label.startsWith(typed)) continue;
      if (h.outline) p.outline(h.rect, h.color);
      const x = h.rect.x + 1, y = h.rect.y + 1;
      p.rect(x, y, 9, 7, h.color);
      p.text(h.label.slice(0, typed.length), x + 1, y + 1, '#8c7430');
      p.text(h.label.slice(typed.length), x + 1 + typed.length * 4, y + 1, C.ink);
    }
  }

  function drawArrow(p, from, to) {
    if (from.x === to.x && from.y === to.y) return;
    p.line(from.x, from.y, to.x, to.y, C.red, 2);
    const a = Math.atan2(to.y - from.y, to.x - from.x);
    for (const da of [-0.6, 0.6]) {
      p.line(to.x, to.y, Math.round(to.x - 6 * Math.cos(a + da)), Math.round(to.y - 6 * Math.sin(a + da)), C.red, 2);
    }
  }

  function drawEditor(p, s, t) {
    const r = M1;
    p.ctx.fillStyle = 'rgba(5, 5, 10, 0.62)';
    p.ctx.fillRect(0, 0, 192, r.y);
    p.ctx.fillRect(0, r.y + r.h, 192, 120 - r.y - r.h);
    p.ctx.fillRect(0, r.y, r.x, r.h);
    p.ctx.fillRect(r.x + r.w, r.y, 192 - r.x - r.w, r.h);
    p.outline({ x: r.x - 1, y: r.y - 1, w: r.w + 2, h: r.h + 2 }, C.accent);

    const cursor = cursorAt(s, t);
    // Crosshair, with a gap in the middle so the aimed pixel stays visible.
    for (let d = 1; d <= 3; d++) {
      p.px(cursor.x - d, cursor.y, '#fff'); p.px(cursor.x + d, cursor.y, '#fff');
      p.px(cursor.x, cursor.y - d, '#fff'); p.px(cursor.x, cursor.y + d, '#fff');
    }
    // Over the crosshair, so a finished arrow's head stays visible.
    if (s.arrow) drawArrow(p, s.arrow.start, s.arrow.end || cursor);

    // Toolbar below the image: arrow (active), box, text, crop, then colors.
    const tb = { x: 40, y: 80, w: 58, h: 10 };
    p.rect(tb.x, tb.y, tb.w, tb.h, C.chrome);
    p.outline(tb, C.line);
    p.rect(tb.x + 2, tb.y + 2, 7, 6, C.accent);
    p.line(tb.x + 3, tb.y + 6, tb.x + 7, tb.y + 3, '#fff');
    p.rect(tb.x + 6, tb.y + 3, 2, 1, '#fff'); p.px(tb.x + 7, tb.y + 4, '#fff');
    p.outline({ x: tb.x + 11, y: tb.y + 3, w: 5, h: 4 }, C.textLo);
    p.rect(tb.x + 18, tb.y + 3, 3, 1, C.textLo); p.rect(tb.x + 19, tb.y + 4, 1, 3, C.textLo);
    p.rect(tb.x + 23, tb.y + 3, 1, 4, C.textLo); p.rect(tb.x + 23, tb.y + 6, 4, 1, C.textLo);
    p.rect(tb.x + 25, tb.y + 2, 1, 3, C.textLo);
    [C.red, C.hint, C.green, C.cyan, '#ffffff'].forEach((color, i) => {
      p.rect(tb.x + 31 + i * 5, tb.y + 4, 3, 3, color);
    });
    p.outline({ x: tb.x + 30, y: tb.y + 3, w: 5, h: 5 }, '#fff');
  }

  function drawCopied(p, s, t) {
    const dt = t - s.copiedAt;
    if (dt < 140) {
      p.ctx.fillStyle = `rgba(255, 255, 255, ${0.7 * (1 - dt / 140)})`;
      p.ctx.fillRect(0, 0, 192, 120);
      return;
    }
    const slide = Math.round((1 - ease(clamp01((dt - 140) / 260))) * 72);
    const x = 118 + slide, y = 8;
    p.rect(x, y, 68, 12, C.chrome);
    p.outline({ x, y, w: 68, h: 12 }, C.accent);
    // A thumbnail of the capture: the chart with its red spike and the arrow.
    p.rect(x + 3, y + 3, 11, 6, '#1a1a2a');
    p.rect(x + 7, y + 4, 1, 4, C.red);
    p.rect(x + 5, y + 6, 1, 2, C.cyan); p.rect(x + 10, y + 5, 1, 3, C.cyan);
    p.px(x + 9, y + 4, C.red); p.px(x + 10, y + 3, C.red);
    p.text('COPIED!', x + 18, y + 4, C.textHi);
  }

  function setupScene() {
    const canvas = document.getElementById('scene');
    if (!canvas || !canvas.getContext) return null;
    const ctx = canvas.getContext('2d');
    const p = painter(ctx);

    const desktop = document.createElement('canvas');
    desktop.width = 192;
    desktop.height = 120;
    drawDesktop(painter(desktop.getContext('2d')));

    return function render(t) {
      const s = stateAt(t);
      ctx.drawImage(desktop, 0, 0);
      switch (s.mode) {
        case 'window':
        case 'element':
          p.outline(grow(selAt(s, t)), C.accent);
          drawHUD(p, s.mode === 'window' ? 'WINDOW' : 'ELEMENT');
          break;
        case 'hints':
          p.outline(grow(s.sel.to), C.accent);
          drawHints(p, s.typed);
          drawHUD(p, 'ELEMENT');
          break;
        case 'editor':
          drawEditor(p, s, t);
          break;
        case 'copied':
          drawCopied(p, s, t);
          break;
      }
      return s;
    };
  }

  const grow = r => ({ x: r.x - 1, y: r.y - 1, w: r.w + 2, h: r.h + 2 });

  // ---------- Playback, keycast and the feature list ----------

  const render = setupScene();
  const features = [...document.querySelectorAll('.feature')];
  const keycastKeys = document.querySelector('.keycast-keys');
  const keycastText = document.querySelector('.keycast-text');
  const playButton = document.querySelector('.playpause');

  let playing = !reducedMotion;
  let origin = performance.now();
  let pausedAt = reducedMotion ? segEnd(0) - 1 : 0;
  let visible = true;
  let shownEvent = null;
  let shownSeg = -1;

  const now = () => (playing ? (performance.now() - origin) % LOOP : pausedAt);

  function show(t) {
    if (!render) return;
    const s = render(t);
    const seg = s.event.seg;

    if (s.event !== shownEvent) {
      shownEvent = s.event;
      keycastKeys.replaceChildren(...s.event.keys.map(k => {
        const kbd = document.createElement('kbd');
        kbd.textContent = k;
        return kbd;
      }));
      keycastText.textContent = s.event.text;
    }
    if (seg !== shownSeg) {
      shownSeg = seg;
      features.forEach((f, i) => f.classList.toggle('active', i === seg));
    }
    const done = clamp01((t - SEG_START[seg]) / (segEnd(seg) - SEG_START[seg]));
    // Stepped, like everything else on the page.
    features[seg].querySelector('.progress').style.transform = `scaleX(${Math.floor(done * 16) / 16})`;
    features.forEach((f, i) => { if (i !== seg) f.querySelector('.progress').style.transform = 'scaleX(0)'; });
  }

  function frame() {
    if (playing && visible) show(now());
    requestAnimationFrame(frame);
  }

  function seek(t) {
    origin = performance.now() - t;
    pausedAt = t;
    show(t);
  }

  function seekSegment(i) {
    const n = SEG_START.length;
    i = ((i % n) + n) % n;
    // While paused, show the segment's last frame: it holds the whole step (the drawn arrow, the toast).
    seek(playing ? SEG_START[i] : segEnd(i) - 1);
  }

  function syncPlayButton() {
    playButton.toggleAttribute('data-paused', !playing);
    playButton.setAttribute('aria-label', playing ? 'Pause the demo' : 'Play the demo');
  }

  function setPlaying(on) {
    if (on === playing) return;
    if (on) origin = performance.now() - pausedAt;
    else pausedAt = now();
    playing = on;
    syncPlayButton();
  }

  if (render) {
    playButton.addEventListener('click', () => setPlaying(!playing));
    syncPlayButton();

    features.forEach((f, i) => f.querySelector('.feature-head').addEventListener('click', () => seekSegment(i)));

    // The page answers to the same keys as the app.
    document.addEventListener('keydown', e => {
      if (e.metaKey || e.ctrlKey || e.altKey || e.target.closest('input, textarea, select')) return;
      if (e.key === 'j') seekSegment(shownSeg + 1);
      else if (e.key === 'k') seekSegment(shownSeg - 1);
      else if (e.key >= '1' && e.key <= '5') seekSegment(Number(e.key) - 1);
      else return;
      e.preventDefault();
    });

    // Don't spend frames on a demo nobody can see.
    new IntersectionObserver(([entry]) => { visible = entry.isIntersecting; })
      .observe(document.getElementById('scene'));

    show(now());
    requestAnimationFrame(frame);
  }

  // ---------- Headline dissolve and reveals ----------

  function dissolve(el) {
    const block = 10;
    const canvas = document.createElement('canvas');
    canvas.className = 'dissolve';
    canvas.setAttribute('aria-hidden', 'true');
    el.append(canvas);
    const ctx = canvas.getContext('2d');

    const cover = () => {
      const box = canvas.getBoundingClientRect();
      canvas.width = Math.ceil(box.width / block);
      canvas.height = Math.ceil(box.height / block);
      ctx.fillStyle = getComputedStyle(document.body).backgroundColor;
      ctx.fillRect(0, 0, canvas.width, canvas.height);
    };
    cover();

    document.fonts.ready.then(() => {
      cover();
      const cells = [];
      for (let y = 0; y < canvas.height; y++) {
        for (let x = 0; x < canvas.width; x++) cells.push({ x, y, k: x / canvas.width + Math.random() * 0.7 });
      }
      cells.sort((a, b) => a.k - b.k);
      const start = performance.now();
      const duration = 750;
      let cleared = 0;
      const tick = () => {
        const target = Math.floor(cells.length * clamp01((performance.now() - start) / duration));
        for (; cleared < target; cleared++) ctx.clearRect(cells[cleared].x, cells[cleared].y, 1, 1);
        if (cleared < cells.length) requestAnimationFrame(tick);
        else canvas.remove();
      };
      requestAnimationFrame(tick);
    });
  }

  if (!reducedMotion) {
    dissolve(document.querySelector('.headline'));

    const items = [
      document.querySelector('.lede'),
      document.querySelector('.waitlist'),
      document.querySelector('.screen'),
      ...features,
    ];
    const io = new IntersectionObserver(entries => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.add('in');
        io.unobserve(entry.target);
      }
    }, { rootMargin: '0px 0px -40px 0px' });
    items.forEach((el, i) => {
      el.classList.add('reveal');
      el.style.animationDelay = `${450 + i * 70}ms`;
      io.observe(el);
    });
  }

  // ---------- Waitlist ----------

  const form = document.getElementById('waitlist');
  const input = document.getElementById('email');
  const error = document.getElementById('email-error');
  const status = form.querySelector('.status');
  const submit = form.querySelector('button');

  function validate() {
    let message = '';
    if (input.validity.valueMissing) message = 'Enter your email address.';
    else if (!input.validity.valid) message = "That doesn't look like an email address.";
    error.textContent = message;
    input.setAttribute('aria-invalid', String(Boolean(message)));
    return !message;
  }

  input.addEventListener('blur', () => { if (input.value) validate(); });
  input.addEventListener('input', () => { if (input.getAttribute('aria-invalid') === 'true') validate(); });

  form.addEventListener('submit', async e => {
    e.preventDefault();
    if (!validate()) { input.focus(); return; }
    submit.disabled = true;
    status.textContent = 'Joining…';
    try {
      // Buttondown's embed endpoint doesn't send CORS headers, so the response is opaque:
      // a network failure throws, anything else counts as subscribed.
      await fetch(form.action, {
        method: 'POST',
        mode: 'no-cors',
        body: new URLSearchParams(new FormData(form)),
      });
      form.classList.add('done');
      form.querySelector('label').textContent = "You're on the list";
      status.textContent = "Thanks! Check your inbox to confirm, and we'll write when the beta opens.";
    } catch {
      status.textContent = '';
      error.textContent = "That didn't go through. Check your connection and try again.";
    } finally {
      submit.disabled = false;
    }
  });
})();
