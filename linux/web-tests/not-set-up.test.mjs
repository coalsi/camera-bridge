// The Add Camera check for a camera with no admin password yet, and the note for a camera found through its maker's own interface.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { installFakeBrowser } from './support/fake-browser.mjs';

const all = (root, match, out = []) => { for (const child of root.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); all(child, match, out); } return out; };
const text = (node) => (node.textContent ?? '') || (node.childNodes ?? []).map((c) => c.data ?? text(c)).join('');
const info = {
  maker: 'Hikvision', title: 'This Hikvision camera hasn’t been set up yet.',
  step: 'This camera hasn’t been set up yet. Open its web page and choose an admin password (you type it twice), then come back and add it.',
  webPage: 'http://192.168.77.30', openLabel: 'Open the camera’s web page', checkAgainLabel: 'Check again',
};

test('the card names the maker, gives the step, opens the camera’s web page in a new tab and checks again', async () => {
  installFakeBrowser();
  const { notSetUpCard } = await import('../web/js/screens/not-set-up.js');
  let asked = 0;
  const card = notSetUpCard(info, { onCheckAgain: () => { asked += 1; } });
  assert.match(text(card), /This Hikvision camera hasn’t been set up yet\./);
  assert.match(text(card), /choose an admin password \(you type it twice\), then come back and add it/);
  const link = all(card, (n) => n.localName === 'a')[0];
  assert.equal(link.getAttribute?.('href') ?? link.href, 'http://192.168.77.30');
  assert.match(text(link), /Open the camera’s web page/);
  const again = all(card, (n) => n.localName === 'button')[0];
  assert.match(text(again), /Check again/);
  again.click();
  assert.equal(asked, 1);
});

test('the note for a camera found through its maker’s own interface is shown, and nothing when there is none', async () => {
  installFakeBrowser();
  const { ownInterfaceBanner } = await import('../web/js/screens/not-set-up.js');
  assert.equal(ownInterfaceBanner(null), null);
  const note = 'Found Hikvision’s own interface (ANNKE I91ET); using it for settings and security.';
  assert.match(text(ownInterfaceBanner(note)), /Found Hikvision’s own interface \(ANNKE I91ET\); using it for settings and security\./);
});

test('the Add Camera page shows the card when the check says the camera is not set up, and the note after a good check', () => {
  const source = readFileSync(new URL('../web/js/screens/add.js', import.meta.url), 'utf8');
  assert.match(source, /w\.notSetUp = result\.notSetUp \?\? null/);
  assert.match(source, /notSetUpCard\(w\.notSetUp, \{ onCheckAgain: runProbe \}\)/);
  assert.match(source, /ownInterfaceBanner\(p\.ownInterfaceNote\)/);
});

test('a camera found on another network says to put it on the home network, and Check again searches again', async () => {
  installFakeBrowser();
  const { otherNetworkCard } = await import('../web/js/screens/not-set-up.js');
  let asked = 0;
  const card = otherNetworkCard({
    address: '192.168.1.64', title: 'Found a camera on another network (192.168.1.64)',
    step: 'It must be put on your home network before Camera Bridge can add it. Open its page with Hikvision’s SADP tool, or from a computer on that network (http://192.168.1.64), turn on DHCP, then Check again.',
    checkAgainLabel: 'Check again',
  }, { onCheckAgain: () => { asked += 1; } });
  assert.match(text(card), /Found a camera on another network \(192\.168\.1\.64\)/);
  assert.match(text(card), /SADP tool.*turn on DHCP, then Check again/);
  assert.equal(all(card, (n) => n.localName === 'a').length, 0, 'its page is on another network: no link the browser could not open');
  const again = all(card, (n) => n.localName === 'button')[0];
  assert.match(text(again), /Check again/);
  again.click();
  assert.equal(asked, 1);
});

test('the camera search shows those cards instead of a choice', () => {
  const source = readFileSync(new URL('../web/js/screens/add.js', import.meta.url), 'utf8');
  assert.match(source, /otherNetworkCard\(camera\.otherNetwork, \{ onCheckAgain: runDiscovery \}\)/);
  assert.match(source, /notSetUpCard\(camera\.notSetUp, \{ onCheckAgain: runDiscovery \}\)/);
  assert.match(source, /filter\(\(camera\) => !camera\.otherNetwork && !camera\.notSetUp\)/);
});
