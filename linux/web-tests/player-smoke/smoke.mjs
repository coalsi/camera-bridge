// Browser smoke test of MseSurface against the real MSE of the browser it runs in (cases 1 to 11 of the spike's list, T00 L12, on fixtures).
// Open /smoke/smoke.html (serve.mjs) and read the table; it takes about 10 s. Keep this tab visible: a page that is not being drawn gets
// no frame callbacks, and the surface then proves pictures by `seeked` (slower, reported in the `via` counts).
import { DEFAULT_POLICY, bufferSeconds, choosePolicy, currentEnvironment, timestampOffsetSeconds } from '/js/nvr/planner.js';
import { MseSurface } from '/js/nvr/surface.js';

const results = [];
const out = document.getElementById('out');
const summary = document.getElementById('summary');
const video = document.getElementById('video');
const canvas = document.getElementById('hold');
const NOW = Date.now();
const BASE = NOW - 400 * 86_400_000;           // the catalog's base: the server's time minus 400 days
const FILE_START = NOW - 3_600_000;

async function fixture(name, startMs = FILE_START) {
  const dir = `/smoke/fixtures/${name}`;
  const manifest = await (await fetch(`${dir}/manifest.json`)).json();
  const init = await (await fetch(`${dir}/init.mp4`)).arrayBuffer();
  const parts = [];
  for (let i = 0; i < manifest.segments.length; i += 1) {
    const seg = manifest.segments[i];
    const bytes = await (await fetch(`${dir}/${seg.file}`)).arrayBuffer();
    const start = startMs + (seg.tfdtTicks / manifest.timescale) * 1000;
    parts.push({ id: `${name}.${i}`, index: i, start, end: start + (seg.durationTicks / manifest.timescale) * 1000, key: seg.key, bytes });
  }
  return { name, manifest, init, parts, anchor: startMs, mime: manifest.mime, offsetSec: timestampOffsetSeconds(startMs, BASE) };
}

const sec = (ms) => bufferSeconds(ms, BASE);
const round = (x) => Math.round(x * 1000) / 1000;
const ranges = (surface) => surface.held().map((r) => [round(r.start), round(r.end)]);
const vias = {};
const seek = async (surface, bufferSec) => {
  const result = await surface.seek(bufferSec);
  vias[result.via] = (vias[result.via] ?? 0) + 1;
  return result;
};
const feed = (surface, fx, index, chainBreak) => {
  const p = fx.parts[index];
  return surface.append(p.bytes, { timestampOffsetSec: fx.offsetSec, chainBreak, startSec: sec(p.start), endSec: sec(p.end), key: p.key });
};
const fresh = (policy = DEFAULT_POLICY, extra = {}) => new MseSurface({ video, holdCanvas: canvas, policy, ...extra });
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function scenario(name, run) {
  const started = performance.now();
  try {
    const details = await Promise.race([run(), new Promise((_, reject) => setTimeout(() => reject(new Error('no answer within 20 s')), 20_000))]);
    results.push({ name, ok: details.ok !== false, ...details, ms: Math.round(performance.now() - started) });
  } catch (error) {
    results.push({ name, ok: false, error: `${error.name}: ${error.message}` });
  }
}

const env = currentEnvironment();
const policy = choosePolicy(env);
const header = {
  isSecureContext: window.isSecureContext, userAgent: navigator.userAgent, typeofVideoDecoder: typeof VideoDecoder, mediaSource: policy.mediaSource,
  policy: { browser: policy.browser, canPlay: policy.canPlay, keySteps: policy.keySteps, mimeChange: policy.mimeChange, maxTiles: policy.maxTiles },
  requestVideoFrameCallback: 'requestVideoFrameCallback' in HTMLVideoElement.prototype, pageVisible: document.visibilityState, bufferSecondsNow: round(sec(NOW)),
};

const gop2 = await fixture('gop2');
const gop8 = await fixture('gop8');
const gop2Next = await fixture('gop2', FILE_START + 20_000);            // the same clip as a second file that starts where the first ends
const high = await fixture('high1080', FILE_START + 600_000);
const isSupported = (fx) => MseSurface.isSupported(fx.mime);
if (!isSupported(gop2)) {
  summary.textContent = `This browser cannot play ${gop2.mime}.`;
  out.textContent = JSON.stringify({ header }, null, 1);
  throw new Error('unsupported');
}

await scenario('1 init + K, seek to K.start + 1 ms: a picture, at that time', async () => {
  const s = fresh();
  await s.open(gop2.mime);
  await s.appendInit(gop2.init);
  await feed(s, gop2, 3, true);
  const target = sec(gop2.parts[3].start + 1);
  const r = await seek(s, target);
  const current = video.currentTime;
  const size = [video.videoWidth, video.videoHeight];
  const held = ranges(s);
  s.destroy();
  return { presented: r.presented, via: r.via, mediaTime: r.mediaTime, target: round(target), size, held, ok: r.presented && Math.abs(r.mediaTime - target) < 0.05 && Math.abs(current - target) < 1e-6 };
});

await scenario('2 init + K..F, seek mid-GOP: the frame at or just before the target', async () => {
  const s = fresh();
  await s.open(gop8.mime);
  await s.appendInit(gop8.init);
  for (let i = 0; i < 3; i += 1) await feed(s, gop8, i, i === 0);
  const target = sec(gop8.parts[2].start + 1230);
  const r = await seek(s, target);
  s.destroy();
  return { presented: r.presented, diffMs: round((target - r.mediaTime) * 1000), ok: r.presented && r.mediaTime <= target + 1e-6 && target - r.mediaTime < 0.08 };
});

await scenario('3 chain extension after a key picture, without abort', async () => {
  const s = fresh();
  await s.open(gop8.mime);
  await s.appendInit(gop8.init);
  await feed(s, gop8, 0, true);
  const first = await seek(s, sec(gop8.parts[0].start + 1));
  await feed(s, gop8, 1, false);
  await feed(s, gop8, 2, false);
  const target = sec(gop8.parts[2].start + 500);
  const r = await seek(s, target);
  const held = ranges(s);
  s.destroy();
  return { first: first.presented, presented: r.presented, diffMs: round((target - r.mediaTime) * 1000), held, ok: first.presented && r.presented && held.length === 1 };
});

await scenario('4 far jump: a second chain (abort, same offset), then back into the first', async () => {
  const s = fresh();
  await s.open(gop2.mime);
  await s.appendInit(gop2.init);
  await feed(s, gop2, 0, true);
  const a = await seek(s, sec(gop2.parts[0].start + 1));
  await feed(s, gop2, 7, true);
  const b = await seek(s, sec(gop2.parts[7].start + 1));
  const back = await seek(s, sec(gop2.parts[0].start + 600));
  const held = ranges(s);
  s.destroy();
  return { a: a.presented, b: b.presented, back: back.presented, held, ok: a.presented && b.presented && back.presented && held.length === 2 };
});

await scenario('4b a delta part appended after a jump is dropped (why only the chain appended last can be continued)', async () => {
  const s = fresh();
  await s.open(gop8.mime);
  await s.appendInit(gop8.init);
  await feed(s, gop8, 0, true);
  await feed(s, gop8, 4, true);
  const before = ranges(s);
  await feed(s, gop8, 1, false);
  const afterContinuation = ranges(s);
  await feed(s, gop8, 1, true);
  const afterBreak = ranges(s);
  const wanted = [sec(gop8.parts[1].start), sec(gop8.parts[1].end)];
  const holds = (list) => list.some(([a, b]) => a <= wanted[0] + 0.01 && b >= wanted[1] - 0.01);
  s.destroy();
  return { before, afterContinuation, afterBreak, ok: !holds(afterContinuation) && !holds(afterBreak) };
});

await scenario('5a two files with different codec strings, recreate: the last frame is held, then the new picture shows', async () => {
  const s = fresh();
  await s.open(gop2.mime);
  await s.appendInit(gop2.init);
  await feed(s, gop2, 2, true);
  const a = await seek(s, sec(gop2.parts[2].start + 1));
  await s.open(high.mime);
  const held = { display: canvas.style.display, width: canvas.width, height: canvas.height };
  await s.appendInit(high.init);
  await feed(s, high, 0, true);
  const b = await seek(s, sec(high.parts[0].start + 1));
  const after = { display: canvas.style.display, width: canvas.width };
  const size = [video.videoWidth, video.videoHeight];
  const generation = s.generation;
  s.destroy();
  return { first: a.presented, second: b.presented, generation, held, after, size, ok: a.presented && b.presented && generation === 1 && held.width === 1280 && after.display === 'none' && size[0] === 1920 };
});

await scenario('5b two files with different codec strings, changeType', async () => {
  const s = fresh({ ...DEFAULT_POLICY, mimeChange: 'changeType' });
  await s.open(gop2.mime);
  await s.appendInit(gop2.init);
  await feed(s, gop2, 2, true);
  const a = await seek(s, sec(gop2.parts[2].start + 1));
  await s.open(high.mime);
  await s.appendInit(high.init);
  await feed(s, high, 0, true);
  const b = await seek(s, sec(high.parts[0].start + 1));
  const back = await seek(s, sec(gop2.parts[2].start + 500));
  const generation = s.generation;
  s.destroy();
  return { first: a.presented, second: b.presented, backIntoFirst: back.presented, generation, ok: a.presented && b.presented };
});

await scenario('6 buffer times near 3.5e7 s keep millisecond precision', async () => {
  const s = fresh();
  await s.open(gop2.mime);
  await s.appendInit(gop2.init);
  await feed(s, gop2, 5, true);
  const target = sec(gop2.parts[5].start + 777);
  const r = await seek(s, target);
  const errorMs = (video.currentTime - target) * 1000;
  const bufferedStart = s.held()[0]?.start;
  s.destroy();
  return { target, errorMs, mediaTime: r.mediaTime, ok: r.presented && Math.abs(errorMs) < 0.01 && Math.abs(bufferedStart - sec(gop2.parts[5].start)) < 0.002 };
});

await scenario('7 the next file, same codec, starting where the first ends: new init, new offset, played across', async () => {
  const s = fresh();
  await s.open(gop2.mime);
  await s.appendInit(gop2.init);
  await feed(s, gop2, 8, true);
  await feed(s, gop2, 9, false);
  await seek(s, sec(gop2.parts[9].start + 500));
  await s.appendInit(gop2Next.init);
  await feed(s, gop2Next, 0, false);                       // another offset: the surface resets the parser itself
  await feed(s, gop2Next, 1, false);
  const held = ranges(s);
  await s.play();
  const boundary = sec(gop2.parts[9].end);
  const started = performance.now();
  while (video.currentTime < boundary + 1 && performance.now() - started < 8000) await wait(100);      // a page that is not drawn plays slowly
  const reached = video.currentTime - boundary;
  s.destroy();
  return { held, playedPastTheBoundarySec: round(reached), ok: held.length === 1 && reached > 0.5 };
});

await scenario('9 evict: the farthest GOP units go first, the unit under the playhead stays', async () => {
  const s = fresh(DEFAULT_POLICY, { budgetBytes: 2_200_000 });
  await s.open(gop2.mime);
  await s.appendInit(gop2.init);
  for (let i = 0; i < 6; i += 1) await feed(s, gop2, i, true);
  const before = ranges(s);
  const keep = sec(gop2.parts[2].start + 500);
  const r = await seek(s, keep);
  await s.evict(keep);
  const after = ranges(s);
  s.destroy();
  return { before, after, ok: r.presented && after.some(([a, b]) => a <= keep && keep < b) && after.length >= 1 && (after.at(-1)[1] - after[0][0]) < (before.at(-1)[1] - before[0][0]) };
});

await scenario('11 hold-back: how close to the end of a chain a seek still shows a picture (decides the 700 ms margin)', async () => {
  const table = [];
  for (const before of [1.0, 0.7, 0.5, 0.3, 0.2, 0.1, 0.05]) {
    const s = fresh();
    await s.open(gop8.mime);
    await s.appendInit(gop8.init);
    await feed(s, gop8, 0, true);
    await feed(s, gop8, 1, false);
    const end = sec(gop8.parts[1].end);
    const r = await seek(s, end - before);
    table.push({ secondsBeforeEnd: before, presented: r.presented, via: r.via });
    s.destroy();
  }
  return { table };
});

await scenario('13 speed: 20 key steps in random order (a new chain, a seek, a picture each)', async () => {
  const s = fresh();
  await s.open(gop2.mime);
  await s.appendInit(gop2.init);
  const times = [];
  let failures = 0;
  for (const index of [0, 5, 2, 8, 1, 9, 3, 6, 4, 7, 5, 0, 8, 2, 9, 1, 6, 3, 7, 4]) {
    const t0 = performance.now();
    await feed(s, gop2, index, true);
    const r = await seek(s, sec(gop2.parts[index].start + 1));
    if (!r.presented) failures += 1;
    times.push(Math.round(performance.now() - t0));
    await s.evict(sec(gop2.parts[index].start + 1));
  }
  s.destroy();
  times.sort((a, b) => a - b);
  return { failures, medianMs: times[10], p90Ms: times[18], maxMs: times.at(-1), ok: failures === 0 };
});

const failed = results.filter((r) => !r.ok);
summary.textContent = failed.length ? `FAILED ${failed.length} of ${results.length}: ${failed.map((r) => r.name.split(' ')[0]).join(', ')}` : `PASSED ${results.length} of ${results.length}`;
out.textContent = JSON.stringify({ header, vias, results }, null, 1);
document.title = failed.length ? 'smoke: failed' : 'smoke: passed';
window.__smoke = { header, vias, results, failed: failed.length };
