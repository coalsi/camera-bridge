// Snapshots of recorded moments for the Events page and the Monitor's events list: the picture at an event's start, from the recording.
//
// The bridge has no picture route for a moment in the past, only the recording's key picture (GET nvr/cameras/:id/keyframe?at=&picture=1: the first
// picture of the key fragment, alone, as a fragment of one sample). So the page decodes that picture itself: a <video> that is never put on the page
// plays it through a MediaSource, one frame is drawn on a canvas, and the picture is kept as a small data: URL (the page's CSP allows img-src data:,
// not blob:). Nothing is shown as video. Pictures are asked for only when their tile is on screen (IntersectionObserver), at most `concurrency` at a
// time, and a tile that scrolled away before its turn is dropped from the queue. A moment with no footage, or a browser that cannot decode it, leaves
// a plain placeholder (data-state "none").
//
// The picture alone is the lighter ask, but only Chrome is known to decode it. When a browser's decode of one fails or says nothing in DECODE_MS, the
// picture is asked for the way every browser was asked before: the whole key fragment, decoded as it always was, for that picture at once and for every
// picture after it for the life of the page. So no thumbnail is worse for the lone picture than it was.
import { getBytes } from '../api.js';
import { clear, h } from '../dom.js';

const WIDTH = 320;
const QUALITY = 0.7;
const DECODE_MS = 6000;
const KEEP = 400;                     // pictures kept in memory (data URLs of 10 to 20 KB)
const RETRY_MS = 30_000;              // a picture that failed for a passing reason is asked for again after this, if its tile is still on screen
const TRIES = 3;                      // and after this many failures it is a plain placeholder for good

// Whether pictures are still asked for alone. A browser that fails to decode one clears it, and every picture after that is the whole key fragment.
let pictureAlone = true;

/** Reads the X-CB-Part header of a keyframe answer: { mime, initId }, or null. */
function partOf(headers) {
  try {
    const part = JSON.parse(headers.get('X-CB-Part'));
    return typeof part?.mime === 'string' && typeof part?.initId === 'string' ? part : null;
  } catch { return null; }
}

function once(target, type, ms) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { target.removeEventListener(type, done); reject(new Error(`no ${type}`)); }, ms);
    function done() { clearTimeout(timer); resolve(); }
    target.addEventListener(type, done, { once: true });
  });
}

async function append(buffer, bytes) {
  const finished = once(buffer, 'updateend', DECODE_MS);
  buffer.appendBuffer(bytes);
  await finished;
}

/** Whether this browser can play `mime` through a MediaSource at all. */
function playable(mime) {
  const Source = globalThis.MediaSource;
  return Boolean(Source && Source.isTypeSupported?.(mime));
}

/**
 * Decodes the first picture of `media` to a JPEG data: URL, or null when this browser cannot. `init` and `media` are MP4 bytes of `mime`: `media` is a
 * key fragment, or with `alone` its first picture only (a fragment of one sample). Alone, the stream is ended before the seek and the seek lands inside
 * a picture shorter than 20 ms; a key fragment is decoded exactly as it was before the picture alone was asked for.
 */
export async function decodeFirstFrame({ mime, init, media, alone = false }) {
  if (!playable(mime)) return null;
  const Source = globalThis.MediaSource;
  const video = document.createElement('video');
  video.muted = true;
  video.preload = 'auto';
  const source = new Source();
  const url = URL.createObjectURL(source);
  try {
    const opened = once(source, 'sourceopen', DECODE_MS);
    video.src = url;
    await opened;
    const buffer = source.addSourceBuffer(mime);
    buffer.mode = 'segments';
    await append(buffer, init);
    await append(buffer, media);
    if (!buffer.buffered.length) return null;
    // Nothing more comes. A decoder that holds pictures back (a stream with B-frames) gives up the first picture of a fragment of one only when it is told so.
    if (alone && source.readyState === 'open') source.endOfStream();
    const ready = once(video, 'seeked', DECODE_MS);
    const range = buffer.buffered;
    // Inside the first picture, which alone may be all there is.
    video.currentTime = range.start(0) + (alone ? Math.min(0.01, (range.end(0) - range.start(0)) / 2) : 0.01);
    await ready;
    if (!video.videoWidth) return null;
    const canvas = document.createElement('canvas');
    canvas.width = Math.min(WIDTH, video.videoWidth);
    canvas.height = Math.max(1, Math.round((canvas.width * video.videoHeight) / video.videoWidth));
    canvas.getContext('2d').drawImage(video, 0, 0, canvas.width, canvas.height);
    return canvas.toDataURL('image/jpeg', QUALITY);
  } finally {
    video.removeAttribute('src');
    try { video.load(); } catch { /* already gone */ }
    URL.revokeObjectURL(url);
  }
}

/**
 * What the bridge answers for the key picture at `atMs`, with the init segment its answer names: { mime, init, media }; null when there is no footage then
 * (a 404 gap) or the answer does not say what it is. `alone` asks for the first picture only (&picture=1), else the whole key fragment. Other failures reject.
 */
async function keyAnswer(base, atMs, bytes, alone) {
  let answer;
  try {
    answer = await bytes(`${base}/keyframe?at=${Math.floor(atMs)}${alone ? '&picture=1' : ''}`);
  } catch (error) {
    if (error?.status === 404 || error?.code === 'gap') return null;
    throw error;
  }
  const part = partOf(answer.headers);
  if (!part) return null;
  const init = await bytes(`${base}/fragments/${encodeURIComponent(part.initId)}/init`);
  return { mime: part.mime, init: init.data, media: answer.data };
}

/**
 * The picture of camera `cameraId` at `atMs` as a data: URL; null when there is none (a 404 gap is a plain "no footage", and so is a browser that
 * cannot decode it). A passing failure (busy, the drive slow or away, the network) rejects. `bytes(path)` fetches: the page's request scheduler
 * (nvr/fetcher.js), so the pictures keep to its budget of the browser's connections; getBytes alone by default. `decode` is decodeFirstFrame (a test
 * gives its own).
 *
 * The picture is asked for alone first. If this browser then fails to decode it (the decode throws, or times out, or draws nothing though the browser can
 * play that codec), the picture is asked for again as the whole key fragment, once, and `pictureAlone` is cleared: the next pictures go straight there. Only
 * the decode counts. A busy bridge or a lost connection says nothing about the browser and rejects as before, with no second request and nothing remembered.
 */
export async function loadKeyframePicture(cameraId, atMs, { bytes = (path) => getBytes(path, { timeoutMs: 8000 }), decode = decodeFirstFrame } = {}) {
  const base = `nvr/cameras/${encodeURIComponent(cameraId)}`;
  if (pictureAlone) {
    const found = await keyAnswer(base, atMs, bytes, true);
    if (!found) return null;
    try {
      const picture = await decode({ ...found, alone: true });
      if (picture || !playable(found.mime)) return picture;
    } catch { /* it never answered, or the browser refused the append: the whole fragment, below */ }
    pictureAlone = false;
  }
  const found = await keyAnswer(base, atMs, bytes, false);
  return found ? decode({ ...found, alone: false }) : null;
}

/** A loader of pictures through the page's request scheduler (`fetcher`, nvr/fetcher.js): the lowest priority, so a button or a tile goes first. */
export function fetcherPictures(fetcher) {
  return (cameraId, atMs) => loadKeyframePicture(cameraId, atMs, { bytes: (path) => fetcher.bytes(path, { priority: -1 }) });
}

/**
 * The tiles: `tile(cameraId, atMs)` is a <div class="ev-thumb" data-state="idle|loading|loaded|none"> that loads its picture when it comes into view.
 *   load(cameraId, atMs)      the picture as a data: URL or null for none (default: loadKeyframePicture); a rejection is a passing failure: the
 *                             tile is idle again and asked for again when it next comes into view or after RETRY_MS, and after TRIES failures it
 *                             is "none" (only a definite answer is kept for the page's life)
 *   createObserver(callback)  an IntersectionObserver-like { observe, unobserve, disconnect }; null: tiles load as they are made
 *   concurrency               pictures in flight at once
 */
export function createThumbnails({ load = loadKeyframePicture, createObserver = defaultObserver, concurrency = 2, keep = KEEP, retryMs = RETRY_MS,
  setTimer = (fn, ms) => setTimeout(fn, ms), clearTimer = (t) => clearTimeout(t) } = {}) {
  const cache = new Map();            // `${camera}|${ms}` -> data URL, or null for no picture
  const failures = new Map();         // `${camera}|${ms}` -> passing failures so far
  const waiting = [];                 // tiles that are visible and wait for a turn
  const records = new Map();          // tile -> { cameraId, atMs, key, visible }
  const retries = new Set();          // timers of tiles to ask for again
  let running = 0;
  let destroyed = false;
  const observer = createObserver ? createObserver((entries) => {
    for (const entry of entries) {
      const record = records.get(entry.target);
      if (!record) continue;
      record.visible = entry.isIntersecting;
      if (record.visible) request(entry.target);
      else if (waiting.includes(entry.target)) waiting.splice(waiting.indexOf(entry.target), 1);
    }
  }) : null;

  function show(el, picture) {
    el.dataset.state = picture ? 'loaded' : 'none';
    clear(el);
    if (picture) el.append(h('img', { src: picture, alt: '', decoding: 'async', draggable: 'false' }));
  }

  function request(el) {
    const record = records.get(el);
    if (!record || el.dataset.state === 'loaded' || el.dataset.state === 'none') return;
    if (cache.has(record.key)) { show(el, cache.get(record.key)); return; }
    if (!waiting.includes(el) && el.dataset.state !== 'loading') waiting.push(el);
    pump();
  }

  function pump() {
    while (!destroyed && running < concurrency && waiting.length) {
      const el = waiting.shift();
      const record = records.get(el);
      if (!record) continue;
      if (cache.has(record.key)) { show(el, cache.get(record.key)); continue; }
      running += 1;
      el.dataset.state = 'loading';
      Promise.resolve().then(() => load(record.cameraId, record.atMs)).then((picture) => {
        running -= 1;
        if (destroyed) return;
        remember(record.key, picture ?? null);
        if (records.has(el)) show(el, picture ?? null);
        pump();
      }, (error) => {
        running -= 1;
        if (destroyed) return;
        const count = (failures.get(record.key) ?? 0) + 1;
        failures.set(record.key, count);
        if (count >= TRIES || error?.status === 404 || error?.code === 'gap') {
          remember(record.key, null);
          if (records.has(el)) show(el, null);
        } else if (records.has(el)) {
          // Busy, the drive slow or away, the network: not "no picture". Idle again, and asked for again while it is on screen.
          el.dataset.state = 'idle';
          const timer = setTimer(() => { retries.delete(timer); if (!destroyed && records.get(el)?.visible) request(el); }, retryMs);
          retries.add(timer);
        }
        pump();
      });
    }
  }

  function remember(key, picture) {
    failures.delete(key);
    cache.set(key, picture);
    if (cache.size > keep) cache.delete(cache.keys().next().value);
  }

  return {
    tile(cameraId, atMs) {
      const el = h('div', { class: 'ev-thumb', 'aria-hidden': 'true', dataset: { state: 'idle' } });
      const key = `${cameraId}|${atMs}`;
      records.set(el, { cameraId, atMs, key, visible: !observer });
      if (cache.has(key)) show(el, cache.get(key));       // seen before: no wait for the next frame
      else if (observer) observer.observe(el);
      else request(el);
      return el;
    },
    /** Forgets tiles that left the page (the list was drawn again). */
    release(el) {
      records.delete(el);
      observer?.unobserve(el);
      if (waiting.includes(el)) waiting.splice(waiting.indexOf(el), 1);
    },
    destroy() {
      destroyed = true;
      for (const timer of retries) clearTimer(timer);
      retries.clear();
      observer?.disconnect();
      records.clear();
      waiting.length = 0;
    },
  };
}

function defaultObserver(callback) {
  return typeof IntersectionObserver === 'function' ? new IntersectionObserver(callback, { rootMargin: '200px 0px' }) : null;
}
