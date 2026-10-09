# Streaming latency changes

Based on `origin/main` at `13e9cb2` (Everywhere Screen 1.3.0), fetched on
2026-10-09. The transport remains H.264/fMP4 over WebSocket with MJPEG fallback;
no new runtime dependencies or changes to pairing, gestures or saved preferences.
Existing native APIs are sufficient for this optimization.

## Changes

- ScreenCaptureKit uses its minimum pool of 3 surfaces rather than 6. The hub
  already replaces pending capture frames with the newest one. A smaller pool
  reduces retained surfaces, but can drop frames sooner if processing stalls.
  See [Apple's queueDepth documentation](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/queuedepth).
- VideoToolbox is explicitly asked for zero compression frame delay in addition
  to real-time encoding and disabled B-frames. Unsupported properties remain
  nonfatal, as in the existing encoder configuration. See
  [Apple's MaxFrameDelayCount documentation](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_maxframedelaycount).
- A viewer stops accepting dependent frames when its outstanding send queue
  exceeds 256 KB or remains nonempty for 120 ms, replacing the 1.5 MB limit.
  These measure local transport backlog, not remote presentation or TCP ACKs;
  bytes already submitted to TCP cannot be withdrawn. Recovery waits for a
  keyframe so skipping frames preserves decodability.
- Coalesced recovery refreshes wait 50 ms rather than 250 ms. Requests remain
  coalesced across viewers to avoid a keyframe storm on healthy devices.
- The browser now bounds its append queue by age (120 ms) and frame rate
  (4–8 segments at 30–60 fps), rather than accepting more than 60 segments.
  Pending dependent segments are discarded until a fresh init/keyframe arrives.
- At 30/60 fps the player seeks toward the live edge when behind by more than
  100/80 ms, instead of 300 ms. Its target margin is 50/25 ms respectively.
  Smaller delays are absorbed at 1.08× playback speed, returning to 1× when
  caught up. These are recovery thresholds, not guaranteed end-to-end latency.
- FPS changes reinitialize the existing viewer's MP4 timeline and report the
  new rate to the browser. Late SourceBuffer callbacks from a replaced stream
  are ignored, and repeated recovery requests are suppressed.

## Verification

- `scripts/test.sh`: display layout geometry.
- `node Tests/Player/main.js`: actual embedded JavaScript syntax and player
  behavior with deterministic MediaSource doubles: decoder stalls, bursts,
  stale queued segments, one recovery request, stale callbacks, live-edge
  correction at 30/60 fps, and init/keyframe ordering.
- `scripts/stress.sh`: synthetic video over real loopback sockets, including
  input flood, authorization, slow/disconnected clients, FPS and resolution
  changes, MJPEG, eight simultaneous displays, and FFmpeg decoding.
- Native app compiled with the project's optimized Swift compiler settings.

In the initial comparison on this Mac, synthetic 1280×800 encode/mux/loopback
latency was 10.5/16.5 ms at p50/p99 before and 9.7/12.8 ms after. This is a
single run, not an isolated benchmark or a measurement of browser presentation.
The optimized streaming test maintained ~60 fps across eight viewers on one
channel and ~30 fps across four on another; eight Retina display channels
also maintained ~30 fps each.

Physical iPad/Android Wi-Fi and Safari rendering must still be checked on the
user's devices, particularly switching from a static screen to dragging a window,
scrolling, Pencil drawing, and recovering after Wi-Fi interruption. Browser tests
with doubles do not establish real Safari playback latency. The local test app
is in `build/optimized/Everywhere Screen.app`; it has a local Developer ID
signature without a timestamp and has not been notarized or released.
