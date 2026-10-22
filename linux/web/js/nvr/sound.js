// A camera's recorded sound beside its picture: one hidden <audio> fed through its own MediaSource with the recording's sound alone
// (`…/fragments/:fid?track=sound`, AAC), kept on the shared playhead. The picture's players stay video-only, so scrubbing and key pictures work
// as before; sound plays only while the playhead plays (not while scrubbing, paused or live: live sound comes with the live video).
//
// Buffer times are the picture's: seconds on the page's time line, (epoch ms - the catalog's baseMs) / 1000, each file placed by its anchor.
import { bufferSeconds, timestampOffsetSeconds } from './planner.js';
import { soundAllowed } from './speed.js';

const TICK_MS = 400;
const AHEAD_SEC = 8;            // keep this much sound ahead of the playhead
const KEEP_BEHIND_SEC = 10;     // and drop what is older than this behind it
const DRIFT_SEC = 0.25;         // further from the playhead than this: jump to it
const SOUND_MIME = 'audio/mp4; codecs="mp4a.40.2"';

/** True when this browser can play recorded sound through MediaSource. */
export function soundSupported(scope = globalThis) {
  const Source = scope.MediaSource ?? scope.ManagedMediaSource;
  return !!Source && typeof Source.isTypeSupported === 'function' && Source.isTypeSupported(SOUND_MIME);
}

/** -> { setCamera(id | null), destroy() } */
export function createRecordingSound({ catalog, fetcher, clock, doc = document }) {
  const audio = doc.createElement('audio');
  audio.hidden = true;
  doc.body.append(audio);
  let cameraId = null;
  let source = null;
  let buffer = null;
  let files = new Map();        // fileKey -> { anchor, initId, sound }
  let activeFile = null;        // the file whose init the buffer parsed last
  let nextAfter = null;         // the fragment id to continue from, null: plan again at the playhead
  let busy = false;
  let generation = 0;           // a new camera or a jump makes everything in flight stale
  let destroyed = false;
  const key = () => `sound:${cameraId}`;

  function waitUpdate() {
    return new Promise((resolve) => {
      if (!buffer?.updating) { resolve(); return; }
      buffer.addEventListener('updateend', () => resolve(), { once: true });
    });
  }

  async function append(data) {
    if (!buffer) return;
    await waitUpdate();
    buffer.appendBuffer(data);
    await waitUpdate();
  }

  function teardown() {
    generation += 1;
    try { audio.pause(); } catch { /* not playing */ }
    if (source?.readyState === 'open') { try { source.endOfStream(); } catch { /* already ended */ } }
    source = null;
    buffer = null;
    activeFile = null;
    nextAfter = null;
    files = new Map();
    audio.removeAttribute('src');
    try { audio.load(); } catch { /* nothing loaded */ }
  }

  async function open() {
    const Source = globalThis.MediaSource ?? globalThis.ManagedMediaSource;
    const created = new Source();
    source = created;
    const mine = generation;
    audio.src = URL.createObjectURL(created);
    await new Promise((resolve) => created.addEventListener('sourceopen', resolve, { once: true }));
    URL.revokeObjectURL(audio.src);
    if (mine !== generation || source !== created) return false;
    buffer = created.addSourceBuffer(SOUND_MIME);
    buffer.mode = 'segments';
    return true;
  }

  const target = () => bufferSeconds(clock.position(), catalog.baseMs);

  function bufferedAround(t) {
    const ranges = audio.buffered;
    for (let i = 0; i < ranges.length; i += 1) if (ranges.start(i) - 0.5 <= t && t <= ranges.end(i) + 0.5) return { start: ranges.start(i), end: ranges.end(i) };
    return null;
  }

  /** Fetches the next few parts' sound and appends it. */
  async function feed() {
    const mine = generation;
    const id = cameraId;
    const answer = nextAfter
      ? await catalog.after(id, nextAfter, { limit: 4, key: key() })
      : await catalog.plan(id, clock.position(), { ahead: 4, key: key() });
    if (mine !== generation) return;
    if (answer.found === false) { nextAfter = null; return; }
    for (const [fileKey, info] of Object.entries(answer.files || {})) files.set(fileKey, info);
    const parts = answer.targetIndex !== undefined ? answer.parts.slice(Math.max(0, answer.targetIndex - 1)) : answer.parts;
    for (const part of parts) {
      if (mine !== generation || destroyed) return;
      nextAfter = part.id;
      const info = files.get(part.file) ?? catalog.file(part.file);
      if (!info?.sound) continue;
      if (activeFile !== part.file) {
        const init = await fetcher.bytes(`nvr/cameras/${encodeURIComponent(id)}/fragments/${encodeURIComponent(info.initId)}/init?track=sound`, { key: key(), priority: -1 });
        if (mine !== generation || !init.data.byteLength) continue;
        await append(init.data);
        activeFile = part.file;
        buffer.timestampOffset = timestampOffsetSeconds(info.anchor, catalog.baseMs);
      }
      const piece = await fetcher.bytes(`nvr/cameras/${encodeURIComponent(id)}/fragments/${encodeURIComponent(part.id)}?track=sound`, { key: key(), priority: -1 });
      if (mine !== generation || !piece.data.byteLength) continue;
      await append(piece.data);
    }
  }

  function trim(t) {
    if (!buffer || buffer.updating || !audio.buffered.length) return;
    const start = audio.buffered.start(0);
    if (t - KEEP_BEHIND_SEC > start + 1) { try { buffer.remove(start, t - KEEP_BEHIND_SEC); } catch { /* the next tick trims */ } }
  }

  async function tick() {
    if (destroyed || busy) return;
    // Above 2× the sound is left out (nvr/speed.js): nothing is fetched or played, and it plays again when the speed comes down.
    if (cameraId === null || clock.mode !== 'playing' || catalog.baseMs === undefined || !soundAllowed(clock.rate)) { if (!audio.paused) audio.pause(); return; }
    busy = true;
    try {
      if (!source && !(await open())) return;
      const t = target();
      const around = bufferedAround(t);
      if (!around && audio.buffered.length) {
        // The playhead jumped away from what is held: start again there.
        const camera = cameraId;
        teardown();
        cameraId = camera;
        return;
      }
      if (!around || around.end - t < AHEAD_SEC) await feed();
      const held = bufferedAround(target());
      if (!held) return;
      const now = target();
      if (Math.abs(audio.currentTime - now) > DRIFT_SEC) audio.currentTime = now;
      if (audio.playbackRate !== (clock.rate ?? 1)) audio.playbackRate = clock.rate ?? 1;
      if (audio.paused) await audio.play().catch(() => {});
      trim(now);
    } catch {
      // A part that could not be read or appended: plan again at the playhead on the next tick.
      nextAfter = null;
    } finally {
      busy = false;
    }
  }

  const timer = setInterval(() => { tick(); }, TICK_MS);
  const offClock = clock.onChange?.(() => { tick(); });
  const offRate = clock.onRate?.(() => { tick(); });

  return {
    /** Plays `id`'s recorded sound while the playhead plays (null: none). */
    setCamera(id) {
      if (id === cameraId) return;
      teardown();
      cameraId = id;
      tick();
    },
    destroy() {
      destroyed = true;
      clearInterval(timer);
      offClock?.();
      offRate?.();
      teardown();
      audio.remove();
    },
  };
}
