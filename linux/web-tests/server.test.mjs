import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import http from 'node:http';
import { join } from 'node:path';
import { after, before, test } from 'node:test';
import { CSP, SECURITY_HEADERS } from '../web-dev/lib/security.mjs';
import { CAMERA_DEFINITIONS, DAY, HOUR } from '../web-dev/lib/cameras.mjs';
import { client, startDevServer } from './support/dev-server.mjs';
import { ensureFixtures, WEB_ROOT } from './support/fixtures.mjs';

const fixtures = ensureFixtures();
const opts = { skip: fixtures.skip };
const camera = (name) => CAMERA_DEFINITIONS.find((definition) => definition.name === name).id;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

let server;
before(async () => { if (!fixtures.skip) server = await startDevServer(); });
after(async () => { await server?.close(); });
const reset = async (scenario = 'ok') => { await server.api.dev('reset', { scenario }); await server.api.dev('options', { latencyMs: 0, jitterMs: 0, throttleMbps: 0 }); };

// ---- the file server and the headers ------------------------------------------------------------------------------------------

test('static: the page, its files, ETags and what is not served', opts, async () => {
  const anon = client(server.base);
  const page = await anon.get('/', { absolute: true, auth: false });
  assert.equal(page.status, 200);
  assert.match(page.headers['content-type'], /^text\/html/);
  assert.equal(page.text, readFileSync(join(WEB_ROOT, 'index.html'), 'utf8'));
  assert.equal(page.headers['cache-control'], 'no-cache');
  const script = await anon.get('/js/app.js', { absolute: true, auth: false });
  assert.match(script.headers['content-type'], /^text\/javascript/);
  assert.equal(script.headers.etag, `"${createHash('sha256').update(readFileSync(join(WEB_ROOT, 'js/app.js'))).digest('hex').slice(0, 16)}"`);
  const revalidated = await anon.get('/js/app.js', { absolute: true, auth: false, headers: { 'If-None-Match': script.headers.etag } });
  assert.equal(revalidated.status, 304);
  assert.equal((await anon.get('/mark.svg', { absolute: true, auth: false })).headers['cache-control'], 'public, max-age=86400');
  for (const path of ['/js/', '/js', '/../web-dev/lib/server.mjs', '/%2e%2e/web-dev/make-fixtures.sh', '/js/%2e%2e/%2e%2e/web-tests/lint.mjs', '/.git/config', '/js//app.js', '/js%5Capp.js', '/js/app.js%00', '/nope']) {
    assert.equal((await anon.get(path, { absolute: true, auth: false })).status, 404, path);
  }
  assert.equal((await anon.send('POST', '/', { absolute: true, auth: false, body: {} })).status, 405);
  assert.equal((await anon.send('HEAD', '/', { absolute: true, auth: false })).status, 200);
});

test('every answer carries the daemon\'s security headers, the CSP with media-src and nothing unsafe', opts, async () => {
  const anon = client(server.base);
  for (const [path, auth] of [['/', false], ['/js/app.js', false], ['/nope', false], ['health', false], ['nvr/storage', false], ['nvr/storage', true]]) {
    const response = await anon.get(path, { absolute: path.startsWith('/'), auth: auth && !!server.api.cookie ? true : false, headers: auth ? { Cookie: server.api.cookie } : {} });
    for (const [name, value] of Object.entries(SECURITY_HEADERS)) assert.equal(response.headers[name.toLowerCase()], value, `${name} on ${path}`);
  }
  assert.ok(CSP.includes("media-src 'self' blob:") && !/unsafe/.test(CSP));
  assert.equal(CSP, "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; media-src 'self' blob:; connect-src 'self'; font-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'");
  assert.equal((await client(server.base).get('health', { auth: false })).headers['cache-control'], 'no-store');
});

test('a Host header that is not an address or a local name is 421', opts, async () => {
  const response = await new Promise((resolve, reject) => {
    const url = new URL(server.base);
    http.get({ host: url.hostname, port: url.port, path: '/api/v1/health', headers: { Host: 'evil.example' } }, (res) => { res.resume(); res.on('end', () => resolve(res.statusCode)); }).on('error', reject);
  });
  assert.equal(response, 421);
});

// ---- sign-in, session, CSRF --------------------------------------------------------------------------------------------------

test('sign-in: wrong password 401, right one a cookie that is HttpOnly and SameSite=Strict, no cookie 401, CSRF 403', opts, async () => {
  const anon = client(server.base);
  const wrong = await anon.signIn('not the password');
  assert.deepEqual([wrong.status, wrong.json.error, wrong.json.field], [401, 'wrong_password', 'password']);
  assert.ok(!wrong.text.includes('not the password'));
  const login = await anon.signIn();
  assert.equal(login.status, 200);
  assert.match(login.headers['set-cookie'], /^cb_session=[0-9a-f]{64}; Path=\/; HttpOnly; SameSite=Strict; Max-Age=\d+$/);
  const noCookie = await client(server.base).get('nvr/storage');
  assert.deepEqual([noCookie.status, noCookie.json.error], [401, 'unauthorized']);
  const noToken = await anon.patch('nvr/storage', { keepDays: 7 }, { csrf: false });
  assert.deepEqual([noToken.status, noToken.json.error], [403, 'csrf']);
  const foreign = await anon.patch('nvr/storage', { keepDays: 7 }, { headers: { Origin: 'http://evil.example' } });
  assert.deepEqual([foreign.status, foreign.json.error], [403, 'cross_origin']);
  const sameOrigin = await anon.patch('nvr/storage', { keepDays: 7 }, { headers: { Origin: server.base } });
  assert.equal(sameOrigin.status, 200);
  const plain = await anon.send('PATCH', 'nvr/storage', { body: '{"keepDays":7}', type: 'text/plain' });
  assert.deepEqual([plain.status, plain.json.error], [415, 'unsupported_media_type']);
  const session = await anon.get('session');
  assert.deepEqual([session.json.authenticated, session.json.csrfToken], [true, anon.csrf]);
  assert.equal((await anon.post('auth/logout', {})).status, 204);
  assert.equal((await anon.get('nvr/storage')).status, 401, 'the session is gone after sign-out');
});

test('methods and unknown routes: 405 with Allow, 404 in the API\'s words, HEAD on media 405', opts, async () => {
  const { api } = server;
  const wrongMethod = await api.send('DELETE', 'nvr/storage');
  assert.deepEqual([wrongMethod.status, wrongMethod.json.error, wrongMethod.headers.allow], [405, 'method_not_allowed', 'GET, PATCH']);
  const unknown = await api.get('nvr/nothing');
  assert.deepEqual([unknown.status, unknown.json.error], [404, 'not_found']);
  const cam = camera('Front Door');
  const plan = (await api.get(`nvr/cameras/${cam}/fragments?at=${Date.now() - HOUR}`)).json;
  const head = await api.send('HEAD', `nvr/cameras/${cam}/fragments/${plan.parts[0].id}`);
  assert.deepEqual([head.status, head.headers.allow], [405, 'GET']);
});

// ---- the nine cameras ----------------------------------------------------------------------------------------------------------

test('cameras: nine, with the NVR flags and a status.nvr each, and a keyframe note on the long-GOP one', opts, async () => {
  await reset();
  const { cameras } = (await server.api.get('cameras')).json;
  assert.equal(cameras.length, 9);
  for (const entry of cameras) assert.ok(entry.id && entry.status.nvr && typeof entry.nvrEnabled === 'boolean' && typeof entry.nvrRecordSound === 'boolean');
  const byName = Object.fromEntries(cameras.map((entry) => [entry.name, entry]));
  assert.equal(byName.Shed.status.nvr.state, 'off');
  assert.equal(byName['Front Door'].status.nvr.state, 'recording');
  assert.deepEqual(byName.Garage.status.nvr.notes, [{ id: 'keyframe', text: 'keyframe every 12 s: scrubbing is slow' }]);
  assert.equal(byName.Porch.nvrRecordSound, true);
  assert.ok(cameras.every((entry) => /^192\.0\.2\.\d+$/.test(entry.endpoint.host)), 'documentation addresses only');
  assert.equal((await server.api.get(`cameras/${camera('Garage')}/snapshot`)).headers['content-type'], 'image/jpeg');
});

test('three days of activity: every recording camera has footage from about 72 hours ago to now', opts, async () => {
  const { json } = await server.api.get('nvr/cameras');
  assert.equal(json.cameras.length, 9);
  for (const entry of json.cameras) {
    const name = CAMERA_DEFINITIONS.find((definition) => definition.id === entry.id).name;
    if (name === 'New Gate') assert.ok(entry.newest - entry.oldest > 20 * 60_000 && entry.newest - entry.oldest < 30 * 60_000);
    else if (name === 'Shed') assert.ok(json.serverTime - entry.newest > 5.9 * HOUR);
    else { assert.ok(json.serverTime - entry.oldest > 2.9 * DAY && json.serverTime - entry.oldest <= 3 * DAY, name); assert.ok(json.serverTime - entry.newest < 3000, `${name} lags ${json.serverTime - entry.newest} ms`); }
  }
});

test('activity (R6): a camera listed again is one camera in either letter case, the limit of 16 counts different cameras, an item that is no camera id refuses the list', opts, async () => {
  const id = camera('Garage');
  const others = Array.from({ length: 16 }, (_, i) => `00000000-0000-4000-8000-${String(i + 1).padStart(12, '0')}`);
  const ask = (list) => server.api.get(`nvr/activity?cameras=${list.join(',')}&from=${Date.now() - 600_000}&binMs=60000&bins=2`);
  const refused = (answer, label) => assert.deepEqual([answer.status, answer.json?.error, answer.json?.field], [400, 'invalid', 'cameras'], `${label}: ${answer.text}`);

  const again = await ask([id, id, id.toLowerCase(), id]);
  assert.equal(again.status, 200, again.text);
  assert.deepEqual(Object.keys(again.json.byCamera), [id], 'one entry, under the upper-case id');
  const copies = await ask(Array(17).fill(id));
  assert.equal(copies.status, 200, '17 copies of one id are one camera: the limit counts different ones');
  assert.deepEqual(Object.keys(copies.json.byCamera), [id]);

  const sixteen = await ask([id, ...others.slice(0, 15)]);
  assert.equal(sixteen.status, 200, sixteen.text);
  assert.equal(Object.keys(sixteen.json.byCamera).length, 16);
  const repeated = await ask([id, ...others.slice(0, 15), id, others[0], others[0].toLowerCase()]);
  assert.equal(repeated.status, 200, 'repeats do not push 16 different cameras over the limit');
  assert.equal(Object.keys(repeated.json.byCamera).length, 16);

  refused(await ask([id, ...others]), '17 different cameras');
  refused(await ask([id, ...others, id, ...others]), 'each of 17 different cameras twice');
  for (const [label, list] of [['an empty item between two ids', [id, '', others[0]]], ['a leading empty item', ['', id]], ['a trailing comma', [id, '']], ['no ids at all', ['']], ['text that is no id', [id, 'nope']]]) {
    refused(await ask(list), label);
  }
  const none = await server.api.get(`nvr/activity?from=${Date.now() - 600_000}&binMs=60000&bins=2`);
  refused(none, 'no cameras parameter');
});

// ---- scenarios -------------------------------------------------------------------------------------------------------------------

test('scenario noFolder: the banner asks for a folder, Record is refused, choosing the folder brings everything back', opts, async () => {
  await reset('noFolder');
  const { api } = server;
  const storage = (await api.get('nvr/storage')).json;
  assert.deepEqual([storage.location, storage.state, storage.message, storage.usedBytes, storage.oldest], [null, 'noFolder', 'Choose where to store recordings.', 0, null]);
  const notice = (await api.get('status')).json.notices.find((entry) => entry.id === 'nvr-storage');
  assert.deepEqual([notice.title, notice.detail, notice.action], ['Recording Can’t Continue', 'Choose where to store recordings.', 'choose-folder']);
  assert.equal((await api.get('nvr/cameras')).json.cameras.length, 0, 'an empty folder has no footage');
  const refused = await api.patch(`cameras/${camera('Shed')}/nvr`, { enabled: true });
  assert.deepEqual([refused.status, refused.json.error, refused.json.message], [409, 'folder_required', 'Choose where to store recordings first.']);
  assert.equal((await api.get(`cameras/${camera('Shed')}`)).json.nvrEnabled, false, 'nothing changed');
  const places = (await api.get('nvr/storage/locations')).json.locations;
  assert.deepEqual(places.map((place) => [place.id, place.current, place.writable]), [['builtin', false, true]]);
  const chosen = await api.patch('nvr/storage', { location: 'builtin' });
  assert.deepEqual([chosen.status, chosen.json.location, chosen.json.state], [200, 'builtin', 'ok']);
  assert.ok(chosen.json.freeBytes > 0 && chosen.json.totalBytes > 0 && chosen.json.floorBytes > 0 && chosen.json.effectiveMaxBytes > 0,
    'the answer to a folder change is a complete snapshot (the daemon once answered with the numbers from before the change: state noFolder, every byte count 0)');
  assert.deepEqual((await api.get('nvr/storage')).json, chosen.json, 'and equals what a GET says right after');
  assert.equal((await api.get('status')).json.notices.length, 0);
  assert.ok((await api.get('nvr/cameras')).json.cameras.length > 0);
  const enabled = await api.patch(`cameras/${camera('Shed')}/nvr`, { enabled: true });
  assert.equal(enabled.json.status.nvr.state, 'recording');
});

test('scenarios folderMissing, notWritable, stalled: recording is paused with the engine\'s sentence and the banner points to Settings', opts, async () => {
  const expected = {
    folderMissing: ['folderMissing', 'The recordings folder isn’t available. Reconnect the drive or choose another folder.'],
    notWritable: ['notWritable', 'Camera Bridge can’t write to that folder.'],
    stalled: ['notWritable', 'The drive isn’t answering.'],
  };
  for (const [scenario, [code, sentence]] of Object.entries(expected)) {
    await reset(scenario);
    const { api } = server;
    const storage = (await api.get('nvr/storage')).json;
    assert.deepEqual([storage.state, storage.message], [code, sentence], scenario);
    const cam = (await api.get(`cameras/${camera('Front Door')}`)).json;
    assert.deepEqual([cam.status.nvr.state, cam.status.nvr.pause, cam.status.nvr.detail], ['paused', code, sentence], scenario);
    const notice = (await api.get('status')).json.notices.find((entry) => entry.id === 'nvr-storage');
    assert.deepEqual([notice.detail, notice.action], [sentence, 'open-settings'], scenario);
    const place = (await api.get('nvr/storage/locations')).json.locations[0];
    assert.equal(place.writable, false, scenario);
    assert.ok(place.problem && place.freeBytes === null, scenario);
  }
});

test('scenario folderMissing: the catalog stays, reads are 410 gone', opts, async () => {
  await reset('folderMissing');
  const { api } = server;
  const cam = camera('Front Door');
  const plan = (await api.get(`nvr/cameras/${cam}/fragments?at=${Date.now() - HOUR}`)).json;
  assert.equal(plan.found, true, 'the plan is a memory lookup');
  const part = await api.get(`nvr/cameras/${cam}/fragments/${plan.parts[0].id}`);
  assert.deepEqual([part.status, part.json.error], [410, 'gone']);
  assert.equal((await api.get(`nvr/cameras/${cam}/keyframe?at=${Date.now() - HOUR}`)).status, 410);
});

test('scenario folderMissing flips back: the URLs that were 410 gone are served again and the camera records again (the page probes for this)', opts, async () => {
  await reset('folderMissing');
  const { api } = server;
  const cam = camera('Front Door');
  const plan = (await api.get(`nvr/cameras/${cam}/fragments?at=${Date.now() - HOUR}`)).json;
  const part = `nvr/cameras/${cam}/fragments/${plan.parts[0].id}`;
  const keyframe = `nvr/cameras/${cam}/keyframe?at=${Date.now() - HOUR}`;
  assert.deepEqual([(await api.get(part)).status, (await api.get(keyframe)).status], [410, 410]);
  assert.equal((await api.get(`cameras/${cam}`)).json.status.nvr.pause, 'folderMissing', 'the page reads this to tell a missing drive from retention');
  await api.dev('scenario', { name: 'ok' });                                      // the drive is plugged in again
  const back = await api.get(part);
  assert.deepEqual([back.status, back.headers['content-type']], [200, 'video/mp4']);
  assert.equal((await api.get(keyframe)).status, 200);
  const nvr = (await api.get(`cameras/${cam}`)).json.status.nvr;
  assert.deepEqual([nvr.state, nvr.pause], ['recording', null]);
  assert.equal((await api.get('status')).json.notices.length, 0, 'the banner is gone');
});

test('scenario stalled: reads wait, then 504 drive_slow with Retry-After 2; the folder check likewise', opts, async () => {
  await reset('stalled');
  const { api } = server;
  const cam = camera('Front Door');
  const plan = (await api.get(`nvr/cameras/${cam}/fragments?at=${Date.now() - HOUR}`)).json;
  const started = Date.now();
  const part = await api.get(`nvr/cameras/${cam}/fragments/${plan.parts[0].id}`);
  assert.deepEqual([part.status, part.json.error, part.headers['retry-after']], [504, 'drive_slow', '2']);
  assert.ok(Date.now() - started >= 140, 'it waited for the stall time');
  const choose = await api.patch('nvr/storage', { location: 'builtin' });
  assert.deepEqual([choose.status, choose.json.error, choose.headers['retry-after']], [504, 'drive_slow', '2']);
});

test('scenario diskFull: below the floor, recording paused and nothing deleted; lowSpace: the notice counts whole GB', opts, async () => {
  await reset('diskFull');
  let storage = (await server.api.get('nvr/storage')).json;
  assert.equal(storage.state, 'diskFull');
  assert.ok(storage.freeBytes < storage.floorBytes);
  assert.equal(storage.roomBytes, storage.usedBytes, 'no spare room');
  const used = storage.usedBytes;
  assert.equal((await server.api.get('nvr/cameras')).json.cameras.length, 9, 'the footage is still there');
  await reset('lowSpace');
  storage = (await server.api.get('nvr/storage')).json;
  assert.equal(storage.state, 'ok');
  const notice = (await server.api.get('status')).json.notices[0];
  assert.deepEqual([notice.title, notice.detail, notice.action], ['Recording Storage Almost Full', 'About 3 GB are left before recording pauses.', 'open-settings']);
  assert.equal(storage.usedBytes, used);
});

test('scenarios noArchive and loading: 503 with and without Retry-After, storage still answers', opts, async () => {
  await reset('noArchive');
  const { api } = server;
  const cam = camera('Front Door');
  const none = await api.get('nvr/cameras');
  assert.deepEqual([none.status, none.json.error, none.headers['retry-after']], [503, 'archive_unavailable', undefined]);
  assert.equal((await api.get(`nvr/cameras/${cam}/fragments?at=${Date.now()}`)).status, 503);
  assert.equal((await api.get('nvr/storage')).status, 200);
  await reset('loading');
  const loading = await api.get('nvr/cameras');
  assert.deepEqual([loading.status, loading.headers['retry-after']], [503, '2']);
  assert.deepEqual((await api.get(`cameras/${cam}`)).json.status.nvr.state, 'waiting');
  await sleep(450);
  assert.equal((await api.get('nvr/cameras')).status, 200, 'loading ends by itself');
});

// ---- settings and the camera flags ---------------------------------------------------------------------------------------------------

test('PATCH nvr/storage: ranges, unknown locations, confirm_required, and what a confirmed change does', opts, async () => {
  await reset();
  const { api } = server;
  assert.equal((await api.patch('nvr/storage', {})).status, 400);
  assert.deepEqual((await api.patch('nvr/storage', { keepDays: 0 })).json.field, 'keepDays');
  assert.deepEqual((await api.patch('nvr/storage', { maxSizeGB: 9 })).json.field, 'maxSizeGB');
  assert.equal((await api.patch('nvr/storage', { location: '/etc' })).json.error, 'folder_rejected');
  const before = (await api.get('nvr/storage')).json;
  const refused = await api.patch('nvr/storage', { keepDays: 1 });
  assert.deepEqual([refused.status, refused.json.error, refused.json.field], [409, 'confirm_required', 'confirm']);
  assert.match(refused.json.message, /^This will delete about \d+ GB of the oldest recordings\. Send confirm to continue\.$/);
  assert.equal((await api.get('nvr/storage')).json.keepDays, before.keepDays, 'a refused change changes nothing');
  assert.equal((await api.patch('nvr/storage', { keepDays: 30 })).status, 200, 'a looser limit needs no confirmation');
  const cam = camera('Front Door');
  const old = (await api.get(`nvr/cameras/${cam}/fragments?at=${Date.now() - 2.5 * DAY}`)).json;
  const confirmed = await api.patch('nvr/storage', { keepDays: 1, confirm: true });
  assert.equal(confirmed.status, 200);
  assert.ok(confirmed.json.usedBytes < before.usedBytes && confirmed.json.oldest > Date.now() - DAY - 16 * 60_000);
  assert.equal((await api.get(`nvr/cameras/${cam}/fragments/${old.parts[0].id}`)).json.error, 'gone', 'a removed fragment is 410');
  assert.equal((await api.get(`nvr/cameras/${cam}/fragments?at=${Date.now() - 2.5 * DAY}`)).json.reason, 'beforeStart');
  const size = await api.patch('nvr/storage', { maxSizeGB: 10, confirm: true });
  assert.equal(size.status, 200);
  assert.ok(size.json.usedBytes <= 10 * 1e9 + 4 * 1e9, `used ${size.json.usedBytes}: the open files stay`);
});

test('PATCH cameras/:id/nvr: the flags, the status and the footage follow', opts, async () => {
  await reset();
  const { api } = server;
  const shed = camera('Shed');
  assert.equal((await api.patch(`cameras/${shed}/nvr`, {})).status, 400);
  assert.equal((await api.patch(`cameras/${shed}/nvr`, { enabled: 'yes' })).json.field, 'enabled');
  assert.equal((await api.patch('cameras/FFFFFFFF-0000-4000-8000-000000000000/nvr', { enabled: true })).status, 404);
  const on = (await api.patch(`cameras/${shed}/nvr`, { enabled: true })).json;
  assert.deepEqual([on.nvrEnabled, on.status.nvr.state], [true, 'recording']);
  await sleep(2600);
  const extent = (await api.get('nvr/cameras')).json.cameras.find((entry) => entry.id === shed);
  assert.ok(Date.now() - extent.newest < 3500, 'the camera that was off now records up to the live edge');
  const sound = (await api.patch(`cameras/${shed}/nvr`, { recordSound: true })).json;
  assert.deepEqual([sound.nvrRecordSound, sound.status.nvr.notes], [true, [{ id: 'sound', text: 'sound could not be recorded' }]], 'sound without Camera audio on is accepted with a note');
  const off = (await api.patch(`cameras/${shed}/nvr`, { enabled: false })).json;
  assert.equal(off.status.nvr.state, 'off');
  const frozen = (await api.get('nvr/cameras')).json.cameras.find((entry) => entry.id === shed).newest;
  await sleep(1200);
  assert.equal((await api.get('nvr/cameras')).json.cameras.find((entry) => entry.id === shed).newest, frozen, 'a camera whose Record is off stops growing');
  assert.equal((await api.get('nvr/storage')).json.recordingCameras, 8);
});

test('record sound makes a new file whose footage says it has sound', opts, async () => {
  await reset();
  const { api } = server;
  const cam = camera('Front Door');
  await api.patch(`cameras/${cam}`, { audioEnabled: true });
  await api.patch(`cameras/${cam}/nvr`, { recordSound: true });
  await sleep(2600);
  const plan = (await api.get(`nvr/cameras/${cam}/fragments?at=${Date.now() - 1500}&ahead=0`)).json;
  assert.equal(plan.found, true);
  assert.equal(Object.values(plan.files)[0].sound, true);
  const earlier = (await api.get(`nvr/cameras/${cam}/fragments?at=${Date.now() - HOUR}&ahead=0`)).json;
  assert.equal(Object.values(earlier.files)[0].sound, false, 'what was recorded before stays as it was');
});

// ---- admission, clock, events, the keyframe fix --------------------------------------------------------------------------------------------

test('admission: at most 6 archive requests at once from one address, the rest 429 busy with Retry-After 1 at once; 8 in all', opts, async () => {
  await reset();
  const cam = camera('Front Door');
  await server.api.dev('options', { latencyMs: 250 });
  const path = `nvr/cameras/${cam}/keyframe?at=${Date.now() - HOUR}`;
  const answers = await Promise.all(Array.from({ length: 40 }, () => server.api.get(path)));
  const busy = answers.filter((answer) => answer.status === 429);
  assert.equal(answers.filter((answer) => answer.status === 200).length + busy.length, 40, 'every answer is 200 or 429');
  assert.ok(busy.length >= 20, `${busy.length} of 40 were refused`);
  assert.ok(busy.every((answer) => answer.json.error === 'busy' && answer.headers['retry-after'] === '1'));
  let { slots } = (await server.api.dev('state')).json;
  assert.deepEqual([slots.peakByAddress, slots.peakTotal, slots.total], [6, 6, 0], 'six at most at once from one address, and every slot given back');
  await server.api.dev('options', { maximumArchiveReadsPerAddress: 20 });
  await Promise.all(Array.from({ length: 40 }, () => server.api.get(path)));
  slots = (await server.api.dev('state')).json.slots;
  assert.deepEqual([slots.peakTotal, slots.total], [8, 0], 'eight in all');
  await server.api.dev('options', { maximumArchiveReadsPerAddress: 6, latencyMs: 0 });
});

test('a request that fails validation never takes a slot, and health answers during a burst', opts, async () => {
  await reset();
  await server.api.dev('options', { latencyMs: 300 });
  const cam = camera('Front Door');
  const burst = Array.from({ length: 6 }, () => server.api.get(`nvr/cameras/${cam}/keyframe?at=${Date.now() - HOUR}`));
  await sleep(50);
  const invalid = await server.api.get(`nvr/cameras/${cam}/keyframe?at=nonsense`);
  assert.equal(invalid.status, 400, 'a malformed request is answered with its error, not 429');
  const started = Date.now();
  assert.equal((await client(server.base).get('health', { auth: false })).status, 200);
  assert.ok(Date.now() - started < 200);
  await Promise.all(burst);
  await server.api.dev('options', { latencyMs: 0 });
});

test('a small pretend drive keeps what fits and warns about its size', opts, async () => {
  const small = await startDevServer({ diskGB: 100 });
  try {
    const storage = (await small.api.get('nvr/storage')).json;
    assert.ok(storage.usedBytes <= storage.effectiveMaxBytes, `${storage.usedBytes} bytes in a store limited to ${storage.effectiveMaxBytes}`);
    assert.ok(storage.effectiveMaxBytes < 100e9 && storage.effectiveMaxBytes > 60e9);
    assert.match((await small.api.get('nvr/storage/locations')).json.locations[0].warning, /^Small drive: room for about \d+ GB$/);
    assert.ok((await small.api.get('nvr/cameras')).json.cameras.every((entry) => entry.newest - entry.oldest > 0), 'every camera keeps some footage');
  } finally {
    await small.close();
  }
});

test('the server clock can be moved: serverTime and the footage follow it', opts, async () => {
  await reset();
  const before = (await server.api.get('nvr/cameras')).json;
  await server.api.dev('clock', { offsetMs: 3_600_000 });
  const after = (await server.api.get('nvr/cameras')).json;
  assert.ok(after.serverTime - before.serverTime > 3_599_000 && after.serverTime - before.serverTime < 3_602_000);
  assert.ok(after.cameras[0].newest - before.cameras[0].newest > 3_590_000, 'the live edge moved with the clock');
  await server.api.dev('clock', { offsetMs: 0 });
});

test('events: a snapshot (bridge, nine cameras, notices), then a camera event and a notices event when things change', opts, async () => {
  await reset();
  const received = [];
  const request = http.get(`${server.base}/api/v1/events`, { headers: { Cookie: server.api.cookie, Accept: 'text/event-stream' } });
  const done = new Promise((resolve) => {
    request.on('response', (response) => {
      assert.equal(response.headers['content-type'], 'text/event-stream; charset=utf-8');
      assert.equal(response.headers['content-security-policy'], CSP);
      let buffer = '';
      response.on('data', (chunk) => { buffer += chunk; });
      const timer = setInterval(() => {
        const names = [...buffer.matchAll(/^event: (\w+)$/gm)].map((match) => match[1]);
        received.splice(0, received.length, ...names);
        if (names.filter((name) => name === 'notices').length >= 2 && names.filter((name) => name === 'camera').length >= 10) { clearInterval(timer); resolve(buffer); }
      }, 25);
      setTimeout(() => { clearInterval(timer); resolve(buffer); }, 4000);
    });
  });
  await sleep(150);
  await server.api.dev('scenario', { name: 'diskFull' });
  const text = await done;
  request.destroy();
  assert.match(text, /^retry: 3000\n\nevent: bridge\n/);
  assert.equal(received.filter((name) => name === 'camera').length >= 10, true, `camera events: ${received.join(',')}`);
  assert.ok(received.filter((name) => name === 'notices').length >= 2, 'a notices event after the scenario changed');
  assert.match(text, /Recording Can’t Continue/);
});

test('optimize: needs confirm, fixes the keyframe interval of new footage once, can be undone', opts, async () => {
  await reset();
  const { api } = server;
  const cam = camera('Garage');
  assert.equal((await api.post(`cameras/${cam}/optimize`, {})).status, 400);
  assert.equal((await api.post(`cameras/${cam}/optimize/undo`, {})).json.error, 'optimize_failed');
  const result = await api.post(`cameras/${cam}/optimize`, { confirm: true });
  assert.equal(result.status, 200);
  assert.deepEqual([result.json.failed, result.json.canUndo, typeof result.json.scoreBefore, result.json.applied.length > 0], [[], true, 'number', true]);
  assert.equal((await api.post(`cameras/${cam}/optimize`, { confirm: true })).json.applied.length, 0, 'a second time changes nothing');
  assert.equal((await api.post(`cameras/${cam}/optimize/undo`, {})).status, 204);
  assert.equal((await api.post(`cameras/${cam}/optimize/undo`, {})).status, 422);
});

test('whatever is sent, the server answers with a status below 500', opts, async () => {
  await reset();
  const cam = camera('Driveway');
  const junk = ['', '0', '-1', '1e9', 'NaN', 'null', '%00', '9'.repeat(30), 'a'.repeat(1500), '../../etc/passwd', '{"a":1}', '1,2', '😀'];
  const paths = [];
  for (const value of junk) {
    const q = encodeURIComponent(value);
    paths.push(`nvr/cameras/${cam}/fragments?at=${q}`, `nvr/cameras/${cam}/fragments?after=${q}`, `nvr/cameras/${cam}/fragments?at=1790000000000&ahead=${q}`, `nvr/cameras/${cam}/keyframe?at=${q}`,
      `nvr/activity?cameras=${q}&from=${q}&binMs=${q}&bins=${q}`, `nvr/cameras/${q}/fragments?at=1790000000000`, `nvr/cameras/${cam}/fragments/${q}`, `nvr/cameras/${cam}/fragments/${q}/init`);
  }
  for (const path of paths) {
    const response = await server.api.get(path);
    assert.ok(response.status < 500, `${path.slice(0, 100)} answered ${response.status}`);
    assert.ok(response.json?.error || response.status === 200, `${path.slice(0, 100)}: ${response.status} without an error body`);
  }
  for (const body of ['', '{', '[]', '"x"', 'null', '{"keepDays":{}}', '{"location":null}', '{"enabled":[]}']) {
    for (const path of ['nvr/storage', `cameras/${cam}/nvr`]) {
      const response = await server.api.send('PATCH', path, { body, type: 'application/json' });
      assert.ok(response.status >= 400 && response.status < 500, `${path} with ${body} answered ${response.status}`);
    }
  }
});
