import test from 'node:test';
import assert from 'node:assert/strict';
import {
  MIN_WINDOW_MS, PRESETS, RIGHT_MARGIN, clampViewport, classifyWheel, floorMs, maxDurationMs, panViewport, presetViewport,
  sameViewport, timeForX, wheelPanMs, wheelZoomFactor, xForTime, zoomViewport,
} from '../web/js/nvr/timeline/viewport.js';

const HOUR = 3_600_000;
const DAY = 86_400_000;
const NOW = Date.UTC(2026, 9, 14, 20, 0, 0);   // Wed 14 Oct 2026 20:00 UTC
const limits = { oldestMs: NOW - 3 * DAY, nowMs: NOW };

test('from live a preset shows [now - N, now + 4% of N]', () => {
  const v = presetViewport('1h', { nowMs: NOW, oldestMs: NOW - 3 * DAY, isLive: true });
  assert.equal(v.startMs, NOW - HOUR);
  assert.equal(v.durationMs, HOUR * (1 + RIGHT_MARGIN));
  assert.equal(v.startMs + v.durationMs, NOW + 0.04 * HOUR);
});

test('from the past a preset is centred on the playhead', () => {
  const playheadMs = NOW - 5 * HOUR;
  const v = presetViewport('1h', { nowMs: NOW, oldestMs: NOW - 3 * DAY, playheadMs, isLive: false });
  assert.equal(v.durationMs, HOUR);
  assert.equal(v.startMs + v.durationMs / 2, playheadMs);
});

test('a centred preset slides inside the limits instead of shrinking', () => {
  const nearOldest = presetViewport('6h', { nowMs: NOW, oldestMs: NOW - 3 * DAY, playheadMs: NOW - 3 * DAY + 1000, isLive: false });
  assert.equal(nearOldest.startMs, NOW - 3 * DAY);
  assert.equal(nearOldest.durationMs, 6 * HOUR);
  const nearNow = presetViewport('6h', { nowMs: NOW, oldestMs: NOW - 3 * DAY, playheadMs: NOW - 1000, isLive: false });
  assert.ok(nearNow.startMs + nearNow.durationMs <= NOW + 0.04 * nearNow.durationMs + 1e-6);
  assert.equal(nearNow.durationMs, 6 * HOUR);
});

test('All is the oldest recording to now, and at least ten minutes', () => {
  const all = presetViewport('all', { nowMs: NOW, oldestMs: NOW - 3 * DAY });
  assert.equal(all.startMs, NOW - 3 * DAY);
  assert.equal(all.startMs + all.durationMs, NOW + 0.04 * 3 * DAY);
  const young = presetViewport('all', { nowMs: NOW, oldestMs: NOW - 2 * 60_000 });
  assert.equal(young.startMs, NOW - 600_000);
  const empty = presetViewport('all', { nowMs: NOW, oldestMs: null });
  assert.equal(empty.startMs, NOW - 600_000);
});

test('24 h is a real 24 hours even when only a little is recorded', () => {
  const v = presetViewport('24h', { nowMs: NOW, oldestMs: NOW - 30 * 60_000 });
  assert.equal(v.startMs, NOW - DAY);
  assert.equal(v.durationMs, DAY * 1.04);
});

test('every preset stays inside the limits', () => {
  for (const preset of PRESETS) {
    for (const isLive of [true, false]) {
      const v = presetViewport(preset, { nowMs: NOW, oldestMs: NOW - 3 * DAY, playheadMs: NOW - 2 * DAY, isLive });
      assert.ok(v.durationMs >= MIN_WINDOW_MS, preset);
      assert.ok(v.startMs >= floorMs(limits) - 1e-6, preset);
      assert.ok(v.startMs + v.durationMs <= NOW + 0.04 * v.durationMs + 1e-6, preset);
    }
  }
  assert.throws(() => presetViewport('7d', { nowMs: NOW }), RangeError);
});

test('zoom keeps the time under the pointer where it was', () => {
  const v = presetViewport('6h', { nowMs: NOW, oldestMs: NOW - 3 * DAY, isLive: true });
  const anchorMs = v.startMs + v.durationMs * 0.25;
  const zoomed = zoomViewport(v, 0.5, anchorMs, limits);
  assert.equal(zoomed.durationMs, v.durationMs / 2);
  const before = xForTime(v, anchorMs, 800);
  const after = xForTime(zoomed, anchorMs, 800);
  assert.ok(Math.abs(before - after) < 1e-6, `${before} vs ${after}`);
});

test('zoom stops at 60 s and at the whole archive', () => {
  const v = presetViewport('10m', { nowMs: NOW, oldestMs: NOW - 3 * DAY, isLive: true });
  let z = v;
  for (let i = 0; i < 20; i += 1) z = zoomViewport(z, 0.5, z.startMs + z.durationMs / 2, limits);
  assert.equal(z.durationMs, MIN_WINDOW_MS);
  for (let i = 0; i < 20; i += 1) z = zoomViewport(z, 2, z.startMs + z.durationMs / 2, limits);
  assert.equal(z.durationMs, maxDurationMs(limits));
  assert.equal(z.startMs, floorMs(limits));
});

test('pan moves the window and stops at the oldest recording and at now', () => {
  const v = presetViewport('1h', { nowMs: NOW, oldestMs: NOW - 3 * DAY, isLive: true });
  const left = panViewport(v, -HOUR, limits);
  assert.equal(left.startMs, v.startMs - HOUR);
  assert.equal(left.durationMs, v.durationMs);
  assert.equal(panViewport(v, -10 * DAY, limits).startMs, NOW - 3 * DAY);
  const right = panViewport(v, 10 * DAY, limits);
  assert.ok(Math.abs(right.startMs + right.durationMs - (NOW + 0.04 * v.durationMs)) < 1e-6);
});

test('clamp never lets the window start after now minus its own length', () => {
  const c = clampViewport({ startMs: NOW + HOUR, durationMs: 10 * 60_000 }, limits);
  assert.ok(c.startMs + c.durationMs <= NOW + 0.04 * c.durationMs + 1e-6);
});

test('x and time are inverses', () => {
  const v = { startMs: 1_000_000, durationMs: 600_000 };
  for (const x of [0, 1, 123.5, 799, 800]) assert.ok(Math.abs(xForTime(v, timeForX(v, x, 800), 800) - x) < 1e-9);
  assert.equal(timeForX(v, 400, 800), 1_300_000);
  assert.ok(sameViewport(v, { ...v }));
  assert.ok(!sameViewport(v, null));
});

test('wheel: ctrl or cmd zooms, shift or a horizontal wheel pans, a plain vertical wheel scrolls the page', () => {
  assert.equal(classifyWheel({ ctrlKey: true, deltaY: -3 }), 'zoom');
  assert.equal(classifyWheel({ metaKey: true, deltaY: 40 }), 'zoom');
  assert.equal(classifyWheel({ shiftKey: true, deltaY: 40 }), 'pan');
  assert.equal(classifyWheel({ deltaX: 30, deltaY: 4 }), 'pan');
  assert.equal(classifyWheel({ deltaY: 40 }), 'none');
  assert.ok(wheelZoomFactor(-100) < 1 && wheelZoomFactor(100) > 1);
  assert.ok(Math.abs(wheelZoomFactor(100) * wheelZoomFactor(-100) - 1) < 1e-12);
  assert.ok(wheelZoomFactor(1e6) <= Math.exp(0.6) + 1e-9);   // one event never zooms by more than about 1.8x
  const v = { startMs: 0, durationMs: 800_000 };
  assert.equal(wheelPanMs(v, 800, { deltaX: 40 }), 40_000);
  assert.equal(wheelPanMs(v, 800, { deltaY: 40, shiftKey: true }), 40_000);
});
