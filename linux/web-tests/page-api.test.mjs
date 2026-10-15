// The page's own api.js against the dev server: sign in, the CSRF token on changes, ApiError for the NVR's error codes, the 'unauthorized'
// signal. api.js is imported as the page imports it, in a fake browser whose fetch talks to a real server.

import assert from 'node:assert/strict';
import { join } from 'node:path';
import { after, before, test } from 'node:test';
import { pathToFileURL } from 'node:url';
import { CAMERA_DEFINITIONS } from '../web-dev/lib/cameras.mjs';
import { cookieFetch } from './support/cookie-fetch.mjs';
import { PASSWORD, startDevServer } from './support/dev-server.mjs';
import { ensureFixtures, WEB_ROOT } from './support/fixtures.mjs';
import { installFakeBrowser } from './support/fake-browser.mjs';

const fixtures = ensureFixtures();
const opts = { skip: fixtures.skip };
let server;
let browser;
let page;
let fetcher;

before(async () => {
  if (fixtures.skip) return;
  server = await startDevServer();
  browser = installFakeBrowser();
  fetcher = cookieFetch(server.base);
  globalThis.fetch = fetcher;
  page = await import(pathToFileURL(join(WEB_ROOT, 'js/api.js')).href);
});
after(async () => { browser?.restore(); await server?.close(); });

test('api.js signs in, carries the CSRF token on changes and reads the NVR resources', opts, async () => {
  const session = await page.get('session');
  assert.equal(session.authenticated, false);
  const signedIn = await page.post('auth/login', { password: PASSWORD });
  page.setCSRFToken(signedIn.csrfToken);
  const storage = await page.get('nvr/storage');
  assert.equal(storage.state, 'ok');
  const changed = await page.patch('nvr/storage', { keepDays: storage.keepDays });
  assert.equal(changed.keepDays, storage.keepDays);
  const { cameras } = await page.get('cameras');
  assert.equal(cameras.length, 9);
});

test('api.js turns the NVR error codes into ApiError with status, code and field', opts, async () => {
  const bad = await page.patch('nvr/storage', { keepDays: 0 }).catch((error) => error);
  assert.ok(bad instanceof page.ApiError);
  assert.deepEqual([bad.status, bad.code, bad.field], [400, 'invalid', 'keepDays']);
  await server.api.dev('scenario', { name: 'noFolder' });
  const shed = CAMERA_DEFINITIONS.find((definition) => definition.name === 'Shed').id;
  const refused = await page.patch(`cameras/${shed}/nvr`, { enabled: true }).catch((error) => error);
  assert.deepEqual([refused.status, refused.code], [409, 'folder_required']);
  assert.equal(refused.message, 'Choose where to store recordings first.');
  await server.api.dev('scenario', { name: 'ok' });
});

test('api.js tells the page when the session is gone', opts, async () => {
  const signals = [];
  const stop = page.onAuthChange((kind) => signals.push(kind));
  fetcher.signOut();
  const error = await page.get('nvr/storage').catch((failure) => failure);
  stop();
  assert.deepEqual([error.status, error.code], [401, 'unauthorized']);
  assert.deepEqual(signals, ['unauthorized']);
});
