// What happens at the cameras, for the monitor wall: a notice on top of the wall, a line in the events list, the tile marked (through
// `onAlert`) and, if switched on, a sound. Events come from the cameras themselves through the page's event stream: motion, doorbell rings
// and the camera's own words for its latest event (person, vehicle, …). The list is kept while the page is loaded, so leaving the wall and
// coming back keeps it.
import { h, replace } from '../dom.js';
import { icon } from '../icons.js';
import { stampText } from '../stamp.js';
import { cameraList, store, subscribe } from '../store.js';

const BANNER_MS = 9_000;
const HISTORY_MAX = 200;
const MOTIONISH = /motion/i;

const history = [];   // newest first: { at, id, name, text, level: 'motion' | 'detection' | 'doorbell' }

/** The events seen so far (newest first). */
export function wallHistory() {
  return history;
}

/**
 * The events machinery of one wall: `{ soundButton, banners, list, destroy }`. `onAlert(id, text, level)` marks the camera's tile; the wall
 * clears the mark itself.
 */
export function createWallEvents({ onAlert = () => {} } = {}) {
  let destroyed = false;
  let soundOn = false;          // off after every page load: a browser lets sound play only after a click
  let audio = null;
  const seenEvent = new Map();  // camera id -> the date of the latest event already known

  const soundButton = h('button', { class: 'btn small', type: 'button', onclick: () => setSound(!soundOn) });
  const banners = h('div', { class: 'mon-banners', role: 'status', 'aria-live': 'polite' });
  const list = h('ol', { class: 'mon-list', 'aria-label': 'Events' });
  const emptyList = h('li', { class: 'mon-empty' }, 'Nothing has happened yet. Motion, detections and doorbell rings appear here.');

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

  function drawList() {
    const items = history.slice(0, 60).map((e) => h('li', { class: 'mon-item', dataset: { level: e.level } },
      h('time', null, stampText(e.at)), h('a', { href: `#/camera/${e.id}` }, e.name), h('span', null, e.text)));
    replace(list, items.length ? items : emptyList);
  }

  /** Something happened at camera `id`. The same words twice within 4 s are one event. */
  function notify(id, text, level) {
    const camera = store.cameras.get(id);
    if (!camera) return;
    const now = Date.now();
    if (history.some((e) => e.id === id && e.text === text && now - e.at < 4000)) return;
    const entry = { at: now, id, name: camera.name, text, level };
    history.unshift(entry);
    if (history.length > HISTORY_MAX) history.length = HISTORY_MAX;
    onAlert(id, text, level);
    showBanner(entry);
    beep(level);
    drawList();
  }

  // What each camera last did before the page opened: the list starts with something to show, and only later changes are news.
  for (const camera of cameraList()) {
    const date = camera.status?.lastEventDate;
    if (!date) continue;
    seenEvent.set(camera.id, date);
    const at = Date.parse(date);
    if (Number.isFinite(at) && camera.status.lastEvent && !history.some((e) => e.id === camera.id && e.at === at)) {
      history.push({ at, id: camera.id, name: camera.name, text: camera.status.lastEvent, level: /doorbell/i.test(camera.status.lastEvent) ? 'doorbell' : 'motion' });
    }
  }
  history.sort((a, b) => b.at - a.at);

  const stop = subscribe((kind, detail) => {
    if (destroyed || !detail) return;
    if (kind === 'motion' && detail.active) notify(detail.id, 'Motion', 'motion');
    else if (kind === 'doorbell') notify(detail.id, 'Doorbell ring', 'doorbell');
    else if (kind === 'camera') {
      const date = detail.status?.lastEventDate;
      const text = detail.status?.lastEvent;
      if (date && date !== seenEvent.get(detail.id)) {
        const first = !seenEvent.has(detail.id);
        seenEvent.set(detail.id, date);
        if (!first && text && !MOTIONISH.test(text) && !/doorbell/i.test(text)) notify(detail.id, text, 'detection');
      }
    }
  });

  showSound();
  drawList();

  return {
    soundButton, banners, list,
    destroy() {
      destroyed = true;
      stop();
      try { audio?.close?.(); } catch { /* already closed */ }
    },
  };
}
