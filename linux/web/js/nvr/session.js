// The shared playhead for one to nine tiles: turns what a person does (drag, release, play, go live) into desires for the cells.
//
// `scrub(ms)` is O(1): it stores a target in every cell's mailbox and arms two timers. It does no request and awaits nothing, because it
// runs on every pointer event. A cell works out the rest. Each dispatch to the cells has a new epoch, so a cell can tell the newest
// desire from an old one, and so can this file when a cell reports back.
import { realTimers } from './clock.js';
import { choosePolicy, currentEnvironment } from './planner.js';

const MAX_TILES = 16;
const STOPPED = new Set(['gap', 'unreadable', 'driveMissing', 'unsupported']);
const SHOWING = new Set(['recorded', 'live', 'coarse', 'loading']);

export function createSession({
  catalog, clock, createCell, tileCap = 4, settleMs = 80, idleMs = 500, startWaitMs = 1500, timers = realTimers,
  policy = choosePolicy(currentEnvironment()),
}) {
  const cap = Math.max(1, Math.min(tileCap, policy.maxTiles, MAX_TILES));
  const cells = new Map();                 // camera id -> { cell, off }
  const listeners = new Set();
  let order = [];
  let epoch = 0;
  let lastDispatch = 0;
  let activated = false;                   // nothing decodes until the first scrub, play or go live
  let scrubbing = false;
  let target = 0;
  let focusId = null;
  let settleTimer = null;
  let idleTimer = null;
  let startTimer = null;
  let waiting = null;                      // { epoch, targetMs }: the clock starts when the main tile shows its first playing frame
  let driveHold = null;                    // { position }: the clock stands still because a tile lost the recordings drive; it plays on when the drive is back
  let suspended = null;                    // { mode, position } while the page is hidden
  let destroyed = false;

  let reportedMode = clock.mode;
  const stopClockEvents = clock.onChange(() => announceMode());

  function emit(event) {
    for (const fn of [...listeners]) {
      try { fn(event); } catch (error) { console.error(error); }
    }
  }

  /** The mode the page shows: while the clock waits for the main tile's first playing frame, the person has already asked to play. */
  const effectiveMode = () => (waiting ? 'playing' : clock.mode);

  function announceMode() {
    const mode = effectiveMode();
    if (mode === reportedMode) return;
    reportedMode = mode;
    emit({ kind: 'mode', mode });
  }

  const primaryId = () => (focusId !== null && cells.has(focusId) ? focusId : order[0] ?? null);

  /** A target no later than the server's now. Before the oldest recording is each cell's business (it says so); only the clock is clamped. */
  function clampUpper(ms) { return Math.min(ms, catalog.serverNow()); }

  function clockTime(ms) {
    let oldest = Infinity;
    for (const id of order) {
      const extent = catalog.extent(id);
      if (extent) oldest = Math.min(oldest, extent.oldest);
    }
    return Number.isFinite(oldest) && ms < oldest ? oldest : ms;
  }

  /** One desire for every cell (or the ones in `only`), all with one new epoch. Returns the epoch. */
  function dispatch(precision, playing, targetMs, only = null) {
    epoch += 1;
    if (!only) lastDispatch = epoch;
    for (const [id, entry] of cells) {
      if (only && !only.includes(id)) continue;
      entry.cell.request({ targetMs, precision, playing, epoch, priority: id === primaryId() ? 1 : 0 });
    }
    return epoch;
  }

  function clearTimers() {
    timers.clearTimeout(settleTimer);
    timers.clearTimeout(idleTimer);
    settleTimer = null;
    idleTimer = null;
  }

  function clearWait({ announce = true } = {}) {
    timers.clearTimeout(startTimer);
    startTimer = null;
    waiting = null;
    driveHold = null;                      // whatever a person (or the start of a play) does ends a drive hold
    if (announce) announceMode();
  }

  // MARK: Starting to play

  /** Pause at `ms`, ask every cell for the exact frame and to play, and start the clock when the main tile shows its first playing frame. */
  function startPlaying(ms) {
    clearWait({ announce: false });
    target = ms;
    waiting = { epoch: -1, targetMs: ms };            // from here the page shows "playing", although the clock stands still for a moment
    clock.scrub(clockTime(ms));
    waiting.epoch = dispatch('exact', true, ms);
    const forEpoch = waiting.epoch;
    startTimer = timers.setTimeout(() => startClock(forEpoch), startWaitMs);
    announceMode();
    emit({ kind: 'position' });
  }

  function startClock(forEpoch) {
    if (!waiting || waiting.epoch !== forEpoch) return;
    const from = clockTime(waiting.targetMs);
    timers.clearTimeout(startTimer);
    startTimer = null;
    waiting = null;
    clock.play(from);                       // announces the mode if it changed
  }

  function goLiveNow() {
    clearWait({ announce: false });
    clearTimers();
    scrubbing = false;
    clock.goLive();                           // announces the mode if it changed
    announceMode();
    target = clock.position();
    dispatch('exact', false, target);         // live shows snapshots (nvr-model.js describeTile): the players stop, nothing decodes
    emit({ kind: 'position' });
  }

  // MARK: What the cells tell us

  function onCell(id, coverage) {
    emit({ kind: 'coverage', id, coverage });
    if (destroyed || suspended) return;
    if (waiting && coverage.epoch === waiting.epoch && id === primaryId()) {
      if (coverage.playing) startClock(waiting.epoch);
      else if (coverage.kind === 'coarse' && Number.isFinite(coverage.snapMs)) startPlaying(coverage.snapMs);
      else if (STOPPED.has(coverage.kind)) clearWait();
    }
    if (coverage.kind === 'driveMissing') holdForDrive();
    else if (driveHold && !anyDriveMissing()) resumeAfterDrive();
    if (coverage.kind === 'gap') jumpOverGap();
  }

  // MARK: The recordings drive

  const anyDriveMissing = () => [...cells.values()].some((entry) => entry.cell.coverage.kind === 'driveMissing');

  /**
   * A tile lost the recordings drive while the clock plays: the clock stands still at the playhead (a playing clock over tiles that cannot
   * fetch would run away from every picture), the tiles that still have video hold a paused frame at the playhead, and the tile that lost
   * the drive probes for it by itself (cell.js). When no tile is `driveMissing` any more, playing starts again from the same place.
   */
  function holdForDrive() {
    if (driveHold || clock.mode !== 'playing') return;
    const position = clock.position();
    clearWait({ announce: false });
    clock.pause();                          // announces the mode if it changed
    announceMode();
    driveHold = { position };
    target = position;
    dispatch('exact', false, position, order.filter((id) => cells.get(id)?.cell.coverage.kind !== 'driveMissing'));
    emit({ kind: 'position' });
  }

  function resumeAfterDrive() {
    const from = driveHold.position;
    driveHold = null;
    startPlaying(from);
  }

  /** Playing into a place nobody has a recording for: go to the next recording of any camera, or live when there is none. */
  function jumpOverGap() {
    if (scrubbing || clock.mode === 'live' || (clock.mode !== 'playing' && !waiting)) return;
    const states = [...cells.values()].map((entry) => entry.cell.coverage).filter((coverage) => coverage.kind !== 'idle');
    if (states.some((coverage) => coverage.epoch < lastDispatch || SHOWING.has(coverage.kind))) return;       // someone still has video or is working
    const gaps = states.filter((coverage) => coverage.kind === 'gap');
    if (!gaps.length) return;
    const nexts = gaps.map((coverage) => coverage.next).filter((next) => Number.isFinite(next));
    if (nexts.length) startPlaying(Math.min(...nexts));
    else goLiveNow();
  }

  // MARK: The API

  const session = {
    /** Shows these cameras (at most `tileCap`, at most the browser's limit). Cells that leave are destroyed. */
    setCameras(ids) {
      if (destroyed) return;
      const wanted = [...new Set(ids)].slice(0, cap);
      for (const [id, entry] of [...cells]) {
        if (wanted.includes(id)) continue;
        entry.off();
        entry.cell.destroy();
        cells.delete(id);
      }
      order = wanted;
      for (const id of wanted) {
        if (cells.has(id)) continue;
        const cell = createCell(id);
        cells.set(id, { cell, off: cell.onChange((coverage) => onCell(id, coverage)) });
        if (activated && !suspended) {
          // Joins where the others are: at the playhead, or at the target they are all about to start playing from.
          const joining = waiting ?? { epoch: (epoch += 1), targetMs: clock.position() };
          cell.request({ targetMs: joining.targetMs, precision: 'exact', playing: waiting !== null || clock.mode !== 'paused', epoch: joining.epoch, priority: 0 });
        }
      }
      emit({ kind: 'cameras', ids: [...order] });
    },
    get cameras() { return [...order]; },
    cell: (id) => cells.get(id)?.cell,

    beginScrub() {
      if (destroyed || suspended) return;
      activated = true;
      scrubbing = true;
      clearWait();
      clearTimers();
      target = clock.position();
      clock.scrub(target);
    },

    /** O(1): the playhead moves, every cell gets the new target, and the settle timers restart. */
    scrub(ms) {
      if (destroyed || suspended) return;
      activated = true;
      scrubbing = true;
      driveHold = null;
      target = clampUpper(ms);
      clock.scrub(clockTime(target));
      if (policy.keySteps) dispatch('key', false, target);
      timers.clearTimeout(settleTimer);
      timers.clearTimeout(idleTimer);
      settleTimer = timers.setTimeout(() => {
        settleTimer = null;
        const id = primaryId();
        if (scrubbing && id !== null) dispatch('exact', false, target, [id]);
      }, settleMs);
      idleTimer = timers.setTimeout(() => {
        idleTimer = null;
        if (scrubbing) dispatch('exact', false, target, order.filter((id) => id !== primaryId()));
      }, idleMs);
    },

    /** Release: play from the target (live when it is within five seconds of now or later). */
    endScrub() {
      if (destroyed || suspended || !scrubbing) return;
      scrubbing = false;
      clearTimers();
      if (clock.shouldGoLive(target)) goLiveNow();
      else startPlaying(target);
    },

    play(fromMs) {
      if (destroyed || suspended) return;
      activated = true;
      if (Number.isFinite(fromMs)) {
        scrubbing = false;
        clearTimers();
        const ms = clampUpper(fromMs);
        if (clock.shouldGoLive(ms)) goLiveNow();
        else startPlaying(ms);
      } else if (effectiveMode() === 'paused') {
        startPlaying(clock.position());
      }
    },

    pause() {
      if (destroyed || suspended) return;
      driveHold = null;                       // a person who pauses during a drive hold does not want it to play on
      if (effectiveMode() === 'paused') return;
      clearWait({ announce: false });
      clock.pause();                          // announces the mode if it changed
      announceMode();
      target = clock.position();
      dispatch('exact', false, target);
      emit({ kind: 'position' });
    },

    togglePlay() {
      if (effectiveMode() === 'paused') session.play();
      else session.pause();
    },

    goLive() {
      if (destroyed || suspended) return;
      activated = true;
      goLiveNow();
    },

    /** Jump by `deltaMs` and keep playing if it was playing. */
    seek(deltaMs) {
      if (destroyed || suspended) return;
      activated = true;
      const playing = effectiveMode() !== 'paused';
      const ms = clampUpper(clock.position() + deltaMs);
      scrubbing = false;
      clearTimers();
      if (clock.mode === 'live' && deltaMs >= 0) {
        goLiveNow();                          // seeking forward (or by nothing) from live stays live
      } else if (!playing) {
        clearWait();
        target = ms;
        clock.scrub(clockTime(ms));
        dispatch('exact', false, ms);
        emit({ kind: 'position' });
      } else if (clock.shouldGoLive(ms)) {
        goLiveNow();
      } else {
        startPlaying(ms);
      }
    },

    /** The tile under the pointer: its pictures are asked for first. */
    focus(id) { focusId = id; },

    /** The page is hidden: stop everything, remember where we were. */
    suspend() {
      if (destroyed || suspended) return;
      suspended = { mode: effectiveMode(), position: clock.position() };
      clearWait({ announce: false });
      clearTimers();
      scrubbing = false;
      if (clock.mode !== 'paused') clock.pause();
      announceMode();
      for (const entry of cells.values()) entry.cell.suspend();
    },

    resume() {
      if (destroyed || !suspended) return;
      const before = suspended;
      suspended = null;
      for (const entry of cells.values()) entry.cell.resume();
      if (!activated) return;
      if (before.mode === 'live') goLiveNow();
      else if (before.mode === 'playing') startPlaying(before.position);
      else { target = before.position; clock.scrub(clockTime(target)); dispatch('exact', false, target); }
    },

    destroy() {
      if (destroyed) return;
      destroyed = true;
      clearTimers();
      clearWait();
      stopClockEvents();
      for (const entry of cells.values()) { entry.off(); entry.cell.destroy(); }
      cells.clear();
      order = [];
      listeners.clear();
    },

    get position() { return clock.position(); },
    get mode() { return effectiveMode(); },
    /** fn({ kind: 'mode', mode } | { kind: 'position' } | { kind: 'cameras', ids } | { kind: 'coverage', id, coverage }); returns the unsubscribe function. */
    onChange(fn) {
      listeners.add(fn);
      return () => listeners.delete(fn);
    },
  };
  return session;
}

