// Painting the timeline track on a 2D canvas: ruler, hatched gaps, stretches on an archive drive that is not connected, the mirrored activity
// waveform and the dashed "normal" line.
// `layoutBars` is pure (numbers in, rectangles out); `paintTimeline` only calls the 2D context, so both run under Node with a fake context.
import { barHeight, isElevated } from './activity.js';
import { xForTime } from './viewport.js';

export const RULER_HEIGHT = 22;                  // CSS px
const HATCH_SPACING = 6;
/** What a stretch on the archive drive says while the drive is not connected (a shorter word when the stretch is narrow). */
export const AWAY_LABEL = 'On the archive drive (not connected)';
export const AWAY_SHORT_LABEL = 'Archive drive';

/**
 * -> { bars: [{ x, w, half, hot, alpha }], gaps: [{ x0, x1 }], aways: [{ x0, x1 }], normal: fraction | null }
 * `half` is the bar's half height as a fraction (0..1) of the half height of the waveform area. A gap is a run of bins without footage
 * between the oldest and the newest recording; before the first and after the last recording there is no gap, just empty track. An away run is
 * a run of bins whose footage is on the archive drive while it is not connected (`combined.away`): it plays again when the drive is back.
 */
export function layoutBars({ viewport, widthPx, plan, combined, reference, typical, oldestMs, newestMs }) {
  const out = { bars: [], gaps: [], aways: [], normal: null };
  if (!plan || !combined || !(reference > 0)) return out;
  let run = null;
  let awayRun = null;
  for (let i = 0; i < combined.level.length; i += 1) {
    const startMs = plan.fromMs + i * plan.binMs;
    const x0 = xForTime(viewport, startMs, widthPx);
    const x1 = xForTime(viewport, startMs + plan.binMs, widthPx);
    if (x1 < 0 || x0 > widthPx) { run = null; awayRun = null; continue; }
    const coverage = combined.coverage[i];
    const inside = oldestMs !== null && newestMs !== null && startMs + plan.binMs > oldestMs && startMs < newestMs;
    if (coverage === 0 && (combined.away?.[i] || 0) > 0) {
      run = null;
      if (awayRun && Math.abs(awayRun.x1 - x0) < 0.01) awayRun.x1 = x1; else { awayRun = { x0, x1 }; out.aways.push(awayRun); }
      continue;
    }
    awayRun = null;
    if (coverage === 0) {
      if (inside) {
        if (run && Math.abs(run.x1 - x0) < 0.01) run.x1 = x1; else { run = { x0, x1 }; out.gaps.push(run); }
      } else run = null;
      continue;
    }
    run = null;
    const level = combined.level[i];
    const half = level > 0 ? Math.max(barHeight(level, reference), 0.02) : 0;
    const w = Math.max(1, x1 - x0 - (x1 - x0 >= 3 ? 1 : 0));
    out.bars.push({ x: x0, w, half, hot: isElevated(level, typical), alpha: 0.35 + 0.65 * Math.min(coverage, 100) / 100 });
  }
  if (Number.isFinite(typical) && typical > 0) out.normal = barHeight(typical, reference);
  return out;
}

/**
 * frame: { width, height, dpr, colors: { track, span, tick, label, bar, hot, normal, gap }, viewport, ticks, oldestMs, newestMs,
 *          plan, combined, reference, typical, enabled }
 */
export function paintTimeline(ctx, frame) {
  const { width, height, dpr, colors, viewport, ticks } = frame;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, width, height);
  ctx.globalAlpha = frame.enabled ? 1 : 0.45;

  const top = RULER_HEIGHT;
  const areaHeight = height - RULER_HEIGHT;
  const mid = top + areaHeight / 2;
  const half = areaHeight / 2 - 2;

  ctx.fillStyle = colors.track;
  ctx.fillRect(0, top, width, areaHeight);
  if (frame.oldestMs !== null && frame.newestMs !== null) {
    const x0 = Math.max(0, xForTime(viewport, frame.oldestMs, width));
    const x1 = Math.min(width, xForTime(viewport, frame.newestMs, width));
    if (x1 > x0) { ctx.fillStyle = colors.span; ctx.fillRect(x0, top, x1 - x0, areaHeight); }
  }

  // Ruler
  ctx.strokeStyle = colors.tick;
  ctx.fillStyle = colors.label;
  ctx.lineWidth = 1;
  ctx.textBaseline = 'top';
  ctx.font = '11px system-ui, sans-serif';
  ctx.beginPath();
  for (const tick of ticks) {
    const x = Math.round(xForTime(viewport, tick.ms, width)) + 0.5;
    if (x < 0 || x > width) continue;
    ctx.moveTo(x, tick.major ? 2 : RULER_HEIGHT - 8);
    ctx.lineTo(x, RULER_HEIGHT);
  }
  ctx.stroke();
  for (const tick of ticks) {
    const x = Math.round(xForTime(viewport, tick.ms, width)) + 0.5;
    if (x < 0 || x > width - 40) continue;
    ctx.fillText(tick.label, x + 4, tick.major ? 3 : 7);
  }

  const layout = layoutBars({ ...frame, widthPx: width });

  // Gaps, hatched
  ctx.strokeStyle = colors.gap;
  for (const gap of layout.gaps) {
    ctx.save();
    ctx.beginPath();
    ctx.rect(gap.x0, top, gap.x1 - gap.x0, areaHeight);
    ctx.clip();
    ctx.beginPath();
    for (let x = gap.x0 - areaHeight; x < gap.x1; x += HATCH_SPACING) { ctx.moveTo(x, top + areaHeight); ctx.lineTo(x + areaHeight, top); }
    ctx.stroke();
    ctx.restore();
  }

  // On the archive drive, not connected: a quiet band with its words where they fit (never a bar: nothing there plays now)
  for (const away of layout.aways) {
    const x0 = Math.max(0, away.x0), x1 = Math.min(width, away.x1);
    if (x1 <= x0) continue;
    ctx.fillStyle = colors.away || colors.span;
    ctx.fillRect(x0, top, x1 - x0, areaHeight);
    ctx.strokeStyle = colors.gap;
    ctx.setLineDash([2, 3]);
    ctx.beginPath();
    ctx.moveTo(x0, top + 0.5); ctx.lineTo(x1, top + 0.5);
    ctx.moveTo(x0, top + areaHeight - 0.5); ctx.lineTo(x1, top + areaHeight - 0.5);
    ctx.stroke();
    ctx.setLineDash([]);
    const label = x1 - x0 >= 230 ? AWAY_LABEL : x1 - x0 >= 90 ? AWAY_SHORT_LABEL : null;
    if (label) {
      ctx.fillStyle = colors.label;
      ctx.textBaseline = 'middle';
      ctx.fillText(label, x0 + 8, mid);
      ctx.textBaseline = 'top';
    }
  }

  // Waveform, mirrored about the centre line; highlighted (brand red) bars are the ones above 1.5 x typical
  for (const bar of layout.bars) {
    if (bar.half <= 0) continue;
    const h = bar.half * half;
    ctx.globalAlpha = (frame.enabled ? 1 : 0.45) * bar.alpha;
    ctx.fillStyle = bar.hot ? colors.hot : colors.bar;
    ctx.fillRect(bar.x, mid - h, bar.w, h * 2);
  }
  ctx.globalAlpha = frame.enabled ? 1 : 0.45;

  // The dashed "normal" line, above and below the centre
  if (layout.normal !== null) {
    const y = layout.normal * half;
    ctx.strokeStyle = colors.normal;
    ctx.setLineDash([4, 4]);
    ctx.beginPath();
    ctx.moveTo(0, mid - y); ctx.lineTo(width, mid - y);
    ctx.moveTo(0, mid + y); ctx.lineTo(width, mid + y);
    ctx.stroke();
    ctx.setLineDash([]);
  }
  ctx.globalAlpha = 1;
}
