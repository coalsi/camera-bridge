// The "Add to Apple Home" panel (screens/pairing.js): one failed request does not stop it. It says what went wrong, asks again after 5 s, and
// shows the code (and later "Added to Apple Home") when the bridge answers.
import assert from 'node:assert/strict';
import { after, before, mock, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';

let browser;
let pairingPanel;
before(async () => {
  browser = installFakeBrowser();
  ({ pairingPanel } = await import('../web/js/screens/pairing.js'));
});
after(() => browser?.restore());

const reply = (status, data) => ({
  status, ok: status < 400, json: async () => data, text: async () => JSON.stringify(data),
  headers: { get: (name) => (name.toLowerCase() === 'content-type' ? 'application/json' : null) },
});

test('a failed request shows its sentence and the panel asks again by itself', async () => {
  mock.timers.enable({ apis: ['setTimeout'] });
  const answers = [
    () => { throw new TypeError('fetch failed'); },
    () => reply(200, { paired: false, setupCode: '123-45-678', qrSVG: '<svg/>' }),
    () => reply(200, { paired: true, accessoryName: 'Porch' }),
  ];
  let asked = 0;
  globalThis.fetch = async () => answers[Math.min(asked++, answers.length - 1)]();
  const settle = async () => { for (let i = 0; i < 10; i += 1) await new Promise((resolve) => setImmediate(resolve)); };
  const paired = [];
  const panel = pairingPanel({ cameraId: 'CAM', cameraName: 'Porch', onPaired: () => paired.push(true) });
  try {
    await settle();
    assert.match(panel.el.textContent, /The bridge didn’t answer/);
    assert.match(panel.el.textContent, /Trying again…/);
    mock.timers.tick(5000);
    await settle();
    assert.equal(asked, 2, 'asked again after 5 s');
    assert.match(panel.el.textContent, /123-45-678/);
    mock.timers.tick(4000);
    await settle();
    assert.match(panel.el.textContent, /Added to Apple Home/);
    assert.deepEqual(paired, [true]);
  } finally {
    panel.destroy();
    mock.timers.reset();
  }
});
