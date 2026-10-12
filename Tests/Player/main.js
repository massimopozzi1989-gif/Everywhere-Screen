// Deterministic tests of the actual embedded player with a stalled MediaSource.
// No browser, screen capture or input injection. Run: node Tests/Player/main.js
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../../Sources/Page.swift'), 'utf8');
const js = source.split('private static let viewerJS = #"""')[1].split('"""#')[0];
new vm.Script(js); // Also validate the complete viewer's JavaScript syntax.
const playerSource = js.slice(js.indexOf('const player = {'), js.indexOf("video.addEventListener('error'"));
let now = 0;
const sent = [];
class MediaSource {
  constructor() { this.readyState = 'open'; this.events = {}; }
  addEventListener(name, callback) { this.events[name] = callback; }
  addSourceBuffer() {
    return {
      updating: false, events: {}, appended: [],
      buffered: { length: 0 },
      addEventListener(name, callback) { this.events[name] = callback; },
      appendBuffer(data) { this.appended.push(Array.from(new Uint8Array(data.buffer || data, data.byteOffset || 0, data.byteLength))); this.updating = true; },
      remove() {},
    };
  }
}
const video = { currentTime: 0, paused: false, playbackRate: 1 };
const context = vm.createContext({
  MS: MediaSource, window: {}, video, useMSE: true, Uint8Array,
  performance: { now: () => now },
  URL: { createObjectURL: () => 'blob:test', revokeObjectURL() {} },
  send: msg => sent.push(msg), fallbackMJPEG() { assert.fail('unexpected MJPEG fallback'); },
});
const player = vm.runInContext(playerSource + '\nplayer;', context);
const seg = (...bytes) => new Uint8Array(bytes).buffer;
function reset(fps = 30) {
  sent.length = 0; now = 0;
  player.reset('avc1.640028', fps);
  player.ms.events.sourceopen();
  return player.sb;
}
function buffered(sb, start, end) {
  sb.buffered = { length: 1, start: () => start, end: () => end };
}
function finish(sb) { sb.updating = false; sb.events.updateend(); }

// Segments arriving while the SourceBuffer is busy are appended together, in order,
// instead of growing a queue of one append per updateend.
let sb = reset();
player.append(seg(1));
for (let i = 2; i <= 6; i++) { now += 5; player.append(seg(i)); }
assert.deepEqual(sb.appended, [[1]]);
finish(sb);
assert.deepEqual(sb.appended, [[1], [2, 3, 4, 5, 6]]);
assert.equal(player.q.length, 0);
assert.equal(sent.length, 0);

// A short decoder hiccup (200 ms) does not throw the stream away and request a keyframe.
sb = reset(60); player.append(seg(1));
for (let i = 0; i < 12; i++) { now += 16; player.append(seg(2 + i)); }
assert.equal(sent.length, 0);
finish(sb);
assert.equal(sb.appended.length, 2);

// A decoder that is really stuck (1 s) restarts once from a keyframe and drops dependent frames.
sb = reset(); player.append(seg(1)); player.append(seg(2));
now = 1001; player.append(seg(3));
assert.equal(sent.length, 1);
assert.equal(sent[0].t, 'kf');
assert.equal(player.q.length, 0);
player.restart(); player.append(seg(4));
finish(sb);
assert.equal(sent.length, 1);
assert.deepEqual(sb.appended, [[1]]);

// A stale updateend from a replaced SourceBuffer must not touch the new stream.
const oldSource = player.ms;
const oldUpdate = sb.events.updateend;
sb = reset(60); video.currentTime = 0; buffered(sb, 0, 1);
oldUpdate();
assert.equal(video.currentTime, 0);
assert.notEqual(player.ms, oldSource);

// Live edge at 60 fps: target 25 ms. Moderate lag speeds playback up (bounded), without seeking.
video.currentTime = 0.97; player.after();
assert.equal(video.currentTime, 0.97);
assert.equal(video.playbackRate, 1);
video.currentTime = 0.9; player.after();
assert.equal(video.currentTime, 0.9);
assert.ok(video.playbackRate > 1.2 && video.playbackRate < 1.4, String(video.playbackRate));
video.currentTime = 0.6; player.after();
assert.equal(video.currentTime, 0.6);
assert.equal(video.playbackRate, 1.5);
// Back near the live edge: normal speed again (hysteresis keeps it until the target).
video.currentTime = 0.96; player.after();
assert.equal(video.playbackRate, 1.5);
video.currentTime = 0.98; player.after();
assert.equal(video.playbackRate, 1);
// Large lag: one seek to the live edge.
video.currentTime = 0.3; player.after();
assert.ok(Math.abs(video.currentTime - 0.975) < 1e-9);
assert.equal(video.playbackRate, 1);
// Behind the buffered range (after a remove): seek too.
sb = reset(30); buffered(sb, 2, 3); video.currentTime = 1;
player.after();
assert.ok(Math.abs(video.currentTime - 2.95) < 1e-9);

// Chrome lets the playhead run past the newest frame when frames arrive slower than the fps
// (static screen). Freeing old data must never remove the newest frames and their keyframe.
sb = reset(30); buffered(sb, 0, 40); video.currentTime = 90;
const removed = []; sb.remove = (a, b) => removed.push([a, b]);
player.after();
assert.deepEqual(removed, [[0, 30]]);
assert.equal(video.currentTime, 90);

// Fresh init and keyframe retain their original ordering after a reset.
sb = reset(); player.append(seg(9)); player.append(seg(8));
finish(sb);
assert.deepEqual(sb.appended, [[9], [8]]);
console.log('✓ player: batching, stuck decoder recovery, live-edge catch-up, stale callbacks, segment order');
