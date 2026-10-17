// "Updated to beta build X" ("Updated to version X" from 1.0): once per browser after the bridge runs a version it has not shown yet, a
// notice at the top of the page names what came since the version this browser last saw and links to the notes on the About page. A
// browser that has never seen the bridge before just remembers the version (nothing is new to it).
import { h } from './dom.js';
import { icon } from './icons.js';
import { isBeta, notesSince } from './release-notes.js';

const KEY = 'cb.seenVersion';

function seenVersion() {
  try { return localStorage.getItem(KEY); } catch { return null; }
}

export function markVersionSeen(version) {
  try { localStorage.setItem(KEY, version); } catch { /* not kept: the notice may show again */ }
}

/** How the page names the system: "Camera Bridge OS beta · build 0.1.108" before 1.0, "Camera Bridge OS 1.0.0" from 1.0. */
export function versionLabel(product, version) {
  return isBeta(version) ? `${product} beta · build ${version}` : `${product} ${version}`;
}

/** The notice for `version`, or null when there is nothing new to say. Dismissing it or opening About marks the version seen. */
export function whatsNewNotice(version) {
  if (!version) return null;
  const seen = seenVersion();
  if (seen === null) { markVersionSeen(version); return null; }
  if (seen === version) return null;
  const news = notesSince(seen, version);
  if (!news.length) return null;
  const titles = news.map((entry) => entry.title).filter(Boolean).join(' · ');
  const notice = h('div', { class: 'whats-new', role: 'status' },
    icon('info'),
    h('span', null, h('strong', null, isBeta(version) ? `Updated to beta build ${version}. ` : `Updated to version ${version}. `), titles),
    h('a', { class: 'btn small primary', href: '#/about', onclick: () => notice.remove() }, 'See what’s new'),
    h('button', { class: 'btn small', type: 'button', 'aria-label': 'Dismiss', onclick: () => { markVersionSeen(version); notice.remove(); } }, icon('x')));
  return notice;
}
