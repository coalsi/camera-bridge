// The notification routes on the dev server (web-dev/lib/notifications.mjs; the bridge's: WebApp+Notifications.swift): the log lists the
// Internet guard's first try once, a toast is handed out once, the read marker counts, and a storage notice that goes away and comes back
// is a new entry.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { startDevServer } from './support/dev-server.mjs';
import { ensureFixtures } from './support/fixtures.mjs';

const fixtures = ensureFixtures();
const opts = { skip: fixtures.skip };
let server;
before(async () => { if (!fixtures.skip) server = await startDevServer(); });
after(async () => { await server?.close(); });
const reset = (scenario = 'ok') => server.api.dev('reset', { scenario });

test('the guard’s first try is one entry, in the Security section, and no daily notice is raised', opts, async () => {
  await reset();
  const { json } = await server.api.get('notifications');
  const tried = json.notifications.filter((entry) => entry.kind === 'internetGuard');
  assert.equal(tried.length, 1);
  assert.deepEqual([tried[0].title, tried[0].detail, tried[0].category, tried[0].action], ['Living Room tried to reach the internet', 'Camera Bridge blocked it. Nothing got out.', 'security', 'open-camera']);
  assert.equal((await server.api.get('notifications')).json.notifications.length, json.notifications.length, 'asking again adds nothing');
  const status = (await server.api.get('status')).json;
  assert.ok(status.notices.every((notice) => notice.id !== 'internet-guard'), 'no daily notice');
});

test('a toast is handed out once; reading counts down; mark all read clears', opts, async () => {
  await reset();
  const first = (await server.api.post('notifications/shown')).json;
  assert.equal(first.shown.length, 1);
  assert.equal(first.unread, 1);
  assert.equal((await server.api.post('notifications/shown')).json.shown.length, 0, 'not again');
  const [entry] = (await server.api.get('notifications')).json.notifications;
  assert.equal(entry.toasted, true);
  assert.equal((await server.api.post('notifications/read', { ids: [entry.id] })).json.unread, 0);
  assert.equal((await server.api.get('notifications')).json.notifications[0].read, true);
  assert.equal((await server.api.post('notifications/read', {})).json.unread, 0);
});

test('a storage notice is an entry when it appears, once while it stays, and again when it comes back', opts, async () => {
  await reset();
  const count = async () => (await server.api.get('notifications')).json.notifications.filter((entry) => entry.kind === 'nvrStorage').length;
  assert.equal(await count(), 0);
  await server.api.dev('scenario', { name: 'diskFull' });
  assert.equal(await count(), 1, 'Recording Can’t Continue');
  assert.equal(await count(), 1, 'the same notice is not another entry');
  await server.api.dev('scenario', { name: 'ok' });
  assert.equal(await count(), 1, 'it went away: the entry stays readable');
  await server.api.dev('scenario', { name: 'diskFull' });
  assert.equal(await count(), 2, 'it came back: it happened again');
});
