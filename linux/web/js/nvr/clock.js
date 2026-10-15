// The shared playhead of the recordings pages. Every time here is epoch milliseconds in the server's time base.

/** How far behind the server's clock "live" plays: fragments are at most 2.5 s and the recorded edge lags by up to about 2.7 s. */
export const LIVE_BEHIND_MS = 6000;
/** A release within this long of the server's now, or after it, goes live. */
export const LIVE_SNAP_MS = 5000;

/** The real timers; tests pass a fake with the same three members. `now` is a monotonic millisecond reading. */
export const realTimers = {
  now: () => performance.now(),
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  clearTimeout: (id) => clearTimeout(id),
};

/**
 * One playhead for one to nine tiles. 'live' follows the server's now minus LIVE_BEHIND_MS, 'playing' runs from an anchor at the speed of the
 * monotonic clock, 'paused' stands still. A new clock is live.
 */
export class PlaybackClock {
  #serverNow;
  #perf;
  #mode = 'live';
  #anchor = 0;
  #since = 0;
  #listeners = new Set();

  constructor({ serverNow, perf = () => performance.now() }) {
    this.#serverNow = serverNow;
    this.#perf = perf;
  }

  get mode() { return this.#mode; }

  position() {
    if (this.#mode === 'live') return this.#serverNow() - LIVE_BEHIND_MS;
    if (this.#mode === 'playing') return this.#anchor + Math.max(0, this.#perf() - this.#since);
    return this.#anchor;
  }

  /** Stand still at `ms`. */
  scrub(ms) { this.#set('paused', ms, 0); }

  /** Run from `fromMs`; with `startingInMs` the position holds still for that long first (so tiles can get ready). */
  play(fromMs, { startingInMs = 0 } = {}) { this.#set('playing', fromMs, this.#perf() + Math.max(0, startingInMs)); }

  /** Stand still where the playhead is now. */
  pause() { this.#set('paused', this.position(), 0); }

  goLive() { this.#set('live', 0, 0); }

  /** True when `ms` is within LIVE_SNAP_MS of the server's now, or later. */
  shouldGoLive(ms) { return ms >= this.#serverNow() - LIVE_SNAP_MS; }

  /** fn(mode) runs when the mode changes. Returns the unsubscribe function. */
  onChange(fn) {
    this.#listeners.add(fn);
    return () => this.#listeners.delete(fn);
  }

  #set(mode, anchor, since) {
    const changed = mode !== this.#mode;
    this.#mode = mode;
    this.#anchor = anchor;
    this.#since = since;
    if (changed) for (const fn of [...this.#listeners]) fn(mode);
  }
}
