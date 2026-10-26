import test from 'node:test';
import assert from 'node:assert/strict';
import {
  BIN_LADDER_SEC, MAX_REQUEST_BINS, MAX_REQUEST_SPAN_MS, alignFrom, barHeight, chooseBin, combineActivity, isElevated, planActivityRequest,
  planCovers, visibleLevels, waveformReference,
} from '../web/js/nvr/timeline/activity.js';

const MIN = 60_000;
const HOUR = 3_600_000;
const DAY = 86_400_000;
const NOW = Date.UTC(2026, 9, 14, 20, 0, 0);

test('the bin is the smallest rung that keeps columns 2 px wide', () => {
  assert.equal(chooseBin(10 * MIN, 800), 2000);          // 600 s / 400 columns = 1.5 s, so the 2 s rung
  assert.equal(chooseBin(HOUR, 800), 10_000);            // 9 s wanted
  assert.equal(chooseBin(DAY, 800), 300_000);            // 216 s wanted
  assert.equal(chooseBin(7 * DAY, 800), 1_800_000);      // 1512 s wanted
  assert.equal(chooseBin(60 * DAY, 800), 3_600_000);     // beyond the ladder: the top rung
  assert.equal(chooseBin(HOUR, 0), 3_600_000);           // a zero width is treated as 1 px: the top rung
  for (const sec of BIN_LADDER_SEC) assert.equal(MAX_REQUEST_SPAN_MS % (sec * 1000), 0);
});

test('from is a multiple of the bin, also before 1970', () => {
  assert.equal(alignFrom(1_000_123, 10_000), 1_000_000);
  assert.equal(alignFrom(-5, 10_000), -10_000);
  assert.equal(alignFrom(20_000, 10_000), 20_000);
});

test('the request holds the viewport plus a quarter window each side, in whole bins, and never the future', () => {
  const viewport = { startMs: NOW - HOUR, durationMs: HOUR * 1.04 };
  const plan = planActivityRequest(viewport, 800, NOW);
  assert.equal(plan.binMs, 10_000);
  assert.equal(plan.fromMs % plan.binMs, 0);
  assert.ok(plan.fromMs <= viewport.startMs - viewport.durationMs / 4 + 1e-6);
  const toMs = plan.fromMs + plan.bins * plan.binMs;
  assert.ok(toMs >= NOW && toMs <= NOW + 2 * plan.binMs, `ends ${toMs - NOW} ms after now`);
  assert.ok(planCovers(plan, viewport, NOW));
  assert.ok(plan.bins >= 1 && plan.bins <= MAX_REQUEST_BINS);
});

test('a small pan needs no new request, a big pan or a zoom does', () => {
  const viewport = { startMs: NOW - 6 * HOUR, durationMs: 2 * HOUR };
  const plan = planActivityRequest(viewport, 800, NOW);
  assert.ok(planCovers(plan, { ...viewport, startMs: viewport.startMs + 20 * MIN }, NOW));
  assert.ok(!planCovers(plan, { ...viewport, startMs: viewport.startMs - HOUR }, NOW));
  assert.notEqual(planActivityRequest({ startMs: viewport.startMs, durationMs: 4 * HOUR }, 800, NOW).binMs, plan.binMs);
});

test('every request obeys the server limits, for every window and width', () => {
  for (const durationMs of [MIN, 10 * MIN, HOUR, DAY, 3 * DAY, 20 * DAY, 31 * DAY, 90 * DAY, 400 * DAY]) {
    for (const widthPx of [200, 800, 2600, 5000]) {
      const plan = planActivityRequest({ startMs: NOW - durationMs, durationMs: durationMs * 1.04 }, widthPx, NOW);
      assert.ok(plan.bins >= 1 && plan.bins <= MAX_REQUEST_BINS, `${durationMs}/${widthPx}: ${plan.bins} bins`);
      assert.ok(plan.bins * plan.binMs <= MAX_REQUEST_SPAN_MS, `${durationMs}/${widthPx}: span`);
      assert.ok(plan.binMs >= 1000 && plan.binMs <= 86_400_000);
      assert.equal(plan.fromMs % plan.binMs, 0);
    }
  }
});

test('a window wider than 31 days asks for the newest 31 days', () => {
  const plan = planActivityRequest({ startMs: NOW - 90 * DAY, durationMs: 90 * DAY * 1.04 }, 800, NOW);
  assert.equal(plan.bins * plan.binMs, MAX_REQUEST_SPAN_MS);
  assert.ok(plan.fromMs + plan.bins * plan.binMs >= NOW);
});

test('one camera keeps its own bytes per second and its own typical level', () => {
  const answer = { A: { typical: 2000, complete: true, coverage: [100, 100, 0, 50], level: [1000, 6000, 0, 3000] } };
  const combined = combineActivity(answer, 4);
  assert.deepEqual(combined.level, [1000, 6000, 0, 3000]);
  assert.deepEqual(combined.coverage, [100, 100, 0, 50]);
  assert.equal(combined.typical, 2000);
  assert.equal(combineActivity({ A: { typical: null, coverage: [100], level: [10] } }, 1).typical, null);
});

test('several cameras: the busiest relative to its own typical level, coverage is the best of them', () => {
  const answer = {
    A: { typical: 1000, coverage: [100, 100, 0], level: [1000, 4000, 0] },
    B: { typical: 10_000, coverage: [100, 0, 0], level: [30_000, 0, 0] },
  };
  const combined = combineActivity(answer, 3);
  assert.deepEqual(combined.level, [3, 4, 0]);          // bin 0: B is 3 x typical, A 1 x; bin 1: only A, 4 x
  assert.deepEqual(combined.coverage, [100, 100, 0]);
  assert.equal(combined.typical, 1);
});

test('a camera without a typical level is measured against its own 99th percentile', () => {
  const answer = {
    A: { typical: 1000, coverage: [100, 100], level: [2000, 2000] },
    B: { typical: null, coverage: [100, 100], level: [50_000, 100_000] },
  };
  const combined = combineActivity(answer, 2);
  assert.deepEqual(combined.level, [2, 2]);             // B: 50 000 / 100 000 = 0.5 and 1, A: 2, so 2 wins
  assert.equal(combined.typical, null);
});

test('malformed or missing answers become an empty waveform, not an exception', () => {
  assert.deepEqual(combineActivity(undefined, 3), { level: [0, 0, 0], coverage: [0, 0, 0], typical: null, away: [0, 0, 0] });
  assert.deepEqual(combineActivity({ A: null, B: { coverage: 'x' } }, 2).coverage, [0, 0]);
  assert.deepEqual(combineActivity({ A: { typical: 5, coverage: [100], level: [1] } }, 3).level, [1, 0, 0]);   // short arrays count as zero
});

test('the scale: 4 x typical, else the 99th percentile of what is visible, never under 1 KB/s', () => {
  assert.equal(waveformReference(500, [1, 2, 3]), 2000);
  const levels = Array.from({ length: 200 }, (_, i) => 1000 + i * 100);   // 1000 ... 20 900
  assert.equal(waveformReference(null, levels), 20_700);                  // sorted[ceil(0.99 x 200) - 1] = sorted[197]
  assert.equal(waveformReference(null, [5, 6, 7]), 1000);                  // floor
  assert.equal(waveformReference(null, []), 1000);
  assert.equal(waveformReference(0, [5000]), 5000);                        // a zero typical level is no typical level
});

test('bar height is the square root, so normal activity sits at half the height', () => {
  const typical = 3000;
  const reference = waveformReference(typical, []);
  assert.equal(barHeight(typical, reference), 0.5);
  assert.equal(barHeight(reference, reference), 1);
  assert.equal(barHeight(reference * 10, reference), 1);
  assert.equal(barHeight(0, reference), 0);
  assert.equal(barHeight(100, 0), 0);
  assert.ok(barHeight(1.5 * typical + 1, reference) > 0.5);                // highlighted bars are also taller than the normal line
});

test('highlighted means above 1.5 x typical, and only when a typical level exists', () => {
  assert.equal(isElevated(1501, 1000), true);
  assert.equal(isElevated(1500, 1000), false);
  assert.equal(isElevated(1e9, null), false);
});

test('visible levels are the covered bins that touch the viewport', () => {
  const plan = { fromMs: 0, binMs: 1000, bins: 5 };
  const combined = { level: [9, 1, 2, 0, 7], coverage: [100, 100, 100, 0, 100] };
  assert.deepEqual(visibleLevels(combined, plan, { startMs: 1000, durationMs: 3000 }), [1, 2]);   // bins 1..3; bin 3 has no footage
  assert.deepEqual(visibleLevels(combined, plan, { startMs: 500, durationMs: 1000 }), [9, 1]);     // bins 0 and 1 touch [500, 1500)
});

test('what is on an archive drive that is not connected is combined apart from the coverage: the most of any camera per bin', () => {
  const answer = {
    A: { typical: 1000, coverage: [0, 0, 100], level: [0, 0, 1000], away: [100, 40, 0] },
    B: { typical: 1000, coverage: [0, 50, 100], level: [0, 900, 1000], away: [20, 0, 0] },
    C: { typical: 1000, coverage: [100, 0, 0], level: [1000, 0, 0] },                       // a bridge without an archive sends none
  };
  const combined = combineActivity(answer, 3);
  assert.deepEqual(combined.away, [100, 40, 0]);
  assert.deepEqual(combined.coverage, [100, 50, 100], 'coverage is what plays now, as before');
});
