// Sky Watcher's words and numbers (screens/sky-model.js): direction, speed, blink, shape, the summary, the conditions line, the aim, the strip's
// dots, the groups of the explained, the path in picture coordinates. Pure: no browser, no requests. The sentences are exact.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { ApiError } from '../web/js/api.js';
import {
  SKY_ROUTE, SKY_TEXT, aimLines, aimText, blinkText, clipAddress, compassWord, conditionsText, countEntries, countLabel, countsAfter, dayLabel, defaultLensLayout, directionText,
  durationText, entryBucket, groupExplained, learningText, normalizeEntry, pathPoints, refusalOf, shapeText, shiftDate, skyWatching, speedText, streamText,
  stripDots, stripTicks, summaryText, timeText, toMs, watchAddress,
} from '../web/js/screens/sky-model.js';

const CHICAGO = 'America/Chicago';
/** 25 October 2026, `hour:minute` in Chicago (still on daylight time: it ends on 1 November), as epoch ms. */
const chicago = (hour, minute = 0, day = 25) => Date.UTC(2026, 9, day, hour + 5, minute);

// MARK: The sentences

test('direction, speed, blink, shape and summary words are exact', () => {
  assert.equal(compassWord(0), 'north');
  assert.deepEqual([45, 90, 135, 180, 225, 270, 315].map(compassWord), ['northeast', 'east', 'southeast', 'south', 'southwest', 'west', 'northwest']);
  assert.equal(compassWord(359), 'north', 'just short of a full turn is north');
  assert.equal(compassWord(-45), 'northwest', 'a negative azimuth wraps');
  assert.equal(compassWord(22.4), 'north');
  assert.equal(compassWord(22.6), 'northeast');
  assert.equal(compassWord(NaN), '');

  assert.equal(directionText(312, 8), 'low in the northwest, 8° up');
  assert.equal(directionText(45, 30), 'in the northeast, 30° up');
  assert.equal(directionText(10, 75), 'high in the north, 75° up');
  assert.equal(directionText(350.2, 14.6), 'in the north, 15° up', 'low or high is decided on the number that is shown');
  assert.equal(directionText(180, 14.4), 'low in the south, 14° up');
  assert.equal(directionText(180, -3), 'low in the south, 0° up', 'never below the horizon');
  assert.equal(directionText(NaN, 5), '');

  assert.equal(speedText(6.1), 'about 6× faster across the sky than planes at that height');
  assert.equal(speedText(1.8), 'about 1.8× faster across the sky than planes at that height');
  assert.equal(speedText(2), 'about 2× faster across the sky than planes at that height', 'no “2.0”');
  assert.equal(speedText(10.4), 'about 10× faster across the sky than planes at that height');
  assert.equal(speedText(0.9), 'about as fast across the sky as planes at that height');
  assert.equal(speedText(0.75), 'about as fast across the sky as planes at that height');
  assert.equal(speedText(1.24), 'about as fast across the sky as planes at that height');
  assert.equal(speedText(0.5), 'slower across the sky than planes at that height');
  assert.equal(speedText(0.74), 'slower across the sky than planes at that height');
  assert.match(speedText(1.3), /^about 1\.3× faster/);
  for (const nothing of [null, undefined, NaN, 0, -2, Infinity, '6']) assert.equal(speedText(nothing), '', `${String(nothing)} is no comparison`);

  assert.equal(blinkText(true, 1), 'Blinks about once a second');
  assert.equal(blinkText(true, 0.9), 'Blinks about once a second');
  assert.equal(blinkText(true, 2), 'Blinks about 2 times a second');
  assert.equal(blinkText(true, 1 / 3), 'Blinks about once every 3 seconds');
  assert.equal(blinkText(true, 0.5), 'Blinks about once every 2 seconds');
  assert.equal(blinkText(true, null), 'Blinks');
  assert.equal(blinkText(false, null), 'Steady (doesn’t blink)');
  assert.equal(blinkText(false, 2), 'Steady (doesn’t blink)', 'a rate without blinks is still steady');
  assert.equal(blinkText(undefined, undefined), 'Steady (doesn’t blink)');

  assert.deepEqual(['straight', 'curved', 'suddenStop', 'sharpTurn'].map(shapeText), ['Straight', 'Curved', 'Stops suddenly', 'Turns sharply']);
  assert.equal(shapeText('zigzag'), '');

  assert.equal(summaryText({ unexplained: 1, explained: 214 }, 'night'), 'Last night: 1 unexplained, 214 explained');
  assert.equal(summaryText({ unexplained: 1, explained: 1 }, 'night'), 'Last night: 1 unexplained, 1 explained');
  assert.equal(summaryText({ unexplained: 0, explained: 0 }, 'night'), 'Last night: 0 unexplained, 0 explained');
  assert.equal(summaryText({ unexplained: 3, explained: 40 }, 'day'), 'Today: 3 unexplained, 40 explained');
  assert.equal(summaryText({ unexplained: 3, explained: 40 }, 'night', 'Tonight so far'), 'Tonight so far: 3 unexplained, 40 explained');
  assert.equal(summaryText({ unexplained: 2, explained: 9 }, 'night', 'Night of Sat, Oct 24'), 'Night of Sat, Oct 24: 2 unexplained, 9 explained');
  assert.equal(summaryText(null, 'night'), 'Last night: 0 unexplained, 0 explained');

  assert.equal(durationText(0.4), 'under a second');
  assert.equal(durationText(1), '1 second');
  assert.equal(durationText(4.2), '4.2 seconds');
  assert.equal(durationText(4), '4 seconds');
  assert.equal(durationText(12.4), '12 seconds');
  assert.equal(durationText(95), '2 minutes');
  assert.equal(durationText(NaN), '');

  assert.equal(countLabel('unexplained', 1), 'unexplained');
  assert.deepEqual([1, 2].map((n) => countLabel('planes', n)), ['plane', 'planes']);
  assert.deepEqual([1, 2].map((n) => countLabel('satellites', n)), ['satellite', 'satellites']);
  assert.deepEqual([1, 2].map((n) => countLabel('meteors', n)), ['meteor', 'meteors']);
  assert.deepEqual([1, 2].map((n) => countLabel('bugsAndBirds', n)), ['bug or bird', 'bugs and birds']);
  assert.equal(countLabel('notSure', 4), 'not sure');
});

test('times read as the box’s clock, in the zone given', () => {
  assert.equal(timeText(chicago(3, 12) + 8000, CHICAGO, { seconds: true }), '3:12:08 AM');
  assert.equal(timeText(chicago(15, 5), CHICAGO), '3:05 PM');
  assert.equal(timeText(chicago(0, 0), CHICAGO), '12:00 AM');
  assert.equal(timeText(chicago(12, 0), CHICAGO), '12:00 PM');
  assert.equal(timeText(chicago(3, 0), 'UTC'), '8:00 AM', 'the zone decides, not this computer');
  assert.equal(timeText(chicago(3, 0), 'Not/AZone').length > 0, true, 'a zone that does not exist falls back to this computer’s');
  assert.equal(dayLabel('2026-10-24'), 'Sat, Oct 24');
  assert.equal(dayLabel('2026-12-31'), 'Thu, Dec 31');
  assert.equal(dayLabel('nonsense'), '');
  assert.equal(shiftDate('2026-10-24', -1), '2026-10-23');
  assert.equal(shiftDate('2026-10-31', 1), '2026-11-01');
  assert.equal(shiftDate('2026-12-31', 1), '2027-01-01');
  assert.equal(shiftDate('2026-03-01', -1), '2026-02-28');
  assert.equal(shiftDate('nonsense', 1), null);
});

test('conditions read as one line', () => {
  const night = [
    { from: chicago(22, 0, 24), to: chicago(3), state: 'clear', cloudCover: 10 },
    { from: chicago(3), to: chicago(5), state: 'notVisible', cloudCover: 95 },
  ];
  assert.equal(conditionsText(night, CHICAGO), '☁︎ clear until 3 AM; sky not visible 3–5 AM');
  assert.equal('☁︎'.codePointAt(0), 0x2601, 'the cloud, with its text selector');
  assert.equal('☁︎'.length, 2);

  assert.equal(conditionsText([{ from: chicago(20, 0, 24), to: chicago(6), state: 'clear' }], CHICAGO), '☁︎ clear all night');
  assert.equal(conditionsText([{ from: chicago(0), to: chicago(23, 59), state: 'cloudy' }], CHICAGO, 'day'), '☁︎ cloudy all day');
  assert.equal(conditionsText([{ from: chicago(20, 0, 24), to: chicago(6), state: 'notVisible' }], CHICAGO), '☁︎ sky not visible all night');

  // Spans of one state that touch are one; minutes show only when there are some; AM and PM are said where they change.
  const long = [
    { from: chicago(19, 30, 24), to: chicago(22, 0, 24), state: 'clear' },
    { from: chicago(22, 0, 24), to: chicago(23, 0, 24), state: 'clear' },
    { from: chicago(23, 0, 24), to: chicago(1, 30), state: 'cloudy' },
    { from: chicago(1, 30), to: chicago(5, 0), state: 'clear' },
  ];
  assert.equal(conditionsText(long, CHICAGO), '☁︎ clear until 11 PM; cloudy 11 PM–1:30 AM; clear 1:30–5 AM');
  assert.equal(conditionsText([
    { from: chicago(20, 0, 24), to: chicago(22, 0, 24), state: 'notVisible' },
    { from: chicago(22, 0, 24), to: chicago(6), state: 'clear' },
  ], CHICAGO), '☁︎ sky not visible until 10 PM; clear 10 PM–6 AM');

  // Spans out of order, a span that is nothing, and unknown stretches.
  assert.equal(conditionsText([night[1], night[0], { from: chicago(5), to: chicago(5), state: 'cloudy' }], CHICAGO), '☁︎ clear until 3 AM; sky not visible 3–5 AM');
  assert.equal(conditionsText([{ from: chicago(20, 0, 24), to: chicago(6), state: 'unknown' }], CHICAGO), '', 'nothing known: nothing said');
  assert.equal(conditionsText([night[0], { from: chicago(3), to: chicago(4), state: 'unknown' }], CHICAGO), '☁︎ clear until 3 AM; sky conditions unknown 3–4 AM');
  assert.equal(conditionsText([], CHICAGO), '');
  assert.equal(conditionsText(null, CHICAGO), '');
  assert.equal(conditionsText([{ from: 'x', to: NaN, state: 'clear' }], CHICAGO), '', 'a span that is not times is left out');
});

test('the aim reads rough, good, precise: overall and by lens', () => {
  assert.equal(aimText({ quality: 'rough', planes: 0, stars: 0, residualPixels: null }), 'Aim: rough');
  assert.equal(aimText({ quality: 'rough', planes: 4, stars: 0, residualPixels: null }), 'Aim: rough', 'a few matches do not make it good');
  assert.equal(aimText({ quality: 'good', planes: 23, stars: 0, residualPixels: 14.2 }), 'Aim: good, 23 planes matched, 14 px');
  assert.equal(aimText({ quality: 'good', planes: 1, stars: 0, residualPixels: 14 }), 'Aim: good, 1 plane matched, 14 px');
  assert.equal(aimText({ quality: 'precise', planes: 30, stars: 214, residualPixels: 1.8 }), 'Aim: precise, 214 stars matched, 1.8 px');
  assert.equal(aimText({ quality: 'precise', planes: 30, stars: 1, residualPixels: 2 }), 'Aim: precise, 1 star matched, 2 px');
  assert.equal(aimText({ quality: 'good', planes: 23, stars: 0, residualPixels: null }), 'Aim: good, 23 planes matched', 'no residual yet: no pixels');
  assert.equal(aimText({ quality: 'good', planes: 0, stars: 12, residualPixels: 6.04 }), 'Aim: good, 12 stars matched, 6 px', 'stars alone count');
  assert.equal(aimText(null), 'Aim: rough');
  assert.equal(aimText({ quality: 'sharp' }), 'Aim: rough', 'a state the page does not know is not claimed');

  const dual = {
    quality: 'good', planes: 40, stars: 214, residualPixels: 5,
    lenses: [{ quality: 'precise', planes: 30, stars: 214, residualPixels: 1.8 }, { quality: 'good', planes: 23, stars: 0, residualPixels: 14 }],
  };
  assert.deepEqual(aimLines(dual), ['Left lens: precise, 214 stars matched, 1.8 px', 'Right lens: good, 23 planes matched, 14 px']);
  assert.deepEqual(aimLines({ quality: 'rough', planes: 0, stars: 0, residualPixels: null, lenses: [] }, 'dual'), ['Left lens: rough', 'Right lens: rough'], 'a dual camera before a fit');
  assert.deepEqual(aimLines({ ...dual, lenses: [dual.lenses[0]] }, 'dual'), ['Left lens: precise, 214 stars matched, 1.8 px', 'Right lens: rough']);
  assert.deepEqual(aimLines({ quality: 'good', planes: 23, stars: 0, residualPixels: 14, lenses: [] }, 'single'), ['Aim: good, 23 planes matched, 14 px']);
  assert.deepEqual(aimLines({ quality: 'good', planes: 23, stars: 0, residualPixels: 14, lenses: [{ quality: 'good', planes: 23, stars: 0, residualPixels: 14 }] }), ['Aim: good, 23 planes matched, 14 px']);
  assert.deepEqual(aimLines(null), ['Aim: rough']);
  assert.deepEqual(aimLines(undefined, 'dual'), ['Left lens: rough', 'Right lens: rough']);
});

test('what the box is still learning, and which stream it watches', () => {
  assert.equal(learningText({ ready: false, planes: 12, satellites: 0 }), 'Still learning this sky: 12 of 30 planes matched. No alerts until then.');
  assert.equal(learningText({ ready: false, planes: 1, satellites: 0 }), 'Still learning this sky: 1 of 30 planes matched. No alerts until then.');
  assert.equal(learningText({ ready: false, planes: 30, satellites: 4 }), 'Still learning this sky: 4 of 10 satellites matched. No alerts until then.');
  assert.equal(learningText({ ready: false, planes: 5, satellites: 0, planesNeeded: 20 }), 'Still learning this sky: 5 of 20 planes matched. No alerts until then.', 'the box’s own number wins');
  assert.equal(learningText({ ready: true, planes: 31, satellites: 11 }), '');
  assert.equal(learningText(null), '');
  assert.equal(learningText({}), '', 'no word from the box: nothing said');

  assert.equal(streamText({ running: true, stream: 'main', analysisWidth: 1920, picturesPerSecond: 5 }), 'Watching the main stream at 1920 px, 5 pictures a second');
  assert.equal(streamText({ running: true, stream: 'sub', analysisWidth: 1280, picturesPerSecond: 4.8 }), 'Watching the sub stream at 1280 px, 4.8 pictures a second');
  assert.equal(streamText({ running: true, stream: 'sub', analysisWidth: 1280, picturesPerSecond: 1 }), 'Watching the sub stream at 1280 px, 1 picture a second');
  assert.equal(streamText({ running: true, stream: 'main', analysisWidth: 1920, picturesPerSecond: 5.04 }), 'Watching the main stream at 1920 px, 5 pictures a second');
  assert.equal(streamText({ running: true, stream: null, analysisWidth: null, picturesPerSecond: null }), 'Starting…');
  assert.equal(streamText({ running: false, stream: null }), 'Not watching right now');
  assert.equal(streamText(null), '');
  assert.equal(streamText(undefined), '');
});

test('refusals read as the bridge’s sentence, and say what is missing', () => {
  const location = new ApiError(400, 'invalid', 'Set where the box is first.', 'sky.location');
  const folder = new ApiError(400, 'invalid', 'Choose a recordings folder first: the sky log is kept with the recordings.', 'nvrFolder');
  const battery = new ApiError(400, 'invalid', 'Battery cameras can’t watch the sky: it would keep them awake.');
  const plugin = new ApiError(400, 'invalid', 'Turn on Sky Watcher in Plugins first.', 'plugins.sky');
  assert.deepEqual(refusalOf(plugin), { text: 'Turn on Sky Watcher in Plugins first.', needs: 'plugin' }, 'the plugin is off: the way to Plugins is offered');
  assert.deepEqual(refusalOf(new ApiError(400, 'invalid', 'Turn on Sky Watcher in Plugins first.')), { text: 'Turn on Sky Watcher in Plugins first.', needs: 'plugin' }, 'by its words too');
  assert.deepEqual(refusalOf(location), { text: 'Set where the box is first.', needs: 'location' });
  assert.deepEqual(refusalOf(folder), { text: 'Choose a recordings folder first: the sky log is kept with the recordings.', needs: 'folder' });
  assert.deepEqual(refusalOf(battery), { text: 'Battery cameras can’t watch the sky: it would keep them awake.', needs: null });
  assert.deepEqual(refusalOf(new ApiError(0, 'network', 'The bridge didn’t answer. Check that it is on and that this device is on the same network.')),
    { text: 'The bridge didn’t answer. Check that it is on and that this device is on the same network.', needs: null });
  assert.deepEqual(refusalOf(new ApiError(500, 'error', '  ')), { text: SKY_TEXT.card.failed, needs: null });
  assert.deepEqual(refusalOf(new TypeError('x is undefined')), { text: SKY_TEXT.card.failed, needs: null }, 'a script error never shows its own text');
  assert.deepEqual(refusalOf(null), { text: SKY_TEXT.card.failed, needs: null });
});

// MARK: The strip and the groups

const entry = (id, label, start, extra = {}) => ({
  id, camera: '0A1B2C3D-0000-4000-8000-000000000004', kind: 'track', start, end: start + 4000, path: [], label, display: label,
  by: null, detail: null, unusual: [], speedVsPlanes: null, candidate: false, alerted: false, hasStill: false, ai: null, correction: null,
  measures: { azimuth: 10, elevation: 45, azimuthEnd: 20, elevationEnd: 55, duration: 4, blinks: false, blinkRate: null, shape: 'straight' }, ...extra,
});

test('the strip puts a dot for each entry by time and height, coloured by kind, the unexplained marked', () => {
  const from = 1_000_000;
  const to = 1_000_000 + 12 * 3_600_000;
  const entries = [
    entry('a', 'plane', from),                                                                                     // at the very start
    entry('b', 'unexplained', from + 6 * 3_600_000, { measures: { elevation: 90, elevationEnd: 90 } }),                // halfway, at the zenith
    entry('c', 'satellite', to - 4000),                                                                            // at the very end
    entry('d', 'meteor', from + 3 * 3_600_000, { measures: { elevation: 0, elevationEnd: 0 } }),                      // a quarter in, on the horizon
    entry('e', 'bird', from + 9 * 3_600_000),
    entry('f', 'probablePlane', from + 1 * 3_600_000),
    entry('g', 'satelliteFlare', from + 2 * 3_600_000),
    entry('h', 'bug', from + 4 * 3_600_000),
    entry('i', 'plane', from + 5 * 3_600_000, { correction: 'notSure' }),
    entry('j', 'plane', from - 60_000),                                                                            // before the window: held at the edge
    entry('k', 'plane', to + 60_000),                                                                              // after: held at the other
  ];
  const dots = stripDots(entries, from, to);
  assert.equal(dots.length, entries.length);
  const at = (id) => dots[entries.findIndex((e) => e.id === id)];
  assert.deepEqual([at('a').x, at('c').x > 0.999, at('b').x, at('d').x], [0, true, 0.5, 0.25]);
  assert.equal(at('b').y, 0, 'the zenith is the top');
  assert.equal(at('d').y, 1, 'the horizon is the bottom');
  assert.ok(Math.abs(at('a').y - (1 - 50 / 90)) < 1e-9, 'the middle of 45° and 55° is 50°');
  assert.deepEqual(dots.map((dot) => dot.kind), ['planes', 'unexplained', 'satellites', 'meteors', 'bugsAndBirds', 'planes', 'satellites', 'bugsAndBirds', 'notSure', 'planes', 'planes']);
  assert.deepEqual(dots.map((dot) => dot.unexplained), [false, true, false, false, false, false, false, false, false, false, false]);
  assert.equal(at('j').x, 0);
  assert.equal(at('k').x, 1);
  assert.deepEqual(dots.map((dot) => dot.id), entries.map((e) => e.id));
  assert.ok(dots.every((dot) => dot.x >= 0 && dot.x <= 1 && dot.y >= 0 && dot.y <= 1));
  assert.deepEqual(stripDots([entry('z', 'plane', 5)], 10, 10), [], 'a window with no length has no strip');
  assert.deepEqual(stripDots([], from, to), []);
  assert.deepEqual(stripDots(null, from, to), []);
  assert.equal(stripDots([entry('n', 'plane', from, { measures: {} })], from, to)[0].y, 1, 'no height known: on the horizon');
});

test('hour marks fall on the zone’s own hours, with room at both ends', () => {
  const from = chicago(18, 32, 24);
  const to = chicago(7, 21);
  const ticks = stripTicks(from, to, CHICAGO);
  assert.deepEqual(ticks.map((tick) => tick.label), ['10 PM', '12 AM', '2 AM', '4 AM'], 'every two hours on a night of 13 hours; 8 PM and 6 AM are too near the ends, where the times of sunset and sunrise stand');
  const span = to - from;
  assert.ok(Math.abs(ticks[0].x - (chicago(22, 0, 24) - from) / span) < 1e-9);
  assert.ok(ticks.every((tick) => tick.x >= 0.14 && tick.x <= 0.86));
  const day = stripTicks(chicago(0, 0), chicago(0, 0) + 86_400_000, CHICAGO);
  assert.deepEqual(day.map((tick) => tick.label), ['6 AM', '9 AM', '12 PM', '3 PM', '6 PM'], 'every three hours across a day');
  assert.deepEqual(stripTicks(10, 10, CHICAGO), []);
  assert.deepEqual(stripTicks(chicago(0, 0), chicago(0, 20), CHICAGO), [], 'a window under an hour has none');
});

test('the explained entries are grouped planes, satellites, meteors, bugs and birds, then not sure; the unexplained are not among them', () => {
  const entries = [
    entry('s2', 'satellite', 30), entry('p1', 'plane', 10), entry('u1', 'unexplained', 15), entry('b1', 'bird', 25), entry('m1', 'meteor', 20),
    entry('p2', 'probablePlane', 12), entry('f1', 'satelliteFlare', 5), entry('g1', 'bug', 40), entry('n1', 'plane', 50, { correction: 'notSure' }),
    entry('u2', 'unexplained', 60, { correction: 'notSure' }),
  ];
  const groups = groupExplained(entries);
  assert.deepEqual(groups.map((group) => [group.label, group.title, group.entries.map((e) => e.id)]), [
    ['planes', 'Planes', ['p1', 'p2']],
    ['satellites', 'Satellites', ['f1', 's2']],
    ['meteors', 'Meteors', ['m1']],
    ['bugsAndBirds', 'Bugs and birds', ['b1', 'g1']],
    ['notSure', 'Not sure', ['n1']],
  ], 'in time order inside each group; an unexplained entry marked “not sure” stays among the unexplained');
  assert.deepEqual(groupExplained([entry('only', 'meteor', 1)]).map((group) => group.label), ['meteors'], 'a group with nothing in it is left out');
  assert.deepEqual(groupExplained([]), []);
  assert.deepEqual(groupExplained(null), []);
  assert.equal(entryBucket(entry('x', 'unexplained', 1)), 'unexplained');
  assert.equal(entryBucket({ display: 'somethingNew' }), 'unexplained', 'a label the page does not know is shown, not hidden');
  assert.equal(entryBucket({ label: 'plane' }), 'planes', 'the entry’s own label when there is no display');
});

test('entries are counted as the bridge counts them', () => {
  const entries = [entry('a', 'plane', 1), entry('b', 'probablePlane', 2), entry('c', 'satellite', 3), entry('d', 'meteor', 4), entry('e', 'bird', 5), entry('f', 'bug', 6),
    entry('g', 'unexplained', 7), entry('h', 'plane', 8, { correction: 'notSure' })];
  assert.deepEqual(countEntries(entries), { unexplained: 1, planes: 2, satellites: 1, meteors: 1, bugsAndBirds: 2, notSure: 1, explained: 7 });
  assert.deepEqual(countEntries(null), { unexplained: 0, planes: 0, satellites: 0, meteors: 0, bugsAndBirds: 0, notSure: 0, explained: 0 });
});

test('a correction moves one entry between the counts and nothing else', () => {
  const counts = { unexplained: 3, planes: 40, satellites: 170, meteors: 4, bugsAndBirds: 2, notSure: 0, explained: 216 };
  const unexplained = entry('u', 'unexplained', 1);
  const bird = { ...unexplained, display: 'bird', correction: 'bird' };
  assert.deepEqual(countsAfter(counts, unexplained, bird), { unexplained: 2, planes: 40, satellites: 170, meteors: 4, bugsAndBirds: 3, notSure: 0, explained: 217 });
  const plane = entry('p', 'plane', 2);
  const notSure = { ...plane, correction: 'notSure' };
  assert.deepEqual(countsAfter(counts, plane, notSure), { ...counts, planes: 39, notSure: 1 }, 'explained stays: it is still explained, but doubted');
  assert.deepEqual(countsAfter(counts, plane, { ...plane, display: 'plane', correction: 'plane' }), counts, 'the same bucket: no change');
  assert.deepEqual(countsAfter(counts, bird, unexplained), { ...counts, unexplained: 4, bugsAndBirds: 1, explained: 215 }, 'and back');
  assert.deepEqual(countsAfter(null, unexplained, bird), null);
  assert.equal(counts.unexplained, 3, 'the counts given are not changed');
});

// MARK: The path, the links, the address

test('the path is in picture coordinates', () => {
  assert.equal(pathPoints([[0, 0.1, 0.2], [1, 0.3, 0.25]], 400, 177), '40,35.4 120,44.25');
  assert.equal(pathPoints([{ t: 0, x: 0.1, y: 0.2 }, { t: 1, x: 0.3, y: 0.25 }], 400, 177), '40,35.4 120,44.25', 'as objects too');
  assert.equal(pathPoints([[0, 0, 0], [3, 1, 1]], 4256, 1888), '0,0 4256,1888');
  assert.equal(pathPoints([[0, 0.5, 0.5]], 400, 177), '200,88.5', 'one point is a point');
  assert.equal(pathPoints([], 400, 177), '');
  assert.equal(pathPoints(null, 400, 177), '');
  assert.equal(pathPoints([[0, 0.1, 0.2], [1, 'x', 0.3], [2, NaN, 0.3], [3, 0.2, 0.3]], 400, 177), '40,35.4 80,53.1', 'a point that is not numbers is skipped');
  assert.equal(pathPoints([[0, 0.1, 0.2], [1, 0.3, 0.25]], 0, 177), '', 'no picture size yet');
  assert.equal(pathPoints(Array.from({ length: 200 }, (_, i) => [i, i / 200, 0.5]), 100, 100).split(' ').length, 64, 'at most 64 points are drawn');
});

test('an entry opens its moment in the recordings three seconds early, and downloads from there', () => {
  const id = '0A1B2C3D-0000-4000-8000-000000000004';
  const e = entry('x', 'unexplained', chicago(3, 12), { watch: chicago(3, 12) - 3000 });
  assert.equal(watchAddress(id, e), `#/camera/${id}/watch/${chicago(3, 12) - 3000}`);
  assert.equal(watchAddress(id, { ...e, watch: undefined }), `#/camera/${id}/watch/${chicago(3, 12) - 3000}`, 'start − 3 s when the box gave none');
  assert.match(watchAddress(id, e), /\/watch\/\d{13}$/, 'the Watch route wants 12 or 13 digits');
  const clip = clipAddress(id, e, CHICAGO);
  assert.equal(clip, `/api/v1/nvr/cameras/${id}/clip?from=${e.start - 3000}&to=${e.end + 3000}&tz=America%2FChicago&part=1`);
  assert.equal(clipAddress(id, { ...e, end: e.start }, CHICAGO).includes(`&to=${e.start + 3000}&`), true, 'a flash still has a clip of a few seconds');
});

test('the sky page’s address, and which cameras make the menu show', () => {
  const id = '0A1B2C3D-0000-4000-8000-000000000004';
  assert.ok(SKY_ROUTE.test('sky'));
  assert.ok(SKY_ROUTE.test(`sky/${id}`));
  assert.ok(SKY_ROUTE.test(`sky/${id}?night=2026-10-24&view=day&entry=abc`));
  assert.ok(SKY_ROUTE.test('sky?night=2026-10-24'));
  assert.equal(SKY_ROUTE.exec(`sky/${id}?night=2026-10-24`).slice(1).join('|'), `${id}|night=2026-10-24`);
  assert.ok(!SKY_ROUTE.test('skyline'));
  assert.ok(!SKY_ROUTE.test('sky/not-an-id'));
  assert.ok(!SKY_ROUTE.test(`camera/${id}`));

  assert.deepEqual(skyWatching([]), []);
  assert.deepEqual(skyWatching(null), []);
  assert.deepEqual(skyWatching([{ id: 'a' }, { id: 'b', skyDetector: null }, { id: 'c', skyDetector: { enabled: false } }, { id: 'd', skyDetector: { enabled: 'yes' } }]), []);
  assert.deepEqual(skyWatching([{ id: 'a' }, { id: 'b', skyDetector: { enabled: true } }, { id: 'c', skyDetector: { enabled: false } }, { id: 'd', skyDetector: { enabled: true } }]).map((c) => c.id), ['b', 'd']);
});

test('a wide picture defaults to two lenses; a saved choice wins', () => {
  const wide = { status: { mainStreamInfo: { width: 4256, height: 1888 } } };
  const normal = { status: { mainStreamInfo: { width: 1920, height: 1080 } } };
  assert.equal(defaultLensLayout(wide), 'dual');
  assert.equal(defaultLensLayout(normal), 'single');
  assert.equal(defaultLensLayout({ status: { mainStreamInfo: { width: 3840, height: 1920 } } }), 'dual', '2 to 1 is wide');
  assert.equal(defaultLensLayout({ status: { mainStreamInfo: { width: 3839, height: 1920 } } }), 'single');
  assert.equal(defaultLensLayout({}), 'single', 'size unknown');
  assert.equal(defaultLensLayout({ status: { mainStreamInfo: { width: 0, height: 0 } } }), 'single');
  assert.equal(defaultLensLayout({ ...wide, skyDetector: { lensLayout: 'single' } }), 'single');
  assert.equal(defaultLensLayout({ ...normal, skyDetector: { lensLayout: 'dual' } }), 'dual');
  assert.equal(defaultLensLayout({ ...wide, skyDetector: { lensLayout: 'triple' } }), 'dual', 'a choice the page does not know is ignored');
});

// MARK: The entry as the page reads it

test('an entry is read safely from what the box sends', () => {
  const raw = {
    id: 'e1', camera: '0A1B2C3D-0000-4000-8000-000000000004', kind: 'track', start: 1_000, end: 5_000, label: 'unexplained', display: 'plane', by: 'person', detail: 'TEST123 · 35,000 ft',
    path: [{ t: 0, x: 0.1, y: 0.2 }, { t: 1, x: 0.3, y: 0.25 }], measures: { azimuth: 312, elevation: 8, duration: 4, blinks: true, blinkRate: 1, shape: 'curved', speed: 3 },
    unusual: ['faster', 'larger'], speedVsPlanes: 6.1, candidate: false, alerted: true, hasStill: true, ai: { kind: 'bird', sentence: 'A bird.', model: 'm', at: 3000 }, correction: 'plane', watch: -2000,
  };
  const e = normalizeEntry(raw);
  assert.deepEqual([e.id, e.kind, e.start, e.end, e.display, e.label, e.correction, e.watch, e.hasStill], ['e1', 'track', 1000, 5000, 'plane', 'unexplained', 'plane', -2000, true]);
  assert.deepEqual(e.path, [{ t: 0, x: 0.1, y: 0.2 }, { t: 1, x: 0.3, y: 0.25 }]);
  assert.deepEqual(e.unusual, ['faster', 'larger']);
  assert.equal(e.speedVsPlanes, 6.1);
  assert.equal(e.ai.sentence, 'A bird.');

  const bare = normalizeEntry({ id: 'e2', start: 1000, end: 2000, label: 'plane' });
  assert.deepEqual([bare.display, bare.kind, bare.path, bare.unusual, bare.ai, bare.correction, bare.speedVsPlanes, bare.detail, bare.hasStill, bare.watch],
    ['plane', 'track', [], [], null, null, null, null, false, -2000], 'the display label is the entry’s own when the box says none; watch is start − 3 s');
  assert.equal(normalizeEntry({ id: 'e3', start: 'x', end: 5 }), null, 'an entry with no time is left out');
  assert.equal(normalizeEntry(null), null);
  assert.equal(normalizeEntry({ start: 1, end: 2 }), null, 'and one with no id');
  assert.equal(normalizeEntry({ id: 'e4', start: 1000, end: 2000, ai: { sentence: '  ' } }).ai, null, 'an empty sentence is no sentence');
  assert.deepEqual(normalizeEntry({ id: 'e5', start: 1000, end: 2000, path: [[0, 0.5, 0.5], [2, 0.6, 0.7], 'junk', [1]] }).path, [{ t: 0, x: 0.5, y: 0.5 }, { t: 2, x: 0.6, y: 0.7 }], 'triples read as points; junk goes');
  assert.equal(normalizeEntry({ id: 'e6', start: 1000, end: 500 }).end, 1000, 'an end before the start is the start');
});

test('times are epoch milliseconds, and an ISO date’s text is read as one rather than losing the entry', () => {
  assert.equal(toMs(1760099000000), 1760099000000);
  assert.equal(toMs('2026-10-25T03:12:08.000Z'), Date.UTC(2026, 9, 25, 3, 12, 8));
  for (const nothing of [null, undefined, NaN, Infinity, '', '  ', 'later', {}, [], true]) assert.equal(toMs(nothing), null, String(nothing));
  const e = normalizeEntry({ id: 'iso', start: '2026-10-25T03:12:08.000Z', end: '2026-10-25T03:12:12.000Z', label: 'plane', ai: { sentence: 'A plane.', at: '2026-10-25T03:13:00Z' }, watch: '2026-10-25T03:12:05Z' });
  assert.deepEqual([e.start, e.end, e.watch, e.ai.at], [Date.UTC(2026, 9, 25, 3, 12, 8), Date.UTC(2026, 9, 25, 3, 12, 12), Date.UTC(2026, 9, 25, 3, 12, 5), Date.UTC(2026, 9, 25, 3, 13)]);
  assert.equal(conditionsText([{ from: '2026-10-25T03:00:00Z', to: '2026-10-25T05:00:00Z', state: 'clear' }], 'UTC'), '☁︎ clear all night');
});

// MARK: The copy

/** Every string in `value`, with the path that leads to it. */
function strings(value, path = 'SKY_TEXT') {
  if (typeof value === 'string') return [[path, value]];
  if (value && typeof value === 'object') return Object.entries(value).flatMap(([key, inner]) => strings(inner, `${path}.${key}`));
  return [];
}

test('the name is Sky Watcher everywhere, and no sentence claims a real size, distance or speed', () => {
  const found = strings(SKY_TEXT);
  assert.ok(found.length > 40, 'every sentence of the card and the log is there');
  const forbidden = /km\/h|mph|metres|meters|feet|miles|\bkm\b|\bm\/s\b|knots|kilomet|\bcm\b|\binches\b/i;
  for (const [path, text] of found) {
    assert.doesNotMatch(text, forbidden, `${path} claims a real size, distance or speed`);
    assert.doesNotMatch(text, /'/, `${path} has a straight apostrophe: the page writes ’`);
    assert.doesNotMatch(text, /Sky detector/i, `${path} uses the old name`);
  }
  assert.equal(SKY_TEXT.card.title, 'Sky Watcher');
  assert.equal(SKY_TEXT.menu, 'Sky Watcher');
  assert.equal(SKY_TEXT.page, 'Sky Watcher');
  assert.equal(SKY_TEXT.card.switchTitle, 'Watch the sky');
  assert.equal(SKY_TEXT.card.switchDesc, 'For a camera that looks at the sky. Camera Bridge logs everything that crosses it — planes, satellites, meteors, bugs and birds — and tells you only about what it can’t explain. One camera can’t tell how far away something is, so it compares how things move across the sky; it never guesses a real size or speed.');
  assert.equal(SKY_TEXT.card.leaves, 'It works without the internet. When the internet is there, Camera Bridge can also download satellite orbits once a day and ask free online services for flights and weather in a wide area around you, never your exact spot. Still pictures of what it can’t explain go to your AI service if you set one up. Nothing leaves the box while it’s off.');
  assert.deepEqual([SKY_TEXT.card.locationTitle, SKY_TEXT.card.locationKept, SKY_TEXT.card.useBrowser, SKY_TEXT.card.latitude, SKY_TEXT.card.longitude],
    ['Where the box is', 'Kept only on this box.', 'Use this browser’s location', 'Latitude', 'Longitude']);
  assert.deepEqual([SKY_TEXT.card.facingTitle, SKY_TEXT.card.tiltTitle, SKY_TEXT.card.groundTitle], ['Which way the camera faces', 'Tilt above the horizon', 'Ground and horizon at the bottom']);
  assert.deepEqual([SKY_TEXT.card.aimMore, SKY_TEXT.card.looseFlights, SKY_TEXT.card.openLog], ['It gets more exact by itself over a few nights.', 'Flight matching is loose until the aim is good.', 'Open the sky log']);
  assert.deepEqual([SKY_TEXT.card.needLocation, SKY_TEXT.card.needFolder], ['Set where the box is first.', 'Choose a recordings folder first: the sky log is kept with the recordings.']);
  assert.deepEqual([SKY_TEXT.log.night, SKY_TEXT.log.day, SKY_TEXT.log.thatWasA], ['Night', 'Day', 'That was a…']);
});

test('the words of the plugin: the page that is off, the empty page, the Setup panel and the way to Plugins', () => {
  assert.deepEqual([SKY_TEXT.log.off, SKY_TEXT.log.offHelp, SKY_TEXT.log.toPlugins],
    ['Sky Watcher is off', 'Switch it on in Plugins, then turn it on for a camera that looks at the sky.', 'Go to Plugins']);
  assert.deepEqual([SKY_TEXT.log.noCameraOn, SKY_TEXT.log.pickCamera, SKY_TEXT.log.noCameras, SKY_TEXT.log.addCamera],
    ['Turn on Sky Watcher in a camera’s settings', 'Open the camera that looks at the sky and switch on “Watch the sky”.', 'Add the camera that looks at the sky first.', 'Add a camera']);
  assert.equal(SKY_TEXT.card.pluginLink, 'Open Plugins');
  assert.equal(SKY_TEXT.settings.title, 'Setup');
  assert.deepEqual([SKY_TEXT.settings.aiTitle, SKY_TEXT.settings.aiLabel, SKY_TEXT.settings.aiRange],
    ['Asking the AI', 'Most questions a day', 'Use a whole number from 1 to 1,000.']);
});
