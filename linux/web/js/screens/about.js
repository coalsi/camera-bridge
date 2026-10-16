// About (#/about): which Camera Bridge OS this is, whether a newer one is out, and what changed in each version (js/release-notes.js).
import { get } from '../api.js';
import { h, replace, spinner } from '../dom.js';
import { icon } from '../icons.js';
import { duration, timeAgo } from '../format.js';
import { RELEASE_NOTES, compareVersions } from '../release-notes.js';
import { markVersionSeen } from '../whats-new.js';
import { inlineError } from './common.js';

const dateFormat = new Intl.DateTimeFormat(undefined, { year: 'numeric', month: 'long', day: 'numeric' });

function noteDate(text) {
  const [y, m, d] = String(text).split('-').map(Number);
  return y && m && d ? dateFormat.format(new Date(y, m - 1, d)) : text;
}

export function renderAbout() {
  const root = h('div', { class: 'about' }, h('div', { class: 'checking' }, spinner()));
  let destroyed = false;

  function headCard(info, status) {
    const update = info.update || {};
    let state;
    if (update.rebootRequired || update.state === 'ready') state = h('a', { class: 'pill live', href: '#/system' }, 'Update installed: restart to use it');
    else if (update.available) state = h('a', { class: 'pill warning', href: '#/system' }, `Version ${update.latest} is available`);
    else if (update.checked) state = h('span', { class: 'pill idle' }, `Up to date · checked ${timeAgo(update.checked)}`);
    const row = (k, v) => v ? [h('dt', null, k), h('dd', null, v)] : null;
    return h('section', { class: 'card about-head' },
      h('img', { src: '/mark.svg?v=3', alt: '', width: 64, height: 64 }),
      h('div', { class: 'about-id' },
        h('h2', null, info.product || 'Camera Bridge OS'),
        h('p', { class: 'about-version' }, `Version ${info.version}`, String(info.version).startsWith('0.') ? h('span', { class: 'pill info', title: 'Versions before 1.0 are betas: the interface is still being refined.' }, 'Beta') : null),
        state,
        h('dl', { class: 'kv' },
          row('Build', info.build && info.build !== 'development' ? info.build : null),
          row('System', info.osName), row('Machine', info.hardware),
          row('Running for', status ? duration(status.uptimeSeconds) : null))),
      h('p', { class: 'about-blurb muted' },
        'Camera Bridge OS turns a small PC into a hub for your cameras: live video, recording and Apple Home, all on your own network. ',
        'Free for personal use. ', h('a', { href: 'https://camera-bridge.app', target: '_blank', rel: 'noopener' }, 'camera-bridge.app')));
  }

  /** The newer version's own notes (from its release page), while it waits to be installed. */
  function comingCard(info) {
    const update = info.update || {};
    if (!update.available || !update.notes) return null;
    return h('section', { class: 'card' },
      h('h2', null, `Coming in version ${update.latest}`),
      h('p', { class: 'about-release-text' }, update.notes),
      h('a', { class: 'btn primary', href: '#/system' }, icon('download'), 'Install from System'));
  }

  function notesCard(info) {
    const current = info.version;
    return h('section', { class: 'card' },
      h('h2', null, 'What’s new'),
      h('div', { class: 'release-list' }, RELEASE_NOTES.map((entry) => {
        const order = compareVersions(entry.version, current);
        const tag = order === 0 ? h('span', { class: 'pill live' }, 'This version')
          : order > 0 ? h('span', { class: 'pill idle' }, 'Being tested on this bridge') : null;
        return h('article', { class: 'release' },
          h('header', null, h('h3', null, `Version ${entry.version}`), tag, h('time', { class: 'muted small', datetime: entry.date }, noteDate(entry.date))),
          entry.title ? h('p', { class: 'release-title' }, entry.title) : null,
          h('ul', null, entry.items.map((item) => h('li', null, item))));
      })));
  }

  Promise.all([get('system'), get('status').catch(() => null)]).then(([info, status]) => {
    if (destroyed) return;
    markVersionSeen(info.version);
    replace(root, headCard(info, status), comingCard(info), notesCard(info));
  }).catch((error) => { if (!destroyed) replace(root, inlineError(error.message)); });

  return { el: h('div', null, h('div', { class: 'page-head' }, h('h1', null, 'About')), root), destroy() { destroyed = true; } };
}
