// Pointer events on the timeline track -> session.beginScrub() / scrub(ms) / endScrub().
// Pointer events can arrive at 120 Hz or more; the session hears about at most one position per animation frame (the newest), and the
// release always flushes the newest position before it ends the scrub. A mouse or pen scrubs from the press; a finger scrubs after it has
// moved 6 px (so a swipe that starts on the track can still be told from a drag), or on a tap.

export const TOUCH_SLOP_PX = 6;

/**
 * `timeForX(x)` maps a pixel to a time, `clampMs(ms)` keeps it between the oldest recording and now, `requestFrame(fn) -> id` and
 * `cancelFrame(id)` are requestAnimationFrame and cancelAnimationFrame (injected so tests can drive frames by hand).
 */
export function createScrubController({ session, timeForX, clampMs = (ms) => ms, requestFrame, cancelFrame, isEnabled = () => true, onStart = null, onEnd = null }) {
  let pointerId = null;
  let touch = false;
  let startX = 0;
  let scrubbing = false;
  let pendingX = null;
  let sentX = null;                  // the last pixel handed to the session, so a release where the pointer already was sends nothing twice
  let frame = null;
  let lastMs = null;
  let lastEdge = null;               // 'oldest' | 'now' when the last position had to be clamped

  function flush() {
    if (frame !== null) { cancelFrame(frame); frame = null; }
    if (pendingX === null || pendingX === sentX) { pendingX = null; return; }
    sentX = pendingX;
    const raw = timeForX(pendingX);
    lastMs = clampMs(raw);
    lastEdge = lastMs > raw ? 'oldest' : lastMs < raw ? 'now' : null;
    pendingX = null;
    session.scrub(lastMs);
  }

  function schedule() {
    if (frame !== null) return;
    frame = requestFrame(() => { frame = null; flush(); });
  }

  function begin(x) {
    scrubbing = true;
    sentX = null;
    session.beginScrub();
    onStart?.();
    pendingX = x;
    schedule();
  }

  function finish() {
    flush();
    if (scrubbing) {
      scrubbing = false;
      session.endScrub();
      onEnd?.({ ms: lastMs, edge: lastEdge });
    }
    pointerId = null;
    pendingX = null;
  }

  return {
    get active() { return pointerId !== null; },
    get scrubbing() { return scrubbing; },
    get lastMs() { return lastMs; },
    get lastEdge() { return lastEdge; },

    /** Returns true when this press is ours (the caller then captures the pointer). */
    down({ id, pointerType = 'mouse', x, button = 0 }) {
      if (!isEnabled() || pointerId !== null || button !== 0) return false;
      pointerId = id;
      touch = pointerType === 'touch';
      startX = x;
      if (!touch) begin(x);
      return true;
    },

    move({ id, x }) {
      if (id !== pointerId) return;
      if (!scrubbing) {
        if (Math.abs(x - startX) < TOUCH_SLOP_PX) return;
        begin(x);
        return;
      }
      pendingX = x;
      schedule();
    },

    up({ id, x }) {
      if (id !== pointerId) return;
      if (!scrubbing) begin(x);          // a tap is begin, scrub, end
      else pendingX = x;
      finish();
    },

    /** The browser took the pointer away (pointercancel) or the screen is going away: end where we are. */
    cancel() {
      if (pointerId === null) return;
      finish();
    },
  };
}
