#!/usr/bin/env node
// Checks that a server answers the NVR API of docs/superpowers/plans/2026-10-10-nvr/T00-contracts.md Part C (and the shapes the page
// relies on) the way the contract says: the dev archive server, the Mac dev daemon over the LAN, or the box.
//
//   CB_PASSWORD=... node linux/web-dev/conformance.mjs http://127.0.0.1:8090 [--mutate] [--intrusive] [--all] [--no-burst] [--only TEXT]
//
// The password is read from CB_PASSWORD, sent only in the sign-in body, and never printed (anything that looks like it, the session
// cookie or the anti-forgery token is replaced by [secret] in every line this tool writes). By default it only reads, plus requests the
// server must refuse. --mutate adds writes that change nothing (the current value again) and invalid input; --intrusive adds a wrong
// password and a burst of 40 requests (those can lock you out or load a real box); --no-burst leaves the burst out and says so, for a
// caller that runs it another way (a port forward that resets connections arriving together cannot carry it; everything else here asks
// one thing at a time). Exit status 0 when nothing failed.

import http from 'node:http';
import https from 'node:https';
import { pathToFileURL } from 'node:url';
import { child, children, parseFragment, parseInit, readBoxes } from './lib/mp4.mjs';
import { CSP, SECURITY_HEADERS } from './lib/security.mjs';

const UUID = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/;
const FRAGMENT_ID = /^[0-9a-f]{12}\.(0|[1-9][0-9]{0,6})$/;
const STATES = ['off', 'waiting', 'recording', 'paused'];
const PAUSES = ['noFolder', 'folderMissing', 'diskFull', 'notWritable'];
const NIGHT_MODES = ['auto', 'on', 'off'];
const UNKNOWN_CAMERA = 'FFFFFFFF-0000-4000-8000-000000000000';
const GIB = 1_073_741_824;
const GB = 1_000_000_000;

class Failure extends Error {}
const show = (value) => (typeof value === 'string' ? JSON.stringify(value) : JSON.stringify(value) ?? String(value));
const ok = (condition, message) => { if (!condition) throw new Failure(message); };
const same = (actual, expected, label) => ok(Object.is(actual, expected) || show(actual) === show(expected), `${label}: expected ${show(expected)}, got ${show(actual)}`);
const isInt = (value) => Number.isInteger(value);
/** The contract names the keys of an object; a key that is missing fails, a key the contract does not know is not this tool's business. */
const hasKeys = (object, keys, label) => ok(object && typeof object === 'object' && keys.every((key) => key in object), `${label}: expected the keys ${keys.join(', ')}, got ${show(object && typeof object === 'object' ? Object.keys(object) : object)}`);
const isNumber = (value) => typeof value === 'number' && Number.isFinite(value);
/** `count` well-formed camera ids that belong to no camera (the contract's limit of 16 is about ids, not about cameras that exist). */
const otherIds = (count) => Array.from({ length: count }, (_, index) => `00000000-0000-4000-8000-${String(index + 1).padStart(12, '0')}`);

// ---- the client ---------------------------------------------------------------------------------------------------------------------

function makeClient(baseUrl, secrets) {
  const base = new URL(baseUrl);
  const transport = base.protocol === 'https:' ? https : http;
  const client = { cookie: null, csrf: null, seen: [] };

  client.send = (method, path, { headers = {}, body, auth = true, csrf = true, origin, type = 'application/json', absolute = false, timeoutMs = 20_000 } = {}) => new Promise((resolve, reject) => {
    const all = { Accept: '*/*', ...headers };
    if (auth && client.cookie) all.Cookie = client.cookie;
    if (method !== 'GET' && method !== 'HEAD' && auth && csrf && client.csrf) all['X-CSRF-Token'] = client.csrf;
    if (origin !== undefined) all.Origin = origin;
    let payload = null;
    if (body !== undefined) {
      payload = Buffer.from(typeof body === 'string' ? body : JSON.stringify(body));
      all['Content-Type'] = type;
      all['Content-Length'] = payload.length;
    }
    const request = transport.request({ protocol: base.protocol, hostname: base.hostname, port: base.port, method, path: absolute ? path : `/api/v1/${path}`, headers: all, agent: false }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => {
        const buffer = Buffer.concat(chunks);
        const result = {
          status: response.statusCode,
          headers: response.headers,
          buffer,
          text: buffer.toString('utf8'),
          get json() { try { return JSON.parse(buffer.toString('utf8')); } catch { return null; } },
        };
        if (result.status >= 400) client.seen.push({ method, path, text: result.text, headers: JSON.stringify(result.headers) });
        resolve(result);
      });
    });
    request.setTimeout(timeoutMs, () => request.destroy(new Error(`no answer within ${timeoutMs} ms`)));
    request.on('error', (error) => reject(new Failure(`${method} ${redact(path, secrets)}: ${error.message}`)));
    if (payload) request.write(payload);
    request.end();
  });
  client.get = (path, options) => client.send('GET', path, options);
  client.patch = (path, body, options) => client.send('PATCH', path, { body, ...options });
  client.post = (path, body, options) => client.send('POST', path, { body, ...options });
  return client;
}

const redact = (text, secrets) => [...secrets].filter(Boolean).reduce((result, secret) => result.split(secret).join('[secret]'), String(text));

// ---- the checks ----------------------------------------------------------------------------------------------------------------------

/**
 * Runs every check. `report(status, name, detail)` is called as each finishes ('ok', 'FAIL' or 'skip'). Returns { passed, failed, skipped }.
 */
export async function runConformance({ baseUrl, password, mutate = false, intrusive = false, burst = true, only = '', report = () => {} }) {
  const secrets = new Set([password]);
  const client = makeClient(baseUrl, secrets);
  const counts = { passed: 0, failed: 0, skipped: 0 };
  const facts = {}; // what earlier checks found, for later ones

  const check = async (name, work) => {
    if (only && !name.toLowerCase().includes(only.toLowerCase())) return;
    try {
      const skipped = await work();
      if (typeof skipped === 'string') { counts.skipped += 1; report('skip', name, skipped); } else { counts.passed += 1; report('ok', name, ''); }
    } catch (error) {
      counts.failed += 1;
      report('FAIL', name, redact(error instanceof Failure ? error.message : `${error.name}: ${error.message}`, secrets));
    }
  };

  // -- A. headers and the unauthenticated surface
  await check('headers: the page is served with the security headers, the CSP exactly', async () => {
    const page = await client.get('/', { absolute: true, auth: false });
    same(page.status, 200, 'GET /');
    ok(String(page.headers['content-type']).startsWith('text/html'), `GET / has the content type ${page.headers['content-type']}`);
    for (const [name, value] of Object.entries(SECURITY_HEADERS)) same(page.headers[name.toLowerCase()], value, `header ${name}`);
    same(page.headers['content-security-policy'], CSP, 'the Content-Security-Policy');
    ok(!/unsafe-(inline|eval)/.test(page.headers['content-security-policy']), 'the CSP allows unsafe-inline or unsafe-eval');
  });
  await check('headers: an API answer carries them too, and is never cached', async () => {
    const health = await client.get('health', { auth: false });
    same(health.status, 200, 'GET health');
    same(health.headers['content-security-policy'], CSP, 'the Content-Security-Policy on an API answer');
    same(health.headers['cache-control'], 'no-store', 'Cache-Control');
  });
  await check('session: nobody is signed in before the sign-in', async () => {
    const session = await client.get('session', { auth: false });
    same(session.status, 200, 'GET session');
    same(session.json.authenticated, false, 'authenticated');
    ok(session.json.csrfToken === null || session.json.csrfToken === undefined, 'a signed-out session shows a CSRF token');
  });

  // -- B. sign-in
  if (intrusive) {
    await check('sign-in: a wrong password is 401 wrong_password', async () => {
      const response = await client.post('auth/login', { password: `${password}-wrong` }, { auth: false });
      same(response.status, 401, 'status');
      same(response.json.error, 'wrong_password', 'error code');
    });
  }
  await check('sign-in: the right password gives a cookie (HttpOnly, SameSite=Strict) and a CSRF token', async () => {
    ok(password, 'CB_PASSWORD is not set');
    const response = await client.post('auth/login', { password }, { auth: false });
    same(response.status, 200, 'status');
    ok(typeof response.json.csrfToken === 'string' && response.json.csrfToken.length >= 16, 'no csrfToken');
    const cookie = [].concat(response.headers['set-cookie'] ?? []).find((line) => line.startsWith('cb_session='));
    ok(cookie, 'no cb_session cookie');
    ok(/;\s*HttpOnly/i.test(cookie) && /;\s*SameSite=Strict/i.test(cookie) && /;\s*Path=\//i.test(cookie), 'the cookie lacks HttpOnly, SameSite=Strict or Path=/');
    client.cookie = cookie.split(';')[0];
    client.csrf = response.json.csrfToken;
    secrets.add(client.cookie.split('=')[1]);
    secrets.add(client.csrf);
    const session = await client.get('session');
    same(session.json.authenticated, true, 'authenticated after sign-in');
    same(session.json.csrfToken, client.csrf, 'the session CSRF token');
  });
  if (!client.cookie) return { ...counts, aborted: 'could not sign in' };

  // -- C. the existing resources the NVR changes
  let cameras = [];
  await check('cameras: each carries nvrEnabled, nvrRecordSound and a coherent status.nvr', async () => {
    const response = await client.get('cameras');
    same(response.status, 200, 'GET cameras');
    cameras = response.json.cameras;
    ok(Array.isArray(cameras), 'cameras is not a list');
    for (const camera of cameras) {
      ok(UUID.test(camera.id), `camera id ${camera.id}`);
      same(typeof camera.nvrEnabled, 'boolean', `${camera.id} nvrEnabled`);
      same(typeof camera.nvrRecordSound, 'boolean', `${camera.id} nvrRecordSound`);
      const nvr = camera.status?.nvr;
      ok(nvr, `${camera.name} has no status.nvr`);
      ok(STATES.includes(nvr.state), `state ${nvr.state}`);
      ok(nvr.pause === null || PAUSES.includes(nvr.pause), `pause ${nvr.pause}`);
      ok(nvr.detail === null || typeof nvr.detail === 'string', 'detail');
      ok(Array.isArray(nvr.notes) && nvr.notes.every((note) => ['sound', 'keyframe'].includes(note.id) && typeof note.text === 'string' && note.text), 'notes');
      same(new Set(nvr.notes.map((note) => note.id)).size, nvr.notes.length, 'a note id twice');
      same(nvr.state === 'off', !camera.nvrEnabled, `${camera.name}: state off exactly when Record is off`);
      same(nvr.state === 'paused', nvr.pause !== null, `${camera.name}: a pause exactly when paused`);
      if (nvr.state === 'off' || nvr.state === 'recording') same(nvr.detail, null, `${camera.name}: detail while ${nvr.state}`);
      else ok(nvr.detail, `${camera.name}: a ${nvr.state} camera says why`);
    }
  });

  // Night vision (POST cameras/:id/night-vision): the shape of status.nightVision, and the refusals, which reach no camera (the body is
  // checked before the camera; a camera without night vision is refused before anything is sent to it).
  await check('cameras: status.nightVision, where a camera has it, offers modes of auto, on and off or a light, and says where they are', async () => {
    for (const camera of cameras) {
      const offer = camera.status?.nightVision;
      if (offer === undefined || offer === null) continue;
      ok(Array.isArray(offer.modes) && offer.modes.every((mode) => NIGHT_MODES.includes(mode)), `${camera.name}: modes ${show(offer.modes)}`);
      same(new Set(offer.modes).size, offer.modes.length, `${camera.name}: a mode listed twice`);
      same(typeof offer.light, 'boolean', `${camera.name}: light`);
      ok(offer.modes.length > 0 || offer.light, `${camera.name}: night vision that offers neither a mode nor a light (the key should be left out)`);
      ok(offer.mode === undefined || offer.mode === null || NIGHT_MODES.includes(offer.mode), `${camera.name}: mode ${show(offer.mode)}`);
      ok(offer.lightOn === undefined || offer.lightOn === null || typeof offer.lightOn === 'boolean', `${camera.name}: lightOn ${show(offer.lightOn)}`);
    }
  });
  await check('night vision: bad input is 400 invalid with the field, an unknown camera 404, a camera without it 409 no_night_vision', async () => {
    const path = `cameras/${UNKNOWN_CAMERA}/night-vision`;
    const bad = [['an unknown mode', { mode: 'dusk' }, 'mode'], ['a mode that is not text', { mode: 1 }, 'mode'], ['a light that is not true or false', { light: 'on' }, 'light'],
      ['neither a mode nor a light', {}, 'mode']];
    for (const [label, body, field] of bad) {
      const response = await client.post(path, body);
      same(response.status, 400, label);
      same(response.json?.error, 'invalid', `${label}: error code`);
      same(response.json?.field, field, `${label}: field`);
    }
    same((await client.post(path, { mode: 'auto' })).status, 404, 'an unknown camera');
    same((await client.post('cameras/not-a-uuid/night-vision', { mode: 'auto' })).status, 404, 'a malformed camera id');
    same((await client.post(path, { mode: 'auto' }, { auth: false })).status, 401, 'without the session cookie');
    same((await client.post(path, { mode: 'auto' }, { csrf: false })).json?.error, 'csrf', 'without the CSRF token');
    const without = cameras.find((camera) => !camera.status?.nightVision);
    if (!without) return 'every camera has night vision, so none is refused for lacking it';
    const refused = await client.post(`cameras/${without.id}/night-vision`, { mode: 'auto' });
    same([refused.status, refused.json?.error], [409, 'no_night_vision'], `${without.name}, which has no night vision`);
    ok(typeof refused.json?.message === 'string' && refused.json.message.length > 0, 'the 409 has no sentence');
  });
  // Pan and tilt (POST cameras/:id/pan-tilt): every camera says whether it turns and zooms; only refusals are sent, so nothing moves.
  await check('pan and tilt: status.panTilt and status.zoom are true or false; a step beyond 1 is 400 invalid, an unknown camera 404', async () => {
    for (const camera of cameras) {
      same(typeof camera.status?.panTilt, 'boolean', `${camera.name}: panTilt`);
      same(typeof camera.status?.zoom, 'boolean', `${camera.name}: zoom`);
    }
    const path = `cameras/${UNKNOWN_CAMERA}/pan-tilt`;
    const far = await client.post(path, { pan: 2, tilt: 0 });
    same([far.status, far.json?.error, far.json?.field], [400, 'invalid', 'pan'], 'a pan of 2');
    same((await client.post(path, { pan: 0, tilt: 0 })).status, 404, 'an unknown camera');
    same((await client.post('cameras/not-a-uuid/pan-tilt', { pan: 0, tilt: 0 })).status, 404, 'a malformed camera id');
    same((await client.post(path, { pan: 0, tilt: 0 }, { auth: false })).status, 401, 'without the session cookie');
    same((await client.post(path, { pan: 0, tilt: 0 }, { csrf: false })).json?.error, 'csrf', 'without the CSRF token');
  });

  // -- D. R1 and R2: storage
  let storage = null;
  await check('R1 storage: every key, the formulas and the words', async () => {
    const response = await client.get('nvr/storage');
    same(response.status, 200, 'GET nvr/storage');
    storage = response.json;
    for (const key of ['location', 'label', 'state', 'message', 'recordingCameras', 'keepDays', 'maxSizeGB', 'limits', 'usedBytes', 'freeBytes', 'totalBytes', 'floorBytes', 'roomBytes', 'effectiveMaxBytes', 'oldest', 'newest']) ok(key in storage, `the key ${key} is missing`);
    ok([null, 'builtin', 'other'].includes(storage.location), `location ${storage.location}`);
    ok(['ok', ...PAUSES].includes(storage.state), `state ${storage.state}`);
    same(storage.state === 'ok', storage.message === null, 'a message exactly when something is wrong');
    same(storage.limits, { keepDays: [1, 365], maxSizeGB: [10, 100000] }, 'limits');
    ok(isInt(storage.keepDays) && storage.keepDays >= 1 && storage.keepDays <= 365, 'keepDays out of its range');
    ok(isInt(storage.maxSizeGB) && storage.maxSizeGB >= 10 && storage.maxSizeGB <= 100000, 'maxSizeGB out of its range');
    for (const key of ['usedBytes', 'freeBytes', 'totalBytes', 'floorBytes', 'roomBytes', 'effectiveMaxBytes']) ok(isInt(storage[key]) && storage[key] >= 0, `${key} is not a whole number of bytes`);
    same(storage.usedBytes % 10_000_000, 0, 'usedBytes rounded to 10 MB');
    same(storage.freeBytes % 10_000_000, 0, 'freeBytes rounded to 10 MB');
    same(storage.roomBytes, storage.usedBytes + Math.max(0, storage.freeBytes - storage.floorBytes), 'roomBytes = used + max(0, free - floor)');
    same(storage.effectiveMaxBytes, Math.min(storage.maxSizeGB * GB, Math.max(0, storage.totalBytes - 2 * storage.floorBytes)), 'effectiveMaxBytes = min(max x 1e9, total - 2 x floor)');
    // the system volume's floor is max(8 GiB, 5%) on the box and max(20 GiB, 10%) on a Mac; any other volume's is 2 GiB (T00 B.1, B.4)
    if (storage.totalBytes > 0) ok(storage.floorBytes === 2 * GIB || (storage.floorBytes >= 8 * GIB && storage.floorBytes >= Math.floor(storage.totalBytes / 20)), `the floor ${storage.floorBytes} is neither 2 GiB nor at least max(8 GiB, 5% of the total)`);
    ok((storage.oldest === null) === (storage.newest === null), 'oldest and newest are both set or both null');
    if (storage.oldest !== null) ok(isInt(storage.oldest) && storage.oldest <= storage.newest, 'oldest after newest');
    same(storage.recordingCameras, cameras.filter((camera) => camera.nvrEnabled).length, 'recordingCameras counts the cameras with Record on');
    if (storage.state === 'noFolder') same(storage.location, null, 'no location while no folder is chosen');
    if (storage.location === null) same(storage.state, 'noFolder', 'no location means noFolder');
    if (storage.state === 'noFolder') same(storage.message, 'Choose where to store recordings.', 'the noFolder sentence');
    if (storage.state === 'folderMissing') same(storage.message, 'The recordings folder isn’t available. Reconnect the drive or choose another folder.', 'the folderMissing sentence');
    if (storage.state === 'diskFull') same(storage.message, 'There isn’t enough free space on the recordings drive.', 'the diskFull sentence');
  });
  await check('R2 locations: one entry per place, never a way to send a path', async () => {
    const response = await client.get('nvr/storage/locations');
    same(response.status, 200, 'GET nvr/storage/locations');
    ok(Array.isArray(response.json.locations), 'locations is not a list');
    same(response.json.locations.filter((place) => place.current).length <= 1, true, 'more than one current location');
    for (const place of response.json.locations) {
      for (const key of ['id', 'label', 'path', 'current', 'writable', 'freeBytes', 'totalBytes', 'roomBytes', 'problem', 'warning']) ok(key in place, `the key ${key} is missing`);
      ok(typeof place.id === 'string' && place.id && typeof place.label === 'string' && typeof place.path === 'string', 'id, label or path');
      same(typeof place.writable, 'boolean', 'writable');
      if (!place.current) same(place.roomBytes, null, 'roomBytes of a location that is not current');
      if (!place.writable) { ok(place.problem, 'a location that cannot be written says why'); same(place.freeBytes, null, 'freeBytes of a failed check'); }
      if (place.warning !== null) ok(/^Small drive: room for about \d+ GB$/.test(place.warning), `the warning ${place.warning}`);
      if (storage) same(place.current, storage.location === place.id, 'current agrees with R1');
    }
  });
  await check('notices: the storage banner exists exactly when it should', async () => {
    const response = await client.get('status');
    same(response.status, 200, 'GET status');
    const notices = response.json.notices;
    ok(Array.isArray(notices), 'notices is not a list');
    for (const notice of notices) for (const key of ['id', 'kind', 'severity', 'title', 'detail', 'cameraID', 'cameraName', 'date', 'action']) ok(key in notice, `a notice lacks ${key}`);
    const banner = notices.filter((notice) => notice.id === 'nvr-storage');
    ok(banner.length <= 1, 'more than one storage notice');
    const recording = cameras.some((camera) => camera.nvrEnabled);
    if (!recording) { same(banner.length, 0, 'a storage notice while no camera records'); return; }
    const spare = Math.max(0, storage.freeBytes - storage.floorBytes);
    if (storage.state !== 'ok') {
      same(banner.length, 1, 'a storage notice while recording cannot continue');
      same(banner[0].title, 'Recording Can’t Continue', 'title');
      same(banner[0].detail, storage.message, 'detail');
      same(banner[0].action, storage.state === 'noFolder' ? 'choose-folder' : 'open-settings', 'action');
    } else if (spare < 5 * GIB) {
      same(banner.length, 1, 'a storage notice while space is low');
      same(banner[0].title, 'Recording Storage Almost Full', 'title');
      same(banner[0].detail, `About ${Math.floor(spare / GB)} GB are left before recording pauses.`, 'detail');
    } else {
      same(banner.length, 0, 'a storage notice while all is well');
    }
    if (banner[0]) { same(banner[0].kind, 'nvrStorage', 'kind'); same(banner[0].severity, 'warning', 'severity'); }
  });

  // -- E. access rules on the NVR routes (all of these are refused, so nothing changes)
  const sample = '0A1B2C3D-0000-4000-8000-000000000001';
  const NVR_REQUESTS = [
    ['GET', 'nvr/storage'], ['GET', 'nvr/storage/locations'], ['PATCH', 'nvr/storage', { keepDays: 7 }], ['PATCH', `cameras/${sample}/nvr`, { enabled: true }],
    ['GET', 'nvr/cameras'], ['GET', `nvr/activity?cameras=${sample}&from=1760000000000&binMs=60000&bins=10`], ['GET', `nvr/cameras/${sample}/fragments?at=1760000000000`],
    ['GET', `nvr/events?cameras=${sample}&from=1760000000000&to=1760003600000`],
    ['GET', `nvr/cameras/${sample}/fragments/0123456789ab.1`], ['GET', `nvr/cameras/${sample}/fragments/0123456789ab.1/init`], ['GET', `nvr/cameras/${sample}/keyframe?at=1760000000000`],
    ['POST', `cameras/${sample}/optimize`, { confirm: true }], ['POST', `cameras/${sample}/optimize/undo`, {}],
  ];
  await check('access: every NVR route is 401 without the session cookie', async () => {
    for (const [method, path, body] of NVR_REQUESTS) {
      const response = await client.send(method, path, { auth: false, body });
      same(response.status, 401, `${method} ${path.split('?')[0]} without a cookie`);
      same(response.json?.error, 'unauthorized', `${method} ${path.split('?')[0]} error code`);
    }
  });
  await check('access: a change without the CSRF token is 403 csrf, from another site 403 cross_origin, with the wrong type 415', async () => {
    for (const [method, path, body] of NVR_REQUESTS.filter(([verb]) => verb !== 'GET')) {
      const label = `${method} ${path.split('?')[0]}`;
      same((await client.send(method, path, { csrf: false, body })).json?.error, 'csrf', `${label} without X-CSRF-Token`);
      const foreign = await client.send(method, path, { origin: 'http://evil.example', body });
      same(foreign.status, 403, `${label} from another site`);
      same(foreign.json?.error, 'cross_origin', `${label} from another site: error code`);
      const wrongType = await client.send(method, path, { type: 'text/plain', body: JSON.stringify(body) });
      same(wrongType.status, 415, `${label} as text/plain`);
    }
  });
  await check('access: a GET needs no CSRF token', async () => {
    const response = await client.send('GET', 'nvr/storage', { csrf: false });
    same(response.status, 200, 'GET nvr/storage without X-CSRF-Token');
  });

  // -- F. R5 and R6: the catalog and the waveform
  let catalog = null;
  await check('R5 cameras: extents of the cameras that have footage', async () => {
    const response = await client.get('nvr/cameras');
    if (response.status === 503) { same(response.json.error, 'archive_unavailable', 'a 503 is archive_unavailable'); return 'the archive is not available or not ready (503)'; }
    same(response.status, 200, 'GET nvr/cameras');
    catalog = response.json;
    ok(isInt(catalog.serverTime) && isInt(catalog.catalogVersion) && catalog.catalogVersion >= 0, 'serverTime or catalogVersion');
    ok(Array.isArray(catalog.cameras), 'cameras is not a list');
    const known = new Set(cameras.map((camera) => camera.id));
    for (const entry of catalog.cameras) {
      ok(UUID.test(entry.id) && known.has(entry.id), `an extent for the unknown camera ${entry.id}`);
      ok(isInt(entry.oldest) && isInt(entry.newest) && entry.oldest <= entry.newest, `extent of ${entry.id}`);
      ok(entry.typicalGOP === null || (isNumber(entry.typicalGOP) && entry.typicalGOP > 0), 'typicalGOP');
    }
    const again = (await client.get('nvr/cameras')).json;
    ok(again.catalogVersion >= catalog.catalogVersion, 'the catalog version went down');
    facts.skewMs = catalog.serverTime - Date.now();
    if (storage?.oldest !== null && storage?.oldest !== undefined && catalog.cameras.length) ok(Math.min(...catalog.cameras.map((entry) => entry.oldest)) >= storage.oldest - 1000, 'a camera is older than the storage says');
  });
  const camera = catalog?.cameras?.[0] ?? null;
  const activityPath = (cameraId, from, bins, binMs) => `nvr/activity?cameras=${cameraId}&from=${from}&binMs=${binMs}&bins=${bins}`;
  await check('R6 activity: bad requests are 400 invalid with the field', async () => {
    const id = camera?.id ?? sample;
    const T = 1760000000000;
    const cases = [
      ['no cameras', `nvr/activity?from=${T}&binMs=60000&bins=10`, 'cameras'],
      ['a bad camera id', `nvr/activity?cameras=nope&from=${T}&binMs=60000&bins=10`, 'cameras'],
      // the limit counts DIFFERENT cameras (T00 R6): one id listed 17 times is one camera, so the refused list has 17 different ids
      ['17 different cameras', `nvr/activity?cameras=${[id, ...otherIds(16)].join(',')}&from=${T}&binMs=60000&bins=10`, 'cameras'],
      ['17 different cameras, each listed twice', `nvr/activity?cameras=${[id, ...otherIds(16), id, ...otherIds(16)].join(',')}&from=${T}&binMs=60000&bins=10`, 'cameras'],
      ['an empty item in the list', `nvr/activity?cameras=${id},,${id}&from=${T}&binMs=60000&bins=10`, 'cameras'],
      ['no from', `nvr/activity?cameras=${id}&binMs=60000&bins=10`, 'from'],
      ['from before 2001', `nvr/activity?cameras=${id}&from=1000&binMs=60000&bins=10`, 'from'],
      ['from after 2100', `nvr/activity?cameras=${id}&from=4102444800001&binMs=60000&bins=10`, 'from'],
      ['from with 16 digits', `nvr/activity?cameras=${id}&from=1760000000000000&binMs=60000&bins=10`, 'from'],
      ['binMs 999', `nvr/activity?cameras=${id}&from=${T}&binMs=999&bins=10`, 'binMs'],
      ['binMs 86400001', `nvr/activity?cameras=${id}&from=${T}&binMs=86400001&bins=10`, 'binMs'],
      ['bins 0', `nvr/activity?cameras=${id}&from=${T}&binMs=60000&bins=0`, 'bins'],
      ['bins 2001', `nvr/activity?cameras=${id}&from=${T}&binMs=60000&bins=2001`, 'bins'],
      ['more than 31 days', `nvr/activity?cameras=${id}&from=${T}&binMs=86400000&bins=32`, ['bins', 'binMs']],
    ];
    for (const [label, path, field] of cases) {
      const response = await client.get(path);
      if (response.status === 503) return 'the archive is not available or not ready (503)';
      same(response.status, 400, label);
      same(response.json?.error, 'invalid', `${label}: error code`);
      ok([].concat(field).includes(response.json?.field), `${label}: field ${show(response.json?.field)}, expected ${[].concat(field).join(' or ')}`);
    }
  });
  await check('R6 activity: a camera listed again is one camera, and the limit of 16 counts only different cameras', async () => {
    const id = camera?.id ?? sample;
    const T = 1760000000000;
    const cases = [
      ['one camera listed four times, once in lower case', [id, id, id.toLowerCase(), id], [id]],
      ['one camera listed 17 times', Array(17).fill(id), [id]],
      ['16 different cameras', [id, ...otherIds(15)], [id, ...otherIds(15)]],
      ['16 different cameras, three of them listed again', [id, ...otherIds(15), id, ...otherIds(2)], [id, ...otherIds(15)]],
    ];
    for (const [label, list, wanted] of cases) {
      const response = await client.get(`nvr/activity?cameras=${list.join(',')}&from=${T}&binMs=60000&bins=10`);
      if (response.status === 503) return 'the archive is not available or not ready (503)';
      same(response.status, 200, label);
      same(Object.keys(response.json?.byCamera ?? {}).sort(), wanted.map((entry) => entry.toUpperCase()).sort(), `${label}: the cameras in byCamera (one entry per different camera, upper case)`);
    }
  });
  await check('events: bad requests are 400 invalid with the field', async () => {
    const id = camera?.id ?? sample;
    const T = 1760000000000;
    const cases = [
      ['no cameras', `nvr/events?from=${T}&to=${T + 1000}`, 'cameras'],
      ['a bad camera id', `nvr/events?cameras=nope&from=${T}&to=${T + 1000}`, 'cameras'],
      ['17 different cameras', `nvr/events?cameras=${[id, ...otherIds(16)].join(',')}&from=${T}&to=${T + 1000}`, 'cameras'],
      ['no from', `nvr/events?cameras=${id}&to=${T}`, 'from'],
      ['no to', `nvr/events?cameras=${id}&from=${T}`, 'to'],
      ['to not after from', `nvr/events?cameras=${id}&from=${T}&to=${T}`, 'to'],
      ['more than 31 days', `nvr/events?cameras=${id}&from=${T}&to=${T + 31 * 86_400_000 + 1}`, 'to'],
      ['limit 0', `nvr/events?cameras=${id}&from=${T}&to=${T + 1000}&limit=0`, 'limit'],
      ['limit 1001', `nvr/events?cameras=${id}&from=${T}&to=${T + 1000}&limit=1001`, 'limit'],
    ];
    for (const [label, path, field] of cases) {
      const response = await client.get(path);
      if (response.status === 503) return 'the archive is not available or not ready (503)';
      same(response.status, 400, label);
      same(response.json?.error, 'invalid', `${label}: error code`);
      same(response.json?.field, field, `${label}: field`);
    }
  });
  await check('events: newest first, inside the range, at most limit, names and times only', async () => {
    if (!camera) return 'no camera has footage';
    const to = camera.newest;
    const from = Math.max(camera.oldest, to - 86_400_000);
    const response = await client.get(`nvr/events?cameras=${camera.id}&from=${from}&to=${to}&limit=5`);
    if (response.status === 503) return 'the archive is not available or not ready (503)';
    same(response.status, 200, 'GET nvr/events');
    const body = response.json;
    same(Object.keys(body).sort(), ['events', 'from', 'more', 'serverTime', 'to'], 'keys');
    same([body.from, body.to], [from, to], 'from and to');
    ok(typeof body.more === 'boolean' && isInt(body.serverTime), 'more or serverTime');
    ok(Array.isArray(body.events) && body.events.length <= 5, 'at most limit events');
    for (const event of body.events) {
      same(Object.keys(event).sort(), ['cameraID', 'end', 'id', 'kind', 'recorded', 'start'], 'event keys');
      same(event.cameraID, camera.id, 'cameraID (upper case)');
      ok(typeof event.id === 'string' && event.id.length > 0 && typeof event.kind === 'string' && typeof event.recorded === 'boolean', 'id, kind or recorded');
      ok(isInt(event.start) && event.start >= from && event.start < to, `start ${event.start} outside ${from} to ${to}`);
      ok(event.end === null || (isInt(event.end) && event.end >= event.start), 'end');
    }
    ok(body.events.every((event, index) => index === 0 || body.events[index - 1].start >= event.start), 'newest first');
    if (body.more) {
      const oldest = body.events.at(-1).start;
      const rest = await client.get(`nvr/events?cameras=${camera.id}&from=${from}&to=${oldest}&limit=1000`);
      same(rest.status, 200, 'the next page');
      ok(rest.json.events.every((event) => event.start < oldest), 'the next page is older');
    }
  });
  await check('R6 activity: bins are aligned, complete and in range', async () => {
    if (!camera) return 'no camera has footage';
    const binMs = 60_000;
    const bins = 120;
    const wanted = camera.newest - bins * binMs;
    const response = await client.get(activityPath(camera.id, wanted + 123, bins, binMs));
    if (response.status === 503) return 'the archive is not available or not ready (503)';
    same(response.status, 200, 'GET nvr/activity');
    const body = response.json;
    same(body.from, Math.floor((wanted + 123) / binMs) * binMs, 'from is snapped down to a multiple of binMs');
    same(body.binMs, binMs, 'binMs');
    same(body.bins, bins, 'bins');
    ok(isInt(body.serverTime) && isInt(body.catalogVersion), 'serverTime or catalogVersion');
    same(Object.keys(body.byCamera), [camera.id], 'byCamera keys (upper case UUIDs)');
    const answer = body.byCamera[camera.id];
    same(answer.coverage.length, bins, 'coverage length');
    same(answer.level.length, bins, 'level length');
    ok(answer.coverage.every((value) => isInt(value) && value >= 0 && value <= 100), 'coverage is not whole numbers 0 to 100');
    ok(answer.level.every((value) => isNumber(value) && value >= 0), 'level is not numbers from 0');
    ok(typeof answer.complete === 'boolean', 'complete');
    ok(answer.typical === null || (isNumber(answer.typical) && answer.typical >= 0), 'typical');
    // What the bins must show is worked out from the window the server ANSWERED, not from the one that was asked for: `from` was snapped down, so that window
    // ends up to one bin before the newest footage, and a recording shorter than a bin can lie wholly after the end of it (or wholly before the start).
    const windowStart = body.from;
    const windowEnd = body.from + body.bins * body.binMs;
    const latest = (await client.get('nvr/cameras')).json?.cameras?.find((entry) => entry.id === camera.id);
    const newest = Math.max(camera.newest, latest?.newest ?? 0); // footage may have been added since R5 answered, never taken from its end
    const stray = answer.coverage.map((value, index) => ({ value, index, start: windowStart + index * binMs }))
      .filter(({ value, start }) => value > 0 && (start + binMs <= camera.oldest || start >= newest + binMs));
    ok(!stray.length, `bin ${stray[0]?.index} (${stray[0]?.start}) has coverage ${stray[0]?.value} but lies outside the footage ${camera.oldest} to ${newest}`);
    const overlapFrom = Math.max(camera.oldest, windowStart);
    const overlapTo = Math.min(camera.newest, windowEnd);
    if (overlapTo - overlapFrom >= 5000) { // under 5 s the whole-percent rounding of one bin's coverage may legitimately show nothing
      const first = Math.floor((overlapFrom - windowStart) / binMs);
      const last = Math.floor((overlapTo - 1 - windowStart) / binMs);
      ok(answer.coverage.slice(first, last + 1).some((value) => value > 0), `the answered window ${windowStart} to ${windowEnd} overlaps the footage ${camera.oldest} to ${camera.newest} by ${overlapTo - overlapFrom} ms (bins ${first} to ${last}), but none of those bins has coverage`);
    }
  });

  // -- G. R7 to R10 for each camera that has footage: the plan, the bytes and the identities between them
  const bad503 = 'the archive is not available or not ready (503)';
  const driveTrouble = (response) => (response.status === 504 || (response.status === 410 && ['folderMissing', 'notWritable'].includes(storage?.state))
    ? `the recordings drive does not answer (${response.status} ${response.json?.error}), as ${storage?.state ?? 'a slow drive'} says` : null);
  await check('R7 fragments: bad requests are refused with the field', async () => {
    const id = camera?.id ?? sample;
    const T = 1760000000000;
    const bad = [
      ['neither at nor after', `nvr/cameras/${id}/fragments`, 400, 'invalid'],
      ['both at and after', `nvr/cameras/${id}/fragments?at=${T}&after=0123456789ab.1`, 400, 'invalid'],
      ['at before 2001', `nvr/cameras/${id}/fragments?at=1000`, 400, 'invalid', 'at'],
      ['at not a number', `nvr/cameras/${id}/fragments?at=soon`, 400, 'invalid', 'at'],
      ['ahead 17', `nvr/cameras/${id}/fragments?at=${T}&ahead=17`, 400, 'invalid', 'ahead'],
      ['after not an id', `nvr/cameras/${id}/fragments?after=zzz`, 400, 'invalid', 'after'],
      ['limit 0', `nvr/cameras/${id}/fragments?after=0123456789ab.1&limit=0`, 400, 'invalid', 'limit'],
      ['limit 65', `nvr/cameras/${id}/fragments?after=0123456789ab.1&limit=65`, 400, 'invalid', 'limit'],
      ['a camera id that is not a UUID', `nvr/cameras/not-a-uuid/fragments?at=${T}`, 404, 'not_found'],
      ['a fragment id that is malformed', `nvr/cameras/${id}/fragments/not-an-id`, 400, 'invalid', 'fid'],
      ['a keyframe time before 2001', `nvr/cameras/${id}/keyframe?at=1`, 400, 'invalid', 'at'],
    ];
    for (const [label, path, status, code, field] of bad) {
      const response = await client.get(path);
      if (response.status === 503) return bad503;
      same(response.status, status, label);
      same(response.json?.error, code, `${label}: error code`);
      if (field) same(response.json?.field, field, `${label}: field`);
    }
  });
  await check('R7 fragments: an unknown camera and times outside the footage', async () => {
    const T = 1760000000000;
    const unknown = await client.get(`nvr/cameras/FFFFFFFF-0000-4000-8000-000000000000/fragments?at=${T}`);
    if (unknown.status === 503) return bad503;
    same(unknown.status, 200, 'an unknown camera');
    same([unknown.json.found, unknown.json.reason, unknown.json.newest], [false, 'empty', null], 'an unknown camera is one with no recordings');
    const gone = await client.get('nvr/cameras/FFFFFFFF-0000-4000-8000-000000000000/fragments/000000000000.1');
    if (!driveTrouble(gone)) {
      same([gone.status, gone.json?.error], [410, 'gone'], 'an unknown fragment id');
      same((await client.get('nvr/cameras/FFFFFFFF-0000-4000-8000-000000000000/fragments/000000000000.1/init')).status, 410, 'an unknown fragment id on init');
    }
    if (!camera) return;
    const before = (await client.get(`nvr/cameras/${camera.id}/fragments?at=${camera.oldest - 60_000}`)).json;
    same([before.found, before.reason], [false, 'beforeStart'], 'a time before the oldest footage');
    const after = (await client.get(`nvr/cameras/${camera.id}/fragments?at=${camera.newest + 60_000}`)).json;
    same([after.found, after.reason], [false, 'afterEnd'], 'a time after the newest footage');
    ok(isInt(after.newest) && after.newest >= camera.newest, 'newest in a not-found answer');
  });

  const withFootage = (catalog?.cameras ?? []).slice(0, 12);
  const nameOf = (entry) => cameras.find((candidate) => candidate.id === entry.id)?.name ?? entry.id;
  for (const entry of withFootage) {
    const label = `[${nameOf(entry)}]`;
    let plan = null;
    await check(`R7 fragments?at ${label}: parts, lead-in, files and the anchor`, async () => {
      const at = entry.newest - 90_000;
      const response = await client.get(`nvr/cameras/${entry.id}/fragments?at=${at}&ahead=3`);
      if (response.status === 503) return bad503;
      same(response.status, 200, 'GET fragments?at');
      plan = response.json;
      if (!plan.found) { plan = null; return `nothing is recorded 90 s before the newest footage (${plan?.reason})`; }
      ok(isInt(plan.serverTime) && plan.at === at && typeof plan.exact === 'boolean', 'serverTime, at or exact');
      ok(Array.isArray(plan.parts) && plan.parts.length >= 1 && plan.parts.length <= 64 + 3, `parts: ${plan.parts?.length}`);
      ok(isInt(plan.targetIndex) && plan.targetIndex >= 0 && plan.targetIndex < plan.parts.length, 'targetIndex');
      same(plan.parts[0].key, true, 'the first part holds the keyframe');
      for (const part of plan.parts) {
        hasKeys(part, ['id', 'file', 'start', 'end', 'bytes', 'key'], 'a part');
        ok(FRAGMENT_ID.test(part.id) && part.id.startsWith(`${part.file}.`), `part id ${part.id}`);
        ok(isInt(part.start) && isInt(part.end) && part.end > part.start && isInt(part.bytes) && part.bytes > 0 && typeof part.key === 'boolean', `part ${part.id}`);
        ok(plan.files[part.file], `files lacks ${part.file}`);
      }
      if (plan.exact) {
        const target = plan.parts[plan.targetIndex];
        ok(target.start <= at && at < target.end, `the target part [${target.start}, ${target.end}) does not contain ${at}`);
        ok(plan.parts.slice(0, plan.targetIndex + 1).every((part) => part.file === target.file), 'the lead-in spans files');
        ok(plan.parts.slice(1, plan.targetIndex + 1).every((part) => !part.key), 'a part between the keyframe and the target holds another keyframe');
      }
      for (let i = 1; i < plan.parts.length; i += 1) {
        const [a, b] = [plan.parts[i - 1], plan.parts[i]];
        ok(b.start >= a.start, `parts are out of order at ${i}`);
        if (a.file === b.file) same(b.start, a.end, `parts ${i - 1} and ${i} of one file touch`);
      }
      for (const [key, file] of Object.entries(plan.files)) {
        hasKeys(file, ['mime', 'width', 'height', 'anchor', 'initId', 'sound'], `files.${key}`);
        ok(/^video\/mp4; codecs="(avc1|hvc1|hev1)\.[0-9A-Za-z.]+"$/.test(file.mime), `mime ${file.mime}`);
        ok(isInt(file.width) && isInt(file.height) && isNumber(file.anchor) && typeof file.sound === 'boolean', `files.${key}`);
        ok(plan.parts.some((part) => part.id === file.initId && part.file === key), `initId ${file.initId} is not a part of ${key} in this answer`);
      }
      same(Object.keys(plan.files).length, new Set(plan.parts.map((part) => part.file)).size, 'files has one entry per file of the parts');
    });
    await check(`R7 fragments?after ${label}: the parts that follow, each once, in order`, async () => {
      if (!plan) return 'no plan to continue from';
      const last = plan.parts.at(-1);
      const response = await client.get(`nvr/cameras/${entry.id}/fragments?after=${last.id}&limit=5`);
      same(response.status, 200, 'GET fragments?after');
      const body = response.json;
      hasKeys(body, ['serverTime', 'parts', 'files'], 'an after answer');
      ok(isInt(body.serverTime) && body.parts.length <= 5, 'serverTime or the number of parts');
      let previous = last;
      for (const part of body.parts) {
        ok(part.start > previous.start, `${part.id} does not start after ${previous.id}`);
        ok(body.files[part.file], `files lacks ${part.file}`);
        previous = part;
      }
    });
    await check(`R7 fragments?at ${label}: a plan across a file boundary names both files`, async () => {
      if (!plan) return 'no plan to continue from';
      // walk forward from 40 minutes before the newest footage until the file changes (files are about 15 minutes long)
      const start = (await client.get(`nvr/cameras/${entry.id}/fragments?at=${entry.newest - 40 * 60_000}&ahead=0`)).json;
      if (!start.found) return 'nothing is recorded 40 minutes before the newest footage';
      let previous = start.parts.at(-1);
      for (let round = 0; round < 14; round += 1) {
        const next = (await client.get(`nvr/cameras/${entry.id}/fragments?after=${previous.id}&limit=64`)).json;
        const all = [previous, ...next.parts];
        const boundary = all.findIndex((part, i) => i > 0 && part.file !== all[i - 1].file);
        if (boundary > 0) {
          const lastOfFirst = all[boundary - 1];
          const crossing = (await client.get(`nvr/cameras/${entry.id}/fragments?at=${lastOfFirst.start + 1}&ahead=2`)).json;
          ok(crossing.found, 'the last part of a file is not found');
          const files = new Set(crossing.parts.map((part) => part.file));
          ok(files.size === 2 && Object.keys(crossing.files).length === 2, `a plan over a file boundary lists ${files.size} files`);
          const second = crossing.parts.find((part) => part.file !== lastOfFirst.file);
          ok(second.start >= lastOfFirst.end - 1, `the next file starts at ${second.start}, before the end ${lastOfFirst.end} of the last part of the first`);
          ok(second.start <= lastOfFirst.end + 999, `the next file starts at ${second.start}, a second or more after ${lastOfFirst.end}`);
          return;
        }
        if (!next.parts.length) break;
        previous = next.parts.at(-1);
      }
      return 'no file boundary within 14 x 64 parts';
    });
    await check(`R8 fragment bytes ${label}: moof and mdat only, the sizes the plan gave, no caching headers`, async () => {
      if (!plan) return 'no plan to read from';
      for (const part of plan.parts) {
        const response = await client.get(`nvr/cameras/${entry.id}/fragments/${part.id}`);
        if (driveTrouble(response)) return driveTrouble(response);
        same(response.status, 200, `GET fragment ${part.id}`);
        same(response.headers['content-type'], 'video/mp4', 'Content-Type');
        same(response.headers['cache-control'], 'no-store', 'Cache-Control');
        same(response.headers['content-length'], String(response.buffer.length), 'Content-Length');
        for (const name of ['etag', 'last-modified', 'vary', 'content-range']) same(response.headers[name], undefined, `the header ${name}`);
        ok(response.headers['accept-ranges'] !== 'bytes', 'Accept-Ranges: bytes');
        const boxes = readBoxes(response.buffer);
        same(boxes.map((box) => box.type), ['moof', 'mdat'], `the boxes of ${part.id} (no prft, no styp)`);
        if (!plan.files[part.file].sound) same(response.buffer.length, part.bytes, `the size of ${part.id} against bytes in the plan`);
        ok(response.buffer.length <= 16 * 1_048_576, `${part.id} is larger than 16 MiB`);
      }
      const head = await client.send('HEAD', `nvr/cameras/${entry.id}/fragments/${plan.parts[0].id}`);
      same([head.status, head.headers.allow], [405, 'GET'], 'HEAD on a fragment');
      const ranged = await client.get(`nvr/cameras/${entry.id}/fragments/${plan.parts[0].id}`, { headers: { Range: 'bytes=0-9', 'If-None-Match': '"x"' } });
      same(ranged.status, 200, 'a Range and an If-None-Match are ignored');
    });
    await check(`R8 fragment bytes ${label}: keyframe flags, contiguous media times, and start = anchor + tfdt`, async () => {
      if (!plan) return 'no plan to read from';
      const decoded = [];
      for (const part of plan.parts) {
        const response = await client.get(`nvr/cameras/${entry.id}/fragments/${part.id}`);
        if (driveTrouble(response)) return driveTrouble(response);
        same(response.status, 200, `GET fragment ${part.id}`);
        const init = parseInit((await client.get(`nvr/cameras/${entry.id}/fragments/${plan.files[part.file].initId}/init`)).buffer);
        const boxes = readBoxes(response.buffer);
        decoded.push({ part, init, fragment: parseFragment(response.buffer, boxes[0], boxes[1], init.defaults) });
      }
      for (const { part, fragment } of decoded) same(fragment.key, part.key, `the first sample of ${part.id} is a keyframe`);
      for (let i = 1; i < decoded.length; i += 1) {
        const [a, b] = [decoded[i - 1], decoded[i]];
        if (a.part.file === b.part.file) same(b.fragment.baseDecodeTime, a.fragment.baseDecodeTime + a.fragment.duration, `the tfdt of part ${i} follows part ${i - 1}`);
      }
      for (const { part, init, fragment } of decoded) {
        const epoch = plan.files[part.file].anchor + (fragment.baseDecodeTime / init.timescale) * 1000;
        ok(Math.abs(epoch - part.start) <= 3, `anchor + tfdt gives ${epoch} for ${part.id} and the plan says it starts at ${part.start}: the anchor must satisfy start = anchor + tfdt / timescale x 1000`);
        const length = (fragment.duration / init.timescale) * 1000;
        ok(Math.abs(length - (part.end - part.start)) <= 3, `${part.id} lasts ${length} ms in its bytes and ${part.end - part.start} ms in the plan`);
      }
    });
    await check(`R9 init ${label}: ftyp and moov of one video track, and the mime the plan gave`, async () => {
      if (!plan) return 'no plan to read from';
      for (const [key, file] of Object.entries(plan.files)) {
        const response = await client.get(`nvr/cameras/${entry.id}/fragments/${file.initId}/init`);
        if (driveTrouble(response)) return driveTrouble(response);
        same(response.status, 200, `GET init of ${key}`);
        same(response.headers['content-type'], 'video/mp4', 'Content-Type');
        const boxes = readBoxes(response.buffer);
        same(boxes[0].type, 'ftyp', 'the first box');
        const moov = boxes.find((box) => box.type === 'moov');
        ok(moov, 'no moov');
        const handler = (trak) => { const hdlr = child(response.buffer, child(response.buffer, trak, 'mdia'), 'hdlr'); return response.buffer.toString('latin1', hdlr.bodyStart + 8, hdlr.bodyStart + 12); };
        same(children(response.buffer, moov, 'trak').map(handler), ['vide'], 'the tracks (video only)');
        const info = parseInit(response.buffer);
        same(info.mime, file.mime, 'mime from the init against the plan');
        same([info.width, info.height], [file.width, file.height], 'the size from the init against the plan');
        same(info.timescale, 90000, 'the video time scale');
      }
    });
    await check(`R10 keyframe ${label}: the key fragment of the GOP and its X-CB-Part header`, async () => {
      if (!plan) return 'no plan to read from';
      const response = await client.get(`nvr/cameras/${entry.id}/keyframe?at=${plan.at}`);
      if (driveTrouble(response)) return driveTrouble(response);
      same(response.status, 200, 'GET keyframe');
      same(response.headers['content-type'], 'video/mp4', 'Content-Type');
      const header = response.headers['x-cb-part'];
      ok(header && /^[\x20-\x7e]+$/.test(header), 'X-CB-Part is missing or not ASCII');
      ok(header.length <= 600, `X-CB-Part is ${header.length} characters`);
      const part = JSON.parse(header);
      hasKeys(part, ['id', 'file', 'start', 'end', 'mime', 'width', 'height', 'anchor', 'initId'], 'X-CB-Part');
      const key = plan.parts[0];
      same([part.id, part.file, part.start, part.end], [key.id, key.file, key.start, key.end], 'X-CB-Part against the first part of the plan');
      const file = plan.files[key.file];
      same([part.mime, part.width, part.height, part.anchor], [file.mime, file.width, file.height, file.anchor], 'mime, size and anchor against the plan');
      ok(FRAGMENT_ID.test(part.initId) && part.initId.startsWith(`${part.file}.`), 'initId');
      const direct = await client.get(`nvr/cameras/${entry.id}/fragments/${key.id}`);
      ok(Buffer.compare(response.buffer, direct.buffer) === 0, 'the keyframe body differs from the fragment of the same id');
      same((await client.send('HEAD', `nvr/cameras/${entry.id}/keyframe?at=${plan.at}`)).status, 405, 'HEAD on keyframe');
    });
    if (entry === withFootage[0]) facts.plan = plan;
  }
  await check('R7 fragments: a gap says where the next recording starts (any camera with a gap of a minute or more)', async () => {
    for (const entry of withFootage) {
      // look for a minute without footage inside the camera's extent, 2000 minutes at a time
      let at = null;
      for (let from = Math.floor(entry.oldest / 60_000) * 60_000; from < entry.newest && at === null; from += 2000 * 60_000) {
        const found = await client.get(activityPath(entry.id, from, 2000, 60_000));
        if (found.status !== 200) return 'no activity to find a gap in';
        const { coverage } = found.json.byCamera[entry.id];
        const empty = coverage.findIndex((value, i) => value === 0 && from + i * 60_000 > entry.oldest + 60_000 && from + (i + 1) * 60_000 < entry.newest - 60_000);
        if (empty >= 0) at = from + empty * 60_000 + 30_000;
      }
      if (at === null) continue;
      const body = (await client.get(`nvr/cameras/${entry.id}/fragments?at=${at}`)).json;
      same([body.found, body.reason], [false, 'gap'], `a time inside a gap of ${nameOf(entry)}`);
      ok(isInt(body.next) && body.next > at, 'next after the gap');
      const keyframe = await client.get(`nvr/cameras/${entry.id}/keyframe?at=${at}`);
      same([keyframe.status, keyframe.json?.error], [404, 'gap'], 'keyframe in a gap');
      same(keyframe.headers['x-cb-next'], String(body.next), 'X-CB-Next');
      return;
    }
    return 'no camera has a gap of a minute or more';
  });

  // -- I. nothing leaks
  await check('hygiene: no error body names a path, a secret or what the request said', async () => {
    const marker = 'leak-probe-7391';
    // One at a time: five connections that arrive together are reset by a port forward such as QEMU's user mode (the box's smoke test), and nothing here depends on it.
    for (const path of [`nvr/cameras/${sample}/fragments?at=${marker}`, `nvr/cameras/${sample}/fragments/${marker}`, `nvr/activity?cameras=${marker}&from=${marker}`,
      `nvr/cameras/${marker}/keyframe?at=1`, `nope/${marker}`]) {
      const response = await client.get(path);
      ok(!response.text.includes(marker), `an error body echoes the request: ${response.text.slice(0, 120)}`);
    }
    for (const seen of client.seen) {
      for (const secret of secrets) if (secret) ok(!`${seen.text}${seen.headers}`.includes(secret), `an error answer to ${seen.method} ${seen.path.split('?')[0]} contains a secret`);
      ok(!/(\/Users\/|\/home\/|\/var\/|\/srv\/|\/private\/|[A-Z]:\\)/.test(seen.text), `an error answer to ${seen.method} ${seen.path.split('?')[0]} names a path: ${seen.text.slice(0, 120)}`);
    }
  });

  // -- J. writes that change nothing
  if (mutate) {
    await check('R3 storage: bad input is refused and the same values again change nothing', async () => {
      const bad = [
        ['an empty body', {}, 400, 'invalid'], ['keepDays 0', { keepDays: 0 }, 400, 'invalid', 'keepDays'], ['keepDays 366', { keepDays: 366 }, 400, 'invalid', 'keepDays'],
        ['keepDays as text', { keepDays: '7' }, 400, 'invalid', 'keepDays'], ['keepDays 1.5', { keepDays: 1.5 }, 400, 'invalid', 'keepDays'],
        ['keepDays too large for an integer', { keepDays: 1e30 }, 400, 'invalid', 'keepDays'], ['maxSizeGB 1.5', { maxSizeGB: 1.5 }, 400, 'invalid', 'maxSizeGB'],
        ['maxSizeGB 9', { maxSizeGB: 9 }, 400, 'invalid', 'maxSizeGB'], ['maxSizeGB 100001', { maxSizeGB: 100001 }, 400, 'invalid', 'maxSizeGB'],
        ['confirm alone', { confirm: true }, 400, 'invalid'], ['location as a number', { location: 5 }, 400, 'invalid', 'location'],
        ['an unknown location', { location: 'nowhere' }, 422, 'folder_rejected'], ['a path as location', { location: '/etc' }, 422, 'folder_rejected'],
      ];
      for (const [label, body, status, code, field] of bad) {
        const response = await client.patch('nvr/storage', body);
        same(response.status, status, label);
        same(response.json?.error, code, `${label}: error code`);
        if (field) same(response.json?.field, field, `${label}: field`);
      }
      const before = (await client.get('nvr/storage')).json;
      const response = await client.patch('nvr/storage', { keepDays: before.keepDays, maxSizeGB: before.maxSizeGB });
      same(response.status, 200, 'the same limits again');
      const after = response.json;
      same([after.keepDays, after.maxSizeGB, after.location, after.state], [before.keepDays, before.maxSizeGB, before.location, before.state], 'the answer after a change that changes nothing');
      if (before.state === 'ok' && before.location) {
        // R3 answers with the R1 body after the change: complete numbers, not the snapshot from before it (the daemon once answered a
        // folder change with state noFolder and every byte count 0 until the next refresh)
        const again = await client.patch('nvr/storage', { location: before.location });
        same(again.status, 200, 'the same location again');
        ok(again.json.state === 'ok' && again.json.freeBytes > 0 && again.json.totalBytes > 0 && again.json.floorBytes > 0 && again.json.effectiveMaxBytes > 0,
          `the answer to a location PATCH is not a complete snapshot (state ${again.json.state}, floor ${again.json.floorBytes}, effectiveMax ${again.json.effectiveMaxBytes})`);
        same(again.json.effectiveMaxBytes, Math.min(again.json.maxSizeGB * 1e9, again.json.totalBytes - 2 * again.json.floorBytes), 'effectiveMaxBytes of that answer');
      }
    });
    await check('R4 camera flags: bad input is refused and the same flags again change nothing', async () => {
      const id = cameras[0]?.id;
      if (!id) return 'there is no camera';
      same((await client.patch(`cameras/${id}/nvr`, {})).json?.error, 'invalid', 'an empty body');
      same((await client.patch(`cameras/${id}/nvr`, { enabled: 'yes' })).json?.field, 'enabled', 'enabled as text');
      same((await client.patch(`cameras/${id}/nvr`, { recordSound: 1 })).json?.field, 'recordSound', 'recordSound as a number');
      same((await client.patch('cameras/FFFFFFFF-0000-4000-8000-000000000000/nvr', { enabled: false })).status, 404, 'an unknown camera');
      same((await client.patch('cameras/not-a-uuid/nvr', { enabled: false })).status, 404, 'a malformed camera id');
      const now = cameras[0];
      const response = await client.patch(`cameras/${id}/nvr`, { enabled: now.nvrEnabled, recordSound: now.nvrRecordSound });
      if (response.status === 409) { same(response.json.error, 'folder_required', 'a 409 is folder_required'); return 'no recordings folder is chosen'; }
      same(response.status, 200, 'the same flags again');
      same([response.json.id, response.json.nvrEnabled, response.json.nvrRecordSound], [id, now.nvrEnabled, now.nvrRecordSound], 'the camera resource');
      ok(response.json.status?.nvr, 'the camera resource has no status.nvr');
    });
    await check('night vision: the mode a camera is in, again, is 204 and changes nothing', async () => {
      const camera = cameras.find((candidate) => NIGHT_MODES.includes(candidate.status?.nightVision?.mode));
      if (!camera) return 'no camera says which night vision mode it is in';
      const before = camera.status.nightVision;
      const response = await client.post(`cameras/${camera.id}/night-vision`, { mode: before.mode });
      if (response.status === 422) {
        same(response.json?.error, 'night_vision_failed', 'a 422 is night_vision_failed');
        ok(typeof response.json?.message === 'string' && response.json.message.length > 0, 'the 422 has no sentence');
        return `${camera.name} refused it: ${response.json.message}`;
      }
      same(response.status, 204, `${camera.name}: the same mode again`);
      const after = (await client.get(`cameras/${camera.id}`)).json?.status?.nightVision;
      same([after?.mode, after?.light, show(after?.modes)], [before.mode, before.light, show(before.modes)], `${camera.name}: night vision afterwards`);
    });
    await check('R11, R12 optimize: needs confirm, and an unknown camera is 404', async () => {
      const id = cameras[0]?.id ?? sample;
      same((await client.post(`cameras/${id}/optimize`, {})).status, 400, 'no confirm');
      same((await client.post(`cameras/${id}/optimize`, { confirm: false })).json?.field, 'confirm', 'confirm false');
      same((await client.post('cameras/FFFFFFFF-0000-4000-8000-000000000000/optimize', { confirm: true })).status, 404, 'an unknown camera');
      same((await client.post('cameras/FFFFFFFF-0000-4000-8000-000000000000/optimize/undo', {})).status, 404, 'undo for an unknown camera');
    });
  }

  // -- K. a burst
  const burstName = 'admission: 40 requests at once get 200 or 429 busy (Retry-After 1), and health still answers';
  if (intrusive && !burst) {
    if (!only || burstName.toLowerCase().includes(only.toLowerCase())) {
      counts.skipped += 1;
      report('skip', burstName, 'left out (--no-burst): the caller runs the burst another way');
    }
  } else if (intrusive && camera && facts.plan) {
    await check(burstName, async () => {
      const path = `nvr/cameras/${camera.id}/keyframe?at=${facts.plan.at}`;
      const started = Date.now();
      const [health, ...answers] = await Promise.all([client.get('health', { auth: false }), ...Array.from({ length: 40 }, () => client.get(path))]);
      same(health.status, 200, 'health during the burst');
      ok(Date.now() - started < 30_000, 'the burst took longer than 30 s');
      for (const answer of answers) {
        ok([200, 429, 503].includes(answer.status), `a burst request answered ${answer.status}`);
        if (answer.status === 429) { same(answer.json.error, 'busy', 'the 429 code'); same(answer.headers['retry-after'], '1', 'Retry-After on 429'); }
      }
    });
  }

  return { ...counts, skewMs: facts.skewMs };
}

// ---- the command line -------------------------------------------------------------------------------------------------------------

async function main() {
  const args = process.argv.slice(2);
  const flags = new Set(args.filter((arg) => arg.startsWith('--')));
  const only = args.includes('--only') ? args[args.indexOf('--only') + 1] : '';
  const url = args.find((arg, i) => !arg.startsWith('--') && args[i - 1] !== '--only');
  if (!url || flags.has('--help')) {
    console.error('Usage: CB_PASSWORD=... node conformance.mjs <base-url> [--mutate] [--intrusive] [--all] [--no-burst] [--only TEXT]');
    process.exit(url ? 0 : 2);
  }
  const password = process.env.CB_PASSWORD;
  if (!password) { console.error('Set CB_PASSWORD to the bridge password (it is read from the environment and never printed).'); process.exit(2); }
  const lines = { ok: ' ok ', FAIL: 'FAIL', skip: 'skip' };
  const result = await runConformance({
    baseUrl: url, password, mutate: flags.has('--mutate') || flags.has('--all'), intrusive: flags.has('--intrusive') || flags.has('--all'), burst: !flags.has('--no-burst'), only,
    report: (status, name, detail) => console.log(`${lines[status]}  ${name}${detail ? `\n        ${detail}` : ''}`),
  });
  if (result.aborted) console.log(`stopped: ${result.aborted}`);
  if (typeof result.skewMs === 'number') {
    const seconds = Math.round(Math.abs(result.skewMs) / 1000);
    console.log(seconds < 2 ? 'the server\'s clock agrees with this computer\'s (within 2 s)' : `the server's clock is ${result.skewMs >= 0 ? 'ahead of' : 'behind'} this computer's by about ${seconds} s`);
  }
  console.log(`${result.passed} passed, ${result.failed} failed, ${result.skipped} skipped`);
  process.exit(result.failed || result.aborted ? 1 : 0);
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) await main();
