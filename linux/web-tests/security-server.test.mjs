// The security levels on the dev server (web-dev/lib/camera-security.mjs): status.security as the bridge words it, every key there
// (the Internet guard's too), one camera per level and one watched camera that keeps trying, and POST cameras/:id/security/check with
// the bridge's answers (200 with the level, 429 within a minute with Retry-After, 409 for a camera turned off, 422 for one the dev server
// has no level for, 404 for an unknown one). "Watch its internet" is a step of the fake setup.

import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { CAMERA_DEFINITIONS } from '../web-dev/lib/cameras.mjs';
import { startDevServer } from './support/dev-server.mjs';
import { ensureFixtures } from './support/fixtures.mjs';

const fixtures = ensureFixtures();
const opts = { skip: fixtures.skip };
const camera = (name) => CAMERA_DEFINITIONS.find((definition) => definition.name === name).id;
let server;

before(async () => { if (!fixtures.skip) server = await startDevServer(); });
after(async () => { await server?.close(); });
const reset = () => server.api.dev('reset', {});
const KEYS = ['level', 'title', 'summary', 'checkedAt', 'findings', 'guard'];
const FINDING_KEYS = ['feature', 'state', 'level', 'sentence', 'canChange', 'linked', 'service'];

test('status.security: one camera per level and one watched camera that keeps trying, with every key; the others have none', opts, async () => {
  await reset();
  const { cameras } = (await server.api.get('cameras')).json;
  const byName = Object.fromEntries(cameras.map((entry) => [entry.name, entry.status.security]));
  assert.deepEqual(Object.entries(byName).filter(([, security]) => security).map(([name, security]) => [name, security.level]),
    [['Front Door', 'red'], ['Driveway', 'yellow'], ['Garage', 'green'], ['Back Yard', 'gold'], ['Living Room', 'yellow']]);
  for (const [name, security] of Object.entries(byName)) {
    if (!security) continue;
    assert.deepEqual(Object.keys(security).sort(), [...KEYS].sort(), `${name}: every key is there`);
    for (const entry of security.findings) assert.deepEqual(Object.keys(entry).sort(), [...FINDING_KEYS].sort());
    assert.deepEqual(Object.keys(security.guard).sort(), ['last24h', 'names', 'today', 'watched']);
    for (const entry of security.guard.names) assert.deepEqual(Object.keys(entry).sort(), ['count', 'last', 'name']);
  }
  const trying = byName['Living Room'];
  assert.equal(trying.guard.watched, true);
  assert.ok(trying.guard.today > 0 && trying.guard.last24h >= trying.guard.today);
  assert.ok(trying.guard.names.length >= 3);
  assert.ok(trying.guard.names.every((entry) => /(^|\.)example\.(com|net|org)$/.test(entry.name)), 'documentation names only');
  assert.equal(trying.findings.find((entry) => entry.feature === 'internetGuard').level, 'yellow');
  assert.equal(byName.Garage.guard.watched, false);
  assert.equal(byName['Back Yard'].guard.watched, true);
  assert.equal(byName['Back Yard'].guard.last24h, 0);
});

test('POST security/check answers the level checked now, then 429 with Retry-After within a minute', opts, async () => {
  await reset();
  const path = `cameras/${camera('Garage')}/security/check`;
  const before = Date.now();
  const first = await server.api.post(path, {});
  assert.equal(first.status, 200);
  assert.equal(first.json.level, 'green');
  assert.ok(Date.parse(first.json.checkedAt) >= before - 1000, 'checked now');
  const read = (await server.api.get(`cameras/${camera('Garage')}`)).json.status.security;
  assert.equal(read.checkedAt, first.json.checkedAt, 'the camera keeps the new time');
  const again = await server.api.post(path, {});
  assert.deepEqual([again.status, again.json.error], [429, 'security_check_too_soon']);
  assert.match(again.headers['retry-after'], /^\d+$/);
  assert.ok(Number(again.headers['retry-after']) >= 1 && Number(again.headers['retry-after']) <= 60);
});

test('POST security/check refuses as the bridge does: 422 for a camera it has no level for, 409 turned off, 404 unknown or malformed', opts, async () => {
  await reset();
  const plain = await server.api.post(`cameras/${camera('Porch')}/security/check`, {});
  assert.deepEqual([plain.status, plain.json.error], [422, 'security_check_unavailable']);
  assert.equal((await server.api.patch(`cameras/${camera('Back Yard')}`, { isEnabled: false })).status, 200);
  const off = await server.api.post(`cameras/${camera('Back Yard')}/security/check`, {});
  assert.deepEqual([off.status, off.json.error], [409, 'camera_offline'], 'a camera turned off');
  assert.equal((await server.api.post('cameras/0A1B2C3D-0000-4000-8000-0000000000FF/security/check', {})).status, 404);
  assert.equal((await server.api.post('cameras/not-a-uuid/security/check', {})).status, 404);
  assert.equal((await server.api.post(`cameras/${camera('Garage')}/security/check`, {}, { auth: false })).status, 401);
});

test('the fake setup has “Watch its internet” last, after the cloud, as the bridge does, and applying it marks it done', opts, async () => {
  await reset();
  const id = camera('Garage');
  const preview = (await server.api.get(`cameras/${id}/setup`)).json;
  const ids = preview.steps.map((step) => step.id);
  assert.equal(ids.at(-1), 'internetWatch');
  assert.ok(ids.indexOf('cloud') < ids.indexOf('internetWatch'));
  const watch = preview.steps.find((step) => step.id === 'internetWatch');
  assert.deepEqual([watch.title, watch.status], ['Watch its internet', 'willChange']);
  assert.match(watch.changes[0].after, /^the bridge \(192\.0\.2\.\d+\)$/);
  const applied = (await server.api.post(`cameras/${id}/setup`, { confirm: true })).json;
  assert.equal(applied.steps.find((step) => step.id === 'internetWatch').status, 'done');
  const read = (await server.api.get(`cameras/${id}`)).json;
  assert.equal(read.setupState.steps.find((step) => step.id === 'internetWatch').status, 'done');
});
