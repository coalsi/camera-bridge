// The Box health card of the System page (screens/drive-health-card.js): the drives' health from the daily check, the clock, and a network cable
// slower than a gigabit (the owner's box once came up at 100 Mb/s with ten cameras).
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';
import { clockLine, driveFacts, driveHealthCardFor, slowLinkWarning } from '../web/js/screens/drive-health-card.js';

let browser;
before(() => { browser = installFakeBrowser(); });
after(() => browser?.restore());

const text = (node) => (node.childNodes ?? []).map((child) => (child.tagName ? text(child) : child.data ?? child.textContent ?? '')).join('');
const NOW = Date.UTC(2026, 9, 31, 12, 0);

test('a cable below a gigabit is a warning; a gigabit, Wi-Fi or an unknown speed is not', () => {
  assert.equal(slowLinkWarning({ interface: 'enp1s0', wired: true, speedMbps: 100, duplex: 'full' }),
    'The network cable is connected at 100 Mb/s instead of 1 Gb/s. Try another cable or switch port: with many cameras the box can run out of room.');
  assert.equal(slowLinkWarning({ interface: 'enp1s0', wired: true, speedMbps: 1000 }), null);
  assert.equal(slowLinkWarning({ interface: 'enp1s0', wired: true, speedMbps: 2500 }), null);
  assert.equal(slowLinkWarning({ interface: 'wlan0', wired: false, speedMbps: null }), null);
  assert.equal(slowLinkWarning({ interface: 'enp1s0', wired: true, speedMbps: null }), null);
  assert.equal(slowLinkWarning(null), null);
});

test('the clock says whether it follows a time server', () => {
  assert.match(clockLine({ synchronized: true, source: '192.0.2.10', lastSync: NOW - 120_000 }, NOW), /^The clock is in sync with 192\.0\.2\.10, checked 2 minutes ago\.$/);
  assert.match(clockLine({ synchronized: false }, NOW), /^The clock is not in sync/);
  assert.equal(clockLine(null, NOW), null);
});

test('a drive in a few words', () => {
  assert.equal(driveFacts({ percentUsed: 12, temperatureCelsius: 41, powerOnHours: 4800 }), '12% of its rated life used · 41 °C · 200 days powered on');
  assert.equal(driveFacts({}), '');
});

test('the card lists each drive with its state and says why one needs attention', () => {
  const card = driveHealthCardFor({
    driveHealth: { state: 'warning', message: 'The recording drive needs attention.', checked: NOW - 3_600_000, drives: [
      { role: 'system', name: 'nvme0n1', model: 'Fast NVMe', state: 'ok', message: 'Healthy, 12% of its rated life used.', percentUsed: 12 },
      { role: 'recording', name: 'sdb', model: 'Portable SSD', state: 'warning', message: 'It has used 93% of its rated life. Plan to replace it.', percentUsed: 93 },
      { role: 'archive', name: 'sdc', state: 'unknown', message: 'This drive does not report its health (many USB enclosures do not).' }] },
    clock: { synchronized: true, source: '192.0.2.10' },
    networkLink: { interface: 'enp1s0', wired: true, speedMbps: 100, duplex: 'full' },
  }, { now: NOW });
  const words = text(card);
  assert.match(words, /Box health/);
  assert.match(words, /This box’s diskHealthy Fast NVMe/);
  assert.match(words, /Recording driveNeeds attention Portable SSDIt has used 93% of its rated life\. Plan to replace it\./);
  assert.match(words, /Archive driveNot reported/);
  assert.match(words, /connected at 100 Mb\/s instead of 1 Gb\/s/);
  assert.match(words, /Drives checked 1 hour ago\./);
  assert.match(words, /The clock is in sync with 192\.0\.2\.10\./);
  assert.ok(!words.includes('Healthy, 12%'), 'a healthy drive shows no sentence, only its facts');
});

test('no card where the system reports nothing (a plain program)', () => {
  assert.equal(driveHealthCardFor({ mode: 'development' }), null);
  assert.equal(driveHealthCardFor(null), null);
});
