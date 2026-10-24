// The shared playhead for one to nine tiles: turns what a person does (drag, release, play, go live) into desires for the cells.
//
// `scrub(ms)` is O(1): it stores a target in every cell's mailbox and arms two timers. It does no request and awaits nothing, because it
// runs on every pointer event. A cell works out the rest. Each dispatch to the cells has a new epoch, so a cell can tell the newest
// desire from an old one, and so can this file when a cell reports back.
import { realTimers } from './clock.js';
import { DEFAULT_FRAME_MS, frameStepTarget } from './frames.js';
import { LAPSE_STEP_MS, isTimelapse, nearestSpeed } from './speed.js';
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
  let holding = false;                     // the person paused: nothing but Play (or going live) plays again
  let scrubHolds = false;                  // the drag that is going on began while held: its release shows the picture there, paused
  let lapseTimer = null;                   // a time-lapse plays: the timer of its next key picture
  let lapseEpoch = 0;                      // the first epoch of the time-lapse playing now
  let destroyed = false;

  let reportedMode = clock.mode;
  const stopClockEvents = clock.onChange(() => announceMode());
  const stopRateEvents = clock.onRate?.((rate) => emit({ kind: 'rate', rate })) ?? (() => {});

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
  function dispatch(precision, playing, targetMs, only = null, extra = null) {
    epoch += 1;
    if (!only) lastDispatch = epoch;
    for (const [id, entry] of cells) {
      if (only && !only.includes(id)) continue;
      entry.cell.request({ targetMs, precision, playing, epoch, priority: id === primaryId() ? 1 : 0, ...extra });
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
    stopLapse();
    driveHold = null;                      // whatever a person (or the start of a play) does ends a drive hold
    if (announce) announceMode();
  }

  // MARK: Starting to play

  /**
   * Pause at `ms`, ask every cell for the exact frame and to play, and start the clock when the main tile shows its first playing frame. At a
   * time-lapse speed the clock runs at once and the cells show key pictures instead (startLapse).
   */
  function startPlaying(ms) {
    if (isTimelapse(clock.rate)) { startLapse(ms); return; }
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

  /** Stands still at `ms` and shows the exact picture there in every tile: what a held (paused) page does instead of playing. */
  function holdAt(ms) {
    clearWait({ announce: false });
    clock.scrub(clockTime(ms));
    announceMode();
    target = ms;
    dispatch('exact', false, ms);
    emit({ kind: 'position' });
  }

  // MARK: Time-lapse

  /**
   * A time-lapse (30× and faster, nvr/speed.js) is not played by the video elements: the clock runs at its speed from `ms`, and every
   * LAPSE_STEP_MS every cell is asked for the key picture at the clock (one keyframe request, behind the page's key picture budget: a cell
   * has one request in flight at most and the newest wish wins), so a fast speed never fetches every part. Gaps are jumped as when playing.
   */
  function startLapse(ms) {
    clearWait({ announce: false });
    target = ms;
    clock.play(clockTime(ms));
    announceMode();
    lapseEpoch = epoch + 1;
    lapseStep();
    emit({ kind: 'position' });
  }

  function stopLapse() {
    if (lapseTimer !== null) timers.clearTimeout(lapseTimer);
    lapseTimer = null;
  }

  function lapseStep() {
    lapseTimer = null;
    if (destroyed || suspended || clock.mode !== 'playing' || !isTimelapse(clock.rate)) return;
    const at = clock.position();
    if (clock.shouldGoLive(at)) { goLiveNow(); return; }
    if (lapseOverGap(at)) return;
    target = at;
    dispatch('key', false, at, null, { lapse: true });
    lapseTimer = timers.setTimeout(lapseStep, LAPSE_STEP_MS);
  }

  /** Every tile answered this time-lapse and none has a picture at the clock: on to the next recording of any camera, or live. */
  function lapseOverGap(at) {
    const states = [...cells.values()].map((entry) => entry.cell.coverage);
    if (!states.length || states.some((coverage) => coverage.epoch < lapseEpoch || !STOPPED.has(coverage.kind))) return false;
    if (!states.some((coverage) => coverage.kind === 'gap')) return false;
    const nexts = states.map((coverage) => coverage.next).filter((next) => Number.isFinite(next) && next > at);
    if (states.some((coverage) => coverage.kind === 'gap' && Number.isFinite(coverage.next) && coverage.next <= at)) return false;
    if (nexts.length) startLapse(Math.min(...nexts));
    else goLiveNow();
    return true;
  }

  function goLiveNow() {
    clearWait({ announce: false });
    clearTimers();
    scrubbing = false;
    holding = false;
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
    if (waiting && coverage.epoch === waiting.epoch) startOrCancel(id, coverage);
    if (coverage.kind === 'driveMissing') holdForDrive();
    else if (driveHold && !anyDriveMissing()) resumeAfterDrive();
    if (coverage.kind === 'gap') jumpOverGap();
  }

  /**
   * While the clock waits to start, the main tile leads: its first playing frame starts the clock, a coarse picture moves the start to its key,
   * and a stop cancels the start. A main tile with no recording at the start (a gap) hands the lead to the others: the first of them that plays
   * starts the clock, and the main tile joins it at its next recording (cell.js). Only when no tile can show anything is the start cancelled.
   */
  function startOrCancel(id, coverage) {
    const forEpoch = waiting.epoch;
    const isMain = id === primaryId();
    const main = cells.get(primaryId())?.cell.coverage;
    const mainAtGap = main?.epoch === forEpoch && main.kind === 'gap';
    if (!isMain && !mainAtGap) return;                                   // the main tile leads while it may have video
    if (coverage.playing) { startClock(forEpoch); return; }
    if (isMain && coverage.kind === 'coarse' && Number.isFinite(coverage.snapMs)) { startPlaying(coverage.snapMs); return; }
    if (!STOPPED.has(coverage.kind)) return;
    if (!mainAtGap) { clearWait(); return; }                            // unreadable, no drive, unsupported
    const others = [...cells].filter(([other]) => other !== primaryId()).map(([, entry]) => entry.cell.coverage);
    if (others.some((state) => state.epoch === forEpoch && state.playing)) startClock(forEpoch);
    else if (others.every((state) => state.epoch === forEpoch && STOPPED.has(state.kind))) clearWait();
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
    // Every cell counts, the idle ones too: a cell that has not answered the newest desire yet (still idle on the first play from live, when
    // a camera with nothing recorded there answers "gap" at once) may still have video, so nobody jumps before it has answered.
    const states = [...cells.values()].map((entry) => entry.cell.coverage);
    if (states.some((coverage) => coverage.epoch < lastDispatch || SHOWING.has(coverage.kind))) return;       // someone still has video or is working
    const gaps = states.filter((coverage) => coverage.kind === 'gap');
    if (!gaps.length) return;
    const nexts = gaps.map((coverage) => coverage.next).filter((next) => Number.isFinite(next));
    if (nexts.some((next) => next <= clock.position())) return;              // the clock is at that tile's next recording: it plays on by itself
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
        if (activated && !suspended && lapseTimer !== null) {
          cell.request({ targetMs: clock.position(), precision: 'key', playing: false, epoch: (epoch += 1), priority: 0, lapse: true });   // the next step asks again
        } else if (activated && !suspended) {
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
      scrubHolds = holding && effectiveMode() === 'paused';
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

    /**
     * Release: play from the target (live when it is within five seconds of now or later). While the person holds the page paused it stays
     * paused there, showing the exact picture.
     */
    endScrub() {
      if (destroyed || suspended || !scrubbing) return;
      scrubbing = false;
      clearTimers();
      if (clock.shouldGoLive(target)) goLiveNow();
      else if (scrubHolds && holding) holdAt(target);
      else startPlaying(target);
    },

    play(fromMs) {
      if (destroyed || suspended) return;
      activated = true;
      holding = false;
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
      holding = true;
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
      holding = false;
      goLiveNow();
    },

    /**
     * Goes to `ms` without changing whether it plays: playing (or live) it plays from there as play(ms) does; paused it stays paused and shows
     * the exact picture there. What an event of the list, a jump or a step does.
     */
    showAt(ms) {
      if (destroyed || suspended || !Number.isFinite(ms)) return;
      activated = true;
      if (effectiveMode() !== 'paused') { session.play(ms); return; }
      scrubbing = false;
      clearTimers();
      holdAt(clampUpper(ms));
    },

    /**
     * One picture forward (+1) or back (-1), paused: a step pauses first, and never plays. The picture's length is the recording's (the main
     * tile's cell read it from the fragments), and the step starts from the picture on screen when the browser said exactly which it was.
     */
    stepFrame(direction) {
      if (destroyed || suspended || clock.mode === 'live') return;
      activated = true;
      if (effectiveMode() !== 'paused') session.pause();
      holding = true;
      const cell = cells.get(primaryId())?.cell ?? null;
      const ms = frameStepTarget({ positionMs: clock.position(), shownMs: cell?.shownMs ?? null, frameMs: cell?.frameMs ?? DEFAULT_FRAME_MS, direction });
      scrubbing = false;
      clearTimers();
      holdAt(clampUpper(ms));
    },

    /** True while the person holds the page paused (Pause or a frame step): only Play, or going live, plays again. */
    get holding() { return holding && effectiveMode() === 'paused'; },

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
      stopRateEvents();
      for (const entry of cells.values()) { entry.off(); entry.cell.destroy(); }
      cells.clear();
      order = [];
      listeners.clear();
    },

    /** The playback speed (nvr/speed.js SPEEDS); live is always 1. */
    get rate() { return clock.rate ?? 1; },
    /**
     * Plays (or will play) at the step nearest to `rate`; every cell follows the clock's speed. Paused it stays paused (the speed applies on
     * Play). Playing into or out of a time-lapse starts again from the playhead the other way (stepped key pictures or played video).
     */
    setRate(rate) {
      if (destroyed) return;
      const next = nearestSpeed(rate);
      const wasLapse = isTimelapse(clock.rate ?? 1);
      clock.setRate?.(next);
      if (wasLapse === isTimelapse(clock.rate ?? 1) || suspended || clock.mode === 'live' || effectiveMode() !== 'playing') return;
      startPlaying(waiting ? waiting.targetMs : clock.position());
    },
    /** True while a time-lapse steps its key pictures. */
    get lapsing() { return lapseTimer !== null; },
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

