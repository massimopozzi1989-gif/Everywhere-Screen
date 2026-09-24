enum Page {
    private static let head = #"""
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <meta name="theme-color" content="#000000">
    <link rel="apple-touch-icon" href="/apple-touch-icon.png">
    """#

    /// Pagina per un tablet. Salvata sulla Home Screen gira a tutto schermo.
    static func viewer(channel: Int) -> String {
        """
        <!doctype html>
        <html lang="it">
        <head>
        \(head)
        <meta name="apple-mobile-web-app-title" content="Schermo \(channel)">
        <title>Everywhere Screen \(channel)</title>
        <style>\(viewerCSS)</style>
        </head>
        <body>
        \(viewerHTML)
        <script>const CH = \(channel);</script>
        <script>\(viewerJS)</script>
        </body>
        </html>
        """
    }

    /// Scelta dello schermo quando ne sono attivi più di uno.
    static func index(channels: [Int]) -> String {
        let links = channels.map { "<a href=\"/\($0)\">Schermo \($0)</a>" }.joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="it">
        <head>
        \(head)
        <meta name="apple-mobile-web-app-title" content="Everywhere Screen">
        <title>Everywhere Screen</title>
        <style>
          html, body { margin: 0; min-height: 100%; background: #000; color: #f2f2f2; font: 17px -apple-system, system-ui, sans-serif; }
          main { min-height: 100vh; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 14px; padding: 24px; box-sizing: border-box; }
          h1 { font-size: 24px; font-weight: 600; margin: 0; }
          p { color: #9a9a9f; margin: 0 0 10px; text-align: center; }
          a { display: block; width: min(320px, 100%); padding: 18px; text-align: center; border-radius: 14px; background: #1c1c1e; color: #fff; text-decoration: none; font-size: 20px; }
          a:active { background: #2c2c2e; }
        </style>
        </head>
        <body>
        <main>
        <h1>Everywhere Screen</h1>
        <p>Quale schermo mostra questo dispositivo?<br>Poi aggiungi la pagina alla Home Screen.</p>
        \(links)
        </main>
        </body>
        </html>
        """
    }

    private static let viewerCSS = #"""
    html, body { margin: 0; height: 100%; background: #000; overflow: hidden; overscroll-behavior: none;
      -webkit-user-select: none; user-select: none; -webkit-touch-callout: none; }
    #v, #i { position: fixed; inset: 0; width: 100%; height: 100%; object-fit: contain; pointer-events: none; }
    #surf { position: fixed; inset: 0; touch-action: none; }
    #s { position: fixed; top: max(12px, env(safe-area-inset-top)); left: 14px; color: #8e8e93;
      font: 13px -apple-system, system-ui, sans-serif; pointer-events: none; }
    #ident { position: fixed; left: 50%; top: 50%; width: 38vmin; height: 38vmin; margin: -19vmin 0 0 -19vmin;
      display: grid; place-items: center; border-radius: 9vmin; background: rgba(10, 132, 255, .88); color: #fff;
      font: 700 26vmin -apple-system, system-ui, sans-serif; pointer-events: none; opacity: 0;
      transform: scale(.85); transition: opacity .2s, transform .2s; }
    #ident.show { opacity: 1; transform: scale(1); }
    #kb { position: fixed; left: 0; bottom: 0; width: 1px; height: 1px; opacity: 0; font-size: 16px;
      border: 0; padding: 0; resize: none; }
    #bar { position: fixed; right: max(12px, env(safe-area-inset-right)); bottom: max(12px, env(safe-area-inset-bottom));
      display: flex; gap: 4px; padding: 5px; border-radius: 14px; background: rgba(44, 44, 46, .75);
      -webkit-backdrop-filter: blur(14px); backdrop-filter: blur(14px); opacity: .4; transition: opacity .2s; }
    #bar:active, #bar:hover { opacity: 1; }
    #bar button { width: 42px; height: 42px; border: 0; border-radius: 10px; background: transparent; color: #fff;
      display: grid; place-items: center; touch-action: manipulation; padding: 0; }
    #bar button.on { background: rgba(255, 255, 255, .2); }
    #bar button.off { opacity: .45; }
    #bar svg { width: 22px; height: 22px; }
    #pair { position: fixed; inset: 0; display: grid; place-items: center; background: #000; color: #f2f2f2;
      font: 17px -apple-system, system-ui, sans-serif; padding: 24px; box-sizing: border-box; }
    [hidden] { display: none !important; }
    .card { width: min(360px, 100%); text-align: center; }
    .card h1 { font-size: 24px; font-weight: 600; margin: 0 0 6px; }
    .card p { color: #9a9a9f; margin: 6px 0 22px; line-height: 1.4; }
    .card input { width: 100%; box-sizing: border-box; font: 600 32px ui-monospace, Menlo, monospace; letter-spacing: .3em;
      text-align: center; padding: 12px; border-radius: 12px; border: 1px solid #3a3a3c; background: #1c1c1e;
      color: #fff; margin-bottom: 14px; -webkit-user-select: text; user-select: text; }
    .primary { width: 100%; padding: 15px; border: 0; border-radius: 12px; background: #0a84ff; color: #fff;
      font: 600 17px -apple-system, system-ui, sans-serif; }
    .primary:active { background: #0071e3; }
    .err { color: #ff6961; min-height: 1.3em; margin-top: 14px !important; }
    """#

    private static let viewerHTML = #"""
    <video id="v" muted autoplay playsinline disablepictureinpicture></video>
    <img id="i" alt="" hidden>
    <div id="surf"></div>
    <div id="s">Connessione…</div>
    <div id="ident"></div>
    <textarea id="kb" autocapitalize="off" autocomplete="off" autocorrect="off" spellcheck="false"></textarea>
    <div id="bar" hidden>
      <button id="bKb" aria-label="Tastiera"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><rect x="2.5" y="6" width="19" height="12" rx="2.5"/><path d="M6.5 10h.01M9.5 10h.01M12.5 10h.01M15.5 10h.01M17.5 10h.01M8 14h8"/></svg></button>
      <button id="bCtl" aria-label="Controllo del Mac"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><path d="M6 3.5l12 7.2-5.3 1.4-2.6 5.4z"/></svg></button>
    </div>
    <div id="pair" hidden>
      <div class="card">
        <h1>Everywhere Screen</h1>
        <div id="step1">
          <p>Collega questo dispositivo al Mac.<br>Sul Mac comparirà un codice.</p>
          <button id="pStart" class="primary">Collega</button>
          <p class="err" id="e1"></p>
        </div>
        <div id="step2" hidden>
          <p>Inserisci il codice mostrato sul Mac.</p>
          <input id="code" inputmode="numeric" autocomplete="one-time-code" maxlength="7" placeholder="000000">
          <button id="pOk" class="primary">Conferma</button>
          <p class="err" id="e2"></p>
        </div>
      </div>
    </div>
    """#

    private static let viewerJS = #"""
    (() => {
    'use strict';
    const $ = id => document.getElementById(id);
    const video = $('v'), img = $('i'), surf = $('surf'), statusEl = $('s'), kb = $('kb'), bar = $('bar');
    const MS = window.MediaSource || window.ManagedMediaSource;
    let useMSE = !!(MS && MS.isTypeSupported && MS.isTypeSupported('video/mp4; codecs="avc1.640028"'));
    let ws = null, retry = null, allowed = false, enabled = true, pairId = null, lastFit = '';

    const status = t => { statusEl.textContent = t || ''; };
    const clamp = v => Math.min(1, Math.max(0, v));

    async function api(path) {
      const r = await fetch(path, { cache: 'no-store', credentials: 'same-origin' });
      let j = {};
      try { j = await r.json(); } catch (e) {}
      j.status = r.status;
      return j;
    }

    function deviceName() {
      const ua = navigator.userAgent;
      if (/iPad/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1)) return 'iPad';
      if (/Android/.test(ua)) return /Mobile/.test(ua) ? 'Telefono Android' : 'Tablet Android';
      if (/iPhone/.test(ua)) return 'iPhone';
      return 'Browser';
    }

    // ---------- Abbinamento ----------

    async function boot() {
      clearTimeout(retry);
      let me;
      try { me = await api('/api/me'); } catch (e) { me = { status: 0 }; }
      if (me.status === 200) { $('pair').hidden = true; connect(); }
      else if (me.status === 401) showPairing();
      else { status('Mac non raggiungibile…'); retry = setTimeout(boot, 2000); }
    }

    function showPairing() {
      if (ws) { ws.onclose = null; ws.close(); ws = null; }
      $('pair').hidden = false; $('step1').hidden = false; $('step2').hidden = true;
      $('e1').textContent = ''; status('');
    }

    $('pStart').onclick = async () => {
      $('e1').textContent = '';
      try {
        const r = await api('/api/pair/start?name=' + encodeURIComponent(deviceName()));
        if (!r.id) { $('e1').textContent = r.error || 'Riprova tra qualche secondo.'; return; }
        pairId = r.id;
        $('step1').hidden = true; $('step2').hidden = false;
        $('code').value = ''; $('e2').textContent = ''; $('code').focus();
      } catch (e) { $('e1').textContent = 'Mac non raggiungibile.'; }
    };

    $('pOk').onclick = async () => {
      const code = $('code').value.split(' ').join('');
      try {
        const r = await api('/api/pair/confirm?id=' + encodeURIComponent(pairId) + '&code=' + encodeURIComponent(code));
        if (r.ok) { $('code').blur(); $('pair').hidden = true; connect(); return; }
        if (r.restart) { showPairing(); $('e1').textContent = r.error || ''; }
        else $('e2').textContent = r.error || 'Codice errato.';
      } catch (e) { $('e2').textContent = 'Mac non raggiungibile.'; }
    };
    $('code').addEventListener('keydown', e => { e.stopPropagation(); if (e.key === 'Enter') $('pOk').click(); });

    // ---------- Connessione ----------

    function connect() {
      clearTimeout(retry);
      if (ws) { ws.onclose = null; ws.close(); }
      status('Connessione…');
      const sock = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/ws/' + CH);
      ws = sock;
      sock.binaryType = 'arraybuffer';
      sock.onopen = () => {
        sock.send(JSON.stringify({ t: 'hello', mse: useMSE }));
        lastFit = ''; fit();
        video.hidden = !useMSE; img.hidden = useMSE;
        if (!useMSE) img.src = '/stream/' + CH + '?t=' + Date.now();
      };
      sock.onmessage = e => {
        if (typeof e.data !== 'string') { player.append(e.data); return; }
        const m = JSON.parse(e.data);
        if (m.t === 'init') { player.reset(m.codec); status(''); }
        else if (m.t === 'info') { allowed = !!m.control; updateBar(); }
        else if (m.t === 'identify') identify(m.n);
      };
      sock.onclose = () => {
        if (ws !== sock) return;
        ws = null;
        status('Riconnessione…');
        retry = setTimeout(boot, 1000);   // boot ricontrolla anche l'abbinamento
      };
    }

    let identTimer = null;
    function identify(n) {
      const el = $('ident');
      el.textContent = n;
      el.classList.add('show');
      clearTimeout(identTimer);
      identTimer = setTimeout(() => el.classList.remove('show'), 2500);
    }

    const send = o => { if (ws && ws.readyState === 1) ws.send(JSON.stringify(o)); };
    const sendInput = o => { if (allowed && enabled) send(o); };

    // Risoluzione del dispositivo in punti, secondo l'orientamento: il Mac adatta lo schermo virtuale.
    const landscape = matchMedia('(orientation: landscape)');
    function fit() {
      const a = screen.width, b = screen.height;
      const w = landscape.matches ? Math.max(a, b) : Math.min(a, b);
      const h = landscape.matches ? Math.min(a, b) : Math.max(a, b);
      const key = w + 'x' + h;
      if (key === lastFit) return;
      lastFit = key;
      send({ t: 'fit', w: w, h: h });
    }
    landscape.addEventListener('change', fit);

    function fallbackMJPEG() {
      if (!useMSE) return;
      useMSE = false;
      connect();
    }

    // ---------- Video H.264 (Media Source Extensions) ----------

    const player = {
      ms: null, sb: null, q: [],
      reset(codec) {
        this.q = []; this.sb = null;
        const ms = new MS();
        this.ms = ms;
        if (window.ManagedMediaSource && ms instanceof window.ManagedMediaSource) video.disableRemotePlayback = true;
        ms.addEventListener('sourceopen', () => {
          if (this.ms !== ms) return;
          try { this.sb = ms.addSourceBuffer('video/mp4; codecs="' + codec + '"'); }
          catch (e) { fallbackMJPEG(); return; }
          this.sb.mode = 'segments';
          this.sb.addEventListener('updateend', () => this.after());
          this.pump();
        }, { once: true });
        video.src = URL.createObjectURL(ms);
      },
      append(buf) { this.q.push(buf); this.pump(); },
      pump() {
        const sb = this.sb;
        if (!sb || sb.updating || !this.q.length || this.ms.readyState !== 'open') return;
        try { sb.appendBuffer(this.q.shift()); } catch (e) { this.q = []; send({ t: 'kf' }); }
      },
      after() {
        const sb = this.sb, b = sb.buffered;
        if (b.length) {
          const start = b.start(0), end = b.end(b.length - 1);
          // Resta sempre a ridosso dell'ultimo frame: niente ritardo accumulato.
          if (video.currentTime < start || end - video.currentTime > 0.3) video.currentTime = Math.max(start, end - 0.05);
          if (video.paused) video.play().catch(() => {});
          if (!sb.updating && video.currentTime - start > 30) {
            try { sb.remove(start, video.currentTime - 10); return; } catch (e) {}
          }
        }
        this.pump();
      }
    };
    video.addEventListener('error', () => send({ t: 'kf' }));
    img.onload = () => status('');
    img.onerror = () => { if (!useMSE) { status('Riconnessione…'); retry = setTimeout(boot, 1000); } };

    // ---------- Tocco, Pencil, mouse ----------

    function pt(e) {
      const vw = useMSE ? video.videoWidth : img.naturalWidth, vh = useMSE ? video.videoHeight : img.naturalHeight;
      if (!vw || !vh) return null;
      const W = innerWidth, H = innerHeight, s = Math.min(W / vw, H / vh);
      const w = vw * s, h = vh * s;
      return { x: +clamp((e.clientX - (W - w) / 2) / w).toFixed(5), y: +clamp((e.clientY - (H - h) / 2) / h).toFixed(5) };
    }
    function mouse(k, p, b, extra) {
      if (p) sendInput(Object.assign({ t: 'p', k: k, x: p.x, y: p.y, b: b || 0 }, extra || {}));
    }

    const touches = new Map();
    let mode = null, downAt = null, lastP = null, longTimer = null, twoAt = 0, scrolled = false;
    const acc = { x: 0, y: 0 };
    let accPending = false;

    surf.addEventListener('pointerdown', e => {
      e.preventDefault();
      if (!(allowed && enabled)) return;
      const p = pt(e);
      if (!p) return;
      try { surf.setPointerCapture(e.pointerId); } catch (_) {}
      if (e.pointerType === 'mouse') { mouse('d', p, e.button === 2 ? 2 : 0); return; }
      if (e.pointerType === 'pen') { mouse('d', p, 0, { p: e.pressure || 0.5, pen: 1 }); return; }

      touches.set(e.pointerId, { x: e.clientX, y: e.clientY, sx: e.clientX, sy: e.clientY });
      if (touches.size === 1) {
        mode = 'pending'; downAt = p; lastP = p;
        mouse('m', p);
        clearTimeout(longTimer);
        longTimer = setTimeout(() => {          // pressione lunga = clic destro
          if (mode !== 'pending') return;
          mode = 'done';
          mouse('d', downAt, 2); mouse('u', downAt, 2);
        }, 550);
      } else if (touches.size === 2) {
        clearTimeout(longTimer);
        if (mode === 'drag') mouse('u', lastP, 0);
        mode = 'scroll'; twoAt = performance.now(); scrolled = false;
      }
    });

    surf.addEventListener('pointermove', e => {
      if (!(allowed && enabled)) return;
      if (e.pointerType === 'mouse') { mouse('m', pt(e)); return; }
      if (e.pointerType === 'pen') { mouse('m', pt(e), 0, e.buttons ? { p: e.pressure, pen: 1 } : { pen: 1 }); return; }
      const t = touches.get(e.pointerId);
      if (!t) return;
      const dx = e.clientX - t.x, dy = e.clientY - t.y;
      t.x = e.clientX; t.y = e.clientY;
      if (mode === 'pending' && Math.hypot(e.clientX - t.sx, e.clientY - t.sy) > 8) {
        clearTimeout(longTimer);
        mode = 'drag';
        mouse('d', downAt, 0);
      }
      if (mode === 'drag') {
        const p = pt(e);
        if (p) { lastP = p; mouse('m', p); }
      } else if (mode === 'scroll') {
        acc.x += dx / 2; acc.y += dy / 2; scrolled = true;   // media delle due dita
        if (!accPending) {
          accPending = true;
          requestAnimationFrame(() => {
            accPending = false;
            const sx = Math.round(acc.x), sy = Math.round(acc.y);
            acc.x -= sx; acc.y -= sy;
            if (sx || sy) sendInput({ t: 's', dx: sx, dy: sy });
          });
        }
      }
    });

    function pointerEnd(e) {
      if (e.pointerType === 'mouse') { mouse('u', pt(e) || lastP, e.button === 2 ? 2 : 0); return; }
      if (e.pointerType === 'pen') { mouse('u', pt(e) || lastP || downAt, 0, { pen: 1 }); return; }
      if (!touches.delete(e.pointerId)) return;
      if (mode === 'pending') {
        clearTimeout(longTimer);
        if (e.type === 'pointerup') { mouse('d', downAt, 0); mouse('u', downAt, 0); }
        mode = null;
      } else if (mode === 'drag') {
        mouse('u', pt(e) || lastP, 0);
        mode = null;
      } else if (mode === 'scroll' && touches.size === 0) {
        if (!scrolled && performance.now() - twoAt < 350) { mouse('d', downAt, 2); mouse('u', downAt, 2); }  // tap a due dita
        mode = null;
      }
      if (touches.size === 0 && mode === 'done') mode = null;
    }
    surf.addEventListener('pointerup', pointerEnd);
    surf.addEventListener('pointercancel', pointerEnd);
    surf.addEventListener('contextmenu', e => e.preventDefault());
    surf.addEventListener('wheel', e => {
      e.preventDefault();
      sendInput({ t: 's', dx: Math.round(-e.deltaX), dy: Math.round(-e.deltaY) });
    }, { passive: false });

    // ---------- Tastiera ----------

    const SENTINEL = '__';
    function resetKb() {
      kb.value = SENTINEL;
      try { kb.setSelectionRange(SENTINEL.length, SENTINEL.length); } catch (_) {}
    }
    resetKb();

    // Tastiera a schermo: si intercettano gli inserimenti invece di lasciare scrivere nel campo.
    kb.addEventListener('beforeinput', e => {
      const t = e.inputType;
      if (t === 'insertCompositionText' || t === 'insertFromComposition') return;
      if (t === 'insertText' || t === 'insertReplacementText') { if (e.data) sendInput({ t: 'txt', s: e.data }); }
      else if (t === 'insertFromPaste') {
        const s = e.dataTransfer && e.dataTransfer.getData('text/plain');
        if (s) sendInput({ t: 'txt', s: s });
      }
      else if (t === 'insertLineBreak' || t === 'insertParagraph') sendInput({ t: 'k', c: 'Enter', m: 0 });
      else if (t === 'deleteContentBackward') sendInput({ t: 'k', c: 'Backspace', m: 0 });
      else if (t === 'deleteWordBackward') sendInput({ t: 'k', c: 'Backspace', m: 4 });
      else if (t === 'deleteContentForward') sendInput({ t: 'k', c: 'Delete', m: 0 });
      e.preventDefault();
    });
    kb.addEventListener('compositionend', e => {
      if (e.data) sendInput({ t: 'txt', s: e.data });
      setTimeout(resetKb, 0);
    });
    kb.addEventListener('input', () => { if (!kb.isComposing) resetKb(); });

    // Tastiere fisiche: tasti speciali e scorciatoie (⌘C, ⌘V…) per posizione fisica.
    const MODIFIERS = ['Shift', 'Control', 'Alt', 'Meta', 'CapsLock'];
    document.addEventListener('keydown', e => {
      if (!$('pair').hidden || !(allowed && enabled) || MODIFIERS.includes(e.key)) return;
      const m = (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0) | (e.metaKey ? 8 : 0);
      const printable = !!e.key && e.key.length === 1;
      const special = !printable && !['Unidentified', 'Process', 'Dead'].includes(e.key);
      if (e.metaKey || e.ctrlKey || special) {
        const code = e.code || (printable ? 'Key' + e.key.toUpperCase() : e.key);
        sendInput({ t: 'k', c: code, m: m });
        e.preventDefault();
      } else if (printable && document.activeElement !== kb) {
        sendInput({ t: 'txt', s: e.key });
        e.preventDefault();
      }
    });

    // ---------- Barra strumenti ----------

    let kbOpen = false, kbWasOpen = false;
    kb.addEventListener('focus', () => { kbOpen = true; $('bKb').classList.add('on'); });
    kb.addEventListener('blur', () => { kbOpen = false; $('bKb').classList.remove('on'); });
    bar.addEventListener('pointerdown', e => { e.stopPropagation(); kbWasOpen = kbOpen; });
    $('bKb').addEventListener('click', () => {
      if (kbWasOpen) kb.blur(); else { resetKb(); kb.focus(); }
    });
    $('bCtl').addEventListener('click', () => {
      enabled = !enabled;
      if (!enabled) kb.blur();
      updateBar();
    });
    function updateBar() {
      bar.hidden = !allowed;
      $('bCtl').classList.toggle('off', !enabled);
      $('bKb').hidden = !enabled;
    }

    document.addEventListener('visibilitychange', () => { if (!document.hidden) boot(); });
    window.addEventListener('pageshow', e => { if (e.persisted) boot(); });
    boot();
    })();
    """#
}
