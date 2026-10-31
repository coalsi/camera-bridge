// "Keep this": a stretch of a camera's recordings the person keeps from retention, with a note (docs/linux/ARCHITECTURE.md, "Kept
// recordings"). The bridge never deletes or moves the files a kept stretch touches, nor the camera's events of those days, until it is let go.
//   GET nvr/kept                          { kept: [{ id, cameraID, cameraName, from, to, note, created, bytes, hasVideo }] }, newest first
//   POST nvr/kept { cameraID, from, to, note? }  201 with the kept stretch; 400 (no range, over 24 h, nothing recorded) or 409 (200 kept, or a
//                                         quarter of the room for recordings) with the bridge's sentence
//   DELETE nvr/kept/:id                   204, or 404
// Kept from the clip bar (nvr/clip.js: the red range, for each camera on offer that recorded it), from an event (the Events page and the
// Monitor's events list: eventKeepRange), and listed in Settings › Recording (createKeptCard), each with Watch and Let go. The Monitor marks
// the kept stretches of its cameras under the timeline (nvr/timeline/view.js setKept). Times are the bridge's (store.js bridgeZone).
import { del, get, post } from '../api.js';
import { confirmDialog, h, promptDialog, replace, toast } from '../dom.js';
import { icon } from '../icons.js';
import { sizeText } from '../format.js';
import { bridgeZone } from '../store.js';
import { sameZonedDay, zonedFormat } from '../zone.js';

export const KEEP_BEFORE_MS = 30_000;            // an event is kept from 30 s before it began
export const KEEP_AFTER_MS = 120_000;            // to 2 minutes after it ended
export const KEEP_OPEN_MS = 5 * 60_000;          // or, while it is still going, to 5 minutes after it began
export const MAX_KEPT_MS = 24 * 3_600_000;       // the bridge keeps at most a day in one stretch
export const MAX_NOTE = 200;                     // and a note of at most 200 characters

export const KEEP_TEXT = {
  kept: 'Kept: retention won’t delete it',
  empty: 'Keep a stretch from the clip bar or an event so retention never deletes it.',
  title: 'Kept recordings',
  desc: 'Stretches you kept so the bridge never deletes them when it makes room. They still count toward the room for recordings: together they can take at most a quarter of it.',
  letGo: 'Let go',
  watch: 'Watch',
  noVideo: 'Its recording is gone (the drive was damaged or replaced).',
  noteLabel: 'Note (optional)',
};

/** The stretch "Keep this event" keeps: 30 s before it began to 2 min after it ended, or to 5 min after it began while it is still going; at most a day. */
export function eventKeepRange(event) {
  const from = Math.round(event.at - KEEP_BEFORE_MS);
  const end = Number.isFinite(event.endAt) && event.endAt >= event.at ? event.endAt + KEEP_AFTER_MS : event.at + KEEP_OPEN_MS;
  return { from, to: Math.round(Math.min(end, from + MAX_KEPT_MS)) };
}

/** "Sat 31 Oct, 2:14:05 PM to 2:19:30 PM" in `zone` (the bridge's), the end naming its day only when it is another. */
export function keptRangeText(from, to, zone = bridgeZone()) {
  const day = zonedFormat({ weekday: 'short', day: 'numeric', month: 'short' }, zone);
  const time = zonedFormat({ hour: 'numeric', minute: '2-digit', second: '2-digit' }, zone);
  const start = `${day.format(from)}, ${time.format(from)}`;
  return `${start} to ${sameZonedDay(from, to, zone) ? time.format(to) : `${day.format(to)}, ${time.format(to)}`}`;
}

/** The Monitor's address that plays `cameraID` from `from` (the one the Events page's rows use): the camera leads the wall and plays. */
export function watchKeptPath(item) {
  return `#/nvr/${Math.round(item.from)}?camera=${item.cameraID}&play=1`;
}

/** Keeps `from`..`to` of `cameraID` (POST nvr/kept) -> the kept stretch; rejects with the bridge's sentence. */
export function keepStretch({ cameraID, from, to, note = '' }, { send = (body) => post('nvr/kept', body) } = {}) {
  const text = String(note ?? '').trim().slice(0, MAX_NOTE);
  return send({ cameraID, from: Math.round(from), to: Math.round(to), ...(text ? { note: text } : {}) });
}

/**
 * Keeps the same stretch of each of `cameras` ([{ id, name }]), one request each, in turn -> { kept: [{ camera, item }], failed: [{ camera,
 * message }] }. One camera's refusal does not stop the others.
 */
export async function keepEach(cameras, { from, to, note = '' }, { send } = {}) {
  const kept = [];
  const failed = [];
  for (const camera of cameras) {
    try {
      kept.push({ camera, item: await keepStretch({ cameraID: camera.id, from, to, note }, { send }) });
    } catch (error) {
      failed.push({ camera, message: error?.message || 'It couldn’t be kept.' });
    }
  }
  return { kept, failed };
}

/** What the page says after keepEach: "Kept: retention won’t delete it (120 MB)." and each camera's refusal; `ok` when anything was kept. */
export function keptSentence({ kept, failed }, { many = kept.length + failed.length > 1 } = {}) {
  const size = kept.reduce((sum, { item }) => sum + (Number(item?.bytes) || 0), 0);
  const parts = [];
  if (kept.length) {
    const who = many ? ` for ${kept.map(({ camera }) => camera.name).join(', ')}` : '';
    parts.push(`${KEEP_TEXT.kept}${who}${size > 0 ? ` (${sizeText(size)})` : ''}.`);
  }
  for (const { camera, message } of failed) parts.push(many ? `${camera.name}: ${message}` : message);
  return { ok: kept.length > 0, text: parts.join(' ') };
}

/**
 * "Keep this event": asks for an optional note, then keeps the event's stretch of its camera (eventKeepRange); the bridge's refusal is said in
 * the dialog, which stays open. Says what was kept with its size. -> the kept stretch, or null when cancelled.
 */
export async function keepEvent(event, { send, ask = promptDialog, say = (text) => toast(text, 'ok'), zone = bridgeZone } = {}) {
  const { from, to } = eventKeepRange(event);
  let kept = null;
  const note = await ask({
    title: 'Keep this event?',
    body: `${event.label} at ${event.cameraName}: ${keptRangeText(from, to, zone())}. Retention won’t delete this recording until you let it go in Settings › Recording.`,
    label: KEEP_TEXT.noteLabel, confirm: 'Keep',
    submit: async (text) => { kept = await keepStretch({ cameraID: event.cameraId, from, to, note: text }, { send }); },
  });
  if (note === undefined || !kept) return null;
  say(keptSentence({ kept: [{ camera: { id: event.cameraId, name: event.cameraName }, item: kept }], failed: [] }).text);
  return kept;
}

/**
 * The "Kept recordings" card (Settings › Recording): each kept stretch with its camera, its range in the bridge's zone, its note and size,
 * Watch (the Monitor at that moment, that camera playing) and Let go (asked first). -> { el, refresh(), destroy() }
 *   load()        GET nvr/kept; forget(id) DELETE nvr/kept/:id; confirm({ title, body, confirm, danger }) asks
 */
export function createKeptCard({ load = () => get('nvr/kept'), forget = (id) => del(`nvr/kept/${encodeURIComponent(id)}`), confirm = confirmDialog,
  zone = bridgeZone } = {}) {
  const list = h('ul', { class: 'kept-list' });
  const status = h('p', { class: 'small muted', role: 'status' });
  const problem = h('p', { class: 'small kept-problem', role: 'alert', hidden: true });
  const el = h('section', { class: 'card kept-card', 'aria-labelledby': 'kept-heading' },
    h('h2', { id: 'kept-heading' }, KEEP_TEXT.title),
    h('p', { class: 'desc' }, KEEP_TEXT.desc),
    problem, list, status);
  let items = [];
  let loaded = false;      // the first answer came: before it the list says nothing (not "keep a stretch…")
  let destroyed = false;
  let sequence = 0;

  function say(text) {
    problem.textContent = text || '';
    problem.hidden = !text;
  }

  function row(item) {
    const meta = [item.cameraName, item.bytes > 0 ? sizeText(item.bytes) : null].filter(Boolean).join(' · ');
    return h('li', { class: 'kept-item', dataset: { id: item.id } },
      h('div', { class: 'kept-text' },
        h('strong', { class: 'kept-range' }, keptRangeText(item.from, item.to, zone())),
        h('span', { class: 'small muted kept-meta' }, meta),
        item.note ? h('span', { class: 'kept-note' }, item.note) : null,
        item.hasVideo === false ? h('span', { class: 'small kept-gone' }, KEEP_TEXT.noVideo) : null),
      h('div', { class: 'kept-actions' },
        item.hasVideo === false ? null : h('a', { class: 'btn small', href: watchKeptPath(item), 'aria-label': `${KEEP_TEXT.watch}: ${item.cameraName}, ${keptRangeText(item.from, item.to, zone())}` }, icon('play'), KEEP_TEXT.watch),
        h('button', { class: 'btn small', type: 'button', 'aria-label': `${KEEP_TEXT.letGo}: ${item.cameraName}, ${keptRangeText(item.from, item.to, zone())}`, onclick: () => letGo(item) }, KEEP_TEXT.letGo)));
  }

  function draw() {
    if (destroyed) return;
    replace(list, items.map(row));
    list.hidden = items.length === 0;
    status.textContent = !loaded ? '' : items.length === 0 ? KEEP_TEXT.empty : `${items.length} kept ${items.length === 1 ? 'stretch' : 'stretches'}.`;
  }

  async function refresh() {
    const mine = ++sequence;
    try {
      const answer = await load();
      if (destroyed || mine !== sequence) return;
      items = Array.isArray(answer?.kept) ? answer.kept : [];
      loaded = true;
      say('');
      draw();
    } catch (error) {
      if (destroyed || mine !== sequence) return;
      say(error?.message || 'The kept recordings can’t be read right now.');
      draw();
    }
  }

  async function letGo(item) {
    const sure = await confirm({
      title: 'Let go of this kept recording?',
      body: `${item.cameraName}, ${keptRangeText(item.from, item.to, zone())}. The recording stays until the bridge needs the room; then it is deleted like any other.`,
      confirm: KEEP_TEXT.letGo, danger: true,
    });
    if (!sure || destroyed) return;
    try {
      await forget(item.id);
    } catch (error) {
      if (error?.status !== 404) { say(error?.message || 'It couldn’t be let go.'); return; }   // 404: already gone
    }
    items = items.filter((other) => other.id !== item.id);
    say('');
    draw();
    refresh();
  }

  draw();
  refresh();
  return { el, refresh, destroy() { destroyed = true; } };
}
