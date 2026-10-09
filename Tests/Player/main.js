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
      appendBuffer(data) { this.appended.push(data); this.updating = true; },
      remove() {},
    };
  }
}
const video = { currentTime: 0, paused: false, playbackRate: 1 };
const context = vm.createContext({
  MS: MediaSource, window: {}, video, useMSE: true,
  performance: { now: () => now },
  URL: { createObjectURL: () => 'blob:test', revokeObjectURL() {} },
  send: msg => sent.push(msg), fallbackMJPEG() { assert.fail('unexpected MJPEG fallback'); },
});
const player = vm.runInContext(playerSource + '\nplayer;', context);
function reset(fps = 30) {
  sent.length = 0; now = 0;
  player.reset('avc1.640028', fps);
  player.ms.events.sourceopen();
  return player.sb;
}
function buffered(sb, start, end) {
  sb.buffered = { length: 1, start: () => start, end: () => end };
}

// Decoder stalls: stop queuing after ~120 ms, request one init/keyframe,
// and never append dependent frames to the old decoder during recovery.
let sb = reset();
player.append('init');
player.append('key');
now = 121;
player.append('delta');
assert.equal(sent.length, 1);
assert.equal(sent[0].t, 'kf');
assert.equal(player.q.length, 0);
player.restart(); player.append('late delta');
sb.updating = false; player.after();
assert.equal(sent.length, 1);
assert.deepEqual(sb.appended, ['init']);

// A burst is bounded even if its timestamps are all identical.
sb = reset(60); sb.updating = true;
for (let i = 0; i < 10; i++) player.append(i);
assert.equal(sent.length, 1);
assert.equal(player.skip, true);

// A single queued frame can grow stale without any more network arrivals.
sb = reset(); sb.updating = true; player.append('old');
now = 121; sb.updating = false; player.pump();
assert.equal(sent.length, 1);
assert.deepEqual(sb.appended, []);

// A stale updateend from a replaced SourceBuffer must not touch the new stream.
const oldSource = player.ms;
const oldUpdate = sb.events.updateend;
sb = reset(60); video.currentTime = 0; buffered(sb, 0, 1);
oldUpdate();
assert.equal(video.currentTime, 0);
assert.notEqual(player.ms, oldSource);

// Catch up within 80–100 ms at 60/30 fps, then return to normal speed.
player.after();
assert.ok(Math.abs(video.currentTime - 0.975) < 1e-9);
assert.equal(video.playbackRate, 1);
video.currentTime = 0.94; player.after();
assert.equal(video.currentTime, 0.94);
assert.equal(video.playbackRate, 1.08);
video.currentTime = 0.98; player.after();
assert.equal(video.playbackRate, 1);
sb = reset(30); buffered(sb, 0, 1); video.currentTime = 0.8;
player.after();
assert.ok(Math.abs(video.currentTime - 0.95) < 1e-9);

// Fresh init and keyframe retain their original ordering after a reset.
sb = reset(); player.append('init'); player.append('key');
sb.updating = false; player.after();
assert.deepEqual(sb.appended, ['init', 'key']);
console.log('✓ player: backlog, recovery, timing, stale callbacks and segment order');
