// Snapshots of recorded moments for the Events page and the Monitor's events list: the picture at an event's start, from the recording.
//
// The bridge has no picture route for a moment in the past, only the recording's key fragment (GET nvr/cameras/:id/keyframe?at=). So the page
// decodes the first picture of that fragment itself: a <video> that is never put on the page plays the fragment through a MediaSource, one
// frame is drawn on a canvas, and the picture is kept as a small data: URL (the page's CSP allows img-src data:, not blob:). Nothing is
// shown as video. Pictures are asked for only when their tile is on screen (IntersectionObserver), at most `concurrency` at a time, and a
// tile that scrolled away before its turn is dropped from the queue. A moment with no footage, or a browser that cannot decode it, leaves a plain
// placeholder (data-state "none").
import { getBytes } from '../api.js';
import { clear, h } from '../dom.js';

const WIDTH = 320;
const QUALITY = 0.7;
const DECODE_MS = 6000;
const KEEP = 400;                     // pictures kept in memory (data URLs of 10 to 20 KB)

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

/** Decodes the first picture of a key fragment (`init` + `media`, MP4 bytes of `mime`) to a JPEG data: URL, or null when this browser cannot. */
export async function decodeFirstFrame({ mime, init, media }) {
  const Source = globalThis.MediaSource;
  if (!Source || !Source.isTypeSupported?.(mime)) return null;
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
    const ready = once(video, 'seeked', DECODE_MS);
    video.currentTime = buffer.buffered.start(0) + 0.01;
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

/** The picture of camera `cameraId` at `atMs` as a data: URL; null when it cannot be had (a 404 gap is a plain "no footage"). */
export async function loadKeyframePicture(cameraId, atMs) {
  const base = `nvr/cameras/${encodeURIComponent(cameraId)}`;
  let answer;
  try {
    answer = await getBytes(`${base}/keyframe?at=${Math.floor(atMs)}`, { timeoutMs: 8000 });
  } catch (error) {
    if (error?.status === 404 || error?.code === 'gap') return null;
    throw error;
  }
  const part = partOf(answer.headers);
  if (!part) return null;
  const init = await getBytes(`${base}/fragments/${encodeURIComponent(part.initId)}/init`, { timeoutMs: 8000 });
  return decodeFirstFrame({ mime: part.mime, init: init.data, media: answer.data });
}

/**
 * The tiles: `tile(cameraId, atMs)` is a <div class="ev-thumb" data-state="idle|loading|loaded|none"> that loads its picture when it comes into view.
 *   load(cameraId, atMs)      the picture as a data: URL or null (default: loadKeyframePicture); a rejection leaves "none" too
 *   createObserver(callback)  an IntersectionObserver-like { observe, unobserve, disconnect }; null: tiles load as they are made
 *   concurrency               pictures in flight at once
 */
export function createThumbnails({ load = loadKeyframePicture, createObserver = defaultObserver, concurrency = 2, keep = KEEP } = {}) {
  const cache = new Map();            // `${camera}|${ms}` -> data URL, or null for no picture
  const waiting = [];                 // tiles that are visible and wait for a turn
  const records = new Map();          // tile -> { cameraId, atMs, key, visible }
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
      Promise.resolve().then(() => load(record.cameraId, record.atMs)).catch(() => null).then((picture) => {
        running -= 1;
        if (destroyed) return;
        cache.set(record.key, picture ?? null);
        if (cache.size > keep) cache.delete(cache.keys().next().value);
        if (records.has(el)) show(el, picture);
        pump();
      });
    }
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
      observer?.disconnect();
      records.clear();
      waiting.length = 0;
    },
  };
}

function defaultObserver(callback) {
  return typeof IntersectionObserver === 'function' ? new IntersectionObserver(callback, { rootMargin: '200px 0px' }) : null;
}
