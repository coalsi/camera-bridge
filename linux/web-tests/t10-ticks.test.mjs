import test from 'node:test';
import assert from 'node:assert/strict';
import { TICK_STEPS_MS, makeTicks, startOfLocalDay, zonedParts } from '../web/js/nvr/timeline/ticks.js';

const LA = 'America/Los_Angeles';
const HOUR = 3_600_000;
const DAY = 24 * HOUR;
const options = (timeZone, extra = {}) => ({ timeZone, locale: 'en-US', ...extra });

test('the step is the smallest one in the table that keeps ticks 80 px apart', () => {
  const ten = makeTicks({ startMs: Date.UTC(2026, 9, 14, 12, 0, 0), durationMs: 10 * 60_000 }, 800, options('UTC'));
  assert.equal(ten[1].ms - ten[0].ms, 60_000);              // 10 min over 800 px: 60 s is 80 px
  const hour = makeTicks({ startMs: Date.UTC(2026, 9, 14, 12, 0, 0), durationMs: HOUR }, 800, options('UTC'));
  assert.equal(hour[1].ms - hour[0].ms, 10 * 60_000);       // 1 h over 800 px: 5 min is 67 px (too close), 10 min is 133 px
  assert.ok(TICK_STEPS_MS.includes(hour[1].ms - hour[0].ms));
  for (const t of hour) assert.ok(t.ms % 60_000 === 0);
});

test('ticks are never closer than the minimum spacing and stay inside the window', () => {
  for (const durationMs of [90_000, 10 * 60_000, HOUR, 6 * HOUR, DAY, 3 * DAY, 14 * DAY, 120 * DAY, 400 * DAY]) {
    for (const widthPx of [320, 800, 1600]) {
      const viewport = { startMs: Date.UTC(2026, 9, 3, 7, 13, 41), durationMs };
      const ticks = makeTicks(viewport, widthPx, options(LA));
      assert.ok(ticks.length >= 1, `${durationMs}/${widthPx}`);
      for (let i = 0; i < ticks.length; i += 1) {
        assert.ok(ticks[i].ms >= viewport.startMs && ticks[i].ms <= viewport.startMs + durationMs);
        if (i > 0) assert.ok(((ticks[i].ms - ticks[i - 1].ms) / durationMs) * widthPx >= 80 - 1e-9, `${durationMs}/${widthPx}`);
      }
    }
  }
});

test('a window of many months uses every n-th Monday, still 80 px apart', () => {
  for (const [durationMs, widthPx] of [[365 * DAY, 320], [400 * DAY, 1015], [90 * DAY, 800]]) {
    const viewport = { startMs: Date.UTC(2026, 0, 1), durationMs };
    const ticks = makeTicks(viewport, widthPx, options(LA));
    assert.ok(ticks.length >= 3, `${durationMs}/${widthPx}`);
    for (let i = 0; i < ticks.length; i += 1) {
      assert.equal(new Date(ticks[i].ms + zonedParts(ticks[i].ms, LA).offsetMs).getUTCDay(), 1);
      if (i > 0) assert.ok(((ticks[i].ms - ticks[i - 1].ms) / durationMs) * widthPx >= 80 - 1e-9, `${durationMs}/${widthPx}`);
    }
  }
});

test('seconds and minutes label as clock time, hours at midnight label as a date', () => {
  const seconds = makeTicks({ startMs: Date.UTC(2026, 9, 14, 12, 0, 0), durationMs: 20_000 }, 800, options('UTC'));
  assert.deepEqual(seconds.slice(0, 2).map((t) => t.label), ['12:00:00', '12:00:02']);
  assert.equal(seconds[0].major, true);                      // a whole minute
  assert.equal(seconds[1].major, false);
  const day = makeTicks({ startMs: Date.UTC(2026, 9, 14, 0, 0, 0), durationMs: DAY }, 800, options('UTC'));
  assert.equal(day[0].label, 'Wed, Oct 14');                 // midnight is the major tick of an hour step
  assert.equal(day[0].major, true);
  assert.equal(day[1].label, '03:00');
  assert.equal(day[1].major, false);
});

test('2026-03-08 (clocks go forward at 02:00 in Los Angeles): 6 h ticks are at local 00, 06, 12, 18', () => {
  const viewport = { startMs: Date.UTC(2026, 2, 8, 8, 0, 0), durationMs: 23 * HOUR };   // local midnight to the next local midnight
  const ticks = makeTicks(viewport, 400, options(LA));
  assert.deepEqual(ticks.map((t) => t.ms), [
    Date.UTC(2026, 2, 8, 8, 0, 0),    // 00:00 PST
    Date.UTC(2026, 2, 8, 13, 0, 0),   // 06:00 PDT, five hours later
    Date.UTC(2026, 2, 8, 19, 0, 0),   // 12:00 PDT
    Date.UTC(2026, 2, 9, 1, 0, 0),    // 18:00 PDT
    Date.UTC(2026, 2, 9, 7, 0, 0),    // 00:00 PDT, the right edge of the window
  ]);
  assert.deepEqual(ticks.map((t) => zonedParts(t.ms, LA).hour), [0, 6, 12, 18, 0]);
  assert.equal(ticks[0].major, true);
});

test('2026-03-08: 2 h ticks skip the hour that does not exist', () => {
  const viewport = { startMs: Date.UTC(2026, 2, 8, 8, 0, 0), durationMs: 23 * HOUR };
  const ticks = makeTicks(viewport, 1000, options(LA));
  assert.deepEqual(ticks.map((t) => zonedParts(t.ms, LA).hour), [0, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 0]);
});

test('2026-11-01 (clocks go back at 02:00): 1 h ticks show the repeated hour twice and cover 25 hours', () => {
  const viewport = { startMs: Date.UTC(2026, 10, 1, 7, 0, 0), durationMs: 25 * HOUR };   // local midnight to the next local midnight
  const ticks = makeTicks(viewport, 2000, options(LA));
  assert.equal(ticks.length, 26);                            // 25 hours plus the right edge, which is the next local midnight
  const labels = ticks.map((t) => t.label);
  assert.equal(labels.filter((l) => l === '01:00').length, 2);
  assert.ok(ticks.every((t, i) => i === 0 || t.ms - ticks[i - 1].ms === HOUR));
  assert.equal(ticks[0].label, 'Sun, Nov 1');
});

test('2026-11-01: 6 h ticks are at local 00, 06, 12, 18 and the gaps are 7, 6 and 6 hours', () => {
  const viewport = { startMs: Date.UTC(2026, 10, 1, 7, 0, 0), durationMs: 25 * HOUR };
  const ticks = makeTicks(viewport, 400, options(LA));
  assert.deepEqual(ticks.map((t) => zonedParts(t.ms, LA).hour), [0, 6, 12, 18, 0]);
  assert.deepEqual(ticks.slice(1).map((t, i) => (t.ms - ticks[i].ms) / HOUR), [7, 6, 6, 6]);
});

test('day ticks are at local midnight: 24, 23 and 24 hours apart across 2026-03-08', () => {
  const viewport = { startMs: Date.UTC(2026, 2, 7, 8, 0, 0), durationMs: 3 * DAY };
  const ticks = makeTicks(viewport, 300, options(LA));
  assert.deepEqual(ticks.slice(0, 4).map((t) => t.ms), [
    Date.UTC(2026, 2, 7, 8, 0, 0), Date.UTC(2026, 2, 8, 8, 0, 0), Date.UTC(2026, 2, 9, 7, 0, 0), Date.UTC(2026, 2, 10, 7, 0, 0),
  ]);
  assert.deepEqual(ticks.map((t) => zonedParts(t.ms, LA).hour), ticks.map(() => 0));
});

test('week ticks are Mondays', () => {
  const viewport = { startMs: Date.UTC(2026, 8, 1), durationMs: 30 * DAY };
  const ticks = makeTicks(viewport, 400, options(LA));              // 6 days wanted: the 7 day step
  assert.ok(ticks.length >= 4);
  for (const t of ticks) assert.equal(new Date(t.ms + zonedParts(t.ms, LA).offsetMs).getUTCDay(), 1);
});

test('a zone with a 45 minute offset still gets ticks on its own :00 and :10', () => {
  const zone = 'Asia/Kathmandu';
  const ticks = makeTicks({ startMs: Date.UTC(2026, 9, 14, 6, 0, 0), durationMs: 80 * 60_000 }, 800, options(zone));
  assert.equal(ticks[1].ms - ticks[0].ms, 10 * 60_000);
  for (const t of ticks) assert.equal(zonedParts(t.ms, zone).minute % 10, 0);
  const india = makeTicks({ startMs: Date.UTC(2026, 9, 14, 6, 0, 0), durationMs: 3 * HOUR }, 800, options('Asia/Kolkata'));
  for (const t of india) assert.equal(zonedParts(t.ms, 'Asia/Kolkata').minute % 15, 0);
});

test('startOfLocalDay and zonedParts agree', () => {
  assert.equal(startOfLocalDay(2026, 3, 8, LA), Date.UTC(2026, 2, 8, 8, 0, 0));
  assert.equal(startOfLocalDay(2026, 3, 9, LA), Date.UTC(2026, 2, 9, 7, 0, 0));
  assert.equal(startOfLocalDay(2026, 11, 1, LA), Date.UTC(2026, 10, 1, 7, 0, 0));
  assert.equal(startOfLocalDay(2026, 11, 2, LA), Date.UTC(2026, 10, 2, 8, 0, 0));
  assert.equal(zonedParts(Date.UTC(2026, 10, 1, 9, 30, 0), LA).hour, 1);   // the second 01:30
  assert.equal(zonedParts(Date.UTC(2026, 10, 1, 8, 30, 0), LA).hour, 1);   // the first 01:30
  assert.equal(zonedParts(Date.UTC(2026, 10, 1, 8, 30, 0), LA).offsetMs, -7 * HOUR);
  assert.equal(zonedParts(Date.UTC(2026, 10, 1, 9, 30, 0), LA).offsetMs, -8 * HOUR);
});

test('empty or degenerate input gives no ticks', () => {
  assert.deepEqual(makeTicks({ startMs: 0, durationMs: 0 }, 800, options('UTC')), []);
  assert.deepEqual(makeTicks({ startMs: 0, durationMs: 1000 }, 0, options('UTC')), []);
});
