// The camera page's Sky Watcher card: the switch "Watch the sky", the questions it asks the first time it is turned on (which way the camera
// faces, where the box is, the lens layout), what the bridge refuses and why (no place for the box, no folder for the sky log, a battery
// camera) in place, and, while it is on, the aim by lens, the stream it watches and how much the box has learned of this sky.
// `createLocationFields` is the place's two fields and the browser's button, and `createSkySettingsCard` is the Setup panel of the Sky Watcher page
// (where the box is, the flight feed with "Find a feed", and the AI's daily limit; sky-setup.js loads it): both use it.
import { get, patch, post } from '../api.js';
import { h, replace } from '../dom.js';
import { icon } from '../icons.js';
import { inlineError } from './common.js';
import { COMPASS, SKY_TEXT, aimLines, compassIndex, defaultLensLayout, learningText, refusalOf, streamText } from './sky-model.js';

const TEXT = SKY_TEXT.card;
const AI_LIMIT = { min: 1, max: 1000 };   // the most questions a day Sky Watcher may ask the AI (the bridge's range)
const DEFAULT_AI_LIMIT = 50;
const ASSUME_MS = 15_000;       // a save the bridge answered is believed this long, until the camera's own word agrees
const LOCATION_WAIT_MS = 10_000;   // a browser that has not answered by then is taken to have said no (some never call back when not allowed)
const realTimers = { setTimeout: (fn, ms) => setTimeout(fn, ms), clearTimeout: (id) => clearTimeout(id) };
let sequence = 0;

const round4 = (value) => Math.round(value * 10_000) / 10_000;
const browserLocation = () => (typeof navigator === 'undefined' ? undefined : navigator.geolocation);
const isPlace = (place) => Number.isFinite(place?.latitude) && Number.isFinite(place?.longitude);
const samePlace = (a, b) => isPlace(a) && isPlace(b) && a.latitude === b.latitude && a.longitude === b.longitude;
const enabledIn = (camera) => camera?.skyDetector?.enabled === true;

/** A coordinate as typed ("40.5", "-100.25", "−100", with the minus sign or without) within ±`limit`; null for anything else. */
function parseCoordinate(text, limit) {
  const clean = text.trim().replace(/^−/, '-');
  if (!/^[+-]?\d+(\.\d+)?$/.test(clean)) return null;
  const value = Number(clean);
  return Math.abs(value) <= limit ? value : null;
}

/**
 * Where the box is: its title, "Kept only on this box.", the button "Use this browser’s location" and the fields Latitude and Longitude.
 * -> { el, read(), set(place), focus(), say(text), dirty(), destroy() }
 *   read()   the place typed ({ latitude, longitude }), null when both fields are empty, undefined when they are not a place (each field
 *            that is wrong says so)
 *   set(p)   fills the fields from a place (null empties them)
 *   say(t)   a line under the button (the browser's refusal); '' takes it away
 *   dirty()  something was typed since the fields were last filled by `set`
 *   onFilled(place)  the browser's answer filled the fields
 *   geolocate        navigator.geolocation, or what a test gives
 *   timers           { setTimeout, clearTimeout }: the 10 s the browser has to answer
 * "Use this browser’s location" fills the fields from the browser. A browser that has no location to give, says no, or has not answered within
 * 10 s gets a plain sentence beside the fields: type it in instead. An answer that comes later still fills them.
 */
export function createLocationFields({ geolocate = browserLocation(), onFilled = () => {}, onChange = () => {}, timers = realTimers } = {}) {
  const id = `sky-place-${++sequence}`;
  let destroyed = false;
  let typed = false;
  const latitudeError = h('span', { class: 'error', id: `${id}-latitude-error`, role: 'alert', hidden: true });
  const longitudeError = h('span', { class: 'error', id: `${id}-longitude-error`, role: 'alert', hidden: true });
  const note = h('p', { class: 'small sky-place-note', role: 'status', hidden: true });
  const edit = () => { typed = true; };
  const input = (name, errorEl) => h('input', {
    type: 'text', inputmode: 'decimal', autocomplete: 'off', spellcheck: 'false', value: '', id: `${id}-${name}`, dataset: { field: name }, 'aria-describedby': errorEl.id,
    oninput: edit, onchange: () => { edit(); onChange(); },
  });
  const latitude = input('latitude', latitudeError);
  const longitude = input('longitude', longitudeError);

  function say(text) {
    note.textContent = text;
    note.hidden = !text;
    note.dataset.tone = text === TEXT.notShared ? 'refused' : '';
  }

  function fail(errorEl, input, text) {
    errorEl.textContent = text;
    errorEl.hidden = !text;
    if (text) input.setAttribute('aria-invalid', 'true');
    else input.removeAttribute('aria-invalid');
  }

  function set(place) {
    latitude.value = isPlace(place) ? String(place.latitude) : '';
    longitude.value = isPlace(place) ? String(place.longitude) : '';
    typed = false;
    fail(latitudeError, latitude, '');
    fail(longitudeError, longitude, '');
  }

  function read() {
    fail(latitudeError, latitude, '');
    fail(longitudeError, longitude, '');
    if (!latitude.value.trim() && !longitude.value.trim()) return null;
    const north = parseCoordinate(latitude.value, 90);
    const east = parseCoordinate(longitude.value, 180);
    if (north === null) fail(latitudeError, latitude, TEXT.latitudeRange);
    if (east === null) fail(longitudeError, longitude, TEXT.longitudeRange);
    return north === null || east === null ? undefined : { latitude: north, longitude: east };
  }

  let asking = null;   // the 10 s the browser has to answer

  function stopAsking() {
    if (asking !== null) timers.clearTimeout(asking);
    asking = null;
  }

  function useBrowser() {
    say('');
    stopAsking();
    if (typeof geolocate?.getCurrentPosition !== 'function') return say(TEXT.notShared);
    say(TEXT.finding);
    const refused = () => { stopAsking(); if (!destroyed) say(TEXT.notShared); };
    // The browser's own timeout starts only once the person allowed it, and a page the box's policy keeps from asking may hear nothing at all.
    asking = timers.setTimeout(() => { asking = null; if (!destroyed) say(TEXT.notShared); }, LOCATION_WAIT_MS);
    try {
      geolocate.getCurrentPosition((position) => {
        if (destroyed) return;
        const { latitude: north, longitude: east } = position?.coords ?? {};
        if (!Number.isFinite(north) || !Number.isFinite(east)) return refused();
        stopAsking();
        set({ latitude: round4(north), longitude: round4(east) });
        typed = true;
        say('');
        onFilled(read());
        return undefined;
      }, refused, { enableHighAccuracy: false, timeout: LOCATION_WAIT_MS, maximumAge: 600_000 });
    } catch {
      refused();
    }
    return undefined;
  }

  const el = h('fieldset', { class: 'sky-group sky-place' },
    h('legend', null, TEXT.locationTitle),
    h('p', { class: 'small muted' }, TEXT.locationKept),
    h('div', { class: 'row' }, h('button', { class: 'btn small', type: 'button', onclick: useBrowser }, TEXT.useBrowser)),
    note,
    h('div', { class: 'inline-fields' },
      h('div', { class: 'field' }, h('label', { for: latitude.id }, TEXT.latitude), latitude, latitudeError),
      h('div', { class: 'field' }, h('label', { for: longitude.id }, TEXT.longitude), longitude, longitudeError)));

  return {
    el, read, set, say,
    dirty: () => typed,
    focus: () => latitude.focus?.(),
    destroy() { destroyed = true; stopAsking(); },
  };
}

/**
 * The camera page's Sky Watcher card. It follows the camera in place (`update(camera)`: the page is not built again, and what is being
 * typed stays). -> { el, update(camera), destroy() }
 *   save(settings)       the camera's sky settings { enabled, facing, tilt, groundPercent, nightProfile, lensLayout }; resolves once the bridge
 *                        took them, rejects with its sentence (an ApiError) when it refused
 *   saveLocation(place)  PATCH settings { sky: { location } }: where the box is, once for the whole bridge
 *   settings()           GET settings (its `sky.location` fills the fields)
 *   geolocate            the browser's location service, or what a test gives; timers: { setTimeout, clearTimeout } for its 10 s
 */
export function createSkyDetectorCard(camera, { save, saveLocation = (place) => patch('settings', { sky: { location: place } }), settings = () => get('settings'),
  geolocate = browserLocation(), timers = realTimers } = {}) {
  let current = camera;
  let box;                         // { location } as the bridge keeps it; null when it could not be read, undefined until it answers
  let asking = false;              // the questions are open: the person is turning it on for the first time
  let failed = false;              // and the last start was refused (or the place was not one): the switch is back to off
  let busy = null;                 // 'on' | 'off': the bridge is answering a start or a stop
  let assumed = null;              // true | false: what the bridge took, until the camera's own word agrees
  let assumedAt = 0;
  let message = null;              // { text, needs } shown in place
  let shownMessage = null;
  let sending = false;             // a save of the card's settings is on its way
  let again = false;               // and they changed since
  let seen = '';                   // the camera's settings the controls were last filled from
  let statusKey = '';
  let destroyed = false;
  const dirty = new Set();         // controls edited and not saved yet
  let facing = 0;
  let layout = 'single';
  let tiltValue = 20;
  let groundValue = 12;

  const id = `sky-${++sequence}`;
  const isOn = () => (assumed !== null && Date.now() - assumedAt < ASSUME_MS ? assumed : enabledIn(current));

  // MARK: Pieces

  const input = h('input', { type: 'checkbox', role: 'switch', onchange: () => (input.checked ? turnOn() : turnOff()) });
  const row = h('label', { class: 'switch-row' },
    h('span', { class: 'text' }, h('span', { class: 'title' }, TEXT.switchTitle), h('span', { class: 'desc' }, TEXT.switchDesc)),
    h('span', { class: 'switch' }, input));
  const leaves = h('p', { class: 'small muted sky-leaves' }, TEXT.leaves);
  const notes = h('div', { class: 'sky-notes' });

  const compass = h('div', { class: 'sky-segments sky-compass', role: 'group', 'aria-label': TEXT.facingTitle },
    COMPASS.map(([word, degrees, name]) => h('button', {
      class: 'sky-segment', type: 'button', title: name, 'aria-label': name, dataset: { facing: String(degrees) },
      onclick: () => { facing = degrees; drawCompass(); changed(); },
    }, word)));
  const lenses = h('div', { class: 'sky-segments sky-lenses', role: 'group', 'aria-label': TEXT.lensTitle },
    [['single', TEXT.lensSingle], ['dual', TEXT.lensDual]].map(([value, label]) => h('button', {
      class: 'sky-segment', type: 'button', dataset: { layout: value }, onclick: () => { layout = value; drawLayout(); changed(); },
    }, label)));
  const numberField = (name, label, hint, min, max) => {
    const fieldId = `${id}-${name}`;
    const control = h('input', {
      type: 'number', inputmode: 'numeric', min, max, step: 1, value: '', id: fieldId, dataset: { field: name }, 'aria-describedby': `${fieldId}-hint`,
      oninput: () => dirty.add(name), onchange: () => { settleNumbers(); changed(); },
    });
    return { control, el: h('div', { class: 'field' }, h('label', { for: fieldId }, label), control, h('span', { class: 'hint', id: `${fieldId}-hint` }, hint)) };
  };
  const tilt = numberField('tilt', TEXT.tiltTitle, TEXT.tiltHint, 0, 90);
  const ground = numberField('ground', TEXT.groundTitle, TEXT.groundHint, 0, 60);
  const place = createLocationFields({
    geolocate,
    timers,
    onFilled: () => { if (!asking && isOn()) savePlace(); },
    onChange: () => { if (!asking && isOn()) savePlace(); },
  });
  const start = h('button', { class: 'btn primary sky-start', type: 'button', onclick: () => begin() }, TEXT.start);
  const setup = h('div', { class: 'sky-setup', hidden: true },
    h('fieldset', { class: 'sky-group' }, h('legend', null, TEXT.facingTitle), compass),
    h('div', { class: 'inline-fields' }, tilt.el, ground.el),
    h('fieldset', { class: 'sky-group' }, h('legend', null, TEXT.lensTitle), lenses, h('span', { class: 'hint' }, TEXT.lensHint)),
    place.el,
    h('div', { class: 'row' }, start));
  const status = h('div', { class: 'sky-status', hidden: true });
  const openLink = h('a', { class: 'btn small sky-open', href: `#/sky/${camera.id}`, hidden: true }, TEXT.openLog);
  // While it is on, what it sees comes first (the aim, the stream, what it has learnt, the way to its log) and the settings follow.
  const el = h('div', { class: 'card sky-card' }, h('h2', null, TEXT.title), row, leaves, notes, status, h('div', { class: 'row sky-open-row' }, openLink), setup);

  // MARK: What the controls hold

  function drawCompass() {
    const chosen = compassIndex(facing);
    for (const button of compass.children) button.setAttribute('aria-pressed', String(Number(button.dataset.facing) === chosen * 45));
  }

  function drawLayout() {
    for (const button of lenses.children) button.setAttribute('aria-pressed', String(button.dataset.layout === layout));
  }

  /** The controls filled from the camera's settings, unless the person is in the middle of changing them (or the camera's word has not changed). */
  function syncFields(force = false) {
    const saved = current.skyDetector;
    const snapshot = JSON.stringify([saved?.facing, saved?.tilt, saved?.groundPercent, saved?.lensLayout, defaultLensLayout(current)]);
    if (!force && (snapshot === seen || dirty.size > 0 || sending || asking)) return;
    seen = snapshot;
    facing = Number.isFinite(saved?.facing) ? saved.facing : 0;
    tiltValue = Number.isFinite(saved?.tilt) ? saved.tilt : 20;
    groundValue = Number.isFinite(saved?.groundPercent) ? saved.groundPercent : 12;
    tilt.control.value = String(tiltValue);
    ground.control.value = String(groundValue);
    layout = defaultLensLayout(current);
    dirty.clear();
    drawCompass();
    drawLayout();
  }

  /** The two numbers within their ranges, written back as they are kept (an empty or odd entry is what it was). */
  function settleNumbers() {
    const settle = (control, fallback, min, max) => {
      const text = control.value.trim();
      const value = text === '' ? NaN : Number(text);
      const kept = Number.isFinite(value) ? Math.min(max, Math.max(min, Math.round(value))) : fallback;
      control.value = String(kept);
      return kept;
    };
    tiltValue = settle(tilt.control, tiltValue, 0, 90);
    groundValue = settle(ground.control, groundValue, 0, 60);
  }

  const values = (enabled) => ({
    enabled, facing, tilt: tiltValue, groundPercent: groundValue, nightProfile: current.skyDetector?.nightProfile !== false, lensLayout: layout,
  });

  // MARK: Turning it on and off

  function say(next) {
    message = next;
    drawMessage();
  }

  function refuse(error) {
    const refusal = refusalOf(error);
    say(refusal);
    if (refusal.needs === 'location') place.focus();
  }

  /** The first time (or with no place on the box), the questions come first; otherwise it starts with what the camera had. */
  function turnOn() {
    say(null);
    const never = !(current.skyDetector && typeof current.skyDetector === 'object');
    const noPlace = box !== undefined && box !== null && box.location === null;
    if (asking) failed = false;
    if (!asking && (never || noPlace)) {
      asking = true;
      failed = false;
      draw();
      return;
    }
    begin();
  }

  function turnOff() {
    if (asking && !isOn()) {
      asking = false;
      failed = false;
      say(null);
      draw();
      return;
    }
    stop();
  }

  async function begin() {
    if (busy || destroyed) return;
    say(null);
    settleNumbers();
    const typedPlace = place.read();
    if (typedPlace === undefined) {
      asking = true;
      failed = true;
      draw();
      return;
    }
    busy = 'on';
    failed = false;
    draw();
    try {
      if (typedPlace && !samePlace(typedPlace, box?.location)) {
        await saveLocation(typedPlace);
        box = { location: typedPlace };
      }
      await save(values(true));
      assumed = true;
      assumedAt = Date.now();
      asking = false;
    } catch (error) {
      if (destroyed) return;
      asking = true;
      failed = true;
      refuse(error);
    }
    busy = null;
    if (!destroyed) draw();
  }

  async function stop() {
    if (busy || destroyed) return;
    say(null);
    busy = 'off';
    draw();
    try {
      await save(values(false));
      assumed = false;
      assumedAt = Date.now();
    } catch (error) {
      if (destroyed) return;
      refuse(error);
    }
    busy = null;
    if (!destroyed) draw();
  }

  // MARK: Changing it while it is on

  /** A control changed: while it is on, everything is saved (one save at a time; the newest values go once the one before is answered). */
  function changed() {
    if (asking || !isOn()) return;
    saveFields();
  }

  async function saveFields() {
    if (sending) { again = true; return; }
    sending = true;
    say(null);
    try {
      do {
        again = false;
        await save(values(true));
      } while (again && !destroyed);
      dirty.clear();
    } catch (error) {
      if (destroyed) return;
      refuse(error);
      sending = false;
      syncFields(true);
    }
    sending = false;
    if (!destroyed) draw();
  }

  async function savePlace() {
    const typedPlace = place.read();
    if (!typedPlace || samePlace(typedPlace, box?.location)) return;
    say(null);
    try {
      await saveLocation(typedPlace);
      box = { location: typedPlace };
    } catch (error) {
      if (destroyed) return;
      refuse(error);
      place.set(box?.location ?? null);
    }
  }

  // MARK: Drawing

  function drawMessage() {
    if (shownMessage === message) return;
    shownMessage = message;
    replace(notes, message ? [
      inlineError(message.text),
      message.needs === 'folder' ? h('p', { class: 'small' }, h('a', { href: '#/settings/recording' }, TEXT.folderLink)) : null,
      message.needs === 'plugin' ? h('p', { class: 'small' }, h('a', { href: '#/plugins' }, TEXT.pluginLink)) : null,
    ] : null);
  }

  function drawStatus() {
    const sky = current.status?.sky;
    const lines = [];
    if (!sky || typeof sky !== 'object') {
      lines.push(['p', 'small muted', TEXT.waiting]);
    } else {
      for (const line of aimLines(sky.aim, defaultLensLayout(current))) lines.push(['p', 'sky-aim', line]);
      lines.push(['p', 'small muted', TEXT.aimMore]);
      if ((sky.aim?.quality ?? 'rough') === 'rough') lines.push(['p', 'small muted', TEXT.looseFlights]);
      if (sky.aim?.note) lines.push(['p', 'small', sky.aim.note]);
      const stream = streamText(sky);
      if (stream) lines.push(['p', 'small muted sky-stream', stream]);
      const learning = learningText(sky.learning);
      if (learning) lines.push(['p', 'small sky-learning', learning]);
      if (typeof sky.problem === 'string' && sky.problem.trim()) lines.push(['problem', '', sky.problem.trim()]);
    }
    const key = JSON.stringify(lines);
    if (key === statusKey) return;
    statusKey = key;
    replace(status, lines.map(([kind, classes, text]) => (kind === 'problem'
      ? h('div', { class: 'banner warning' }, icon('alert'), h('div', { class: 'text' }, text))
      : h('p', { class: classes }, text))));
  }

  function draw() {
    const on = isOn();
    const switchOn = busy === 'on' || (busy !== 'off' && (on || (asking && !failed)));
    input.checked = switchOn;
    setup.hidden = !(on || asking);
    start.hidden = !(asking && !on);
    start.textContent = busy === 'on' ? TEXT.working : TEXT.start;
    if (busy) start.setAttribute('aria-disabled', 'true');
    else start.removeAttribute('aria-disabled');
    status.hidden = !on;
    openLink.hidden = !(current.skyDetector && typeof current.skyDetector === 'object');
    drawMessage();
    drawStatus();
  }

  // The place the box has fills the fields, unless something was typed meanwhile.
  Promise.resolve().then(settings).then((answer) => {
    if (destroyed) return;
    const saved = answer?.sky?.location;
    box = { location: isPlace(saved) ? { latitude: saved.latitude, longitude: saved.longitude } : null };
    if (!place.dirty()) place.set(box.location);
    draw();
  }, () => {
    if (!destroyed) box = null;
  });

  syncFields(true);
  draw();

  return {
    el,
    /** The camera as the store has it now: its status moves the lines, its sky settings move the controls (unless they are being changed). */
    update(next) {
      current = next;
      if (assumed !== null && enabledIn(next) === assumed) assumed = null;
      syncFields();
      draw();
    },
    destroy() {
      destroyed = true;
      place.destroy();
    },
  };
}

/**
 * The Sky Watcher page's Setup panel: where the box is (kept only on the box), the address of a flight feed, with "Find a feed", which lists what
 * answers on the network, and the most questions a day the Sky Watcher may ask the AI. A `<details>`: open until the box has a place, and folded
 * away after that unless the person opens it (`open` says otherwise). Made once by sky-setup.js, which tells it the settings again when they change
 * elsewhere (`update(settings)`): what is being typed stays. -> { el, update(settings), destroy() }
 *   save(partial)   PATCH settings { sky: partial } -> the settings the bridge answers with; find() POST sky/feeds/find -> { feeds }
 *   onSettings(s)   the page takes the settings the bridge answered with
 */
export function createSkySettingsCard(settings, { onSettings = () => {}, save = (partial) => patch('settings', { sky: partial }), find = () => post('sky/feeds/find'),
  geolocate = browserLocation(), timers = realTimers, open = !isPlace(settings?.sky?.location) } = {}) {
  const T = SKY_TEXT.settings;
  let saved = { location: null, feed: '', limit: DEFAULT_AI_LIMIT };
  let feedTyped = false;           // the address field was typed in since it was last filled from the settings
  let limitTyped = false;          // and so was the limit
  let feeds = null;                // what Find a feed found (a list, empty for none); null before it was asked
  let working = false;
  let destroyed = false;
  const id = `sky-settings-${++sequence}`;

  const place = createLocationFields({ geolocate, timers });
  const feed = h('input', {
    type: 'url', inputmode: 'url', autocomplete: 'off', autocapitalize: 'off', spellcheck: 'false', value: '', id: `${id}-feed`, dataset: { field: 'feed' }, 'aria-describedby': `${id}-hint`,
    oninput: () => { feedTyped = true; },
  });
  const limit = h('input', {
    type: 'number', inputmode: 'numeric', min: AI_LIMIT.min, max: AI_LIMIT.max, step: 1, value: '', id: `${id}-limit`, dataset: { field: 'limit' }, 'aria-describedby': `${id}-limit-hint`,
    oninput: () => { limitTyped = true; },
  });
  const problems = h('div', { class: 'sky-problems' });
  const status = h('p', { class: 'small sky-saved', role: 'status', hidden: true });
  const found = h('div', { class: 'sky-found' });
  const removeButton = h('button', { class: 'btn small danger', type: 'button', hidden: true, onclick: () => run(() => save({ location: null }), T.locationRemoved, { place: true }) }, T.removeLocation);
  const findButton = h('button', { class: 'btn small', type: 'button', onclick: () => findFeeds() }, T.find);
  const el = h('details', { class: 'card sky-settings-card' },
    h('summary', null, h('h2', null, T.title), h('span', { class: 'small muted sky-gist' }, T.gist)),
    h('p', { class: 'desc' }, T.desc),
    place.el,
    h('div', { class: 'row' }, h('button', { class: 'btn small', type: 'button', onclick: () => saveLocation() }, T.saveLocation), removeButton),
    h('fieldset', { class: 'sky-group' },
      h('legend', null, T.feedTitle),
      h('div', { class: 'field' }, h('label', { for: feed.id }, T.feedLabel), feed, h('span', { class: 'hint', id: `${id}-hint` }, T.feedHint)),
      h('div', { class: 'row' }, h('button', { class: 'btn small', type: 'button', onclick: () => saveFeed() }, T.save), findButton), found),
    h('fieldset', { class: 'sky-group' },
      h('legend', null, T.aiTitle),
      h('div', { class: 'field' }, h('label', { for: limit.id }, T.aiLabel), limit,
        h('span', { class: 'hint', id: `${id}-limit-hint` }, T.aiHint, ' ', h('a', { href: '#/settings/ai' }, T.aiSetup))),
      h('div', { class: 'row' }, h('button', { class: 'btn small', type: 'button', onclick: () => saveLimit() }, T.saveLimit))),
    problems, status);
  el.open = open === true;

  function say(text) {
    status.textContent = text;
    status.hidden = !text;
  }

  /** A refusal (the bridge's sentence) or a sentence of the card's own, in place; nothing takes it away. */
  function problem(error) {
    replace(problems, error ? inlineError(typeof error === 'string' ? error : refusalOf(error).text) : null);
  }

  /** Takes what the settings say; what is being typed is left alone unless `force` (what was just saved is what the bridge has). */
  function adopt(next, { place: forcePlace = false, feed: forceFeed = false, limit: forceLimit = false } = {}) {
    const sky = next?.sky ?? {};
    saved = {
      location: isPlace(sky.location) ? { latitude: sky.location.latitude, longitude: sky.location.longitude } : null,
      feed: typeof sky.flightFeedURL === 'string' ? sky.flightFeedURL : '',
      limit: Number.isInteger(sky.aiDailyLimit) ? sky.aiDailyLimit : DEFAULT_AI_LIMIT,
    };
    if (forcePlace || !place.dirty()) place.set(saved.location);
    if (forceFeed || !feedTyped) { feed.value = saved.feed; feedTyped = false; }
    if (forceLimit || !limitTyped) { limit.value = String(saved.limit); limitTyped = false; }
    removeButton.hidden = !saved.location;
  }

  /** One change: the bridge answers with the settings, which the page takes; a refusal is said in place and nothing typed is lost. */
  async function run(action, done, force = {}) {
    if (working || destroyed) return;
    working = true;
    problem(null);
    say('');
    try {
      const answer = await action();
      if (destroyed) return;
      onSettings(answer);
      adopt(answer, force);
      say(done);
    } catch (error) {
      if (destroyed) return;
      problem(error);
    }
    working = false;
  }

  function saveLocation() {
    const typed = place.read();
    if (typed === undefined) return undefined;
    if (typed === null) { place.focus(); return undefined; }
    return run(() => save({ location: typed }), T.locationSaved, { place: true });
  }

  function saveFeed() {
    const typed = feed.value.trim();
    return run(() => save({ flightFeedURL: typed || null }), T.saved, { feed: true });
  }

  /** The limit as typed, a whole number from 1 to 1,000; anything else is said and nothing is sent. */
  function saveLimit() {
    const text = limit.value.trim();
    const count = /^\d+$/.test(text) ? Number(text) : NaN;
    if (!(count >= AI_LIMIT.min && count <= AI_LIMIT.max)) {
      problem(T.aiRange);
      return undefined;
    }
    return run(() => save({ aiDailyLimit: count }), T.aiSaved, { limit: true });
  }

  function drawFound() {
    if (feeds === null) return replace(found);
    if (!feeds.length) return replace(found, h('p', { class: 'small muted' }, T.noFeeds));
    return replace(found, h('ul', { class: 'sky-feeds' }, feeds.map((url) => h('li', { class: 'sky-feed' },
      h('code', null, url), h('button', { class: 'btn small', type: 'button', onclick: () => useFeed(url) }, T.useFeed)))));
  }

  async function findFeeds() {
    if (working || destroyed) return;
    working = true;
    problem(null);
    say(T.finding);
    try {
      const answer = await find();
      if (destroyed) return;
      feeds = Array.isArray(answer?.feeds) ? answer.feeds.filter((url) => typeof url === 'string') : [];
      say('');
    } catch (error) {
      if (destroyed) return;
      say('');
      problem(error);
    }
    working = false;
    drawFound();
  }

  function useFeed(url) {
    feed.value = url;
    feedTyped = true;
    return saveFeed();
  }

  adopt(settings);
  return {
    el,
    update: (next) => adopt(next),
    destroy() { destroyed = true; place.destroy(); },
  };
}
