// The secure address routes on the dev server (web-dev/lib/server.mjs; the bridge's: WebApp+SecureAddress.swift).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { startDevServer } from './support/dev-server.mjs';
import { ensureFixtures } from './support/fixtures.mjs';

const HOST = 'k7f2q9.box.camera-bridge.app';


const fixtures = ensureFixtures();

test('the dev server answers the secure address routes like the bridge', { skip: fixtures.skip }, async () => {
  const server = await startDevServer();
  try {
    assert.equal((await server.api.get('system/secure-address', { auth: false })).status, 401);
    const report = (await server.api.get('system/secure-address')).json;
    assert.deepEqual([report.available, report.state, report.url, report.redirect, report.redirectActive], [true, 'ready', `https://${HOST}`, true, true]);
    assert.ok(Date.parse(report.renewsOn) < Date.parse(report.expiresOn));
    assert.equal((await server.api.post('system/secure-address/redirect', { enabled: false })).json.redirectActive, false);
    assert.equal((await server.api.post('system/secure-address/redirect', {})).status, 400);
    assert.equal((await server.api.post('system/secure-address/check', {})).json.rebind.state, 'ok');
    await server.api.dev('secure', { router: 'blocked', state: 'error' });
    assert.equal((await server.api.post('system/secure-address/check', {})).json.rebind.state, 'blocked');
    assert.equal((await server.api.get('system/secure-address')).json.problem.code, 'no_internet');
  } finally {
    await server.close();
  }
});
