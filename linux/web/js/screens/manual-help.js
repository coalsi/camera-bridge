// "Change it by hand": what a person can do on the camera, or on the router, where Camera Bridge could not (the bridge's words, one table:
// BridgeEngine/Security/CameraManualHelp.swift). Shown under a step of Set up for Camera Bridge the camera refused or does not support
// (camera-setup.js) and under the Security card's findings the setup can't change, the Internet guard's "Not watched" among them
// (security.js). A menu path the bridge does not call confirmed (read on the camera's own pages or in its maker's documents) always comes
// with "Menu names differ between models". Pointing the DNS at Camera Bridge also has a button to the camera's own page (the address the
// bridge is configured with; a new tab that can't reach back), what the camera asks now, Copy for the addresses to type (the clipboard where
// the browser has it, else the value selected: the box's page is plain HTTP), the address to keep and reserve, and warnings. Built with the
// DOM API only: nothing the bridge sends becomes markup.
import { h } from '../dom.js';

const list = (items) => (items.length < 2 ? items.join('') : `${items.slice(0, -1).join(', ')} and ${items.at(-1)}`);

/** The page's own words for the help. */
export const MANUAL_TEXT = {
  summary: 'Change it by hand',
  /** Under the Internet guard's "Not watched". */
  watchSummary: 'Point its DNS at Camera Bridge yourself',
  router: 'On your router',
  /** The bridge's CameraManualHelpText.caveat, for help that left it out. */
  caveat: 'Menu names differ between models and firmware versions, so look for the closest match.',
  open: 'Open the camera’s web page',
  copy: 'Copy',
  copied: 'Copied',
  selected: 'Selected: press Ctrl+C (⌘C on a Mac)',
  copyLabel: (label) => `Copy ${label}`,
  /** What the camera asks now, and what both its slots should be (`target`, the first address to type). */
  current: (servers, target) => `Right now it asks ${list(servers)}.${target ? ` Change both to ${target}.` : ''}`,
  keep: ({ address, mask, gateway }) => `Keep its address as it is: ${[address, mask && `mask ${mask}`, gateway && `gateway ${gateway}`].filter(Boolean).join(', ')}.`,
  /** The router reservation (also the setup's, camera-setup.js). */
  reserve: (address, mac) => (mac ? `Reserve ${address} for this camera in your router (its hardware address is ${mac}).`
    : `Reserve ${address} for this camera in your router.`),
};

const text = (value) => (typeof value === 'string' && value.trim() ? value.trim() : null);
const IPV4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;
const MAC = /^[0-9a-f]{2}([:-][0-9a-f]{2}){5}$/i;
const ipv4 = (value) => (typeof value === 'string' && IPV4.test(value) && value.split('.').every((part) => Number(part) <= 255) ? value : null);

/** The bridge's link to the camera's own page, or null: only an absolute http or https address with no user name or password in it. */
function pageLink(raw) {
  if (!raw || typeof raw !== 'object' || typeof raw.url !== 'string') return null;
  let url;
  try { url = new URL(raw.url); } catch { return null; }
  if ((url.protocol !== 'http:' && url.protocol !== 'https:') || url.username || url.password || !url.hostname) return null;
  return { label: text(raw.label) ?? MANUAL_TEXT.open, url: url.href };
}

/**
 * The bridge's `manualHelp` as the page shows it, or null when there is nothing to show:
 *   why       one sentence
 *   places    [{ app, path: [menu, …], action, confirmed }] (entries without an app or an action are left out)
 *   values    [{ label, value, copy }] what to set (`copy`: an address to type, with a Copy button)
 *   router, note, then   one sentence each, or null
 *   caveat    "Menu names differ between models …" whenever a place is not confirmed (the page adds it when the bridge did not), else the
 *             bridge's, or null
 *   link      { label, url } the camera's own page (http or https only), or null
 *   current   [server, …] what the camera's DNS asks now (empty: not known)
 *   keep      { address, mask, gateway } the camera's address to keep (mask and gateway null when not known), or null
 *   reserve   { address, mac } the router reservation (mac null when not known), or null
 *   warnings  [sentence, …]
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
    .map((entry) => ({ label: text(entry.label), value: text(entry.value), copy: entry.copy === true }));
  const why = text(raw.why);
  const router = text(raw.router);
  if (!why && !places.length && !router) return null;
  const unconfirmed = places.some((place) => !place.confirmed);
  const keepAddress = ipv4(raw.keep?.address);
  const reserveAddress = ipv4(raw.reserve?.address);
  return {
    why, places, values, router, note: text(raw.note), then: text(raw.then),
    caveat: unconfirmed ? (text(raw.caveat) ?? MANUAL_TEXT.caveat) : text(raw.caveat),
    link: pageLink(raw.link),
    current: (Array.isArray(raw.current) ? raw.current : []).map(text).filter(Boolean),
    keep: keepAddress ? { address: keepAddress, mask: ipv4(raw.keep.mask), gateway: ipv4(raw.keep.gateway) } : null,
    reserve: reserveAddress ? { address: reserveAddress, mac: typeof raw.reserve.mac === 'string' && MAC.test(raw.reserve.mac) ? raw.reserve.mac : null } : null,
    warnings: (Array.isArray(raw.warnings) ? raw.warnings : []).map(text).filter(Boolean),
  };
}

/**
 * Copies `value`: through the clipboard where the browser has it (a secure page), else by selecting `element`'s text and asking the browser
 * to copy the selection (it can, from a click, on a plain HTTP page too); the selection stays for the person to copy when it can't.
 * 'copied', 'selected' or 'failed'. The browser's parts can be given for tests.
 */
export async function copyText(value, element, {
  clipboard = globalThis.navigator?.clipboard,
  selection = globalThis.window?.getSelection?.() ?? null,
  range = () => globalThis.document?.createRange?.() ?? null,
  exec = (command) => globalThis.document?.execCommand?.(command) === true,
} = {}) {
  if (typeof clipboard?.writeText === 'function') {
    try {
      await clipboard.writeText(value);
      return 'copied';
    } catch {
      // Refused (no permission, the page not in front): select it instead.
    }
  }
  const made = typeof range === 'function' ? range() : null;
  if (!selection || !made || !element) return 'failed';
  try {
    made.selectNodeContents(element);
    selection.removeAllRanges();
    selection.addRange(made);
  } catch {
    return 'failed';
  }
  try { if (exec('copy')) return 'copied'; } catch { /* the selection stays */ }
  return 'selected';
}

/** A value to type, with its Copy button: the button says what happened for a moment. */
function valueWithCopy(entry) {
  const shown = h('span', { class: 'manual-value' }, entry.value);
  if (!entry.copy) return [shown];
  const button = h('button', { class: 'btn small manual-copy', type: 'button', 'aria-label': MANUAL_TEXT.copyLabel(entry.label) }, MANUAL_TEXT.copy);
  let reset = null;
  button.addEventListener('click', async () => {
    const result = await copyText(entry.value, shown);
    button.textContent = result === 'copied' ? MANUAL_TEXT.copied : result === 'selected' ? MANUAL_TEXT.selected : MANUAL_TEXT.copy;
    clearTimeout(reset);
    reset = setTimeout(() => { button.textContent = MANUAL_TEXT.copy; }, 2500);
    reset?.unref?.();
  });
  return [shown, ' ', button];
}

/**
 * The help as one disclosure, closed unless `open`: why, the camera's own page, what it asks now, where (each menu joined by ›), what to
 * set (Copy for the addresses), the address to keep and reserve, warnings, what else, then the router's way (another way, after the
 * camera's), what then. `onToggle(open)` hears it opened or closed, so a view drawn again can keep it as the person left it.
 */
export function manualHelpBlock(view, { summary = MANUAL_TEXT.summary, open = false, onToggle = null } = {}) {
  if (!view) return null;
  const where = view.places.map((place) => h('li', null, h('strong', null, `${place.app}: `),
    place.path.length ? [h('span', { class: 'manual-path' }, place.path.join(' › ')), '. '] : null, place.action));
  const target = (view.values ?? []).find((entry) => entry.copy)?.value ?? null;
  const ontoggle = typeof onToggle === 'function' ? (event) => onToggle(event.target?.open === true) : null;
  return h('details', { class: 'manual-help', open, ontoggle },
    h('summary', null, summary),
    view.why ? h('p', null, view.why) : null,
    view.link ? h('p', null, h('a', { class: 'btn small manual-link', href: view.link.url, target: '_blank', rel: 'noopener noreferrer' }, view.link.label)) : null,
    view.current?.length ? h('p', { class: 'manual-current' }, MANUAL_TEXT.current(view.current, target)) : null,
    where.length ? h('ol', { class: 'steps' }, where) : null,
    view.values.length ? h('dl', { class: 'manual-values' }, view.values.map((entry) => [h('dt', null, entry.label), h('dd', null, valueWithCopy(entry))])) : null,
    view.keep ? h('p', { class: 'manual-keep' }, MANUAL_TEXT.keep(view.keep)) : null,
    view.reserve ? h('p', { class: 'manual-reserve' }, MANUAL_TEXT.reserve(view.reserve.address, view.reserve.mac)) : null,
    view.warnings?.length ? h('ul', { class: 'manual-warnings' }, view.warnings.map((warning) => h('li', null, warning))) : null,
    view.note ? h('p', { class: 'muted' }, view.note) : null,
    view.router ? h('p', { class: 'manual-router' }, h('strong', null, `${MANUAL_TEXT.router}: `), view.router) : null,
    view.then ? h('p', null, view.then) : null,
    view.caveat ? h('p', { class: 'muted' }, view.caveat) : null);
}
