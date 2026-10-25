// The Wi-Fi card on the System page: the radio the box is on, and the warning on 2.4 GHz.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';

let browser;
before(() => { browser = installFakeBrowser(); });
after(() => browser?.restore());

const ONLINE = { state: 'online', message: '', ssid: 'Maple Cottage', hotspot: null, saved: ['Maple Cottage'], lastError: null, hasWifi: true, wired: false, networks: [] };
const WARNING = '2.4 GHz is slow for many cameras; an Ethernet cable or 5 GHz is better.';
const text = (node) => (node.childNodes ?? []).map((child) => (child.tagName ? text(child) : child.data ?? child.textContent ?? '')).join('');
const actions = { scan() {}, join() {}, forget() {} };

test('on 5 GHz the card names the band and has no warning', async () => {
  const { wifiCardFor } = await import('../web/js/screens/wifi-card.js');
  const words = text(wifiCardFor({ ...ONLINE, band: '5 GHz' }, actions));
  assert.match(words, /On the Wi-Fi network “Maple Cottage” · 5 GHz\./);
  assert.ok(!words.includes('slow'));
});

test('on 6 GHz the card names the band and has no warning', async () => {
  const { wifiCardFor } = await import('../web/js/screens/wifi-card.js');
  const words = text(wifiCardFor({ ...ONLINE, band: '6 GHz' }, actions));
  assert.match(words, /· 6 GHz\./);
  assert.ok(!words.includes('slow'));
});

test('on 2.4 GHz the card names the band and warns that it is slow for many cameras', async () => {
  const { wifiCardFor } = await import('../web/js/screens/wifi-card.js');
  const words = text(wifiCardFor({ ...ONLINE, band: '2.4 GHz' }, actions));
  assert.match(words, /On the Wi-Fi network “Maple Cottage” · 2\.4 GHz\./);
  assert.ok(words.includes(WARNING), words);
});

test('without a band in the report (an older system, or not yet measured) the card says nothing about it', async () => {
  const { wifiCardFor } = await import('../web/js/screens/wifi-card.js');
  for (const band of [undefined, null, '', 'Wi-Fi 7']) {
    const words = text(wifiCardFor({ ...ONLINE, band }, actions));
    assert.match(words, /On the Wi-Fi network “Maple Cottage”\./);
    assert.ok(!words.includes('GHz'), String(band));
  }
});

test('with a cable the band does not matter and nothing is said about it', async () => {
  const { wifiCardFor } = await import('../web/js/screens/wifi-card.js');
  const words = text(wifiCardFor({ ...ONLINE, wired: true, band: '2.4 GHz' }, actions));
  assert.match(words, /Connected with a network cable\./);
  assert.ok(!words.includes('GHz'));
});

test('no card without the system, or where it manages no Wi-Fi', async () => {
  const { wifiCardFor, wifiBand } = await import('../web/js/screens/wifi-card.js');
  assert.equal(wifiCardFor(null, actions), null);
  assert.equal(wifiCardFor({ ...ONLINE, state: 'unavailable' }, actions), null);
  assert.equal(wifiBand({ ...ONLINE, ssid: '', band: '5 GHz' }), '');
});

test('the saved networks and the search keep working', async () => {
  const { wifiCardFor } = await import('../web/js/screens/wifi-card.js');
  const forgotten = [];
  const card = wifiCardFor({ ...ONLINE, band: '5 GHz' }, { networks: [{ ssid: 'Cafe', signal: 40, security: '' }], busy: '', scan() {}, join() {}, forget: (ssid) => forgotten.push(ssid) });
  const words = text(card);
  assert.match(words, /Maple Cottage · in use/);
  assert.match(words, /Cafe/);
  assert.match(words, /40% · open/);
});
