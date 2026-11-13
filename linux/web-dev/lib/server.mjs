// The dev archive server: linux/web served as camerabridged serves it, the session, CSRF and header rules of BridgeWeb/WebApp.swift,
// enough of the existing API for the page to run, and the NVR routes (nvr-routes.mjs) over the virtual archive. Dependency free.
//
// Not the daemon: one process, one fake bridge with nine cameras, a fixed development password, everything in memory. Sky Watcher's routes and
// its made-up night are in sky.mjs.

import { randomBytes } from 'node:crypto';
import http from 'node:http';
import { ApiError, COOKIE_NAME, constantTimeEqual, empty, errorResponse, hostAllowed, isLoopback, json, bytes, originAllowed, parseCookies, parseObject, readBody } from './http.mjs';
import { createStaticFiles } from './static.mjs';
import { NVR_ROUTES } from './nvr-routes.mjs';
import { withSecurityHeaders } from './security.mjs';
import { DevState, SCENARIOS } from './state.mjs';
import { loadFixtures } from './fixtures.mjs';
import { changeNightVision, setNightVisionFailure } from './night-vision.mjs';
import { checkSecurity } from './camera-security.mjs';

export const DEFAULTS = {
  host: '127.0.0.1',
  port: 8090,
  scenario: 'ok',
  password: 'camera-bridge-dev',
  bridgeName: 'Camera Bridge Dev',
  allowedHosts: [],
  latencyMs: 0,
  jitterMs: 0,
  throttleMbps: 0,
  stallReadMs: 5000,
  stallFolderMs: 8000,
  loadingMs: 3000,
  optimizeMs: 1500,
  diskGB: 512,
  clockOffsetMs: 0,
  maximumArchiveReads: 8,
  maximumArchiveReadsPerAddress: 6,
  maximumEventStreams: 16,
  eventIntervalMs: 500,
  verbose: false,
};

const SESSION_SECONDS = 30 * 86_400;
const sessionCookie = (token) => `${COOKIE_NAME}=${token}; Path=/; HttpOnly; SameSite=Strict; Max-Age=${SESSION_SECONDS}`;
const CLEARED_COOKIE = `${COOKIE_NAME}=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0`;
const UUID = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;

/** Creates the server. Nothing listens until `listen()`. `options` overrides DEFAULTS; `webRoot` and `fixtureDir` are required. */
export function createDevServer(options) {
  const config = { ...DEFAULTS, ...options };
  const fixtures = options.fixtures ?? loadFixtures(config.fixtureDir);
  const state = new DevState({ fixtures, clock: options.clock, diskGB: config.diskGB, loadingMs: config.loadingMs, scenario: config.scenario, definitions: options.definitions });
  state.clockOffset = config.clockOffsetMs;
  const sessions = new Map(); // token -> { csrfToken }
  const slots = { total: 0, byAddress: new Map(), peakTotal: 0, peakByAddress: 0 }; // the peaks let a test prove the caps without relying on timing
  const streams = { events: 0 };
  const serveFile = createStaticFiles(config.webRoot);
  const app = { state, config, slots };
  const log = (text) => config.verbose && console.error(text);

  // ---- the existing API, as much as the page needs ---------------------------------------------------------------------------------

  const publicStatus = () => ({ product: 'Camera Bridge OS', version: '0.0-dev', name: config.bridgeName, setupRequired: false, authenticated: false });

  function status(ctx) {
    if (!ctx.session) return json(publicStatus());
    const list = state.cameraList();
    return json({
      ...publicStatus(), build: 'development', authenticated: true, state: 'running', stateText: 'Running', uptimeSeconds: Math.floor(process.uptime()),
      cameras: { total: list.length, online: list.filter((camera) => camera.configuration.isEnabled).length, paired: list.filter((camera) => camera.definition.index % 2 === 1).length },
      localNetwork: 'granted', notices: state.notices(), configurationRecovered: false, streamingHelperInstalled: false, sensorsBridge: null,
      system: { mode: 'development', hostname: null, updateAvailable: false, updateState: null, latestVersion: null },
    });
  }

  const sessionInfo = (ctx) => json({ authenticated: !!ctx.session, setupRequired: false, setupTokenRequired: false, bridgeName: config.bridgeName, csrfToken: ctx.session?.csrfToken ?? null });

  function login(ctx) {
    const { password } = ctx.body;
    if (typeof password !== 'string' || !constantTimeEqual(password, config.password)) {
      throw new ApiError(401, 'wrong_password', 'That password isn’t right.', { field: 'password' });
    }
    const token = randomBytes(32).toString('hex');
    const csrfToken = randomBytes(16).toString('hex');
    sessions.set(token, { csrfToken });
    return json({ csrfToken, bridgeName: config.bridgeName }, 200, { 'Set-Cookie': sessionCookie(token) });
  }

  function logout(ctx) {
    if (ctx.token) sessions.delete(ctx.token);
    return empty(204, { 'Set-Cookie': CLEARED_COOKIE });
  }

  function findCamera(ctx) {
    const id = ctx.params.id;
    const camera = UUID.test(id) ? state.cameras.get(id.toUpperCase()) : null;
    if (!camera) throw ApiError.notFound('There is no camera with this identifier.');
    return camera;
  }

  const EDITABLE = ['name', 'isEnabled', 'audioEnabled', 'twoWayAudio', 'motionSource', 'motionSensitivity', 'motionHoldSeconds', 'liveStreamMode', 'liveQualityMode',
    'liveMaxBitrateOverride', 'recordingStreamMode', 'recordingQualityMode'];

  // The owner's pan, tilt and zoom switches: true or false (null changes nothing), anything else refused with the field, as the bridge does.
  const SWITCHES = ['panTiltEnabled', 'zoomEnabled'];

  function patchCameraSettings(ctx) {
    const camera = findCamera(ctx);
    for (const name of SWITCHES) {
      const value = ctx.body[name];
      if (value !== undefined && value !== null && typeof value !== 'boolean') throw ApiError.invalid(`“${name}” has the wrong kind of value.`, name);
    }
    // Sky Watcher (sky.mjs): checked first, so that a refusal changes nothing.
    if (ctx.body.skyDetector !== undefined) state.sky.patchCamera(camera, ctx.body.skyDetector, { hasFolder: state.settings.nvrFolder !== null });
    for (const name of SWITCHES) if (typeof ctx.body[name] === 'boolean') camera.configuration[name] = ctx.body[name];
    for (const name of EDITABLE) if (ctx.body[name] !== undefined) camera.configuration[name] = ctx.body[name];
    for (const name of ['sensors', 'timestampOverlay']) if (ctx.body[name] && typeof ctx.body[name] === 'object') Object.assign(camera.configuration[name], ctx.body[name]);
    return json(state.cameraResource(camera));
  }

  // "Set up for Camera Bridge" (GET/POST cameras/:id/setup, POST …/setup/restore): a scripted camera that needs every step but the time from
  // the bridge (a dev server does not serve time); "Watch its internet" is offered, as on Camera Bridge OS, at a documentation address.
  // Applying marks the steps done and keeps a pretend backup; restoring clears both.
  const SETUP_STEPS = [
    ['timeZone', 'Time zone', [['Time zone', 'UTC−8 with daylight saving', 'America/Phoenix (UTC−7)']]],
    ['timeSource', 'Time from the bridge', null],
    ['cleanPicture', 'Clean picture', [['The camera’s own labels', 'date and time and camera name', 'off (the bridge draws its own)']]],
    ['streams', 'Streams for recording, Apple Home and live view', [['Smart codec (H.264+ or H.265+)', 'on', 'off'],
      ['Main stream', 'H.265, 3840×2160, 20 fps, 4.1 Mbit/s, keyframe every 2.5 s', 'H.264, 3840×2160, 20 fps, 4.1 Mbit/s, keyframe every 2 s'],
      ['Sub stream', 'H.264, 640×480, 20 fps, keyframe every 2.5 s', 'H.264, 640×480, 20 fps, keyframe every 2 s']]],
    ['upnp', 'UPnP off', [['UPnP', 'on', 'off']]],
    ['cloud', 'Cloud off', [['Hik-Connect (the maker’s cloud)', 'on', 'off']]],
    // Last, as on the bridge: a camera that refuses it still gets every other step, and Restore puts its DNS back first.
    ['internetWatch', 'Watch its internet', [['DNS', '8.8.8.8 and 1.1.1.1', 'the bridge (192.0.2.2)']]],
  ];

  function setupReport(camera, phase) {
    const applied = Boolean(camera.configuration.setupBackup);
    const steps = SETUP_STEPS.map(([id, title, changes]) => {
      if (!changes) return { id, title, status: 'notOffered', changes: [], detail: 'Camera Bridge OS serves time to cameras; this bridge does not.', needsRestart: false };
      const list = changes.map(([label, now, after]) => ({ label, now, after }));
      const status = phase === 'apply' ? 'done' : phase === 'restore' ? 'restored' : applied ? 'alreadyRight' : 'willChange';
      return { id, title, status, changes: status === 'alreadyRight' ? [] : list, detail: phase === 'apply' ? 'via ISAPI' : null, needsRestart: false };
    });
    return { steps, state: camera.configuration.setupState ?? null, canRestore: Boolean(camera.configuration.setupBackup), streamRestarted: phase === 'apply',
      mayNeedRecordingReEnabled: phase === 'apply' };
  }

  function setupPreview(ctx) { return json(setupReport(findCamera(ctx), 'preview')); }

  function setupApply(ctx) {
    if (ctx.body?.confirm !== true) throw new ApiError(400, 'invalid', 'Confirm that the camera’s settings may be changed.', { field: 'confirm' });
    const camera = findCamera(ctx);
    const already = Boolean(camera.configuration.setupBackup);
    const now = new Date().toISOString();
    camera.configuration.setupBackup = { version: 1, created: now };
    camera.configuration.setupState = { version: 1, started: now, applied: now,
      steps: SETUP_STEPS.map(([id, , changes]) => ({ id, status: !changes ? 'notOffered' : already ? 'alreadyRight' : 'done', needsRestart: false })) };
    return json(setupReport(camera, already ? 'preview' : 'apply'));
  }

  function setupRestore(ctx) {
    if (ctx.body?.confirm !== true) throw new ApiError(400, 'invalid', 'Confirm that the camera’s original settings may be written back.', { field: 'confirm' });
    const camera = findCamera(ctx);
    if (!camera.configuration.setupBackup) throw new ApiError(422, 'camera_setup_failed', 'Invalid settings: this camera has no saved settings to put back.');
    const report = setupReport(camera, 'restore');
    delete camera.configuration.setupBackup;
    delete camera.configuration.setupState;
    report.steps = report.steps.filter((step) => step.status === 'restored').reverse();
    report.canRestore = false;
    report.state = null;
    return json(report);
  }

  // Night vision (night-vision.mjs): a malformed id is 404 before the body is read, as the bridge's ctx.uuid; the bridge answers 204.
  function nightVision(ctx) {
    if (!UUID.test(ctx.params.id)) throw ApiError.notFound('There is no camera with this identifier.');
    changeNightVision(ctx.body, () => findCamera(ctx));
    return empty(204);
  }

  // Pan and tilt (WebApp+Routes.swift panTilt), in the bridge's order: the id, the body (pan and tilt, and a zoom step, each -1…1), the
  // camera, then whether it turns (or zooms, for a zoom step) and the owner left it on: 409 no_pan_tilt as for a camera that isn't
  // running, its sentence about zooming for a zoom step. Nothing moves; 204.
  function panTilt(ctx) {
    if (!UUID.test(ctx.params.id)) throw ApiError.notFound('There is no camera with this identifier.');
    const { pan, tilt, zoom } = ctx.body;
    for (const [name, value] of [['pan', pan], ['tilt', tilt]]) {
      if (value === undefined) throw ApiError.invalid(`“${name}” is missing.`, name);
      if (typeof value !== 'number') throw ApiError.invalid(`“${name}” has the wrong kind of value.`, name);
    }
    if (zoom !== undefined && zoom !== null && typeof zoom !== 'number') throw ApiError.invalid('“zoom” has the wrong kind of value.', 'zoom');
    if ([pan, tilt, zoom ?? 0].some((value) => Math.abs(value) > 1)) throw ApiError.invalid('Pan and tilt are numbers from -1 to 1.', 'pan');
    const { configuration, definition } = findCamera(ctx);
    const offered = zoom ? definition.zoom && configuration.zoomEnabled !== false : definition.panTilt && configuration.panTiltEnabled !== false;
    if (!configuration.isEnabled || !offered) throw new ApiError(409, 'no_pan_tilt', zoom ? 'This camera can’t zoom right now.' : 'This camera can’t pan and tilt right now.');
    return empty(204);
  }

  const settingsBody = { basePort: 21100, sensorsBridgePort: 21099, webhookEnabled: false, webhookPort: 21090, webhookToken: '00000000000000000000000000000000', webhookProblem: null, logLevel: 'info', motionShadowTest: false, cameraOrder: [] };

  const systemInfo = () => json({ product: 'Camera Bridge OS', version: '0.0-dev', build: 'development', mode: 'development', osName: 'Dev server', canUpdate: false, canReboot: false, canInstall: false, canManage: false });

  // The secure address (BridgeWeb/WebApp+SecureAddress.swift): a ready address with a certificate, its own switch, a redirect switch and a
  // rebind self-test. `POST /__dev/secure` {state: 'ready' | 'waiting' | 'error', router: 'open' | 'blocked'} changes what the card shows.
  const secure = { state: 'ready', enabled: true, redirect: true, router: 'open', rebind: null };
  function secureReport() {
    const host = 'k7f2q9.box.camera-bridge.app';
    const shown = secure.enabled ? secure.state : 'off';
    const ready = shown === 'ready';
    const expires = new Date(state.serverNow() + 60 * 86_400_000);
    return {
      available: true, enabled: secure.enabled, state: shown, host, url: `https://${host}`, address: '192.168.77.5',
      expiresOn: ready ? expires.toISOString() : null, renewsOn: ready ? new Date(expires.getTime() - 30 * 86_400_000).toISOString() : null,
      redirect: secure.redirect, redirectActive: ready && secure.redirect,
      problem: shown === 'error' ? { code: 'no_internet', message: 'The Camera Bridge website can’t be reached. Check that the box has internet.' } : null,
      rebind: secure.rebind,
    };
  }
  // The secure address's switch. A phone reaches the box through the tunnel by its secure name, so the bridge keeps it on while Away from
  // home is on.
  function secureEnabled(ctx) {
    if (typeof ctx.body.enabled !== 'boolean') throw ApiError.invalid(ctx.body.enabled === undefined ? '“enabled” is missing.' : '“enabled” has the wrong kind of value.', 'enabled');
    if (!ctx.body.enabled && away.available && away.on) {
      throw new ApiError(409, 'away_on', 'Away from home needs the secure address. Turn Away from home off first.');
    }
    secure.enabled = ctx.body.enabled;
    return json(secureReport());
  }

  // Away from home (BridgeWeb/WebApp+Away.swift): the card and its devices in memory, the page's four routes answered in the bridge's order
  // (the body, then 503 on a box without it, then the rest). A WireGuard device's configuration is made of placeholders, which no WireGuard app
  // takes for a key: the dev server has no keys at all, so the phone's `viewer/away` routes are left out too. `POST /__dev/away` {available,
  // on, state, router, problem, devices} sets the scenario; a state other than 'off' turns it on.
  const AWAY_ADDRESS = '2001:db8:4:7000:1a2b:3c4d:5e6f:7a8b';
  const AWAY_NAME = 'devserver0123456789a.away.camera-bridge.app';
  const AWAY_PORT = 51820;
  const AWAY_SUBNET = '10.123.45';
  const AWAY_STATES = ['off', 'checking', 'no_ipv6', 'setup', 'working', 'address_changed', 'problem'];
  const away = { available: true, on: false, state: 'off', problem: null, router: null, addressChangedAt: null, devices: [] };
  const awayUnavailable = () => new ApiError(503, 'unavailable', 'Away from home is part of Camera Bridge OS.');
  const awayHasAddress = () => away.on && !['checking', 'no_ipv6'].includes(away.state);
  // The bridge's order (AwayService.ordered): the devices that reached the box from away, the newest first, then the others as they were added.
  const awayOrdered = () => [...away.devices].sort((a, b) => (Date.parse(b.lastAwayAt ?? '') || 0) - (Date.parse(a.lastAwayAt ?? '') || 0) || a.added - b.added);
  const awayDevice = ({ id, kind, name, lastHandshake, lastAwayAt }) => ({ id, kind, name, lastHandshake, lastAwayAt });
  function awayCard() {
    if (!away.available) throw awayUnavailable();
    if (!away.on) {
      return { on: false, state: away.problem ? 'problem' : 'off', problem: away.problem, port: AWAY_PORT, address: null, name: null, router: null, addressChangedAt: null, devices: [] };
    }
    return {
      on: true, state: away.state, problem: away.state === 'problem' ? away.problem ?? 'The VPN interface isn’t up.' : null, port: AWAY_PORT,
      address: awayHasAddress() ? AWAY_ADDRESS : null, name: AWAY_NAME, router: away.router,
      addressChangedAt: away.state === 'address_changed' ? away.addressChangedAt : null, devices: awayOrdered().map(awayDevice),
    };
  }
  function setAwayState(next) {
    away.state = next;
    away.on = next !== 'off';
    if (!away.on) away.devices = [];
    const now = state.serverNow();
    // Working means some device reached the box from away, and a changed address means it did before the change: one is added when none has.
    if (['working', 'address_changed'].includes(next) && !away.devices.some((device) => device.lastAwayAt)) {
      const at = new Date(now - 5 * 60_000).toISOString();
      away.devices.push({ id: randomBytes(16).toString('hex'), kind: 'app', name: 'iPhone', lastHandshake: at, lastAwayAt: at, added: now });
    }
    if (next === 'address_changed') away.addressChangedAt = new Date(now).toISOString();
  }
  function awaySetOn(ctx) {
    if (typeof ctx.body.on !== 'boolean') throw ApiError.invalid(ctx.body.on === undefined ? '“on” is missing.' : '“on” has the wrong kind of value.', 'on');
    if (!away.available) throw awayUnavailable();
    away.problem = null;
    if (ctx.body.on) {
      secure.enabled = true;   // as the bridge does: the phone talks HTTPS to the secure name through the tunnel
      // Turning it on, or the card's Try again on a problem: here the system always takes it.
      if (!away.on || away.state === 'problem') setAwayState('setup');
    } else {
      setAwayState('off');
    }
    return json(awayCard());
  }
  function awayAddDevice(ctx) {
    const { name } = ctx.body;
    if (name !== undefined && name !== null && typeof name !== 'string') throw ApiError.invalid('“name” has the wrong kind of value.', 'name');
    if (!away.available) throw awayUnavailable();
    if (!away.on) throw new ApiError(409, 'away_off', 'Away from home is off on the box.');
    // Cleaned as the box cleans a device's name (AuthStore.cleaned): no control characters, trimmed, at most 60 characters.
    const cleaned = String(name ?? '').replace(/\p{Cc}/gu, '').trim().slice(0, 60);
    if (!cleaned) throw ApiError.invalid('Give the device a name.', 'name');
    if (away.devices.filter((device) => device.kind === 'wireguard').length >= 20) {
      throw new ApiError(409, 'too_many_devices', '20 devices use the WireGuard app already. Remove one first.');
    }
    if (!awayHasAddress()) throw new ApiError(409, 'no_address', 'The box has no address on the internet yet, so a device couldn’t reach it from away.');
    const taken = new Set(away.devices.map((device) => device.address));
    let host = 2;
    while (taken.has(host)) host += 1;
    const device = { id: randomBytes(16).toString('hex'), kind: 'wireguard', name: cleaned, lastHandshake: null, lastAwayAt: null, address: host, added: state.serverNow() };
    away.devices.push(device);
    // AwayRules.wireGuardConfig's text, with placeholders of a key's length where the keys go.
    const config = ['[Interface]', `PrivateKey = ${'devserver-placeholder-not-a-key'.padEnd(44, '-')}`, `Address = ${AWAY_SUBNET}.${host}/32`, 'MTU = 1280', '',
      '[Peer]', `PublicKey = ${'devserver-placeholder-box-key'.padEnd(44, '-')}`, `AllowedIPs = ${AWAY_SUBNET}.1/32, ${secureReport().address}/32`,
      `Endpoint = [${AWAY_ADDRESS}]:${AWAY_PORT}`, ''].join('\n');
    return json({ device: awayDevice(device), config }, 201);
  }
  function awayRemoveDevice(ctx) {
    if (!away.available) throw awayUnavailable();
    const before = away.devices.length;
    away.devices = away.devices.filter((device) => device.id !== ctx.params.id);
    if (away.devices.length === before) throw ApiError.notFound('That device isn’t there any more.');
    return empty(204);
  }
  function secureCheck() {
    const blocked = secure.router === 'blocked';
    secure.rebind = blocked
      ? { state: 'blocked', message: 'Your router doesn’t give out names that point inside your home (DNS rebind protection).', checkedAt: new Date(state.serverNow()).toISOString() }
      : { state: 'ok', message: 'Your router gives out the secure address.', checkedAt: new Date(state.serverNow()).toISOString() };
    return json({ rebind: secure.rebind });
  }

  function snapshot(ctx) {
    const camera = findCamera(ctx);
    const name = typeof camera.definition.fixture === 'string' ? camera.definition.fixture : 'gop2';
    return bytes(fixtures.get(name).snapshot, 'image/jpeg', { 'Cache-Control': 'no-store' });
  }

  function live() {
    throw new ApiError(429, 'too_many_streams', 'Too many live previews are open. Close one and try again.', { headers: { 'Retry-After': '5' } });
  }

  // ---- the route table ----------------------------------------------------------------------------------------------------------

  // [method, pattern, access, takesBody, handler]
  const ROUTES = [
    ['GET', 'status', 'open', false, status],
    ['GET', 'health', 'open', false, () => json({ ok: true, state: 'running' })],
    ['GET', 'session', 'open', false, sessionInfo],
    ['POST', 'auth/login', 'open', true, login],
    ['POST', 'auth/logout', 'session', false, logout],
    ['GET', 'cameras', 'session', false, () => json({ cameras: state.cameraList().map((camera) => state.cameraResource(camera)) })],
    ['GET', 'cameras/:id', 'session', false, (ctx) => json(state.cameraResource(findCamera(ctx)))],
    ['PATCH', 'cameras/:id', 'session', true, patchCameraSettings],
    ['GET', 'cameras/:id/snapshot', 'session', false, snapshot],
    ['GET', 'cameras/:id/live', 'session', false, live],
    ['GET', 'cameras/:id/setup', 'session', false, setupPreview],
    ['POST', 'cameras/:id/setup', 'session', true, setupApply],
    ['POST', 'cameras/:id/setup/restore', 'session', true, setupRestore],
    ['POST', 'cameras/:id/night-vision', 'session', true, nightVision],
    ['POST', 'cameras/:id/security/check', 'session', false, (ctx) => json(checkSecurity(findCamera(ctx), state.serverNow()))],
    ['POST', 'cameras/:id/pan-tilt', 'session', true, panTilt],
    ['GET', 'settings', 'session', false, () => json({ bridgeName: config.bridgeName, ...settingsBody, sky: state.sky.settingsView() })],
    ['PATCH', 'settings', 'session', true, (ctx) => {
      if (ctx.body.sky !== undefined) state.sky.patchSettings(ctx.body.sky);
      if (typeof ctx.body.bridgeName === 'string') config.bridgeName = ctx.body.bridgeName.slice(0, 60);
      for (const name of Object.keys(settingsBody)) if (name in ctx.body && name !== 'cameraOrder' && name !== 'webhookToken' && name !== 'webhookProblem') settingsBody[name] = ctx.body[name];
      if ('cameraOrder' in ctx.body) {
        // As the bridge does: only cameras that exist, each once (a stale id is dropped, not an error).
        if (!Array.isArray(ctx.body.cameraOrder)) throw new ApiError(400, 'invalid', 'Send the cameras’ ids as a list.', { field: 'cameraOrder' });
        const known = new Set(state.cameraList().map((camera) => camera.configuration.id));
        settingsBody.cameraOrder = [...new Set(ctx.body.cameraOrder)].filter((id) => known.has(id));
      }
      return json({ bridgeName: config.bridgeName, ...settingsBody, sky: state.sky.settingsView() });
    }],
    // Plugins (BridgeWeb/WebApp+Plugins.swift): this server has one, Sky Watcher, with its switch (sky.mjs); Wyze and eufy need their clouds.
    ['GET', 'plugins', 'session', false, () => json({ plugins: state.sky.pluginList() })],
    ['PATCH', 'plugins/:id', 'session', true, (ctx) => json({ plugins: state.sky.patchPlugin(ctx.params.id, ctx.body) })],
    // Sky Watcher (BridgeWeb/WebApp+Sky.swift; sky.mjs has the made-up night): the log, a still, a correction, the flight feeds on the network.
    ['GET', 'sky/cameras/:id/night', 'session', false, (ctx) => json(state.sky.night(findCamera(ctx), ctx.query, state.serverNow()))],
    ['GET', 'sky/cameras/:id/entries/:eid/still', 'session', false, (ctx) => state.sky.still(findCamera(ctx), ctx.params.eid, ctx.query, state.serverNow())],
    ['POST', 'sky/cameras/:id/entries/:eid/correction', 'session', true, (ctx) => json(state.sky.correct(findCamera(ctx), ctx.params.eid, ctx.body, state.serverNow()))],
    ['POST', 'sky/feeds/find', 'session', false, () => json({ feeds: [...state.sky.feeds] })],
    // Notifications (BridgeWeb/WebApp+Notifications.swift): the log of every notice, the once-only claim for a toast, the read marker.
    ['GET', 'notifications', 'session', false, () => { state.notifications.record(state.notices(), state.serverNow()); return json({ unread: state.notifications.unread, notifications: state.notifications.list }); }],
    ['POST', 'notifications/shown', 'session', false, () => {
      const notices = state.notices();
      state.notifications.record(notices, state.serverNow());
      return json({ shown: state.notifications.claim(notices), unread: state.notifications.unread });
    }],
    ['POST', 'notifications/read', 'session', true, (ctx) => { state.notifications.markRead(ctx.body.ids); return json({ unread: state.notifications.unread }); }],
    ['GET', 'system', 'session', false, systemInfo],
    ['GET', 'system/secure-address', 'session', false, () => json(secureReport())],
    ['POST', 'system/secure-address/redirect', 'session', true, (ctx) => {
      if (typeof ctx.body.enabled !== 'boolean') throw ApiError.invalid('“enabled” is missing.', 'enabled');
      secure.redirect = ctx.body.enabled;
      return json(secureReport());
    }],
    ['POST', 'system/secure-address/enabled', 'session', true, secureEnabled],
    ['POST', 'system/secure-address/check', 'session', true, secureCheck],
    ['POST', 'system/secure-address/retry', 'session', true, () => json(secureReport())],
    ['GET', 'away', 'session', false, () => json(awayCard())],
    ['POST', 'away', 'session', true, awaySetOn],
    ['POST', 'away/devices', 'session', true, awayAddDevice],
    ['DELETE', 'away/devices/:id', 'session', false, awayRemoveDevice],
    ['GET', 'events', 'session', false, () => ({ events: true })],
    ...NVR_ROUTES.map(([method, pattern, handler, takesBody]) => [method, pattern, 'session', takesBody, (ctx) => handler(app, ctx)]),
  ];

  function matchRoute(method, segments) {
    const allowed = [];
    for (const route of ROUTES) {
      const pattern = route[1].split('/');
      if (pattern.length !== segments.length) continue;
      const params = {};
      if (!pattern.every((part, i) => (part.startsWith(':') ? ((params[part.slice(1)] = segments[i]), true) : part === segments[i]))) continue;
      if (route[0] === method) return { route, params };
      allowed.push(route[0]);
    }
    return allowed.length ? { allowed } : null;
  }

  // ---- one request ------------------------------------------------------------------------------------------------------------------

  async function api(request, url) {
    const segments = url.pathname.split('/').filter(Boolean);
    if (segments.length < 2 || segments[0] !== 'api' || segments[1] !== 'v1') throw ApiError.notFound('This address isn’t part of the API.');
    const found = matchRoute(request.method === 'HEAD' ? 'GET' : request.method, segments.slice(2));
    if (!found) throw ApiError.notFound('This address isn’t part of the API.');
    if (found.allowed) throw new ApiError(405, 'method_not_allowed', 'That isn’t possible here.', { headers: { Allow: [...new Set(found.allowed)].join(', ') } });
    const [, , access, takesBody, handler] = found.route;
    const unsafe = !['GET', 'HEAD'].includes(request.method);
    const raw = unsafe || takesBody ? await readBody(request) : Buffer.alloc(0);
    if (unsafe) {
      if (!originAllowed(request)) throw new ApiError(403, 'cross_origin', 'This request came from another site, so it was refused.');
      if (raw.length && !(request.headers['content-type'] ?? '').toLowerCase().startsWith('application/json')) {
        throw new ApiError(415, 'unsupported_media_type', 'Send JSON with Content-Type: application/json.');
      }
    }
    const token = parseCookies(request.headers.cookie)[COOKIE_NAME];
    const session = token ? sessions.get(token) : undefined;
    if (access === 'session') {
      if (!session) throw new ApiError(401, 'unauthorized', 'Sign in to continue.', { headers: { 'Set-Cookie': CLEARED_COOKIE } });
      if (unsafe && !(request.headers['x-csrf-token'] && constantTimeEqual(request.headers['x-csrf-token'], session.csrfToken))) {
        throw new ApiError(403, 'csrf', 'This page is out of date. Reload it and try again.');
      }
    }
    const ctx = { request, params: found.params, query: url.searchParams, session, token, address: request.socket.remoteAddress ?? 'unknown', body: undefined };
    if (takesBody) ctx.body = parseObject(raw);
    return handler(ctx);
  }

  const eventClients = new Set();   // the open event streams' writers (the development 'event' control sends to them)
  function devControls(request, url, body) {
    if (!isLoopback(request.socket.remoteAddress)) return { status: 403, headers: { 'Content-Type': 'text/plain; charset=utf-8' }, body: Buffer.from('The development controls answer this computer only.\n') };
    const view = () => json({
      scenario: state.scenario, scenarios: Object.keys(SCENARIOS), clockOffsetMs: state.clockOffset, serverTime: state.serverNow(),
      settings: state.settings, slots: { total: slots.total, byAddress: Object.fromEntries(slots.byAddress), peakTotal: slots.peakTotal, peakByAddress: slots.peakByAddress },
      options: Object.fromEntries(Object.keys(config).filter((name) => typeof config[name] === 'number').map((name) => [name, config[name]])),
      cameras: state.cameraList().map((camera) => ({ id: camera.definition.id, name: camera.definition.name, nvrEnabled: camera.configuration.nvrEnabled, recording: state.archive.isRecording(camera.definition.id) })),
    });
    if (request.method === 'GET' && url.pathname === '/__dev/state') return view();
    if (request.method !== 'POST') return { status: 405, headers: { Allow: 'GET, POST' }, body: null };
    const input = parseObject(body);
    if (url.pathname === '/__dev/scenario') {
      if (!(input.name in SCENARIOS)) throw ApiError.invalid(`The scenarios are ${Object.keys(SCENARIOS).join(', ')}.`, 'name');
      state.setScenario(input.name);
    } else if (url.pathname === '/__dev/reset') {
      state.reset(input.scenario ?? 'ok');
      slots.peakTotal = 0;
      slots.peakByAddress = 0;
    } else if (url.pathname === '/__dev/clock') {
      state.clockOffset = Number(input.offsetMs) || 0;
    } else if (url.pathname === '/__dev/event') {
      // Sends a motion (kind 'motion') or doorbell (kind 'doorbell') event for camera `id` to every open page: to try the monitor's notices.
      const camera = state.cameraList().find((c) => c.definition.id === input.id);
      if (!camera) throw ApiError.invalid('No camera has that id.', 'id');
      const kind = input.kind === 'doorbell' ? 'doorbell' : 'motion';
      const resource = kind === 'doorbell' ? { id: input.id, name: camera.definition.name, date: new Date().toISOString() } : { id: input.id, name: camera.definition.name, active: true };
      for (const write of eventClients) write(kind, resource);
      const seconds = Math.min(Math.max(Number(input.seconds) || 8, 1), 120);
      state.noteEvent(camera, kind === 'doorbell' ? 'Doorbell ring' : 'Motion', kind === 'doorbell' ? 0 : seconds);
      // Motion ends after `seconds` (8 by default), as a camera's would: the monitor's list shows how long it lasted.
      if (kind === 'motion') {
        setTimeout(() => { for (const write of eventClients) write('motion', { ...resource, active: false }); }, seconds * 1000).unref?.();
      }
    } else if (url.pathname === '/__dev/night-vision') {
      // Makes camera `id`'s night vision changes fail with 422 (`fail`: true or a sentence), or work again (false): to try the page's error.
      const camera = state.cameraList().find((c) => c.definition.id === input.id);
      if (!camera) throw ApiError.invalid('No camera has that id.', 'id');
      setNightVisionFailure(camera, input.fail);
    } else if (url.pathname === '/__dev/sky') {
      // What the box reports about Sky Watcher: {plugin: on | off, aim: rough | good | mixed | precise, learning: learning | ready, problem, stream: main | sub, location, feeds}.
      state.sky.control(input);
    } else if (url.pathname === '/__dev/secure') {
      if (['ready', 'waiting', 'error', 'off'].includes(input.state)) secure.state = input.state;
      if (['open', 'blocked'].includes(input.router)) { secure.router = input.router; secure.rebind = null; }
    } else if (url.pathname === '/__dev/away') {
      // What the box says about Away from home: {available, on, state, router: 'eero' | null, problem, devices: [{id, kind, name, lastHandshake, lastAwayAt}]}.
      if (typeof input.available === 'boolean') away.available = input.available;
      if (typeof input.on === 'boolean') setAwayState(input.on ? (away.on ? away.state : 'setup') : 'off');
      if (Array.isArray(input.devices)) away.devices = input.devices.map((device, index) => ({ ...awayDevice({ lastHandshake: null, lastAwayAt: null, ...device }), added: index }));
      if (AWAY_STATES.includes(input.state)) setAwayState(input.state);
      if ('router' in input) away.router = input.router === 'eero' ? 'eero' : null;
      if ('problem' in input) away.problem = typeof input.problem === 'string' ? input.problem : null;
    } else if (url.pathname === '/__dev/options') {
      for (const [name, value] of Object.entries(input)) if (typeof config[name] === 'number' && Number.isFinite(value)) config[name] = value;
    } else {
      return { status: 404, headers: {}, body: null };
    }
    return view();
  }

  async function dispatch(request) {
    if (!hostAllowed(request, config.allowedHosts)) {
      return { status: 421, headers: { 'Content-Type': 'text/plain; charset=utf-8' }, body: Buffer.from('Unrecognised host name. Use the bridge’s IP address or its .local name.\n') };
    }
    const url = new URL(request.url, 'http://placeholder');
    if (url.pathname.startsWith('/__dev/')) return devControls(request, url, request.method === 'POST' ? await readBody(request) : Buffer.alloc(0));
    if (url.pathname === '/api' || url.pathname.startsWith('/api/')) {
      try {
        return await api(request, url);
      } catch (error) {
        if (error instanceof ApiError) return errorResponse(error);
        throw error;
      }
    }
    return serveFile(request, url.pathname);
  }

  function serveEvents(request, response) {
    if (streams.events >= config.maximumEventStreams) {
      send(request, response, errorResponse(new ApiError(429, 'too_many_streams', 'Too many pages are listening. Close one and try again.', { headers: { 'Retry-After': '5' } })), true);
      return;
    }
    streams.events += 1;
    response.writeHead(200, withSecurityHeaders({ 'Content-Type': 'text/event-stream; charset=utf-8', 'Cache-Control': 'no-store', 'X-Accel-Buffering': 'no' }, true));
    const write = (name, value) => response.write(`event: ${name}\ndata: ${JSON.stringify(value)}\n\n`);
    eventClients.add(write);
    const cameraJson = () => new Map(state.cameraList().map((camera) => [camera.definition.id, JSON.stringify(state.cameraResource(camera))]));
    let seen = cameraJson();
    let notices = JSON.stringify(state.notices().map(({ id, severity, detail }) => [id, severity, detail]));
    response.write('retry: 3000\n\n');
    write('bridge', { state: 'running', stateText: 'Running' });
    for (const camera of state.cameraList()) write('camera', JSON.parse(seen.get(camera.definition.id)));
    write('notices', state.notices());
    let pinged = Date.now();
    const timer = setInterval(() => {
      const now = cameraJson();
      for (const [id, text] of now) if (seen.get(id) !== text) write('camera', JSON.parse(text));
      seen = now;
      const list = state.notices();
      const fingerprint = JSON.stringify(list.map(({ id, severity, detail }) => [id, severity, detail]));
      if (fingerprint !== notices) write('notices', list);
      notices = fingerprint;
      if (Date.now() - pinged >= 15_000) { response.write(': ping\n\n'); pinged = Date.now(); }
    }, config.eventIntervalMs);
    response.on('close', () => { clearInterval(timer); streams.events -= 1; eventClients.delete(write); });
  }

  function send(request, response, result, isAPI) {
    const headers = withSecurityHeaders(result.headers, isAPI);
    const hasBody = result.body && result.status !== 204 && result.status !== 304;
    if (hasBody) headers['Content-Length'] = result.body.length;
    response.writeHead(result.status, headers);
    response.end(hasBody && request.method !== 'HEAD' ? result.body : undefined);
  }

  const server = http.createServer(async (request, response) => {
    const path = request.url.split('?')[0];
    const isAPI = path === '/api' || path.startsWith('/api/');
    try {
      const result = await dispatch(request);
      if (result.events) {
        serveEvents(request, response);
        return;
      }
      send(request, response, result, isAPI);
      log(`${request.method} ${path} -> ${result.status}`);
    } catch (error) {
      log(`${request.method} ${path} failed: ${error.name}`);
      send(request, response, errorResponse(new ApiError(500, 'internal', 'Something went wrong in the dev server.')), isAPI);
    }
  });

  return {
    server,
    state,
    config,
    slots,
    listen: () => new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(config.port, config.host, () => resolve(server.address()));
    }),
    close: () => new Promise((resolve) => {
      clearTimeout(state.loadingTimer);
      server.close(() => resolve());
      server.closeAllConnections();
    }),
  };
}

