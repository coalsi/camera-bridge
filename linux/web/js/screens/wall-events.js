// What happens at the cameras, for the monitor wall: a notice on top of the wall, the tile marked (through `onAlert`), if switched on a sound,
// and the events list. Live events come from the cameras through the page's event stream: motion (start and end), doorbell rings and the
// camera's own words for its latest event (person, vehicle, …). The list adds the archive's events for the timeline's range (GET nvr/events,
// kept beside the recordings, so the whole recorded timeline and across restarts) and the bridge's recent events of every camera
// (status.recentEvents), and shows those the timeline shows, newest first; a click on one plays every camera of the wall from just before it
// (`onPick`). The rules are in wall-events-model.js. The live history is kept while the page is loaded, so leaving the wall and coming back keeps it.
import { h, replace, svg } from '../dom.js';
import { icon } from '../icons.js';
import { stampText } from '../stamp.js';
import { cameraList, store, subscribe } from '../store.js';
import { PAGE_ROWS, concernWord, createEventArchive, durationText, gatherEvents, isRecorded, sameEvent, visibleEvents } from './wall-events-model.js';

const BANNER_MS = 9_000;
const HISTORY_MAX = 200;
const MOTIONISH = /motion/i;

const history = [];   // newest first: { at, endAt, id, name, text, level: 'motion' | 'detection' | 'doorbell' } (at, endAt: server time)

/** The live events seen so far (newest first). */
export function wallHistory() {
  return history;
}

/** A small play mark for a row that can be played (inline: icons.js belongs to another part of the page). */
function playMark() {
  return svg('svg', { class: 'mon-event-play', viewBox: '0 0 12 12', width: 12, height: 12, 'aria-hidden': 'true', focusable: 'false' },
    svg('path', { d: 'M3 1.8v8.4L10 6z', fill: 'currentColor' }));
}

/**
 * The events machinery of one wall: `{ soundButton, banners, head, list, update(context), select(event), destroy }`.
 *   onAlert(id, text, level)  marks the camera's tile; the wall clears the mark itself
 *   onPick(event)             a row was chosen (click, Enter or Space): event is { at, endAt, cameraId, cameraName, label, level, recorded, description }
 *   onChange()                the events changed: the wall calls update() again
 *   now()                     the server's clock (live events are stamped with it, like the bridge's own)
 *   loadEvents(query)         GET nvr/events ({ cameras, fromMs, toMs, limit } -> its answer); without it the list has no archive
 * update({ cameraIds, range: { fromMs, toMs }, extentOf(id) }) draws the list for the cameras on the wall and the timeline's range.
 */
export function createWallEvents({ onAlert = () => {}, onPick = () => {}, onChange = () => {}, now = () => Date.now(), loadEvents = null } = {}) {
  let destroyed = false;
  const archive = loadEvents ? createEventArchive({ load: loadEvents, now, onChange: () => { if (!destroyed) { signature = ''; onChange(); } } }) : null;
  let soundOn = false;          // off after every page load: a browser lets sound play only after a click
  let audio = null;
  const seenEvent = new Map();  // camera id -> the date of the latest event already known
  const openMotion = new Map(); // camera id -> its history entry while the motion lasts
  let context = null;           // the last update()'s argument
  let selected = null;          // { cameraId, label, at } of the chosen row
  let shownRows = PAGE_ROWS;
  let signature = '';
  let rows = [];                // the events drawn, in order (the buttons' index)
  let focusRow = null;          // after "Show more": the index of the first new row, which the keyboard goes on from once it is drawn

  const soundButton = h('button', { class: 'btn small', type: 'button', onclick: () => setSound(!soundOn) });
  const banners = h('div', { class: 'mon-banners', role: 'status', 'aria-live': 'polite' });
  const count = h('span', { class: 'mon-event-count' });
  const head = h('div', { class: 'mon-timeline-head' }, h('strong', { id: 'mon-events-title' }, 'Events'), count);
  const list = h('ol', { class: 'mon-list', 'aria-labelledby': 'mon-events-title' });

  function showSound() {
    replace(soundButton, icon(soundOn ? 'bell' : 'bellOff'), soundOn ? 'Alert sound on' : 'Alert sound off');
    soundButton.title = 'A chime for motion, detections and doorbell rings (a camera’s own sound is the speaker on its picture)';
    soundButton.setAttribute('aria-pressed', String(soundOn));
  }

  function setSound(on) {
    soundOn = on;
    if (on) {
      try { audio ??= new (window.AudioContext || window.webkitAudioContext)(); audio.resume?.(); beep('motion'); } catch { soundOn = false; }
    }
    showSound();
  }

  function beep(level) {
    if (!soundOn || !audio) return;
    try {
      const notes = level === 'doorbell' ? [660, 880, 660] : [880, 880];
      notes.forEach((frequency, i) => {
        const start = audio.currentTime + i * 0.22;
        const osc = audio.createOscillator();
        const gain = audio.createGain();
        osc.frequency.value = frequency;
        gain.gain.setValueAtTime(0.0001, start);
        gain.gain.exponentialRampToValueAtTime(0.25, start + 0.02);
        gain.gain.exponentialRampToValueAtTime(0.0001, start + 0.18);
        osc.connect(gain).connect(audio.destination);
        osc.start(start);
        osc.stop(start + 0.2);
      });
    } catch { /* no sound: the notice still shows */ }
  }

  function showBanner(entry) {
    const item = h('a', { class: 'mon-banner', href: `#/camera/${entry.id}`, dataset: { level: entry.level } },
      h('strong', null, entry.name), h('span', null, entry.text), h('time', null, stampText(entry.at)));
    banners.prepend(item);
    while (banners.children.length > 3) banners.lastElementChild.remove();
    setTimeout(() => item.remove(), BANNER_MS);
  }

  // MARK: The list

  /** One row. An AI description is the model's words: on its own line under the kind, as text only, its mark from `data-concern` (monitor.css). */
  function rowFor(event, index, recorded) {
    const chosen = sameEvent(event, selected);
    const duration = durationText(event.endAt !== null ? event.endAt - event.at : null);
    const when = stampText(event.at);
    const described = event.description;
    const word = described ? concernWord(described.concern) : null;
    const said = described ? `, ${word ? `${word.toLowerCase()}: ` : ''}${described.text}` : '';
    const label = `${event.label}, ${event.cameraName}, ${when}${duration ? `, ${duration}` : ''}${recorded ? '' : ', not recorded'}${said}`;
    const button = h('button', {
      class: 'mon-event', type: 'button', 'aria-label': label, 'aria-current': chosen ? 'true' : null, 'aria-disabled': recorded ? null : 'true',
      title: recorded ? 'Play every camera from just before this' : 'Nothing was recorded at this moment',
      dataset: { level: event.level, index: String(index), selected: String(chosen), recorded: String(recorded) },
    },
    h('time', { datetime: new Date(event.at).toISOString() }, when),
    h('strong', { class: 'mon-event-camera' }, event.cameraName),
    h('span', { class: 'mon-event-kind' }, event.label),
    duration ? h('span', { class: 'mon-event-duration' }, duration) : null,
    described ? h('span', { class: 'mon-event-ai', title: word, dataset: { concern: described.concern } }, described.text) : null,
    recorded ? playMark() : h('span', { class: 'mon-event-note' }, 'Not recorded'));
    return h('li', { class: 'mon-item' }, button);
  }

  function draw({ fromMore = false } = {}) {
    if (destroyed || !context) return;
    const extentOf = context.extentOf ?? (() => null);
    archive?.want({ cameraIds: context.cameraIds ?? [], fromMs: context.range?.fromMs, toMs: context.range?.toMs });
    const all = gatherEvents({ cameras: cameraList(), live: history, archived: archive?.events() ?? [] });
    const visible = visibleEvents(all, { cameraIds: context.cameraIds ?? [], ...(context.range ?? {}) });
    const older = archive?.hasOlder() === true;
    const drawn = visible.slice(0, shownRows);
    const recorded = drawn.map((event) => isRecorded(event, extentOf(event.cameraId)));
    const key = [visible.length, shownRows, older, selected ? `${selected.cameraId}|${selected.label}|${selected.at}` : '',
      ...drawn.map((event, i) => `${event.cameraId}|${event.label}|${event.at}|${event.endAt}|${recorded[i]}|${event.cameraName}|${event.description?.concern}|${event.description?.text}`)].join('\n');
    if (key === signature) return;
    signature = key;

    // The row with the keyboard focus keeps it across a redraw, and so does "Show more" until the rows it asked for are there.
    const active = list.contains(document.activeElement) ? document.activeElement : null;
    const onMore = fromMore || active?.classList?.contains('mon-more') === true;
    if (!onMore) focusRow = null;   // the keyboard went elsewhere meanwhile
    const focusedIndex = active ? Number(active.dataset?.index) : NaN;
    const focusedEvent = Number.isInteger(focusedIndex) ? rows[focusedIndex] : null;

    rows = drawn;
    count.textContent = visible.length ? `${visible.length}${older ? '+' : ''}` : '';
    const items = drawn.map((event, i) => rowFor(event, i, recorded[i]));
    if (visible.length > drawn.length || older) {
      const more = Math.min(PAGE_ROWS, visible.length - drawn.length);
      items.push(h('li', { class: 'mon-item mon-item-more' },
        h('button', { class: 'btn small mon-more', type: 'button', onclick: () => {
          focusRow = drawn.length;
          shownRows += PAGE_ROWS;
          if (more <= 0) archive?.loadOlder();   // every loaded row is drawn: the archive's next older page
          draw({ fromMore: true });
        } }, more > 0 ? `Show ${more} more` : 'Show older events')));
    }
    const empty = all.length === 0
      ? 'Nothing has happened yet. Motion, detections and doorbell rings appear here.'
      : 'No events in this part of the timeline. Choose a longer range to see more.';
    replace(list, items.length ? items : h('li', { class: 'mon-empty' }, empty));

    if (focusRow !== null) {
      const row = list.querySelector(`button[data-index="${focusRow}"]`);
      if (row) {
        focusRow = null;
        row.focus({ preventScroll: false });   // the keyboard goes on from the first new row
      } else {
        // The older page is on its way: the keyboard stays on the button (on the last row if there is no button any more).
        (list.querySelector('button.mon-more') ?? list.querySelector(`button[data-index="${drawn.length - 1}"]`))?.focus({ preventScroll: true });
      }
    } else if (focusedEvent) {
      const index = drawn.findIndex((event) => sameEvent(event, focusedEvent));
      list.querySelector(`button[data-index="${index >= 0 ? index : Math.min(focusedIndex, drawn.length - 1)}"]`)?.focus({ preventScroll: true });
    }
  }

  list.addEventListener('click', (event) => {
    const button = event.target instanceof Element ? event.target.closest('button.mon-event') : null;
    if (!button || !list.contains(button)) return;
    const chosen = rows[Number(button.dataset.index)];
    if (!chosen || button.dataset.recorded !== 'true') return;
    selected = { cameraId: chosen.cameraId, label: chosen.label, at: chosen.at };
    signature = '';
    draw();
    onPick(chosen);
  });

  // MARK: Live events

  function changed() {
    if (destroyed) return;
    onChange();
  }

  /** Something happened at camera `id`. The same words twice within 4 s are one event. */
  function notify(id, text, level) {
    const camera = store.cameras.get(id);
    if (!camera) return null;
    const at = now();
    const repeat = history.find((e) => e.id === id && e.text === text && at - e.at < 4000);
    if (repeat) return repeat;
    const entry = { at, endAt: null, id, name: camera.name, text, level };
    history.unshift(entry);
    if (history.length > HISTORY_MAX) history.length = HISTORY_MAX;
    onAlert(id, text, level);
    showBanner(entry);
    beep(level);
    changed();
    return entry;
  }

  function motion(id, active) {
    if (active) {
      const entry = notify(id, 'Motion', 'motion');
      if (entry) {
        if (entry.endAt !== null && now() - entry.endAt < 4000) { entry.endAt = null; changed(); }   // it started again at once: one event
        openMotion.set(id, entry);
      }
      return;
    }
    const entry = openMotion.get(id);
    openMotion.delete(id);
    if (entry && entry.endAt === null) { entry.endAt = Math.max(entry.at, now()); changed(); }
  }

  // What each camera last did before the page opened: only later changes are news (the list reads status.recentEvents itself).
  for (const camera of cameraList()) {
    const date = camera.status?.lastEventDate;
    if (date) seenEvent.set(camera.id, date);
  }

  const stop = subscribe((kind, detail) => {
    if (destroyed) return;
    if (kind === 'removed') { changed(); return; }
    if (!detail) return;
    if (kind === 'motion') motion(detail.id, detail.active === true);
    else if (kind === 'doorbell') notify(detail.id, 'Doorbell ring', 'doorbell');
    else if (kind === 'camera') {
      const date = detail.status?.lastEventDate;
      const text = detail.status?.lastEvent;
      if (date && date !== seenEvent.get(detail.id)) {
        const first = !seenEvent.has(detail.id);
        seenEvent.set(detail.id, date);
        if (!first && text && !MOTIONISH.test(text) && !/doorbell/i.test(text)) notify(detail.id, text, 'detection');
      }
      changed();   // its recent events may have changed
    }
  });

  showSound();

  return {
    soundButton, banners, head, list,
    /** Draws the list for these cameras and this range; cheap when nothing changed. */
    update(next) {
      context = next;
      draw();
    },
    /** Marks `event` as the chosen one (null: none). */
    select(event) {
      selected = event ? { cameraId: event.cameraId, label: event.label, at: event.at } : null;
      signature = '';
      draw();
    },
    destroy() {
      destroyed = true;
      stop();
      archive?.destroy();
      try { audio?.close?.(); } catch { /* already closed */ }
    },
  };
}
