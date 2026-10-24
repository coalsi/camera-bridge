// About (#/about): which Camera Bridge OS this is, whether a newer one is out, and what changed (js/release-notes.js). Before 1.0 it is one
// product, "Camera Bridge OS beta" with the build number as the detail, and its changes are one list grouped by day; from 1.0 each version
// has its own notes again, and the beta's days follow them.
import { get } from '../api.js';
import { h, replace, spinner } from '../dom.js';
import { icon } from '../icons.js';
import { duration, timeAgo } from '../format.js';
import { RELEASE_NOTES, compareVersions, isBeta, notesByDay } from '../release-notes.js';
import { markVersionSeen } from '../whats-new.js';
import { inlineError } from './common.js';

const dateFormat = new Intl.DateTimeFormat(undefined, { year: 'numeric', month: 'long', day: 'numeric' });

function noteDate(text) {
  const [y, m, d] = String(text).split('-').map(Number);
  return y && m && d ? dateFormat.format(new Date(y, m - 1, d)) : text;
}

/** What a newer system is called: "A newer beta is available: build 0.1.109", or "Version 1.0.0 is available". */
function availableText(latest) {
  if (!latest) return 'An update is available';
  return isBeta(latest) ? `A newer beta is available: build ${latest}` : `Version ${latest} is available`;
}

export function headCard(info, status) {
  const update = info.update || {};
  const beta = isBeta(info.version);
  const product = info.product || 'Camera Bridge OS';
  let state;
  if (update.rebootRequired || update.state === 'ready') state = h('a', { class: 'pill live', href: '#/system' }, 'Update installed: restart to use it');
  else if (update.available) state = h('a', { class: 'pill warning', href: '#/system' }, availableText(update.latest));
  else if (update.checked) state = h('span', { class: 'pill idle' }, `Up to date · checked ${timeAgo(update.checked)}`);
  const row = (k, v) => v ? [h('dt', null, k), h('dd', null, v)] : null;
  return h('section', { class: 'card about-head' },
    h('img', { src: '/mark.svg?v=3', alt: '', width: 64, height: 64 }),
    h('div', { class: 'about-id' },
      h('h2', null, beta ? `${product} beta` : product),
      beta
        ? h('p', { class: 'about-version', title: 'Camera Bridge OS is a beta until 1.0: the interface is still being refined. Each update is a new build.' }, `Build ${info.version}`)
        : h('p', { class: 'about-version' }, `Version ${info.version}`),
      state,
      h('dl', { class: 'kv' },
        row('Build', info.build && info.build !== 'development' ? info.build : null),
        row('System', info.osName), row('Machine', info.hardware),
        row('Running for', status ? duration(status.uptimeSeconds) : null))),
    h('p', { class: 'about-blurb muted' },
      'Camera Bridge OS is a local NVR for the cameras you already own. It records every camera around the clock, shows them all live, ',
      'and keeps them on your own network: no cloud, no account, no subscription. ',
      'Apple Home is optional, and Google Home is planned. ',
      'Free for personal use. ', h('a', { href: 'https://camera-bridge.app', target: '_blank', rel: 'noopener' }, 'camera-bridge.app')));
}

/** The newer system's own notes (from its release page), while it waits to be installed. */
export function comingCard(info) {
  const update = info.update || {};
  if (!update.available || !update.notes) return null;
  const beta = isBeta(update.latest);
  return h('section', { class: 'card' },
    h('h2', null, beta ? 'Coming in the next beta' : `Coming in version ${update.latest}`),
    beta && update.latest ? h('p', { class: 'muted small' }, `Build ${update.latest}`) : null,
    h('p', { class: 'about-release-text' }, update.notes),
    h('a', { class: 'btn primary', href: '#/system' }, icon('download'), 'Install from System'));
}

/** "This build" or "This version" on the notes of the running system, and a mark on notes newer than it. */
function tagFor(entry, current) {
  const order = compareVersions(entry.version, current);
  if (order === 0) return h('span', { class: 'pill live' }, isBeta(entry.version) ? 'This build' : 'This version');
  return order > 0 ? h('span', { class: 'pill idle' }, 'Being tested on this bridge') : null;
}

/** One day of the beta: the date as the heading, then each entry's title in bold with its build number small beside it, and its lines. */
function dayArticle(day, current) {
  return h('article', { class: 'release' },
    h('header', null, h('h3', null, h('time', { datetime: day.date }, noteDate(day.date)))),
    day.entries.map((entry) => h('div', { class: 'release-entry' },
      h('p', { class: 'release-entry-head' },
        entry.title ? h('strong', null, entry.title) : null,
        h('span', { class: 'release-build' }, `build ${entry.version}`),
        tagFor(entry, current)),
      h('ul', null, entry.items.map((item) => h('li', null, item))))));
}

/** One numbered version (1.0 and later), as its own article. */
function versionArticle(entry, current) {
  return h('article', { class: 'release' },
    h('header', null, h('h3', null, `Version ${entry.version}`), tagFor(entry, current), h('time', { class: 'muted small', datetime: entry.date }, noteDate(entry.date))),
    entry.title ? h('p', { class: 'release-title' }, entry.title) : null,
    h('ul', null, entry.items.map((item) => h('li', null, item))));
}

/**
 * What changed, for a bridge running `current`. On a beta: one card, the beta's changes by day. From 1.0: the numbered versions, then the
 * beta's days in a card of their own.
 */
export function notesCard(current, notes = RELEASE_NOTES) {
  const betaDays = (entries) => h('div', { class: 'release-list' }, notesByDay(entries).map((day) => dayArticle(day, current)));
  if (isBeta(current)) return h('section', { class: 'card' }, h('h2', null, 'What’s new'), betaDays(notes));
  const versions = notes.filter((entry) => !isBeta(entry.version));
  const betas = notes.filter((entry) => isBeta(entry.version));
  return [
    versions.length ? h('section', { class: 'card' }, h('h2', null, 'What’s new'), h('div', { class: 'release-list' }, versions.map((entry) => versionArticle(entry, current)))) : null,
    betas.length ? h('section', { class: 'card' }, h('h2', null, 'Camera Bridge OS beta'), h('p', { class: 'muted' }, 'What changed before 1.0, by day.'), betaDays(betas)) : null,
  ];
}

export function renderAbout() {
  const root = h('div', { class: 'about' }, h('div', { class: 'checking' }, spinner()));
  let destroyed = false;

  Promise.all([get('system'), get('status').catch(() => null)]).then(([info, status]) => {
    if (destroyed) return;
    markVersionSeen(info.version);
    replace(root, headCard(info, status), comingCard(info), notesCard(info.version));
  }).catch((error) => { if (!destroyed) replace(root, inlineError(error.message)); });

  return { el: h('div', null, h('div', { class: 'page-head' }, h('h1', null, 'About')), root), destroy() { destroyed = true; } };
}
