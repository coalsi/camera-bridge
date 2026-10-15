// Runs conformance.mjs against the dev archive server, in every scenario: the tool and the server must agree with the contract, and the
// tool must be able to tell a healthy server from a broken one (the mutation tests at the end make the server wrong on purpose).

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { runConformance } from '../web-dev/conformance.mjs';
import { CAMERA_DEFINITIONS } from '../web-dev/lib/cameras.mjs';
import { PASSWORD, startDevServer } from './support/dev-server.mjs';
import { ensureFixtures } from './support/fixtures.mjs';

const fixtures = ensureFixtures();
const opts = { skip: fixtures.skip };

async function run(server, options = {}) {
  const lines = [];
  const result = await runConformance({ baseUrl: server.base, password: PASSWORD, report: (status, name, detail) => lines.push({ status, name, detail }), ...options });
  return { ...result, lines, failures: lines.filter((line) => line.status === 'FAIL'), skips: lines.filter((line) => line.status === 'skip') };
}

test('conformance passes against the dev server in its default scenario, with every optional group', opts, async () => {
  const server = await startDevServer();
  try {
    const result = await run(server, { mutate: true, intrusive: true });
    assert.deepEqual(result.failures, [], result.failures.map((line) => `${line.name}: ${line.detail}`).join('\n'));
    assert.ok(result.passed >= 80, `only ${result.passed} checks passed`);
    assert.equal(result.skipped, 1, `skipped: ${result.skips.map((line) => `${line.name} (${line.detail})`).join('; ')}`); // New Gate has no 40 minutes of footage
    for (const name of ['Front Door', 'Driveway', 'Garage', 'Back Yard', 'Side Gate', 'Living Room', 'Porch', 'Shed']) {
      assert.ok(result.lines.some((line) => line.status === 'ok' && line.name.includes(`[${name}]`) && line.name.includes('R10 keyframe')), `${name} was not checked`);
    }
  } finally {
    await server.close();
  }
});

for (const scenario of ['noFolder', 'folderMissing', 'diskFull', 'lowSpace', 'notWritable', 'stalled', 'noArchive', 'loading']) {
  test(`conformance passes in the scenario ${scenario}`, opts, async () => {
    const server = await startDevServer({ scenario, loadingMs: 60_000 });
    try {
      const result = await run(server, { mutate: true });
      assert.deepEqual(result.failures, [], result.failures.map((line) => `${line.name}: ${line.detail}`).join('\n'));
      assert.ok(result.passed >= 15, `only ${result.passed} checks passed`);
    } finally {
      await server.close();
    }
  });
}

// ---- a recording shorter than a minute --------------------------------------------------------------------------------------------

/**
 * One camera that began 24 s ago (its footage is 22 s long and ends 2 s before "now") and a server clock that stands still `second` seconds into a minute.
 * The R6 check asks for 120 bins of a minute whose end is the newest footage, with `from` 123 ms late; the server snaps `from` down to a minute, so the
 * window it answers ends at the start of the minute the newest footage lies in: after all of the footage (second 2), inside it (8), or before it began.
 */
async function shortRecordingServer(second) {
  const base = CAMERA_DEFINITIONS.find((definition) => definition.name === 'New Gate');
  const now = Math.floor(Date.now() / 60_000) * 60_000 + second * 1000;
  return startDevServer({ definitions: [{ ...base, freshMinutes: 0.4 }], clock: () => now });
}

for (const [second, overlap] of [[2, 'all of the footage'], [8, 'the first part of the footage'], [30, 'none of the footage'], [59, 'none of the footage']]) {
  test(`conformance passes when the only recording is 22 s long and the answered R6 window overlaps ${overlap} (second ${second} of the minute)`, opts, async () => {
    const server = await shortRecordingServer(second);
    try {
      const extent = (await server.api.get('nvr/cameras')).json.cameras[0];
      assert.ok(extent.newest - extent.oldest < 60_000, 'the recording is shorter than a minute');
      const windowEnd = Math.floor((extent.newest + 123) / 60_000) * 60_000;
      const seen = windowEnd >= extent.newest ? 'all of the footage' : windowEnd > extent.oldest ? 'the first part of the footage' : 'none of the footage';
      assert.equal(seen, overlap, 'the test is set up as its name says');
      const result = await run(server, { mutate: true });
      assert.deepEqual(result.failures, [], result.failures.map((line) => `${line.name}: ${line.detail}`).join('\n'));
      assert.ok(result.lines.some((line) => line.status === 'ok' && line.name.startsWith('R6 activity: bins are aligned')), 'the R6 alignment check ran and passed');
    } finally {
      await server.close();
    }
  });
}

test('conformance refuses a wrong password and stops', opts, async () => {
  const server = await startDevServer();
  try {
    const result = await runConformance({ baseUrl: server.base, password: 'wrong-password-1', report: () => {} });
    assert.equal(result.aborted, 'could not sign in');
    assert.ok(result.failed >= 1);
  } finally {
    await server.close();
  }
});

test('conformance output never contains the password, the cookie or the CSRF token', opts, async () => {
  const server = await startDevServer();
  try {
    const result = await run(server, { mutate: true, intrusive: true });
    const text = JSON.stringify(result.lines);
    assert.ok(!text.includes(PASSWORD));
    assert.ok(!text.includes(server.api.csrf));
  } finally {
    await server.close();
  }
});

// ---- what a port forward needs ---------------------------------------------------------------------------------------------------
// QEMU's user-mode port forwarding (what carries a host's port to the web port of the box in linux/os/test-vm.sh) resets connections that
// arrive together: on a macOS host two at once are enough. So the tool asks one thing at a time, except in the burst, which it can leave out
// (the caller then runs the burst another way, test-vm.sh from inside the box).

test('conformance asks one thing at a time, so that a port forward that resets simultaneous connections cannot fail it', opts, async () => {
  const server = await startDevServer();
  const original = server.dev.server.listeners('request')[0];
  let inFlight = 0;
  let widest = 0;
  server.dev.server.removeAllListeners('request');
  server.dev.server.on('request', (request, response) => {
    inFlight += 1;
    widest = Math.max(widest, inFlight);
    response.on('close', () => { inFlight -= 1; });
    setTimeout(() => original(request, response), 15); // long enough for requests that are sent together to overlap
  });
  try {
    const result = await run(server, { mutate: true });
    assert.deepEqual(result.failures, [], result.failures.map((line) => `${line.name}: ${line.detail}`).join('\n'));
    assert.equal(widest, 1, `${widest} requests were in flight at once`);
  } finally {
    await server.close();
  }
});

test('conformance leaves its burst of 40 out when told to, and says so', opts, async () => {
  const server = await startDevServer();
  try {
    const burst = (line) => line.name.startsWith('admission');
    const without = await run(server, { mutate: true, intrusive: true, burst: false });
    assert.deepEqual(without.failures, [], without.failures.map((line) => `${line.name}: ${line.detail}`).join('\n'));
    assert.ok(!without.lines.some((line) => burst(line) && line.status === 'ok'), 'the burst ran although it was left out');
    const left = without.lines.filter((line) => burst(line) && line.status === 'skip');
    assert.equal(left.length, 1, 'the burst is not reported as left out');
    assert.match(left[0].detail, /left out/);
    const with40 = await run(server, { mutate: true, intrusive: true });
    assert.ok(with40.lines.some((line) => burst(line) && line.status === 'ok'), 'the burst did not run by default');
    assert.equal(with40.passed, without.passed + 1, 'only the burst differs');
  } finally {
    await server.close();
  }
});

// ---- the tool must notice a server that is wrong --------------------------------------------------------------------------------

/** A server whose responses are changed by `damage(path, response)` (mutates the answer the dev server built) before they are sent. */
async function brokenServer(damage, makeServer = () => startDevServer()) {
  const server = await makeServer();
  const original = server.dev.server.listeners('request')[0];
  server.dev.server.removeAllListeners('request');
  server.dev.server.on('request', (request, response) => {
    const path = request.url.split('?')[0];
    const write = response.writeHead.bind(response);
    const end = response.end.bind(response);
    let head = null;
    response.writeHead = (status, headers) => { head = { status, headers }; return response; };
    response.end = (body) => {
      const answer = { ...head, body, request };
      damage(path, answer);
      write(answer.status, answer.headers);
      return end(answer.body);
    };
    original(request, response);
  });
  return server;
}

const patchJson = (body, change) => { const value = JSON.parse(body.toString()); change(value); const out = Buffer.from(JSON.stringify(value)); return out; };

test('conformance notices a server that is wrong: the CSP, a plan, an anchor, a storage formula, a prft box, a status', opts, async () => {
  const cases = [
    ['the CSP', (path, answer) => { if (path === '/') answer.headers['Content-Security-Policy'] = answer.headers['Content-Security-Policy'].replace(" media-src 'self' blob:;", ''); }, /CSP|Content-Security-Policy/],
    ['a plan whose targetIndex is out of range', (path, answer) => { if (path.endsWith('/fragments') || path.includes('/fragments')) { try { const body = patchJson(answer.body, (v) => { if (v.found && v.parts) v.targetIndex = v.parts.length + 1; }); answer.body = body; answer.headers['Content-Length'] = body.length; } catch { /* binary */ } } }, /targetIndex/],
    ['an anchor that is 40 ms off', (path, answer) => { if (path.includes('/fragments') && answer.headers['Content-Type']?.includes('json')) { try { const body = patchJson(answer.body, (v) => { for (const file of Object.values(v.files ?? {})) file.anchor += 40; }); answer.body = body; answer.headers['Content-Length'] = body.length; } catch { /* ignore */ } } }, /anchor/],
    ['a storage whose roomBytes is wrong', (path, answer) => { if (path === '/api/v1/nvr/storage') { const body = patchJson(answer.body, (v) => { v.roomBytes += 1; }); answer.body = body; answer.headers['Content-Length'] = body.length; } }, /roomBytes/],
    ['a prft box in front of a fragment', (path, answer) => {
      if (/\/fragments\/[0-9a-f]{12}\.\d+$/.test(path) && answer.status === 200) {
        const prft = Buffer.concat([Buffer.from([0, 0, 0, 32]), Buffer.from('prft', 'latin1'), Buffer.alloc(24)]);
        answer.body = Buffer.concat([prft, answer.body]);
        answer.headers['Content-Length'] = answer.body.length;
      }
    }, /prft|boxes/],
    ['a 200 for an unknown fragment id', (path, answer) => { if (path.endsWith('/fragments/000000000000.1')) { answer.status = 200; } }, /unknown fragment id|410/],
  ];
  for (const [label, damage, expected] of cases) {
    const server = await brokenServer(damage);
    try {
      const result = await run(server, {});
      assert.ok(result.failures.length >= 1, `${label}: the tool found nothing wrong`);
      assert.ok(result.failures.some((line) => expected.test(`${line.name} ${line.detail}`)), `${label}: the failures were ${result.failures.map((line) => `${line.name}: ${line.detail}`).join(' | ')}`);
    } finally {
      await server.close();
    }
  }
});

// ---- R6: the camera list and the bins -------------------------------------------------------------------------------------------

const setJson = (answer, status, value) => {
  answer.status = status;
  answer.body = Buffer.from(JSON.stringify(value));
  answer.headers['Content-Type'] = 'application/json';
  answer.headers['Content-Length'] = answer.body.length;
};
/** The camera ids an R6 request lists (as written, repeats included). */
const listedCameras = (answer) => (new URL(answer.request.url, 'http://x').searchParams.get('cameras') ?? '').split(',');

test('conformance notices an R6 that counts a repeated id as many cameras or lets 17 different cameras through', opts, async () => {
  const cases = [
    ['an R6 that counts every listed id, repeats included', (path, answer) => {
      if (path === '/api/v1/nvr/activity' && listedCameras(answer).length > 16 && new Set(listedCameras(answer).map((id) => id.toUpperCase())).size <= 16) {
        setJson(answer, 400, { error: 'invalid', message: 'Ask for 1 to 16 cameras at a time.', field: 'cameras' });
      }
    }, /listed 17 times/],
    ['an R6 that does not collapse a repeated id in byCamera', (path, answer) => {
      if (path === '/api/v1/nvr/activity' && answer.status === 200) {
        const body = JSON.parse(answer.body.toString());
        body.byCamera = Object.fromEntries(listedCameras(answer).map((id, index) => [index === 0 ? id.toUpperCase() : `${id.toUpperCase().slice(0, -2)}${String(index).padStart(2, '0')}`, Object.values(body.byCamera)[0]]));
        setJson(answer, 200, body);
      }
    }, /the cameras in byCamera/],
    ['an R6 that lets 17 different cameras through', (path, answer) => {
      if (path === '/api/v1/nvr/activity' && new Set(listedCameras(answer).map((id) => id.toUpperCase())).size > 16 && answer.status === 400) {
        setJson(answer, 200, { from: 0, binMs: 60000, bins: 10, serverTime: 0, catalogVersion: 1, byCamera: {} });
      }
    }, /17 different cameras/],
  ];
  for (const [label, damage, expected] of cases) {
    const server = await brokenServer(damage);
    try {
      const result = await run(server, {});
      assert.ok(result.failures.some((line) => expected.test(`${line.name} ${line.detail}`)), `${label}: the failures were ${result.failures.map((line) => `${line.name}: ${line.detail}`).join(' | ') || 'none'}`);
    } finally {
      await server.close();
    }
  }
});

test('conformance notices R6 bins that hold the footage in the wrong place, in a recording shorter than a minute', opts, async () => {
  const shifted = (bins) => (path, answer) => {
    if (path === '/api/v1/nvr/activity' && answer.status === 200) {
      const body = JSON.parse(answer.body.toString());
      for (const entry of Object.values(body.byCamera)) {
        entry.coverage = [...entry.coverage.slice(bins), ...Array(bins).fill(0)];
        entry.level = [...entry.level.slice(bins), ...Array(bins).fill(0)];
      }
      setJson(answer, 200, body);
    }
  };
  const cases = [
    // second 8: the answered window ends 6 s after the footage began, so its last bin holds 16 s of footage
    ['coverage three bins too early', shifted(3), /lies outside the footage/],
    ['no coverage at all', (path, answer) => {
      if (path === '/api/v1/nvr/activity' && answer.status === 200) {
        const body = JSON.parse(answer.body.toString());
        for (const entry of Object.values(body.byCamera)) { entry.coverage = entry.coverage.map(() => 0); entry.level = entry.level.map(() => 0); }
        setJson(answer, 200, body);
      }
    }, /none of those bins has coverage/],
    ['coverage in every bin although the footage is 22 s long', (path, answer) => {
      if (path === '/api/v1/nvr/activity' && answer.status === 200) {
        const body = JSON.parse(answer.body.toString());
        for (const entry of Object.values(body.byCamera)) entry.coverage = entry.coverage.map(() => 40);
        setJson(answer, 200, body);
      }
    }, /lies outside the footage/],
  ];
  for (const [label, damage, expected] of cases) {
    const server = await brokenServer(damage, () => shortRecordingServer(8));
    try {
      const result = await run(server, {});
      assert.ok(result.failures.some((line) => line.name.startsWith('R6 activity: bins are aligned') && expected.test(line.detail)), `${label}: the failures were ${result.failures.map((line) => `${line.name}: ${line.detail}`).join(' | ') || 'none'}`);
    } finally {
      await server.close();
    }
  }
});
