// One camera: a quick look, its state, and everything you can change. Changes save by themselves a moment after you make them.
import { del, get, patch, post } from '../api.js';
import { confirmDialog, debounce, h, promptDialog, replace, toast } from '../dom.js';
import { icon } from '../icons.js';
import { timeAgo } from '../format.js';
import { showLabel } from '../labels.js';
import { createLivePlayer, liveSupported, openLive } from '../live/mux.js';
import { createStraightenedView, isOn, landing, largestStretch } from '../live/straighten.js';
import { loadNVR, nvrSupported } from '../nvr/lite.js';
import { stampText } from '../stamp.js';
import { putCamera, store, subscribe } from '../store.js';
import { aiNotices, aiSettingsView } from './ai-settings.js';
import { SHOW_SECURITY_EVENT, banners } from './banners.js';
import { cameraSetupCard, cameraSetupDialog, localOnlyCard, removalNote, RESTART_TEXT, restartControl, setupSupported } from './camera-setup.js';
import { batteryCharging, batteryPill } from './cameras.js';
import { backLink, field, homeState, inlineError, selectField, statePill, switchRow } from './common.js';
import { createNightVisionCard } from './night-vision.js';
import { pairingPanel } from './pairing.js';
import { createSecurityCard, securityBadge, securityView } from './security.js';
import { ARCHIVE_PAGE, concernWord, eventDescription, eventKind } from './wall-events-model.js';

const SENSORS = [
  ['person', 'Person Detection', 'person', 'Occupancy sensor (stays on for 60 seconds)'],
  ['vehicle', 'Vehicle Detection', 'vehicle', 'Occupancy sensor (stays on for 60 seconds)'],
  ['animal', 'Animal Detection', 'animal', 'Occupancy sensor (stays on for 60 seconds)'],
  ['package', 'Package Detection', 'package', 'Occupancy sensor (stays on for 60 seconds)'],
  ['dayNight', 'Day and Night', 'dayNight', 'Light sensor (night reads 1 lux, day 1000 lux)'],
  ['digitalInputs', 'Alarm Inputs', 'digitalInput', 'Contact sensor'],
  ['temperature', 'Temperature', 'temperature', 'Temperature sensor'],
  ['humidity', 'Humidity', 'humidity', 'Humidity sensor'],
];
const WEBHOOK_KINDS = new Set(['person', 'vehicle', 'animal', 'package']);
const MOTION_SOURCES = [
  ['cameraEvents', 'Camera events', 'Uses the camera’s own motion detection.'],
  ['softMotion', 'Built-in motion detection', 'Camera Bridge compares frames from the camera’s sub stream.'],
  ['webhook', 'Webhook', 'Another system reports motion to Camera Bridge’s webhook.'],
];
const BITRATES = [['auto', 'Automatic'], ['mbps1', '1 Mbps'], ['mbps2', '2 Mbps'], ['mbps4', '4 Mbps'], ['mbps6', '6 Mbps'], ['mbps8', '8 Mbps']];

function sensorsFor(camera) {
  const events = new Set(camera.capabilities?.events || []);
  return SENSORS.filter(([key, , event]) => events.has(event) || (camera.motionSource === 'webhook' && WEBHOOK_KINDS.has(key)) || (!camera.capabilities && camera.sensors[key]))
    .map(([key, title, event, accessory]) => ({ key, title, accessory, fromWebhook: !events.has(event) && camera.motionSource === 'webhook' && WEBHOOK_KINDS.has(key) }));
}

function cameraEventsText(camera) {
  const s = camera.status;
  if (camera.vendor === 'rtsp') return 'None — RTSP cameras send no events';
  if (camera.vendor === 'go2rtc') return 'None — cloud cameras send no events here; built-in motion detection is used';
  return s?.eventChannelConnected ? 'Connected' : 'Not connected';
}

function viewersText(s) {
  const total = (s?.liveViewers || 0) + (s?.appViewers || 0);
  return total === 0 ? 'No viewers' : total === 1 ? '1 viewer' : `${total} viewers`;
}

function viewersDetail(s) {
  const home = s?.liveViewers || 0, app = s?.appViewers || 0;
  if (!home && !app) return 'Nobody is watching right now';
  if (!app) return 'Watching in the Home app';
  if (!home) return app === 1 ? '1 viewer in Camera Bridge' : `${app} viewers in Camera Bridge`;
  return `${home} in the Home app · ${app} in Camera Bridge`;
}

function describeSession(session) {
  const size = session.width ? ` ${session.width}×${session.height}` : '';
  return `${session.usesSubStream ? 'Sub stream' : 'Main stream'}${size}, ${session.isPassthrough ? 'original' : 'transcoded'}${session.bitrateKbps ? `, ${Math.round(session.bitrateKbps)} kbit/s` : ''}`;
}

const STRAIGHTEN_LINE = 'Applies everywhere this camera is seen: live view, the Monitor, recordings, saved clips and Apple Home. Recordings keep the camera’s original picture.';

/** The quality card's sentence while the camera's picture is straightened (Apple Home's video then always goes through the encoder). */
const encoderNote = (camera) => (isOn(camera.pictureCorrection) ? ' Straighten the picture is on, so Apple Home’s live view and recordings always use the video encoder.' : '');

/** How long the Straighten card waits for arrow keys to pause before it saves (a range input sends a change for every step). */
const KEY_PAUSE_MS = 400;

/** A stored Straighten or Level (−0.60…0.60, −0.40…0.40) as its slider shows it (−60…60, −40…40). */
const sliderValue = (value) => Math.round((Number(value) || 0) * 100);

/**
 * Where a `width` × `height` picture shows in a `boxWidth` × `boxHeight` box with object-fit `fit` (contain when unknown) and centred, as
 * fractions of the box: { left, top, width, height } (beyond 0…1 where cover cuts it). The whole box for fill, or while a size is unknown.
 */
function pictureArea(fit, boxWidth, boxHeight, width, height) {
  if (fit === 'fill' || !(boxWidth > 0 && boxHeight > 0 && width > 0 && height > 0)) return { left: 0, top: 0, width: 1, height: 1 };
  const contain = Math.min(boxWidth / width, boxHeight / height);
  const scale = fit === 'cover' ? Math.max(boxWidth / width, boxHeight / height) : fit === 'none' ? 1 : fit === 'scale-down' ? Math.min(1, contain) : contain;
  const across = width * scale / boxWidth, down = height * scale / boxHeight;
  return { left: (1 - across) / 2, top: (1 - down) / 2, width: across, height: down };
}

/** The camera page's address (app.js): #/camera/<id>, and #/camera/<id>/security, which brings its Security card into view (the Internet
 *  guard's notice opens it, banners.js securityAddress). */
export const CAMERA_ROUTE = /^camera\/([0-9A-Fa-f-]{36})(?:\/(security))?$/;

// MARK: AI descriptions

const AI_RECHECK_MS = 30_000;      // a description is written a few seconds after its event: the events are asked for again this much later,
const AI_WAIT_MS = 120_000;        // while the newest has none and is younger than this
const AI_SETTINGS_LINK = 'Settings › AI descriptions';

/** Every word of the camera page's AI descriptions card (Settings › AI descriptions tells people to turn the switch on here). */
const AI_CAMERA_TEXT = {
  title: 'AI descriptions',
  switchTitle: 'Describe events with AI',
  switchDesc: 'For each event, up to five still pictures from around it are sent to the AI service chosen in Settings. No video, no sound.',
  setUp: (link) => ['To turn this on, choose an AI service in ', link, '.'],
  onWithoutService: (link) => ['AI descriptions are on for this camera, but no AI service is chosen (', link, ').'],
  last: 'Last description',
  none: 'No description in the latest events',
};

/** GET nvr/events: the camera's newest page, over the longest range the route allows, ending a day ahead (this device's clock may be behind the bridge's). */
function newestEvents(cameraID) {
  const toMs = Date.now() + 86_400_000;
  return get(`nvr/events?cameras=${encodeURIComponent(cameraID)}&from=${toMs - 31 * 86_400_000}&to=${toMs}&limit=${ARCHIVE_PAGE}`);
}

/**
 * The camera page's AI descriptions card, next to Motion: the switch "Describe events with AI", disabled while Settings has no AI service
 * (with the way there; a switch that is on can always be turned off), what Settings says is missing (a place for recordings; for a camera
 * that is on, a refused or missing key too), and the camera's last description with its time, or "No description in the latest events".
 * The description is the newest one in the camera's newest events page. For a camera that is described, the page is asked for again 30 s
 * after a new event, and every 30 s while its newest event has none and is under two minutes old (the bridge's clock); a first page that
 * failed is asked for once more. Its words are the model's, so they go in as text only and their mark comes from `data-concern`
 * (style.css). It follows the camera in place (`update(camera)`), so the switch never builds the page again. Returns { el, update, destroy }.
 *   save(on)          the switch was flipped
 *   busy()            a flip is on its way: the camera's own word does not move the switch back meanwhile
 *   settings()        GET settings (its `ai`); events(cameraID) GET nvr/events for the camera; setTimer, clearTimer: for tests
 */
export function createAIDescriptionsCard(camera, { save, busy = () => false, settings = () => get('settings'), events = newestEvents,
  setTimer = (fn, ms) => setTimeout(fn, ms), clearTimer = (handle) => clearTimeout(handle) } = {}) {
  let current = camera;
  let service;            // aiSettingsView of Settings; null when it could not be read, undefined until it answers
  let last;               // { description, kind, start } of the newest described event; null: none; undefined: not known
  let lastEvent = camera.status?.lastEventDate ?? null;
  let timer = null;
  let asked = 0;          // the newest request for the events: an older answer is not used
  let retried = false;    // a first page that failed was asked for once more
  let notesFor = null;    // { service, on }: what the notes were drawn for
  let destroyed = false;

  const input = h('input', { type: 'checkbox', role: 'switch', disabled: true, onchange: () => { save(input.checked); drawEnabled(); drawNotes(); } });
  const row = h('label', { class: 'switch-row' },
    h('span', { class: 'text' }, h('span', { class: 'title' }, AI_CAMERA_TEXT.switchTitle), h('span', { class: 'desc' }, AI_CAMERA_TEXT.switchDesc)),
    h('span', { class: 'switch' }, input));
  const notes = h('div', { class: 'ai-cam-notes' });
  const lastHost = h('div', { class: 'ai-cam-last', hidden: true });
  const el = h('div', { class: 'card ai-cam-card' }, h('h2', null, AI_CAMERA_TEXT.title), row, notes, lastHost);
  const toSettings = () => h('a', { href: '#/settings/ai' }, AI_SETTINGS_LINK);

  function draw() {
    if (!busy()) input.checked = current.aiDescriptions === true;
    drawEnabled();
    drawNotes();
  }

  /** Off while Settings has not answered, and while it has no AI service for a switch that is off. */
  function drawEnabled() {
    input.disabled = service === undefined || (service !== null && !service.provider && !input.checked);
  }

  /** Drawn again only when Settings or the switch changed. A refused or missing key matters only to a camera that is on. */
  function drawNotes() {
    const on = input.checked;
    if (notesFor && notesFor.service === service && notesFor.on === on) return;
    notesFor = { service, on };
    if (!service) return replace(notes);
    if (!service.provider) return replace(notes, h('p', { class: 'small muted' }, (on ? AI_CAMERA_TEXT.onWithoutService : AI_CAMERA_TEXT.setUp)(toSettings())));
    return replace(notes, aiNotices(service, { keyNotes: on, fix: toSettings }));
  }

  /** The camera's events can still be described: its switch is on and Settings has (or may have) a service. */
  function describing() {
    return current.aiDescriptions === true && !(service && !service.provider);
  }

  /** Asks for the events again AI_RECHECK_MS from now (once: a later reason joins the ask that is waiting). */
  function recheck() {
    if (timer !== null || destroyed) return;
    timer = setTimer(() => { timer = null; loadLast(); }, AI_RECHECK_MS);
  }

  function drawLast() {
    lastHost.hidden = last === undefined;
    if (last === undefined) return replace(lastHost);
    const label = h('span', { class: 'small muted' }, AI_CAMERA_TEXT.last);
    if (!last) return replace(lastHost, label, h('p', { class: 'ai-cam-none muted' }, AI_CAMERA_TEXT.none));
    const { description, kind, start } = last;
    const word = concernWord(description.concern);
    return replace(lastHost, label,
      h('p', { class: 'ai-cam-summary', title: word, dataset: { concern: description.concern } }, description.text),
      h('p', { class: 'small muted ai-cam-when' },
        h('time', { datetime: new Date(start).toISOString() }, [word, eventKind(kind).label, stampText(start)].filter(Boolean).join(' · '))));
  }

  async function loadLast() {
    const ticket = ++asked;
    let answer;
    try {
      answer = await events(current.id);
    } catch {
      // Not known: what is shown stays. A first page that failed is asked for once more.
      if (!destroyed && ticket === asked && last === undefined && !retried) { retried = true; recheck(); }
      return;
    }
    if (destroyed || ticket !== asked) return;
    const list = (Array.isArray(answer?.events) ? answer.events : []).filter((event) => event && Number.isFinite(event.start));
    const newestOf = (items) => items.reduce((newest, event) => (!newest || event.start > newest.start ? event : newest), null);
    last = newestOf(list.map((event) => ({ description: eventDescription(event.description), kind: event.kind, start: event.start }))
      .filter((event) => event.description));
    drawLast();
    // The newest event's description may still be on its way: asked for again while it is young (by the bridge's clock) and the camera
    // is described, which Settings has to have said first.
    await ready;
    if (destroyed || ticket !== asked) return;
    const newest = newestOf(list);
    const now = Number.isFinite(answer?.serverTime) ? answer.serverTime : Date.now();
    if (newest && !eventDescription(newest.description) && now - newest.start < AI_WAIT_MS && describing()) recheck();
  }

  const ready = Promise.resolve().then(settings).then((answer) => { service = aiSettingsView(answer); }, () => { service = null; }).then(() => {
    if (!destroyed) draw();
  });
  loadLast();
  draw();

  return {
    el,
    /** The camera as the store has it now; a new event of a camera that is described asks for its description a little later. */
    update(next) {
      current = next;
      const date = next.status?.lastEventDate ?? null;
      if (date && date !== lastEvent && describing()) recheck();
      lastEvent = date ?? lastEvent;
      draw();
    },
    destroy() {
      destroyed = true;
      if (timer !== null) clearTimer(timer);
      timer = null;
    },
  };
}

export function renderCamera({ params, navigate, setTitle }) {
  const id = params[0];
  const bannerHost = banners();
  const root = h('div');
  let camera = store.cameras.get(id);
  let destroyed = false;
  let pairing = null;
  let recordHandle = null;   // the Record card (from the recording code, which may fail to load)
  let nightHandle = null;    // the Night vision card: it follows status.nightVision in place, hidden while the camera offers none
  let securityHandle = null; // the Security card: it follows status.security in place
  let wantsSecurity = params[1] === 'security';   // #/camera/<id>/security, or the banner's button on this page: bring the card into view once
  let aiHandle = null;       // the AI descriptions card: made once, it follows the camera's switch in place
  let live = false;
  let pictureTimer = null;
  let previewStop = null;   // stops the clock of the preview on screen
  let previewStraighten = null;   // straightens the preview on screen by a correction: the Straighten card's sliders, saved or not
  let straightenHandle = null;    // the Straighten the picture card: it follows the saved correction in place
  let encoderHost = null;         // the quality card's sentence about the straightened picture, kept up to date in place
  const saveState = h('span', { class: 'save-state', role: 'status', 'aria-live': 'polite' });
  let pending = {};
  let sending = {};          // what is on its way to the bridge

  // MARK: Saving

  async function send() {
    const body = pending;
    pending = {};
    if (!Object.keys(body).length || destroyed) return;
    sending = body;
    replace(saveState, 'Saving…');
    saveState.className = 'save-state';
    try {
      const updated = await patch(`cameras/${id}`, body);
      sending = {};
      putCamera(updated);
      camera = updated;
      replace(saveState, 'Saved');
      saveState.className = 'save-state ok';
      setTimeout(() => { if (saveState.textContent === 'Saved') replace(saveState); }, 2500);
    } catch (error) {
      sending = {};
      replace(saveState, `Not saved: ${error.message}`);
      saveState.className = 'save-state bad';
      toast(error.message, 'error');
      renderAll();   // show what the bridge has
    }
  }
  const flush = debounce(send, 600);

  /** Saves `partial` a moment after the last change, or `now`: then it resolves once the bridge answered (or refused). */
  function save(partial, { now = false } = {}) {
    pending = mergeDeep(pending, partial);
    replace(saveState, 'Saving…');
    saveState.className = 'save-state';
    if (!now) return flush();
    flush.cancel();
    return send();
  }

  function mergeDeep(a, b) {
    const out = { ...a };
    for (const [key, value] of Object.entries(b)) {
      out[key] = value && typeof value === 'object' && !Array.isArray(value) ? mergeDeep(out[key] || {}, value) : value;
    }
    return out;
  }

  // MARK: Pieces

  function previewCard() {
    previewStop?.();   // the card this one replaces stops its clock
    const img = h('img', { alt: `Picture from ${camera.name}`, hidden: true });
    const placeholder = h('div', { class: 'placeholder' }, h('div', null, icon('camera', { size: 34 }), h('div', null, 'Waiting for a picture…')));
    const toggle = h('button', { class: 'btn small', type: 'button' });
    const note = h('span', { class: 'pill plain' });
    // The time of the picture: "Updated 6:27:14 PM" for a snapshot, the time now ("Live · 6:27:14 PM") while the live picture plays.
    const stamp = h('span', { class: 'video-label', hidden: true });   // the camera's name and the date and time, as the bridge burns them
    // The page straightens the preview itself, so that it follows the Straighten card's sliders as they move: its pictures are the
    // camera's own (original=1; the bridge's are straightened already), drawn straightened while the correction shown is on. The guide is
    // the line the straightened horizon lands on.
    const guide = h('div', { class: 'straighten-guide', hidden: true });
    let shown = camera.pictureCorrection;   // the sliders' values, saved or not
    let views = null;                       // { picture, video }: the img and the video straightened, while `shown` is on
    let stampTimer = null;
    let autoTried = false;   // the live preview starts by itself once, when the camera is online
    const stopStamp = () => { clearInterval(stampTimer); stampTimer = null; };
    // Real live video (the camera's own H.264/HEVC through /api/v1/live) where the browser plays it; the picture stream otherwise.
    const video = h('video', { class: 'preview-video', muted: true, playsinline: true, hidden: true, 'aria-label': `Live video from ${camera.name}` });
    let liveVideo = null;     // { request, player } while the real video runs
    const stopVideo = () => {
      liveVideo?.request.close();
      liveVideo?.player.destroy();
      liveVideo = null;
      video.hidden = true;
      placeGuide();
    };
    const startVideo = () => {
      const player = createLivePlayer(video, {
        onPlaying: () => { video.hidden = false; img.hidden = true; placeholder.hidden = true; placeGuide(); },
        onProblem: () => { stopVideo(); if (live) startPictures(); },
      });
      const width = Math.round((video.parentElement?.clientWidth || 960) * (window.devicePixelRatio || 1));
      const request = openLive([id], {
        stream: 'automatic', width,
        onMessage: (index, message) => {
          if (message.kind === 'meta') player.meta(message.json);
          else if (message.kind === 'init') player.init(message.bytes);
          else if (message.kind === 'delta' || message.kind === 'keyframe') player.media(message.bytes, message.kind === 'keyframe');
        },
      });
      liveVideo = { request, player };
    };
    const startPictures = () => {
      img.hidden = false; placeholder.hidden = true;
      img.src = `/api/v1/cameras/${id}/live?original=1&t=${Date.now()}`;
      replace(note, 'Live preview · about one picture a second');
      placeGuide();
    };
    const showSnapshot = () => {
      if (live || document.hidden) return;
      const s = camera.status;
      if (!camera.isEnabled || s?.connection !== 'online') {
        img.hidden = true; placeholder.hidden = false;
        replace(placeholder, h('div', null, icon('camera', { size: 34 }), h('div', null, camera.isEnabled ? (s?.connection === 'offline' ? 'The camera isn’t answering' : 'Waiting for a picture…') : 'This camera is turned off')));
        placeGuide();
        return;
      }
      const next = new Image();
      next.onload = () => {
        img.src = next.src; img.hidden = false; placeholder.hidden = true;
        if (!live) { stopStamp(); showLabel(stamp, camera, Date.now()); }
      };
      next.src = `/api/v1/cameras/${id}/snapshot?original=1&t=${Date.now()}`;
    };
    /**
     * The guide across the picture itself (not the bars its object-fit leaves beside it), at the landing row of `shown`; hidden while off,
     * and while the preview shows no picture (the placeholder).
     */
    const placeGuide = () => {
      const picture = !video.hidden ? video : !img.hidden ? img : null;
      guide.hidden = !isOn(shown) || !picture;
      if (guide.hidden) return;
      const playing = picture === video && video.videoWidth > 0;
      const box = guide.parentNode;
      const fit = typeof getComputedStyle === 'function' ? getComputedStyle(picture).objectFit : '';
      const area = pictureArea(fit, box?.clientWidth, box?.clientHeight, playing ? video.videoWidth : img.naturalWidth, playing ? video.videoHeight : img.naturalHeight);
      guide.style.left = `${area.left * 100}%`;
      guide.style.width = `${area.width * 100}%`;
      guide.style.top = `${(area.top + landing(shown) * area.height) * 100}%`;
    };
    /** Shows the preview straightened by `correction`: its two views exist only while it is on. */
    const showCorrection = (correction) => {
      shown = correction;
      if (!isOn(correction)) {
        views?.picture.destroy();
        views?.video.destroy();
        views = null;
      } else if (views) {
        views.picture.set(correction);
        views.video.set(correction);
      } else {
        views = { picture: createStraightenedView({ source: img, correction }), video: createStraightenedView({ source: video, correction }) };
      }
      placeGuide();
    };
    img.addEventListener('load', placeGuide);
    video.addEventListener('resize', placeGuide);   // the live video's size is known, or changed
    const setLive = (on) => {
      live = on;
      if (on) {
        if (liveSupported()) {
          replace(note, 'Live video');
          startVideo();
        } else {
          startPictures();
        }
        replace(toggle, icon('pause'), 'Stop live preview');
        const tick = () => {
          showLabel(stamp, camera, Date.now());
          // A browser tells of a picture stream's first picture only (one load event): its newest is drawn straightened here.
          if (!liveVideo) views?.picture.set(shown);
        };
        tick();
        stopStamp();
        stampTimer = setInterval(tick, 1000);

      } else {
        stopStamp();
        stopVideo();
        img.removeAttribute('src');
        replace(toggle, icon('play'), 'Start live preview');
        replace(note, 'Picture refreshes every few seconds');
        showSnapshot();
      }
    };
    img.addEventListener('error', () => { if (live) { toast('The live preview stopped. The camera may be offline.'); setLive(false); } });
    toggle.addEventListener('click', () => setLive(!live));
    // Plays by itself when the camera is online; if it is not yet, the picture timer below starts it once it is.
    const online = () => camera.isEnabled && camera.status?.connection === 'online';
    setLive(false);
    clearInterval(pictureTimer);
    pictureTimer = setInterval(() => {
      showSnapshot();
      if (!autoTried && !live && online()) { autoTried = true; setLive(true); }
    }, 5000);
    if (online()) { autoTried = true; setLive(true); }
    previewStop = () => { stopStamp(); stopVideo(); showCorrection(null); };
    previewStraighten = showCorrection;
    const card = h('div', null, h('div', { class: 'preview' }, img, video, guide, placeholder, stamp, h('div', { class: 'overlay' }, note, toggle)));
    showCorrection(shown);   // now that the img and the video are in their box: each view puts its canvas right after its source
    return card;
  }

  /** The battery tile's line under the level: how it charges, or that it runs on its battery (low: charge it soon). */
  function batteryText(battery) {
    const charging = batteryCharging(battery);
    if (charging) return charging[0].toUpperCase() + charging.slice(1);
    return battery.level < 20 ? 'Low: charge it soon' : 'On battery';
  }

  function tiles() {
    const s = camera.status;
    const tile = (k, v, d) => h('div', { class: 'tile' }, h('div', { class: 'k' }, k), h('div', { class: 'v' }, v), d ? h('div', { class: 'd' }, d) : null);
    const recording = s?.recordingNow ? 'Recording now' : s?.recordingEnabled ? 'Ready to record' : 'Not turned on';
    return h('div', { class: 'tiles' },
      tile('Status', s ? s.summary : 'Starting', s?.connectionReason ? s.connectionReason : null),
      tile('Camera events', cameraEventsText(camera), s?.eventsNote),
      tile('Picture', s?.videoSummary || 'No picture yet', s?.subStreamProblem ? `Sub stream: ${s.subStreamProblem}` : null),
      tile('Live view', viewersText(s), viewersDetail(s)),
      tile('Home recording', recording, s?.recordingEnabled ? null : 'Turn it on for this camera in the Home app'),
      tile('Last event', s?.lastEvent || 'None yet', s?.lastEventDate ? timeAgo(s.lastEventDate) : null),
      s?.battery ? tile('Battery', batteryPill(s.battery, { word: false }), batteryText(s.battery)) : null);
  }

  function eventsCard() {
    const events = [...(camera.status?.recentEvents || [])].reverse();
    return h('div', { class: 'card' }, h('h2', null, 'Recent events'),
      events.length ? h('ul', { class: 'events' }, events.map((e) => h('li', null, h('span', null, e.name), h('span', { class: 'muted' }, timeAgo(e.date)))))
        : h('p', { class: 'muted' }, 'No recent events'));
  }

  function homeCard() {
    const s = camera.status;
    if (s?.paired) {
      return h('div', { class: 'card' }, h('h2', null, 'Apple Home'), homeState(camera),
        h('p', { class: 'muted small' }, 'Open the Home app to watch live view and recordings.'),
        h('div', { class: 'row' }, h('a', { class: 'btn small', href: `#/camera/${id}/pair` }, 'Pairing details')));
    }
    pairing?.destroy();
    pairing = pairingPanel({ cameraId: id, cameraName: camera.name });
    return h('div', { class: 'home-block' }, h('h2', { class: 'section-title' }, 'Apple Home'), pairing.el);
  }

  function motionCard() {
    const caps = camera.capabilities;
    const canEvents = !caps || (caps.events || []).includes('motion');
    const sources = MOTION_SOURCES.filter(([key]) => key !== 'cameraEvents' || canEvents);
    const sensors = sensorsFor(camera);
    const out = h('output', { class: 'muted' }, `${Math.round(camera.motionSensitivity * 100)}%`);
    const slider = h('input', { type: 'range', min: 0, max: 1, step: 0.05, value: camera.motionSensitivity, id: 'sens', 'aria-label': 'Sensitivity',
      oninput: (e) => { out.textContent = `${Math.round(e.target.value * 100)}%`; save({ motionSensitivity: Number(e.target.value) }); } });
    return h('div', { class: 'card' }, h('h2', null, 'Motion'),
      h('p', { class: 'desc' }, `${MOTION_SOURCES.find(([k]) => k === camera.motionSource)?.[2] || ''} Motion starts HomeKit Secure Video recordings.`),
      selectField('Motion source', sources.map(([k, t]) => [k, t]), camera.motionSource, (value) => { save({ motionSource: value }, { now: true }); camera = { ...camera, motionSource: value }; renderAll(); }),
      camera.motionSource === 'softMotion' ? h('div', { class: 'field' }, h('div', { class: 'row spread' }, h('label', { for: 'sens' }, 'Sensitivity'), out), slider,
        h('div', { class: 'row spread small muted' }, h('span', null, 'Low'), h('span', null, 'High'))) : null,
      field('Motion stays on for (seconds)', h('input', { type: 'number', min: 1, max: 3600, value: camera.motionHoldSeconds, onchange: (e) => save({ motionHoldSeconds: Number(e.target.value) }) })),
      h('div', { class: 'row' }, h('button', { class: 'btn small', type: 'button', onclick: triggerMotion }, icon('bolt'), 'Trigger motion'),
        h('span', { class: 'small muted' }, 'Sends a motion event to the Home app as if the camera saw motion: with recording on, Home records a clip, and people who get this camera’s notifications are notified.')),
      sensors.length ? h('div', null, h('h3', { class: 'section-title' }, 'Sensors'),
        sensors.map((s) => switchRow({ title: s.title, desc: `${s.fromWebhook ? 'From the webhook · ' : ''}${s.accessory}`, checked: camera.sensors[s.key], onchange: (v) => save({ sensors: { [s.key]: v } }) })),
        h('p', { class: 'small muted' }, 'Sensors appear on the Camera Bridge Sensors bridge in the Home app. They never start recordings.')) : null);
  }

  // After the camera setup changed the camera: its configuration (the setup's record, its backup) as the bridge has it now.
  async function refreshCamera() {
    try {
      const updated = await get(`cameras/${id}`);
      if (destroyed) return;
      putCamera(updated);
      camera = updated;
      renderAll();
    } catch { /* the event stream brings it */ }
  }

  // "Fix with Set up for Camera Bridge" and "Watch its internet" on the Security card: the setup's own dialog (it shows every change first).
  async function openSetup() {
    const outcome = await cameraSetupDialog(camera);
    if (outcome !== 'cancelled') refreshCamera();
  }

  /** Scrolls the Security card to the top and moves the focus to its heading, once it is on the page (it comes after the page's first
   *  requests). */
  function showSecurity() {
    const card = securityHandle?.el;
    if (!wantsSecurity || destroyed || !card?.isConnected || card.hidden) return;
    wantsSecurity = false;
    card.scrollIntoView?.({ block: 'start' });
    securityHandle.heading?.focus({ preventScroll: true });
  }

  // The banner's "See what <camera> tried" while this camera's page is already on screen.
  const onShowSecurity = (event) => {
    if (String(event?.detail).toLowerCase() !== String(id).toLowerCase()) return;
    wantsSecurity = true;
    showSecurity();
  };
  window.addEventListener(SHOW_SECURITY_EVENT, onShowSecurity);

  async function triggerMotion() {
    try {
      await post(`cameras/${id}/test-motion`);
      toast('Motion sent to the Home app.', 'ok');
    } catch (error) { toast(error.message, 'error'); }
  }

  function audioCard() {
    return h('div', { class: 'card' }, h('h2', null, 'Audio'),
      switchRow({ title: 'Camera audio', desc: 'Hear the camera’s microphone in live view and recordings.', checked: camera.audioEnabled, onchange: (v) => save({ audioEnabled: v }) }),
      camera.capabilities?.twoWayAudio ? switchRow({ title: 'Two-way audio', desc: 'Talk through the camera’s speaker from the Home app.', checked: camera.twoWayAudio, onchange: (v) => save({ twoWayAudio: v }) }) : null);
  }

  function qualityCard() {
    const overlay = camera.timestampOverlay.enabled ? ' The Camera Bridge timestamp is on, so live view and recordings always use the video encoder.' : '';
    encoderHost = h('span', null, encoderNote(camera));   // follows the saved correction in place (saving it does not build the page again)
    return h('div', { class: 'card' }, h('h2', null, 'Live view and Home recording'),
      selectField('Live view stream', [['automatic', 'Automatic'], ['alwaysMain', 'Always main stream'], ['alwaysSub', 'Always sub stream']], camera.liveStreamMode, (v) => save({ liveStreamMode: v })),
      selectField('Live view quality', [['matchHomeKitRequest', 'Match Home app request'], ['originalQuality', 'Original quality']], camera.liveQualityMode, (v) => save({ liveQualityMode: v }),
        { hint: [`Original quality sends the camera’s own H.264 untouched when possible, ignoring what the Home app asked for; it falls back to matching the request for HEVC cameras or ones that use B-frames.${overlay}`, encoderHost] }),
      camera.liveQualityMode === 'matchHomeKitRequest' ? selectField('Maximum bit rate', BITRATES, camera.liveMaxBitrateOverride, (v) => save({ liveMaxBitrateOverride: v }),
        { hint: 'Caps what the bridge sends while it converts the picture. Automatic keeps what Home asks for.' }) : null,
      selectField('Home recording stream', [['automatic', 'Automatic (main stream)'], ['main', 'Main stream'], ['sub', 'Sub stream']], camera.recordingStreamMode, (v) => save({ recordingStreamMode: v })),
      selectField('Home recording quality', [['matchHubRequest', 'Match Home hub request'], ['originalWhenPossible', 'Original when possible']], camera.recordingQualityMode, (v) => save({ recordingQualityMode: v }),
        { hint: 'HomeKit Secure Video records motion clips. Changing the recording stream or quality changes what the Home app thinks this camera supports; you may need to turn recording off and back on for this camera in the Home app afterward.' }),
      camera.status?.liveSessions?.length ? h('div', null, h('h3', { class: 'section-title' }, 'Watching now'), h('ul', { class: 'events' }, camera.status.liveSessions.map((s, i) => h('li', null, h('span', null, `Viewer ${i + 1}`), h('span', { class: 'muted' }, describeSession(s)))))) : null,
      camera.status?.recordingSession ? h('p', { class: 'small muted' }, `Home recording now: ${describeSession(camera.status.recordingSession)}`) : null);
  }

  function overlayCard() {
    const o = camera.timestampOverlay;
    const set = (partial) => { Object.assign(camera.timestampOverlay, partial); save({ timestampOverlay: partial }); };
    const clean = Boolean(camera.cleanPictureBackup || camera.setupBackup?.cleanPicture);   // the setup keeps its backup in its own
    const position = [['topRight', 'Top right'], ['topLeft', 'Top left'], ['bottomRight', 'Bottom right'], ['bottomLeft', 'Bottom left']];
    return h('div', { class: 'card' }, h('h2', null, 'Labels on video'),
      h('p', { class: 'desc' }, 'The bridge draws the camera’s name and the date and time the same way everywhere: on the Monitor, on recordings as you play them, burned into saved clips and, if you choose, into Apple Home’s video.'),
      switchRow({
        title: 'Clean picture from the camera', checked: clean,
        onchange: async (on) => {
          try {
            await post(`cameras/${id}/clean-picture`, { clean: on });
            toast(on ? 'The camera’s own labels are off: only the bridge’s show.' : 'The camera’s own labels are back.', 'ok');
          } catch (error) { toast(error.message, 'error'); }
        },
      }),
      h('p', { class: 'small muted' }, 'Turns off everything the camera draws itself (its clock, name, text and logo) through its own API or ONVIF, and puts it back as it was when turned off again.'),
      h('h3', { class: 'section-title' }, 'The bridge’s label'),
      selectField('Corner', position, o.position, (v) => set({ position: v })),
      selectField('Size', [['small', 'Small'], ['medium', 'Medium'], ['large', 'Large']], o.size, (v) => set({ size: v })),
      switchRow({ title: 'Camera name', checked: o.showCameraName, onchange: (v) => set({ showCameraName: v }) }),
      switchRow({ title: 'Date', checked: o.showDate, onchange: (v) => set({ showDate: v }) }),
      switchRow({ title: 'Seconds', checked: o.showSeconds, onchange: (v) => set({ showSeconds: v }) }),
      switchRow({ title: '24-hour time', checked: o.use24Hour, onchange: (v) => set({ use24Hour: v }) }),
      switchRow({ title: 'Burn it into Apple Home’s video', checked: o.enabled, onchange: (v) => { set({ enabled: v }); renderAll(); } }),
      h('p', { class: 'small muted' }, 'Apple Home’s live view and Home recordings then carry the label. The bridge converts that video (at Home’s size) instead of passing it through.'),
      h('button', { class: 'btn small', type: 'button', onclick: async () => {
        try {
          const answer = await post(`cameras/${id}/camera-time-zone`, {});
          toast(`The camera’s clock is set to the bridge’s time zone (${answer.timeZone}).`, 'ok');
        } catch (error) { toast(error.message, 'error'); }
      } }, icon('refresh'), 'Set the camera’s own clock to the bridge’s time zone'));
  }

  /**
   * Straighten the picture: two sliders that say where the camera's horizon is (Straighten its curve, Level its tilt). The preview follows
   * them as they move, and nothing builds the page again. A pointer saves when it lets go; keys save once they pause (a range input sends
   * a change for every step). One save of the card is on its way at a time: a newer value waits for its answer, and only the newest goes.
   * -> { el, update(camera), destroy() }: the card follows the saved correction in place (another browser changed it), except while a
   * slider is held or a change of its own is not saved and answered yet (the answers to its own saves never move it back).
   */
  function straightenCard() {
    let saved = camera.pictureCorrection;   // what the bridge has, as far as the card knows
    let moving = false;                      // a slider is held: moved and not let go
    let byPointer = false;                   // the sliders were last worked with a pointer (else with the keys)
    let pause = null;                        // the timer of a change by the keys, waiting for them to pause
    let sending = false;                     // one of the card's saves is on its way
    let again = false;                       // and the sliders changed since: their newest values go once it is answered
    let retired = false;                     // the page went, or built a new card: nothing more is saved from this card, except what it owes
    let owes = false;                        // retired with a key edit still waiting for its pause: that edit's newest values still go
    const stretch = h('p', { class: 'small muted', hidden: true });
    const control = (inputId, title, limit, value) => {
      const out = h('output', { class: 'muted', for: inputId });
      const letGo = () => { moving = false; };   // a drag that ends where it began sends no change
      const input = h('input', { type: 'range', id: inputId, min: -limit, max: limit, step: 1, value,
        onpointerdown: () => { byPointer = true; },
        onkeydown: () => { byPointer = false; },
        oninput: () => { moving = true; show(); },
        onchange: () => { moving = false; if (byPointer) commit(); else waitForPause(); },
        onpointerup: letGo,
        onpointercancel: letGo,
        onblur: () => { letGo(); if (pause) commit(); },
      });
      return { input, out, el: h('div', { class: 'field' }, h('div', { class: 'row spread' }, h('label', { for: inputId }, title), out), input) };
    };
    const straighten = control('pc-straighten', 'Straighten', 60, sliderValue(saved?.straighten));
    const level = control('pc-level', 'Level', 40, sliderValue(saved?.level));
    const values = () => ({ straighten: Number(straighten.input.value) / 100, level: Number(level.input.value) / 100 });
    const same = (a, b) => sliderValue(a?.straighten) === sliderValue(b?.straighten) && sliderValue(a?.level) === sliderValue(b?.level);

    /** The numbers, the stretch line and the preview, from where the sliders are. */
    function show() {
      const correction = values();
      replace(straighten.out, String(Number(straighten.input.value)));
      replace(level.out, String(Number(level.input.value)));
      const factor = largestStretch(correction);
      stretch.hidden = !(factor >= 2);
      replace(stretch, `At this setting parts of the picture are stretched up to ${factor.toFixed(1)}×.`);
      previewStraighten?.(correction);
    }
    function waitForPause() {
      clearTimeout(pause);
      pause = setTimeout(commit, KEY_PAUSE_MS);
    }
    /** Saves where the sliders are: at once, or, while a save of the card is on its way, once that one is answered. */
    async function commit() {
      clearTimeout(pause);
      pause = null;
      if (sending) { again = true; return; }
      sending = true;
      try {
        do {
          again = false;
          await save({ pictureCorrection: values() }, { now: true });
        } while (again && (!retired || owes));
      } finally {
        sending = false;
      }
    }
    function reset() {
      straighten.input.value = 0;
      level.input.value = 0;
      moving = false;
      show();
      commit();
    }

    show();
    return {
      el: h('div', { class: 'card' }, h('h2', null, 'Straighten the picture'), h('p', { class: 'desc' }, STRAIGHTEN_LINE), straighten.el, level.el, stretch,
        h('div', { class: 'row' }, h('button', { class: 'btn small', type: 'button', onclick: reset }, 'Reset'))),
      update(next) {
        const correction = next.pictureCorrection;
        if (same(correction, saved)) return;
        saved = correction;
        if (moving || pause || sending) return;   // the card's own values stand: its save carries them
        straighten.input.value = sliderValue(correction?.straighten);
        level.input.value = sliderValue(correction?.level);
        show();
      },
      destroy() {
        // A key edit still waiting for its pause is saved now: leaving the page or building it again (another browser edited the camera)
        // would otherwise drop it.
        if (pause !== null) {
          owes = true;
          commit();
        }
        retired = true;
        clearTimeout(pause);
        pause = null;
      },
    };
  }

  function connectionCard() {
    const e = camera.endpoint;
    const usesAddress = !['demo', 'go2rtc'].includes(camera.vendor);
    return h('div', { class: 'card' }, h('h2', null, 'Camera'),
      h('dl', { class: 'kv' },
        h('dt', null, 'Type'), h('dd', null, camera.vendorName),
        camera.manufacturer || camera.model ? [h('dt', null, 'Make'), h('dd', null, [camera.manufacturer, camera.model].filter(Boolean).join(' '))] : null,
        camera.firmware ? [h('dt', null, 'Firmware'), h('dd', null, camera.firmware)] : null,
        usesAddress ? [h('dt', null, 'Address'), h('dd', null, `${e.host}${e.useHTTPS ? ' (HTTPS)' : ''}`)] : null,
        camera.username ? [h('dt', null, 'User'), h('dd', null, camera.username)] : null,
        camera.integration ? [h('dt', null, 'Service'), h('dd', null, camera.integration.service)] : null),
      switchRow({ title: 'Turned on', desc: 'Turn off to stop streaming without removing the camera from the Home app.', checked: camera.isEnabled, onchange: (v) => { save({ isEnabled: v }, { now: true }); } }),
      h('div', { class: 'row' },
        usesAddress ? h('button', { class: 'btn small', type: 'button', onclick: changeConnection }, 'Change address…') : null,
        camera.username || camera.vendor === 'rtsp' ? h('button', { class: 'btn small', type: 'button', onclick: changePassword }, 'Change password…') : null));
  }

  async function changeConnection() {
    const host = await promptDialog({ title: 'Camera address', label: 'Address', value: camera.endpoint.host, body: 'If the camera’s address changed, enter the new one. The Home app keeps the camera.', confirm: 'Save' });
    if (host === undefined || host.trim() === camera.endpoint.host) return;
    save({ endpoint: { host: host.trim() } }, { now: true });
  }

  async function changePassword() {
    const password = await promptDialog({ title: `Password for “${camera.name}”`, label: 'New password', type: 'password', autocomplete: 'new-password', confirm: 'Save',
      body: 'The password is kept encrypted on this bridge.' });
    if (!password) return;
    save({ password }, { now: true });
  }

  async function webhookCard(settingsAnswer) {
    let settings;
    try { settings = await settingsAnswer; } catch { return null; }
    const base = `http://${location.hostname}:${settings.webhookPort}/cameras/${id}`;
    return h('div', { class: 'card' }, h('h2', null, 'Webhook'),
      settings.webhookEnabled
        ? h('div', null, h('p', { class: 'desc' }, 'Send a POST request with the webhook token from Settings. A detection appears in the Home app when its sensor is turned on.'),
          h('ul', { class: 'events' }, ['motion', 'motion/stop', 'doorbell', 'person', 'vehicle'].map((event) => h('li', null, h('code', null, `POST ${base}/${event}`)))))
        : h('p', { class: 'muted' }, 'Turn on the webhook in ', h('a', { href: '#/settings' }, 'Settings'), ' to report this camera’s motion, doorbell rings or detections from Home Assistant, Frigate or another system.'));
  }

  async function removeCamera() {
    const ok = await confirmDialog({
      title: `Remove “${camera.name}”?`,
      body: ['Camera Bridge stops publishing this camera and deletes its saved password. Remove it from the Home app as well.', removalNote(camera)]
        .filter(Boolean).join(' '),
      confirm: 'Remove camera', danger: true,
    });
    if (!ok) return;
    try {
      await del(`cameras/${id}`);
      toast(`“${camera.name}” was removed.`);
      navigate('/');
    } catch (error) { toast(error.message, 'error'); }
  }

  async function rename() {
    const name = await promptDialog({ title: 'Rename camera', label: 'Name', value: camera.name, confirm: 'Rename' });
    if (name === undefined || !name.trim() || name.trim() === camera.name) return;
    save({ name: name.trim() }, { now: true });
  }

  // MARK: Layout

  const headingHost = h('div', { class: 'page-head' });
  const left = h('div', { class: 'stack' });
  const right = h('div', { class: 'stack' });
  const statusHost = h('div');
  const homeHost = h('div');
  const homeBottomHost = h('div');   // a camera that is already in Apple Home keeps its card here, below everything that needs attention

  function renderStatus() {
    if (!camera) return;
    const s = camera.status;
    replace(statusHost,
      s?.lastError ? inlineError(s.lastError) : null,
      s?.homeKitNote ? h('div', { class: 'banner info' }, icon('info'), h('div', { class: 'text' }, s.homeKitNote)) : null,
      tiles());
  }

  function renderHead() {
    setTitle(camera.name);
    const security = securityView(camera);
    replace(headingHost, h('h1', null, camera.name), statePill(camera), security ? securityBadge(security.level, { prefix: true }) : null,
      h('div', { class: 'actions' }, h('button', { class: 'btn small', type: 'button', onclick: rename }, 'Rename'), saveState));
  }

  async function renderAll() {
    if (destroyed) return;
    camera = store.cameras.get(id) || camera;
    if (!camera) return;
    renderHead();
    pairing?.destroy(); pairing = null;
    replace(left, previewCard(), statusHost, eventsCard());
    renderStatus();
    const settingsAnswer = get('settings');   // for the Webhook card, the AI descriptions card when it is made, and the Security card's AI line
    aiHandle ??= createAIDescriptionsCard(camera, {
      save: (on) => save({ aiDescriptions: on }),
      busy: () => 'aiDescriptions' in pending || 'aiDescriptions' in sending,
      settings: () => settingsAnswer,
    });
    aiHandle.update(camera);
    const [hook, nvr] = await Promise.all([webhookCard(settingsAnswer), nvrSupported(camera) ? loadNVR() : null]);
    if (destroyed) return;
    recordHandle?.destroy();
    recordHandle = nvr ? nvr.recordCard(camera) : null;
    nightHandle?.destroy();
    nightHandle = createNightVisionCard(camera);
    securityHandle?.destroy();
    const canSetUp = setupSupported(camera);
    // "Restart the camera now": the card goes once the camera no longer waits (the page draws again), so a toast says it is restarting.
    const restart = (c) => restartControl(c, { onRestarted: () => toast(RESTART_TEXT.sent) });
    securityHandle = createSecurityCard(camera, { canSetUp, openSetup, routerHelp: localOnlyCard, restart, aiSettings: settingsAnswer });
    const home = homeCard();
    if (camera.status?.paired) { replace(homeHost); replace(homeBottomHost, home); } else { replace(homeBottomHost); replace(homeHost, home); }
    straightenHandle?.destroy();
    straightenHandle = straightenCard();
    replace(right, recordHandle?.el, securityHandle.el, canSetUp ? cameraSetupCard(camera, { onDone: refreshCamera, localHelp: false }) : null, motionCard(), aiHandle.el, audioCard(), nightHandle.el, qualityCard(), overlayCard(), straightenHandle.el, hook, connectionCard(),
      h('div', { class: 'card' }, h('h2', null, 'Remove'), h('p', { class: 'desc' }, 'Removes the camera from Camera Bridge. Remove it from the Home app as well.'),
        h('button', { class: 'btn danger', type: 'button', onclick: removeCamera }, icon('trash'), 'Remove camera…')));
    showSecurity();
  }

  // What counts as the camera's structure: everything but its status, the two Record flags, its picture correction and the AI switch.
  // The Record, Straighten and AI descriptions cards follow those in place, so pressing Record or the AI switch, or letting go of a
  // slider, never rebuilds the page (the preview keeps running) or takes keyboard focus away from the control.
  const structure = (c) => JSON.stringify({ ...c, status: null, nvrEnabled: null, nvrRecordSound: null, pictureCorrection: null, aiDescriptions: null });

  const stop = subscribe((kind, detail) => {
    if (destroyed) return;
    if (kind === 'removed' && detail === id) { toast('This camera was removed.'); navigate('/'); }
    if (kind === 'camera' && detail?.id === id) {
      const before = camera;
      camera = detail;
      renderHead();
      renderStatus();
      nightHandle?.update(detail);
      securityHandle?.update(detail);
      straightenHandle?.update(detail);
      if (encoderHost) replace(encoderHost, encoderNote(detail));
      aiHandle?.update(detail);
      // The structure only changes when something other than a status moved (another browser edited it).
      if (before && structure(before) !== structure(detail) && !Object.keys(pending).length) renderAll();
    }
  });

  if (!camera) {
    replace(root, backLink('#/cameras', 'Cameras'), h('div', { class: 'empty' }, h('h2', null, 'This camera was removed'), h('a', { class: 'btn primary', href: '#/cameras' }, 'Back to your cameras')));
    return { el: root, destroy() { destroyed = true; stop(); bannerHost.destroy(); window.removeEventListener(SHOW_SECURITY_EVENT, onShowSecurity); } };
  }
  replace(root, backLink('#/cameras', 'Cameras'), headingHost, bannerHost, homeHost, h('div', { class: 'layout-2' }, left, right), homeBottomHost);
  renderAll();

  return {
    el: root,
    destroy() {
      straightenHandle?.destroy();   // first, while the page can still send: a key edit it was waiting to save goes now
      destroyed = true;
      flush.flush();
      clearInterval(pictureTimer);
      previewStop?.();
      stop();
      pairing?.destroy();
      recordHandle?.destroy();
      nightHandle?.destroy();
      securityHandle?.destroy();
      aiHandle?.destroy();
      bannerHost.destroy();
      window.removeEventListener(SHOW_SECURITY_EVENT, onShowSecurity);
      for (const img of root.querySelectorAll('img')) img.removeAttribute('src');   // closes a live preview
    },
  };
}

/** The pairing page of one camera (also where "Add to Apple Home" on the overview goes). */
export function renderCameraPairing({ params, setTitle }) {
  const id = params[0];
  const camera = store.cameras.get(id);
  const panel = pairingPanel({ cameraId: id, cameraName: camera?.name });
  setTitle(camera ? `${camera.name}: Apple Home` : 'Apple Home');
  return {
    el: h('div', { class: 'wizard' }, backLink(`#/camera/${id}`, camera?.name || 'Camera'), h('h1', null, 'Add to Apple Home'),
      h('p', { class: 'lede' }, camera ? `“${camera.name}” appears in the Home app as its own accessory.` : ''), panel.el),
    destroy: () => panel.destroy(),
  };
}

export function renderSensorsPairing({ setTitle }) {
  const panel = pairingPanel({ source: 'sensors-bridge' });
  setTitle('Sensors bridge');
  return {
    el: h('div', { class: 'wizard' }, backLink('#/settings', 'Settings'), h('h1', null, 'Sensors bridge'),
      h('p', { class: 'lede' }, 'One accessory in the Home app that carries the sensors of all your cameras: people, vehicles, animals, packages, day and night, alarm inputs. Add it once.'), panel.el),
    destroy: () => panel.destroy(),
  };
}
