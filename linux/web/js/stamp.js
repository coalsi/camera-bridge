// The clock written on every picture: "Tue 14 Oct · 6:27:14 PM". One place, so a Live Feed card, the camera page, an NVR tile and the
// monitor all read the same.
const dayFormat = new Intl.DateTimeFormat(undefined, { weekday: 'short', day: 'numeric', month: 'short' });
const timeFormat = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit', second: '2-digit' });

/** Date and time of `ms` (now when omitted). */
export function stampText(ms = Date.now()) {
  return `${dayFormat.format(ms)} · ${timeFormat.format(ms)}`;
}
