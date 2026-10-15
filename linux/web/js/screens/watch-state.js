// The rules of the watch screen, without any DOM: which layer is on top, what the overlay says, and the words for times.
// watch.js feeds this the camera, the catalog, the session and the cell, and draws whatever it answers.

export const HEALTHY_EDGE_MS = 8000;
export const LONG_GOP_SECONDS = 4;
export const SNAPSHOT_CAPTION = 'Picture changes every few seconds';
export const RECORD_NUDGE = 'Turn on Record for smooth live video and a timeline';
export const OLDEST_CAPTION = 'This is the oldest recording';
export const EMPTY_TIMELINE_OFF = 'Nothing recorded yet. Turn on Record to build a timeline.';
export const EMPTY_TIMELINE_ON = 'Nothing recorded yet. The timeline appears after the first few seconds of footage.';
export const COARSE_CAPTION = 'Showing the nearest key picture. This camera sends key frames far apart, so the exact frame is not shown while scrubbing.';
export const UNSUPPORTED_SENTENCE = 'This browser can’t play these recordings. Safari, or Chrome on a Mac, can.';

/** Record is on, the recorder says it is recording, and the newest recorded part is less than 8 s old. */
export function recorderHealthy({ nvrEnabled, nvrState, extent, serverNowMs }) {
  return !!nvrEnabled && nvrState === 'recording' && !!extent && serverNowMs - extent.newest < HEALTHY_EDGE_MS;
}

/**
 * Whether the watch screen should ask the session to go live now. The session decodes nothing by itself (it is idle until the first scrub, play
 * or go live: the NVR grid opens paused on purpose), so a watch screen that only waits shows "Loading" for ever. It asks once, when the address
 * has no time, nobody has moved the playhead (the clock still reads live) and the recorder is healthy; before that, and whenever Record is off
 * or paused, the existing snapshot slideshow is the live picture and nothing is requested.
 */
export function shouldStartLive({ addressHasTime, started, mode, healthy }) {
  return !addressHasTime && !started && mode === 'live' && !!healthy;
}

/** The sentence under the picture when key frames are far apart, or null. */
export function gopCaption(typicalGOP) {
  if (!Number.isFinite(typicalGOP) || typicalGOP <= LONG_GOP_SECONDS) return null;
  return `Keyframes every ${Math.round(typicalGOP)} s: scrubbing is coarse. A 2 s interval scrubs best.`;
}

const action = (id, label, primary = false) => ({ id, label, primary });

/**
 * input: { mode: 'live' | 'paused' | 'playing', nvrEnabled, nvrState, extent: { oldest, newest, typicalGOP } | null, serverNowMs, positionMs,
 *          cell: { kind, next, message }, presented, catalogPhase: 'starting' | 'ready' | 'loading' | 'unavailable', playable, formatTime }
 * -> { layer: 'preview' | 'video', overlay, caption, nudge, loading, badge: { kind, text }, scrubbable }
 */
export function stageState(input) {
  const { mode, nvrEnabled, nvrState, extent, serverNowMs, positionMs, cell = { kind: 'idle' }, presented, catalogPhase, playable, formatTime } = input;
  const base = { layer: 'preview', overlay: null, caption: null, nudge: false, loading: false, badge: { kind: 'snapshot', text: 'Snapshot' }, scrubbable: false };

  if (!playable || cell.kind === 'unsupported') {
    return { ...base, overlay: { kind: 'unsupported', title: 'Can’t play recordings here', body: (playable && cell.message) || UNSUPPORTED_SENTENCE, actions: [] } };
  }
  if (catalogPhase === 'starting') return { ...base, loading: true, badge: { kind: 'none', text: '' } };
  if (catalogPhase === 'loading') {
    return { ...base, overlay: { kind: 'unavailable', title: 'Recordings are loading', body: 'This takes a moment after the bridge starts.', actions: [] } };
  }
  if (catalogPhase === 'unavailable') {
    return { ...base, overlay: { kind: 'unavailable', title: 'Recordings aren’t available', body: 'This bridge has no place to keep recordings.', actions: [] } };
  }
  if (!extent) {
    // The slideshow is all there is; the timeline itself says that nothing is recorded (EMPTY_TIMELINE_*).
    const why = nvrEnabled ? ' Waiting for the first footage.' : ` ${RECORD_NUDGE}.`;
    return { ...base, caption: `${SNAPSHOT_CAPTION}.${why}`, nudge: !nvrEnabled };
  }

  const scrubbable = true;
  if (mode === 'live') {
    if (recorderHealthy({ nvrEnabled, nvrState, extent, serverNowMs })) {
      return { ...base, layer: 'video', badge: { kind: 'live', text: 'Live' }, loading: !presented, scrubbable };
    }
    const why = !nvrEnabled ? ` ${RECORD_NUDGE}.` : nvrState === 'waiting' ? ' Waiting for the camera.' : nvrState === 'paused' ? ' Recording is paused.' : '';
    return { ...base, caption: `${SNAPSHOT_CAPTION}.${why}`, nudge: !nvrEnabled, scrubbable };
  }

  const state = { ...base, layer: presented ? 'video' : 'preview', badge: { kind: 'recorded', text: 'Recorded' }, scrubbable };
  switch (cell.kind) {
    case 'loading':
      return { ...state, loading: true };
    case 'coarse':
      return { ...state, caption: COARSE_CAPTION };
    case 'gap': {
      const next = Number.isFinite(cell.next) ? cell.next : null;
      return {
        ...state,
        overlay: {
          kind: 'gap',
          title: `No recording at ${formatTime(positionMs)}`,
          body: next === null ? 'Nothing was recorded after this.' : `Next recording at ${formatTime(next)}.`,
          actions: next === null ? [action('live', 'Go live', true)] : [action('jump', 'Jump to next recording', true)],
        },
      };
    }
    case 'driveMissing':
      return {
        ...state,
        overlay: { kind: 'drive', title: 'The recordings drive isn’t connected', body: 'The picture stays as it was. Footage comes back as soon as the drive does.', actions: [action('live', 'Go live')] },
      };
    case 'unreadable':
      return {
        ...state,
        overlay: { kind: 'unreadable', title: 'Can’t read this part of the recording', body: 'The rest of the recording plays normally.', actions: [action('retry', 'Try again', true), action('live', 'Go live')] },
      };
    default:
      return state;
  }
}

// MARK: Words for times

function formatterFor(kind, timeZone, locale) {
  const options = {
    time: { hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' },
    date: { weekday: 'short', day: 'numeric', month: 'short' },
    day: { year: 'numeric', month: '2-digit', day: '2-digit' },
    words: { dateStyle: 'full', timeStyle: 'medium' },
  }[kind];
  return new Intl.DateTimeFormat(kind === 'day' ? 'en-CA' : locale, { timeZone, ...options });
}

/** (ms, { withDate }) -> "14:32:10", or "Tue, Oct 13 14:32:10". `timeZone` is an IANA name; `locale` only changes the words. */
export function makeTimeFormatter({ timeZone, locale } = {}) {
  const time = formatterFor('time', timeZone, locale);
  const date = formatterFor('date', timeZone, locale);
  const day = formatterFor('day', timeZone, locale);
  const words = formatterFor('words', timeZone, locale);
  const format = (ms, { withDate = false } = {}) => (withDate ? `${date.format(ms)} ${time.format(ms)}` : time.format(ms));
  format.sameDay = (a, b) => day.format(a) === day.format(b);
  format.words = (ms) => words.format(ms);
  return format;
}

/** "6 s ago", "4 min ago", "3 h 12 min ago", "2 d 5 h ago". */
export function agoText(ms) {
  const seconds = Math.max(0, Math.round(ms / 1000));
  if (seconds < 1) return 'now';
  if (seconds < 60) return `${seconds} s ago`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return minutes % 60 ? `${hours} h ${minutes % 60} min ago` : `${hours} h ago`;
  const days = Math.floor(hours / 24);
  return hours % 24 ? `${days} d ${hours % 24} h ago` : `${days} d ago`;
}

/** The same in words for a screen reader: "3 hours 12 minutes ago". */
export function agoWords(ms) {
  const seconds = Math.max(0, Math.round(ms / 1000));
  const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;
  if (seconds < 1) return 'now';
  if (seconds < 60) return `${plural(seconds, 'second')} ago`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${plural(minutes, 'minute')} ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return minutes % 60 ? `${plural(hours, 'hour')} ${plural(minutes % 60, 'minute')} ago` : `${plural(hours, 'hour')} ago`;
  const days = Math.floor(hours / 24);
  return hours % 24 ? `${plural(days, 'day')} ${plural(hours % 24, 'hour')} ago` : `${plural(days, 'day')} ago`;
}

/** The time readout: { primary, secondary }. Live shows how far behind the picture is; the past shows how long ago. */
export function formatReadout({ mode, positionMs, serverNowMs, healthy, format }) {
  if (mode === 'live') {
    if (!healthy) return { primary: format(serverNowMs), secondary: 'Live' };
    return { primary: format(positionMs), secondary: `Live, ${Math.max(0, Math.round((serverNowMs - positionMs) / 1000))} s behind` };
  }
  return { primary: format(positionMs, { withDate: !format.sameDay(positionMs, serverNowMs) }), secondary: agoText(serverNowMs - positionMs) };
}

/** `aria-valuetext` of the position slider, in words. */
export function valueText({ mode, positionMs, serverNowMs, healthy, format }) {
  if (mode === 'live') return healthy ? `Live, ${Math.max(0, Math.round((serverNowMs - positionMs) / 1000))} seconds behind` : 'Live';
  return `${format.words(positionMs)}, ${agoWords(serverNowMs - positionMs)}`;
}
