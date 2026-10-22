// The Events page (#/events): every camera's events, newest first, in groups by day, each with a snapshot taken at its start, the event's type and
// the AI's sentence, what it saw and how much it matters. No live video: snapshots only. A row opens the Monitor at that moment (events-model.js
// eventPath). Filters (cameras, type, what the AI saw, concern, described only, words, range) live in the address, so a reload or a shared link keeps
// them. The events come from the archive (GET nvr/events, wall-events-model.js createEventArchive) plus the bridge's recent events of every camera;
// while the page is open it asks again for the newest part, and new events wait behind a button when the person has scrolled down.
import { get } from '../api.js';
import { h, replace } from '../dom.js';
import { createThumbnails } from '../nvr/thumbs.js';
import { cameraList, subscribe } from '../store.js';
import {
  CONCERN_CHOICES, EVENT_RANGES, emptyFilters, eventKey, eventPath, filterEvents, filtersFromQuery, filtersToQuery, groupByDay, holdNewEvents,
  isDescribing, queryRange, typeChoices,
} from './events-model.js';
import { eventRow, kindWord } from './events-row.js';
import { AI_KINDS, createEventArchive, gatherEvents } from './wall-events-model.js';

const PAGE_ROWS = 60;
const REFRESH_MS = 10_000;                // "Describing…" ends and rows age on this beat
const HOLD_SCROLL_PX = 200;               // scrolled further down than this, new events wait behind a button
const SEARCH_WAIT_MS = 250;

/** GET nvr/events for the archive. */
function loadEvents({ cameras, fromMs, toMs, limit }) {
  const ids = cameras.slice(0, 16).map((cid) => encodeURIComponent(cid)).join(',');
  return get(`nvr/events?cameras=${ids}&from=${Math.floor(fromMs)}&to=${Math.ceil(toMs)}&limit=${limit}`);
}

/**
 * The page, without its wiring (tests pass fakes): `{ el, destroy, filters() }`.
 *   query         the address's query string (filters)
 *   load          the archive's loader; thumbs the snapshot tiles (nvr/thumbs.js createThumbnails)
 *   now()         this device's clock; writeAddress(query) puts the filters into the address without a page change
 *   cameras()     the camera resources (store.js cameraList()); onCameras(fn) calls fn when they change, returns the stop function
 *   scrolledDown() true when the person has read down the page
 */
export function createEventsPage({ query = '', load = loadEvents, thumbs = createThumbnails(), now = () => Date.now(), writeAddress = () => {},
  cameras = cameraList, onCameras = (fn) => subscribe((kind) => { if (kind === 'camera' || kind === 'removed') fn(); }),
  scrolledDown = () => (globalThis.window?.scrollY ?? 0) > HOLD_SCROLL_PX, setTimer = (fn, ms) => setTimeout(fn, ms), clearTimer = (t) => clearTimeout(t) } = {}) {
  let filters = filtersFromQuery(query);
  let destroyed = false;
  let loadFailure = null;
  let skewMs = 0;                   // the bridge's clock minus this device's, from the archive's own `serverTime`
  let shownRows = PAGE_ROWS;
  let known = new Set();            // keys of the events drawn at the last draw
  let holdOpen = false;             // the person asked to see the held events
  let searchTimer = null;
  const rows = new Map();           // event key -> { signature, item, thumb }

  const archive = createEventArchive({
    load: async (request) => {
      try {
        const answer = await load(request);
        loadFailure = null;
        if (Number.isFinite(answer?.serverTime) && answer.serverTime > 0) skewMs = answer.serverTime - now();
        return answer;
      } catch (error) {
        loadFailure = error;
        draw();
        throw error;
      }
    },
    now: () => now() + skewMs,
    onChange: () => draw(),
  });

  // MARK: Filters

  const update = (change) => { filters = { ...filters, ...change }; shownRows = PAGE_ROWS; holdOpen = false; changed(); };
  function changed() {
    const text = filtersToQuery(filters);
    writeAddress(text);
    syncControls();
    draw();
  }
  const toggle = (values, value) => (values.includes(value) ? values.filter((v) => v !== value) : [...values, value]);

  function chip(label, pressed, onclick, data = {}) {
    return h('button', { class: 'ev-filter', type: 'button', 'aria-pressed': String(pressed), dataset: data, onclick }, label);
  }

  const rangeSelect = h('select', { 'aria-label': 'Time range', onchange: (event) => update({ range: event.target.value }) },
    Object.entries(EVENT_RANGES).map(([value, label]) => h('option', { value }, label)));
  const concernSelect = h('select', { 'aria-label': 'How much it matters', onchange: (event) => update({ concern: event.target.value }) },
    Object.entries(CONCERN_CHOICES).map(([value, label]) => h('option', { value }, label)));
  const describedBox = h('input', { type: 'checkbox', onchange: (event) => update({ described: event.target.checked }) });
  const search = h('input', {
    type: 'search', placeholder: 'Search the descriptions', 'aria-label': 'Search the descriptions', maxlength: '100',
    oninput: (event) => {
      clearTimer(searchTimer);
      const value = event.target.value;
      searchTimer = setTimer(() => update({ q: value }), SEARCH_WAIT_MS);
    },
  });
  const camerasGroup = h('div', { class: 'ev-chips', role: 'group', 'aria-label': 'Cameras' });
  const typesGroup = h('div', { class: 'ev-chips', role: 'group', 'aria-label': 'Event type' });
  const sawGroup = h('div', { class: 'ev-chips', role: 'group', 'aria-label': 'What the AI saw' },
    AI_KINDS.filter((kind) => kind !== 'nothing').concat('nothing').map((kind) => chip(kindWord(kind), false, () => update({ saw: toggle(filters.saw, kind) }), { kind })));
  const clearButton = h('button', { class: 'btn small', type: 'button', onclick: () => { filters = emptyFilters(); search.value = ''; shownRows = PAGE_ROWS; changed(); } }, 'Clear filters');
  const bar = h('div', { class: 'ev-filters' },
    h('div', { class: 'ev-line' }, rangeSelect, concernSelect, h('label', { class: 'ev-check' }, describedBox, 'Described only'), search, clearButton),
    h('div', { class: 'ev-group' }, h('span', { class: 'ev-label' }, 'Camera'), camerasGroup),
    h('div', { class: 'ev-group' }, h('span', { class: 'ev-label' }, 'Type'), typesGroup),
    h('div', { class: 'ev-group' }, h('span', { class: 'ev-label' }, 'AI saw'), sawGroup));

  let optionsKey = '';
  function syncControls() {
    rangeSelect.value = filters.range;
    concernSelect.value = filters.concern;
    describedBox.checked = filters.described;
    if (search.value !== filters.q && !(globalThis.document?.activeElement === search)) search.value = filters.q;
    for (const button of sawGroup.children) button.setAttribute('aria-pressed', String(filters.saw.includes(button.dataset.kind)));
    for (const button of camerasGroup.children) button.setAttribute('aria-pressed', String(filters.cameras.includes(button.dataset.id)));
    for (const button of typesGroup.children) button.setAttribute('aria-pressed', String(filters.types.some((t) => t.toLowerCase() === button.dataset.type.toLowerCase())));
    clearButton.hidden = filtersToQuery(filters) === '';
  }

  /** The camera and type chips follow the cameras and the types seen. */
  function syncOptions(list, types) {
    const key = JSON.stringify([list.map((c) => [c.id, c.name]), types]);
    if (key === optionsKey) return;
    optionsKey = key;
    replace(camerasGroup, list.map((camera) => chip(camera.name, false, () => update({ cameras: toggle(filters.cameras, camera.id) }), { id: camera.id })));
    replace(typesGroup, types.map((type) => chip(type, false, () => update({ types: filters.types.some((t) => t.toLowerCase() === type.toLowerCase())
      ? filters.types.filter((t) => t.toLowerCase() !== type.toLowerCase()) : [...filters.types, type] }), { type })));
    syncControls();
  }

  // MARK: The list

  const heldButton = h('button', { class: 'btn small ev-held', type: 'button', hidden: true, onclick: () => { holdOpen = true; draw(); window.scrollTo?.(0, 0); } });
  const listHost = h('div', { class: 'ev-list' });
  let unseenRows = 0;               // matching events loaded but not drawn yet
  const moreButton = h('button', { class: 'btn', type: 'button', onclick: () => {
    shownRows += PAGE_ROWS;
    if (unseenRows <= 0) archive.loadOlder();       // every loaded row is drawn: the archive's next older page
    draw();
  } }, 'Load more');
  const status = h('p', { class: 'ev-count muted small', role: 'status' });
  const el = h('section', { class: 'ev-page', 'aria-labelledby': 'ev-title' },
    h('div', { class: 'page-head' }, h('h1', { id: 'ev-title' }, 'Events')),
    bar, status, heldButton, listHost, h('div', { class: 'ev-foot' }, moreButton));

  const signatureOf = (event, describing) => [event.endAt, event.recorded, event.cameraName, event.description?.text, event.description?.concern, event.description?.kind, describing].join('|');

  function draw() {
    if (destroyed) return;
    const at = now();
    const list = cameras();
    const byId = new Map(list.map((camera) => [camera.id, camera]));
    const { fromMs, toMs } = queryRange(filters, at);
    archive.want({ cameraIds: filters.cameras.length ? filters.cameras : list.map((camera) => camera.id), fromMs, toMs });
    const all = gatherEvents({ cameras: list, archived: archive.events() }).sort((a, b) => b.at - a.at || a.cameraName.localeCompare(b.cameraName) || a.label.localeCompare(b.label));
    syncOptions(list.filter((camera) => camera.isEnabled !== false), typeChoices(all));   // a camera that is turned off is no filter; its recordings' events stay listed
    const matching = filterEvents(all, filters, { now: at });
    const { shown, held } = holdNewEvents(matching, known, { hold: scrolledDown() && !holdOpen });
    holdOpen = false;                // asking to see the held events is once
    const drawn = shown.slice(0, shownRows);
    known = new Set(drawn.map(eventKey));

    // Rows that are still the same stay as they are (their picture, their focus); the others are made again.
    const active = document.activeElement;
    const focusedKey = [...rows].find(([, row]) => row.item.contains?.(active))?.[0] ?? null;
    const wanted = new Set(drawn.map(eventKey));
    for (const [key, row] of rows) if (!wanted.has(key)) { thumbs.release?.(row.thumb); rows.delete(key); }
    const items = new Map();
    for (const event of drawn) {
      const key = eventKey(event);
      const describing = isDescribing(event, byId.get(event.cameraId), at);
      const signature = signatureOf(event, describing);
      let row = rows.get(key);
      if (!row || row.signature !== signature) {
        const thumb = row ? row.thumb : thumbs.tile(event.cameraId, event.at);   // the picture stays when only the words changed
        row = { signature, event, thumb, item: eventRow(event, { thumb, href: eventPath(event), describing }) };
        rows.set(key, row);
      }
      items.set(key, row.item);
    }

    const groups = groupByDay(drawn, at);
    replace(listHost, groups.map((group) => h('section', { class: 'ev-day', 'aria-label': group.label },
      h('h2', null, group.label), h('ol', { class: 'ev-items' }, group.events.map((event) => items.get(eventKey(event)))))));
    if (focusedKey && rows.get(focusedKey)) rows.get(focusedKey).item.querySelector?.('a, button')?.focus({ preventScroll: true });

    heldButton.hidden = held.length === 0;
    if (held.length) heldButton.textContent = `${held.length} new ${held.length === 1 ? 'event' : 'events'}`;
    const more = matching.length > drawn.length || archive.hasOlder();
    moreButton.hidden = !more;
    unseenRows = matching.length - drawn.length;
    status.textContent = drawn.length ? `${matching.length}${archive.hasOlder() ? '+' : ''} ${matching.length === 1 ? 'event' : 'events'}` : '';
    if (!drawn.length) replace(listHost, emptyState(all.length, list.length));
  }

  function emptyState(total, cameraCount) {
    if (loadFailure && total === 0) {
      return h('div', { class: 'empty ev-empty' }, h('h2', null, 'No place for recordings yet'),
        h('p', null, 'Events are kept beside the recordings, and they aren’t available right now. Choose a place for recordings in Settings, or try again in a moment.'),
        h('a', { class: 'btn', href: '#/settings/recording' }, 'Recording settings'));
    }
    if (cameraCount === 0) {
      return h('div', { class: 'empty ev-empty' }, h('h2', null, 'No cameras yet'), h('p', null, 'Events appear here once a camera is added.'), h('a', { class: 'btn primary', href: '#/add' }, 'Add a camera'));
    }
    if (total > 0 || filtersToQuery(filters) !== '') {
      return h('div', { class: 'empty ev-empty' }, h('h2', null, 'No events match'), h('p', null, 'Nothing in this time range fits these filters. Widen the range or clear a filter.'));
    }
    return h('div', { class: 'empty ev-empty' }, h('h2', null, 'Nothing has happened yet'), h('p', null, 'Motion, people, vehicles and doorbell rings appear here, each with a picture.'));
  }

  const stopCameras = onCameras(() => draw());
  const beat = setInterval(() => draw(), REFRESH_MS);
  syncControls();
  draw();

  return {
    el,
    filters: () => filters,
    destroy() {
      destroyed = true;
      clearInterval(beat);
      clearTimer(searchTimer);
      stopCameras();
      archive.destroy();
      thumbs.destroy();
    },
  };
}

/** The route: #/events?<filters>. The address is read raw (a decoded `&` in a search would split it); writing it replaces the entry, so Back leaves the page. */
export function renderEvents({ setTitle } = {}) {
  setTitle?.('Events');
  const hash = location.hash;
  const page = createEventsPage({
    query: hash.includes('?') ? hash.slice(hash.indexOf('?') + 1) : '',
    writeAddress: (text) => { try { history.replaceState(history.state, '', `#/events${text ? `?${text}` : ''}`); } catch { /* the address stays as it is */ } },
  });
  return { el: page.el, destroy: () => page.destroy() };
}
