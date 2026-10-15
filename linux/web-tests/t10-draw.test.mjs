import test from 'node:test';
import assert from 'node:assert/strict';
import { RULER_HEIGHT, layoutBars, paintTimeline } from '../web/js/nvr/timeline/draw.js';
import { waveformReference } from '../web/js/nvr/timeline/activity.js';
import { makeTicks } from '../web/js/nvr/timeline/ticks.js';

const MIN = 60_000;
const NOW = Date.UTC(2026, 9, 14, 20, 0, 0);

/** A context that writes down what it was asked to do. */
function fakeContext() {
  const ops = [];
  const ctx = {
    ops,
    fillStyle: '', strokeStyle: '', lineWidth: 1, globalAlpha: 1, font: '', textBaseline: '',
  };
  for (const name of ['setTransform', 'clearRect', 'beginPath', 'moveTo', 'lineTo', 'stroke', 'rect', 'clip', 'save', 'restore', 'setLineDash']) {
    ctx[name] = (...args) => ops.push([name, ...args]);
  }
  ctx.fillRect = (...args) => ops.push(['fillRect', ctx.fillStyle, ctx.globalAlpha, ...args]);
  ctx.fillText = (...args) => ops.push(['fillText', ...args]);
  return ctx;
}

// 10 bins of one minute ending at NOW; bin 3 and 4 have no footage; bin 7 is busy.
const viewport = { startMs: NOW - 10 * MIN, durationMs: 10 * MIN };
const plan = { fromMs: NOW - 10 * MIN, binMs: MIN, bins: 10 };
const typical = 2000;
const combined = {
  level: [2000, 2000, 2000, 0, 0, 2000, 2000, 6000, 2000, 2000],
  coverage: [100, 100, 100, 0, 0, 100, 100, 100, 100, 50],
  typical,
};
const reference = waveformReference(typical, []);
const geometry = { viewport, widthPx: 1000, plan, combined, reference, typical, oldestMs: NOW - 20 * MIN, newestMs: NOW };

test('bars: normal activity is half height, elevated ones are amber and taller, gaps are runs', () => {
  const layout = layoutBars(geometry);
  assert.equal(layout.bars.length, 8);
  assert.equal(layout.bars[0].half, 0.5);
  assert.equal(layout.bars[0].hot, false);
  const busy = layout.bars.find((b) => b.hot);
  assert.ok(busy.half > 0.5 && busy.half < 1);
  assert.equal(busy.half, Math.sqrt(6000 / 8000));
  assert.equal(layout.normal, 0.5);
  assert.deepEqual(layout.gaps, [{ x0: 300, x1: 500 }]);                     // bins 3 and 4 merge into one run, 100 px each
  assert.equal(layout.bars.at(-1).alpha, 0.35 + 0.65 * 0.5);                 // half-covered bin is paler
});

test('bars are at least one pixel wide, with a hairline between wide ones', () => {
  const wide = layoutBars(geometry);
  assert.equal(wide.bars[0].w, 99);
  const narrow = layoutBars({ ...geometry, widthPx: 20 });                  // 2 px per bin
  assert.ok(narrow.bars.every((b) => b.w >= 1 && b.w <= 2));
});

test('no gap is drawn before the first or after the last recording', () => {
  const layout = layoutBars({ ...geometry, oldestMs: NOW - 5 * MIN });      // the empty bins 3 and 4 are before the oldest recording
  assert.deepEqual(layout.gaps, []);
  assert.equal(layoutBars({ ...geometry, oldestMs: null, newestMs: null }).gaps.length, 0);
});

test('bins outside the window are not laid out', () => {
  const layout = layoutBars({ ...geometry, viewport: { startMs: NOW - 5 * MIN, durationMs: 5 * MIN } });
  assert.equal(layout.bars.length, 5);
  assert.ok(layout.bars.every((b) => b.x >= -0.001));
});

test('a camera with no typical level has no dashed line and no amber bars', () => {
  const layout = layoutBars({ ...geometry, typical: null, reference: 6000 });
  assert.equal(layout.normal, null);
  assert.ok(layout.bars.every((b) => !b.hot));
});

test('no data, no bars', () => {
  assert.deepEqual(layoutBars({ ...geometry, combined: null }), { bars: [], gaps: [], normal: null });
  assert.deepEqual(layoutBars({ ...geometry, reference: 0 }), { bars: [], gaps: [], normal: null });
});

test('painting: the dashed normal line sits at half height above and below the centre, amber is used once', () => {
  const ctx = fakeContext();
  const colors = { track: '#t', span: '#s', tick: '#k', label: '#l', bar: '#bar', hot: '#hot', normal: '#n', gap: '#g' };
  const height = 122;
  const { widthPx, ...withoutWidthPx } = geometry;                          // the painter is given `width`, not `widthPx`
  assert.equal(widthPx, 1000);
  paintTimeline(ctx, {
    ...withoutWidthPx, width: 1000, height, dpr: 2, colors, ticks: makeTicks(viewport, 1000, { timeZone: 'UTC', locale: 'en-US' }), enabled: true,
  });
  assert.deepEqual(ctx.ops[0], ['setTransform', 2, 0, 0, 2, 0, 0]);
  const areaHeight = height - RULER_HEIGHT;
  const mid = RULER_HEIGHT + areaHeight / 2;
  const half = areaHeight / 2 - 2;
  const moves = ctx.ops.filter((o) => o[0] === 'moveTo' && o[1] === 0);
  assert.deepEqual(moves.map((o) => o[2]), [mid - 0.5 * half, mid + 0.5 * half]);
  assert.deepEqual(ctx.ops.filter((o) => o[0] === 'setLineDash').map((o) => o[1]), [[4, 4], []]);
  const bars = ctx.ops.filter((o) => o[0] === 'fillRect' && (o[1] === '#bar' || o[1] === '#hot'));
  assert.equal(bars.length, 8);
  assert.ok(bars.every((o) => o.slice(3).every(Number.isFinite)), 'every rectangle has real coordinates');
  assert.equal(bars[0][3], 0);                                               // the first bin starts at the left edge
  assert.equal(bars.filter((o) => o[1] === '#hot').length, 1);
  const hot = bars.find((o) => o[1] === '#hot');
  assert.equal(hot[6], 2 * Math.sqrt(0.75) * half);                          // mirrored: the rectangle is twice the half height
  assert.ok(ctx.ops.some((o) => o[0] === 'clip'), 'the gap is hatched inside a clip');
  assert.ok(ctx.ops.some((o) => o[0] === 'fillText'), 'the ruler has labels');
  assert.equal(ctx.globalAlpha, 1);
});

test('a disabled track is dimmed', () => {
  const ctx = fakeContext();
  const { widthPx, ...withoutWidthPx } = geometry;
  paintTimeline(ctx, { ...withoutWidthPx, width: widthPx, height: 100, dpr: 1, colors: { track: '#t', span: '#s', tick: '#k', label: '#l', bar: '#bar', hot: '#hot', normal: '#n', gap: '#g' }, ticks: [], enabled: false });
  assert.equal(ctx.ops.find((o) => o[0] === 'fillRect')[2], 0.45);
});
