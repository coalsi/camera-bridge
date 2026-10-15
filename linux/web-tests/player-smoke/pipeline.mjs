// Browser smoke test of the whole player: api.js, fetcher, catalog, clock, session, cell and surface against the archive routes of
// mini-archive.mjs (real clips, real HTTP). Open /smoke/pipeline.html (serve.mjs) and keep the tab visible; it takes about 45 s.
import { ApiError, get, getBytes } from '/js/api.js';
import { createCatalog } from '/js/nvr/catalog.js';
import { createCell } from '/js/nvr/cell.js';
import { PlaybackClock } from '/js/nvr/clock.js';
import { createFetcher } from '/js/nvr/fetcher.js';
import { bufferSeconds, choosePolicy, currentEnvironment } from '/js/nvr/planner.js';
import { createSession } from '/js/nvr/session.js';
import { MseSurface } from '/js/nvr/surface.js';

const results = [];
const out = document.getElementById('out');
const summary = document.getElementById('summary');
const stage = document.getElementById('stage');
const layout = await (await fetch('/smoke/layout.json')).json();
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const round = (x) => Math.round(x * 100) / 100;

async function until(check, timeoutMs, what) {
  const started = performance.now();
  for (;;) {
    const value = check();
    if (value) return value;
    if (performance.now() - started > timeoutMs) throw new Error(`gave up waiting for ${what}`);
    await wait(50);
  }
}

const kits = new Set();       // every kit a scenario built, destroyed when the scenario ends, whatever happened

function build({ tileCap = 1 } = {}) {
  const fetcher = createFetcher({ get, getBytes, sleep: wait });
  const catalog = createCatalog({ fetcher });
  const clock = new PlaybackClock({ serverNow: () => catalog.serverNow() });
  const session = createSession({
    catalog, clock, tileCap,
    createCell: (id) => createCell({ cameraId: id, stage, catalog, fetcher, clock, createSurface: (options) => new MseSurface(options) }),
  });
  catalog.start();
  const coverage = [];
  session.onChange((event) => { if (event.kind === 'coverage') coverage.push({ at: Math.round(performance.now()), ...event.coverage }); });
  const kit = { fetcher, catalog, clock, session, coverage, destroy() { kits.delete(kit); session.destroy(); catalog.stop(); fetcher.destroy(); } };
  kits.add(kit);
  return kit;
}

const video = () => stage.querySelector('video');
async function scenario(name, run) {
  const started = performance.now();
  try {
    const details = await Promise.race([run(), new Promise((_, reject) => setTimeout(() => reject(new Error('no answer within 40 s')), 40_000))]);
    results.push({ name, ok: details.ok !== false, ...details, ms: Math.round(performance.now() - started) });
  } catch (error) {
    results.push({ name, ok: false, error: `${error.name}: ${error.message}` });
  } finally {
    for (const kit of [...kits]) kit.destroy();
  }
  out.textContent = JSON.stringify(results, null, 1);
}

const policy = choosePolicy(currentEnvironment());
const header = { isSecureContext: window.isSecureContext, userAgent: navigator.userAgent, mediaSource: policy.mediaSource, policy: policy.browser, layout, pageVisible: document.visibilityState };
if (!policy.canPlay) {
  summary.textContent = policy.reason;
  out.textContent = JSON.stringify({ header }, null, 1);
  throw new Error(policy.reason);
}

await scenario('P1 the catalog: extents, time base and the server\'s clock', async () => {
  const kit = build();
  await kit.catalog.ready();
  const extent = kit.catalog.extent('CAM-1');
  const skewMs = kit.catalog.serverNow() - Date.now();
  kit.destroy();
  return { extent, baseMs: kit.catalog.baseMs, skewMs, ok: extent.oldest === layout.startA && extent.newest === layout.endB && Math.abs(skewMs) < 500 && kit.catalog.baseMs < Date.now() - 399 * 86_400_000 };
});

await scenario('P2 a drag across the first file and a release: pictures while dragging, then playing, the video follows the clock', async () => {
  const kit = build();
  await kit.catalog.ready();
  kit.session.setCameras(['CAM-1']);
  const cell = kit.session.cell('CAM-1');
  kit.session.beginScrub();
  const shown = new Set();
  for (let i = 0; i < 30; i += 1) {
    kit.session.scrub(layout.startA + 1000 + i * 350);
    await wait(30);
    if (video()) shown.add(Math.round(video().currentTime));
  }
  await wait(150);
  kit.session.endScrub();
  await until(() => cell.coverage.playing, 8000, 'the first playing frame');
  const started = video().currentTime;
  await wait(3000);
  const v = video();
  const drift = v.currentTime - bufferSeconds(kit.clock.position(), kit.catalog.baseMs);
  const details = {
    pictureTimesSeen: shown.size, coverage: cell.coverage.kind, mode: kit.session.mode, advancedSec: round(v.currentTime - started), driftSec: round(drift),
    size: [v.videoWidth, v.videoHeight],
  };
  kit.destroy();
  return { ...details, ok: details.pictureTimesSeen >= 2 && details.coverage === 'recorded' && details.mode === 'playing' && details.advancedSec > 2.5 && Math.abs(drift) < 0.6 && details.size[0] === 1280 };
});

await scenario('P3 playing out of the first file into the second (another codec string): the surface is rebuilt behind the held picture', async () => {
  const kit = build();
  await kit.catalog.ready();
  kit.session.setCameras(['CAM-1']);
  kit.session.play(layout.endA - 3000);
  await until(() => kit.session.mode === 'playing' && kit.clock.mode === 'playing', 8000, 'the clock to start');
  const hole = layout.gapMs >= 1000;               // a hole of a second or more is reported and jumped over by the session; a smaller one is crossed by the cell
  const gap = hole ? await until(() => kit.coverage.find((c) => c.kind === 'gap'), 15_000, 'the gap') : null;
  const startOfB = bufferSeconds(layout.startB, kit.catalog.baseMs);
  const inSecond = await until(() => video() && video().currentTime >= startOfB + 1 && kit.clock.mode === 'playing', 15_000, 'the second file');
  const first = kit.coverage[0].at;
  const details = {
    gapNext: gap?.next ?? null, secondFileAt: round(video().currentTime - startOfB), mode: kit.session.mode, size: [video().videoWidth, video().videoHeight],
    coverage: kit.coverage.map((c) => `${c.at - first} ms ${c.kind} epoch ${c.epoch}${c.playing ? ' playing' : ''}${c.next ? ` next ${c.next - layout.startA}` : ''}`),
  };
  kit.destroy();
  return { ...details, ok: inSecond && (!hole || gap.next === layout.startB) && details.size[0] === 1920 && details.mode === 'playing' };
});

await scenario('P4 a time with no recording: 404 gap with X-CB-Next from the real server, and a tile that keeps its picture', async () => {
  if (layout.gapMs < 1000) return { skipped: 'the clips are served without a gap' };
  const kit = build();
  await kit.catalog.ready();
  const error = await getBytes(`nvr/cameras/CAM-1/keyframe?at=${layout.endA + 2000}`).then(() => null, (e) => e);
  kit.session.setCameras(['CAM-1']);
  const cell = kit.session.cell('CAM-1');
  kit.session.scrub(layout.startA + 5000);
  await until(() => cell.coverage.kind === 'recorded', 8000, 'a picture');
  const before = video().currentTime;
  kit.session.scrub(layout.endA + 2000);
  await until(() => cell.coverage.kind === 'gap', 8000, 'the gap');
  const details = { errorCode: error?.code, errorStatus: error?.status, errorNext: error?.next, coverageNext: cell.coverage.next, pictureKept: video().currentTime === before };
  kit.destroy();
  return { ...details, ok: error instanceof ApiError && error.code === 'gap' && error.next === layout.startB && details.coverageNext === layout.startB && details.pictureKept };
});

await scenario('P5 seeking while playing keeps playing; go live with nothing recently recorded says so', async () => {
  const kit = build();
  await kit.catalog.ready();
  kit.session.setCameras(['CAM-1']);
  const cell = kit.session.cell('CAM-1');
  kit.session.play(layout.startA + 4000);
  await until(() => cell.coverage.playing, 8000, 'playing');
  const modes = [];
  kit.session.onChange((event) => { if (event.kind === 'mode') modes.push(event.mode); });
  kit.session.seek(+6000);
  await until(() => kit.clock.mode === 'playing' && cell.coverage.playing, 8000, 'playing again');
  const moved = bufferSeconds(kit.clock.position(), kit.catalog.baseMs) - bufferSeconds(layout.startA + 4000, kit.catalog.baseMs);
  kit.session.goLive();
  await until(() => cell.coverage.kind === 'gap', 8000, 'live to find nothing');
  const details = { modesDuringSeek: modes, movedSec: round(moved), liveMode: kit.session.mode, liveCoverage: cell.coverage.kind };
  kit.destroy();
  return { ...details, ok: modes.length === 1 && modes[0] === 'live' && moved > 5.5 && details.liveMode === 'live' && details.liveCoverage === 'gap' };
});

await scenario('P6 suspend and resume (a hidden tab): everything stops, then plays on from the same place', async () => {
  const kit = build();
  await kit.catalog.ready();
  kit.session.setCameras(['CAM-1']);
  const cell = kit.session.cell('CAM-1');
  kit.session.play(layout.startA + 2000);
  await until(() => cell.coverage.playing, 8000, 'playing');
  await wait(1000);
  kit.session.suspend();
  const heldAt = kit.session.position;
  const media = () => performance.getEntriesByType('resource').filter((e) => e.name.includes('/fragments') || e.name.includes('/keyframe')).length;
  const requests = media();
  await wait(3000);
  const quiet = media() === requests && video().paused && kit.session.mode === 'paused' && kit.session.position === heldAt;
  kit.session.resume();
  await until(() => kit.session.mode === 'playing' && cell.coverage.playing && !video().paused, 8000, 'playing again');
  const details = { quiet, resumedNear: round((kit.session.position - heldAt) / 1000) };
  kit.destroy();
  return { ...details, ok: quiet && details.resumedNear < 3 };
});

const failed = results.filter((r) => !r.ok);
summary.textContent = failed.length ? `FAILED ${failed.length} of ${results.length}: ${failed.map((r) => r.name.split(' ')[0]).join(', ')}` : `PASSED ${results.length} of ${results.length}`;
out.textContent = JSON.stringify({ header, results }, null, 1);
document.title = failed.length ? 'pipeline: failed' : 'pipeline: passed';
window.__pipeline = { header, results, failed: failed.length };
