// The clock written on every picture: "Tue 14 Oct · 6:27:14 PM". One place, so a Live Feed card, the camera page, an NVR tile and the
// monitor all read the same. Said in the bridge's time zone (store.js bridgeZone), as the bridge's own label is, whichever zone the browser is in.
import { bridgeZone } from './store.js';
import { zonedFormat } from './zone.js';

const DAY = { weekday: 'short', day: 'numeric', month: 'short' };
const TIME = { hour: 'numeric', minute: '2-digit', second: '2-digit' };

/** Date and time of `ms` (now when omitted), in `zone` (the bridge's when omitted). */
export function stampText(ms = Date.now(), zone = bridgeZone()) {
  return `${zonedFormat(DAY, zone).format(ms)} · ${zonedFormat(TIME, zone).format(ms)}`;
}
