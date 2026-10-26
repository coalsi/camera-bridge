// Sky Watcher on the dev server (web-dev/lib/sky.mjs): the plugin and its switch (GET plugins, PATCH plugins/sky: off when the server starts, as
// on a new box), and, once it is on, the routes of Task 5's API with a made-up night to read: GET sky/cameras/:id/night, the still, POST
// …/correction, POST sky/feeds/find, `sky` in the settings, and PATCH cameras/:id with `skyDetector` and the bridge's refusals.
// And the page itself (sky-log.js, sky-card.js) against it, in a fake browser whose fetch talks to the real server.
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
const camera = (name) => CAMERA_DEFINITIONS.find((definition) => definition.name === name).id;
const BACKYARD = () => camera('Back Yard');
let server;
/** The server's clock at `hour:minute` local time today (it keeps running from there), so what a night holds does not depend on when the test runs. */
const clockAt = (hour, minute = 0) => {
  const at = new Date();
  at.setHours(hour, minute, 0, 0);
  return server.api.dev('clock', { offsetMs: at.getTime() - Date.now() });
};
before(async () => {
  if (fixtures.skip) return;
  server = await startDevServer();
  await clockAt(10);
});
after(async () => { await server?.close(); });
const reset = () => server.api.dev('reset', {});
/** A reset with the Sky Watcher plugin switched on, as the person does in Plugins: the made-up night is there to read. */
const ready = async () => {
  await reset();
  const on = await server.api.patch('plugins/sky', { enabled: true });
  assert.equal(on.status, 200);
};
const night = (id, query = '') => server.api.get(`sky/cameras/${id}/night${query}`);
const NEED_LOCATION = 'Set where the box is first.';
const NEED_FOLDER = 'Choose a recordings folder first: the sky log is kept with the recordings.';
const BATTERY = 'Battery cameras can’t watch the sky: it would keep them awake.';

// MARK: Settings

test('the settings carry sky: a made-up place, no flight feed, 50 pictures a day', opts, async () => {
  await reset();
  const { json } = await server.api.get('settings');
  assert.deepEqual(json.sky, { location: { latitude: 40, longitude: -100, heightMeters: 0 }, flightFeedURL: null, aiDailyLimit: 50 });
  assert.equal(json.bridgeName, 'Camera Bridge Dev', 'the rest of the settings are as they were');
});

test('PATCH settings sky keeps a valid place, a feed and a limit, and refuses the rest with the field', opts, async () => {
  await reset();
  const patch = (sky) => server.api.patch('settings', { sky });
  const changed = await patch({ location: { latitude: 41.5, longitude: -101.25 }, flightFeedURL: 'http://192.168.77.20/tar1090/data/aircraft.json', aiDailyLimit: 80 });
  assert.equal(changed.status, 200);
  assert.deepEqual(changed.json.sky, { location: { latitude: 41.5, longitude: -101.25, heightMeters: 0 }, flightFeedURL: 'http://192.168.77.20/tar1090/data/aircraft.json', aiDailyLimit: 80 });
  assert.deepEqual((await server.api.get('settings')).json.sky, changed.json.sky, 'and it is kept');

  for (const [sky, field] of [
    [{ location: { latitude: 91, longitude: 0.5 } }, 'sky.location'],
    [{ location: { latitude: 10, longitude: -181 } }, 'sky.location'],
    [{ location: { latitude: 0, longitude: 0 } }, 'sky.location'],
    [{ location: { latitude: 'north', longitude: 5 } }, 'sky.location'],
    [{ flightFeedURL: 'ftp://192.168.77.20/aircraft.json' }, 'sky.flightFeedURL'],
    [{ flightFeedURL: 'http://' }, 'sky.flightFeedURL'],
    [{ aiDailyLimit: 0 }, 'sky.aiDailyLimit'],
    [{ aiDailyLimit: 1001 }, 'sky.aiDailyLimit'],
  ]) {
    const refused = await patch(sky);
    assert.equal(refused.status, 400, JSON.stringify(sky));
    assert.equal(refused.json.error, 'invalid');
    assert.equal(refused.json.field, field, JSON.stringify(sky));
    assert.ok(refused.json.message.length > 10);
  }
  assert.equal((await server.api.get('settings')).json.sky.aiDailyLimit, 80, 'a refusal changes nothing');

  const cleared = await patch({ location: null, flightFeedURL: null });
  assert.deepEqual([cleared.json.sky.location, cleared.json.sky.flightFeedURL], [null, null]);
  await reset();
  assert.equal((await server.api.get('settings')).json.sky.location.latitude, 40, 'a reset puts it back');
});

// MARK: The plugin

const PLUGIN_SENTENCE = 'Turn on Sky Watcher in Plugins first.';
const SUMMARY = 'Watches the sky with a camera pointed up and keeps a log of planes, satellites, meteors and anything it can’t explain.';

test('Sky Watcher is a plugin that is off when the server starts, and its switch turns it on and off', opts, async () => {
  await reset();
  const list = await server.api.get('plugins');
  assert.equal(list.status, 200);
  assert.deepEqual(list.json.plugins.map((plugin) => plugin.id), ['sky'], 'the one plugin this server has');
  const [plugin] = list.json.plugins;
  assert.deepEqual([plugin.name, plugin.summary, plugin.enabled, plugin.needsInternet], ['Sky Watcher', SUMMARY, false, false]);
  assert.equal(typeof plugin.needs, 'string');
  assert.equal(typeof plugin.internetNote, 'string');
  assert.ok(!('account' in plugin) && !('lastError' in plugin), 'no account, nothing to sign in to');

  const on = await server.api.patch('plugins/sky', { enabled: true });
  assert.equal(on.status, 200);
  assert.equal(on.json.plugins[0].enabled, true, 'the answer is the list, as the bridge’s is');
  assert.equal((await server.api.get('plugins')).json.plugins[0].enabled, true, 'and it is kept');
  assert.equal((await server.api.patch('plugins/sky', { enabled: false })).json.plugins[0].enabled, false);

  for (const [body, status, field] of [[{}, 400, 'enabled'], [{ enabled: 'yes' }, 400, 'enabled'], [{ enabled: null }, 400, 'enabled']]) {
    const refused = await server.api.patch('plugins/sky', body);
    assert.deepEqual([refused.status, refused.json.field], [status, field], JSON.stringify(body));
  }
  assert.equal((await server.api.patch('plugins/nope', { enabled: true })).status, 404, 'there is no plugin by that name');
  assert.equal((await server.api.get('plugins', { auth: false })).status, 401);
  assert.equal((await server.api.patch('plugins/sky', { enabled: true }, { auth: false })).status, 401);
  assert.equal((await server.api.patch('plugins/sky', { enabled: true }, { csrf: false })).status, 403, 'a change needs the token');
  assert.equal((await server.api.get('plugins')).json.plugins[0].enabled, false, 'nothing of that changed it');
  await reset();
});

test('the development switch and a reset put the plugin on and off', opts, async () => {
  await reset();
  const view = async () => (await server.api.get('plugins')).json.plugins[0].enabled;
  assert.equal(await view(), false);
  await server.api.dev('sky', { plugin: true });
  assert.equal(await view(), true);
  await server.api.dev('sky', { plugin: false });
  assert.equal(await view(), false);
  await server.api.dev('sky', { plugin: true });
  const bad = await server.api.dev('sky', { plugin: 'maybe' });
  assert.notEqual(bad.status, 200, 'a switch that is not on or off is refused');
  assert.equal(await view(), true, 'and changes nothing');
  await reset();
  assert.equal(await view(), false, 'a reset is a new box');
});

test('while the plugin is off Back Yard keeps what it was set to, the box reports nothing about the sky, and no camera can be turned on', opts, async () => {
  await reset();
  const back = (await server.api.get(`cameras/${BACKYARD()}`)).json;
  assert.deepEqual(back.skyDetector, { enabled: true, facing: 0, tilt: 20, groundPercent: 12, nightProfile: true, lensLayout: 'dual' }, 'its settings are kept');
  assert.equal(back.status.sky, undefined, 'and nothing runs');
  assert.deepEqual((await server.api.get('cameras')).json.cameras.filter((entry) => entry.status.sky).map((entry) => entry.name), []);

  const driveway = camera('Driveway');
  const body = { skyDetector: { enabled: true, facing: 90, tilt: 30, groundPercent: 10, nightProfile: true, lensLayout: 'single' } };
  const refused = await server.api.patch(`cameras/${driveway}`, body);
  assert.deepEqual([refused.status, refused.json.error, refused.json.message, refused.json.field], [400, 'invalid', PLUGIN_SENTENCE, 'plugins.sky']);
  assert.equal((await server.api.get(`cameras/${driveway}`)).json.skyDetector, undefined, 'nothing was turned on');
  // The plugin comes before the other limits: with no place and a camera on a battery it is still the first thing to do.
  await server.api.dev('sky', { location: null });
  assert.equal((await server.api.patch(`cameras/${camera('Porch')}`, body)).json.message, PLUGIN_SENTENCE);
  await server.api.dev('sky', { location: { latitude: 40, longitude: -100 } });

  // Saving “off” and the aim still works, and the made-up night can still be read.
  const aimed = await server.api.patch(`cameras/${BACKYARD()}`, { skyDetector: { facing: 90 } });
  assert.deepEqual([aimed.status, aimed.json.skyDetector.facing, aimed.json.skyDetector.enabled], [200, 90, true]);
  assert.equal((await night(BACKYARD())).status, 200, 'the log is on the drive, and reading it asks for nothing');
  const stopped = await server.api.patch(`cameras/${BACKYARD()}`, { skyDetector: { enabled: false } });
  assert.deepEqual([stopped.status, stopped.json.skyDetector.enabled], [200, false]);

  // Switched on, the same cameras are back: Back Yard watches again, with its status; the refused one can be turned on now.
  await server.api.patch(`cameras/${BACKYARD()}`, { skyDetector: { enabled: true } }).then((answer) => assert.equal(answer.status, 400, 'turning it on again needs the plugin too'));
  assert.equal((await server.api.patch('plugins/sky', { enabled: true })).status, 200);
  const again = await server.api.patch(`cameras/${BACKYARD()}`, { skyDetector: { enabled: true } });
  assert.equal(again.status, 200);
  assert.equal(again.json.status.sky.running, true);
  assert.equal((await server.api.patch(`cameras/${driveway}`, body)).status, 200);
  // Off again: the status goes, the settings stay.
  await server.api.patch('plugins/sky', { enabled: false });
  const kept = (await server.api.get(`cameras/${driveway}`)).json;
  assert.deepEqual([kept.skyDetector.enabled, kept.skyDetector.facing, kept.status.sky], [true, 90, undefined]);
  await reset();
});

test('the plugin’s words are the box’s: the dev server says what Plugins.swift says', opts, async () => {
  const { readFileSync } = await import('node:fs');
  const swift = readFileSync(new URL('../../Packages/CameraBridgeKit/Sources/BridgeWeb/Plugins/Plugins.swift', import.meta.url), 'utf8');
  const sky = swift.slice(swift.indexOf('id: SkyWatcherPlugin.id'));
  await reset();
  const [plugin] = (await server.api.get('plugins')).json.plugins;
  for (const key of ['name', 'summary', 'needs', 'internetNote']) assert.ok(sky.includes(JSON.stringify(plugin[key]).slice(1, -1)), `${key}: ${plugin[key]}`);
  const bridge = readFileSync(new URL('../../Packages/CameraBridgeKit/Sources/BridgeWeb/Plugins/SkyWatcherPlugin.swift', import.meta.url), 'utf8');
  assert.ok(bridge.includes(`"${PLUGIN_SENTENCE}"`) && bridge.includes('"plugins.sky"'), 'the refusal is worded as the box words it');
});

// MARK: Turning it on

test('a camera that watches the sky has its settings and its status; the others have neither', opts, async () => {
  await ready();
  const back = (await server.api.get(`cameras/${BACKYARD()}`)).json;
  assert.deepEqual(back.skyDetector, { enabled: true, facing: 0, tilt: 20, groundPercent: 12, nightProfile: true, lensLayout: 'dual' });
  assert.deepEqual(Object.keys(back.status.sky).sort(), ['aim', 'analysisWidth', 'learning', 'picturesPerSecond', 'problem', 'profile', 'running', 'stream']);
  assert.deepEqual([back.status.sky.running, back.status.sky.stream, back.status.sky.analysisWidth, back.status.sky.picturesPerSecond], [true, 'main', 1920, 5]);
  assert.equal(back.status.sky.aim.lenses.length, 2, 'two lenses');
  assert.ok(['rough', 'good', 'precise'].includes(back.status.sky.aim.quality));
  assert.equal(back.status.sky.learning.ready, false);
  const { cameras } = (await server.api.get('cameras')).json;
  assert.deepEqual(cameras.filter((entry) => entry.skyDetector).map((entry) => entry.name), ['Back Yard']);
  assert.deepEqual(cameras.filter((entry) => entry.status.sky).map((entry) => entry.name), ['Back Yard']);
});

test('enabling needs a place and a folder, and a camera on a battery cannot; with them it works and the status appears', opts, async () => {
  await ready();
  const driveway = camera('Driveway');
  const body = { skyDetector: { enabled: true, facing: 90, tilt: 30, groundPercent: 10, nightProfile: true, lensLayout: 'single' } };

  await server.api.dev('sky', { location: null });
  const noPlace = await server.api.patch(`cameras/${driveway}`, body);
  assert.deepEqual([noPlace.status, noPlace.json.error, noPlace.json.message, noPlace.json.field], [400, 'invalid', NEED_LOCATION, 'sky.location']);
  assert.equal((await server.api.get(`cameras/${driveway}`)).json.skyDetector, undefined, 'nothing was turned on');

  await server.api.dev('sky', { location: { latitude: 40, longitude: -100 } });
  await server.api.dev('scenario', { name: 'noFolder' });
  const noFolder = await server.api.patch(`cameras/${driveway}`, body);
  assert.deepEqual([noFolder.status, noFolder.json.message, noFolder.json.field], [400, NEED_FOLDER, 'nvrFolder']);
  await server.api.dev('scenario', { name: 'ok' });

  const battery = await server.api.patch(`cameras/${camera('Porch')}`, body);
  assert.deepEqual([battery.status, battery.json.message], [400, BATTERY]);

  const on = await server.api.patch(`cameras/${driveway}`, body);
  assert.equal(on.status, 200);
  assert.deepEqual(on.json.skyDetector, body.skyDetector);
  assert.equal(on.json.status.sky.running, true);
  assert.equal(on.json.name, 'Driveway');

  const off = await server.api.patch(`cameras/${driveway}`, { skyDetector: { ...body.skyDetector, enabled: false } });
  assert.equal(off.json.skyDetector.enabled, false);
  assert.equal(off.json.status.sky, undefined, 'no status while it is off');

  // Settings that are not settings.
  for (const [value, field] of [[{ ...body.skyDetector, facing: 360 }, 'skyDetector.facing'], [{ ...body.skyDetector, tilt: 91 }, 'skyDetector.tilt'],
    [{ ...body.skyDetector, groundPercent: 61 }, 'skyDetector.groundPercent'], [{ ...body.skyDetector, lensLayout: 'triple' }, 'skyDetector.lensLayout'],
    [{ ...body.skyDetector, enabled: 'yes' }, 'skyDetector.enabled'], ['on', 'skyDetector']]) {
    const refused = await server.api.patch(`cameras/${driveway}`, { skyDetector: value });
    assert.deepEqual([refused.status, refused.json.field], [400, field], JSON.stringify(value));
  }
  await reset();
});

// MARK: The night

test('the night route answers the log as Task 5 describes it', opts, async () => {
  await ready();
  const { status, json } = await night(BACKYARD());
  assert.equal(status, 200);
  assert.deepEqual(Object.keys(json).sort(), ['aim', 'camera', 'capped', 'conditions', 'counts', 'entries', 'from', 'learning', 'night', 'serverTime', 'to', 'view']);
  assert.ok(Array.isArray(json.capped) && json.capped.every((hour) => Number.isInteger(hour.hour) && Number.isInteger(hour.count) && hour.count > 0),
    'the hours with more lights than were logged: [{ hour, count }]');
  assert.equal(json.camera, BACKYARD());
  assert.match(json.night, /^\d{4}-\d{2}-\d{2}$/);
  assert.equal(json.view, 'night');
  assert.ok(Number.isInteger(json.from) && Number.isInteger(json.to) && json.to - json.from > 11 * 3_600_000 && json.to - json.from < 14 * 3_600_000, 'epoch ms, sunset to sunrise');
  assert.equal(new Date(json.serverTime).getHours(), 10, 'the server’s clock, which these tests set to 10 in the morning');

  // A busy night: dozens of planes, hundreds of satellites, a few that nothing explains.
  const { counts, entries } = json;
  assert.ok(counts.planes >= 30 && counts.satellites >= 150 && counts.meteors >= 1 && counts.bugsAndBirds >= 3 && counts.unexplained >= 3, JSON.stringify(counts));
  assert.equal(counts.explained, counts.planes + counts.satellites + counts.meteors + counts.bugsAndBirds + counts.notSure);
  const finished = entries.filter((entry) => entry.end <= json.serverTime);
  assert.equal(finished.length, entries.length, 'nothing that has not happened yet');
  for (const key of ['unexplained', 'planes', 'satellites', 'meteors', 'bugsAndBirds']) {
    const found = entries.filter((entry) => ({ unexplained: ['unexplained'], planes: ['plane', 'probablePlane'], satellites: ['satellite', 'satelliteFlare'], meteors: ['meteor'], bugsAndBirds: ['bug', 'bird'] })[key].includes(entry.display)).length;
    assert.equal(counts[key], found, `${key} counted as the entries say`);
  }

  // Every entry has the fields of SkyEntry, with `display` and `watch`; times are epoch ms, optional fields null.
  const keys = ['ai', 'alerted', 'by', 'camera', 'candidate', 'correction', 'detail', 'display', 'end', 'hasStill', 'id', 'kind', 'label', 'measures', 'path', 'speedVsPlanes', 'start', 'unusual', 'watch'];
  for (const entry of entries) {
    assert.deepEqual(Object.keys(entry).sort(), keys, entry.id);
    assert.equal(entry.watch, entry.start - 3000);
    assert.ok(['track', 'newLight', 'flash'].includes(entry.kind));
    assert.ok(Number.isInteger(entry.start) && entry.end >= entry.start && entry.start >= json.from && entry.end <= json.to);
    assert.ok(entry.path.length <= 64 && entry.path.every((point) => point.x >= 0 && point.x <= 1 && point.y >= 0 && point.y <= 1 && point.t >= 0));
    assert.equal(entry.display, entry.label, 'nothing corrected yet');
    assert.equal(entry.camera, BACKYARD());
    for (const name of ['azimuth', 'elevation', 'duration', 'speed', 'straightness', 'sizeDegrees', 'brightness', 'focus']) assert.equal(typeof entry.measures[name], 'number', `${entry.id} ${name}`);
    assert.ok(['straight', 'curved', 'suddenStop', 'sharpTurn'].includes(entry.measures.shape));
  }
  const planes = entries.filter((entry) => entry.label === 'plane');
  assert.match(planes[0].detail, /^[A-Z0-9]+ · \d{1,2},\d00 ft$/);
  assert.ok(entries.filter((entry) => entry.label === 'satellite').every((entry) => typeof entry.detail === 'string' && entry.detail.length > 3), 'a satellite has its name');
  const unexplained = entries.filter((entry) => entry.label === 'unexplained');
  assert.ok(unexplained.every((entry) => entry.hasStill), 'a still for each');
  assert.ok(unexplained.some((entry) => entry.kind === 'newLight'), 'lights that rise, hold and fade');
  assert.ok(unexplained.some((entry) => entry.kind === 'track' && entry.ai && entry.speedVsPlanes > 1), 'a fast track with the AI’s sentence');
  assert.ok(entries.some((entry) => entry.kind === 'flash' && entry.label === 'probablePlane' && entry.measures.elevation < 8 && entry.measures.blinks), 'strobes crawling along the horizon');
  const waves = entries.filter((entry) => entry.label === 'satellite').map((entry) => (entry.start - json.from) / (json.to - json.from));
  assert.ok(waves.some((x) => x < 0.2) && waves.some((x) => x > 0.8), 'satellites in waves after dusk and before dawn');
  assert.ok(waves.every((x) => x < 0.3 || x > 0.7), 'and none in the middle of the night');

  // Conditions: spans inside the night, in order, with the states the page reads.
  assert.ok(json.conditions.length >= 1);
  for (const span of json.conditions) {
    assert.ok(['clear', 'cloudy', 'notVisible', 'unknown'].includes(span.state));
    assert.ok(span.from >= json.from && span.to <= json.to && span.to > span.from);
  }
  assert.deepEqual(Object.keys(json.aim).sort(), ['lenses', 'note', 'planes', 'quality', 'residualPixels', 'stars', 'updated']);
  assert.deepEqual(Object.keys(json.learning).sort(), ['planes', 'ready', 'satellites']);
});

test('a night is the same on every ask, a date asks for another night, and the day view is a whole day', opts, async () => {
  await ready();
  const first = (await night(BACKYARD())).json;
  const again = (await night(BACKYARD())).json;
  assert.deepEqual(again.entries, first.entries, 'the same night, entry for entry');
  const same = (await night(BACKYARD(), `?date=${first.night}&view=night`)).json;
  assert.deepEqual(same.entries, first.entries, 'asked for by its date');
  const older = (await night(BACKYARD(), '?date=2020-01-01')).json;
  assert.deepEqual([older.night, older.entries.length, older.counts.explained, older.counts.unexplained], ['2020-01-01', 0, 0, 0], 'a night long ago is empty');
  const earlier = new Date(first.from - 20 * 3_600_000);
  const name = `${earlier.getFullYear()}-${String(earlier.getMonth() + 1).padStart(2, '0')}-${String(earlier.getDate()).padStart(2, '0')}`;
  const before = (await night(BACKYARD(), `?date=${name}`)).json;
  assert.equal(before.night, name);
  assert.ok(before.entries.length > 50, 'the night before has a log too');
  assert.notDeepEqual(before.entries.map((entry) => entry.id), first.entries.map((entry) => entry.id).slice(0, before.entries.length));
  const day = (await night(BACKYARD(), '?view=day')).json;
  assert.equal(day.view, 'day');
  assert.ok([23, 24, 25].includes((day.to - day.from) / 3_600_000), 'a day (23 or 25 hours where the clocks change)');
  assert.ok(day.counts.planes > 0 && day.counts.satellites === 0, 'planes by day, no satellites in sight');
  const future = (await night(BACKYARD(), '?date=2099-01-01')).json;
  assert.equal(future.entries.length, 0);

  assert.equal((await night(BACKYARD(), '?date=yesterday')).status, 400);
  assert.equal((await night(BACKYARD(), '?date=2026-02-30')).status, 400);
  assert.equal((await night(BACKYARD(), '?view=week')).json.field, 'view');
  assert.equal((await night('0A1B2C3D-0000-4000-8000-0000000000FF')).status, 404, 'no such camera');
  assert.equal((await night('not-an-id')).status, 404);
  assert.equal((await night(camera('Front Door'))).json.entries.length, 0, 'a camera that never watched the sky has nothing');
  assert.equal((await server.api.get(`sky/cameras/${BACKYARD()}/night`, { auth: false })).status, 401);
});

test('a night still going has only what has happened, and its window ends ahead of the server’s clock', opts, async () => {
  await ready();
  await clockAt(2, 30);
  try {
    const { json } = await night(BACKYARD());
    assert.ok(json.to > json.serverTime && json.from < json.serverTime, 'now is inside the night');
    assert.ok(json.entries.length > 20 && json.entries.every((entry) => entry.end <= json.serverTime));
    const waves = json.entries.filter((entry) => entry.label === 'satellite').map((entry) => (entry.start - json.from) / (json.to - json.from));
    assert.ok(waves.length > 50 && waves.every((x) => x < 0.3), 'the evening’s satellites, not the morning’s yet');
    assert.ok(json.conditions.every((span) => span.to <= json.serverTime), 'conditions are known up to now');
  } finally {
    await clockAt(10);
  }
});

// MARK: The still and the correction

test('a still is a JPEG for an entry that has one, and 404 for the rest', opts, async () => {
  await ready();
  const { entries, night: name } = (await night(BACKYARD())).json;
  const withStill = entries.find((entry) => entry.hasStill);
  const without = entries.find((entry) => !entry.hasStill);
  const still = await server.api.get(`sky/cameras/${BACKYARD()}/entries/${withStill.id}/still?night=${name}`);
  assert.equal(still.status, 200);
  assert.equal(still.headers['content-type'], 'image/jpeg');
  assert.deepEqual([still.buffer[0], still.buffer[1]], [0xff, 0xd8], 'a JPEG');
  assert.ok(still.buffer.length > 1000 && still.buffer.length < 50_000);
  for (const path of [`${without.id}/still?night=${name}`, `nothing/still?night=${name}`, `${withStill.id}/still?night=2020-01-01`, `${withStill.id}/still`]) {
    const missing = await server.api.get(`sky/cameras/${BACKYARD()}/entries/${path}`);
    assert.equal(missing.status, 404, path);
    assert.equal(missing.json.error, 'not_found');
  }
  assert.equal((await server.api.get(`sky/cameras/${BACKYARD()}/entries/${withStill.id}/still?night=${name}`, { auth: false })).status, 401);
});

test('a correction is kept and answered with the entry; the night shows it afterwards', opts, async () => {
  await ready();
  const before = (await night(BACKYARD())).json;
  const lonely = before.entries.find((entry) => entry.label === 'unexplained');
  const post = (id, body) => server.api.post(`sky/cameras/${BACKYARD()}/entries/${id}/correction`, body);

  const bird = await post(lonely.id, { night: before.night, label: 'bird' });
  assert.equal(bird.status, 200);
  assert.equal(bird.json.id, lonely.id);
  assert.deepEqual([bird.json.correction, bird.json.display, bird.json.label], ['bird', 'bird', 'unexplained']);
  assert.equal(bird.json.watch, lonely.watch);
  const after = (await night(BACKYARD())).json;
  assert.equal(after.entries.find((entry) => entry.id === lonely.id).correction, 'bird');
  assert.equal(after.counts.unexplained, before.counts.unexplained - 1);
  assert.equal(after.counts.bugsAndBirds, before.counts.bugsAndBirds + 1);
  assert.equal(after.counts.explained, before.counts.explained + 1);

  const plane = before.entries.find((entry) => entry.label === 'plane');
  const notSure = await post(plane.id, { night: before.night, label: 'notSure' });
  assert.deepEqual([notSure.json.correction, notSure.json.display], ['notSure', 'plane'], 'not sure keeps the entry’s own label');
  const counted = (await night(BACKYARD())).json.counts;
  assert.deepEqual([counted.planes, counted.notSure], [before.counts.planes - 1, 1]);

  const bad = await post(lonely.id, { night: before.night, label: 'ufo' });
  assert.deepEqual([bad.status, bad.json.error, bad.json.field], [400, 'invalid', 'label']);
  assert.equal((await post('nothing', { night: before.night, label: 'bird' })).status, 404);
  assert.equal((await post(lonely.id, { night: '2020-01-01', label: 'bird' })).status, 404);
  assert.equal((await post(lonely.id, { night: 'later', label: 'bird' })).status, 400);
  await reset();
  assert.equal((await night(BACKYARD())).json.entries.find((entry) => entry.id === lonely.id).correction, null, 'a reset forgets corrections');
});

test('Find a feed answers the feeds on the network, and the development switch changes them', opts, async () => {
  await ready();
  const found = await server.api.post('sky/feeds/find');
  assert.equal(found.status, 200);
  assert.deepEqual(found.json, { feeds: ['http://192.168.77.20/tar1090/data/aircraft.json'] });
  await server.api.dev('sky', { feeds: [] });
  assert.deepEqual((await server.api.post('sky/feeds/find')).json, { feeds: [] });
  await reset();
});

test('the development switch changes the aim, what the box is learning and the trouble it reports', opts, async () => {
  await ready();
  const aim = async () => (await server.api.get(`cameras/${BACKYARD()}`)).json.status.sky;
  await server.api.dev('sky', { aim: 'rough', learning: 'ready', problem: 'The camera’s stream stopped.' });
  let sky = await aim();
  assert.deepEqual([sky.aim.quality, sky.aim.lenses, sky.learning.ready, sky.problem], ['rough', [], true, 'The camera’s stream stopped.']);
  await server.api.dev('sky', { aim: 'precise', problem: null, stream: 'sub' });
  sky = await aim();
  assert.equal(sky.aim.quality, 'precise');
  assert.deepEqual([sky.stream, sky.analysisWidth], ['sub', 1280]);
  assert.deepEqual((await night(BACKYARD())).json.aim.quality, 'precise', 'the log says the same');
  await ready();
  assert.equal((await aim()).aim.quality, 'good', 'the overall aim of the first look: good, with one lens precise');
});

// MARK: The page against it

test('the page reads the dev server’s night, shows it and takes a correction', opts, async () => {
  await ready();
  const browser = installFakeBrowser();
  const realFetch = globalThis.fetch;
  globalThis.fetch = cookieFetch(server.base);
  try {
    const api = await import(pathToFileURL(join(WEB_ROOT, 'js/api.js')).href);
    const signedIn = await api.post('auth/login', { password: PASSWORD });
    api.setCSRFToken(signedIn.csrfToken);
    const { store, loadCameras, loadPlugins, pluginOn } = await import(pathToFileURL(join(WEB_ROOT, 'js/store.js')).href);
    await loadCameras();
    await loadPlugins();
    assert.equal(pluginOn('sky'), true, 'the plugin was switched on for these tests (ready)');
    const { renderSkyLog } = await import(pathToFileURL(join(WEB_ROOT, 'js/screens/sky-log.js')).href);
    const page = renderSkyLog({ params: [BACKYARD(), ''], setTitle() {} });
    for (let tries = 0; tries < 100 && !/Last night|Tonight so far|Night of/.test(textOf(page.el)); tries += 1) await new Promise((resolve) => setTimeout(resolve, 20));
    const text = textOf(page.el);
    assert.match(text, /Sky log · Back Yard/);
    assert.match(text, /(Last night|Tonight so far): \d+ unexplained, \d+ explained/);
    assert.match(text, /\d+ satellites/);
    const card = all(page.el, (node) => node.classList?.contains('sky-entry'))[0];
    assert.ok(card, 'an unexplained entry has a card');
    const bird = all(card, (node) => node.localName === 'button' && node.textContent === 'Bird')[0];
    bird.click();
    for (let tries = 0; tries < 100 && !/You said: bird/.test(textOf(card)); tries += 1) await new Promise((resolve) => setTimeout(resolve, 20));
    assert.match(textOf(card), /You said: bird\. Camera Bridge learns from this\./);
    assert.equal(store.cameras.size, 9);
    page.destroy();
  } finally {
    globalThis.fetch = realFetch;
    browser.restore();
  }
  await reset();
});

test('the dev server lets the page ask this browser for its location, as the box does', opts, async () => {
  await ready();
  const policy = 'camera=(), microphone=(), geolocation=(self), payment=(), usb=()';
  const page = await server.api.send('GET', '/', { absolute: true, auth: false });
  const api = await server.api.get('settings');
  assert.equal(page.headers['permissions-policy'], policy, 'the page');
  assert.equal(api.headers['permissions-policy'], policy, 'and the API');
});

test('Back Yard’s recordings hold the night’s lights, so the clip player has something to play', opts, async () => {
  await ready();
  const { json } = await night(BACKYARD());
  const catalog = await server.api.get('nvr/cameras');
  assert.equal(catalog.status, 200);
  const extent = catalog.json.cameras.find((entry) => entry.id.toUpperCase() === BACKYARD().toUpperCase());
  assert.ok(extent, 'Back Yard records');
  const lights = json.entries.filter((entry) => entry.label === 'unexplained');
  assert.ok(lights.length >= 3);
  for (const light of lights) {
    assert.ok(extent.oldest <= light.start - 15_000 && light.end + 15_000 <= extent.newest, `${light.id}: its window is in the recordings`);
  }
});

function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const textOf = (root) => {
  const parts = [];
  const walk = (node) => { if (node.hidden) return; if (node.data !== undefined) parts.push(node.data); for (const child of node.childNodes ?? []) walk(child); };
  walk(root);
  return parts.join(' ').replace(/\s+/g, ' ');
};
