// Starts the dev archive server inside a test (port 0, quick timers) and gives the test a signed-in client.

import { createDevServer } from '../../web-dev/lib/server.mjs';
import { fixtureSet, FIXTURE_DIR, WEB_ROOT } from './fixtures.mjs';

export const PASSWORD = 'a-test-password-1';

/** A client with a cookie jar of one: `get`, `patch`, `post`, `send` return { status, headers, json, text, buffer }. */
export function client(base) {
  const state = { cookie: null, csrf: null };
  const send = async (method, path, { body, headers = {}, auth = true, csrf = true, absolute = false, type = 'application/json' } = {}) => {
    const all = { ...headers };
    if (auth && state.cookie) all.Cookie = state.cookie;
    if (auth && csrf && state.csrf && method !== 'GET' && method !== 'HEAD') all['X-CSRF-Token'] = state.csrf;
    let payload;
    if (body !== undefined) { all['Content-Type'] = type; payload = typeof body === 'string' ? body : JSON.stringify(body); }
    const response = await fetch(`${base}${absolute ? path : `/api/v1/${path}`}`, { method, headers: all, body: payload, redirect: 'manual' });
    const buffer = Buffer.from(await response.arrayBuffer());
    const text = buffer.toString('utf8');
    let json = null;
    try { json = JSON.parse(text); } catch { /* not JSON */ }
    return { status: response.status, headers: Object.fromEntries(response.headers), json, text, buffer, raw: response };
  };
  const api = {
    send,
    get: (path, options) => send('GET', path, options),
    patch: (path, body, options) => send('PATCH', path, { body, ...options }),
    post: (path, body, options) => send('POST', path, { body, ...options }),
    async signIn(password = PASSWORD) {
      const response = await send('POST', 'auth/login', { body: { password }, auth: false });
      if (response.status === 200) {
        state.cookie = response.headers['set-cookie'].split(';')[0];
        state.csrf = response.json.csrfToken;
      }
      return response;
    },
    get cookie() { return state.cookie; },
    get csrf() { return state.csrf; },
    dev: (path, body) => send(body === undefined ? 'GET' : 'POST', `/__dev/${path}`, { body, auth: false, absolute: true }),
  };
  return api;
}

/** `{ dev, base, api, close }`: a running server and a client signed in to it. Options override the quick defaults. */
export async function startDevServer(options = {}) {
  const dev = createDevServer({
    webRoot: WEB_ROOT, fixtureDir: FIXTURE_DIR, fixtures: fixtureSet(), port: 0, password: PASSWORD, eventIntervalMs: 50, stallReadMs: 150, stallFolderMs: 150,
    optimizeMs: 30, loadingMs: 250, ...options,
  });
  const address = await dev.listen();
  dev.server.unref(); // a test file whose tests were all filtered out must still be able to end
  const base = `http://127.0.0.1:${address.port}`;
  const api = client(base);
  const signedIn = await api.signIn();
  if (signedIn.status !== 200) throw new Error(`the test server refused the sign-in (${signedIn.status})`);
  return { dev, base, api, close: () => dev.close() };
}
