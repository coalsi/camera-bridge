import test from 'node:test';
import assert from 'node:assert/strict';
import {
  COARSE_CAPTION, EMPTY_TIMELINE_OFF, EMPTY_TIMELINE_ON, RECORD_NUDGE, SNAPSHOT_CAPTION, UNSUPPORTED_SENTENCE, agoText, agoWords, formatReadout, gopCaption, makeTimeFormatter,
  recorderHealthy, shouldStartLive, stageState, valueText,
} from '../web/js/screens/watch-state.js';

const NOW = Date.UTC(2026, 9, 14, 20, 0, 0);
const format = makeTimeFormatter({ timeZone: 'UTC', locale: 'en-US' });

const live = (over = {}) => ({
  mode: 'live', nvrEnabled: true, nvrState: 'recording', extent: { oldest: NOW - 86_400_000, newest: NOW - 1500, typicalGOP: 2 }, serverNowMs: NOW,
  positionMs: NOW - 6000, cell: { kind: 'live' }, presented: true, catalogPhase: 'ready', playable: true, formatTime: format, ...over,
});
const past = (over = {}) => live({ mode: 'paused', positionMs: NOW - 3_600_000, cell: { kind: 'recorded' }, ...over });

test('a recorder is healthy only while it records and the newest part is under 8 s old', () => {
  assert.equal(recorderHealthy({ nvrEnabled: true, nvrState: 'recording', extent: { newest: NOW - 7999 }, serverNowMs: NOW }), true);
  assert.equal(recorderHealthy({ nvrEnabled: true, nvrState: 'recording', extent: { newest: NOW - 8000 }, serverNowMs: NOW }), false);
  assert.equal(recorderHealthy({ nvrEnabled: true, nvrState: 'paused', extent: { newest: NOW }, serverNowMs: NOW }), false);
  assert.equal(recorderHealthy({ nvrEnabled: false, nvrState: 'recording', extent: { newest: NOW }, serverNowMs: NOW }), false);
  assert.equal(recorderHealthy({ nvrEnabled: true, nvrState: 'recording', extent: null, serverNowMs: NOW }), false);
});

test('the screen asks the session for live video once: no time in the address, nobody has moved the playhead, a healthy recorder', () => {
  // T08's session decodes nothing until the first scrub, play or go live, so a watch screen that only waits shows "Loading" for ever.
  const ok = { addressHasTime: false, started: false, mode: 'live', healthy: true };
  assert.equal(shouldStartLive(ok), true);
  assert.equal(shouldStartLive({ ...ok, started: true }), false, 'only once');
  assert.equal(shouldStartLive({ ...ok, addressHasTime: true }), false, 'an address with a time opens there (openAt), never live');
  assert.equal(shouldStartLive({ ...ok, mode: 'paused' }), false, 'a person who already scrubbed or paused stays where they are');
  assert.equal(shouldStartLive({ ...ok, mode: 'playing' }), false);
  assert.equal(shouldStartLive({ ...ok, healthy: false }), false, 'without a healthy recorder the slideshow is the live picture and nothing is decoded');
});

test('live with a healthy recorder is video; the picture never goes blank while the first frame loads', () => {
  const s = stageState(live({ presented: false, cell: { kind: 'loading' } }));
  assert.equal(s.layer, 'video');
  assert.equal(s.loading, true);
  assert.equal(s.badge.kind, 'live');
  assert.equal(s.overlay, null);
  assert.equal(stageState(live()).loading, false);
});

test('live without a healthy recorder is the snapshot preview, with the honest caption', () => {
  const off = stageState(live({ nvrEnabled: false, nvrState: 'off' }));
  assert.equal(off.layer, 'preview');
  assert.equal(off.caption, 'Picture changes every few seconds. Turn on Record for smooth live video and a timeline.');
  assert.equal(off.caption, `${SNAPSHOT_CAPTION}. ${RECORD_NUDGE}.`);
  assert.equal(off.nudge, true);
  const stale = stageState(live({ extent: { oldest: NOW - 1e7, newest: NOW - 30_000, typicalGOP: 2 } }));
  assert.equal(stale.layer, 'preview');
  assert.equal(stale.nudge, false);
  assert.equal(stale.caption, `${SNAPSHOT_CAPTION}.`);
  assert.match(stageState(live({ nvrState: 'paused' })).caption, /Recording is paused\.$/);
  assert.match(stageState(live({ nvrState: 'waiting' })).caption, /Waiting for the camera\.$/);
  assert.equal(RECORD_NUDGE, 'Turn on Record for smooth live video and a timeline');
});

test('scrubbing from live keeps the preview until a recorded frame was presented, then shows video', () => {
  assert.equal(stageState(past({ presented: false, cell: { kind: 'loading' } })).layer, 'preview');
  assert.equal(stageState(past({ presented: false, cell: { kind: 'loading' } })).loading, true);
  assert.equal(stageState(past({ presented: true })).layer, 'video');
  assert.equal(stageState(past({ presented: true, cell: { kind: 'loading' } })).layer, 'video');   // an old frame stays while the next one loads
});

test('a gap holds the picture and offers the next recording, or live', () => {
  const withNext = stageState(past({ cell: { kind: 'gap', next: NOW - 1_800_000 } }));
  assert.equal(withNext.layer, 'video');
  assert.equal(withNext.overlay.kind, 'gap');
  assert.equal(withNext.overlay.title, 'No recording at 19:00:00');
  assert.equal(withNext.overlay.body, 'Next recording at 19:30:00.');
  assert.deepEqual(withNext.overlay.actions.map((a) => a.id), ['jump']);
  const none = stageState(past({ cell: { kind: 'gap', next: null } }));
  assert.equal(none.overlay.body, 'Nothing was recorded after this.');
  assert.deepEqual(none.overlay.actions.map((a) => a.id), ['live']);
});

test('drive missing, unreadable and unsupported have their sentences and buttons', () => {
  const drive = stageState(past({ cell: { kind: 'driveMissing' } }));
  assert.equal(drive.overlay.title, 'The recordings drive isn’t connected');
  assert.deepEqual(drive.overlay.actions.map((a) => a.id), ['live']);
  const bad = stageState(past({ cell: { kind: 'unreadable' } }));
  assert.equal(bad.overlay.title, 'Can’t read this part of the recording');
  assert.deepEqual(bad.overlay.actions.map((a) => a.id), ['retry', 'live']);
  const unsupported = stageState(past({ cell: { kind: 'unsupported', message: 'This browser can’t play H.265 recordings. Safari, or Chrome on a Mac, can.' } }));
  assert.equal(unsupported.layer, 'preview');
  assert.equal(unsupported.overlay.body, 'This browser can’t play H.265 recordings. Safari, or Chrome on a Mac, can.');
  assert.equal(unsupported.scrubbable, false);
  const noMse = stageState(live({ playable: false }));
  assert.equal(noMse.overlay.body, UNSUPPORTED_SENTENCE);
  assert.equal(noMse.layer, 'preview');
});

test('coarse pictures say so', () => {
  const s = stageState(past({ cell: { kind: 'coarse' } }));
  assert.equal(s.caption, COARSE_CAPTION);
  assert.equal(s.layer, 'video');
});

test('nothing recorded: the track is off, the slideshow stays, and the words depend on Record', () => {
  const off = stageState(live({ extent: null, nvrEnabled: false, nvrState: 'off' }));
  assert.equal(off.scrubbable, false);
  assert.equal(off.layer, 'preview');
  assert.equal(off.caption, `${SNAPSHOT_CAPTION}. ${RECORD_NUDGE}.`);
  assert.equal(off.nudge, true);
  const on = stageState(live({ extent: null, nvrState: 'waiting' }));
  assert.equal(on.caption, `${SNAPSHOT_CAPTION}. Waiting for the first footage.`);
  assert.equal(on.nudge, false);
  assert.equal(EMPTY_TIMELINE_OFF, 'Nothing recorded yet. Turn on Record to build a timeline.');
  assert.match(EMPTY_TIMELINE_ON, /first few seconds of footage\.$/);
});

test('while the catalog loads: a spinner, a calm message, or a plain refusal', () => {
  assert.equal(stageState(live({ catalogPhase: 'starting', extent: null })).loading, true);
  assert.equal(stageState(live({ catalogPhase: 'loading', extent: null })).overlay.title, 'Recordings are loading');
  assert.equal(stageState(live({ catalogPhase: 'unavailable', extent: null })).overlay.title, 'Recordings aren’t available');
});

test('the long key-frame caption starts above 4 s', () => {
  assert.equal(gopCaption(null), null);
  assert.equal(gopCaption(4), null);
  assert.equal(gopCaption(2), null);
  assert.equal(gopCaption(4.2), 'Keyframes every 4 s: scrubbing is coarse. A 2 s interval scrubs best.');
  assert.equal(gopCaption(29.6), 'Keyframes every 30 s: scrubbing is coarse. A 2 s interval scrubs best.');
});

test('readout: live shows the measured lag, the past shows how long ago and adds the date for another day', () => {
  assert.deepEqual(formatReadout({ mode: 'live', positionMs: NOW - 6000, serverNowMs: NOW, healthy: true, format }), { primary: '19:59:54', secondary: 'Live, 6 s behind' });
  assert.deepEqual(formatReadout({ mode: 'live', positionMs: NOW - 6000, serverNowMs: NOW, healthy: false, format }), { primary: '20:00:00', secondary: 'Live' });
  assert.deepEqual(formatReadout({ mode: 'paused', positionMs: NOW - 3_725_000, serverNowMs: NOW, healthy: true, format }), { primary: '18:57:55', secondary: '1 h 2 min ago' });
  assert.deepEqual(formatReadout({ mode: 'playing', positionMs: NOW - 26 * 3_600_000, serverNowMs: NOW, healthy: true, format }), { primary: 'Tue, Oct 13 18:00:00', secondary: '1 d 2 h ago' });
});

test('words for ago', () => {
  assert.equal(agoText(400), 'now');
  assert.equal(agoText(45_000), '45 s ago');
  assert.equal(agoText(5 * 60_000), '5 min ago');
  assert.equal(agoText(3 * 3_600_000), '3 h ago');
  assert.equal(agoText(3 * 3_600_000 + 12 * 60_000), '3 h 12 min ago');
  assert.equal(agoText(2 * 86_400_000), '2 d ago');
  assert.equal(agoWords(1000), '1 second ago');
  assert.equal(agoWords(3 * 3_600_000 + 12 * 60_000), '3 hours 12 minutes ago');
  assert.equal(agoWords(86_400_000 + 3_600_000), '1 day 1 hour ago');
});

test('slider text is in words', () => {
  assert.equal(valueText({ mode: 'live', positionMs: NOW - 6000, serverNowMs: NOW, healthy: true, format }), 'Live, 6 seconds behind');
  assert.equal(valueText({ mode: 'live', positionMs: NOW - 6000, serverNowMs: NOW, healthy: false, format }), 'Live');
  assert.equal(valueText({ mode: 'paused', positionMs: NOW - 3_725_000, serverNowMs: NOW, healthy: true, format }),
    'Wednesday, October 14, 2026 at 6:57:55 PM, 1 hour 2 minutes ago');
});
