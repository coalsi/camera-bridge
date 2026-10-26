// Sky Watcher's clip player (screens/sky-player.js, sky-player-model.js): a modal on the sky log that plays the camera's recording around one
// light with the Monitor's own playback (its catalog, session, cells and grid controller, its transport, keys and scrubbing). The window from 15 s
// before the light to 15 s after it and its widening, the light's path at the matching times, the Zoom's origin, the keys bounded by the window,
// what it says when there is no recording to play, and, against the real session over the fake archive, that paused stays paused while scrubbing
// and stepping, that the end of the window pauses, and that closing it frees the stream.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { after, before, describe, it, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';
import { createRig } from './player-fakes/rig.mjs';
import { FILE_A, FILE_B, ORIGIN } from './player-fakes/fake-archive.mjs';
import { DEFAULT_POLICY } from '../web/js/nvr/planner.js';
import { KEY_MAP } from '../web/js/screens/nvr-model.js';
import { SKY_TEXT, normalizeEntry } from '../web/js/screens/sky-model.js';
import {
  SKY_KEY_MAP, WINDOW, clipWindow, clockText, marginText, pathPointAt, playerNotice, widenMargin, windowedAction, zoomAt,
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

test('the Zoom magnifies around the light: its origin is the light at that moment, its scale the close-up’s', () => {
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

test('the keyboard help is the Monitor’s, less what a clip has no use for, and says Esc closes', () => {
  const monitor = new Map(KEY_MAP);
  assert.deepEqual(SKY_KEY_MAP.map(([keys]) => keys), ['Space', '← →', 'Shift + ← →', 'Alt + ← →', ', .', 'Esc']);
  for (const keys of ['Space', '← →', 'Shift + ← →', ', .']) assert.equal(new Map(SKY_KEY_MAP).get(keys), monitor.get(keys), `${keys} reads as on the Monitor`);
  assert.equal(new Map(SKY_KEY_MAP).get('Alt + ← →'), '10 seconds back or forward');
  assert.equal(new Map(SKY_KEY_MAP).get('Esc'), 'Close');
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
  assert.equal(T.zoom, 'Zoom');
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
  ({ openSkyPlayer } = await import('../web/js/screens/sky-player.js'));
});
after(() => browser?.restore());

/**
 * The player over the rig: the real fetcher, catalog, clock, cells and session over the fake archive, the grid controller, and every timer
 * (the cells', the session's, the controller's and the player's frames) on the rig's fake clock.
 */
async function openOver({ files = FILES(), entry = lightAt(ORIGIN + 50_000), at = camera(), still = '/api/v1/sky/cameras/x/entries/u1/still?night=2026-10-24', playable = true } = {}) {
  const rig = createRig({ cameras: [{ id: CAM, files }] });
  await rig.start();
  const closed = [];
  const player = openSkyPlayer({
    camera: at, entry, zone: CHICAGO, heading: '3:12:08 AM', what: 'Moving light · North Sky', still, watchHref: `#/camera/${CAM}/watch/${entry.watch}`,
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
  await rig.timers.advance(500);
  return { rig, player, dialog, track, closed, surface: () => rig.surface(CAM) };
}
const playButton = (dialog) => all(dialog, (node) => node.localName === 'button' && node.dataset?.playing !== undefined)[0];
const readout = (dialog) => byClass(dialog, 'nvr-readout');
const position = (track) => Number(track.getAttribute('aria-valuenow'));
const key = (init) => document.dispatchEvent({ type: 'keydown', target: document.body, preventDefault() {}, stopImmediatePropagation() {}, ...init });
const pointer = (track, type, clientX) => track.dispatchEvent({ type, pointerId: 1, pointerType: 'mouse', button: 0, clientX, target: track, preventDefault() {} });

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

  it('draws the light’s path over the video and the light where it is at that moment; Zoom magnifies around it', async () => {
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
      const [width, height] = overlay.getAttribute('viewBox').split(' ').slice(2).map(Number);
      assert.deepEqual([width, height], [1920, 852], 'in the picture’s own coordinates');
      const now = byClass(overlay, 'sky-player-now');
      const point = pathPointAt(entry.path, entry.start, position(track), entry.end);
      assert.equal(Number(now.getAttribute('cx')).toFixed(1), (point.x * 1920).toFixed(1));
      assert.equal(Number(now.getAttribute('cy')).toFixed(1), (point.y * 852).toFixed(1));
      assert.equal(now.dataset.at, 'during');
      assert.ok(byClass(overlay, 'sky-path-line'), 'and the whole path, faint');

      const zoom = button(dialog, T.zoom);
      zoom.click();
      await rig.timers.advance(100);
      const stage = byClass(dialog, 'sky-player-stage');
      assert.equal(stage.dataset.zoom, 'true');
      assert.equal(zoom.getAttribute('aria-pressed'), 'true');
      const picture = byClass(dialog, 'sky-player-picture');
      const expected = zoomAt(entry.path, entry.start, position(track), { width: 1920, height: 852 });
      assert.equal(picture.style.getPropertyValue('--sky-zoom'), String(expected.scale));
      assert.equal(picture.style.getPropertyValue('--sky-zoom-x'), `${expected.x}%`);
      assert.equal(picture.style.getPropertyValue('--sky-zoom-y'), `${expected.y}%`);
      zoom.click();
      assert.equal(stage.dataset.zoom, 'false');
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
