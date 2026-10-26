// Sky Watcher on the dev server: the plugin and its switch, and Task 5's routes with a made-up night to read, so the page (js/screens/sky-card.js,
// sky-log.js, plugins.js) can be tried without a box. Nothing here is a camera's or a person's: the places, flights, satellites and lights are
// invented, and every night is the same night each time it is asked for (the entries are seeded by the date).
//
// Sky Watcher is a plugin, off when the server starts, as on a new box (switch it on in Plugins, or POST /__dev/sky {"plugin": true}). While it is
// off the box reports nothing about the sky (no `status.sky`), no camera can be turned on for it, and every camera keeps what it was set to.
//
//   GET   plugins                                                the plugins this server has: { plugins: [{ id, name, summary, needs, needsInternet, internetNote, enabled }] }
//   PATCH plugins/:id {enabled}                                  the switch; answers the list
//   GET   sky/cameras/:id/night?date=yyyy-MM-dd&view=night|day   the log: { camera, night, view, from, to, serverTime, entries, conditions, counts, aim, learning,
//                                                                 capped } (times are epoch ms; an entry carries `display` and `watch`, its optional fields are
//                                                                 null; `capped` the hours with more lights than were logged, [{ hour, count }])
//   GET   sky/cameras/:id/entries/:eid/still?night=…[&size=thumb] image/jpeg, or 404; size=thumb is the close-up of the light, cut as the page cuts it
//                                                                 (the box makes it the same way: ffmpeg here, when there is one, else the whole picture)
//   POST  sky/cameras/:id/entries/:eid/correction {night, label}  the entry, or 400 for a label that is not one
//   POST  sky/feeds/find                                         { feeds: [url] }
//   PATCH settings {sky: {location, flightFeedURL, aiDailyLimit}} and GET settings (its `sky`)
//   PATCH cameras/:id {skyDetector: {enabled, facing, tilt, groundPercent, nightProfile, lensLayout}}: enabling needs the plugin, a place and a folder
//   POST  /__dev/sky {plugin, aim, learning, problem, location, feeds, stream, busy}   what the box reports and what it has (this computer only)
//
// A night runs from 6:30 PM to 7:10 AM in this computer's zone, a day from midnight to midnight; the latest night is the one that began at the
// last 6:30 PM. One that is still going holds only what has happened. The camera "Back Yard" watches the sky when the server starts.

import { spawn } from 'node:child_process';
import { thumbRect } from '../../web/js/screens/sky-model.js';
import { ApiError, bytes } from './http.mjs';

// A made-up night sky, 400 × 177 (the shape of a stitched 4256 × 1888 view): a dark gradient, a few stars, a tree line.
const STILL = Buffer.from([
  '/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAABkKADAAQA',
  'AAABAAAAsQAAAAD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/8AAEQgAsQGQAwEiAAIRAQMR',
  'Af/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHw',
  'JDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1',
  'tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQE',
  'AwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2Rl',
  'ZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/b',
  'AEMACQkJCQkJEAkJEBYQEBAWHhYWFhYeJh4eHh4eJi4mJiYmJiYuLi4uLi4uLjc3Nzc3N0BAQEBASEhISEhISEhISP/bAEMBCwwMEhESHxERH0szKjNL',
  'S0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS//dAAQAGf/aAAwDAQACEQMRAD8A8WooorUkKKKKACnFiUCcYBJ6',
  'DPOO/XtTaKACipJEVGAVw4wDlc4yQCRyByOh7ZHGRzUdABUqGEOhkVioI3gMASM84ODjj1B559qiooAKKKKACiiigAooooAKKeiFzgY6E8kDoM9/0Hfo',
  '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',
  'ANxRinYp0kryys8rF5HJZixySSeST7mgCPFGKdijFADcUYp2KMUANxSsoU4BDcA5Ge46c+lLinO8kh3SMWIAGSc8AYA+gAwKAP/Q8XimMZJxnPWri3MR',
  'GScH0rNorSNRolouzXKkFY+c9TSWsij92eMniqdAJByKOd3uFjaxTJGEaFzzioIrpSMS8H1qCa4MnyrwtbuorXRCTLsTiRN3GfSpDgDJrFBIORTzI7DB',
  'YkfWs1V01K5SWebzDtX7opYZyh2vyv8AKq1FZ87vcdjaGCMioJpfKxxnNUUmlQbVOBTXd3OXOa1dXTQXKa+KMVmxXDR8Nyv+elTPeDGIwc+pq1Uja5PK',
  'yO5f96Np+7/OnR3RziTketU6Kw53e6LsavnQ43bhVLzV8/zecf8A1qr0U3UbBI2VIYbl5BpcVmwT+Vwwypq291GFyhya2jUTV2Q0xv2hRIVbgDv71Ojo',
  '4yhzWQSWJJ6mkrJVWVymnLMsYwOW9Kz0dozlTTKKmU23caRrRSLKuR+Ip5IAJPQVko7RtuWp3umdNoAGRzWqqq2pLiXI5FlXcvrjmpMVjq7IcqSKtLeM',
  'BhlyfXpRGquoOPYnuWCxEZwT0rPWR0+6TxSyStKct+VR1lOd3dFJGlHcI4+YgGkuJdi4RhuzWdRT9q7WDlNWKRZFHOTjmpcVjKxUhlOCK0kuoyuXODWs',
  'Kie5LQs8vlLx1PSmfaos45+tVriYSsAvQdKr1EqjvoNRNbzYsZ3Cs+WXfIHXjHSoaKmVRvQaVi/Bcbjsk69jVvFYtXYrsKuJMkjuKuFTpITXYtGRA4jz',
  'yafismSQu5ccZoSWSP7p49O1HtdRcprHAGTWS7nzGZSeT19qfJcSSjacAe1QVNSd9hpFqK4ZTiQ5H8q0BgjIrFpwZgNoJAPaiNRrRg4l+GcSEhsDpirO',
  'KxatwXOwBH5Hr6VUKnSQOPYvEgAk9BVM3YwcDnPH0p81yhQrHyTxWfRUqa+6CXc//9HxGiiimIKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiig',
  'AooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooA//0vEaKKKYgooooAKKKKACiiigAooo',
  'oAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigD//Z'
].join(''), 'base64');

/** The size of STILL, which a night's `picture` says. */
const STILL_SIZE = Object.freeze({ width: 400, height: 177 });
/** A thumbnail is at most this wide; a made-up still is narrower, so one is never scaled. */
const THUMB_WIDTH = 480;

// MARK: Thumbnails

const cutting = [];
let cuts = 0;

/**
 * Cuts `rect` (whole pixels, inside STILL) out of STILL with ffmpeg, as the box does it (`crop=…:exact=1`): a JPEG, or null when there is no ffmpeg or it
 * fails. At most two at a time, so a fast scroll in the page is not a storm of children either. (`FFMPEG` in the environment names the program.)
 */
function cut(rect) {
  return new Promise((resolve) => {
    cutting.push({ rect, resolve });
    pump();
  });
}

function pump() {
  while (cuts < 2 && cutting.length) {
    const { rect, resolve } = cutting.shift();
    cuts += 1;
    runFFmpeg(rect).then(resolve, () => resolve(null)).finally(() => { cuts -= 1; pump(); });
  }
}

function runFFmpeg(rect) {
  return new Promise((resolve) => {
    const filters = `crop=${rect.width}:${rect.height}:${rect.x}:${rect.y}:exact=1,scale=out_range=pc,format=yuvj420p`;
    const child = spawn(process.env.FFMPEG || 'ffmpeg', ['-hide_banner', '-nostdin', '-loglevel', 'error', '-f', 'image2pipe', '-i', 'pipe:0', '-vf', filters, '-frames:v', '1',
      '-c:v', 'mjpeg', '-q:v', '4', '-f', 'mjpeg', 'pipe:1'], { stdio: ['pipe', 'pipe', 'ignore'] });
    const chunks = [];
    child.stdout.on('data', (chunk) => chunks.push(chunk));
    child.on('error', () => resolve(null));   // no ffmpeg here
    child.on('close', (code) => resolve(code === 0 && chunks.length ? Buffer.concat(chunks) : null));
    child.stdin.on('error', () => {});
    child.stdin.end(STILL);
  });
}

const NAME = /^\d{4}-\d{2}-\d{2}$/;
const SUNSET = [18, 30];
const SUNRISE = [7, 10];
const KEEP_NIGHTS = 14;
const LABELS = ['plane', 'bird', 'bug', 'satellite', 'meteor', 'notSure'];
const OWN_LABEL = { plane: 'plane', bird: 'bird', bug: 'bug', satellite: 'satellite', meteor: 'meteor' };
const AIMS = ['rough', 'good', 'mixed', 'precise'];
const LEARNING = ['learning', 'ready'];
const MINUTE = 60_000;
const HOUR = 3_600_000;

export const NEED_PLUGIN = 'Turn on Sky Watcher in Plugins first.';
export const NEED_LOCATION = 'Set where the box is first.';
export const NEED_FOLDER = 'Choose a recordings folder first: the sky log is kept with the recordings.';
export const BATTERY = 'Battery cameras can’t watch the sky: it would keep them awake.';

/** The plugin as `GET plugins` lists it (the words are BridgeWeb/Plugins/Plugins.swift's; a test keeps them equal). */
const PLUGIN = {
  id: 'sky',
  name: 'Sky Watcher',
  summary: 'Watches the sky with a camera pointed up and keeps a log of planes, satellites, meteors and anything it can’t explain.',
  needs: 'A camera that looks at the sky, and a recordings folder for the sky log.',
  needsInternet: false,
  internetNote: 'Works without the internet: planes come from a flight receiver on your network. When the internet is there, Camera Bridge can also download satellite orbits once a day and ask free online services for flights and weather in a wide area around you, never your exact spot. Nothing leaves the box while Sky Watcher is off.',
};

const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const finite = (value) => typeof value === 'number' && Number.isFinite(value);
const clamp01 = (value) => Math.min(1, Math.max(0, value));
const round = (value, places = 2) => Math.round(value * 10 ** places) / 10 ** places;

// MARK: Nights

function parseName(name) {
  if (typeof name !== 'string' || !NAME.test(name)) return null;
  const [y, m, d] = name.split('-').map(Number);
  const date = new Date(y, m - 1, d);
  return date.getFullYear() === y && date.getMonth() === m - 1 && date.getDate() === d ? [y, m, d] : null;
}

export const nameOf = (date) => `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;

/** The window of a night (6:30 PM to the next 7:10 AM) or a day (midnight to midnight), in this computer's zone, as epoch ms. */
export function windowOf(name, view) {
  const [y, m, d] = parseName(name);
  if (view === 'day') return { from: new Date(y, m - 1, d).getTime(), to: new Date(y, m - 1, d + 1).getTime() };
  return { from: new Date(y, m - 1, d, ...SUNSET).getTime(), to: new Date(y, m - 1, d + 1, ...SUNRISE).getTime() };
}

/** The name of the latest night (the one that began at the last 6:30 PM) or day (today) at `now`. */
export function latestName(now, view) {
  const date = new Date(now);
  const today = nameOf(date);
  if (view === 'day') return today;
  return now >= new Date(date.getFullYear(), date.getMonth(), date.getDate(), ...SUNSET).getTime() ? today : nameOf(new Date(date.getFullYear(), date.getMonth(), date.getDate() - 1));
}

const hash = (text) => { let h = 2166136261; for (const c of text) { h ^= c.codePointAt(0); h = Math.imul(h, 16777619); } return h >>> 0; };
function seeded(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// MARK: Entries

const wrap = (azimuth) => round(((azimuth % 360) + 360) % 360);
const pictureX = (azimuth) => clamp01(((((azimuth + 90) % 360) + 360) % 360) / 180);   // facing north: 270° to 90° across the picture
const pictureY = (elevation) => clamp01(0.88 - (elevation / 80) * 0.88);                  // the ground is the bottom 12 %

/** One entry as the bridge stores it (Task 5's SkyEntry), before its id and any correction. */
function make(rand, { kind = 'track', label, start, duration, azimuth, elevation, azimuthEnd = azimuth, elevationEnd = elevation, shape = 'straight', blinks = false, blinkRate = null,
  speed = 1, size = 0.08, brightness = 120, focus = 1, by = null, detail = null, speedVsPlanes = null, unusual = [], candidate = false, alerted = false, hasStill = false, ai = null, points = 8,
  priority = null, reasons = [], together = null, sortedLater = false }) {
  const count = kind === 'track' ? points : kind === 'flash' ? 3 : 1;
  const path = [];
  for (let i = 0; i < count; i += 1) {
    const f = count === 1 ? 0 : i / (count - 1);
    const bend = shape === 'curved' ? Math.sin(f * Math.PI) * 0.03 : 0;
    path.push({
      t: round(f * duration),
      x: round(clamp01(pictureX(azimuth + (azimuthEnd - azimuth) * f) + (rand() - 0.5) * 0.004), 4),
      y: round(clamp01(pictureY(elevation + (elevationEnd - elevation) * f) - bend + (rand() - 0.5) * 0.004), 4),
    });
  }
  return {
    id: '', camera: '', kind, start, end: start + Math.round(duration * 1000), path,
    measures: {
      azimuth: wrap(azimuth), elevation, azimuthEnd: wrap(azimuthEnd), elevationEnd, duration, speed, acceleration: 0, turnRate: shape === 'straight' ? 0.02 : 0.4, maxTurn: shape === 'sharpTurn' ? 70 : shape === 'curved' ? 18 : 4,
      straightness: shape === 'straight' ? 0.99 : 0.9, shape, sizeDegrees: size, brightness, blinks, blinkRate, focus,
      strobePeriod: null, strobeStrength: null, seenShare: null, wobble: null, turns: null,
    },
    label, by, detail, unusual, speedVsPlanes, candidate, alerted, hasStill, ai, correction: null,
    // The guide to the unexplained (the bridge's SkyGuide): a priority and its reasons; `together` names the made-up group a light is in (the
    // bridge finds the groups as it reads the log; `finish` names them after their first light).
    priority: label === 'unexplained' ? priority ?? 'low' : null, reasons: label === 'unexplained' ? (reasons.length ? reasons : ['Nothing unusual about it']) : [],
    doubtful: false, group: null, together,
    // Logged before the rules, and sorted by them as the bridge read the night (SkySortLater): the player says so.
    sortedLater,
  };
}

const CALLSIGNS = ['AAL', 'UAL', 'DAL', 'SWA', 'FDX', 'UPS', 'JBU', 'ASA', 'NKS', 'EJA'];
const flightDetail = (rand, high = false) => {
  const call = rand() < 0.12 ? `N${100 + Math.floor(rand() * 899)}${'ABCDEFGHJKLMNPRSTUVWXYZ'[Math.floor(rand() * 23)]}${'ABCDEFGHJKLMNPRSTUVWXYZ'[Math.floor(rand() * 23)]}`
    : `${CALLSIGNS[Math.floor(rand() * CALLSIGNS.length)]}${10 + Math.floor(rand() * 4989)}`;
  const feet = high ? 30_000 + Math.floor(rand() * 11) * 1000 : 6000 + Math.floor(rand() * 340) * 100;
  return `${call} · ${feet.toLocaleString('en-US')} ft`;
};
const SATELLITES = ['STARLINK', 'STARLINK', 'STARLINK', 'STARLINK', 'ONEWEB', 'COSMOS', 'IRIDIUM', 'SPACEX'];
const satelliteName = (rand) => {
  const family = SATELLITES[Math.floor(rand() * SATELLITES.length)];
  return `${family}-${1000 + Math.floor(rand() * 5800)}`;
};
const compass = (rand) => (rand() < 0.5 ? 270 + rand() * 90 : rand() * 90);   // somewhere in the north half of the view

/**
 * The made-up log of a night, as Task 5's store would hold it: busy, as a real one is, and most lights with a still (the box makes one for nearly
 * every light now). About 860 lights: planes and their strobes, two waves of satellites, meteors, bugs and birds, and the lights nothing explains,
 * 200 of them (the most the box logs in an hour) at 9 PM. `busy` (POST /__dev/sky {"busy": true}) is a night of about 2,600, the most a box logs:
 * many more lights nothing explains in every hour, at most 200 an hour.
 */
function nightEntries(name, camera, { busy = false } = {}) {
  const { from, to } = windowOf(name, 'night');
  const rand = seeded(hash(`${camera}|${name}|night${busy ? '|busy' : ''}`));
  const span = to - from;
  const [y, m, d] = parseName(name);
  const local = (hours, minutes = 0, seconds = 0, plus = 1) => new Date(y, m - 1, d + plus, hours, minutes, seconds).getTime();
  const still = (share) => rand() < share;
  const entries = [];

  // Planes: busy in the evening and at dawn, fewer in the small hours.
  for (let i = 0; i < (busy ? 170 : 120); i += 1) {
    let x;
    do { x = rand(); } while (rand() > 0.2 + 0.8 * Math.exp(-(((x - 0.18) / 0.22) ** 2)) + 0.5 * Math.exp(-(((x - 0.93) / 0.07) ** 2)));
    const duration = 25 + rand() * 60;
    const azimuth = compass(rand);
    entries.push(make(rand, {
      label: rand() < 0.15 ? 'probablePlane' : 'plane', by: 'flight', detail: flightDetail(rand), start: Math.round(from + x * (span - 100_000)), duration, azimuth,
      elevation: 12 + rand() * 50, azimuthEnd: azimuth + (rand() < 0.5 ? -1 : 1) * (15 + rand() * 40), elevationEnd: 10 + rand() * 50, speed: round(0.8 + rand() * 1.2), size: 0.05, brightness: 140,
      blinks: rand() < 0.6, blinkRate: 1, hasStill: still(0.7),
    }));
  }
  // Distant planes near the skyline: only their strobes show, crawling along the horizon.
  for (let i = 0; i < 24; i += 1) {
    const x = 0.04 + rand() * 0.9;
    const azimuth = rand() < 0.5 ? 280 + rand() * 60 : 15 + rand() * 60;
    entries.push(make(rand, {
      kind: 'flash', label: 'probablePlane', by: 'flight', detail: flightDetail(rand, true), start: Math.round(from + x * span), duration: 20 + rand() * 25, azimuth,
      elevation: 1 + rand() * 4, azimuthEnd: azimuth + (rand() < 0.5 ? -1 : 1) * (4 + rand() * 6), speed: round(0.1 + rand() * 0.2), size: 0.03, brightness: 90, blinks: true, blinkRate: round(0.9 + rand() * 0.3),
      hasStill: still(0.5),
    }));
  }
  // Satellites come in waves, after dusk and before dawn, while they are in sunlight and the sky is dark.
  const satellites = busy ? 420 : 360;
  for (let i = 0; i < satellites; i += 1) {
    const evening = i < satellites / 2;
    const start = evening ? from + 20 * MINUTE + rand() * 90 * MINUTE : to - 90 * MINUTE + rand() * 70 * MINUTE;
    const azimuth = compass(rand);
    const station = i === 7;
    // One in four is a probable satellite (the rules': a steady light at a steady speed where a satellite can be in the sunlight, no orbit to name it).
    const probable = !station && i % 4 === 3;
    entries.push(make(rand, {
      label: i % 63 === 62 ? 'satelliteFlare' : probable ? 'probableSatellite' : 'satellite', by: probable ? 'rule' : 'orbit',
      detail: station ? 'ISS (ZARYA)' : probable ? 'Probable satellite: a steady light at a steady speed (no orbit check yet)' : satelliteName(rand),
      start: Math.round(start), duration: station ? 95 : 35 + rand() * 70,
      azimuth, elevation: 18 + rand() * 55, azimuthEnd: azimuth + (rand() < 0.5 ? -1 : 1) * (20 + rand() * 50), elevationEnd: 15 + rand() * 55, speed: round(0.3 + rand() * 0.6), size: 0.03, brightness: station ? 400 : 70,
      hasStill: still(0.65),
    }));
  }
  // Meteors: short, straight and fast.
  for (let i = 0; i < 14; i += 1) {
    const azimuth = compass(rand);
    entries.push(make(rand, {
      label: 'meteor', by: 'rule', start: Math.round(from + (0.15 + rand() * 0.8) * span), duration: round(0.4 + rand() * 0.8), azimuth, elevation: 25 + rand() * 35, azimuthEnd: azimuth + 6 + rand() * 8,
      elevationEnd: 10 + rand() * 20, speed: round(18 + rand() * 20), size: 0.1, brightness: 500, points: 4, hasStill: i === 0 || still(0.8),
    }));
  }
  // Bugs near the lens, more in the warm evening, and birds at dusk and dawn.
  for (let i = 0; i < 48; i += 1) {
    entries.push(make(rand, {
      label: 'bug', by: 'rule', start: Math.round(from + (rand() < 0.6 ? 0.02 + rand() * 0.3 : 0.3 + rand() * 0.65) * span), duration: round(1 + rand() * 3), azimuth: compass(rand), elevation: 8 + rand() * 40,
      shape: 'sharpTurn', speed: round(4 + rand() * 6), size: 1.2, brightness: 260, focus: 0.3, points: 6, hasStill: still(0.75),
    }));
  }
  for (let i = 0; i < 24; i += 1) {
    entries.push(make(rand, {
      label: 'bird', by: 'rule', start: Math.round(i < 16 ? from + (0.005 + rand() * 0.06) * span : to - (0.02 + rand() * 0.06) * span), duration: round(3 + rand() * 6), azimuth: compass(rand),
      elevation: 10 + rand() * 30, azimuthEnd: 40, shape: 'curved', speed: round(2 + rand() * 2), size: 0.4, brightness: 80, focus: 0.6, hasStill: still(0.75),
    }));
  }
  // What nothing explains: a fast light low in the northwest, and brief bright lights that rise, hold and fade, and flashes on the skyline.
  entries.push(make(rand, {
    label: 'unexplained', start: local(3, 12, 8), duration: 4.2, azimuth: 312, elevation: 8, azimuthEnd: 330, elevationEnd: 14, shape: 'curved', speed: 3.1, size: 0.3, brightness: 900, blinks: true, blinkRate: 1,
    speedVsPlanes: 6.1, unusual: ['faster', 'larger'], candidate: true, alerted: true, hasStill: true, points: 12,
    priority: 'high', reasons: ['Fast across the sky (about 6× a plane at that height)', 'Looks larger than planes here'],
    ai: { kind: 'unknown', sentence: 'A small bright light moving quickly low on the horizon; it doesn’t look like a plane.', model: 'claude-haiku-5-5', at: local(3, 12, 40) },
  }));
  for (const [hours, minutes, azimuth, elevation, duration, extra] of [
    [1, 5, 20, 24, 9, { unusual: ['brighter'], ai: { kind: 'artifact', sentence: 'A steady point of light that brightens and fades, like a reflection in the lens.', model: 'claude-haiku-5-5', at: local(1, 6, 10) } }],
    [2, 41, 350, 31, 12, {}], [4, 30, 5, 22, 6, {}],
  ]) {
    entries.push(make(rand, { kind: 'newLight', label: 'unexplained', start: local(hours, minutes, 14), duration, azimuth, elevation, shape: 'curved', speed: 0.02, size: 0.2, brightness: 700, candidate: true, hasStill: true,
      priority: 'medium', reasons: extra.unusual ? ['Looks brighter than planes and satellites here'] : ['Appeared and stayed on one spot for seconds'], ...extra }));
  }
  for (const [hours, minutes, azimuth, rate, duration] of [[23, 40, 300, 1.2, 5], [4, 5, 40, 2, 3]]) {
    entries.push(make(rand, {
      kind: 'flash', label: 'unexplained', start: local(hours, minutes, 31, hours > 12 ? 0 : 1), duration, azimuth, elevation: 4, azimuthEnd: azimuth + 3, speed: 0.1, size: 0.05, brightness: 300,
      blinks: true, blinkRate: rate, candidate: true, hasStill: true,
    }));
  }
  // A swarm at 9 PM: as many lights nothing explains as the box logs in an hour (the hour's note says how many more it followed), and
  // others through the night; a busy night has them in every hour.
  const unexplained = (start) => {
    const pick = rand();
    const kind = pick < 0.45 ? 'newLight' : pick < 0.8 ? 'track' : 'flash';
    const azimuth = compass(rand);
    const elevation = 5 + rand() * 55;
    const track = kind === 'track';
    return make(rand, {
      kind, label: 'unexplained', start: Math.round(start), duration: kind === 'flash' ? round(0.2 + rand()) : round(1 + rand() * (track ? 14 : 8)), azimuth, elevation,
      azimuthEnd: azimuth + (track ? (rand() - 0.5) * 30 : 0), elevationEnd: elevation + (track ? (rand() - 0.5) * 16 : 0), shape: ['straight', 'curved', 'suddenStop', 'sharpTurn'][Math.floor(rand() * 4)],
      speed: round(track ? 0.5 + rand() * 4 : 0.02), speedVsPlanes: track ? round(0.4 + rand() * 5) : null, size: round(0.05 + rand() * 0.3), brightness: Math.round(150 + rand() * 700),
      blinks: kind === 'flash' || rand() < 0.2, blinkRate: round(0.5 + rand() * 2), candidate: true, hasStill: true, points: track ? 10 : 1,
      ...guided(track && rand() < 0.3 ? ['faster'] : rand() < 0.1 ? ['brighter'] : [], kind),
    });
  };
  /** The guide of a made-up light nothing explains, from what is unusual about it. */
  function guided(unusual, kind) {
    if (unusual.includes('faster')) return { unusual, candidate: true, priority: 'high', reasons: [`Fast across the sky (about ${2 + Math.floor(rand() * 7)}× a plane at that height)`] };
    if (unusual.includes('brighter')) return { unusual, candidate: true, priority: 'medium', reasons: ['Looks brighter than planes and satellites here'] };
    return { unusual, candidate: false, priority: 'low', reasons: [kind === 'flash' ? 'Too short to tell what it was' : 'Nothing unusual about it'] };
  }
  // Three lights crossing together at 10:15 PM, the same way at the same pace: one group, high.
  for (let i = 0; i < 3; i += 1) {
    entries.push(make(rand, {
      label: 'unexplained', start: local(22, 15, 5 + i * 3, 0), duration: 18, azimuth: 300 + i * 2, elevation: 30 - i * 3, azimuthEnd: 320 + i * 2, elevationEnd: 34 - i * 3,
      speed: 1.2, size: 0.2, brightness: 600, hasStill: true, points: 10, priority: 'high', reasons: ['Several lights moving together'], together: 'swarm-2215',
    }));
  }
  const swarm = local(21, 0, 0, 0);
  for (let i = 0; i < 200; i += 1) entries.push(unexplained(swarm + 20_000 + rand() * (HOUR - 60_000)));
  const others = busy ? 1700 : 60;
  for (let i = 0; i < others; i += 1) {
    let start;
    do { start = from + 60_000 + rand() * (span - 180_000); } while (start >= swarm && start < swarm + HOUR);
    entries.push(unexplained(start));
  }
  return finish(entries, 'n', name, camera);
}

/** The made-up log of a day: planes, birds and bugs, and one glint. No satellites are in sight, and no meteors. */
function dayEntries(name, camera) {
  const { from, to } = windowOf(name, 'day');
  const rand = seeded(hash(`${camera}|${name}|day`));
  const span = to - from;
  const [y, m, d] = parseName(name);
  const entries = [];
  for (let i = 0; i < 22; i += 1) {
    const azimuth = compass(rand);
    entries.push(make(rand, {
      label: rand() < 0.1 ? 'probablePlane' : 'plane', by: 'flight', detail: flightDetail(rand), start: Math.round(from + (0.25 + rand() * 0.7) * span), duration: 20 + rand() * 50, azimuth, elevation: 15 + rand() * 50,
      azimuthEnd: azimuth + (rand() < 0.5 ? -1 : 1) * (20 + rand() * 40), speed: round(0.8 + rand() * 1.2), size: 0.05, brightness: 60,
    }));
  }
  // Nine birds, three of them logged before the rules (an older box) and sorted by them as the night is read.
  for (let i = 0; i < 9; i += 1) {
    entries.push(make(rand, { label: 'bird', by: 'rule', start: Math.round(from + (0.25 + rand() * 0.65) * span), duration: round(3 + rand() * 8), azimuth: compass(rand), elevation: 10 + rand() * 45, shape: 'curved', speed: 3, size: 0.4, brightness: 50, focus: 0.6,
      sortedLater: i < 3 }));
  }
  for (let i = 0; i < 6; i += 1) {
    entries.push(make(rand, { label: 'bug', by: 'rule', start: Math.round(from + (0.3 + rand() * 0.6) * span), duration: round(1 + rand() * 3), azimuth: compass(rand), elevation: 5 + rand() * 40, shape: 'sharpTurn', speed: 6, size: 1.2, brightness: 40, focus: 0.3, points: 6 }));
  }
  entries.push(make(rand, {
    kind: 'newLight', label: 'unexplained', start: new Date(y, m - 1, d, 14, 20, 5).getTime(), duration: 7, azimuth: 340, elevation: 38, shape: 'curved', speed: 0.02, size: 0.15, brightness: 600, candidate: true, hasStill: true,
    ai: { kind: 'artifact', sentence: 'A bright spot that comes and goes in daylight, probably a reflection off the lens or a window.', model: 'claude-haiku-5-5', at: new Date(y, m - 1, d, 14, 20, 40).getTime() },
  }));
  return finish(entries, 'd', name, camera);
}

/** Sorted by time, with ids that tell the view and the night (so a still or a correction can find its entry again). */
function finish(entries, prefix, name, camera) {
  entries.sort((a, b) => a.start - b.start || a.label.localeCompare(b.label));
  entries.forEach((entry, index) => { entry.id = `${prefix}${String(index).padStart(3, '0')}-${name}`; entry.camera = camera; });
  // A group is named after its first light, as the bridge names it.
  const first = new Map();
  for (const entry of entries) {
    if (entry.together && !first.has(entry.together)) first.set(entry.together, `g-${entry.id}`);
    entry.group = entry.together ? first.get(entry.together) : null;
    delete entry.together;
  }
  return entries;
}

// MARK: Counts, conditions, the aim

/** Which count an entry is in (what the bridge counts): "not sure" holds the explained entries the person doubted. */
function bucketOf(entry) {
  if (entry.display === 'unexplained') return 'unexplained';
  if (entry.correction === 'notSure') return 'notSure';
  return { plane: 'planes', probablePlane: 'planes', satellite: 'satellites', probableSatellite: 'satellites', satelliteFlare: 'satellites', meteor: 'meteors', bug: 'bugsAndBirds',
    bird: 'bugsAndBirds' }[entry.display];
}

function countsOf(entries) {
  const counts = { unexplained: 0, planes: 0, satellites: 0, meteors: 0, bugsAndBirds: 0, notSure: 0, explained: 0 };
  for (const entry of entries) {
    const bucket = bucketOf(entry);
    counts[bucket] += 1;
    if (bucket !== 'unexplained') counts.explained += 1;
  }
  return counts;
}

/** The sky's conditions: the latest night is clear until 3 AM, not visible from 3 to 5 AM, then clear (the example of the page's words); others vary. */
function conditionsOf(name, view, now) {
  const { from, to } = windowOf(name, view);
  const [y, m, d] = parseName(name);
  const at = (hours, plus = 1) => new Date(y, m - 1, d + plus, hours).getTime();
  let spans;
  if (view === 'day') spans = [{ from, to, state: 'clear', cloudCover: 15 }];
  else {
    const style = name === latestName(now, 'night') ? 0 : hash(name) % 3;
    spans = style === 0 ? [{ from, to: at(3), state: 'clear', cloudCover: 10 }, { from: at(3), to: at(5), state: 'notVisible', cloudCover: 95 }, { from: at(5), to, state: 'clear', cloudCover: 20 }]
      : style === 1 ? [{ from, to, state: 'clear', cloudCover: 5 }]
        : [{ from, to: at(22, 0), state: 'clear', cloudCover: 15 }, { from: at(22, 0), to: at(1), state: 'cloudy', cloudCover: 70 }, { from: at(1), to, state: 'clear', cloudCover: 10 }];
  }
  return spans.filter((span) => span.from < now).map((span) => ({ ...span, to: Math.min(span.to, now) }));
}

/** The hours in which the box followed more lights than it logs (at most 200 an hour): the latest night's 9 PM had 37 more, once it is over. */
function cappedOf(name, view, now) {
  if (view !== 'night' || name !== latestName(now, 'night')) return [];
  const [y, m, d] = parseName(name);
  const hour = new Date(y, m - 1, d, 21).getTime();
  return hour + HOUR <= now ? [{ hour, count: 37 }] : [];
}

const lens = (quality, planes, stars, residualPixels) => ({ quality, planes, stars, residualPixels });
function aimStatus(kind, rightNow) {
  const now = Math.floor(rightNow / HOUR) * HOUR;   // the fit's time moves once an hour, not with every request (the page is told of a camera that changed)
  switch (kind) {
    case 'rough': return { quality: 'rough', planes: 3, stars: 0, residualPixels: null, updated: null, lenses: [], note: null };
    case 'precise': return { quality: 'precise', planes: 61, stars: 401, residualPixels: 1.8, updated: now - HOUR, lenses: [lens('precise', 30, 214, 1.8), lens('precise', 31, 187, 2.1)], note: null };
    case 'mixed': return { quality: 'good', planes: 53, stars: 214, residualPixels: 6.3, updated: now - 3 * HOUR, lenses: [lens('precise', 30, 214, 1.8), lens('good', 23, 0, 14)], note: null };
    default: return { quality: 'good', planes: 40, stars: 0, residualPixels: 6.4, updated: now - 3 * HOUR, lenses: [lens('good', 23, 0, 5.1), lens('good', 17, 0, 7.9)], note: null };
  }
}
const learningStatus = (kind) => (kind === 'ready' ? { ready: true, planes: 34, satellites: 11 } : { ready: false, planes: 12, satellites: 4 });

// MARK: The state

export class SkyDev {
  constructor() { this.reset(); }

  reset() {
    this.pluginOn = false;   // a new box: the plugin is off
    this.settings = { location: { latitude: 40, longitude: -100, heightMeters: 0 }, flightFeedURL: null, aiDailyLimit: 50 };
    this.corrections = new Map();   // camera|night|entry id -> label
    this.aim = 'mixed';
    this.learning = 'learning';
    this.problem = null;
    this.stream = 'main';
    this.feeds = ['http://192.168.77.20/tar1090/data/aircraft.json'];
    this.busy = false;   // nights of about 2,600 lights (POST /__dev/sky {"busy": true})
    this.thumbnails = new Map();   // a close-up's rectangle -> the promise of its JPEG
  }

  /** GET plugins: the one plugin this server has, with its switch. */
  pluginList() {
    return [{ ...PLUGIN, enabled: this.pluginOn }];
  }

  /** PATCH plugins/:id {enabled}: the switch. 404 for a plugin this server does not have, 400 for an `enabled` that is not on or off. */
  patchPlugin(id, body) {
    if (id !== PLUGIN.id) throw ApiError.notFound('There is no plugin with this name.');
    if (typeof body.enabled !== 'boolean') throw ApiError.invalid('“enabled” is missing.', 'enabled');
    this.pluginOn = body.enabled;
    return this.pluginList();
  }

  /** GET settings' `sky`. */
  settingsView() {
    return { location: this.settings.location ? { ...this.settings.location } : null, flightFeedURL: this.settings.flightFeedURL, aiDailyLimit: this.settings.aiDailyLimit };
  }

  /** PATCH settings {sky}: a place on the map, a feed with a host, a limit of 1 to 1000; a refusal changes nothing. */
  patchSettings(value) {
    if (!isObject(value)) throw ApiError.invalid('“sky” isn’t what was expected.', 'sky');
    const next = { ...this.settings };
    if ('location' in value) {
      if (value.location === null) next.location = null;
      else {
        const { latitude, longitude, heightMeters } = isObject(value.location) ? value.location : {};
        if (!finite(latitude) || !finite(longitude) || Math.abs(latitude) > 90 || Math.abs(longitude) > 180 || (latitude === 0 && longitude === 0)) {
          throw ApiError.invalid('That isn’t a place on the map. Latitude is from −90 to 90 and longitude from −180 to 180.', 'sky.location');
        }
        next.location = { latitude, longitude, heightMeters: finite(heightMeters) ? heightMeters : this.settings.location?.heightMeters ?? 0 };
      }
    }
    if ('flightFeedURL' in value) {
      if (value.flightFeedURL === null || value.flightFeedURL === '') next.flightFeedURL = null;
      else {
        let url = null;
        try { url = new URL(String(value.flightFeedURL)); } catch { /* not an address */ }
        if (!url || !['http:', 'https:'].includes(url.protocol) || !url.hostname) throw ApiError.invalid('The flight feed’s address must start with http:// or https:// and name a computer.', 'sky.flightFeedURL');
        next.flightFeedURL = String(value.flightFeedURL);
      }
    }
    if ('aiDailyLimit' in value) {
      if (!Number.isInteger(value.aiDailyLimit) || value.aiDailyLimit < 1 || value.aiDailyLimit > 1000) throw ApiError.invalid('The daily limit is a whole number from 1 to 1000.', 'sky.aiDailyLimit');
      next.aiDailyLimit = value.aiDailyLimit;
    }
    this.settings = next;
  }

  /**
   * PATCH cameras/:id {skyDetector}: the whole setting checked, then (when it turns on) what it needs: the plugin, a camera that does not run on a
   * battery, a place for the box and a place for recordings, in that order. Nothing changes when anything is refused. Saying "off", or changing the
   * aim, needs none of them: every camera keeps its settings while the plugin is off.
   */
  patchCamera(camera, value, { hasFolder }) {
    if (!isObject(value)) throw ApiError.invalid('“skyDetector” isn’t what was expected.', 'skyDetector');
    const was = camera.configuration.skyDetector;
    const next = { enabled: was?.enabled ?? false, facing: was?.facing ?? 0, tilt: was?.tilt ?? 20, groundPercent: was?.groundPercent ?? 12, nightProfile: was?.nightProfile ?? true, ...(was?.lensLayout ? { lensLayout: was.lensLayout } : {}) };
    const check = (name, ok, message) => { if (name in value && !ok(value[name])) throw ApiError.invalid(message, `skyDetector.${name}`); if (name in value) next[name] = value[name]; };
    check('enabled', (v) => typeof v === 'boolean', '“enabled” is on or off.');
    check('facing', (v) => finite(v) && v >= 0 && v < 360, 'Which way the camera faces is a number of degrees from 0 to 359.');
    check('tilt', (v) => finite(v) && v >= 0 && v <= 90, 'Tilt is a number of degrees from 0 to 90.');
    check('groundPercent', (v) => Number.isInteger(v) && v >= 0 && v <= 60, 'Ground and horizon is a whole number from 0 to 60 percent.');
    check('nightProfile', (v) => typeof v === 'boolean', '“nightProfile” is on or off.');
    check('lensLayout', (v) => v === 'single' || v === 'dual', 'The lens layout is single or dual.');
    if (value.enabled === true && !this.pluginOn) throw ApiError.invalid(NEED_PLUGIN, 'plugins.sky');
    if (next.enabled && !was?.enabled) {
      if (camera.definition.battery) throw ApiError.invalid(BATTERY, 'skyDetector.enabled');
      if (!this.settings.location) throw ApiError.invalid(NEED_LOCATION, 'sky.location');
      if (!hasFolder) throw ApiError.invalid(NEED_FOLDER, 'nvrFolder');
    }
    camera.configuration.skyDetector = next;
  }

  /** status.sky of a camera that watches the sky (undefined for one that does not, and for every camera while the plugin is off: the bridge leaves the key out). */
  statusFor(camera, now) {
    if (!this.pluginOn || camera.configuration.skyDetector?.enabled !== true) return undefined;
    return {
      running: true, stream: this.stream, analysisWidth: this.stream === 'main' ? 1920 : 1280, picturesPerSecond: 5,
      aim: aimStatus(this.aim, now), learning: learningStatus(this.learning), problem: this.problem, profile: null,
    };
  }

  /** The base log of a night or a day (what the box wrote, before corrections and before "now"); nothing for a camera that never watched, or a night out of range. */
  baseEntries(camera, name, view, now) {
    if (!camera.configuration.skyDetector) return [];
    const today = parseName(latestName(now, view));
    const oldest = new Date(today[0], today[1] - 1, today[2] - KEEP_NIGHTS).getTime();
    const { from } = windowOf(name, view);
    if (from < oldest || from > now) return [];
    return view === 'day' ? dayEntries(name, camera.definition.id) : nightEntries(name, camera.definition.id, { busy: this.busy });
  }

  /** The entries of a night as they stand at `now`: only what has happened, each with its correction and its `display` and `watch`. */
  entries(camera, name, view, now) {
    return this.baseEntries(camera, name, view, now).filter((entry) => entry.end <= now).map((entry) => this.present(camera, name, entry));
  }

  present(camera, name, entry) {
    const correction = this.corrections.get(`${camera.definition.id}|${name}|${entry.id}`) ?? null;
    return { ...entry, correction, display: correction && OWN_LABEL[correction] ? OWN_LABEL[correction] : entry.label, watch: entry.start - 3000 };
  }

  /** GET sky/cameras/:id/night?date=yyyy-MM-dd&view=night|day. */
  night(camera, query, now) {
    const view = query.get('view') ?? 'night';
    if (view !== 'night' && view !== 'day') throw ApiError.invalid('Give “view” as night or day.', 'view');
    const date = query.get('date');
    if (date !== null && !parseName(date)) throw ApiError.invalid('Give “date” as yyyy-MM-dd, for example 2026-10-24.', 'date');
    const name = date ?? latestName(now, view);
    const { from, to } = windowOf(name, view);
    const entries = this.entries(camera, name, view, now);
    return {
      camera: camera.definition.id, night: name, view, from, to, serverTime: now, entries, conditions: conditionsOf(name, view, now), counts: countsOf(entries),
      aim: aimStatus(this.aim, now), learning: learningStatus(this.learning), capped: cappedOf(name, view, now),
      picture: entries.some((entry) => entry.hasStill) ? { ...STILL_SIZE } : null,
    };
  }

  /** The entry of an id in a night (null when there is none): ids say the view (n or d) and the night. */
  find(camera, id, name, now) {
    const view = id[0] === 'd' ? 'day' : 'night';
    if (!parseName(name) || !id.endsWith(`-${name}`)) return null;
    return this.entries(camera, name, view, now).find((entry) => entry.id === id) ?? null;
  }

  /**
   * GET sky/cameras/:id/entries/:eid/still?night=…[&size=thumb]: the picture, or 404. With size=thumb the close-up of the light, as the box cuts it (the
   * page’s own rule, `thumbRect`, in the picture’s pixels): a JPEG of just that part, made with ffmpeg when there is one and the whole picture when there is
   * not (it is small already). Any other size is 400 with the field `size`.
   */
  async still(camera, id, query, now) {
    const size = query.get('size');
    const found = this.find(camera, id, query.get('night') ?? '', now);
    if (!found?.hasStill) throw ApiError.notFound('There is no picture for that.');
    if (size !== null && size !== 'full' && size !== 'thumb') throw ApiError.invalid('Choose thumb for a small picture, or leave size out for the whole picture.', 'size');
    const picture = size === 'thumb' ? await this.thumbnail(found) : STILL;
    return bytes(picture, 'image/jpeg', { 'Cache-Control': 'no-store' });
  }

  /** The small picture of an entry: its close-up cut out of STILL, or STILL itself when there is no close-up or no ffmpeg to cut it with. */
  thumbnail(entry) {
    const rect = thumbRect(entry.path, STILL_SIZE.width, STILL_SIZE.height);
    if (!rect || rect.width > THUMB_WIDTH) return STILL;
    const key = `${rect.x},${rect.y},${rect.width},${rect.height}`;
    if (!this.thumbnails.has(key)) {
      this.thumbnails.set(key, cut(rect).then((jpeg) => jpeg ?? STILL));
    }
    return this.thumbnails.get(key);
  }

  /** POST sky/cameras/:id/entries/:eid/correction {night, label}: the entry as it is now. */
  correct(camera, id, body, now) {
    if (!LABELS.includes(body.label)) throw ApiError.invalid('That isn’t a label Sky Watcher knows: plane, bird, bug, satellite, meteor or notSure.', 'label');
    if (!parseName(body.night)) throw ApiError.invalid('Give “night” as yyyy-MM-dd.', 'night');
    if (!this.find(camera, id, body.night, now)) throw ApiError.notFound('There is no such entry in that night.');
    this.corrections.set(`${camera.definition.id}|${body.night}|${id}`, body.label);
    return this.find(camera, id, body.night, now);
  }

  /**
   * POST /__dev/sky: whether the plugin is on, what the box reports (aim, learning, problem, stream), where it is, the feeds Find a feed finds,
   * and whether its nights are as busy as a box's can be (`busy`: about 2,600 lights).
   */
  control(input) {
    if ('plugin' in input) {
      if (typeof input.plugin !== 'boolean') throw ApiError.invalid('The plugin is on or off.', 'plugin');
      this.pluginOn = input.plugin;
    }
    if ('busy' in input) {
      if (typeof input.busy !== 'boolean') throw ApiError.invalid('A busy night is on or off.', 'busy');
      this.busy = input.busy;
    }
    if ('aim' in input) {
      if (!AIMS.includes(input.aim)) throw ApiError.invalid(`The aims are ${AIMS.join(', ')}.`, 'aim');
      this.aim = input.aim;
    }
    if ('learning' in input) {
      if (!LEARNING.includes(input.learning)) throw ApiError.invalid(`Learning is ${LEARNING.join(' or ')}.`, 'learning');
      this.learning = input.learning;
    }
    if ('problem' in input) this.problem = typeof input.problem === 'string' && input.problem ? input.problem : null;
    if ('stream' in input) {
      if (input.stream !== 'main' && input.stream !== 'sub') throw ApiError.invalid('The stream is main or sub.', 'stream');
      this.stream = input.stream;
    }
    if ('location' in input) this.patchSettings({ location: input.location });
    if ('feeds' in input) this.feeds = Array.isArray(input.feeds) ? input.feeds.filter((url) => typeof url === 'string') : [];
  }
}
