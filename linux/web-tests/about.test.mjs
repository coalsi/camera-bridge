// About (screens/about.js) and the notice after an update (js/whats-new.js), in the fake browser: a beta is "Camera Bridge OS beta" with
// its build number and one list of changes by day; 1.0 and later show each version on its own; the notice names everything since the
// version this browser last saw.
import assert from 'node:assert/strict';
import { after, before, beforeEach, test } from 'node:test';
import { RELEASE_NOTES } from '../web/js/release-notes.js';
import { installFakeBrowser, makeStorage } from './support/fake-browser.mjs';

let browser;
let about;
let news;
before(async () => {
  browser = installFakeBrowser();
  about = await import('../web/js/screens/about.js');
  news = await import('../web/js/whats-new.js');
});
after(() => browser?.restore());
beforeEach(() => { globalThis.localStorage = makeStorage(); });

/** Every element under `root` (depth first) that `match` accepts. */
function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  for (const node of [root].flat()) if (node) { if (node.tagName && match(node)) out.push(node); walk(node); }
  return out;
}
const byClass = (root, name) => all(root, (node) => node.classList.contains(name));
const byTag = (root, tag) => all(root, (node) => node.localName === tag);
const texts = (nodes) => nodes.map((node) => node.textContent);

const NEWEST = RELEASE_NOTES[0];

// MARK: About

test('a beta is "Camera Bridge OS beta", with its build number as the detail', () => {
  const card = about.headCard({ product: 'Camera Bridge OS', version: '0.1.108' }, null);
  assert.equal(byTag(card, 'h2')[0].textContent, 'Camera Bridge OS beta');
  assert.equal(byClass(card, 'about-version')[0].textContent, 'Build 0.1.108');
  assert.doesNotMatch(card.textContent, /Version 0\./);
});

test('1.0 and later are named by version, with no beta', () => {
  const card = about.headCard({ product: 'Camera Bridge OS', version: '1.0.0' }, null);
  assert.equal(byTag(card, 'h2')[0].textContent, 'Camera Bridge OS');
  assert.equal(byClass(card, 'about-version')[0].textContent, 'Version 1.0.0');
  assert.doesNotMatch(card.textContent, /beta/i);
});

test('a newer beta is offered by its build, a numbered release by its version', () => {
  const pill = (latest) => byClass(about.headCard({ version: '0.1.108', update: { available: true, latest } }, null), 'warning')[0].textContent;
  assert.equal(pill('0.1.109'), 'A newer beta is available: build 0.1.109');
  assert.equal(pill('1.0.0'), 'Version 1.0.0 is available');
  const coming = (latest) => about.comingCard({ version: '0.1.108', update: { available: true, latest, notes: 'Lines.' } });
  assert.equal(byTag(coming('0.1.109'), 'h2')[0].textContent, 'Coming in the next beta');
  assert.match(coming('0.1.109').textContent, /Build 0\.1\.109/);
  assert.equal(byTag(coming('1.0.0'), 'h2')[0].textContent, 'Coming in version 1.0.0');
});

test('on a beta the changes are one list by day, newest day first, with no version headers', () => {
  const card = about.notesCard(NEWEST.version);
  const days = byClass(card, 'release');
  const dates = [...new Set(RELEASE_NOTES.map((entry) => entry.date))];
  assert.deepEqual(days.map((day) => byTag(day, 'time')[0].getAttribute('datetime')), dates);
  assert.ok(!texts(byTag(card, 'h3')).some((text) => /Version/.test(text)), 'no per-version headers');
  // Each day holds its own entries, newest first: the title in bold, its build number small beside it, then its lines.
  for (const day of days) {
    const date = byTag(day, 'time')[0].getAttribute('datetime');
    const entries = RELEASE_NOTES.filter((entry) => entry.date === date);
    assert.deepEqual(texts(byTag(day, 'strong')), entries.map((entry) => entry.title));
    assert.deepEqual(texts(byClass(day, 'release-build')), entries.map((entry) => `build ${entry.version}`));
    assert.equal(byTag(day, 'li').length, entries.reduce((sum, entry) => sum + entry.items.length, 0));
  }
  assert.equal(byClass(card, 'release-entry').length, RELEASE_NOTES.length, 'every entry once');
});

test('the running build is marked, and builds newer than it say they are being tested', () => {
  const card = about.notesCard('0.1.106');
  const tagOf = (version) => {
    const entry = byClass(card, 'release-entry').find((node) => byClass(node, 'release-build')[0].textContent === `build ${version}`);
    return byClass(entry, 'pill')[0]?.textContent ?? null;
  };
  assert.equal(tagOf('0.1.106'), 'This build');
  assert.equal(tagOf('0.1.107'), 'Being tested on this bridge');
  assert.equal(tagOf('0.1.108'), 'Being tested on this bridge');
  assert.equal(tagOf('0.1.105'), null);
});

test('from 1.0 each version has its own notes again, and the beta follows by day', () => {
  const notes = [
    { version: '1.1.0', date: '2026-12-01', title: 'Eleven', items: ['a', 'b'] },
    { version: '1.0.0', date: '2026-11-02', title: 'One', items: ['a'] },
    { version: '0.1.110', date: '2026-10-18', title: 'Ten', items: ['a'] },
    { version: '0.1.109', date: '2026-10-17', title: 'Nine', items: ['a'] },
  ];
  const [versions, beta] = about.notesCard('1.0.0', notes);
  assert.deepEqual(texts(byTag(versions, 'h3')), ['Version 1.1.0', 'Version 1.0.0']);
  assert.deepEqual(texts(byClass(versions, 'release-title')), ['Eleven', 'One']);
  assert.deepEqual(texts(byClass(versions, 'pill')), ['Being tested on this bridge', 'This version']);
  assert.equal(byTag(beta, 'h2')[0].textContent, 'Camera Bridge OS beta');
  assert.deepEqual(byTag(beta, 'time').map((node) => node.getAttribute('datetime')), ['2026-10-18', '2026-10-17']);
  assert.deepEqual(texts(byClass(beta, 'release-build')), ['build 0.1.110', 'build 0.1.109']);
  // A 1.0 bridge whose notes are all betas shows only the beta's card.
  assert.deepEqual(about.notesCard('1.0.0').filter(Boolean).map((card) => byTag(card, 'h2')[0].textContent), ['Camera Bridge OS beta']);
});

// MARK: The notice after an update

const shown = (notice) => byTag(notice, 'span')[0].textContent;

test('a browser that has never seen the bridge only remembers the version', () => {
  assert.equal(news.whatsNewNotice(NEWEST.version), null);
  assert.equal(localStorage.getItem('cb.seenVersion'), NEWEST.version);
  assert.equal(news.whatsNewNotice(NEWEST.version), null, 'nothing new the second time either');
});

test('after an update the notice names every entry since the version last seen, newest first', () => {
  const since = RELEASE_NOTES[3];
  localStorage.setItem('cb.seenVersion', since.version);
  const notice = news.whatsNewNotice(NEWEST.version);
  const titles = RELEASE_NOTES.slice(0, 3).map((entry) => entry.title);
  assert.equal(shown(notice), `Updated to beta build ${NEWEST.version}. ${titles.join(' · ')}`);
  assert.ok(!shown(notice).includes(since.title), 'not the one already seen');
  assert.equal(byTag(notice, 'a')[0].getAttribute('href'), '#/about');
  assert.equal(byTag(notice, 'a')[0].textContent, 'See what’s new');
});

test('the notice shows once: dismissing it marks the version seen', () => {
  localStorage.setItem('cb.seenVersion', RELEASE_NOTES[1].version);
  const notice = news.whatsNewNotice(NEWEST.version);
  assert.equal(shown(notice), `Updated to beta build ${NEWEST.version}. ${NEWEST.title}`);
  byTag(notice, 'button')[0].click();
  assert.equal(localStorage.getItem('cb.seenVersion'), NEWEST.version);
  assert.equal(news.whatsNewNotice(NEWEST.version), null);
});

test('a last-seen version that is not a version, or older than every entry, gives the newest entry only', () => {
  for (const seen of ['', 'garbage', '0.0-dev', '0.0.1', '0.1.50']) {
    localStorage.setItem('cb.seenVersion', seen);
    assert.equal(shown(news.whatsNewNotice(NEWEST.version)), `Updated to beta build ${NEWEST.version}. ${NEWEST.title}`, seen);
  }
});

test('nothing is new on the same version, after a rollback, or when storage is blocked', () => {
  localStorage.setItem('cb.seenVersion', NEWEST.version);
  assert.equal(news.whatsNewNotice(NEWEST.version), null);
  localStorage.setItem('cb.seenVersion', '0.1.999');
  assert.equal(news.whatsNewNotice(NEWEST.version), null);
  globalThis.localStorage = makeStorage({ broken: true });
  assert.equal(news.whatsNewNotice(NEWEST.version), null);
  assert.equal(news.whatsNewNotice(null), null);
});

test('from 1.0 the notice names the version', () => {
  localStorage.setItem('cb.seenVersion', RELEASE_NOTES[2].version);
  const notice = news.whatsNewNotice('1.0.0');
  assert.equal(shown(notice), `Updated to version 1.0.0. ${RELEASE_NOTES.slice(0, 2).map((entry) => entry.title).join(' · ')}`);
});

test('the side menu names a beta by its build, a release by its version', () => {
  assert.equal(news.versionLabel('Camera Bridge OS', '0.1.108'), 'Camera Bridge OS beta · build 0.1.108');
  assert.equal(news.versionLabel('Camera Bridge OS', '1.0.0'), 'Camera Bridge OS 1.0.0');
});

test('the System page names a beta update by its build', async () => {
  const { updateLabel } = await import('../web/js/screens/system.js');
  assert.equal(updateLabel('0.1.109'), 'beta build 0.1.109');
  assert.equal(updateLabel('0.1.109', true), 'Beta build 0.1.109');
  assert.equal(updateLabel('1.0.0', true), 'Version 1.0.0');
});
