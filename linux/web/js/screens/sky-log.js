// The Sky Watcher page (#/sky): a night's (or a day's) sky log as a grid you scroll through. At the top the summary ("Last night: 214
// unexplained, 2,387 explained"), the sky's conditions and what the box is still learning; then a dock that stays at the top of the window while
// the grid scrolls under it: the night as a strip from sunset to sunrise (a dot for each light, the unexplained larger and glowing; a tap on a
// time brings that hour into view, and a band shows which part of the night is on the screen), and the filters: a chip for each kind with its
// count (several at once; All clears them), "High priority", "With picture", and the order (newest or oldest first, by priority, the longest,
// the fastest across the sky; inside Unexplained the night opens by priority).
// The grid (sky-grid.js) holds a card for each light, under the hours they began in, made as they come near the screen; a note at an hour in
// which the box followed more lights than it logs. A card opens the clip player on this page (sky-player.js, loaded on demand): the recording
// around the light, with the light's details beside it, the one-tap correction ("That was a…": the card, the counts, the summary and the strip
// follow at once, and a card the filters no longer show fades out of the grid while the page keeps its place) and the way to the Monitor.
// Past nights and days, a camera picker, and the aim and the stream as status.
// The filters and the order are in the address (#/sky/<camera>?night=…&view=…&kinds=…&sort=…&pictures=1), so a reload or Back keeps them, and
// in this browser's memory, so the page opens as it was left. The unexplained come with the bridge's guide: a priority (a badge on the card) and
// the reasons for it (the first on the card, every one in the player); lights that moved together say which of them each was ("1 of 3 moving
// together"), and in the player a tap on that shows only them (group=… in the address, and a chip that takes it away).
// Sky Watcher is a plugin: while it is off the page says so, with the way to Plugins; while it is on, a Setup panel (where the box is, the flight
// feed, the AI's limit: sky-setup.js) sits at the top, and with no camera watching the sky yet the page says where to turn it on.
// Nothing here claims a real size, distance or speed: a light's speed is only ever "faster across the sky than planes at that height".
import { get, post } from '../api.js';
import { h, replace, spinner, svg, toast } from '../dom.js';
import { capitalize } from '../format.js';
import { icon } from '../icons.js';
import { cameraList, pluginOn, subscribe } from '../store.js';
import { inlineError } from './common.js';
import { createSkyGrid } from './sky-grid.js';
import { createSkySetupPanel } from './sky-setup.js';
import {
  BUCKETS, CORRECTIONS, GRID_KINDS, GRID_SORTS, SKY_ROUTE, SKY_TEXT, aimLines, blinkText, cappedByHour, cappedText, chipCounts, clipAddress, conditionsText, correctionText,
  countEntries, countLabel, countsAfter, dayLabel, defaultLensLayout, defaultSort, directionText, durationText, entryBucket, gridChoice, gridQuery, groupText, groupsOf,
  isTimeSort, kindWord, learningText, matchesFilters, normalizeEntry, piecesText, priorityOf, priorityWord, readGridQuery, readGroupQuery, reasonsOf, shapeText, shiftDate, skyWatching,
  sortEntries, speedText, streamText, stripDots, stripTicks, summaryText, timeText, toMs, watchAddress,
} from './sky-model.js';

export { SKY_ROUTE };

const TEXT = SKY_TEXT.log;
const NIGHT_NAME = /^\d{4}-\d{2}-\d{2}$/;
/** Where this browser keeps the filters and the order it chose last. */
const MEMORY_KEY = 'cb.sky.grid';

/**
 * The strip's drawing: its view box is the strip's own pixels (as wide as the page, so the dots stay round), the sky this tall, over a lane for the
 * hours. Halos for the unexplained up to `halos` of them, glowing (moving) up to `glowing`: a busy night's strip stays still and light to draw.
 */
const STRIP = { tall: 64, short: 40, narrow: 560, lane: 18, shortLane: 16, padX: 10, padY: 7, dot: 2.6, unexplained: 4.8, halo: 10, halos: 60, glowing: 12 };

const OWN_LABEL = { plane: 'plane', bird: 'bird', bug: 'bug', satellite: 'satellite', meteor: 'meteor' };
/** A kind chip's colour key (sky.css .sky-key--…). */
const KEY_OF_CHIP = { unexplained: 'unexplained', high: 'unexplained', planes: 'planes', satellites: 'satellites', meteors: 'meteors', bugs: 'bugsAndBirds' };
const SORT_SHORT = { newest: 'Newest', oldest: 'Oldest', priority: 'Priority', longest: 'Longest', fastest: 'Fastest' };
const finite = (value) => (typeof value === 'number' && Number.isFinite(value) ? value : null);
const clamp01 = (value) => Math.min(1, Math.max(0, value));
const count = (n) => n.toLocaleString('en-US');

// MARK: Requests

/** GET sky/cameras/:id/night?date=yyyy-MM-dd&view=night|day (no date: the latest night). */
function loadNight({ cameraID, night, view }) {
  return get(`sky/cameras/${encodeURIComponent(cameraID)}/night?${night ? `date=${encodeURIComponent(night)}&` : ''}view=${view}`);
}

/** POST sky/cameras/:id/entries/:eid/correction { night, label }: the entry as the bridge has it afterwards. */
function sendCorrection({ cameraID, entryID, night, label }) {
  return post(`sky/cameras/${encodeURIComponent(cameraID)}/entries/${encodeURIComponent(entryID)}/correction`, { night, label });
}

/** The clip player (sky-player.js), loaded the first time a card is opened: the log itself does not need its code. -> { close() } */
function openSkyPlayer(options) {
  return import('./sky-player.js').then((module) => module.openSkyPlayer(options));
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

/** How big the night's pictures are, { width, height } in pixels, as the bridge says; null when it did not (an older bridge, or none of the pictures can be read). */
function readPicture(value) {
  const side = (number) => Number.isInteger(number) && number > 0 && number <= 65_535;
  return value && typeof value === 'object' && side(value.width) && side(value.height) ? { width: value.width, height: value.height } : null;
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
    capped: Array.isArray(answer.capped) ? answer.capped : [],   // the hours with more lights than were logged (a bridge from before sends none)
    picture: readPicture(answer.picture),
  };
}

/** The page's address parts: night=yyyy-MM-dd, view=night|day, entry=<id>, the grid's kinds, sort and pictures, and group=<lights that moved together>. */
function readQuery(query) {
  const found = new URLSearchParams(typeof query === 'string' ? query : '');
  const night = found.get('night');
  return { night: night && shiftDate(night, 0) ? night : null, view: found.get('view') === 'day' ? 'day' : 'night', entry: found.get('entry') || null, grid: readGridQuery(found),
    group: readGroupQuery(found) };
}

/** The filters and the order this browser chose last (localStorage; a private window or blocked site data keeps nothing, and the page still works). */
function browserMemory() {
  return {
    read() { try { const text = globalThis.localStorage?.getItem(MEMORY_KEY); return text ? JSON.parse(text) : null; } catch { return null; } },
    write(choice) { try { globalThis.localStorage?.setItem(MEMORY_KEY, JSON.stringify(choice)); } catch { /* not kept: the address still has them */ } },
  };
}

/** How far down the window the page's own bar reaches when it lies across the top (a phone), so the dock sticks under it; 0 when it is beside the page. */
function shellTop() {
  const bar = typeof globalThis.document?.querySelector === 'function' ? globalThis.document.querySelector('.app.signed-in > .sidebar') : null;
  if (!bar || typeof getComputedStyle !== 'function') return 0;
  const position = getComputedStyle(bar).position;
  if (position !== 'sticky' && position !== 'fixed') return 0;
  const box = bar.getBoundingClientRect();
  return box.top <= 1 && box.width >= (globalThis.innerWidth || 0) - 1 ? Math.max(0, Math.round(box.bottom)) : 0;
}

function nextFrame(fn) {
  return typeof requestAnimationFrame === 'function' ? requestAnimationFrame(fn) : setTimeout(fn, 16);
}

// MARK: The page

/**
 * The page, without its wiring (tests pass fakes). -> { el, destroy() }
 *   cameraID      the camera whose log is shown (none: the first that watches the sky)
 *   query         the address's query string (night, view, entry, kinds, sort, pictures)
 *   load(request) GET the night for { cameraID, night (null: the latest), view }; correct({ cameraID, entryID, night, label }) POSTs a correction
 *   now()         this device's clock; the bridge's `serverTime` says how far off it is
 *   writeAddress(address)   puts 'sky/<camera>?night=…&view=…&kinds=…' into the address bar without a page change
 *   cameras()     the camera resources (store.js cameraList()); onCameras(fn) calls fn when they change and returns the stop function
 *   zone()        the bridge's time zone (or a promise of it): the page says the box's hours
 *   plugin()      whether the Sky Watcher plugin is on (store.js pluginOn): off, the page only says so; it is read once, when the page is made
 *   setup()       the Setup panel, { el, destroy() } (sky-setup.js), or null for none
 *   openPlayer(o) the clip player over the page (sky-player.js openSkyPlayer): { camera, entry, zone, heading, what, still, watchHref, details,
 *                 onClose } -> a promise of { close() }
 *   remember      { read(), write(choice) }: this browser's memory of the filters and the order (localStorage)
 *   createObserver, frame, wait, scrollBy   the grid's (sky-grid.js): what tells it a card is near the screen, the next frame, a timer (a
 *                 leaving card's fade) and the window's scrolling (the page keeps its place when a card leaves)
 *   notify(text)  says something that went wrong for a moment (a toast)
 */
export function createSkyLogPage({ cameraID = null, query = '', load = loadNight, correct = sendCorrection, now = () => Date.now(), writeAddress = () => {},
  cameras = cameraList, onCameras = (fn) => subscribe((kind) => { if (kind === 'camera' || kind === 'removed') fn(); }), zone = loadZone,
  plugin = () => pluginOn('sky'), setup = () => createSkySetupPanel(), openPlayer = openSkyPlayer, remember = browserMemory(), createObserver, frame = nextFrame,
  wait, scrollBy, notify = (text) => toast(text, 'error') } = {}) {
  const wanted = readQuery(query);
  const pluginIsOn = plugin() === true;
  let current = cameraID;        // the camera shown (null: not chosen yet)
  let night = wanted.night;      // the night asked for (null: the latest)
  let view = wanted.view;
  let target = wanted.entry;     // the entry the address names, until it has been shown
  let choice = gridChoice(wanted.grid.given ? wanted.grid : remember.read());   // the filters and the order (sort null: the night's own)
  let group = wanted.group;      // the lights that moved together the grid is narrowed to (null: none); the address keeps it, this browser does not
  let together = new Map();      // the night's lights that moved together (groupsOf)
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
  let statusKey = '';            // what the status lines say now, so that they are drawn again only when that changes
  let noteOff = null;            // whether the note "Sky Watcher is off for this camera" is on the page
  let stripWidth = 0;            // the width the strip was drawn at
  const stripDotsOf = new Map(); // entry id -> its dot and halo on the strip, so a filter fades them without drawing the strip again
  let bandQueued = false;
  let resizeTimer = null;
  const latest = { night: null, day: null };   // the name of the latest night (and day) the bridge answered with
  const refreshers = new Map();                // entry id -> the functions that draw an open player's details again after a correction
  let player = null;                           // the clip player that is open ({ close() }), or null
  let opening = false;                         // and one is on its way
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

  // The dock: the strip and the filters, at the top of the window while the grid scrolls.
  const stripBox = h('div', { class: 'sky-strip' });
  const band = h('div', { class: 'sky-strip-view', 'aria-hidden': 'true', hidden: true });   // which part of the night is on the screen
  const counts = new Map();   // a chip's kind ('all' or a GRID_KINDS name) -> the number on it
  function filterButton(kind, word) {
    const number = h('span', { class: 'sky-filter-count' });
    counts.set(kind, number);
    const mark = kind === 'all' ? null : kind === 'corrected' ? icon('check') : h('span', { class: `sky-key sky-key--${KEY_OF_CHIP[kind]}`, 'aria-hidden': 'true' });
    const all = () => { group = null; choose({ ...choice, kinds: [] }); };
    return h('button', { class: 'sky-filter', type: 'button', dataset: { kind }, 'aria-pressed': 'false', onclick: () => (kind === 'all' ? all() : toggleKind(kind)) },
      mark, h('span', { class: 'sky-filter-word' }, word), number);
  }
  const allButton = filterButton('all', TEXT.all);
  const kindButtons = new Map(GRID_KINDS.map(([kind, word]) => [kind, filterButton(kind, word)]));
  // The lights that moved together, when the grid is narrowed to them: a chip that takes it away.
  const groupCount = h('span', { class: 'sky-filter-count' });
  const groupButton = h('button', { class: 'sky-filter sky-filter--group', type: 'button', dataset: { kind: 'group' }, 'aria-pressed': 'true', hidden: true,
    title: TEXT.showEveryLight, onclick: () => { group = null; choose(choice); } },
  h('span', { class: 'sky-key sky-key--unexplained', 'aria-hidden': 'true' }), h('span', { class: 'sky-filter-word' }, TEXT.movingTogether), groupCount, icon('x'));
  const picturesInput = h('input', { type: 'checkbox', role: 'switch', onchange: () => choose({ ...choice, pictures: picturesInput.checked }) });
  const picturesSwitch = h('label', { class: 'sky-pictures' }, h('span', { class: 'switch' }, picturesInput), h('span', { class: 'sky-pictures-word' }, TEXT.withPicture));
  // The night's own order is kept as none chosen, so that another night opens in its own (the newest first while it is still going).
  const sortSelect = h('select', { class: 'sky-sort-select', 'aria-label': TEXT.sort,
    onchange: () => choose({ ...choice, sort: log && sortSelect.value === ownSort() ? null : sortSelect.value }) },
  GRID_SORTS.map(([value, words]) => h('option', { value }, words)));
  const sortLong = h('span', { class: 'sky-sort-long' });
  const sortShort = h('span', { class: 'sky-sort-short' });
  const sortBox = h('label', { class: 'sky-sort' }, icon('sort'), h('span', { class: 'sky-sort-face', 'aria-hidden': 'true' }, sortLong, sortShort), sortSelect);
  const chipRow = h('div', { class: 'sky-chip-row', role: 'group', 'aria-label': TEXT.show }, allButton, [...kindButtons.values()], groupButton);
  const filters = h('div', { class: 'sky-filters' }, chipRow, h('div', { class: 'sky-tools' }, picturesSwitch, sortBox));
  const dock = h('div', { class: 'sky-dock' }, stripBox, filters);

  const grid = createSkyGrid({
    thumbAddress: (entry) => stillAddress(entry, 'thumb'), stillAddress: (entry) => stillAddress(entry), picture: () => log?.picture ?? null,
    onOpen: (entry, card) => open(entry, card), onChange: () => queueBand(), createObserver, frame, wait, scrollBy,
    viewTop: () => dockBottom(),
  });

  // The parts of the log that change in place.
  let summaryEl = null;
  let statusBox = null;
  let noteBox = null;

  // MARK: Cameras

  const cameraById = (id) => (id ? cameras().find((camera) => String(camera.id).toLowerCase() === String(id).toLowerCase()) ?? null : null);
  const skyCameras = () => skyWatching(cameras());

  /** Picks the camera to show: the one named, else the first that watches the sky. Returns what the page can do about it. */
  function pickCamera() {
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
    params.push(...gridQuery(choice));
    if (group) params.push(`group=${group}`);
    return `sky/${current}${params.length ? `?${params.join('&')}` : ''}`;
  }

  function writeOut() {
    try { writeAddress(addressFor()); } catch { /* the address stays as it is */ }
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
    const state = pickCamera();
    if (state !== 'ready') {
      phase = state;
      log = null;
      drawChrome();
      drawBody();
      return;
    }
    const mine = ++ticket;
    const asked = { cameraID: current, night, view };
    phase = 'loading';
    failure = '';
    writeOut();
    drawChrome();
    drawBody();
    zoneAsk ??= Promise.resolve().then(zone).then((name) => { if (typeof name === 'string' && name) zoneName = name; }, () => {});
    try {
      const [answer] = await Promise.all([load(asked), zoneAsk]);
      if (destroyed || mine !== ticket) return;
      log = readNight(answer, asked);
      together = groupsOf(log.entries);
      if (group && !together.has(group)) group = null;   // another night's group (or one no longer there): every light
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

  function countsLabel() {
    return BUCKETS.filter((kind) => kind !== 'notSure' || log.counts.notSure > 0).map((kind) => `${log.counts[kind]} ${countLabel(kind, log.counts[kind])}`).join(', ');
  }

  // MARK: The filters and the order

  /**
   * The order a night opens in with these filters: by priority inside Unexplained (or High priority); else the night's own (the newest first
   * while it is still going, the oldest first after); the lights that moved together by time.
   */
  const ownSort = () => (group ? 'oldest' : log ? defaultSort(log, clock(), choice.kinds, log.entries.some((entry) => priorityOf(entry) !== null)) : 'oldest');
  /** The order shown: the person's, else the filters' own. */
  const sortNow = () => choice.sort ?? ownSort();
  /** What the grid is narrowed to: the chips, With picture and the lights that moved together. */
  const narrowing = () => ({ ...choice, group });

  function drawFilters() {
    if (!log) return;
    const numbers = chipCounts(log.entries);
    for (const [kind, number] of counts) {
      number.textContent = count(numbers[kind]);
      const button = kind === 'all' ? allButton : kindButtons.get(kind);
      button.dataset.empty = String(numbers[kind] === 0);
    }
    allButton.setAttribute('aria-pressed', String(choice.kinds.length === 0 && !group));
    for (const [kind, button] of kindButtons) button.setAttribute('aria-pressed', String(choice.kinds.includes(kind)));
    groupButton.hidden = !group;
    groupCount.textContent = group ? count(together.get(group)?.length ?? 0) : '';
    picturesInput.checked = choice.pictures;
    const sort = sortNow();
    sortSelect.value = sort;
    sortLong.textContent = GRID_SORTS.find(([value]) => value === sort)?.[1] ?? '';
    sortShort.textContent = SORT_SHORT[sort] ?? '';
    filters.hidden = log.entries.length === 0;
  }

  /** What the grid shows when nothing is left: the night had nothing, or the filters leave nothing (and the way back to everything). */
  function emptyState() {
    if (!log.entries.length) return h('p', { class: 'muted sky-nothing' }, TEXT.nothingAtAll);
    const onlyUnexplained = choice.kinds.length === 1 && choice.kinds[0] === 'unexplained' && !choice.pictures;
    const sentence = onlyUnexplained ? TEXT.nothingUnexplained : choice.pictures && !choice.kinds.length ? TEXT.noPictures : TEXT.noMatch;
    return h('div', { class: 'sky-no-match' }, h('p', null, sentence),
      h('button', { class: 'btn', type: 'button', onclick: () => { group = null; choose({ ...choice, kinds: [], pictures: false }); } }, TEXT.clearFilters));
  }

  /** The grid of what the filters show, in the order chosen; with `keepPlace`, what is at the top of the screen stays there. */
  function drawGrid({ keepPlace = false } = {}) {
    if (!log) return;
    const sort = sortNow();
    const byHour = isTimeSort(sort);
    const shown = sortEntries(log.entries.filter((entry) => matchesFilters(entry, narrowing())), sort);
    grid.show({ entries: shown, zone: zoneName, byHour, capped: cappedByHour(log.capped, zoneName), notes: byHour ? [] : cappedText(log.capped, zoneName), together,
      empty: emptyState() }, { keepPlace });
  }

  const dockBottom = () => dock.getBoundingClientRect().bottom || 0;

  /** The time at the top of the grid, when the person has scrolled into it (null before that: the page then stays where it is). */
  function placeNow() {
    const box = grid.el.getBoundingClientRect();
    if (!(box.height > 0) || box.top >= dockBottom()) return null;
    return grid.span(dockBottom(), window.innerHeight || 0)?.first ?? null;
  }

  /** A new choice of filters or order: kept in the address and in this browser, and the grid drawn again at the time the person was at. */
  function choose(next) {
    const at = placeNow();
    choice = gridChoice(next);
    remember.write(choice);
    writeOut();
    drawFilters();
    fadeStrip();
    drawGrid();
    if (at !== null && (!isTimeSort(sortNow()) || grid.jumpTo(at) === null)) grid.el.scrollIntoView?.({ block: 'start' });
    queueBand();
  }

  function toggleKind(kind) {
    group = null;
    choose({ ...choice, kinds: choice.kinds.includes(kind) ? choice.kinds.filter((name) => name !== kind) : [...choice.kinds, kind] });
  }

  /** Only the lights of `named` (they moved together), from the player: it closes, and every kind and picture is shown, in their own order. */
  function showGroup(named) {
    if (!named || !together.has(named)) return;
    player?.close?.();
    group = named;
    choose({ ...choice, kinds: [], pictures: false });
  }

  /** The strip's tap on a time: that hour in view, in the night's own order when another order had the grid without hours. */
  function jump(ms) {
    if (!log) return;
    if (!isTimeSort(sortNow())) {
      choice = gridChoice({ ...choice, sort: null });
      remember.write(choice);
      writeOut();
      drawFilters();
      drawGrid();
    }
    grid.jumpTo(ms);
    queueBand();
  }

  // MARK: The strip

  function drawStrip() {
    if (!log) return;
    const measured = Number(stripBox.clientWidth);
    const width = measured > 0 ? Math.round(measured) : 720;
    stripWidth = width;
    const narrow = width < STRIP.narrow;
    const sky = narrow ? STRIP.short : STRIP.tall;
    const height = sky + (narrow ? STRIP.shortLane : STRIP.lane);
    const size = narrow ? 0.75 : 1;   // a phone's strip is shorter: its dots are smaller
    const { padX, padY } = STRIP;
    const from = log.from ?? 0;
    const to = log.to ?? 0;
    const dots = stripDots(log.entries, from, to);
    if (!dots.length && !(to > from)) {
      replace(stripBox);
      return;
    }
    const px = (x) => padX + x * (width - 2 * padX);
    const py = (y) => padY + y * (sky - 2 * padY);
    const chart = svg('svg', { class: 'sky-strip-svg', viewBox: `0 0 ${width} ${height}`, role: 'img', 'aria-label': `${log.view === 'day' ? 'Day' : 'Night'} strip: ${countsLabel()}`, focusable: 'false' });
    chart.append(svg('rect', { class: 'sky-sky', x: 0, y: 0, width, height, rx: 10 }));
    const span = to - from;
    for (const part of log.conditions) {
      if (part?.state !== 'cloudy' && part?.state !== 'notVisible') continue;
      const start = clamp01((part.from - from) / span);
      const end = clamp01((part.to - from) / span);
      if (end > start) chart.append(svg('rect', { class: `sky-band sky-band--${part.state}`, x: round(px(start)), y: 0, width: round(px(end) - px(start)), height: sky }));
    }
    for (const elevation of [60, 30]) chart.append(svg('line', { class: 'sky-grid', x1: padX, x2: width - padX, y1: round(py(1 - elevation / 90)), y2: round(py(1 - elevation / 90)) }));
    chart.append(svg('line', { class: 'sky-horizon', x1: padX, x2: width - padX, y1: round(py(1)), y2: round(py(1)) }));
    // The dots, the unexplained last so that nothing covers them; what the filters leave out is faint (fadeStrip).
    const lights = dots.filter((dot) => dot.unexplained).length;
    chart.dataset.calm = String(lights > STRIP.glowing);
    const order = (dot) => BUCKETS.length - BUCKETS.indexOf(dot.kind);
    stripDotsOf.clear();
    for (const dot of [...dots].sort((a, b) => order(b) - order(a))) {
      const cx = round(px(dot.x));
      const cy = round(py(dot.y));
      const halo = dot.unexplained && lights <= STRIP.halos ? svg('circle', { class: 'sky-halo', cx, cy, r: round(STRIP.halo * size) }) : null;
      const circle = svg('circle', { class: `sky-dot sky-dot--${dot.kind}`, cx, cy, r: round((dot.unexplained ? STRIP.unexplained : STRIP.dot) * size) });
      if (halo) chart.append(halo);
      chart.append(circle);
      stripDotsOf.set(dot.id, { circle, halo, kind: dot.kind, out: false });
    }
    fadeStrip();
    const at = (fraction) => `${((px(fraction) / width) * 100).toFixed(2)}%`;
    const ticks = stripTicks(from, to, zoneName).map((tick) => {
      const button = h('button', { class: 'sky-tick', type: 'button', 'aria-label': `${TEXT.goTo} ${tick.label}`, onclick: () => jump(from + tick.x * span) }, tick.label);
      button.style.left = at(tick.x);
      return button;
    });
    const hover = h('span', { class: 'sky-strip-hover', hidden: true }, h('span', { class: 'sky-strip-hover-time' }));
    const plot = h('div', { class: 'sky-strip-plot' }, chart, band, hover,
      h('div', { class: 'sky-axis' }, ticks),
      h('div', { class: 'sky-ends', 'aria-hidden': 'true' }, h('span', null, timeText(from, zoneName)), h('span', null, timeText(to, zoneName))));
    plot.style.setProperty('--sky-strip-sky', `${sky}px`);
    // A tap or a click anywhere on the night: the hour of that time comes into view. A mouse over it says the time.
    const timeAt = (event) => {
      const box = chart.getBoundingClientRect();
      if (!(box.width > 0)) return null;
      const x = ((event.clientX - box.left) / box.width) * width;
      return { ms: from + clamp01((x - padX) / (width - 2 * padX)) * span, x: (event.clientX - box.left) / box.width };
    };
    plot.addEventListener('click', (event) => {
      if (typeof event.target?.closest === 'function' && event.target.closest('button')) return;
      const found = timeAt(event);
      if (found) jump(found.ms);
    });
    plot.addEventListener('pointermove', (event) => {
      const found = event.pointerType === 'mouse' ? timeAt(event) : null;
      hover.hidden = !found;
      if (!found) return;
      hover.style.setProperty('--sky-hover-x', (found.x * 100).toFixed(2));
      hover.firstChild.textContent = timeText(found.ms, zoneName);
    });
    plot.addEventListener('pointerleave', () => { hover.hidden = true; });
    replace(stripBox, plot);
    queueBand();
  }

  /** What the filters leave out is faint on the strip (its halo hidden); the rest as drawn. */
  function fadeStrip() {
    if (!log) return;
    const filtered = choice.kinds.length > 0 || choice.pictures || Boolean(group);
    for (const entry of log.entries) {
      const drawn = stripDotsOf.get(entry.id);
      const out = filtered && !matchesFilters(entry, narrowing());
      if (!drawn || drawn.out === out) continue;   // only the dots that change are touched
      drawn.out = out;
      drawn.circle.setAttribute('class', `sky-dot sky-dot--${drawn.kind}${out ? ' is-out' : ''}`);
      if (drawn.halo) drawn.halo.setAttribute('class', out ? 'sky-halo is-out' : 'sky-halo');
    }
  }

  function queueBand() {
    if (bandQueued || destroyed) return;
    bandQueued = true;
    frame(drawBand);
  }

  function drawBand() {
    bandQueued = false;
    if (destroyed || !log || !band.isConnected) return;
    const length = (log.to ?? 0) - (log.from ?? 0);
    const seen = isTimeSort(sortNow()) && length > 0 ? grid.span(dockBottom(), window.innerHeight || 0) : null;
    band.hidden = !seen;
    if (!seen) return;
    const plotWidth = stripWidth - 2 * STRIP.padX;
    const left = (STRIP.padX + clamp01((seen.from - log.from) / length) * plotWidth) / stripWidth;
    const right = (STRIP.padX + clamp01((seen.to - log.from) / length) * plotWidth) / stripWidth;
    band.style.setProperty('--sky-view-l', (left * 100).toFixed(3));
    band.style.setProperty('--sky-view-w', Math.max(right - left, 6 / stripWidth).toFixed(5));
  }

  /** The dock sticks under the page's own bar on a phone; the hours' headings and a jump stop under the dock. */
  function layout() {
    if (destroyed) return;
    el.style.setProperty('--sky-top', `${shellTop()}px`);
    const height = dock.getBoundingClientRect().height;
    if (height > 0) el.style.setProperty('--sky-dock-h', `${Math.round(height)}px`);
  }

  // MARK: The still and the player

  /**
   * The address of an entry's picture: the whole one, or with `size` 'thumb' the small one the grid's cards use (the player keeps the whole one). A light
   * the box joined from pieces has the picture of one of its parts (`stillPart`).
   */
  const stillAddress = (entry, size = '') => `/api/v1/sky/cameras/${encodeURIComponent(current)}/entries/${encodeURIComponent(entry.stillPart?.id ?? entry.id)}/still?night=${encodeURIComponent(log.night)}${size ? `&size=${size}` : ''}`;

  /** What the player's title says the light was, and on which camera: never a height or a distance (a flight's stays in the details). */
  function playerWhat(entry) {
    const kind = entryBucket(entry) === 'unexplained' ? TEXT.kinds[entry.kind] ?? TEXT.kinds.track : kindWord(entry);
    return [kind, cameraById(current)?.name].filter(Boolean).join(' · ');
  }

  /**
   * Opens the clip player over the log with the light's details beside it: one at a time. It stays on its light whatever a correction does to
   * the card (its title says the new kind), and closing it puts the focus back on the card, or on the one that took its place when it left.
   */
  async function open(entry, opener) {
    if (player || opening || destroyed || !log) return;
    opening = true;
    opener.setAttribute('aria-busy', 'true');
    const camera = cameraById(current) ?? { id: current, name: '' };
    const details = detailsFor(entry);
    let handle = null;
    let closedEarly = false;
    const stopWhat = follow(entry.id, () => handle?.setWhat?.(playerWhat(entry)));
    try {
      handle = await openPlayer({
        camera, entry, zone: zoneName, heading: timeText(entry.start, zoneName, { seconds: true }), what: playerWhat(entry),
        still: entry.hasStill ? stillAddress(entry) : null, watchHref: watchAddress(current, entry), details: details.el,
        onClose: () => {
          closedEarly = handle === null;
          player = null;
          details.stop();
          stopWhat();
          if (!destroyed) (grid.focusFor(entry.id) ?? (grid.el.contains(opener) ? opener : null))?.focus?.({ preventScroll: true });
        },
      });
    } catch {
      details.stop();
      stopWhat();
      notify(TEXT.playerFailed);
    }
    opener.removeAttribute('aria-busy');
    opening = false;
    if (!handle || closedEarly) return;
    if (destroyed) { handle.close?.(); return; }
    player = handle;
  }

  /** Something to draw again after a correction of the entry, until `stop()`. */
  function follow(id, fn) {
    const list = refreshers.get(id) ?? new Set();
    list.add(fn);
    refreshers.set(id, list);
    fn();
    return () => { list.delete(fn); if (!list.size) refreshers.delete(id); };
  }

  /**
   * The facts under a light: where, how long (and in how many pieces it was seen: "1 light, seen in 15 parts"), how fast against planes, blinking, the
   * shape of its path, and what makes it stand out.
   */
  function facts(entry) {
    const m = entry.measures;
    const track = entry.kind === 'track';
    const seconds = durationText(m.duration ?? (entry.end - entry.start) / 1000);
    return [
      capitalize(directionText(m.azimuth, m.elevation)),
      seconds ? `Lasted ${seconds}` : '',
      piecesText(entry),
      track ? capitalize(speedText(entry.speedVsPlanes)) : '',
      blinkText(m.blinks, m.blinkRate),
      track ? shapeText(m.shape) : '',
      entry.unusual.includes('larger') ? TEXT.larger : '',
      entry.unusual.includes('brighter') ? TEXT.brighter : '',
    ].filter(Boolean);
  }

  /**
   * The light's details for the player: what it is (a chip in its kind's colour, and a quiet "Sorted later" for a light logged before the rules that they
   * sorted as the bridge read the night), what the box matched it to, the facts, the AI's sentence, the correction and the clip.
   */
  function detailsFor(entry) {
    const key = h('span', { class: 'sky-key', 'aria-hidden': 'true' });
    const word = h('span');
    const chip = h('span', { class: 'sky-kind-chip' }, key, word);
    const stopChip = follow(entry.id, () => {
      const kind = entryBucket(entry);
      chip.dataset.kind = kind;
      key.className = `sky-key sky-key--${kind}`;
      word.textContent = kindWord(entry);
    });
    const correction = correctionBlock(entry);
    const el = h('div', { class: 'sky-details' },
      h('div', { class: 'sky-details-kind' }, chip,
        entry.sortedLater ? h('span', { class: 'small sky-sorted-later', title: TEXT.sortedLaterWhy }, TEXT.sortedLater) : null),
      entry.detail ? h('p', { class: 'sky-detail' }, entry.detail) : null,
      reasonsBlock(entry),
      h('ul', { class: 'sky-facts' }, facts(entry).map((line) => h('li', null, line))),
      entry.ai ? h('p', { class: 'sky-ai' }, h('span', { class: 'sky-ai-label' }, TEXT.ai), ' ', entry.ai.sentence) : null,
      correction.el,
      h('div', { class: 'sky-details-actions' }, h('a', { class: 'btn small', href: clipAddress(current, entry, zoneName), download: true }, icon('download'), TEXT.download)));
    return { el, stop() { stopChip(); correction.stop(); } };
  }

  /**
   * Why an unexplained light ranks where it does: its priority and every reason; for one that moved with others, which of them it was, as a
   * button that shows only them. Nothing for an explained light, or one logged before the guide.
   */
  function reasonsBlock(entry) {
    const priority = priorityOf(entry);
    const reasons = reasonsOf(entry, together);
    if (!priority || !reasons.length) return null;
    const ours = groupText(entry, together);
    const item = (reason) => h('li', null, reason === ours && entry.group
      ? h('button', { class: 'btn small sky-group-show', type: 'button', title: TEXT.showTogether, onclick: () => showGroup(entry.group) }, reason)
      : reason);
    return h('div', { class: 'sky-reasons', dataset: { priority } },
      h('p', { class: 'sky-reasons-head' }, h('span', { class: 'sky-reasons-badge', dataset: { priority } }, `${priorityWord(priority)} priority`)),
      h('ul', { class: 'sky-reasons-list' }, reasons.map(item)));
  }

  // MARK: Corrections

  /** "That was a…" and its six buttons. After a tap the words say what was said, in place. -> { el, stop() } */
  function correctionBlock(entry) {
    const labelId = `sky-say-${entry.id}`;
    const said = h('p', { class: 'small sky-said', role: 'status', hidden: true });
    let busy = false;
    let problem = '';
    const buttons = CORRECTIONS.map(([value, word]) => h('button', {
      class: 'sky-chip', type: 'button', dataset: { label: value }, 'aria-pressed': 'false', onclick: () => tap(value),
    }, word));
    const el = h('div', { class: 'sky-correct' },
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

    return { el, stop: follow(entry.id, refresh) };
  }

  /**
   * The bridge took a correction: the entry changes kind, and its card (its chip and colour), the chips' counts, the summary and the strip follow
   * it at once. A card the filters no longer show fades out of the grid, the page keeping its place (an open player stays on its light); one they
   * show again (the person changed their mind) comes back to its place.
   */
  function applyCorrection(entry, value, answer) {
    const before = { ...entry };
    const back = normalizeEntry(answer);
    const same = back && back.id === entry.id;
    entry.correction = same ? back.correction ?? value : value;
    entry.display = same ? back.display : OWN_LABEL[value] ?? entry.label;
    log.counts = countsAfter(log.counts, before, entry) ?? log.counts;
    // A light the person named is no longer one of the lights that moved together: the others' cards say so (the bridge regroups them on the
    // next read).
    const members = entry.group ? together.get(entry.group) ?? [] : [];
    together = groupsOf(log.entries);
    grid.setGroups(together);
    drawSummary();
    drawFilters();
    drawStrip();
    grid.refresh(entry);
    for (const id of members) {
      const member = log.entries.find((candidate) => candidate.id === id);
      if (member && member !== entry) grid.refresh(member);
    }
    if (!matchesFilters(entry, narrowing())) grid.leave(entry.id);
    else if (!grid.has(entry.id)) drawGrid({ keepPlace: true });
    for (const refresh of [...(refreshers.get(entry.id) ?? [])]) refresh();
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
    replace(statusBox, h('summary', null, TEXT.status), h('div', { class: 'sky-status-lines' }, lines.map(([classes, text]) => h('p', { class: classes }, text))));
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

  /**
   * The entry the address names (or the light it is a part of, joined from pieces): shown even when the filters would leave it out (they are cleared),
   * its card brought into view and marked.
   */
  function showTarget() {
    const named = target;
    target = null;
    if (!named) return;
    const entry = log.entries.find((candidate) => candidate.id === named) ?? log.entries.find((candidate) => candidate.parts.includes(named));
    if (!entry) return;
    if (!matchesFilters(entry, narrowing())) {
      group = null;
      choice = gridChoice({ ...choice, kinds: [], pictures: false });
      remember.write(choice);
      writeOut();
      drawFilters();
      fadeStrip();
      drawGrid();
    }
    const card = grid.reveal(entry.id);
    if (!card) return;
    card.classList.add('sky-target');
    card.scrollIntoView?.({ block: 'center' });   // at once: the grid gives back cards that are far from the screen
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
    const camera = cameraById(current);
    summaryEl = h('p', { class: 'sky-summary', role: 'status' });
    statusBox = h('details', { class: 'sky-status' });
    statusBox.open = false;   // folded under the summary until the person opens it
    noteBox = h('div', { class: 'sky-note' });
    statusKey = '';
    noteOff = null;
    const conditions = conditionsText(log.conditions, zoneName, log.view);
    replace(body,
      h('header', { class: 'sky-top' },
        h('h2', null, `${TEXT.titlePrefix}${camera?.name ?? ''}`),
        noteBox, summaryEl,
        conditions ? h('p', { class: 'sky-conditions' }, conditions) : null,
        drawLearning(),
        statusBox),
      dock,
      grid.el);
    drawNote();
    drawSummary();
    drawStatus();
    drawFilters();
    drawStrip();
    drawGrid();
    showTarget();
    layout();
    nextFrame(() => {
      if (destroyed || !log) return;
      if (Math.round(Number(stripBox.clientWidth) || 0) > 0 && Math.round(stripBox.clientWidth) !== stripWidth) {
        drawStrip();
        layout();
      }
      queueBand();
    });
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

  // Scrolling moves the strip's band (a scroll event comes once a frame at most); a new width draws the strip, measures the cards and puts the
  // dock under the page's bar again.
  const onScroll = () => drawBand();
  const onResize = () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => {
      if (destroyed) return;
      if (log && phase === 'ready' && Math.round(Number(stripBox.clientWidth) || 0) !== stripWidth) drawStrip();
      layout();
      grid.remeasure();
      queueBand();
    }, 120);
  };
  window.addEventListener?.('scroll', onScroll, { passive: true });
  window.addEventListener?.('resize', onResize);

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
      clearTimeout(resizeTimer);
      window.removeEventListener?.('scroll', onScroll);
      window.removeEventListener?.('resize', onResize);
      stopCameras();
      panel?.destroy();
      grid.destroy();
      player?.close?.();     // leaving the page stops the clip player and frees its stream
      player = null;
    },
  };
}

const round = (value) => Math.round(value * 100) / 100;

/** The route: #/sky, #/sky/<camera> and ?night=yyyy-MM-dd&view=night|day&entry=<id>&kinds=…&sort=…&pictures=1. Writing the address replaces the entry, so Back leaves the page. */
export function renderSkyLog({ params = [], setTitle } = {}) {
  setTitle?.(SKY_TEXT.page);
  const page = createSkyLogPage({
    cameraID: params[0] ?? null,
    query: params[1] ?? '',
    writeAddress: (address) => { try { history.replaceState(history.state, '', `#/${address}`); } catch { /* the address stays as it is */ } },
  });
  return { el: page.el, destroy: () => page.destroy() };
}
