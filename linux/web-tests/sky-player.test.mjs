// Sky Watcher's clip player (screens/sky-player.js, sky-player-model.js): a modal on the sky log that plays the camera's recording around one
// light with the Monitor's own playback (its catalog, session, cells and grid controller, its transport, keys and scrubbing) and the Monitor's
// own zoom (js/live/zoom.js, whose gestures zoom.test.mjs checks). The window from 15 s before the light to 15 s after it and its widening, the
// light's path at the matching times, Zoom to the light, the keys bounded by the window, what it says when there is no recording to play, and,
// against the real session over the fake archive, that paused stays paused while scrubbing and stepping, that the end of the window pauses,
// that closing it frees the stream, that the marker hides and shows (its button and M) and is remembered, that the marker follows the zoom,
// and that Escape gives the whole picture back before it closes.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { after, before, describe, it, test } from 'node:test';
import { installFakeBrowser, makeStorage } from './support/fake-browser.mjs';
import { givePicture, recordingCanvases } from './support/fake-picture.mjs';
import { createRig } from './player-fakes/rig.mjs';
import { FILE_A, FILE_B, ORIGIN } from './player-fakes/fake-archive.mjs';
import { DEFAULT_POLICY } from '../web/js/nvr/planner.js';
import { KEY_MAP } from '../web/js/screens/nvr-model.js';
import { SKY_TEXT, normalizeEntry } from '../web/js/screens/sky-model.js';
import {
  SKY_KEY_MAP, WINDOW, clipWindow, clockText, marginText, overlayViewBox, pathPointAt, playerNotice, widenMargin, windowedAction, zoomAt,
} from '../web/js/screens/sky-player-model.js';

const CHICAGO = 'America/Chicago';
/** 25 October 2026, `hour:minute:second` in Chicago, as epoch ms. */
const chicago = (hour, minute = 0, second = 0) => Date.UTC(2026, 9, 25, hour + 5, minute, second);
const T = SKY_TEXT.player;

// MARK: The window

test('the window runs from 15 s before the light to 15 s after it, and widens by a minute or five on both sides', () => {
  const entry = { start: chicago(3, 12, 8), end: chicago(3, 12, 12) };
  assert.deepEqual(WINDOW, { marginMs: 15_000, widenMs: [60_000, 300_000], maxMarginMs: 30 * 60_000 });
  assert.deepEqual(clipWindow(entry), { from: entry.start - 15_000, to: entry.end + 15_000, start: entry.start, end: entry.end, marginMs: 15_000 });
  assert.equal(widenMargin(15_000, 60_000), 75_000);
  assert.equal(widenMargin(75_000, 300_000), 375_000);
  assert.deepEqual(clipWindow(entry, 375_000), { from: entry.start - 375_000, to: entry.end + 375_000, start: entry.start, end: entry.end, marginMs: 375_000 });
  assert.equal(widenMargin(29 * 60_000, 300_000), 30 * 60_000, 'at most half an hour on each side');
  // A flash has no length of its own: the window is still 30 s.
  assert.deepEqual(clipWindow({ start: entry.start, end: entry.start }), { from: entry.start - 15_000, to: entry.start + 15_000, start: entry.start, end: entry.start, marginMs: 15_000 });
  assert.deepEqual([15_000, 75_000, 60_000, 375_000, 1_800_000].map(marginText),
    ['15 s before and after', '1 min 15 s before and after', '1 min before and after', '6 min 15 s before and after', '30 min before and after']);
});

test('the time of day is the box’s, with tenths of a second while paused', () => {
  const at = chicago(3, 12, 8) + 437;
  assert.equal(clockText(at, CHICAGO), '3:12:08 AM');
  assert.equal(clockText(at, CHICAGO, { tenths: true }), '3:12:08.4 AM');
  assert.equal(clockText(chicago(15, 0, 0), CHICAGO, { tenths: true }), '3:00:00.0 PM');
  assert.equal(clockText(Number.NaN, CHICAGO), '');
});

// MARK: The path at a time, the zoom

test('the overlay takes the path’s point for the time: between two points by how far the time is between them, the ends outside them', () => {
  const start = chicago(3, 12, 8);
  const path = [{ t: 0, x: 0.1, y: 0.2 }, { t: 2, x: 0.3, y: 0.4 }, { t: 4, x: 0.5, y: 0.2 }];
  const at = (ms) => pathPointAt(path, start, ms);
  assert.deepEqual(at(start - 5000), { x: 0.1, y: 0.2, at: 'before' }, 'before the light: where it will appear');
  assert.deepEqual(at(start), { x: 0.1, y: 0.2, at: 'during' });
  assert.deepEqual(at(start + 1000), { x: 0.2, y: 0.3, at: 'during' }, 'half way between the first two points');
  assert.deepEqual(at(start + 2000), { x: 0.3, y: 0.4, at: 'during' });
  assert.deepEqual(at(start + 3000), { x: 0.4, y: 0.3, at: 'during' });
  assert.deepEqual(at(start + 4000), { x: 0.5, y: 0.2, at: 'during' });
  assert.deepEqual(at(start + 9000), { x: 0.5, y: 0.2, at: 'after' }, 'after it: where it went');
  assert.deepEqual(pathPointAt([[4, 0.5, 0.2], [0, 0.1, 0.2], [2, 0.3, 0.4]], start, start + 1000), { x: 0.2, y: 0.3, at: 'during' }, 'triples, in any order');
  // One point (a flash, a new light): it is there for the entry's whole length.
  const flash = [[0, 0.6, 0.1]];
  assert.deepEqual(pathPointAt(flash, start, start + 300, start + 400), { x: 0.6, y: 0.1, at: 'during' });
  assert.deepEqual(pathPointAt(flash, start, start + 500, start + 400), { x: 0.6, y: 0.1, at: 'after' });
  assert.equal(pathPointAt([], start, start), null);
  assert.equal(pathPointAt(null, start, start), null);
});

test('the overlay’s view box is the part of the picture the zoom shows, in the picture’s own pixels', () => {
  assert.equal(overlayViewBox({ x: 0, y: 0, w: 1, h: 1 }, { width: 1920, height: 852 }), '0 0 1920 852', 'the whole picture');
  assert.equal(overlayViewBox(null, { width: 1920, height: 852 }), '0 0 1920 852');
  assert.equal(overlayViewBox({ x: 0.25, y: 0.5, w: 0.25, h: 0.25 }, { width: 1920, height: 852 }), '480 426 480 213');
  assert.equal(overlayViewBox({ x: 1 / 3, y: 0, w: 1 / 3, h: 1 / 3 }, { width: 4256, height: 1888 }), '1418.67 0 1418.67 629.33', 'to a hundredth of a pixel');
});

test('Zoom to the light goes where the light is at that moment, as close as its close-up', () => {
  const start = chicago(3, 12, 8);
  const picture = { width: 1920, height: 852 };
  // A single point: the smallest close-up is 160 px of 1920, more than six times: six.
  assert.deepEqual(zoomAt([[0, 0.5, 0.3]], start, start, picture), { scale: 6, x: 50, y: 30 });
  // A path in the middle: its close-up is 384 px wide, five times; the origin follows the light.
  const middle = [[0, 0.45, 0.4], [2, 0.5, 0.42], [4, 0.55, 0.45]];
  assert.deepEqual(zoomAt(middle, start, start + 1000, picture), { scale: 5, x: 47.5, y: 41 });
  assert.deepEqual(zoomAt(middle, start, start - 10_000, picture), { scale: 5, x: 45, y: 40 }, 'before the light: where it will appear');
  assert.deepEqual(zoomAt(middle, start, start + 60_000, picture), { scale: 5, x: 55, y: 45 }, 'after it: where it went');
  // A light that crossed the sky: twice, following it.
  assert.deepEqual(zoomAt([[0, 0.05, 0.1], [9, 0.95, 0.9]], start, start + 4500, picture), { scale: 2, x: 50, y: 50 });
  // The stitched 4256 × 1888 recording: the same close-up as its 1920-wide still.
  assert.deepEqual(zoomAt(middle, start, start + 1000, { width: 4256, height: 1888 }), { scale: 5, x: 47.5, y: 41 });
  assert.equal(zoomAt([], start, start, picture), null);
});

// MARK: The keys

test('the Monitor’s keys, bounded by the window: Space plays or pauses, ← → step a picture while paused and a second while playing', () => {
  const from = 100_000;
  const to = 134_000;
  const state = (mode, positionMs) => ({ mode, positionMs, from, to });
  const nudge = (direction) => ({ action: 'nudge', direction, deltaMs: direction * 1000 });
  assert.deepEqual(windowedAction({ action: 'togglePlay' }, state('playing', 110_000)), { kind: 'toggle' });
  assert.deepEqual(windowedAction(nudge(1), state('paused', 110_000)), { kind: 'step', direction: 1 });
  assert.deepEqual(windowedAction(nudge(-1), state('paused', 110_000)), { kind: 'step', direction: -1 });
  assert.equal(windowedAction(nudge(1), state('paused', to)), null, 'no picture after the window');
  assert.equal(windowedAction(nudge(-1), state('paused', from)), null, 'nor before it');
  assert.deepEqual(windowedAction(nudge(1), state('playing', 110_000)), { kind: 'seek', deltaMs: 1000 });
  assert.deepEqual(windowedAction(nudge(1), state('playing', to - 400)), { kind: 'seek', deltaMs: 400 }, 'up to the end of the window');
  assert.equal(windowedAction(nudge(1), state('playing', to)), null);
  assert.deepEqual(windowedAction({ action: 'seek', deltaMs: -60_000 }, state('paused', from + 10_000)), { kind: 'seek', deltaMs: -10_000 }, 'Shift + ←: back to the start of the window');
  assert.deepEqual(windowedAction({ action: 'seek', deltaMs: 10_000 }, state('playing', 110_000)), { kind: 'seek', deltaMs: 10_000 });
  assert.deepEqual(windowedAction({ action: 'speed', step: -1 }, state('playing', 110_000)), { kind: 'speed', step: -1 });
  assert.equal(windowedAction({ action: 'goLive' }, state('playing', 110_000)), null, 'live is not a place in a clip');
  assert.equal(windowedAction(null, state('playing', 110_000)), null);
});

test('the keyboard help is the Monitor’s, less what a clip has no use for, with the marker and the zoom, and says Esc closes', () => {
  const monitor = new Map(KEY_MAP);
  assert.deepEqual(SKY_KEY_MAP.map(([keys]) => keys), ['Space', '← →', 'Shift + ← →', 'Alt + ← →', ', .', 'M', '0', 'Esc']);
  for (const keys of ['Space', '← →', 'Shift + ← →', ', .']) assert.equal(new Map(SKY_KEY_MAP).get(keys), monitor.get(keys), `${keys} reads as on the Monitor`);
  assert.equal(new Map(SKY_KEY_MAP).get('Alt + ← →'), '10 seconds back or forward');
  assert.equal(new Map(SKY_KEY_MAP).get('M'), 'Hide or show the marker');
  assert.equal(new Map(SKY_KEY_MAP).get('0'), 'The whole picture again (double-click too)');
  assert.equal(new Map(SKY_KEY_MAP).get('Esc'), 'Zoomed in: the whole picture again. Otherwise: close');
});

// MARK: What it says instead of playing

test('with no recording to play it says why, plainly, and offers the still', () => {
  const from = 100_000;
  const to = 134_000;
  const ok = { playable: true, phase: 'ready', catalogPhase: 'ready', extent: { oldest: 0, newest: 500_000 }, from, to, coverage: { kind: 'recorded' }, presented: true, pause: null, hasStill: true };
  assert.equal(playerNotice(ok), null, 'it can play');
  assert.equal(playerNotice({ ...ok, phase: 'connecting', coverage: { kind: 'idle' }, presented: false }), null, 'still asking: the spinner says so');

  const missing = playerNotice({ ...ok, extent: { oldest: 200_000, newest: 500_000 }, presented: false, coverage: { kind: 'idle' } });
  assert.deepEqual(missing, { kind: 'missing', title: 'There’s no recording of this moment', body: 'It may have been removed to make room for newer recordings. Here’s the still picture Sky Watcher kept.', retry: false });
  assert.equal(playerNotice({ ...ok, extent: { oldest: 0, newest: 90_000 }, presented: false })?.kind, 'missing', 'the recording ended before the window');
  assert.equal(playerNotice({ ...ok, extent: null, presented: false })?.kind, 'missing', 'nothing recorded at all');
  assert.equal(playerNotice({ ...ok, extent: null, presented: false, hasStill: false }).body, 'It may have been removed to make room for newer recordings.', 'no still to offer');
  // A gap as long as the rest of the window, before anything was shown.
  assert.equal(playerNotice({ ...ok, coverage: { kind: 'gap', next: null }, presented: false })?.kind, 'missing');
  assert.equal(playerNotice({ ...ok, coverage: { kind: 'gap', next: to + 1 }, presented: false })?.kind, 'missing');
  assert.equal(playerNotice({ ...ok, coverage: { kind: 'gap', next: to - 5000 }, presented: false }), null, 'a recording later in the window plays');
  assert.equal(playerNotice({ ...ok, coverage: { kind: 'gap', next: null }, presented: true }), null, 'a gap after part of the window was shown is the picture’s own note');

  assert.deepEqual(playerNotice({ ...ok, pause: 'folderMissing', presented: false }),
    { kind: 'drive', title: 'The recordings drive isn’t connected', body: 'Connect it again to play this moment. Here’s the still picture Sky Watcher kept.', retry: false });
  assert.equal(playerNotice({ ...ok, coverage: { kind: 'driveMissing' } })?.kind, 'drive');
  assert.deepEqual(playerNotice({ ...ok, phase: 'unreachable' }),
    { kind: 'unreachable', title: 'The recordings can’t be reached right now', body: 'Try again in a moment. Here’s the still picture Sky Watcher kept.', retry: true });
  assert.equal(playerNotice({ ...ok, catalogPhase: 'unavailable' })?.kind, 'unreachable');
  assert.deepEqual(playerNotice({ ...ok, catalogPhase: 'loading', presented: false }),
    { kind: 'loading', title: 'The recordings are loading', body: 'This takes a moment after the box starts. Here’s the still picture Sky Watcher kept.', retry: false });
  assert.deepEqual(playerNotice({ ...ok, playable: false }),
    { kind: 'unplayable', title: 'This browser can’t play recordings', body: 'Safari, or Chrome on a Mac, can play them. Here’s the still picture Sky Watcher kept.', retry: false });
  assert.equal(playerNotice({ ...ok, coverage: { kind: 'unsupported', message: 'This browser can’t play H.265 recordings. Safari, or Chrome on a Mac, can.' }, hasStill: false }).body,
    'This browser can’t play H.265 recordings. Safari, or Chrome on a Mac, can.', 'the browser’s own reason');
});

test('the player’s words are plain, with no straight apostrophe, and never claim a size or a distance', () => {
  const words = Object.values(T).filter((value) => typeof value === 'string');
  assert.ok(words.length >= 20);
  for (const text of words) {
    assert.doesNotMatch(text, /'/, text);
    assert.doesNotMatch(text, /\b(?:ft|feet|metres|meters|miles|km)\b/i, text);
  }
  assert.equal(T.watch, 'Watch on the Monitor');
  assert.equal(T.zoom, 'Zoom to the light');
  assert.deepEqual([T.hideMarker, T.showMarker], ['Hide marker', 'Show marker']);
  assert.deepEqual([T.widenOne, T.widenFive], ['±1 min', '±5 min']);
});

// MARK: The modal, against the real session over the fake archive

const CAM = '0A1B2C3D-0000-4000-8000-0000000000AA';
const FILES = () => [
  { key: FILE_A, startMs: ORIGIN, parts: 60, gop: 4 },                  // 120 s, a key every 8 s
  { key: FILE_B, startMs: ORIGIN + 300_000, parts: 20, gop: 1 },        // after a gap of three minutes
];
/** A light at ORIGIN + 50 s, 4 s long: its window is ORIGIN + 35 s to ORIGIN + 69 s, inside file A. */
const lightAt = (startMs, extra = {}) => normalizeEntry({
  id: 'u1', kind: 'track', start: startMs, end: startMs + 4000, label: 'unexplained', hasStill: true,
  path: [{ t: 0, x: 0.2, y: 0.3 }, { t: 2, x: 0.4, y: 0.35 }, { t: 4, x: 0.6, y: 0.3 }], measures: { azimuth: 312, elevation: 8, duration: 4 }, ...extra,
});
const camera = (extra = {}) => ({ id: CAM, name: 'North Sky', nvrEnabled: true, status: { connection: 'online', nvr: { state: 'recording', pause: null }, mainStreamInfo: { width: 1920, height: 852 } }, ...extra });

/** Every element under `root` (depth first) that `match` accepts. */
function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const byClass = (root, name) => all(root, (node) => node.classList?.contains(name))[0];
const visible = (node) => { for (let n = node; n; n = n.parentNode) if (n.hidden) return false; return true; };
const button = (root, text) => all(root, (node) => node.localName === 'button' && node.textContent.trim() === text)[0];
const shown = (root) => {
  const parts = [];
  const walk = (node) => { if (node.hidden) return; if (node.data !== undefined) parts.push(node.data); for (const child of node.childNodes ?? []) walk(child); };
  walk(root);
  return parts.join(' ').replace(/\s+/g, ' ');
};

let browser;
let openSkyPlayer;
before(async () => {
  browser = installFakeBrowser();
  recordingCanvases(browser.document);                                   // the zoom's canvases draw in 2D (no WebGL here) and keep what they drew
  globalThis.ResizeObserver = class { observe() {} disconnect() {} };    // the zoom's
  ({ openSkyPlayer } = await import('../web/js/screens/sky-player.js'));
});
after(() => { delete globalThis.ResizeObserver; browser?.restore(); });

/** The picture's box on screen: 960 × 426 at the page's top left, the shape of the recording's 1920 × 852 picture. */
const FRAME = { width: 960, height: 426 };

/**
 * The player over the rig: the real fetcher, catalog, clock, cells and session over the fake archive, the grid controller, and every timer
 * (the cells', the session's, the controller's and the player's frames) on the rig's fake clock. Its picture is laid out as a browser would:
 * the frame (the zoom's host) FRAME, the video 1920 × 852 (the recording's picture, once one shows). `open` is the sky player module's
 * openSkyPlayer (another copy of the module is another visit to the page).
 */
async function openOver({ files = FILES(), entry = lightAt(ORIGIN + 50_000), at = camera(), still = '/api/v1/sky/cameras/x/entries/u1/still?night=2026-10-24', playable = true, details = null, open = openSkyPlayer } = {}) {
  const rig = createRig({ cameras: [{ id: CAM, files }] });
  await rig.start();
  const closed = [];
  const player = open({
    camera: at, entry, zone: CHICAGO, heading: '3:12:08 AM', what: 'Moving light · North Sky', still, watchHref: `#/camera/${CAM}/watch/${entry.watch}`, details,
    onClose: () => closed.push('closed'),
    parts: {
      fetcher: rig.fetcher, catalog: rig.catalog, clock: rig.clock, makeCell: (id) => rig.makeCell(id), policy: DEFAULT_POLICY, timers: rig.timers, playable,
      frame: (fn) => rig.timers.setTimeout(() => fn(rig.timers.now()), 16), cancelFrame: (id) => rig.timers.clearTimeout(id),
      subscribeCamera: () => () => {},
    },
  });
  const dialog = player.el;
  const track = byClass(dialog, 'sky-scrub-track');
  track.getBoundingClientRect = () => ({ left: 0, top: 0, right: 340, bottom: 40, width: 340, height: 40, x: 0, y: 0 });
  const frame = byClass(dialog, 'sky-player-frame');
  Object.assign(frame, { clientWidth: FRAME.width, clientHeight: FRAME.height });
  frame.getBoundingClientRect = () => ({ left: 0, top: 0, right: FRAME.width, bottom: FRAME.height, width: FRAME.width, height: FRAME.height, x: 0, y: 0 });
  givePicture(all(dialog, (node) => node.localName === 'video')[0], { width: 1920, height: 852 });
  await rig.timers.advance(500);
  return { rig, player, dialog, track, closed, surface: () => rig.surface(CAM) };
}
const playButton = (dialog) => all(dialog, (node) => node.localName === 'button' && node.dataset?.playing !== undefined)[0];
const readout = (dialog) => byClass(dialog, 'nvr-readout');
const position = (track) => Number(track.getAttribute('aria-valuenow'));
/** A key pressed on the page; -> the event, which keeps whether the player took it. */
const key = (init) => {
  const event = { type: 'keydown', target: document.body, taken: false, preventDefault() { this.taken = true; }, stopImmediatePropagation() {}, ...init };
  document.dispatchEvent(event);
  return event;
};
const pointer = (track, type, clientX) => track.dispatchEvent({ type, pointerId: 1, pointerType: 'mouse', button: 0, clientX, target: track, preventDefault() {} });
/** An event on the zoom's surface (the picture) at the frame's point (x, y), as a mouse gives it; -> the event. */
function onPicture(dialog, type, x, y, extra = {}) {
  const surface = byClass(dialog, 'zoom-surface');
  const event = { type, pointerId: 1, pointerType: 'mouse', button: 0, clientX: x, clientY: y, target: surface, defaultPrevented: false,
    preventDefault() { this.defaultPrevented = true; }, stopPropagation() {}, ...extra };
  surface.dispatchEvent(event);
  return event;
}
/** A mouse drag over the picture from `from` to `to` (frame points). */
function dragPicture(dialog, from, to, extra = {}) {
  onPicture(dialog, 'pointerdown', ...from, extra);
  onPicture(dialog, 'pointermove', ...to, extra);
  onPicture(dialog, 'pointerup', ...to, extra);
}
const zoomOf = (dialog) => byClass(dialog, 'sky-player-stage').dataset.zoom;
/** `got` is `want` to within `within` (the overlay's view box is kept to a hundredth of a pixel). */
const near = (got, want, what = '', within = 0.006) => assert.ok(Math.abs(got - want) <= within, `${what} ${got} ≈ ${want}`);
/** The overlay's view box as numbers: [x, y, width, height] in the picture's pixels. */
const viewBoxOf = (dialog) => byClass(dialog, 'sky-player-path').getAttribute('viewBox').split(' ').map(Number);

describe('the modal', () => {
  it('opens on the page as a dialog and plays the window from 15 s before the light', async () => {
    const { rig, player, dialog, track, surface } = await openOver();
    try {
      assert.equal(dialog.localName, 'dialog');
      assert.equal(dialog.open, true, 'shown as a modal');
      assert.ok(document.body.childNodes.includes(dialog), 'on the sky log’s own page');
      assert.deepEqual(player.window, { from: ORIGIN + 35_000, to: ORIGIN + 69_000 });
      assert.equal(track.getAttribute('aria-valuemin'), String(ORIGIN + 35_000));
      assert.equal(track.getAttribute('aria-valuemax'), String(ORIGIN + 69_000));
      await rig.timers.advance(2000);
      assert.equal(surface().playing, true, 'it plays');
      assert.equal(playButton(dialog).dataset.playing, 'true');
      assert.ok(position(track) >= ORIGIN + 35_000 && position(track) < ORIGIN + 40_000, `from the start of the window: ${position(track) - ORIGIN}`);
      // The light's own span is marked on the scrubber: 15 s of 34 in, 4 s of 34 long.
      const span = byClass(dialog, 'sky-scrub-span');
      assert.equal(span.style.left, `${((15 / 34) * 100).toFixed(3)}%`);
      assert.equal(span.style.width, `${((4 / 34) * 100).toFixed(3)}%`);
      assert.match(shown(dialog), /15 s before and after/);
    } finally {
      player.close();
    }
  });

  it('widens by a minute or five on both sides, and goes back', async () => {
    const { player, dialog, track } = await openOver();
    try {
      button(dialog, '±1 min').click();
      assert.deepEqual(player.window, { from: ORIGIN + 50_000 - 75_000, to: ORIGIN + 54_000 + 75_000 });
      assert.equal(track.getAttribute('aria-valuemin'), String(ORIGIN + 50_000 - 75_000));
      assert.match(shown(dialog), /1 min 15 s before and after/);
      button(dialog, '±5 min').click();
      assert.deepEqual(player.window, { from: ORIGIN + 50_000 - 375_000, to: ORIGIN + 54_000 + 375_000 });
      const back = button(dialog, T.narrow);
      assert.ok(back && visible(back), 'a way back to the light alone');
      back.click();
      assert.deepEqual(player.window, { from: ORIGIN + 35_000, to: ORIGIN + 69_000 });
      assert.equal(visible(button(dialog, T.narrow)), false);
    } finally {
      player.close();
    }
  });

  it('keeps paused while scrubbing and stepping: only Play plays', async () => {
    const { rig, player, dialog, track, surface } = await openOver();
    try {
      await rig.timers.advance(2000);
      playButton(dialog).click();                          // Pause
      await rig.timers.advance(500);
      assert.equal(surface().playing, false);
      assert.equal(readout(dialog).dataset.held, 'true');

      // A drag on the scrubber and its release: the picture there, paused.
      pointer(track, 'pointerdown', 170);
      await rig.timers.advance(40);
      pointer(track, 'pointermove', 255);
      await rig.timers.advance(40);
      pointer(track, 'pointerup', 255);
      await rig.timers.advance(1500);
      const dropped = ORIGIN + 35_000 + (255 / 340) * 34_000;
      assert.ok(Math.abs(position(track) - dropped) < 2, `at the release: ${position(track) - ORIGIN}`);
      assert.equal(surface().playing, false, 'still paused');
      assert.equal(playButton(dialog).dataset.playing, 'false');

      // A picture at a time, with the keys and with the buttons.
      const before = position(track);
      key({ key: 'ArrowRight' });
      await rig.timers.advance(500);
      assert.ok(position(track) > before, 'one picture on');
      assert.ok(position(track) - before < 200, 'a picture, not a second');
      byClass(dialog, 'nvr-frame').click();               // One picture back
      await rig.timers.advance(500);
      assert.equal(surface().playing, false);
      key({ key: 'ArrowLeft', shiftKey: true });           // a minute back, held by the window's start
      await rig.timers.advance(1000);
      assert.equal(position(track), ORIGIN + 35_000);
      key({ key: 'ArrowLeft' });                           // nothing before the window
      await rig.timers.advance(500);
      assert.equal(position(track), ORIGIN + 35_000);
      // Widening keeps it paused, and so does a new speed.
      button(dialog, '±1 min').click();
      key({ key: ',' });
      await rig.timers.advance(1000);
      assert.equal(surface().playing, false, 'paused through all of it');

      // Space (from the page, not a button) plays, at the speed chosen meanwhile.
      key({ key: ' ' });
      await rig.timers.advance(2500);
      assert.equal(surface().playing, true);
      assert.equal(playButton(dialog).dataset.playing, 'true');
    } finally {
      player.close();
    }
  });

  it('pauses at the end of the window, and Play there starts it again', async () => {
    const { rig, player, dialog, track, surface } = await openOver();
    try {
      await rig.timers.advance(40_000);
      assert.equal(surface().playing, false, 'it stopped at the end');
      assert.equal(position(track), ORIGIN + 69_000);
      assert.equal(readout(dialog).dataset.held, 'true');
      playButton(dialog).click();
      await rig.timers.advance(2500);
      assert.equal(surface().playing, true);
      assert.ok(position(track) < ORIGIN + 40_000, 'from the start of the window again');
    } finally {
      player.close();
    }
  });

  it('draws the light’s path over the video and the light where it is at that moment; Zoom to the light zooms the Monitor’s zoom there', async () => {
    const entry = lightAt(ORIGIN + 50_000);
    const { rig, player, dialog, track } = await openOver({ entry });
    try {
      playButton(dialog).click();
      key({ key: 'ArrowLeft', shiftKey: true });
      await rig.timers.advance(500);
      // Paused at the window's start, then dragged to the light's first second.
      const x = ((ORIGIN + 51_000 - (ORIGIN + 35_000)) / 34_000) * 340;
      pointer(track, 'pointerdown', x);
      pointer(track, 'pointerup', x);
      await rig.timers.advance(1000);
      const overlay = byClass(dialog, 'sky-player-path');
      assert.deepEqual(viewBoxOf(dialog), [0, 0, 1920, 852], 'in the picture’s own coordinates, all of it');
      const now = byClass(overlay, 'sky-player-now');
      const point = pathPointAt(entry.path, entry.start, position(track), entry.end);
      assert.equal(Number(now.getAttribute('cx')).toFixed(1), (point.x * 1920).toFixed(1));
      assert.equal(Number(now.getAttribute('cy')).toFixed(1), (point.y * 852).toFixed(1));
      assert.equal(now.dataset.at, 'during');
      assert.ok(byClass(overlay, 'sky-path-line'), 'and the whole path, faint');
      assert.equal(Number(now.getAttribute('r')), 30.72, 'the ring: 1.6 % of the picture');

      // Zoom to the light: the zoom's own view, centred on the light, as close as its close-up shows it.
      const zoomButton = button(dialog, T.zoom);
      assert.ok(byClass(dialog, 'sky-player-transport').contains(zoomButton), 'in the control bar');
      assert.equal(zoomButton.getAttribute('aria-pressed'), null, 'a press, not a switch');
      zoomButton.click();
      assert.equal(zoomOf(dialog), 'true');
      const expected = zoomAt(entry.path, entry.start, position(track), { width: 1920, height: 852 });
      const [vx, vy, vw, vh] = viewBoxOf(dialog);
      near(vw, 1920 / expected.scale, 'as close as the close-up:');
      near(vh, 852 / expected.scale, 'in the picture’s shape:');
      near((vx + vw / 2) / 1920, point.x, 'centred on the light across', 1e-3);
      near((vy + vh / 2) / 852, point.y, 'and down', 1e-3);
      near(Number(now.getAttribute('r')), Math.round((30.72 / expected.scale) * 100) / 100, 'the ring keeps its size on screen');
      assert.equal(byClass(dialog, 'zoom-level').textContent, `${expected.scale.toFixed(1)}×`, 'the zoom’s level, as on the Monitor');
      assert.equal(visible(byClass(dialog, 'zoom-controls')), true, 'and its Reset');

      // From there the person moves it: a drag of a quarter of the picture's box to the left moves the view a quarter of itself to the right.
      dragPicture(dialog, [480, 213], [240, 213]);
      near(viewBoxOf(dialog)[0], vx + vw / 4, 'moved');
      assert.equal(viewBoxOf(dialog)[2], vw, 'not zoomed');
    } finally {
      player.close();
    }
  });

  it('hides and shows the light’s marker with its button and with M, and remembers the choice for the next light', async () => {
    const one = await openOver();
    let two = null;
    try {
      const stage = byClass(one.dialog, 'sky-player-stage');
      const overlay = byClass(one.dialog, 'sky-player-path');
      assert.equal(stage.dataset.marker, 'true', 'shown at first');
      assert.ok(byClass(overlay, 'sky-player-now') && byClass(overlay, 'sky-path-line'), 'the marker is the ring and the path');
      const hide = button(one.dialog, T.hideMarker);
      assert.ok(hide && byClass(one.dialog, 'sky-player-transport').contains(hide), 'Hide marker, in the control bar');
      assert.equal(all(hide, (node) => node.localName === 'svg').length, 1, 'with its sign, as the buttons beside it');
      assert.match(hide.title, /\(M\)$/, 'and its key');
      hide.click();
      assert.equal(stage.dataset.marker, 'false', 'hidden');
      assert.equal(button(one.dialog, T.hideMarker), undefined);
      assert.ok(button(one.dialog, T.showMarker), 'the button now says Show marker');
      assert.equal(localStorage.getItem('cb.sky.marker'), '0', 'kept in this browser');
      button(one.dialog, T.showMarker).click();
      assert.equal(stage.dataset.marker, 'true', 'and shows it again');
      assert.equal(localStorage.getItem('cb.sky.marker'), '1');

      const m = key({ key: 'm' });
      assert.equal(stage.dataset.marker, 'false', 'M hides it');
      assert.equal(m.taken, true, 'the player’s key');
      key({ key: 'M', shiftKey: true });
      assert.equal(stage.dataset.marker, 'true', 'and shows it');
      key({ key: 'm', repeat: true });
      assert.equal(stage.dataset.marker, 'true', 'a held key does not make it flicker');
      key({ key: 'm', metaKey: true });
      key({ key: 'm', ctrlKey: true });
      assert.equal(stage.dataset.marker, 'true', 'not with cmd or ctrl');
      key({ key: 'm', target: Object.assign(document.createElement('input'), { closest: () => ({}) }) });
      assert.equal(stage.dataset.marker, 'true', 'not while typing');
      key({ key: 'm' });
      assert.equal(stage.dataset.marker, 'false');
      one.player.close();

      two = await openOver();
      assert.equal(byClass(two.dialog, 'sky-player-stage').dataset.marker, 'false', 'the next light opens with it hidden');
      assert.ok(button(two.dialog, T.showMarker));
      const css = readFileSync(new URL('../web/sky.css', import.meta.url), 'utf8');
      assert.match(css, /\.sky-player-stage\[data-marker="false"\] \.sky-player-path \{ visibility: hidden; \}/, 'hidden is not drawn');
    } finally {
      one.player.close();
      if (two) { button(two.dialog, T.showMarker)?.click(); two.player.close(); }
    }
  });

  it('remembers the marker in this browser for the next visit, and for the visit where the browser keeps nothing', async () => {
    const kept = globalThis.localStorage;
    kept.setItem('cb.sky.marker', '0');
    const { openSkyPlayer: nextVisit } = await import('../web/js/screens/sky-player.js?visit=next');
    const one = await openOver({ open: nextVisit });
    try {
      assert.equal(byClass(one.dialog, 'sky-player-stage').dataset.marker, 'false', 'hidden, as it was left last time');
    } finally {
      one.player.close();
    }
    // A browser that keeps nothing (a private window, blocked site data): shown at first, and the choice holds for the visit.
    globalThis.localStorage = makeStorage({ broken: true });
    try {
      const { openSkyPlayer: privateVisit } = await import('../web/js/screens/sky-player.js?visit=private');
      const two = await openOver({ open: privateVisit });
      try {
        assert.equal(byClass(two.dialog, 'sky-player-stage').dataset.marker, 'true', 'nothing was kept');
        button(two.dialog, T.hideMarker).click();
        assert.equal(byClass(two.dialog, 'sky-player-stage').dataset.marker, 'false', 'and hiding it works all the same');
      } finally {
        two.player.close();
      }
      const three = await openOver({ open: privateVisit });
      try {
        assert.equal(byClass(three.dialog, 'sky-player-stage').dataset.marker, 'false', 'still hidden for the next light of this visit');
      } finally {
        three.player.close();
      }
    } finally {
      globalThis.localStorage = kept;
      kept.setItem('cb.sky.marker', '1');
    }
  });

  it('zooms like the Monitor, on the picture alone: a box, the wheel around the pointer, a drag that moves it inside the picture; the marker follows', async () => {
    const { rig, player, dialog } = await openOver();
    try {
      await rig.timers.advance(2000);
      assert.equal(byClass(dialog, 'sky-player-stage').dataset.layer, 'video', 'the recording shows');
      const layer = byClass(dialog, 'zoom-layer');
      assert.ok(byClass(dialog, 'sky-player-frame').contains(layer), 'the zoom covers the picture’s box, not the page or the dialog');
      assert.equal(layer.childNodes[1], byClass(dialog, 'sky-player-path'), 'the marker over the zoomed picture, under the zoom’s controls');
      const now = byClass(dialog, 'sky-player-now');
      const ring = Number(now.getAttribute('r'));

      // A box a quarter of the picture across and down, a quarter in from its top left: that quarter fills the box.
      dragPicture(dialog, [240, 106.5], [480, 213]);
      assert.equal(zoomOf(dialog), 'true');
      assert.deepEqual(viewBoxOf(dialog), [480, 213, 480, 213], 'the marker is drawn on the zoomed quarter, in the picture’s pixels');
      assert.equal(Number(now.getAttribute('r')), ring / 4, 'four times in, the ring a quarter of its size in the picture: the same on screen');
      assert.equal(byClass(dialog, 'zoom-level').textContent, '4.0×', 'the zoom’s level and Reset, as on the Monitor');
      assert.equal(visible(byClass(dialog, 'zoom-controls')), true);

      // The wheel: in around the pointer, the point of the picture under it staying where it is.
      const [x0, y0, w0, h0] = viewBoxOf(dialog);
      const before = { x: x0 + (720 / 960) * w0, y: y0 + (106.5 / 426) * h0 };
      const wheel = onPicture(dialog, 'wheel', 720, 106.5, { deltaY: -100, deltaMode: 0 });
      assert.equal(wheel.defaultPrevented, true, 'the page does not scroll');
      const [x1, y1, w1, h1] = viewBoxOf(dialog);
      assert.ok(w1 < w0, `in further (${w1} of ${w0})`);
      near(x1 + (720 / 960) * w1, before.x, 'the point under the pointer stays across', 0.02);
      near(y1 + (106.5 / 426) * h1, before.y, 'and down', 0.02);

      // A drag moves it, never past the picture's edges.
      dragPicture(dialog, [480, 213], [5480, 5213]);
      assert.deepEqual(viewBoxOf(dialog).slice(0, 2), [0, 0], 'the picture’s top left corner, no further');
      dragPicture(dialog, [480, 213], [-4520, -4787]);
      const [x3, y3, w3, h3] = viewBoxOf(dialog);
      near(x3 + w3, 1920, 'its right edge, no further', 0.011);
      near(y3 + h3, 852, 'its foot', 0.011);
      assert.equal(w3, w1, 'moving never zooms');
    } finally {
      player.close();
    }
  });

  it('double-click and 0 show the whole picture again, the marker with it', async () => {
    const { rig, player, dialog } = await openOver();
    try {
      await rig.timers.advance(2000);
      const ring = Number(byClass(dialog, 'sky-player-now').getAttribute('r'));
      button(dialog, T.zoom).click();
      assert.equal(zoomOf(dialog), 'true');
      onPicture(dialog, 'dblclick', 100, 100);
      assert.equal(zoomOf(dialog), 'false', 'a double-click');
      assert.deepEqual(viewBoxOf(dialog), [0, 0, 1920, 852], 'the marker on the whole picture again');
      assert.equal(Number(byClass(dialog, 'sky-player-now').getAttribute('r')), ring);
      button(dialog, T.zoom).click();
      const zero = key({ key: '0' });
      assert.equal(zoomOf(dialog), 'false', '0');
      assert.equal(zero.taken, true, 'the player’s key');
      assert.deepEqual(viewBoxOf(dialog), [0, 0, 1920, 852]);
      assert.equal(key({ key: '0' }).taken, false, 'whole, 0 does nothing');
    } finally {
      player.close();
    }
  });

  it('Escape gives the whole picture back first, as on the Monitor, and closes the player the second time', async () => {
    const { rig, player, dialog, closed, surface } = await openOver();
    try {
      await rig.timers.advance(2000);
      button(dialog, T.zoom).click();
      assert.equal(zoomOf(dialog), 'true');
      const first = key({ key: 'Escape' });
      assert.equal(first.taken, true, 'the browser does not close the dialog itself');
      assert.equal(zoomOf(dialog), 'false', 'the whole picture');
      assert.equal(dialog.open, true, 'still open');
      assert.deepEqual(closed, []);
      assert.equal(surface().playing, true, 'and still playing');
      key({ key: 'Escape' });
      assert.equal(dialog.open, false, 'closed');
      assert.deepEqual(closed, ['closed']);
    } finally {
      player.close();
    }
  });

  it('zooms the still when there is no recording to play, and the marker follows it there too', async () => {
    const { rig, player, dialog } = await openOver({ entry: lightAt(ORIGIN + 1_400_000) });
    try {
      await rig.timers.advance(1000);
      assert.equal(byClass(dialog, 'sky-player-stage').dataset.layer, 'still');
      const still = all(dialog, (node) => node.localName === 'img' && node.classList.contains('sky-player-still'))[0];
      dragPicture(dialog, [240, 106.5], [480, 213]);
      assert.equal(zoomOf(dialog), 'false', 'nothing to zoom before the still has come');
      Object.assign(still, { naturalWidth: 1920, naturalHeight: 852 });
      dragPicture(dialog, [240, 106.5], [480, 213]);
      assert.equal(zoomOf(dialog), 'true');
      assert.deepEqual(viewBoxOf(dialog), [480, 213, 480, 213]);
      assert.ok(all(dialog, (node) => node.className === 'zoom-canvas')[0].getContext('2d').draws.some(([picture]) => picture === still), 'the still, zoomed');
    } finally {
      player.close();
    }
  });

  it('closes with Escape: the dialog goes, playing stops and the stream is freed', async () => {
    const { rig, player, dialog, surface, closed } = await openOver();
    await rig.timers.advance(2000);
    assert.equal(surface().playing, true);
    const video = all(dialog, (node) => node.localName === 'video')[0];
    key({ key: 'Escape' });
    assert.equal(dialog.open, false);
    assert.equal(document.body.childNodes.includes(dialog), false, 'gone from the page');
    assert.equal(surface().destroyed, true, 'the cell’s player is taken down');
    assert.equal(video.getAttribute('src'), null, 'the video holds nothing');
    assert.deepEqual(closed, ['closed']);
    await assert.rejects(rig.fetcher.json('nvr/cameras'), (error) => error.name === 'AbortError', 'nothing more is asked of the bridge');
    const requests = rig.requests().length;
    await rig.timers.advance(5000);
    assert.equal(rig.requests().length, requests, 'and nothing is still on its way');
    player.close();                                        // a second close does nothing
    assert.deepEqual(closed, ['closed']);
  });

  it('closes with its X and with a tap outside it', async () => {
    const one = await openOver();
    all(one.dialog, (node) => node.localName === 'button' && node.getAttribute('aria-label') === T.close)[0].click();
    assert.equal(one.dialog.open, false);
    assert.equal(one.surface().destroyed, true);
    const two = await openOver();
    two.dialog.dispatchEvent({ type: 'pointerdown', target: two.dialog });
    two.dialog.dispatchEvent({ type: 'click', target: two.dialog });
    assert.equal(two.dialog.open, false, 'a tap on the dimmed page around it');
    const three = await openOver();
    const stage = byClass(three.dialog, 'sky-player-stage');
    stage.dispatchEvent({ type: 'pointerdown', target: stage });
    three.dialog.dispatchEvent({ type: 'click', target: three.dialog });
    assert.equal(three.dialog.open, true, 'a drag that began inside and ended outside is not a tap outside');
    three.player.close();
  });

  it('has the Monitor’s transport, and Watch on the Monitor as a second way', async () => {
    const { player, dialog } = await openOver();
    try {
      const transport = byClass(dialog, 'nvr-transport');
      const names = transport.childNodes.filter((node) => node.tagName).map((node) => node.dataset?.nvr ?? node.className);
      const play = names.indexOf('btn primary');
      assert.ok(play > 0, names.join(', '));
      assert.equal(names[play - 1], 'frame-back');
      assert.equal(names[play + 1], 'frame-forward');
      const select = all(transport, (node) => node.dataset?.nvr === 'speed')[0];
      assert.deepEqual(select.childNodes.filter((node) => node.localName === 'optgroup').map((group) => group.getAttribute('label')), ['Slow', 'Normal', 'Fast', 'Time-lapse']);
      assert.deepEqual(all(select, (node) => node.localName === 'option').slice(0, 3).map((option) => option.textContent), ['¼×', '½×', '1×'], 'slow motion first');
      assert.deepEqual(all(dialog, (node) => node.localName === 'kbd').map((node) => node.textContent), SKY_KEY_MAP.map(([keys]) => keys));
      const watch = all(dialog, (node) => node.localName === 'a' && node.textContent.trim() === T.watch)[0];
      assert.equal(watch.getAttribute('href'), `#/camera/${CAM}/watch/${ORIGIN + 50_000 - 3000}`);
      assert.match(shown(byClass(dialog, 'sky-player-head')), /3:12:08 AM.*Moving light · North Sky/);
    } finally {
      player.close();
    }
  });

  it('holds the light’s details from the log beside the picture and its controls (under them on a narrow window)', async () => {
    const details = document.createElement('div');
    details.className = 'sky-details';
    let tapped = 0;
    const bird = document.createElement('button');
    bird.textContent = 'Bird';
    bird.addEventListener('click', () => { tapped += 1; });
    details.append(bird);
    const { player, dialog } = await openOver({ details });
    try {
      const side = byClass(dialog, 'sky-player-side');
      assert.ok(side && side.contains(details), 'the details are in the player');
      assert.equal(side.localName, 'aside');
      assert.equal(side.getAttribute('aria-label'), 'About this light');
      assert.equal(byClass(dialog, 'sky-player-panel').dataset.side, 'true');
      const body = byClass(dialog, 'sky-player-body');
      assert.deepEqual(body.childNodes.map((node) => node.className), ['sky-player-main', 'sky-player-side'], 'after the picture and its controls');
      const main = byClass(dialog, 'sky-player-main');
      assert.ok(main.contains(byClass(dialog, 'sky-player-stage')) && main.contains(byClass(dialog, 'sky-player-controls')));
      bird.click();
      assert.equal(tapped, 1, 'its buttons work from here');
      assert.ok(all(dialog, (node) => node.localName === 'a' && node.textContent.trim() === T.watch)[0], 'with Watch on the Monitor');
    } finally {
      player.close();
    }
    const bare = await openOver();
    try {
      assert.equal(byClass(bare.dialog, 'sky-player-side'), undefined, 'none given: none shown');
      assert.equal(byClass(bare.dialog, 'sky-player-panel').dataset.side, 'false');
    } finally {
      bare.player.close();
    }
    const css = readFileSync(new URL('../web/sky.css', import.meta.url), 'utf8');
    assert.match(css, /@media \(min-width: 1000px\) \{[^@]*\.sky-player-body\[data-side="true"\] \{ flex-direction: row;/, 'beside them on a wide window');
  });

  it('looks like the Monitor: its dark colours, and the Monitor’s button and transport rules', () => {
    const css = readFileSync(new URL('../web/monitor.css', import.meta.url), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '');
    const tokens = (block) => Object.fromEntries([...block.matchAll(/(--[\w-]+):\s*([^;]+);/g)].map(([, name, value]) => [name, value.trim()]));
    const wall = tokens(/\.monitor \{([^}]*)\}/.exec(css)[1]);
    const player = tokens(/\n\.sky-player \{([^}]*)\}/.exec(css)[1]);
    assert.ok(Object.keys(player).length >= 18);
    for (const [name, value] of Object.entries(player)) assert.equal(value, wall[name], `${name} is the wall’s`);
    for (const selector of ['.btn {', '.btn.primary {', 'select {', '.nvr-transport {', '.nvr-readout {', '.nvr-frame {', '.nvr-readout[data-held="true"] {']) {
      assert.ok(css.includes(`:is(.monitor, .sky-player) ${selector}`), `the Monitor’s ${selector.slice(0, -2)} is the player’s`);
    }
  });

  it('shares the Monitor’s transport and playback code instead of a second player', () => {
    const source = readFileSync(new URL('../web/js/screens/sky-player.js', import.meta.url), 'utf8');
    const monitor = readFileSync(new URL('../web/js/screens/nvr.js', import.meta.url), 'utf8');
    for (const text of [source, monitor]) assert.match(text, /import \{[^}]*createTransport[^}]*\} from '\.\.\/nvr\/transport\.js'/);
    assert.match(source, /import \{[^}]*createGridController[^}]*\} from '\.\/nvr-controller\.js'/, 'the Monitor’s controller, for one camera');
    assert.match(source, /import \{[^}]*createSession[^}]*\} from '\.\.\/nvr\/session\.js'/);
    assert.match(source, /import \{[^}]*createScrubController[^}]*\} from '\.\.\/nvr\/timeline\/scrub\.js'/);
    assert.match(source, /import \{[^}]*keyAction[^}]*\} from '\.\/nvr-model\.js'/, 'and its keys');
    assert.doesNotMatch(source, /new MediaSource|addSourceBuffer/, 'no media code of its own');
  });

  it('says plainly when the recording is gone and shows the still instead', async () => {
    // Recordings from ORIGIN to ORIGIN + 340 s; the light more than 20 minutes later.
    const entry = lightAt(ORIGIN + 1_400_000);
    const { rig, player, dialog, track, surface } = await openOver({ entry });
    try {
      await rig.timers.advance(1000);
      const note = byClass(dialog, 'sky-player-notice');
      assert.ok(visible(note), 'said above the picture');
      assert.equal(visible(byClass(dialog, 'sky-player-note')), false, 'and nothing over the still');
      assert.match(shown(note), /There’s no recording of this moment/);
      assert.match(shown(note), /It may have been removed to make room for newer recordings\. Here’s the still picture Sky Watcher kept\./);
      const still = all(dialog, (node) => node.localName === 'img' && node.classList.contains('sky-player-still'))[0];
      assert.ok(still && visible(still), 'the still');
      assert.equal(byClass(dialog, 'sky-player-stage').dataset.layer, 'still');
      assert.equal(playButton(dialog).disabled, true, 'nothing to play');
      assert.equal(position(track), entry.start - 15_000, 'the playhead stands at the window’s start');
      assert.equal(track.getAttribute('aria-disabled'), 'true');
      assert.equal(surface(), undefined, 'and nothing was asked for it');
    } finally {
      player.close();
    }
  });

  it('a window inside a gap says so, and widening it to a recording plays', async () => {
    // File A ends at ORIGIN + 120 s, file B starts at ORIGIN + 300 s; the light at ORIGIN + 200 s.
    const { rig, player, dialog, surface } = await openOver({ entry: lightAt(ORIGIN + 200_000) });
    try {
      await rig.timers.advance(2000);
      assert.match(shown(byClass(dialog, 'sky-player-notice')), /There’s no recording of this moment/);
      button(dialog, '±5 min').click();
      await rig.timers.advance(3000);
      assert.equal(visible(byClass(dialog, 'sky-player-notice')), false, 'the window holds recordings now');
      assert.equal(surface().playing, true);
    } finally {
      player.close();
    }
  });

  it('says so when the recordings drive is away, or the browser cannot play', async () => {
    const away = await openOver({ at: camera({ status: { connection: 'online', nvr: { state: 'paused', pause: 'folderMissing' } } }) });
    try {
      await away.rig.timers.advance(1000);
      assert.match(shown(byClass(away.dialog, 'sky-player-notice')), /The recordings drive isn’t connected/);
    } finally {
      away.player.close();
    }
    const unplayable = await openOver({ playable: false, still: null });
    try {
      await unplayable.rig.timers.advance(1000);
      const text = shown(byClass(unplayable.dialog, 'sky-player-notice'));
      assert.match(text, /This browser can’t play recordings/);
      assert.doesNotMatch(text, /still picture/, 'no still to offer');
    } finally {
      unplayable.player.close();
    }
  });
});
