// One tile: the code that gets a camera's picture for a time onto a surface.
//
// A cell has one worker loop. `request(desire)` only stores the newest desire (latest wins) and wakes the loop; the loop is the only code
// that touches the cell's surface or its model of what the surface holds. The model is a list of chains: runs of consecutive parts
// appended in order, each starting at a key part.
//
// `stage` is either an element the caller owns and has put in the page, or an object `{ video, holdCanvas }` of elements the caller owns (the
// watch screen layers its own). With an element, the cell appends a <video muted playsinline> and a hold <canvas> to it on its first request
// (an idle cell has no media element) and removes them in destroy(); with the object it uses the two elements and leaves them in place. The
// surface factory is given exactly `{ video, holdCanvas, holdFrom }` either way.
//
// A camera whose picture is straightened (its page's Straighten the picture): the video the cell made is drawn straightened on a canvas right
// after it (js/live/straighten.js), under the hold canvas, by `getCorrection(cameraId)` when the video is made and by setCorrection() after
// that; `holdFrom()` gives the surface that canvas, so the held picture is straightened too. A caller's own video is the caller's to straighten.
//
// A desire is { targetMs, precision: 'key' | 'exact', playing, epoch, priority? }.
//   key    the nearest key picture: one request, the fastest way to show something while the pointer moves
//   exact  the frame at the target: the GOP's parts from the key part up to the target, appended, then a seek
// A request that was sent is never wasted: its bytes are appended and stay in the model whatever happened to the desire meanwhile.
import { createStraightenedView, isOn } from '../live/straighten.js';
import { realTimers } from './clock.js';
import { aheadFactor } from './speed.js';
import {
  DEFAULT_POLICY, MESSAGES, bufferSeconds, canSeekInChain, dedupeChains, extendChain, findChainPart, follows, heldRangeAt, keyStepLookup, lastChain,
  makeChain, nextFetches, rangeAfterHole, reconcileChains, seekSeconds, timestampOffsetSeconds,
} from './planner.js';

const LOADING_AFTER_MS = 300;
const TICK_MS = 250;
const DRIFT_CHECK_MS = 1000;
const DRIFT_LIMIT_MS = 400;
const PREFETCH_BELOW_MS = 5000;
const PREFETCH_EVERY_MS = 2500;
const BUSY_RETRY_MS = 2000;
const BUSY_RETRIES = 3;
const GAP_CONTINUOUS_MS = 1000;
const END_REACHED_MS = 60;                // the playhead this close to the end of a held chain has reached it
const END_PROBE_MS = 1000;                // at the end of what is held, ask what follows at most this often
const INIT_CACHE_FILES = 32;
const MARGIN_SLACK_MS = 20;               // a seek this much earlier than the hold-back margin cannot fail on rounding
const DRIVE_PROBE_MS = 5000;              // with the recordings drive gone, look again this often (one keyframe read)

const IDLE = Object.freeze({ kind: 'idle', next: null, message: null, epoch: 0, playing: false, snapMs: null });

export function createCell({
  cameraId, stage, catalog, fetcher, clock, createSurface, leadLimitBytes = 16 * 1_048_576, timers = realTimers, policy = DEFAULT_POLICY, marginMs = 700,
  getPause = () => null, getCorrection = () => null,
}) {
  const margin = marginMs + MARGIN_SLACK_MS;      // what a direct seek needs after the target: the decoders' hold-back and a little for rounding
  const bytesKey = `cell:${cameraId}`;
  const planKey = `plan:${cameraId}`;
  const listeners = new Set();
  let surface = null;
  let surfaceOff = null;
  let video = null;
  let holdCanvas = null;
  let created = false;                  // the cell made the media elements (and removes them)
  let view = null;                      // the cell's video straightened: made the first time the correction is on (off, it draws nothing)
  let correction = null;                // the camera's picture correction the video is drawn with
  let desire = null;
  let handledEpoch = -1;
  let restart = null;                   // a desire the worker handles next, made by the cell itself (the playhead drifted)
  let wake = null;
  let signalled = false;
  let destroyed = false;
  let suspended = false;
  let chains = [];
  let hints = new Map();                // chain head id -> { fromMs, toMs }: key pictures already shown for that range
  let files = new Map();                // fileKey -> FileInfo
  let initCache = new Map();            // fileKey -> init segment bytes
  let activeInit = null;                // the file whose init segment the SourceBuffer parsed last
  let lastAppendedId = null;            // the part appended last: only the chain that ends with it can be continued
  let knownGeneration = 0;
  let coverage = IDLE;
  let loadingTimer = null;
  let playerError = false;
  let retriedEpoch = -1;
  let goneEpoch = -1;
  let busyRetries = 0;
  let lastPrefetch = -Infinity;
  let lastDriftCheck = 0;
  let lastEndProbe = -Infinity;
  let replannedFor = null;              // { epoch, id }: follow() planned again because no chain ended with this part, the one appended last
  let driveTimer = null;                // the next probe of a recordings drive that is gone

  // MARK: Waking the worker

  function wakeUp() {
    if (wake) { const resolve = wake; wake = null; resolve(); } else signalled = true;
  }

  function waitFor(ms) {
    if (signalled) { signalled = false; return Promise.resolve(); }
    return new Promise((resolve) => {
      let timer = null;
      const done = () => { if (timer !== null) timers.clearTimeout(timer); if (wake === done) wake = null; resolve(); };
      if (Number.isFinite(ms)) timer = timers.setTimeout(done, ms);
      wake = done;
    });
  }

  // MARK: Coverage

  function setCoverage(patch) {
    const next = { ...coverage, next: null, message: null, snapMs: null, ...patch };
    const same = ['kind', 'next', 'message', 'epoch', 'playing', 'snapMs'].every((key) => next[key] === coverage[key]);
    if (patch.kind !== 'loading' && loadingTimer !== null && (patch.epoch ?? coverage.epoch) >= (desire?.epoch ?? 0)) { timers.clearTimeout(loadingTimer); loadingTimer = null; }
    if (same) return;
    coverage = Object.freeze(next);
    for (const fn of [...listeners]) {
      try { fn(coverage); } catch (error) { console.error(error); }
    }
  }

  // MARK: The recordings drive

  /** True when the bridge says this camera's recording is paused because the recordings folder is gone: every read then answers 410 or 504. */
  function driveIsGone() {
    try { return getPause(cameraId) === 'folderMissing'; } catch { return false; }
  }

  function clearDriveProbe() {
    if (driveTimer !== null) { timers.clearTimeout(driveTimer); driveTimer = null; }
  }

  /**
   * The drive is not there. The tile keeps its last picture (the surface is paused, nothing is removed), says so, and every DRIVE_PROBE_MS the
   * worker is asked to probe (`handle` runs `probe`), so the cell still has one request in flight at most.
   */
  function driveGone(d) {
    surface?.pause();
    setCoverage({ kind: 'driveMissing', message: MESSAGES.driveMissing, epoch: d.epoch, playing: false });
    clearDriveProbe();
    driveTimer = timers.setTimeout(() => {
      driveTimer = null;
      if (destroyed || suspended || !desire || desire.epoch !== d.epoch || coverage.kind !== 'driveMissing') return;
      restart = { ...d, probe: true };
      wakeUp();
    }, DRIVE_PROBE_MS);
  }

  /**
   * One read that needs the disk: the key fragment at the playhead. Answered (200, a gap, or a 410 with the pause cleared: retention) means the
   * drive is back, and the cell shows the playhead again as a paused exact step; anything else is thrown to `fail`, which probes again later.
   */
  async function probe(d) {
    try {
      await fetcher.bytes(`nvr/cameras/${encodeURIComponent(cameraId)}/keyframe?at=${Math.floor(clock.position())}`, { key: bytesKey, priority: -1 });
    } catch (error) {
      const answered = error?.code === 'gap' || ((error?.status === 410 || error?.code === 'gone') && !driveIsGone());
      if (!answered) throw error;
    }
    if (stale(d)) return;
    restart = { targetMs: clock.position(), precision: 'exact', playing: false, epoch: d.epoch, priority: d.priority ?? 0 };
  }

  // MARK: The straightened picture

  function readCorrection() {
    try { return getCorrection(cameraId) ?? null; } catch { return null; }
  }

  /** Draws the video the cell made by `correction` (the view's canvas goes right after the video: under the hold). */
  function straighten() {
    if (!created || destroyed) return;
    if (view) view.set(correction);
    else if (isOn(correction)) view = createStraightenedView({ source: video, correction });
  }

  /** The picture the surface holds while it builds its buffer again: the straightened canvas, drawn now (a WebGL canvas can be copied only right
   *  after a draw); null while there is none (the video's own frame is the picture on screen). */
  function holdFrom() {
    if (!view?.canvas) return null;
    view.set(correction);
    return view.canvas;
  }

  // MARK: The model of what the surface holds

  const base = () => catalog.baseMs;
  const stale = (d) => destroyed || suspended || !desire || desire.epoch !== d.epoch;
  const fileInfo = (fileKey) => files.get(fileKey) ?? catalog.file(fileKey);

  /**
   * Data in front of the playhead is only appended in the codec the surface has now: another codec string rebuilds the MediaSource (or changes
   * the type), which would throw away what is playing. The playhead gets to the new codec by a jump or by reaching the end of this one.
   */
  function sameCodec(part) {
    const info = fileInfo(part.file);
    return !surface || !surface.mime || !info || info.mime === surface.mime;
  }

  function resetModel() {
    chains = [];
    hints = new Map();
    activeInit = null;
    lastAppendedId = null;
  }

  function tidy() {
    chains = dedupeChains(chains, lastAppendedId);
    const heads = new Set(chains.map((chain) => chain.headId));
    for (const head of [...hints.keys()]) if (!heads.has(head)) hints.delete(head);
  }

  function ensureSurface() {
    if (surface) return surface;
    if (stage && stage.video && 'holdCanvas' in stage) {
      ({ video, holdCanvas } = stage);                       // the caller's own elements
    } else {
      const doc = stage.ownerDocument ?? document;
      video = doc.createElement('video');
      video.muted = true;
      video.playsInline = true;
      video.setAttribute('playsinline', '');
      holdCanvas = doc.createElement('canvas');
      stage.append(video, holdCanvas);
      created = true;
      correction = readCorrection();
      straighten();
    }
    surface = createSurface({ video, holdCanvas, holdFrom });
    knownGeneration = surface.generation ?? 0;
    surfaceOff = surface.onEvent?.((event) => {
      if (event.type === 'error') { playerError = true; wakeUp(); }
    });
    return surface;
  }

  /** Opens the surface for the codec of `fileKey`; when that rebuilt the buffer, everything the model knew is void. */
  async function prepareFile(fileKey) {
    const info = fileInfo(fileKey);
    if (!info) throw new Error('The recording has no format information.');
    const target = ensureSurface();
    await target.open(info.mime);
    if (target.generation !== knownGeneration) {
      knownGeneration = target.generation;
      resetModel();
    }
  }

  async function initFor(fileKey) {
    let data = initCache.get(fileKey);
    if (!data) {
      const info = fileInfo(fileKey);
      data = (await fetcher.bytes(`nvr/cameras/${encodeURIComponent(cameraId)}/fragments/${encodeURIComponent(info.initId)}/init`, { key: bytesKey })).data;
      initCache.set(fileKey, data);
      if (initCache.size > INIT_CACHE_FILES) initCache.delete(initCache.keys().next().value);
    }
    return data;
  }

  /** True when `part` can be appended after `chain` without a break: `chain` ends with the part appended last and the part follows its end. */
  function continues(chain, part) {
    return !!chain && chains.includes(chain) && chain === lastChain(chains, lastAppendedId) && follows(chain, part);
  }

  /** A part can be appended when it continues the chain or is a key part that starts a new one. */
  const appendable = (chain, part) => part.key || continues(chain, part);

  /**
   * Appends one fetched part. It continues `chain` when it can; otherwise it must be a key part and starts a new chain.
   * Returns the chain that now ends with the part.
   */
  async function appendPart(part, data, chain) {
    const info = fileInfo(part.file);
    const continuing = continues(chain, part);
    if (!continuing && !part.key) throw new Error('A chain must start at a key part.');
    // The init of a file goes in when the file changes. Whether it comes once more behind an abort() (policy.initAfterBreak) is the surface's business:
    // the abort happens inside append(), after this, so only the surface can put the init after it.
    if (activeInit !== part.file) {
      await surface.appendInit(await initFor(part.file));
      activeInit = part.file;
    }
    await surface.append(data, {
      timestampOffsetSec: timestampOffsetSeconds(info.anchor, base()),
      chainBreak: !continuing,
      startSec: bufferSeconds(part.start, base()),
      endSec: bufferSeconds(part.end, base()),
      key: part.key,
    });
    let result;
    if (continuing) result = extendChain(chain, part);
    else { result = makeChain(part); chains.push(result); }
    lastAppendedId = part.id;
    tidy();
    return result;
  }

  async function fetchPart(part) {
    return (await fetcher.bytes(`nvr/cameras/${encodeURIComponent(cameraId)}/fragments/${encodeURIComponent(part.id)}`, { key: bytesKey, priority: desire?.priority ?? 0 })).data;
  }

  /** What the video holds now; the model keeps only that. */
  function reconcile() {
    chains = reconcileChains(chains, surface.held(), base());
    tidy();
  }

  // MARK: Showing a picture

  function clampToExtent(ms) {
    const extent = catalog.extent(cameraId);
    if (extent && ms < extent.oldest) return { ms: extent.oldest, oldest: true };
    return { ms, oldest: false };
  }

  /** Seeks to `atMs` inside `part`. Returns true when a frame was shown. */
  async function present(part, atMs, d, { coarse = false, oldest = false } = {}) {
    const seconds = seekSeconds(part, atMs, base());
    const result = await surface.seek(seconds);
    if (destroyed) return false;
    if (!result.presented) return false;
    if (!stale(d)) {
      await surface.evict(seconds);
      reconcile();
      setCoverage(coarse
        ? { kind: 'coarse', epoch: d.epoch, playing: false, snapMs: part.start }
        : { kind: clock.mode === 'live' && d.playing ? 'live' : 'recorded', epoch: d.epoch, playing: false, message: oldest ? MESSAGES.oldest : null });
    }
    return true;
  }

  /** A seek that showed nothing: build the buffer again once and do the whole desire again; the second time it is an unreadable part. */
  async function recover(d) {
    if (retriedEpoch === d.epoch) {
      setCoverage({ kind: 'unreadable', message: MESSAGES.unreadable, epoch: d.epoch, playing: false });
      return;
    }
    retriedEpoch = d.epoch;
    await surface.reset();
    knownGeneration = surface.generation;
    resetModel();
    if (!stale(d)) await handle(d);
  }

  // MARK: Key step

  async function keyStep(d, target, oldest) {
    const look = keyStepLookup(chains, hints, target, { marginMs: margin });
    if (look.kind === 'held') {
      if (!(await present(look.part, look.atMs, d, { oldest }))) await recover(d);
      return;
    }
    let answer;
    try {
      answer = await fetcher.bytes(`nvr/cameras/${encodeURIComponent(cameraId)}/keyframe?at=${Math.floor(target)}`, { key: bytesKey, priority: d.priority ?? 0 });
    } catch (error) {
      if (error?.code === 'gap') { setCoverage({ kind: 'gap', next: error.next ?? null, epoch: d.epoch, playing: false }); return; }
      throw error;
    }
    const header = readPartHeader(answer.headers.get('X-CB-Part'));
    files.set(header.file, { mime: header.mime, width: header.width, height: header.height, anchor: header.anchor, initId: header.initId, sound: false });
    const part = { id: header.id, file: header.file, start: header.start, end: header.end, bytes: answer.data.byteLength, key: true };
    await prepareFile(part.file);
    const chain = chains.find((candidate) => candidate.headId === part.id) ?? await appendPart(part, answer.data, null);
    const hint = hints.get(chain.headId);
    hints.set(chain.headId, { fromMs: part.start, toMs: Math.max(part.end, target, hint?.toMs ?? 0) });
    if (stale(d)) {
      // The pointer moved on while this was on its way. Show this picture only when the newest desire is another key step that has nothing
      // better held; a newer exact step will find this part held and ask for the rest.
      const latest = desire;
      if (!latest || latest.precision !== 'key' || destroyed || suspended) return;
      if (keyStepLookup(chains, hints, clampToExtent(latest.targetMs).ms, { marginMs: margin }).kind === 'held') return;
    }
    if (!(await present(part, part.start + 1, d, { oldest }))) await recover(d);
  }

  // MARK: Exact step

  async function exactStep(d, target, oldest) {
    surface?.pause();
    const hit = findChainPart(chains, target);
    // Playing from held data needs a chain that can be continued (or plenty ahead); otherwise plan it again so that the GOP is appended last.
    const feedable = hit && (!d.playing || hit.chain === lastChain(chains, lastAppendedId) || hit.chain.endMs - target >= PREFETCH_BELOW_MS);
    if (hit && feedable && canSeekInChain(hit.chain, target, { marginMs: margin })) {
      if (!(await present(hit.part, target, d, { oldest }))) { await recover(d); return; }
      if (d.playing && !stale(d)) await follow(d);
      return;
    }
    const plan = await catalog.plan(cameraId, target, { ahead: 1, key: planKey });
    if (stale(d)) return;
    if (!plan.found) { await notFound(plan, d, target, oldest); return; }
    for (const [key, info] of Object.entries(plan.files || {})) files.set(key, info);
    const { fetch: toFetch, coarse, extend } = nextFetches(plan, chains, { maxBytes: leadLimitBytes, lastAppendedId });
    let chain = extend;
    for (const part of toFetch) {
      if (stale(d)) break;
      if (plan.parts.indexOf(part) > plan.targetIndex && !sameCodec(part)) break;          // look-ahead in another codec waits for the playhead
      const data = await fetchPart(part);
      await prepareFile(part.file);
      chain = await appendPart(part, data, chain);
    }
    if (stale(d)) return;
    let shown = coarse ? plan.parts[0] : plan.parts[plan.targetIndex];
    let at = coarse ? shown.start + 1 : target;
    if (!coarse) await extendForMargin(shown, at, d);
    if (stale(d)) return;
    if (!coarse) {
      // At the very end of the recordings nothing can follow: show the last picture a decoder will release instead of a seek that cannot succeed.
      // A recording too short to release any picture is, for a playing tile, part of the hole (skipTooShort).
      const hit = findChainPart(chains, at);
      if (hit && !canSeekInChain(hit.chain, at, { marginMs: margin })) {
        if (d.playing && !canSeekInChain(hit.chain, hit.chain.startMs + 1, { marginMs: margin })) { await skipTooShort(d, hit.chain); return; }
        at = Math.max(hit.chain.startMs + 1, hit.chain.endMs - margin);
        shown = findChainPart(chains, at)?.part ?? shown;
      }
    }
    if (!(await present(shown, at, d, { coarse, oldest }))) { await recover(d); return; }
    if (d.playing && !coarse && !stale(d)) await follow(d);
  }

  /** Hardware decoders hold frames back: when under the margin of the chain lies after the target, append what follows first. */
  async function extendForMargin(shown, at, d) {
    for (let round = 0; round < 2; round += 1) {
      const hit = findChainPart(chains, at);
      if (!hit || canSeekInChain(hit.chain, at, { marginMs: margin })) return;
      const more = await catalog.after(cameraId, hit.chain.tailId, { limit: 2, key: planKey });
      if (stale(d) || !more.parts.length) return;
      for (const [key, info] of Object.entries(more.files || {})) files.set(key, info);
      let chain = hit.chain;
      for (const part of more.parts) {
        if (stale(d) || !continues(chain, part) || !sameCodec(part)) return;
        const data = await fetchPart(part);
        await prepareFile(part.file);
        chain = await appendPart(part, data, chain);
      }
    }
  }

  /**
   * A playing tile in a recording too short for a decoder to show a picture from (shorter than its hold-back, and nothing continues it, as
   * between two file breaks): that recording is part of the hole. The tile waits for the recording after it (waitForRecording), or plays at
   * the clock when the clock is there already, instead of a seek that cannot succeed.
   */
  async function skipTooShort(d, chain) {
    const next = (await catalog.after(cameraId, chain.tailId, { limit: 1, key: planKey })).parts[0] ?? null;
    if (stale(d)) return;
    if (next && clock.position() >= next.start) { restart = { ...d, targetMs: clock.position() }; return; }
    surface?.pause();
    setCoverage({ kind: 'gap', next: next?.start ?? null, epoch: d.epoch, playing: false });
  }

  async function notFound(plan, d, target, oldest) {
    let next = plan.next ?? null;
    if (plan.reason === 'beforeStart') {
      next = plan.next ?? catalog.extent(cameraId)?.oldest ?? null;
      // Before the first recording: as in handle(), a playing tile waits for the clock to get there (below).
      if (!oldest && Number.isFinite(next) && !(d.playing && clock.position() < next)) { await exactStep(d, next, true); return; }
    }
    if (plan.reason === 'empty') { setCoverage({ kind: 'gap', next: null, message: MESSAGES.empty, epoch: d.epoch, playing: false }); return; }
    // The clock plays on while the plan is on its way: when it has got to the next recording already, play there instead of naming a time behind it.
    const reached = d.playing && Number.isFinite(next) && next > target && clock.position() >= next;
    if (reached) { restart = { ...d, targetMs: clock.position() }; return; }
    setCoverage({ kind: 'gap', next, epoch: d.epoch, playing: false });
  }

  /**
   * A playing tile at a hole: the clock plays on (another tile has video, or the session jumps when none has). Waits, without a request, until
   * the clock gets to the next recording, or when nothing followed until the catalog says this camera recorded past the playhead, and then plays
   * again at the clock. Ends at once on a newer desire, a suspend or a destroy. `fromMs` is the target that led here: a next recording that is
   * not after it is not believed (asking again at once would only get the same answer).
   */
  async function waitForRecording(d, fromMs) {
    const next = Number.isFinite(coverage.next) && coverage.next > fromMs ? coverage.next : null;
    const newestThen = catalog.extent(cameraId)?.newest ?? -Infinity;
    while (!stale(d)) {
      const at = clock.position();
      const newest = catalog.extent(cameraId)?.newest ?? -Infinity;
      if (next !== null ? at >= next : newest > newestThen && newest > at) {
        restart = { ...d, targetMs: at };
        loadingLater(d);
        return;
      }
      await waitFor(TICK_MS);
    }
  }

  /** The hole's sentence stops being true when the clock gets to the next recording: "Loading" if the picture there takes a moment. */
  function loadingLater(d) {
    if (loadingTimer !== null) timers.clearTimeout(loadingTimer);
    loadingTimer = timers.setTimeout(() => {
      loadingTimer = null;
      if (!stale(d) && coverage.kind === 'gap' && coverage.epoch === d.epoch) setCoverage({ kind: 'loading', epoch: d.epoch, playing: false });
    }, LOADING_AFTER_MS);
  }

  // MARK: Playing

  /** Plays the surface and keeps it fed until a newer desire, a suspend or a destroy. */
  async function follow(d) {
    playerError = false;
    lastPrefetch = timers.now() - PREFETCH_EVERY_MS;
    lastDriftCheck = timers.now();
    try {
      await surface.play();
    } catch {
      setCoverage({ kind: 'unreadable', message: MESSAGES.playerFailed, epoch: d.epoch, playing: false });
      return;
    }
    if (stale(d)) return;
    surface.setRate?.(clock.rate ?? 1);
    setCoverage({ kind: clock.mode === 'live' ? 'live' : 'recorded', epoch: d.epoch, playing: true });
    let last = null;                                                                      // { videoMs, at } at the tick before
    let stoppedAt = null;                                                                 // when the picture stopped at the end of what the video holds
    while (!stale(d)) {
      await waitFor(TICK_MS);
      if (stale(d)) return;
      if (playerError) { playerError = false; await recover(d); return; }
      const rate = clock.rate ?? 1;
      if (surface.rate !== rate) surface.setRate?.(rate);     // a new speed takes hold within a tick
      const ahead = aheadFactor(rate);
      const positionMs = clock.position();
      const videoSec = surface.currentTime();
      const videoMs = base() + videoSec * 1000;
      // The picture moved less than half as far as time did: the decoder waits for data. At the end of what the video holds it stands up to the
      // margin before the end (a hardware decoder keeps its last frames back until more data comes), so a stop there is the end of what is held.
      const stalled = last !== null && videoMs - last.videoMs < ((timers.now() - last.at) * rate) / 2;
      last = { videoMs, at: timers.now() };
      const range = heldRangeAt(surface.held(), videoSec);
      const atHeldEnd = range !== null && (range.end - videoSec) * 1000 <= margin;
      stoppedAt = stalled && atHeldEnd ? (stoppedAt ?? timers.now()) : null;
      if (stoppedAt !== null && (await stepOverHole(videoSec, positionMs))) { last = null; stoppedAt = null; continue; }
      if (stale(d)) return;
      const here = findChainPart(chains, videoMs);
      const hereAheadMs = here ? here.chain.endMs - videoMs : -Infinity;
      const tail = lastChain(chains, lastAppendedId);                                     // the only chain that can be continued
      // Near the end of what is held a seek cannot show a picture: what comes after the end is the end's business (below). A stop there that
      // the end could do nothing about for a while counts as drift again.
      const endsBusiness = atHeldEnd && (stoppedAt === null || timers.now() - stoppedAt < END_PROBE_MS + TICK_MS);
      if (!endsBusiness && timers.now() - lastDriftCheck >= DRIFT_CHECK_MS) {
        lastDriftCheck = timers.now();
        if (Math.abs(videoMs - positionMs) > DRIFT_LIMIT_MS * Math.max(1, rate)) {
          restart = { ...d, targetMs: positionMs };
          return;
        }
      }
      if (hereAheadMs < PREFETCH_BELOW_MS * ahead && timers.now() - lastPrefetch >= PREFETCH_EVERY_MS) {
        lastPrefetch = timers.now();
        if (!tail || tail.endMs < videoMs) {
          // What plays cannot be continued: plan it again, so that it can. Once for the same part appended last: a part too short for what
          // the video holds to reach into it (its sound ends before it starts) is lost from the model as soon as it is appended again, and
          // planning again for it would fetch it again and again. Then what is held plays out, and its end asks what follows (reachEnd).
          if (replannedFor?.epoch !== d.epoch || replannedFor.id !== lastAppendedId) {
            replannedFor = { epoch: d.epoch, id: lastAppendedId };
            restart = { ...d, targetMs: videoMs };
            return;
          }
        } else if (tail.endMs - videoMs < PREFETCH_BELOW_MS * ahead) {
          if ((await prefetch(tail, d, ahead)) === 'gone') { restart = { ...d, targetMs: positionMs }; return; }
          if (stale(d)) return;
        }
      }
      if ((hereAheadMs <= END_REACHED_MS || stoppedAt !== null) && (await reachEnd(videoMs, d))) return;       // the playhead stands at the end of what is held
    }
  }

  /**
   * The picture stopped before a hole under a second in what the video holds (between two files, say): seeks to the held range after it, at the
   * clock when the clock is inside it already. Returns true when it seeked.
   */
  async function stepOverHole(videoSec, positionMs) {
    const after = rangeAfterHole(surface.held(), videoSec, { maxHoleSec: GAP_CONTINUOUS_MS / 1000, minSec: margin / 1000 });
    if (!after) return false;
    const target = Math.min(Math.max(after.start + 0.001, bufferSeconds(positionMs, base())), after.end - margin / 1000);
    await surface.seek(target);
    return true;
  }

  /** Fetches the parts after the chain's tail (one request for the list, then the bytes one by one). */
  async function prefetch(chain, d, ahead = 1) {
    let list;
    try {
      list = await catalog.after(cameraId, chain.tailId, { limit: 4 * ahead, key: planKey });
    } catch (error) {
      if (error?.code === 'gone') return 'gone';
      throw error;
    }
    if (stale(d)) return 'stale';
    for (const [key, info] of Object.entries(list.files || {})) files.set(key, info);
    let current = chain;
    for (const part of list.parts) {
      if (stale(d)) return 'stale';
      if (!appendable(current, part) || !sameCodec(part)) break;                  // a delta part that does not follow, or another codec: the playhead will find it
      const data = await fetchPart(part);
      await prepareFile(part.file);
      current = await appendPart(part, data, current);
    }
    if (!stale(d)) {
      await surface.evict(surface.currentTime());
      reconcile();
    }
    return 'ok';
  }

  /**
   * The playhead stands at the end of the chain it played. Asks the server what follows (at most once a second) and either bridges a hole
   * under a second, restarts at the next recording (a jump the cell makes itself, so a new codec can be opened), or reports the gap.
   * Returns true when the follow loop should end.
   */
  async function reachEnd(videoMs, d) {
    const here = findChainPart(chains, videoMs - 1);
    if (!here || timers.now() - lastEndProbe < END_PROBE_MS) return false;
    lastEndProbe = timers.now();
    const endMs = here.chain.endMs;
    let next;
    try {
      next = (await catalog.after(cameraId, here.chain.tailId, { limit: 1, key: planKey })).parts[0];
    } catch (error) {
      if (error?.code !== 'gone') throw error;
      restart = { ...d, targetMs: videoMs };
      return true;
    }
    if (stale(d)) return true;
    if (next) {
      if (next.start - endMs >= GAP_CONTINUOUS_MS) {
        if (clock.position() >= next.start) { restart = { ...d, targetMs: clock.position() }; return true; }        // the clock is there already
        setCoverage({ kind: 'gap', next: next.start, epoch: d.epoch, playing: false });
        surface.pause();
        return true;
      }
      const held = chains.find((chain) => chain.headId === next.id);
      if (held) {
        surface.seek(seekSeconds(held.parts[0], held.startMs + 1, base())).catch(() => {});      // a hole under a second stalls the video: step over it
        return false;
      }
      // A next file that starts inside what just played (files can overlap on disk): go on where this chain ends, never back into it.
      restart = { ...d, targetMs: Math.max(next.start + 1, endMs) };
      return true;
    }
    const extent = catalog.extent(cameraId);
    if (extent && clock.mode === 'live' && videoMs >= extent.newest - 2500) return false;      // waiting for the recorder at the live edge
    setCoverage({ kind: 'gap', next: null, epoch: d.epoch, playing: false });
    surface.pause();
    return true;
  }

  // MARK: One desire

  async function handle(d) {
    await catalog.ready();
    if (stale(d)) return;
    if (d.probe) { await probe(d); return; }
    const { ms, oldest } = clampToExtent(d.targetMs);
    if (d.playing && oldest && clock.position() < ms) {
      // Before this camera's first recording. Paused, the tile shows that recording's first picture; playing (on a wall whose clock starts
      // at another camera's older recording) it waits for the clock to get there, as at any hole, so the picture tells the clock's time.
      surface?.pause();
      setCoverage({ kind: 'gap', next: ms, epoch: d.epoch, playing: false });
    } else if (d.precision === 'key') await keyStep(d, ms, oldest);
    else await exactStep(d, ms, oldest);
    if (d.playing && !stale(d) && restart === null && coverage.kind === 'gap' && coverage.epoch === d.epoch) await waitForRecording(d, d.targetMs);
  }

  function fail(error, d) {
    const name = error?.name;
    if (name === 'Superseded' || name === 'AbortError' || destroyed) return;
    if (name === 'Unsupported') { setCoverage({ kind: 'unsupported', message: error.message, epoch: d.epoch, playing: false }); return; }
    if (stale(d)) return;
    const status = error?.status;
    if (error?.code === 'unauthorized') return;                      // the page is signing out
    if ((status === 410 || error?.code === 'gone') && driveIsGone()) { driveGone(d); return; }       // the drive, not retention: no second plan
    if (status === 410 || error?.code === 'gone') {
      if (goneEpoch !== d.epoch) { goneEpoch = d.epoch; restart = { ...d }; return; }   // the catalog changed under us: plan again once
      setCoverage({ kind: 'unreadable', message: MESSAGES.unreadable, epoch: d.epoch, playing: false });
      return;
    }
    if (status === 504 || error?.code === 'drive_slow') { driveGone(d); return; }
    if (status === 429 || status === 503) {
      if (busyRetries < BUSY_RETRIES) {
        busyRetries += 1;
        setCoverage({ kind: 'loading', message: MESSAGES.busy, epoch: d.epoch, playing: false });
        timers.setTimeout(() => { if (!destroyed && desire && desire.epoch === d.epoch) { restart = { ...d }; wakeUp(); } }, BUSY_RETRY_MS);
        return;
      }
      setCoverage({ kind: 'unreadable', message: status === 429 ? MESSAGES.busy : MESSAGES.unavailable, epoch: d.epoch, playing: false });
      return;
    }
    if (status === 502 && driveIsGone()) { driveGone(d); return; }   // a file that was open when the volume vanished: the read fails with EIO (the bridge says unreadable) while the recorder says folderMissing
    if (status === 502) { setCoverage({ kind: 'unreadable', message: MESSAGES.unreadable, epoch: d.epoch, playing: false }); return; }
    if (status === 0) { setCoverage({ kind: 'unreadable', message: MESSAGES.network, epoch: d.epoch, playing: false }); return; }
    console.error(error);
    setCoverage({ kind: 'unreadable', message: MESSAGES.unavailable, epoch: d.epoch, playing: false });
  }

  async function run() {
    while (!destroyed) {
      const current = restart ?? desire;
      if (suspended || !current || (!restart && current.epoch === handledEpoch)) { await waitFor(Infinity); continue; }
      restart = null;
      handledEpoch = current.epoch;
      if (current.epoch !== desire.epoch) continue;
      try {
        await handle(current);
      } catch (error) {
        fail(error, current);
      }
    }
  }

  const done = run();
  done.catch((error) => console.error(error));

  return {
    /** O(1): keeps the newest desire and wakes the worker. */
    request(next) {
      if (destroyed || (desire && next.epoch <= desire.epoch)) return;
      desire = next;
      busyRetries = 0;
      clearDriveProbe();
      if (loadingTimer !== null) timers.clearTimeout(loadingTimer);
      loadingTimer = timers.setTimeout(() => {
        loadingTimer = null;
        if (!destroyed && desire && coverage.epoch < desire.epoch) setCoverage({ kind: 'loading', epoch: desire.epoch, playing: false });
      }, LOADING_AFTER_MS);
      wakeUp();
    },
    get coverage() { return coverage; },
    /** The camera's picture correction changed (saved on its page): the video the cell made is drawn straightened by it from now on. */
    setCorrection(next) {
      if (destroyed) return;
      correction = next ?? null;
      straighten();
    },
    onChange(fn) {
      listeners.add(fn);
      return () => listeners.delete(fn);
    },
    suspend() {
      suspended = true;
      clearDriveProbe();
      surface?.pause();
      wakeUp();
    },
    resume() {
      suspended = false;
      handledEpoch = -1;
      wakeUp();
    },
    destroy() {
      if (destroyed) return;
      destroyed = true;
      clearDriveProbe();
      if (loadingTimer !== null) timers.clearTimeout(loadingTimer);
      surfaceOff?.();
      surface?.destroy();
      view?.destroy();
      view = null;
      if (created) {
        video?.remove();
        holdCanvas?.remove();
      }
      listeners.clear();
      wakeUp();
    },
  };
}

/** Reads and checks the X-CB-Part header of a keyframe answer. */
export function readPartHeader(text) {
  let header;
  try { header = JSON.parse(text); } catch { header = null; }
  const ok = header
    && typeof header.id === 'string' && typeof header.file === 'string' && Number.isFinite(header.start) && Number.isFinite(header.end)
    && typeof header.mime === 'string' && Number.isFinite(header.anchor) && typeof header.initId === 'string';
  if (!ok) throw Object.assign(new Error(MESSAGES.unreadable), { status: 502, code: 'unreadable' });
  return header;
}
