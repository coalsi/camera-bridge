// The video label: the camera's name and the date and time, drawn on pictures the way the bridge burns them into Apple Home's video and saved
// clips (PlatformLinux/Codecs/OverlayScratch.swift `overlayLine`, MediaCore TimestampOverlay): "Front Door  |  Thu, Oct 2  7:42:15 PM", white
// on a translucent black box, in the corner and size the camera's style says (`camera.timestampOverlay`). One look everywhere.

// The time is the bridge's (store.js bridgeZone), as in the label it burns.
import { bridgeZone } from './store.js';
import { zonedFormat } from './zone.js';

const MAX_NAME = 28;
const DATE = { weekday: 'short', month: 'short', day: 'numeric' };

function timeFormat(seconds, hour24, zone) {
  return zonedFormat({ hour: 'numeric', minute: '2-digit', ...(seconds ? { second: '2-digit' } : {}), hour12: !hour24 }, zone);
}

/** The style of `camera`'s label (its timestamp overlay settings, with the bridge's defaults). */
export function labelStyle(camera) {
  const o = camera?.timestampOverlay ?? {};
  return {
    position: o.position ?? 'topRight', size: o.size ?? 'medium', showCameraName: o.showCameraName ?? true,
    showDate: o.showDate ?? true, showSeconds: o.showSeconds ?? true, use24Hour: o.use24Hour ?? false,
  };
}

/** The label's words for `camera` at `ms` (epoch milliseconds), in `zone` (the bridge's when omitted). */
export function labelLine(camera, ms, zone = bridgeZone()) {
  const style = labelStyle(camera);
  let clock = timeFormat(style.showSeconds, style.use24Hour, zone).format(ms).replace(/ /g, ' ');
  if (style.showDate) clock = `${zonedFormat(DATE, zone).format(ms)}  ${clock}`;
  const name = (camera?.name ?? '').trim();
  if (!style.showCameraName || !name) return clock;
  return `${name.length > MAX_NAME ? `${name.slice(0, MAX_NAME - 1)}…` : name}  |  ${clock}`;
}

/** Shows `camera`'s label on `el` (a `.video-label` element) for `ms`; nil `ms` hides it. */
export function showLabel(el, camera, ms) {
  if (ms === null || ms === undefined || !Number.isFinite(ms)) { el.hidden = true; return; }
  const style = labelStyle(camera);
  const text = labelLine(camera, ms);
  if (el.textContent !== text) el.textContent = text;
  if (el.dataset.position !== style.position) el.dataset.position = style.position;
  if (el.dataset.size !== style.size) el.dataset.size = style.size;
  el.hidden = false;
}
