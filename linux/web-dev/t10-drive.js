// T10 browser driver: a plain script (no module, no dependencies) that you evaluate inside the open watch screen with the browser tool's
// "run JavaScript in the page" action. It defines window.__t10 and returns nothing. Every function returns a plain object so the result can be
// printed. It reads no cookie and no storage, and never prints a header or a body.
//
// Needs the debug hook: set it BEFORE the page loads the watch screen (the watch screen publishes window.__cbWatch only then):
//     localStorage.setItem('cb.nvr.debug', '1');  location.reload();
(() => {
  const hook = () => {
    if (!window.__cbWatch) throw new Error('window.__cbWatch is missing: set localStorage cb.nvr.debug to 1 and reload the watch screen');
    return window.__cbWatch;
  };
  const track = () => document.querySelector('[data-nvr="track"]');
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const frame = () => new Promise((resolve) => requestAnimationFrame(resolve));

  async function waitFor(test, timeoutMs = 2000, stepMs = 25) {
    const started = performance.now();
    while (performance.now() - started < timeoutMs) {
      if (test()) return true;
      await sleep(stepMs);
    }
    return !!test();
  }

  let last = { x: 0, y: 0 };
  const pointer = (type, x, y, extra = {}) => new PointerEvent(type, {
    pointerId: 7, pointerType: 'mouse', isPrimary: true, button: 0, buttons: type === 'pointerup' ? 0 : 1, clientX: x, clientY: y, bubbles: true, cancelable: true, ...extra,
  });

  /** Records every beginScrub/scrub/endScrub call with the animation-frame time it ran in. Safe to call twice. */
  function instrument() {
    const { session } = hook();
    if (session.__t10) return session.__t10;
    const log = { calls: [], frames: 0, stop: false };
    for (const name of ['beginScrub', 'scrub', 'endScrub', 'seek', 'togglePlay', 'goLive', 'play', 'pause']) {
      if (typeof session[name] !== 'function') continue;
      const original = session[name].bind(session);
      session[name] = (...args) => { log.calls.push({ name, args, frame: document.timeline.currentTime, at: performance.now() }); return original(...args); };
    }
    (function count() { log.frames += 1; if (!log.stop) requestAnimationFrame(count); }());
    session.__t10 = log;
    return log;
  }

  /** How many pixels of the stage show a picture right now (the preview image, the video, or the hold canvas). 0 means a blank frame. */
  function litPixels() {
    const stage = document.querySelector('[data-nvr="stage"]');
    const probe = document.createElement('canvas');
    probe.width = 32; probe.height = 18;
    const context = probe.getContext('2d', { willReadFrequently: true });
    const img = stage.querySelector('.preview img');
    const video = stage.querySelector('video');
    const hold = stage.querySelector('canvas');
    const visible = [
      [img, img && !img.hidden && img.complete && img.naturalWidth > 0],
      [video, video && stage.dataset.layer === 'video' && video.readyState >= 2 && video.videoWidth > 0],
      [hold, hold && !hold.hidden],
    ];
    for (const [element, show] of visible) if (show) { try { context.drawImage(element, 0, 0, 32, 18); } catch { /* tainted: cannot happen on the same origin */ } }
    const { data } = context.getImageData(0, 0, 32, 18);
    let lit = 0;
    for (let i = 0; i < data.length; i += 4) if (data[i + 3] > 0 && data[i] + data[i + 1] + data[i + 2] > 12) lit += 1;
    return lit;
  }

  /**
   * One drag across the track, at `hz` pointer events a second (events are issued from animation frames, so 120 Hz on a 60 Hz display is two events per frame).
   * -> { events, frames, scrubs, maxScrubsPerFrame, meanEventMs, p95EventMs, maxEventMs, blankFrames, finalPositionMs }
   */
  async function drag({ from = 0.8, to = 0.2, hz = 120, durationMs = 2000, release = true, sampleBlank = true } = {}) {
    const log = instrument();
    const el = track();
    const rect = el.getBoundingClientRect();
    const y = rect.top + rect.height / 2;
    const xAt = (t) => rect.left + rect.width * (from + (to - from) * t);
    const costs = [];
    const timed = (event) => { last = { x: event.clientX, y: event.clientY }; const t0 = performance.now(); el.dispatchEvent(event); costs.push(performance.now() - t0); };
    const callsBefore = log.calls.length;
    const framesBefore = log.frames;
    let blank = 0;
    timed(pointer('pointerdown', xAt(0), y));
    const total = Math.max(1, Math.round((hz * durationMs) / 1000));
    const started = performance.now();
    let sent = 0;
    while (sent < total) {
      await frame();
      const due = Math.min(total, Math.floor(((performance.now() - started) * hz) / 1000));
      while (sent < due) { sent += 1; timed(pointer('pointermove', xAt(sent / total), y)); }
      if (sampleBlank && litPixels() === 0) blank += 1;
    }
    const beforeRelease = log.calls.length;
    if (release) timed(pointer('pointerup', xAt(1), y, { buttons: 0 }));
    const calls = log.calls.slice(callsBefore);
    const scrubs = calls.filter((c) => c.name === 'scrub');
    // The release flushes the newest position at once (by design), so the one-per-frame rule is counted over the drag itself.
    const perFrame = new Map();
    for (const c of log.calls.slice(callsBefore, beforeRelease)) if (c.name === 'scrub') perFrame.set(c.frame, (perFrame.get(c.frame) || 0) + 1);
    costs.sort((a, b) => a - b);
    return {
      events: costs.length, frames: log.frames - framesBefore, scrubs: scrubs.length, maxScrubsPerFrame: Math.max(0, ...perFrame.values()),
      meanEventMs: +(costs.reduce((a, b) => a + b, 0) / costs.length).toFixed(3), p95EventMs: +costs[Math.floor(costs.length * 0.95)].toFixed(3),
      maxEventMs: +costs[costs.length - 1].toFixed(3), blankFrames: blank, finalPositionMs: hook().session.position,
      endedOnce: calls.filter((c) => c.name === 'endScrub').length === (release ? 1 : 0),
    };
  }

  /** Lets go of a drag that was started with `release: false`, where the pointer stopped. */
  function release() {
    track().dispatchEvent(pointer('pointerup', last.x, last.y, { buttons: 0 }));
  }

  /** A click on the track (touch or mouse): down and up at the same place. */
  async function tap({ at = 0.5, pointerType = 'mouse' } = {}) {
    const el = track();
    const rect = el.getBoundingClientRect();
    const x = rect.left + rect.width * at;
    const y = rect.top + rect.height / 2;
    el.dispatchEvent(pointer('pointerdown', x, y, { pointerType }));
    await frame();
    el.dispatchEvent(pointer('pointerup', x, y, { pointerType, buttons: 0 }));
    await frame();
    return { position: hook().session.position };
  }

  /** `count` quick scrubs to random places, each released and sampled for blank frames. -> { scrubs, blankFrames, samples } */
  async function scrubStorm({ count = 100, settleMs = 60 } = {}) {
    let blank = 0;
    let samples = 0;
    for (let i = 0; i < count; i += 1) {
      const from = 0.1 + Math.random() * 0.8;
      const result = await drag({ from, to: Math.min(0.95, Math.max(0.05, from + (Math.random() - 0.5) * 0.3)), hz: 120, durationMs: 150, sampleBlank: true });
      blank += result.blankFrames;
      samples += result.frames;
      await sleep(settleMs);
      if (litPixels() === 0) blank += 1;
      samples += 1;
    }
    return { scrubs: count, blankFrames: blank, samples };
  }

  /** The first gap in the recorded span, from the activity answer the page itself would get. -> { fromMs, toMs } or null */
  async function findGap(cameraId) {
    const { catalog } = hook();
    const extent = catalog.extent(cameraId);
    const binMs = 60_000;
    const fromMs = Math.floor((Math.max(extent.oldest, catalog.serverNow() - 1440 * binMs) + binMs) / binMs) * binMs;
    const answer = await catalog.activity({ cameras: [cameraId], fromMs, binMs, bins: 1440, key: 't10-find-gap' });
    const { coverage } = answer.byCamera[cameraId] || { coverage: [] };
    const first = coverage.findIndex((c) => c > 0);
    const start = coverage.findIndex((c, i) => i > first && c === 0);
    if (first < 0 || start < 0) return null;
    let end = start;
    while (end < coverage.length && coverage[end] === 0) end += 1;
    return end >= coverage.length ? null : { fromMs: answer.from + start * binMs, toMs: answer.from + end * binMs };
  }

  const key = (k, extra = {}) => document.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true, ...extra }));

  function wheel(extra) {
    const el = track();
    const rect = el.getBoundingClientRect();
    const event = new WheelEvent('wheel', { clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2, bubbles: true, cancelable: true, deltaMode: 0, ...extra });
    el.dispatchEvent(event);
    return { defaultPrevented: event.defaultPrevented };
  }

  /** Makes every request to /api/v1/ answer 401 once `trigger()` is called, and counts them; `restore()` puts fetch back. */
  function forceUnauthorized() {
    const original = window.fetch;
    const seen = { total: 0, afterTrigger: 0 };
    let on = false;
    window.fetch = (input, init) => {
      const url = typeof input === 'string' ? input : input.url;
      if (url.includes('/api/v1/')) {
        seen.total += 1;
        if (on) {
          seen.afterTrigger += 1;
          return Promise.resolve(new Response(JSON.stringify({ error: 'unauthorized', message: 'Sign in again.' }), { status: 401, headers: { 'Content-Type': 'application/json' } }));
        }
      }
      return original(input, init);
    };
    return { trigger() { on = true; }, seen, restore() { window.fetch = original; } };
  }

  /** What the screen shows, for a printed summary (no storage, no cookies). */
  function state() {
    const { session, catalog } = hook();
    const stage = document.querySelector('[data-nvr="stage"]');
    const slider = track();
    return {
      mode: session.mode, positionMs: Math.round(session.position), nowMs: Math.round(catalog.serverNow()), layer: stage?.dataset.layer,
      overlay: document.querySelector('.watch-overlay:not([hidden]) strong')?.textContent ?? null,
      caption: document.querySelector('.watch-caption-text')?.textContent ?? null,
      readout: document.querySelector('[data-nvr="readout"]')?.textContent ?? null,
      pressedPreset: document.querySelector('.nvr-preset[aria-pressed="true"]')?.dataset.preset ?? null,
      valueText: slider?.getAttribute('aria-valuetext') ?? null, disabled: slider?.getAttribute('aria-disabled'),
      hash: location.hash, lit: litPixels(),
    };
  }

  window.__t10 = { hook, track, sleep, frame, waitFor, instrument, litPixels, drag, release, tap, scrubStorm, findGap, key, wheel, forceUnauthorized, state };
})();
