# Everywhere Screen — design

App macOS (barra dei menu) che crea fino a 3 schermi virtuali e li mostra su qualsiasi tablet
tramite browser, senza installare nulla sul tablet. Il tablet può anche controllare il Mac.

## Decisioni
- Nome: **Everywhere Screen**, bundle id `com.massimopozzi.everywherescreen`.
- Distribuzione: fuori dal Mac App Store (usa l'API privata `CGVirtualDisplay`), firmata
  Developer ID + notarizzata, DMG, aggiornamenti Sparkle da GitHub Releases.
- Modello: Free + Pro. Per ora nessun sistema di pagamento: `Edition.isPro = true`.
  Free (futuro): 1 schermo, solo visione. Pro: 8 schermi, controllo touch/Pencil/tastiera.
- Sicurezza: abbinamento con PIN a 6 cifre mostrato sul Mac → token per dispositivo (cookie
  HttpOnly). Senza token niente video né controllo. Dispositivi revocabili dal menu.
  HTTP in chiaro sulla LAN; HTTPS (profilo certificato da installare sul tablet) in una fase futura.

- Lingue: italiano e inglese (`L10n.swift`, `tr(it, en)` accanto a ogni testo). Scelta nel menu
  "Lingua · Language": automatica (Mac = lingue di macOS, tablet = Accept-Language del browser,
  altrimenti inglese) oppure fissa per Mac e tablet. Al cambio i tablet ricaricano la pagina.

## Architettura
- `VirtualScreen` — schermo virtuale HiDPI (CGVirtualDisplay), seriale fisso per slot.
- `ScreenCapturer` — ScreenCaptureKit, pixel buffer 4:2:0, cursore incluso.
- `StreamHub` (uno per schermo) — codifica H.264 (VideoToolbox, low-latency, hardware) solo se
  ci sono client H.264; JPEG solo se ci sono client MJPEG. Tiene l'ultimo frame per poter
  inviare subito un keyframe ai nuovi client anche a schermo fermo.
- `FMP4Muxer` — fMP4 per Media Source Extensions; timeline contigua (durata fissa 1/fps per
  frame): a schermo fermo il player si ferma sull'ultimo frame e riparte senza accumulare ritardo.
- `WebSocket` / `HTTPServer` — un'unica porta (5050): pagine, API di abbinamento, `/ws/N`
  (video + input), `/stream/N` (MJPEG di ripiego).
- Backpressure: se un client accumula troppi dati non inviati, si scartano i suoi frame; il
  keyframe per ripartire si chiede solo quando ha smaltito l'arretrato (chiederlo a ogni frame
  renderebbe keyframe lo stream di tutti gli altri). Un client fermo da 10 s viene chiuso.
- Connessioni: header entro 10 s (niente connessioni appese), TCP keepalive per scoprire i
  tablet spariti anche a schermo fermo. La prima sessione VideoToolbox (~0,6 s) si crea all'avvio.
- `InputInjector` — CGEvent: mouse (clic, doppio clic, trascinamento, destro), scroll in pixel,
  testo Unicode, tasti con modificatori (per posizione fisica, `KeyboardEvent.code`), pressione
  della Pencil. Richiede il permesso Accessibilità.

## Gesti sul tablet
- tap = clic · doppio/triplo tap = doppio/triplo clic (il tablet decide il numero di clic e lo
  manda in `c`: le dita non tornano mai nello stesso punto, la tolleranza è 40 px e 500 ms)
- schermo intero: Fullscreen API sull'intera pagina (iPad, Android); con l'opzione del Mac il
  tablet lo propone al primo tocco (il browser lo concede solo dopo un gesto). Su iPhone: Home Screen.
- trascinare = drag · pressione lunga o tap a due dita = clic destro
- due dita = scroll · Apple Pencil = mouse preciso con pressione (hover se supportato)
- mouse/trackpad dell'iPad = mouse · pulsante tastiera = tastiera a schermo; tastiere fisiche
  con scorciatoie (⌘C, ⌘V…)

## Protocollo WebSocket `/ws/N`
- client → Mac (JSON): `hello{mse}`, `fit{w,h}`, `kf`, `p{k:d|m|u,x,y,b,c,p,pen}`, `s{dx,dy}`,
  `txt{s}`, `k{c,m}` (m: 1 shift, 2 ctrl, 4 alt, 8 cmd)
- Mac → client: JSON `init{codec}` seguito da init segment binario, poi media segment binari;
  JSON `info{control,fs}`.
