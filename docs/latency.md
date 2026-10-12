# Streaming latency changes

Based on `origin/main` at `13e9cb2` (Everywhere Screen 1.3.0), fetched on
2026-10-09. The transport remains H.264/fMP4 over WebSocket with MJPEG fallback;
no new runtime dependencies or changes to pairing, gestures or saved preferences.
Existing native APIs are sufficient for this optimization.

## Changes

Revised on 2026-10-12 (1.3.2) after testing the first version of these changes.

- **Real end-to-end lag.** The browser acknowledges every binary message it
  receives (`{"t":"a","b":<total bytes>}`). The server tracks the age of the
  oldest unacknowledged frame: above 200 ms it stops sending dependent frames
  and resumes with a keyframe once everything sent has arrived. This sees the
  delay held in the Mac's TCP buffers and on Wi-Fi, which the local send queue
  cannot. Clients that never acknowledge (older pages, test clients) keep the
  local-queue checks below.
- **Local send queue.** A viewer is behind when its oldest send has waited
  250 ms or more than 1 MB is queued. The first version measured "time since the
  queue was last empty", which at 60 fps never resets even on a fast network and
  caused needless skips and keyframes.
- **Adaptive bitrate.** When every video viewer of a channel falls behind, the
  bitrate drops by 30% (down to 35%) and climbs back 15% every 2 s after 4 s
  without trouble. A single slow or sleeping tablet does not lower the quality
  of the others.
- **Player.** Segments queued while the SourceBuffer is busy are appended in one
  call. The player restarts from a keyframe only when the decoder is stuck for
  1 s, not after 120 ms. It catches up with the live edge by playing up to 1.5×
  faster and seeks only when more than 500 ms behind: a seek makes the decoder
  start again from the last keyframe (up to 10 s earlier), visible as a stutter
  on an iPad. Old data is freed up to the newest frame, never past it: Chrome
  lets the playhead run ahead of the buffer on a static screen and the previous
  rule could delete the frame still needed (frozen image).
- **Watchdog.** If no video is decoded 6 s after connecting, the page reconnects;
  after a second failure it switches to MJPEG.
- `?debug` in the address shows player lag, playback rate, decoded fps and
  dropped frames.
- ScreenCaptureKit uses 4 surfaces (the hub can hold two: the one being encoded
  and the last one, kept for refreshes). VideoToolbox keeps
  `MaxFrameDelayCount = 0`; recovery keyframes are coalesced over 50 ms; FPS
  changes reinitialize the MP4 timeline (unchanged from the first version).

## Verification

- `scripts/test.sh`, `node Tests/Player/main.js`: layout geometry and the real
  embedded player with MediaSource doubles (batched appends, stuck decoder,
  live-edge catch-up by playback rate, buffer removal never past the newest
  frame, stale callbacks, segment order).
- `scripts/stress.sh`: synthetic video over real sockets. Half of the streaming
  viewers acknowledge like the browser, half do not. New scenario "Wi-Fi in
  ritardo": a viewer whose acknowledgements are delayed by 400 ms receives about
  22 fps instead of 60 (frames skipped, not queued), returns to 60 fps when the
  delay ends, its recording decodes with FFmpeg, and a healthy viewer on the
  same channel keeps 60 fps with 1.4% keyframes.
- Safari (iPadOS 26 simulator) against the synthetic stream with `?debug`:
  player lag 2–4 ms, 30 fps decoded, no dropped frames.

Not yet measured: physical iPad/Android over real Wi-Fi (switching from a static
screen to dragging a window, scrolling, Pencil, Wi-Fi interruptions). Use
`?debug` on the device to read the actual player lag.
