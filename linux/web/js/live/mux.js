// Live video from the bridge: one request (`GET /api/v1/live`) carries every asked camera's live H.264/HEVC as fragmented MP4; this file reads
// it and feeds one Media Source Extensions player per camera. The message format is described in BridgeWeb/WebApp+LiveVideo.swift:
// a 6-byte header (type, camera index, length as a big-endian UInt32) and the payload.
//
//   const live = openLive(ids, { stream: 'sub', onMessage: (index, message) => … });   live.close();
//   const player = createLivePlayer(videoElement, { onPlaying, onProblem });  player.meta(meta); player.init(bytes); player.media(bytes, keyframe)
import { openStream } from '../api.js';

const TYPE = { 1: 'meta', 2: 'init', 3: 'delta', 4: 'keyframe', 5: 'status' };
const decoder = new TextDecoder();

/** The Media Source the browser offers (ManagedMediaSource on iPhone and iPad), or null. */
export function mediaSourceClass() {
  if (typeof window === 'undefined') return null;
  return window.ManagedMediaSource || window.MediaSource || null;
}

export function liveSupported() {
  const Source = mediaSourceClass();
  return Boolean(Source && Source.isTypeSupported?.('video/mp4; codecs="avc1.640028"'));
}

/** Splits a byte stream into messages. Returns a function to feed it chunks; `onMessage(type, index, payload)` runs per message. */
export function createParser(onMessage) {
  let buffer = new Uint8Array(0);
  return (chunk) => {
    if (chunk?.length) {
      const joined = new Uint8Array(buffer.length + chunk.length);
      joined.set(buffer, 0);
      joined.set(chunk, buffer.length);
      buffer = joined;
    }
    let offset = 0;
    while (buffer.length - offset >= 6) {
      const type = buffer[offset];
      const index = buffer[offset + 1];
      const length = ((buffer[offset + 2] << 24) >>> 0) + (buffer[offset + 3] << 16) + (buffer[offset + 4] << 8) + buffer[offset + 5];
      if (buffer.length - offset - 6 < length) break;
      const payload = buffer.slice(offset + 6, offset + 6 + length);
      offset += 6 + length;
      const kind = TYPE[type];
      if (kind) onMessage(kind, index, payload);
    }
    if (offset) buffer = buffer.slice(offset);
  };
}

/**
 * Opens the live request for `ids` (camera ids, in the order the indexes refer to), with the sound of the cameras in `audio`, and keeps it open: when it ends or fails it is opened again
 * after a short wait. `onMessage(index, { kind, json?, bytes? })` gets every message. Returns { close }.
 */
export function openLive(ids, { stream = 'sub', width = null, audio = [], onMessage, onState = () => {} } = {}) {
  let closed = false;
  let controller = null;
  let failures = 0;
  const query = `cameras=${ids.map(encodeURIComponent).join(',')}&stream=${encodeURIComponent(stream)}${width ? `&width=${Math.round(width)}` : ''}`
    + (audio.length ? `&audio=${audio.map(encodeURIComponent).join(',')}` : '');

  async function run() {
    while (!closed) {
      controller = new AbortController();
      try {
        onState('connecting');
        const body = await openStream(`live?${query}`, { signal: controller.signal });
        onState('open');
        failures = 0;
        const parse = createParser((kind, index, payload) => {
          if (kind === 'meta' || kind === 'status') onMessage(index, { kind, json: JSON.parse(decoder.decode(payload)) });
          else onMessage(index, { kind, bytes: payload });
        });
        const reader = body.getReader();
        for (;;) {
          const { value, done } = await reader.read();
          if (done || closed) break;
          parse(value);
        }
      } catch (error) {
        if (closed) return;
        failures += 1;
        onState('retrying', error);
      }
      if (closed) return;
      await new Promise((resolve) => setTimeout(resolve, Math.min(1000 * 2 ** Math.min(failures, 4), 15000)));
    }
  }
  run();
  return { close() { closed = true; controller?.abort(); } };
}

/**
 * A live player on `video` (muted until `setMuted(false)`, inline): a new MediaSource for every init (a new format or a new timeline), the frames appended as they
 * come, the oldest seconds trimmed, and the playhead kept at the live edge. `onPlaying()` runs when pictures move; `onProblem(text)` when this
 * browser cannot play the camera's format.
 */
export function createLivePlayer(video, { onPlaying = () => {}, onProblem = () => {} } = {}) {
  const Source = mediaSourceClass();
  let source = null;
  let buffer = null;
  let mime = null;
  let queue = [];
  let waitingForKey = false;
  let destroyed = false;
  let lastTrim = 0;
  // How far behind the newest frame playback aims to be. Most cameras play fine 0.3 s behind; a camera whose encoder holds frames back (its
  // decoder needs more ahead before it shows one) stalls there, and every stall moves the aim back by half a second, up to 3 s.
  let lag = 0.3;
  video.muted = true;
  video.playsInline = true;
  video.autoplay = true;
  video.disableRemotePlayback = true;

  function teardown() {
    queue = [];
    buffer = null;
    if (source) {
      try { if (source.readyState === 'open') source.endOfStream(); } catch { /* already ended */ }
    }
    source = null;
    video.removeAttribute('src');
    try { video.load(); } catch { /* nothing loaded */ }
  }

  function pump() {
    if (!buffer || buffer.updating || !queue.length || destroyed) return;
    const next = queue.shift();
    try {
      buffer.appendBuffer(next);
    } catch (error) {
      if (error?.name === 'QuotaExceededError') { trim(true); queue.unshift(next); return; }
      // The buffer refused it (a decode error): start over at the next init or keyframe.
      queue = [];
      waitingForKey = true;
    }
  }

  function trim(force = false) {
    if (!buffer || buffer.updating || !video.buffered.length) return;
    const now = performance.now();
    if (!force && now - lastTrim < 5000) return;
    const start = video.buffered.start(0);
    const keepFrom = video.currentTime - 8;
    if (keepFrom - start > 2) {
      lastTrim = now;
      try { buffer.remove(start, keepFrom); } catch { /* the next append trims again */ }
    }
  }

  function chase() {
    if (!video.buffered.length) return;
    const end = video.buffered.end(video.buffered.length - 1);
    // Well behind the aim (a hidden tab, a slow moment): jump to it.
    if (end - video.currentTime > lag + 1.0 || video.currentTime < video.buffered.start(0)) video.currentTime = Math.max(video.buffered.start(0), end - lag);
    if (video.paused) video.play().catch(() => {});
  }

  function start(nextMime, initBytes) {
    teardown();
    if (!Source || !Source.isTypeSupported(nextMime)) { onProblem('This browser can’t play this camera’s video format.'); return; }
    mime = nextMime;
    waitingForKey = false;
    const created = new Source();
    source = created;
    video.src = URL.createObjectURL(created);
    created.addEventListener('sourceopen', () => {
      if (source !== created || destroyed) return;
      URL.revokeObjectURL(video.src);
      try {
        buffer = created.addSourceBuffer(mime);
        buffer.mode = 'segments';
      } catch {
        onProblem('This browser can’t play this camera’s video format.');
        return;
      }
      buffer.addEventListener('updateend', () => { trim(); chase(); pump(); });
      queue.unshift(initBytes);
      pump();
    }, { once: true });
  }

  const onPlay = () => onPlaying();
  const onWaiting = () => { if (!destroyed && source) lag = Math.min(3, lag + 0.5); };
  // The browser could not decode what it accepted (a picture larger than its decoder takes): say so, so the page shows pictures instead.
  const onError = () => { if (!destroyed && video.error) onProblem('This browser could not decode this camera’s video.'); };
  video.addEventListener('playing', onPlay);
  video.addEventListener('error', onError);
  video.addEventListener('waiting', onWaiting);
  let pendingMeta = null;

  return {
    /** A new init segment follows (its mime type and picture size). */
    meta(json) { pendingMeta = json; },
    init(bytes) {
      if (!pendingMeta?.mime) return;
      start(pendingMeta.mime, bytes);
    },
    media(bytes, keyframe) {
      if (destroyed || !source) return;
      if (waitingForKey) { if (!keyframe) return; waitingForKey = false; }
      queue.push(bytes);
      // Far behind (a slow device): drop what waits and continue at the next keyframe.
      if (queue.length > 240) { queue = []; waitingForKey = !keyframe; if (keyframe) queue.push(bytes); }
      pump();
    },
    /** Sound on or off (on needs a click on the page first: browsers play sound only after one). */
    setMuted(muted) { video.muted = muted; if (!muted && video.paused) video.play().catch(() => {}); },
    /** Called when the tab shows again: jump to the newest picture. */
    catchUp() { chase(); },
    destroy() {
      destroyed = true;
      video.removeEventListener('playing', onPlay);
      video.removeEventListener('error', onError);
      video.removeEventListener('waiting', onWaiting);
      teardown();
    },
  };
}
