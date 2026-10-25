// The Sky Watcher page (#/sky): the morning sky log, in layout A. At the top the summary ("Last night: 1 unexplained, 214 explained"), the counts
// by kind and the sky's conditions; the night as a strip from sunset to sunrise with a dot for each light (the unexplained larger and glowing);
// the unexplained ones first, each with its still, the path drawn over it, its facts and its moment in the recordings; the explained ones
// below, collapsed by kind (a night has dozens of planes and hundreds of satellites: they are built when a group is opened, fifty at a time);
// a one-tap correction on every entry; past nights and days; a camera picker; and the aim and stream as status.
// Sky Watcher is a plugin: while it is off the page says so, with the way to Plugins; while it is on, a Setup panel (where the box is, the flight
// feed, the AI's limit: sky-setup.js) sits at the top, and with no camera watching the sky yet the page says where to turn it on.
// Nothing here claims a real size, distance or speed: a light's speed is only ever "faster across the sky than planes at that height".
import { get, post } from '../api.js';
import { h, replace, spinner, svg } from '../dom.js';
import { capitalize } from '../format.js';
import { icon } from '../icons.js';
import { cameraList, pluginOn, subscribe } from '../store.js';
import { inlineError } from './common.js';
import { createSkySetupPanel } from './sky-setup.js';
import {
  BUCKETS, CORRECTIONS, SKY_ROUTE, SKY_TEXT, aimLines, blinkText, clipAddress, conditionsText, correctionText, countEntries, countLabel, countsAfter, dayLabel,
  defaultLensLayout, directionText, durationText, entryBucket, groupExplained, learningText, normalizeEntry, pathPoints, shapeText, shiftDate, skyWatching, speedText,
  streamText, stripDots, stripTicks, summaryText, timeText, toMs, watchAddress,
} from './sky-model.js';

export { SKY_ROUTE };

const TEXT = SKY_TEXT.log;
const PAGE_ROWS = 50;           // rows of an explained group built at a time
const PAGE_CARDS = 20;          // cards of the unexplained built at a time
const NIGHT_NAME = /^\d{4}-\d{2}-\d{2}$/;

/** The strip's drawing: a box of this many units, scaled to the page's width. */
const STRIP = { width: 720, height: 150, padX: 10, padY: 14, dot: 3.2, unexplained: 7, halo: 15 };

const KIND_WORDS = { unexplained: 'Unexplained', plane: 'Plane', probablePlane: 'Probably a plane', satellite: 'Satellite', satelliteFlare: 'Satellite flare', meteor: 'Meteor', bug: 'Bug', bird: 'Bird' };
const OWN_LABEL = { plane: 'plane', bird: 'bird', bug: 'bug', satellite: 'satellite', meteor: 'meteor' };
const finite = (value) => (typeof value === 'number' && Number.isFinite(value) ? value : null);

// MARK: Requests

/** GET sky/cameras/:id/night?date=yyyy-MM-dd&view=night|day (no date: the latest night). */
function loadNight({ cameraID, night, view }) {
  return get(`sky/cameras/${encodeURIComponent(cameraID)}/night?${night ? `date=${encodeURIComponent(night)}&` : ''}view=${view}`);
}

/** POST sky/cameras/:id/entries/:eid/correction { night, label }: the entry as the bridge has it afterwards. */
function sendCorrection({ cameraID, entryID, night, label }) {
  return post(`sky/cameras/${encodeURIComponent(cameraID)}/entries/${encodeURIComponent(entryID)}/correction`, { night, label });
}

const browserZone = () => Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';

/** The bridge's time zone (its times are the box's clock), else this browser's. */
function loadZone() {
  return get('settings').then((settings) => (typeof settings?.timeZone === 'string' && settings.timeZone ? settings.timeZone : browserZone()), () => browserZone());
}

/** The bridge's sentence for a request that failed (an ApiError), else a plain one (never a script's own error text). */
function sentenceOf(error, fallback) {
  const message = error && typeof error === 'object' && 'status' in error && typeof error.message === 'string' ? error.message.trim() : '';
  return message || fallback;
}

/** The night as the page reads it, from what the bridge sent. */
function readNight(answer, asked) {
  if (!answer || typeof answer !== 'object') throw new TypeError('no log');
  const entries = (Array.isArray(answer.entries) ? answer.entries : []).map(normalizeEntry).filter(Boolean).sort((a, b) => a.start - b.start);
  let counts = countEntries(entries);
  if (answer.counts && typeof answer.counts === 'object') {
    counts = {};
    for (const key of [...BUCKETS, 'explained']) counts[key] = Number.isFinite(answer.counts[key]) && answer.counts[key] >= 0 ? answer.counts[key] : 0;
  }
  return {
    camera: typeof answer.camera === 'string' ? answer.camera : asked.cameraID,
    night: typeof answer.night === 'string' && NIGHT_NAME.test(answer.night) ? answer.night : asked.night,
    view: answer.view === 'day' ? 'day' : answer.view === 'night' ? 'night' : asked.view,
    from: toMs(answer.from),
    to: toMs(answer.to),
    serverTime: toMs(answer.serverTime),
    entries,
    conditions: (Array.isArray(answer.conditions) ? answer.conditions : [])
      .map((part) => ({ from: toMs(part?.from), to: toMs(part?.to), state: part?.state, cloudCover: finite(part?.cloudCover) }))
      .filter((part) => part.from !== null && part.to !== null && part.to > part.from),
    counts,
    aim: answer.aim && typeof answer.aim === 'object' ? answer.aim : null,
    learning: answer.learning && typeof answer.learning === 'object' ? answer.learning : null,
  };
}

/** The page's address parts: night=yyyy-MM-dd, view=night|day, entry=<id>. */
function readQuery(query) {
  const found = new URLSearchParams(typeof query === 'string' ? query : '');
  const night = found.get('night');
  return { night: night && shiftDate(night, 0) ? night : null, view: found.get('view') === 'day' ? 'day' : 'night', entry: found.get('entry') || null };
}

// MARK: The page

/**
 * The page, without its wiring (tests pass fakes). -> { el, destroy() }
 *   cameraID      the camera whose log is shown (none: the first that watches the sky)
 *   query         the address's query string (night, view, entry)
 *   load(request) GET the night for { cameraID, night (null: the latest), view }; correct({ cameraID, entryID, night, label }) POSTs a correction
 *   now()         this device's clock; the bridge's `serverTime` says how far off it is
 *   writeAddress(address)   puts 'sky/<camera>?night=…&view=…' into the address bar without a page change
 *   cameras()     the camera resources (store.js cameraList()); onCameras(fn) calls fn when they change and returns the stop function
 *   zone()        the bridge's time zone (or a promise of it): the page says the box's hours
 *   plugin()      whether the Sky Watcher plugin is on (store.js pluginOn): off, the page only says so; it is read once, when the page is made
 *   setup()       the Setup panel, { el, destroy() } (sky-setup.js), or null for none
 */
export function createSkyLogPage({ cameraID = null, query = '', load = loadNight, correct = sendCorrection, now = () => Date.now(), writeAddress = () => {},
  cameras = cameraList, onCameras = (fn) => subscribe((kind) => { if (kind === 'camera' || kind === 'removed') fn(); }), zone = loadZone,
  plugin = () => pluginOn('sky'), setup = () => createSkySetupPanel() } = {}) {
  const wanted = readQuery(query);
  const pluginIsOn = plugin() === true;
  let current = cameraID;        // the camera shown (null: not chosen yet)
  let night = wanted.night;      // the night asked for (null: the latest)
  let view = wanted.view;
  let target = wanted.entry;     // the entry the address names, until it has been shown
  let log = null;                // the night as read
  let phase = pluginIsOn ? 'loading' : 'off';   // 'loading' | 'ready' | 'failed' | 'none' (no camera watches) | 'removed' | 'off' (the plugin is off)
  let failure = '';
  let zoneName = '';
  let zoneAsk = null;
  let skew = 0;                  // the bridge's clock minus this device's
  let ticket = 0;                // the newest request: an older answer is not drawn
  let destroyed = false;
  let pickerKey = '';
  let noneKey = '';              // the cameras the empty state lists, so that it is drawn again only when they change
  let targetNode = null;         // the card or row the address names, once it is built
  let statusKey = '';            // what the status lines say now, so that they are drawn again only when that changes
  let noteOff = null;            // whether the note "Sky Watcher is off for this camera" is on the page
  let headings = null;           // { unexplained, explained }: the counts in the two section headings, which a correction moves
  const latest = { night: null, day: null };   // the name of the latest night (and day) the bridge answered with
  const opened = new Set();                    // the groups the person opened
  const refreshers = new Map();                // entry id -> [functions that draw its words again after a correction]
  const clock = () => now() + skew;

  // MARK: Pieces that stay

  const picker = h('select', { 'aria-label': TEXT.camera, onchange: () => switchCamera(picker.value) });
  const pickerBox = h('div', { class: 'sky-picker', hidden: true }, picker);
  const viewButton = (value, label) => h('button', { class: 'sky-segment', type: 'button', dataset: { view: value }, onclick: () => setView(value) }, label);
  const nightButton = viewButton('night', TEXT.night);
  const dayButton = viewButton('day', TEXT.day);
  const earlier = h('button', { class: 'btn small', type: 'button', onclick: () => step(-1) }, icon('back'), TEXT.earlier);
  const later = h('button', { class: 'btn small', type: 'button', onclick: () => step(1) }, TEXT.later, icon('chevron'));
  const when = h('span', { class: 'sky-when', role: 'status' });
  const toolbar = h('div', { class: 'sky-toolbar' },
    h('div', { class: 'sky-segments', role: 'group', 'aria-label': TEXT.night }, nightButton, dayButton),
    h('div', { class: 'sky-nav' }, earlier, when, later));
  const body = h('div', { class: 'sky-body' });
  const setupHost = h('div', { class: 'sky-setup-panel' });
  const el = h('section', { class: 'sky-page', 'aria-labelledby': 'sky-title' },
    h('div', { class: 'page-head' }, h('h1', { id: 'sky-title' }, SKY_TEXT.page), h('div', { class: 'actions' }, pickerBox)),
    setupHost, toolbar, body);

  // The parts of the log that change in place.
  let summaryEl = null;
  let countsEl = null;
  let stripBox = null;
  let statusBox = null;
  let noteBox = null;

  // MARK: Cameras

  const cameraById = (id) => (id ? cameras().find((camera) => String(camera.id).toLowerCase() === String(id).toLowerCase()) ?? null : null);
  const skyCameras = () => skyWatching(cameras());

  /** Picks the camera to show: the one named, else the first that watches the sky. Returns what the page can do about it. */
  function choose() {
    if (current) {
      const camera = cameraById(current);
      if (!camera) return 'removed';
      current = camera.id;
      return 'ready';
    }
    const first = skyCameras()[0];
    if (!first) return 'none';
    current = first.id;
    return 'ready';
  }

  const noneCamerasKey = () => cameras().map((camera) => `${camera.id}\n${camera.name}`).join('\n');

  function drawPicker() {
    const options = cameras().filter((camera) => camera.skyDetector?.enabled === true || camera.id === current);
    pickerBox.hidden = options.length < 2;
    const key = options.map((camera) => `${camera.id}\n${camera.name}`).join('\n');
    if (key !== pickerKey) {
      pickerKey = key;
      replace(picker, options.map((camera) => h('option', { value: camera.id }, camera.name)));
    }
    if (current) picker.value = current;
  }

  function switchCamera(id) {
    if (!id || id === current) return;
    current = id;
    night = null;
    latest.night = null;
    latest.day = null;
    log = null;
    fetchLog();
  }

  // MARK: Nights and days

  const isLatest = () => night === null || (log !== null && log.night === latest[view]);

  function addressFor() {
    const params = [];
    if (night !== null && night !== latest[view]) params.push(`night=${night}`);
    if (view === 'day') params.push('view=day');
    return `sky/${current}${params.length ? `?${params.join('&')}` : ''}`;
  }

  function canLater() {
    if (!log) return false;
    if (latest[view]) return log.night < latest[view];
    return log.to !== null && log.to < clock();
  }

  function step(days) {
    const base = night ?? log?.night;
    const next = base ? shiftDate(base, days) : null;
    if (!next || unavailable()) return;
    if (days > 0 && !canLater()) return;
    night = next;
    fetchLog();
  }

  function setView(next) {
    if (next === view || unavailable()) return;
    night = isLatest() ? null : night;
    view = next;
    fetchLog();
  }

  /** There is no log to flip through: the plugin is off, no camera watches the sky, or the camera in the address was removed. */
  const unavailable = () => phase === 'off' || phase === 'none' || phase === 'removed';

  function drawChrome() {
    drawPicker();
    nightButton.setAttribute('aria-pressed', String(view === 'night'));
    dayButton.setAttribute('aria-pressed', String(view === 'day'));
    const date = log?.night ?? night;
    when.textContent = date ? (view === 'night' ? `Night of ${dayLabel(date)}` : dayLabel(date)) : '';
    toolbar.hidden = unavailable();
    if (phase === 'off') pickerBox.hidden = true;
    if (canLater()) later.removeAttribute('aria-disabled');
    else later.setAttribute('aria-disabled', 'true');
    if (phase === 'loading' && !log) earlier.setAttribute('aria-disabled', 'true');
    else earlier.removeAttribute('aria-disabled');
  }

  // MARK: Loading

  async function fetchLog() {
    const state = choose();
    if (state !== 'ready') {
      phase = state;
      log = null;
      drawChrome();
      drawBody();
      return;
    }
    const mine = ++ticket;
    const asked = { cameraID: current, night, view };
    opened.clear();   // another night, another camera: the explained start closed again
    phase = 'loading';
    failure = '';
    try { writeAddress(addressFor()); } catch { /* the address stays as it is */ }
    drawChrome();
    drawBody();
    zoneAsk ??= Promise.resolve().then(zone).then((name) => { if (typeof name === 'string' && name) zoneName = name; }, () => {});
    try {
      const [answer] = await Promise.all([load(asked), zoneAsk]);
      if (destroyed || mine !== ticket) return;
      log = readNight(answer, asked);
      skew = log.serverTime !== null ? log.serverTime - now() : 0;
      if (asked.night === null) latest[log.view] = log.night;
      phase = 'ready';
    } catch (error) {
      if (destroyed || mine !== ticket) return;
      phase = 'failed';
      failure = sentenceOf(error, TEXT.failed);
    }
    drawChrome();
    drawBody();
  }

  // MARK: The words of the log

  /** The first words of the summary: nothing for the latest night ("Last night") or this day ("Today"); else the night or the day. */
  function lead() {
    if (!log) return null;
    const running = log.from !== null && log.to !== null && log.from <= clock() && clock() < log.to;
    if (log.view === 'night') {
      if (running) return TEXT.tonight;
      return isLatest() ? null : `Night of ${dayLabel(log.night)}`;
    }
    if (running && isLatest()) return null;
    return dayLabel(log.night) || null;
  }

  function drawSummary() {
    if (summaryEl && log) summaryEl.textContent = summaryText(log.counts, log.view, lead());
  }

  function drawCounts() {
    if (!countsEl || !log) return;
    const kinds = BUCKETS.filter((kind) => kind !== 'notSure' || log.counts.notSure > 0);
    replace(countsEl, kinds.map((kind) => h('li', { class: 'sky-count-item' },
      h('span', { class: `sky-key sky-key--${kind}`, 'aria-hidden': 'true' }), h('strong', null, String(log.counts[kind])), ` ${countLabel(kind, log.counts[kind])}`)));
  }

  function countsLabel() {
    return BUCKETS.filter((kind) => kind !== 'notSure' || log.counts.notSure > 0).map((kind) => `${log.counts[kind]} ${countLabel(kind, log.counts[kind])}`).join(', ');
  }

  // MARK: The strip

  function drawStrip() {
    if (!stripBox || !log) return;
    const { width, height, padX, padY } = STRIP;
    const dots = stripDots(log.entries, log.from ?? 0, log.to ?? 0);
    if (!dots.length && !(log.to > log.from)) return replace(stripBox);
    const px = (x) => padX + x * (width - 2 * padX);
    const py = (y) => padY + y * (height - 2 * padY);
    const chart = svg('svg', { class: 'sky-strip-svg', viewBox: `0 0 ${width} ${height}`, role: 'img', 'aria-label': `${log.view === 'day' ? 'Day' : 'Night'} strip: ${countsLabel()}`, focusable: 'false' });
    chart.append(svg('rect', { class: 'sky-sky', x: 0, y: 0, width, height, rx: 10 }));
    const span = log.to - log.from;
    for (const part of log.conditions) {
      if (part?.state !== 'cloudy' && part?.state !== 'notVisible') continue;
      const start = Math.min(1, Math.max(0, (part.from - log.from) / span));
      const end = Math.min(1, Math.max(0, (part.to - log.from) / span));
      if (end > start) chart.append(svg('rect', { class: `sky-band sky-band--${part.state}`, x: px(start), y: 0, width: px(end) - px(start), height }));
    }
    for (const elevation of [60, 30]) chart.append(svg('line', { class: 'sky-grid', x1: padX, x2: width - padX, y1: py(1 - elevation / 90), y2: py(1 - elevation / 90) }));
    chart.append(svg('line', { class: 'sky-horizon', x1: padX, x2: width - padX, y1: py(1), y2: py(1) }));
    const order = (dot) => BUCKETS.indexOf(dot.kind);
    for (const dot of [...dots].sort((a, b) => order(b) - order(a))) {   // the unexplained last, so nothing covers them
      if (dot.unexplained) chart.append(svg('circle', { class: 'sky-halo', cx: round(px(dot.x)), cy: round(py(dot.y)), r: STRIP.halo }));
      chart.append(svg('circle', { class: `sky-dot sky-dot--${dot.kind}`, cx: round(px(dot.x)), cy: round(py(dot.y)), r: dot.unexplained ? STRIP.unexplained : STRIP.dot }));
    }
    const ticks = stripTicks(log.from, log.to, zoneName).map((tick) => {
      const mark = h('span', { class: 'sky-tick' }, tick.label);
      mark.style.left = `${((px(tick.x) / width) * 100).toFixed(2)}%`;
      return mark;
    });
    replace(stripBox, chart, h('div', { class: 'sky-axis', 'aria-hidden': 'true' }, ticks),
      h('div', { class: 'sky-ends', 'aria-hidden': 'true' }, h('span', null, timeText(log.from, zoneName)), h('span', null, timeText(log.to, zoneName))));
  }

  // MARK: The still and the path

  const stillAddress = (entry) => `/api/v1/sky/cameras/${encodeURIComponent(current)}/entries/${encodeURIComponent(entry.id)}/still?night=${encodeURIComponent(log.night)}`;

  /** The still with the path over it. The overlay's coordinates are the picture's own, known once it has arrived: the still is the camera's original picture. */
  function stillBlock(entry) {
    if (!entry.hasStill) return h('div', { class: 'sky-still sky-still--none' }, h('span', { class: 'small muted' }, TEXT.noPicture));
    const img = h('img', { class: 'sky-still-img', src: stillAddress(entry), alt: `Still picture from ${timeText(entry.start, zoneName)}`, loading: 'lazy', decoding: 'async' });
    const overlay = svg('svg', { class: 'sky-path', 'aria-hidden': 'true', focusable: 'false', preserveAspectRatio: 'none' });
    const draw = () => {
      const width = img.naturalWidth;
      const height = img.naturalHeight;
      if (!(width > 0 && height > 0)) return;
      overlay.setAttribute('viewBox', `0 0 ${width} ${height}`);
      while (overlay.firstChild) overlay.removeChild(overlay.firstChild);
      const points = pathPoints(entry.path, width, height);
      const list = points ? points.split(' ').map((pair) => pair.split(',')) : [];
      const radius = round(Math.max(width, height) * 0.012);
      if (list.length >= 2) overlay.append(svg('polyline', { class: 'sky-path-line', points, fill: 'none' }));
      if (list.length >= 1) overlay.append(svg('circle', { class: list.length >= 2 ? 'sky-mark sky-mark--start' : 'sky-mark sky-mark--point', cx: list[0][0], cy: list[0][1], r: radius }));
      if (list.length >= 2) overlay.append(svg('circle', { class: 'sky-mark sky-mark--end', cx: list.at(-1)[0], cy: list.at(-1)[1], r: radius }));
    };
    img.addEventListener('load', draw);
    if (img.complete && img.naturalWidth > 0) draw();
    return h('figure', { class: 'sky-still' }, img, overlay);
  }

  // MARK: Corrections

  /** "That was a…" and its six buttons, under an entry. After a tap the words say what was said, in place. */
  function correctionBlock(entry) {
    const labelId = `sky-say-${entry.id}`;
    const said = h('p', { class: 'small sky-said', role: 'status', hidden: true });
    let busy = false;
    let problem = '';
    const buttons = CORRECTIONS.map(([value, word]) => h('button', {
      class: 'sky-chip', type: 'button', dataset: { label: value }, 'aria-pressed': 'false', onclick: () => tap(value),
    }, word));
    const block = h('div', { class: 'sky-correct' },
      h('span', { class: 'sky-correct-label', id: labelId }, TEXT.thatWasA),
      h('div', { class: 'sky-chips', role: 'group', 'aria-labelledby': labelId }, buttons), said);

    function refresh() {
      for (const button of buttons) {
        button.setAttribute('aria-pressed', String(entry.correction === button.dataset.label));
        if (busy) button.setAttribute('aria-disabled', 'true');
        else button.removeAttribute('aria-disabled');
      }
      const text = problem || (entry.correction ? correctionText(entry.correction) : '');
      said.textContent = text;
      said.hidden = !text;
      said.className = problem ? 'small sky-said bad' : 'small sky-said';
    }

    async function tap(value) {
      if (busy || destroyed) return;
      busy = true;
      problem = '';
      refresh();
      try {
        const answer = await correct({ cameraID: current, entryID: entry.id, night: log.night, label: value });
        if (destroyed) return;
        applyCorrection(entry, value, answer);
      } catch (error) {
        if (destroyed) return;
        problem = sentenceOf(error, TEXT.notSaved);
      }
      busy = false;
      refresh();
    }

    const list = refreshers.get(entry.id) ?? [];
    list.push(refresh);
    refreshers.set(entry.id, list);
    refresh();
    return block;
  }

  /** The bridge took a correction: the entry changes kind, and the counts, the summary and the strip follow it. Its card or row stays where it is. */
  function applyCorrection(entry, value, answer) {
    const before = { ...entry };
    const back = normalizeEntry(answer);
    const same = back && back.id === entry.id;
    entry.correction = same ? back.correction ?? value : value;
    entry.display = same ? back.display : OWN_LABEL[value] ?? entry.label;
    log.counts = countsAfter(log.counts, before, entry) ?? log.counts;
    const wasUnexplained = entryBucket(before) === 'unexplained';
    if (headings && wasUnexplained !== (entryBucket(entry) === 'unexplained')) {
      headings.unexplained.textContent = String(Number(headings.unexplained.textContent) + (wasUnexplained ? -1 : 1));
      if (headings.explained) headings.explained.textContent = String(Number(headings.explained.textContent) + (wasUnexplained ? 1 : -1));
    }
    drawSummary();
    drawCounts();
    drawStrip();
    for (const refresh of refreshers.get(entry.id) ?? []) refresh();
  }

  /** A tag that says what the entry is now (after a correction it is the person's word). */
  function labelTag(entry) {
    const tag = h('span', { class: 'sky-tag', hidden: true });
    const draw = () => {
      const word = KIND_WORDS[entry.display] ?? '';
      tag.textContent = entry.correction && entry.display !== 'unexplained' ? word : '';
      tag.hidden = !tag.textContent;
    };
    const list = refreshers.get(entry.id) ?? [];
    list.push(draw);
    refreshers.set(entry.id, list);
    draw();
    return tag;
  }

  // MARK: The unexplained

  /** The facts under a light: where, how long, how fast against planes, blinking, the shape of its path, and what makes it stand out. */
  function facts(entry) {
    const m = entry.measures;
    const track = entry.kind === 'track';
    const seconds = durationText(m.duration ?? (entry.end - entry.start) / 1000);
    return [
      capitalize(directionText(m.azimuth, m.elevation)),
      seconds ? `Lasted ${seconds}` : '',
      track ? capitalize(speedText(entry.speedVsPlanes)) : '',
      blinkText(m.blinks, m.blinkRate),
      track ? shapeText(m.shape) : '',
      entry.unusual.includes('larger') ? TEXT.larger : '',
      entry.unusual.includes('brighter') ? TEXT.brighter : '',
    ].filter(Boolean);
  }

  function unexplainedCard(entry) {
    const card = h('article', { class: `card sky-entry${entry.id === target ? ' sky-target' : ''}`, dataset: { entry: entry.id }, tabindex: '-1' },
      stillBlock(entry),
      h('div', { class: 'sky-entry-body' },
        h('div', { class: 'sky-entry-head' },
          h('h3', null, h('time', { datetime: new Date(entry.start).toISOString() }, timeText(entry.start, zoneName, { seconds: true }))),
          h('span', { class: 'sky-kind' }, TEXT.kinds[entry.kind] ?? TEXT.kinds.track), labelTag(entry)),
        h('ul', { class: 'sky-facts' }, facts(entry).map((line) => h('li', null, line))),
        entry.ai ? h('p', { class: 'sky-ai' }, h('span', { class: 'sky-ai-label' }, TEXT.ai), ' ', entry.ai.sentence) : null,
        h('div', { class: 'row sky-actions' },
          h('a', { class: 'btn small', href: watchAddress(current, entry) }, icon('film'), TEXT.watch),
          h('a', { class: 'btn small', href: clipAddress(current, entry, zoneName), download: true }, icon('download'), TEXT.download)),
        correctionBlock(entry)));
    if (entry.id === target) targetNode = card;
    return card;
  }

  function unexplainedSection(list) {
    headings.unexplained = h('span', { class: 'sky-count' }, String(list.length));
    const section = h('section', { class: 'sky-unexplained', 'aria-label': TEXT.unexplained }, h('h2', null, TEXT.unexplained, ' ', headings.unexplained));
    if (!list.length) {
      section.append(h('p', { class: 'muted' }, log.entries.length ? TEXT.nothingUnexplained : TEXT.nothingAtAll));
      return section;
    }
    const cards = h('div', { class: 'sky-cards' });
    let shown = 0;
    const more = h('button', { class: 'btn', type: 'button', hidden: true, onclick: () => build() }, TEXT.showMore);
    const targetAt = list.findIndex((entry) => entry.id === target);
    function build(upTo = shown + PAGE_CARDS) {
      for (; shown < Math.min(upTo, list.length); shown += 1) cards.append(unexplainedCard(list[shown]));
      more.hidden = shown >= list.length;
      more.setAttribute('aria-label', `${TEXT.showMore}: ${list.length - shown} left`);
    }
    build(Math.max(PAGE_CARDS, targetAt + 1));
    section.append(cards, more);
    return section;
  }

  // MARK: The explained

  function explainedRow(entry) {
    const probable = entry.display === 'probablePlane';
    const where = directionText(entry.measures.azimuth, entry.measures.elevation);
    const row = h('li', { class: `sky-row${entry.id === target ? ' sky-target' : ''}`, dataset: { entry: entry.id }, tabindex: '-1' },
      h('div', { class: 'sky-row-main' },
        h('span', { class: 'sky-row-time' }, timeText(entry.start, zoneName, { seconds: true })),
        h('span', { class: 'sky-row-what' }, entry.detail ?? (probable ? KIND_WORDS.plane : KIND_WORDS[entry.display] ?? '')),
        probable ? h('span', { class: 'sky-tag' }, TEXT.probable) : null,
        labelTag(entry),
        where ? h('span', { class: 'sky-row-where muted' }, where) : null),
      correctionBlock(entry));
    if (entry.id === target) targetNode = row;
    return row;
  }

  function groupDetails(group) {
    const details = h('details', { class: 'sky-group-details', dataset: { group: group.label } });
    details.open = false;   // collapsed until the person opens it
    const rows = h('ul', { class: 'sky-rows' });
    let shown = 0;
    let built = false;
    const more = h('button', { class: 'btn small', type: 'button', hidden: true, onclick: () => build() }, TEXT.showMore);
    function build(upTo = shown + PAGE_ROWS) {
      for (; shown < Math.min(upTo, group.entries.length); shown += 1) rows.append(explainedRow(group.entries[shown]));
      more.hidden = shown >= group.entries.length;
      more.setAttribute('aria-label', `${TEXT.showMore}: ${group.entries.length - shown} left`);
    }
    function ensure() {
      if (built) return;
      built = true;
      const targetAt = group.entries.findIndex((entry) => entry.id === target);
      build(Math.max(PAGE_ROWS, targetAt + 1));
    }
    details.append(
      h('summary', null, h('span', { class: `sky-key sky-key--${group.label}`, 'aria-hidden': 'true' }), h('span', { class: 'sky-group-title' }, group.title), ' ', h('span', { class: 'sky-count' }, String(group.entries.length))),
      rows, more);
    details.addEventListener('toggle', () => {
      if (details.open) { opened.add(group.label); ensure(); } else opened.delete(group.label);
    });
    if (opened.has(group.label) || group.entries.some((entry) => entry.id === target)) {
      details.open = true;
      opened.add(group.label);
      ensure();
    }
    return details;
  }

  function explainedSection(explained) {
    const groups = groupExplained(explained);
    if (!groups.length) return null;
    headings.explained = h('span', { class: 'sky-count' }, String(explained.length));
    return h('section', { class: 'sky-explained', 'aria-label': TEXT.explained }, h('h2', null, TEXT.explained, ' ', headings.explained), groups.map(groupDetails));
  }

  // MARK: Status

  function drawStatus() {
    if (!statusBox || !log) return;
    const camera = cameraById(current);
    const sky = camera?.status?.sky;
    const aim = sky?.aim ?? log.aim;
    const lines = aimLines(aim, camera ? defaultLensLayout(camera) : null).map((line) => ['sky-aim', line]);
    if ((aim?.quality ?? 'rough') === 'rough') lines.push(['small muted', SKY_TEXT.card.looseFlights]);
    if (aim?.note) lines.push(['small', aim.note]);
    const stream = streamText(sky);
    if (stream) lines.push(['small muted', stream]);
    const key = JSON.stringify(lines);
    if (key === statusKey) return;   // the camera's news comes every few seconds: the lines are drawn again only when they changed
    statusKey = key;
    replace(statusBox, h('h2', null, TEXT.status), lines.map(([classes, text]) => h('p', { class: classes }, text)));
  }

  function drawNote() {
    if (!noteBox) return;
    const camera = cameraById(current);
    const off = Boolean(camera && camera.skyDetector?.enabled !== true);
    if (off === noteOff) return;
    noteOff = off;
    replace(noteBox, off ? h('div', { class: 'banner info' }, icon('info'), h('div', { class: 'text' }, TEXT.cameraOff, ' ', h('a', { href: `#/camera/${current}` }, TEXT.turnOn))) : null);
  }

  function drawLearning() {
    const sky = cameraById(current)?.status?.sky;
    const text = learningText(sky?.learning ?? log?.learning);
    return text ? h('p', { class: 'sky-learning' }, text) : null;
  }

  // MARK: The body

  /** The plugin is off: Sky Watcher does nothing, and the way to switch it on is Plugins. */
  function offPage() {
    return h('div', { class: 'empty sky-off' }, h('h2', null, TEXT.off), h('p', null, TEXT.offHelp), h('a', { class: 'btn primary', href: '#/plugins' }, TEXT.toPlugins));
  }

  /** The plugin is on and no camera watches the sky yet: where to turn it on, with a link to every camera's page (or to add one). */
  function noCameraPage() {
    const list = cameras();
    return h('div', { class: 'empty sky-empty' },
      h('h2', null, TEXT.noCameraOn),
      list.length
        ? [h('p', null, TEXT.pickCamera), h('ul', { class: 'sky-camera-links' }, list.map((camera) => h('li', null, h('a', { class: 'btn', href: `#/camera/${camera.id}` }, camera.name))))]
        : [h('p', null, TEXT.noCameras), h('a', { class: 'btn primary', href: '#/add' }, TEXT.addCamera)]);
  }

  function drawBody() {
    body.setAttribute('aria-busy', String(phase === 'loading'));
    if (phase === 'off') return replace(body, offPage());
    if (phase === 'none') {
      noneKey = noneCamerasKey();
      return replace(body, noCameraPage());
    }
    if (phase === 'removed') {
      return replace(body, h('div', { class: 'empty' }, h('h2', null, TEXT.removed), h('a', { class: 'btn primary', href: '#/cameras' }, TEXT.toCameras)));
    }
    if (phase === 'failed') {
      return replace(body, h('div', { class: 'sky-failed' }, inlineError(failure), h('button', { class: 'btn', type: 'button', onclick: () => fetchLog() }, TEXT.retry)));
    }
    if (!log) {
      return replace(body, h('div', { class: 'checking', role: 'status' }, spinner(), h('span', { class: 'muted' }, TEXT.loading)));
    }
    if (phase === 'loading') {
      body.classList.add('sky-stale');
      return undefined;
    }
    body.classList.remove('sky-stale');
    refreshers.clear();
    const camera = cameraById(current);
    summaryEl = h('p', { class: 'sky-summary', role: 'status' });
    countsEl = h('ul', { class: 'sky-counts' });
    stripBox = h('div', { class: 'sky-strip' });
    statusBox = h('section', { class: 'sky-status' });
    noteBox = h('div', { class: 'sky-note' });
    statusKey = '';
    noteOff = null;
    headings = { unexplained: null, explained: null };
    const conditions = conditionsText(log.conditions, zoneName, log.view);
    const explained = log.entries.filter((entry) => entryBucket(entry) !== 'unexplained');
    const unexplained = log.entries.filter((entry) => entryBucket(entry) === 'unexplained');
    const learning = drawLearning();
    replace(body,
      h('header', { class: 'sky-top' },
        h('h2', null, `${TEXT.titlePrefix}${camera?.name ?? ''}`),
        noteBox, summaryEl, countsEl,
        conditions ? h('p', { class: 'sky-conditions' }, conditions) : null,
        learning),
      stripBox,
      unexplainedSection(unexplained),
      explainedSection(explained),
      statusBox);
    drawNote();
    drawSummary();
    drawCounts();
    drawStrip();
    drawStatus();
    // The entry the address names: brought into view once, when the page is first drawn.
    const named = targetNode;
    target = null;
    targetNode = null;
    if (named) setTimeout(() => { if (!destroyed) named.scrollIntoView?.({ block: 'center' }); }, 0);
    return undefined;
  }

  // MARK: Start

  const stopCameras = onCameras(() => {
    if (destroyed || phase === 'off') return;
    if (current && !cameraById(current)) {
      phase = 'removed';
      log = null;
      drawChrome();
      drawBody();
      return;
    }
    if (phase === 'none') {
      if (skyCameras().length) { fetchLog(); return; }
      if (noneCamerasKey() !== noneKey) drawBody();   // the list of cameras to open follows the cameras
    }
    drawChrome();
    if (phase === 'ready') { drawStatus(); drawNote(); }
  });

  // The Setup panel (the box's own settings) is there while the plugin is on; with it off, Sky Watcher does nothing at all.
  let panel = null;
  if (pluginIsOn) {
    panel = setup();
    if (panel) replace(setupHost, panel.el);
    fetchLog();
  } else {
    drawChrome();
    drawBody();
  }

  return {
    el,
    destroy() {
      destroyed = true;
      stopCameras();
      panel?.destroy();
    },
  };
}

const round = (value) => Math.round(value * 100) / 100;

/** The route: #/sky, #/sky/<camera> and ?night=yyyy-MM-dd&view=night|day&entry=<id>. Writing the address replaces the entry, so Back leaves the page. */
export function renderSkyLog({ params = [], setTitle } = {}) {
  setTitle?.(SKY_TEXT.page);
  const page = createSkyLogPage({
    cameraID: params[0] ?? null,
    query: params[1] ?? '',
    writeAddress: (address) => { try { history.replaceState(history.state, '', `#/${address}`); } catch { /* the address stays as it is */ } },
  });
  return { el: page.el, destroy: () => page.destroy() };
}
