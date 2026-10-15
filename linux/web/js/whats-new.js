// "Updated to version X": once per browser after the bridge runs a version it has not shown yet, a notice at the top of the page links to
// the notes on the About page. A browser that has never seen the bridge before just remembers the version (nothing is new to it).
import { h } from './dom.js';
import { icon } from './icons.js';
import { notesFor } from './release-notes.js';

const KEY = 'cb.seenVersion';

function seenVersion() {
  try { return localStorage.getItem(KEY); } catch { return null; }
}

export function markVersionSeen(version) {
  try { localStorage.setItem(KEY, version); } catch { /* not kept: the notice may show again */ }
}

/** The notice for `version`, or null when there is nothing new to say. Dismissing it or opening About marks the version seen. */
export function whatsNewNotice(version) {
  if (!version) return null;
  const seen = seenVersion();
  if (seen === null) { markVersionSeen(version); return null; }
  if (seen === version || !notesFor(version)) return null;
  const notice = h('div', { class: 'whats-new', role: 'status' },
    icon('info'),
    h('span', null, h('strong', null, `Updated to version ${version}. `), notesFor(version).title || ''),
    h('a', { class: 'btn small primary', href: '#/about', onclick: () => notice.remove() }, 'See what’s new'),
    h('button', { class: 'btn small', type: 'button', 'aria-label': 'Dismiss', onclick: () => { markVersionSeen(version); notice.remove(); } }, icon('x')));
  return notice;
}
