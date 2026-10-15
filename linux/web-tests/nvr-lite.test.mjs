import test from 'node:test';
import assert from 'node:assert/strict';
import { createLoader, hasNVR, nvrSupported, RETRY_AFTER_MS } from '../web/js/nvr/lite.js';

test('hasNVR is true only when Record is on', () => {
  assert.equal(hasNVR({ nvrEnabled: true }), true);
  assert.equal(hasNVR({ nvrEnabled: false }), false);
  assert.equal(hasNVR({}), false);
  assert.equal(hasNVR(undefined), false);
});

test('nvrSupported tells a bridge that records from one that is too old to', () => {
  assert.equal(nvrSupported({ nvrEnabled: false }), true);
  assert.equal(nvrSupported({ nvrEnabled: true }), true);
  assert.equal(nvrSupported({ id: 'x' }), false);
  assert.equal(nvrSupported(null), false);
});

test('the module is imported once, however many callers ask', async () => {
  let calls = 0;
  const load = createLoader(async () => { calls += 1; return { name: 'ui' }; });
  const [a, b] = await Promise.all([load(), load()]);
  assert.equal(a, b);
  assert.equal(await load(), a);
  assert.equal(calls, 1);
});

test('a failed import resolves null and is logged once; it is tried again only after the retry delay', async () => {
  let clock = 1000;
  const logged = [];
  let calls = 0;
  let broken = true;
  const load = createLoader(async () => { calls += 1; if (broken) throw new Error('syntax'); return { name: 'ui' }; }, { now: () => clock, log: (...args) => logged.push(args) });
  assert.equal(await load(), null);
  assert.equal(await load(), null);       // still inside the delay: no second import
  assert.equal(calls, 1);
  clock += RETRY_AFTER_MS - 1;
  assert.equal(await load(), null);
  assert.equal(calls, 1);
  clock += 1;
  assert.equal(await load(), null);       // retried, still broken
  assert.equal(calls, 2);
  assert.equal(logged.length, 1, 'the failure is logged once');
  broken = false;
  clock += RETRY_AFTER_MS;
  assert.deepEqual(await load(), { name: 'ui' });
  assert.equal(calls, 3);
  assert.deepEqual(await load(), { name: 'ui' });
  assert.equal(calls, 3);
});

test('an importer that throws at once (not a rejected promise) is also a null', async () => {
  const load = createLoader(() => { throw new Error('boom'); }, { log: () => {} });
  assert.equal(await load(), null);
});
