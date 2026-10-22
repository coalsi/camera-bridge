// The cameras' security levels on the dev server, as the bridge answers status.security (BridgeWeb/Resources.swift CameraSecurityResource; the
// levels, their words and the findings' sentences: BridgeEngine/Security/CameraSecurity.swift). One camera per level (a definition's
// `security`: red, yellow, green or gold) and one watched camera that keeps trying to reach the internet (`trying`: its blocked attempts count in its favour, so gold), checked three
// hours before the server's now; the others have not been checked yet, so the key is absent, as on the bridge until a camera's first check.
// Findings are worst first; every key is always there, `guard` too (what the Internet guard saw: the dev server plays Camera Bridge OS, so
// every checked camera has one). POST cameras/:id/security/check answers as the bridge does (checkSecurity).

import { ApiError } from './http.mjs';

const TITLES = { red: 'Outside access possible', yellow: 'Needs work', green: 'Good', gold: 'Local only' };

const SUMMARIES = {
  red: 'Something on this camera can let it be reached from outside your home.',
  yellow: 'Nothing Camera Bridge read opens this camera to the outside, but something needs work.',
  green: 'Camera Bridge found no cloud turned on, but it can’t confirm everything, so a way out is still possible.',
  gold: 'Every outside feature Camera Bridge knows for this camera is off, its video needs a password, and the Internet guard saw nothing get out in the last 24 hours.',
};

const finding = (feature, state, level, sentence, { canChange = false, linked = null, service = null } = {}) =>
  ({ feature, state, level, sentence, canChange, linked, service });

const WATCHED_QUIET = finding('internetGuard', 'on', 'gold', 'The Internet guard has watched it for the last 24 hours and saw it make no internet lookups.');
const NOT_WATCHED = finding('internetGuard', 'off', 'green', 'The Internet guard doesn’t watch this camera, so Camera Bridge can’t confirm that nothing gets out.');
const VIDEO_LOCKED = finding('unauthenticatedVideo', 'off', 'gold', 'Its video needs a password.');
const TRYING = finding('internetGuard', 'on', 'gold', 'The Internet guard blocked 112 attempts to reach the internet in the last 24 hours '
  + '(*.p2p.example.com, cloud.example.net, time.example.org). Nothing got out.');

/** The findings of each level's camera. */
export const SECURITY_FINDINGS = {
  red: [
    finding('cloud', 'on', 'red', 'Hik-Connect is on, and Camera Bridge can’t tell whether it is linked to an account. If it is, the camera can be '
      + 'reached from outside your home.', { canChange: true, service: 'Hik-Connect' }),
    finding('upnp', 'on', 'red', 'UPnP is on, so the camera can open ports on your router to the internet.', { canChange: true }),
    finding('ddns', 'absent', 'gold', 'The camera has no dynamic DNS.'),
    VIDEO_LOCKED,
    WATCHED_QUIET,
  ],
  yellow: [
    finding('cloud', 'unknown', 'yellow', 'Camera Bridge can’t read whether the maker’s cloud is on.'),
    finding('unauthenticatedVideo', 'on', 'yellow', 'Its video plays without a password on your home network.'),
    NOT_WATCHED,
  ],
  green: [
    finding('ddns', 'unknown', 'green', 'Camera Bridge can’t read whether dynamic DNS is on.'),
    NOT_WATCHED,
    finding('cloud', 'off', 'gold', 'Hik-Connect is off.', { canChange: true, service: 'Hik-Connect' }),
    finding('upnp', 'off', 'gold', 'UPnP is off.', { canChange: true }),
    VIDEO_LOCKED,
  ],
  gold: [
    finding('cloud', 'off', 'gold', 'VisionEye cloud is off.', { canChange: true, service: 'VisionEye cloud' }),
    finding('cloud', 'absent', 'gold', 'The camera has no P2P service.', { service: 'P2P service' }),
    finding('upnp', 'absent', 'gold', 'The camera has no UPnP.'),
    finding('ddns', 'off', 'gold', 'Dynamic DNS is off.'),
    finding('rtmp', 'off', 'gold', 'RTMP push is off.'),
    VIDEO_LOCKED,
    finding('extraService', 'off', 'gold', 'Meari service (port 10000) is off.', { canChange: true, service: 'Meari service (port 10000)' }),
    WATCHED_QUIET,
  ],
  trying: [
    TRYING,
    finding('cloud', 'off', 'gold', 'Hik-Connect is off.', { canChange: true, service: 'Hik-Connect' }),
    finding('upnp', 'off', 'gold', 'UPnP is off.', { canChange: true }),
    VIDEO_LOCKED,
  ],
};

/** Each fake's level (the key, but for `trying`). */
const LEVEL = { red: 'red', yellow: 'yellow', green: 'green', gold: 'gold', trying: 'gold' };

const MINUTE = 60_000;
const quiet = () => ({ watched: true, today: 0, last24h: 0, last7d: 0, names: [] });
const notWatched = () => ({ watched: false, today: 0, last24h: 0, last7d: 0, names: [] });
const at = (ms) => new Date(Math.floor(ms / 1000) * 1000).toISOString().replace('.000Z', 'Z');

/** status.security.guard of each fake: watched or not, its blocked lookups today and in 24 hours, and its names, most asked first (the bridge's
 *  order), each with when it was first and last asked for in the last 7 days. */
const GUARD = {
  red: quiet,
  yellow: notWatched,
  green: notWatched,
  gold: quiet,
  trying: (nowMs) => ({ watched: true, today: 47, last24h: 112, last7d: 389, names: [
    { name: '*.p2p.example.com', count: 290, first: at(nowMs - 6 * 24 * 60 * MINUTE), last: at(nowMs - 4 * MINUTE) },
    { name: 'cloud.example.net', count: 75, first: at(nowMs - 5 * 24 * 60 * MINUTE), last: at(nowMs - 120 * MINUTE) },
    { name: 'time.example.org', count: 21, first: at(nowMs - 4 * 24 * 60 * MINUTE), last: at(nowMs - 20 * 60 * MINUTE) },
    { name: 'update.example.com', count: 3, first: at(nowMs - 3 * 24 * 60 * MINUTE), last: at(nowMs - 3 * 24 * 60 * MINUTE) },
  ] }),
};

/** A check on demand within this long of the camera's last one is refused (EngineTuning.securityCheckCooldown). */
export const SECURITY_CHECK_COOLDOWN_MS = 60_000;

/** status.security of a camera (undefined while it has not been checked: the bridge leaves the key out), checked three hours ago or when
 * it was last checked on demand. */
export function securityStatus(camera, nowMs) {
  const fake = camera.definition.security;
  if (!SECURITY_FINDINGS[fake]) return undefined;
  const level = LEVEL[fake];
  const checkedAt = at(camera.securityCheckedMs ?? nowMs - 3 * 3_600_000);
  return { level, title: TITLES[level], summary: SUMMARIES[level], checkedAt, findings: SECURITY_FINDINGS[fake].map((item) => ({ ...item })), guard: GUARD[fake](nowMs) };
}

/**
 * POST cameras/:id/security/check (WebApp+Routes.swift checkSecurity) for a camera `find` found (it throws the 404): 429
 * security_check_too_soon with Retry-After within a minute of the last check on demand, 409 camera_offline for a camera turned off, 422
 * security_check_unavailable for one the dev server has no level for; else the camera's status.security, checked now. The time lives on the
 * camera's entry, so /__dev/reset puts it back.
 */
export function checkSecurity(camera, nowMs) {
  const last = camera.securityCheckedMs;
  if (last !== undefined && nowMs - last < SECURITY_CHECK_COOLDOWN_MS) {
    const seconds = Math.max(1, Math.ceil((SECURITY_CHECK_COOLDOWN_MS - (nowMs - last)) / 1000));
    throw new ApiError(429, 'security_check_too_soon', 'This camera was checked less than a minute ago. Try again in a minute.', { headers: { 'Retry-After': String(seconds) } });
  }
  if (!camera.configuration.isEnabled) throw new ApiError(409, 'camera_offline', 'The camera isn’t answering, so it can’t be checked now.');
  if (!SECURITY_FINDINGS[camera.definition.security]) throw new ApiError(422, 'security_check_unavailable', 'This bridge can’t check cameras.');
  camera.securityCheckedMs = nowMs;
  return securityStatus(camera, nowMs);
}
