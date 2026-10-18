// "Change it by hand": what a person can do on the camera, or on the router, where Camera Bridge could not (the bridge's words, one table:
// BridgeEngine/Security/CameraManualHelp.swift). Shown under a step of Set up for Camera Bridge the camera refused or does not support
// (camera-setup.js) and under the Security card's findings the setup can't change, the Internet guard's "Not watched" among them
// (security.js). A menu path the bridge does not call confirmed (read on the camera's own pages or in its maker's documents) always comes
// with "Menu names differ between models". Built with the DOM API only: nothing the bridge sends becomes markup.
import { h } from '../dom.js';

/** The page's own words for the help. */
export const MANUAL_TEXT = {
  summary: 'Change it by hand',
  /** Under the Internet guard's "Not watched". */
  watchSummary: 'Point its DNS at Camera Bridge yourself',
  router: 'On your router',
  /** The bridge's CameraManualHelpText.caveat, for help that left it out. */
  caveat: 'Menu names differ between models and firmware versions, so look for the closest match.',
};

const text = (value) => (typeof value === 'string' && value.trim() ? value.trim() : null);

/**
 * The bridge's `manualHelp` as the page shows it, or null when there is nothing to show:
 *   why       one sentence
 *   places    [{ app, path: [menu, …], action, confirmed }] (entries without an app or an action are left out)
 *   values    [{ label, value }] what to set
 *   router, note, then   one sentence each, or null
 *   caveat    "Menu names differ between models …" whenever a place is not confirmed (the page adds it when the bridge did not), else the
 *             bridge's, or null
 */
export function manualHelpView(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const places = (Array.isArray(raw.places) ? raw.places : [])
    .filter((place) => place && typeof place === 'object' && text(place.app) && text(place.action))
    .map((place) => ({
      app: text(place.app),
      path: (Array.isArray(place.path) ? place.path : []).map(text).filter(Boolean),
      action: text(place.action),
      confirmed: place.confirmed === true,
    }));
  const values = (Array.isArray(raw.values) ? raw.values : [])
    .filter((entry) => entry && typeof entry === 'object' && text(entry.label) && text(entry.value))
    .map((entry) => ({ label: text(entry.label), value: text(entry.value) }));
  const why = text(raw.why);
  const router = text(raw.router);
  if (!why && !places.length && !router) return null;
  const unconfirmed = places.some((place) => !place.confirmed);
  return { why, places, values, router, note: text(raw.note), then: text(raw.then), caveat: unconfirmed ? (text(raw.caveat) ?? MANUAL_TEXT.caveat) : text(raw.caveat) };
}

/**
 * The help as one disclosure, closed unless `open`: why, where (each menu joined by ›), what to set, the router's way, what else, what then.
 * `onToggle(open)` hears it opened or closed, so a view drawn again can keep it as the person left it.
 */
export function manualHelpBlock(view, { summary = MANUAL_TEXT.summary, open = false, onToggle = null } = {}) {
  if (!view) return null;
  const where = view.places.map((place) => h('li', null, h('strong', null, `${place.app}: `),
    place.path.length ? [h('span', { class: 'manual-path' }, place.path.join(' › ')), '. '] : null, place.action));
  if (view.router) where.push(h('li', null, h('strong', null, `${MANUAL_TEXT.router}: `), view.router));
  const ontoggle = typeof onToggle === 'function' ? (event) => onToggle(event.target?.open === true) : null;
  return h('details', { class: 'manual-help', open, ontoggle },
    h('summary', null, summary),
    view.why ? h('p', null, view.why) : null,
    where.length ? h('ol', { class: 'steps' }, where) : null,
    view.values.length ? h('dl', { class: 'manual-values' }, view.values.map((entry) => [h('dt', null, entry.label), h('dd', null, entry.value)])) : null,
    view.note ? h('p', { class: 'muted' }, view.note) : null,
    view.then ? h('p', null, view.then) : null,
    view.caveat ? h('p', { class: 'muted' }, view.caveat) : null);
}
