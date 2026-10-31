// The Monitor's pan/tilt pad (live/pan-tilt.js): while an arrow is held, the next step goes out only after the bridge answered the last one
// (a slow camera gets no pile of moves that keep it turning after the arrow is let go), at most every 500 ms; the stop goes out at once on release.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';

let browser;
let createPanTiltPad;
before(async () => {
  browser = installFakeBrowser();
  ({ createPanTiltPad } = await import('../web/js/live/pan-tilt.js'));
});
after(() => browser?.restore());

function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}

function harness() {
  const sent = [];
  let clock = 0;
  const timers = new Map();
  let next = 1;
  const pad = createPanTiltPad({
    send: (id, body) => new Promise((resolve, reject) => sent.push({ id, body, resolve, reject })),
    setTimer: (fn, ms) => { const t = next++; timers.set(t, { at: clock + ms, fn }); return t; },
    clearTimer: (t) => timers.delete(t),
    now: () => clock,
  });
  pad.setCamera('CAM', {});
  const button = (label) => all(pad.el, (node) => node.localName === 'button' && node.getAttribute('aria-label') === label)[0];
  const settle = async () => { for (let i = 0; i < 10; i += 1) await Promise.resolve(); };
  return {
    pad, sent, button, settle,
    async advance(ms) {
      const until = clock + ms;
      for (;;) {
        const due = [...timers.entries()].filter(([, t]) => t.at <= until).sort((a, b) => a[1].at - b[1].at)[0];
        if (!due) break;
        clock = due[1].at;
        timers.delete(due[0]);
        due[1].fn();
        await settle();
      }
      clock = until;
      await settle();
    },
    down: (b) => b.dispatchEvent({ type: 'pointerdown', pointerId: 1, preventDefault() {} }),
    up: (b) => b.dispatchEvent({ type: 'pointerup', pointerId: 1 }),
  };
}

test('a held arrow sends the next step only after the last was answered, and the stop at once on release', async () => {
  const t = harness();
  const left = t.button('Pan left');
  t.down(left);
  await t.settle();
  assert.equal(t.sent.length, 1);
  assert.deepEqual(t.sent[0].body, { pan: -0.6, tilt: 0 });
  await t.advance(3000);
  assert.equal(t.sent.length, 1, 'a slow camera: no pile of steps while the first waits');
  t.sent[0].resolve();
  await t.settle();
  assert.equal(t.sent.length, 2, 'answered after more than 500 ms: the next step at once');
  await t.advance(100);
  t.sent[1].resolve();
  await t.settle();
  assert.equal(t.sent.length, 2, 'a quick answer: the next step waits for the rest of the 500 ms');
  await t.advance(399);
  assert.equal(t.sent.length, 2);
  await t.advance(1);
  assert.equal(t.sent.length, 3);
  t.up(left);
  await t.settle();
  assert.equal(t.sent.length, 4, 'the stop does not wait for the step in flight');
  assert.deepEqual(t.sent[3].body, { pan: 0, tilt: 0 });
  t.sent[2].resolve();
  await t.advance(5000);
  assert.equal(t.sent.length, 4, 'and nothing after it');
  t.pad.destroy();
});

test('a refused step lets go of the arrow and says why', async () => {
  const t = harness();
  const up = t.button('Tilt up');
  t.down(up);
  await t.settle();
  t.sent[0].reject(new Error('The camera didn’t answer.'));
  await t.settle();
  assert.equal(up.getAttribute('aria-pressed'), 'false');
  assert.match(t.pad.el.textContent, /The camera didn’t answer\./);
  assert.deepEqual(t.sent.at(-1).body, { pan: 0, tilt: 0 }, 'a stop after it');
  await t.advance(5000);
  assert.equal(t.sent.length, 2, 'no more steps');
  t.pad.destroy();
});
