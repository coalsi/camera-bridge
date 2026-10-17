// Night vision on the dev server (web-dev/lib/night-vision.mjs): status.nightVision as the bridge words it, POST cameras/:id/night-vision
// with the bridge's answers (204, 400 invalid with the field, 404, 409 no_night_vision, 422 night_vision_failed and its sentence), the
// development switch that makes a camera refuse, the page's own requests (api.js in a fake browser) against it, and the conformance checks.
// Driveway pans, tilts and zooms too (POST cameras/:id/pan-tilt), as a camera whose lamp is on its PTZ node: the Monitor holds both.

import assert from 'node:assert/strict';
import { join } from 'node:path';
import { after, before, test } from 'node:test';
import { pathToFileURL } from 'node:url';
import { runConformance } from '../web-dev/conformance.mjs';
import { CAMERA_DEFINITIONS } from '../web-dev/lib/cameras.mjs';
import { cookieFetch } from './support/cookie-fetch.mjs';
import { PASSWORD, startDevServer } from './support/dev-server.mjs';
import { ensureFixtures, WEB_ROOT } from './support/fixtures.mjs';
import { installFakeBrowser } from './support/fake-browser.mjs';

const fixtures = ensureFixtures();
const opts = { skip: fixtures.skip };
const camera = (name) => CAMERA_DEFINITIONS.find((definition) => definition.name === name).id;
const path = (name) => `cameras/${camera(name)}/night-vision`;
let server;

before(async () => { if (!fixtures.skip) server = await startDevServer(); });
after(async () => { await server?.close(); });
const reset = () => server.api.dev('reset', {});
const nightVisionOf = async (name) => (await server.api.get(`cameras/${camera(name)}`)).json.status.nightVision;

test('status.nightVision: what each camera offers, `mode` and `lightOn` left out while unknown, no key for a camera without', opts, async () => {
  await reset();
  const { cameras } = (await server.api.get('cameras')).json;
  const byName = Object.fromEntries(cameras.map((entry) => [entry.name, entry.status]));
  assert.deepEqual(byName.Driveway.nightVision, { modes: ['auto', 'on', 'off'], mode: 'auto', light: true, lightOn: false });
  assert.deepEqual(byName.Garage.nightVision, { modes: ['auto', 'off'], mode: 'auto', light: false });
  assert.ok(!('nightVision' in byName['Front Door']), 'a camera without night vision has no key');
  assert.deepEqual(cameras.filter((entry) => entry.status.nightVision).map((entry) => entry.name).sort(), ['Driveway', 'Garage', 'Side Gate']);
});

test('POST night-vision sets the mode and the lamp: 204, and the camera reads back the change', opts, async () => {
  await reset();
  const answer = await server.api.post(path('Driveway'), { mode: 'on' });
  assert.deepEqual([answer.status, answer.text], [204, '']);
  assert.equal((await nightVisionOf('Driveway')).mode, 'on');
  assert.equal((await server.api.post(path('Driveway'), { light: true })).status, 204);
  assert.deepEqual(await nightVisionOf('Driveway'), { modes: ['auto', 'on', 'off'], mode: 'on', light: true, lightOn: true });
  assert.equal((await server.api.post(path('Driveway'), { mode: 'off', light: false })).status, 204);
  assert.deepEqual([(await nightVisionOf('Driveway')).mode, (await nightVisionOf('Driveway')).lightOn], ['off', false]);
  await reset();
  assert.equal((await nightVisionOf('Driveway')).mode, 'auto', 'a reset puts it back');
});

test('POST night-vision refuses as the bridge does: the body first, then the camera, then what it can do', opts, async () => {
  await reset();
  const refused = async (target, body, expected) => {
    const answer = await server.api.post(target, body);
    assert.deepEqual([answer.status, answer.json?.error, answer.json?.field ?? null], expected, `${target} ${JSON.stringify(body)}: ${answer.text}`);
    assert.ok(answer.json?.message, 'a sentence');
    return answer;
  };
  await refused(path('Driveway'), { mode: 'dusk' }, [400, 'invalid', 'mode']);
  await refused(path('Driveway'), { mode: 2 }, [400, 'invalid', 'mode']);
  await refused(path('Driveway'), { light: 'on' }, [400, 'invalid', 'light']);
  await refused(path('Driveway'), {}, [400, 'invalid', 'mode']);
  await refused('cameras/FFFFFFFF-0000-4000-8000-000000000000/night-vision', { mode: 'dusk' }, [400, 'invalid', 'mode']);
  await refused('cameras/FFFFFFFF-0000-4000-8000-000000000000/night-vision', { mode: 'auto' }, [404, 'not_found', null]);
  await refused('cameras/not-a-uuid/night-vision', { mode: 'dusk' }, [404, 'not_found', null]);
  const none = await refused(path('Front Door'), { mode: 'auto' }, [409, 'no_night_vision', null]);
  assert.equal(none.json.message, 'This camera can’t switch that right now.');
  await refused(path('Garage'), { mode: 'on' }, [409, 'no_night_vision', null]);   // a mode it doesn't offer
  await refused(path('Garage'), { light: true }, [409, 'no_night_vision', null]);   // no lamp
  const failed = await refused(path('Side Gate'), { mode: 'on' }, [422, 'night_vision_failed', null]);
  assert.equal(failed.json.message, 'The camera accepted night vision on but stayed in auto.');
  assert.equal((await nightVisionOf('Side Gate')).mode, 'auto', 'a refused change changes nothing');
  assert.equal((await server.api.post(path('Driveway'), { mode: 'on' }, { csrf: false })).json.error, 'csrf');
});

test('the development switch makes a camera refuse (with its own sentence, if given) and work again', opts, async () => {
  await reset();
  assert.equal((await server.api.dev('night-vision', { id: camera('Driveway'), fail: 'The camera is busy. Try again in a minute.' })).status, 200);
  const failed = await server.api.post(path('Driveway'), { light: true });
  assert.deepEqual([failed.status, failed.json.error, failed.json.message], [422, 'night_vision_failed', 'The camera is busy. Try again in a minute.']);
  await server.api.dev('night-vision', { id: camera('Driveway'), fail: true });
  assert.equal((await server.api.post(path('Driveway'), { light: true })).json.message, 'The camera refused the lamp command.');
  await server.api.dev('night-vision', { id: camera('Driveway'), fail: false });
  assert.equal((await server.api.post(path('Driveway'), { light: true })).status, 204);
  await server.api.dev('night-vision', { id: camera('Side Gate'), fail: false });
  assert.equal((await server.api.post(path('Side Gate'), { mode: 'off' })).status, 204, 'the camera that refuses can be made to work');
  await reset();
  assert.equal((await server.api.post(path('Side Gate'), { mode: 'off' })).status, 422, 'and refuses again after a reset');
});

test('Driveway also pans, tilts and zooms, so the Monitor holds the pad and the night vision together; POST pan-tilt answers as the bridge', opts, async () => {
  await reset();
  const { cameras } = (await server.api.get('cameras')).json;
  const driveway = cameras.find((entry) => entry.name === 'Driveway').status;
  assert.deepEqual([driveway.panTilt, driveway.zoom, driveway.nightVision?.light], [true, true, true]);
  assert.ok(cameras.every((entry) => typeof entry.status.panTilt === 'boolean' && typeof entry.status.zoom === 'boolean'), 'every camera says, as the bridge does');
  assert.deepEqual(cameras.filter((entry) => entry.status.panTilt).map((entry) => entry.name), ['Driveway']);
  const answer = async (target, body) => {
    const response = await server.api.post(target, body);
    return [response.status, response.json?.error ?? null, response.json?.field ?? null];
  };
  const turn = (name) => `cameras/${camera(name)}/pan-tilt`;
  assert.deepEqual(await answer(turn('Driveway'), { pan: 0.6, tilt: 0 }), [204, null, null]);
  assert.deepEqual(await answer(turn('Driveway'), { pan: 0, tilt: 0 }), [204, null, null], 'a stop');
  assert.deepEqual(await answer(turn('Driveway'), { pan: 0, tilt: 0, zoom: -1 }), [204, null, null], 'a zoom step');
  assert.deepEqual(await answer(turn('Driveway'), { pan: 2, tilt: 0 }), [400, 'invalid', 'pan']);
  assert.deepEqual(await answer(turn('Driveway'), { tilt: 0 }), [400, 'invalid', 'pan']);
  assert.deepEqual(await answer(turn('Driveway'), { pan: 0, tilt: 'up' }), [400, 'invalid', 'tilt']);
  assert.deepEqual(await answer(turn('Front Door'), { pan: 0.6, tilt: 0 }), [409, 'no_pan_tilt', null], 'a camera that doesn’t turn');
  assert.deepEqual(await answer(turn('Front Door'), { pan: 0, tilt: 0, zoom: 1 }), [409, 'no_pan_tilt', null], 'nor zoom');
  assert.deepEqual(await answer('cameras/FFFFFFFF-0000-4000-8000-000000000000/pan-tilt', { pan: 0, tilt: 0 }), [404, 'not_found', null]);
  assert.deepEqual(await answer('cameras/not-a-uuid/pan-tilt', { pan: 2, tilt: 0 }), [404, 'not_found', null]);
});

test('the page’s own requests against the dev server: a change, the camera read back into the store, a refusal in the bridge’s words', opts, async () => {
  await reset();
  const browser = installFakeBrowser();
  globalThis.fetch = cookieFetch(server.base);
  let store = null;
  try {
    const api = await import(pathToFileURL(join(WEB_ROOT, 'js/api.js')).href);
    ({ store } = await import(pathToFileURL(join(WEB_ROOT, 'js/store.js')).href));
    const nv = await import(pathToFileURL(join(WEB_ROOT, 'js/screens/night-vision.js')).href);
    api.setCSRFToken((await api.post('auth/login', { password: PASSWORD })).csrfToken);
    const driveway = await api.get(`cameras/${camera('Driveway')}`);
    store.cameras.set(driveway.id, driveway);
    const requests = nv.createNightVisionRequests();
    const done = await requests.change(driveway, { mode: 'off' });
    assert.equal(done.camera.status.nightVision.mode, 'off', 'read back after the 204');
    assert.equal(store.cameras.get(driveway.id).status.nightVision.mode, 'off', 'and put in the store');
    const sideGate = await api.get(`cameras/${camera('Side Gate')}`);
    assert.deepEqual(await requests.change(sideGate, { mode: 'on' }), { message: 'The camera accepted night vision on but stayed in auto.' });
    const buttons = nv.createNightVisionButtons();
    const { createPanTiltPad } = await import(pathToFileURL(join(WEB_ROOT, 'js/live/pan-tilt.js')).href);
    const side = nv.createMonitorSide(createPanTiltPad(), buttons);
    side.setCamera(store.cameras.get(driveway.id));
    assert.equal(buttons.el.hidden, false);
    assert.deepEqual([side.el.hidden, side.el.dataset.both], [false, 'true'], 'Driveway opened on its own: the pad and the night vision side by side');
    side.destroy();
  } finally {
    store?.cameras?.clear?.();
    browser.restore();
  }
});

// The whole run each time (`only` would leave out the sign-in and the camera list the night vision checks start from); its night vision lines are read.
const nightLines = (lines) => lines.filter((line) => /night ?vision/i.test(line.name));

test('conformance checks night vision against the dev server, and notices a server that takes a mode it should refuse', opts, async () => {
  await reset();
  const lines = [];
  await runConformance({ baseUrl: server.base, password: PASSWORD, mutate: true, report: (status, name, detail) => lines.push({ status, name, detail }) });
  assert.equal(nightLines(lines).length, 3, 'the shape, the refusals and the same mode again');
  assert.deepEqual(nightLines(lines).filter((line) => line.status !== 'ok'), [], 'every night vision check passed');
  assert.deepEqual(lines.filter((line) => /^pan and tilt/.test(line.name)).map((line) => line.status), ['ok'], 'and the pan and tilt check');

  const broken = await startDevServer();
  const original = broken.dev.server.listeners('request')[0];
  broken.dev.server.removeAllListeners('request');
  broken.dev.server.on('request', (request, response) => {
    if (request.method === 'POST' && request.url.endsWith('/night-vision')) {
      // Every change "works", even a mode that does not exist: the answer becomes 204 with the same headers and no body.
      const write = response.writeHead.bind(response);
      const end = response.end.bind(response);
      let headers = {};
      response.writeHead = (status, given = {}) => { headers = Object.fromEntries(Object.entries(given).filter(([name]) => name.toLowerCase() !== 'content-length')); return response; };
      response.end = () => { write(204, headers); return end(); };
    }
    original(request, response);
  });
  try {
    const found = [];
    await runConformance({ baseUrl: broken.base, password: PASSWORD, report: (status, name, detail) => found.push({ status, name, detail }) });
    const night = nightLines(found);
    assert.ok(night.some((line) => line.status === 'FAIL' && /unknown mode/.test(line.detail)), night.map((line) => `${line.status} ${line.name}: ${line.detail}`).join('\n'));
  } finally {
    await broken.close();
  }
});
