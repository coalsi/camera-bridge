// Security: how far a camera can be reached from outside the home, from what Camera Bridge read of it and what its Internet guard saw
// (status.security: BridgeWeb/Resources.swift CameraSecurityResource; the levels and the findings' sentences: BridgeEngine/Security/
// CameraSecurity.swift). Four levels, worst first: red "Outside access possible", yellow "Needs work", green "Good", gold "Local only"; gold
// needs the Internet guard of Camera Bridge OS, so on a bridge without it green is the best. Shown as a badge (a shield in the level's colour
// with its own mark, and the level's word) on the Cameras page with a legend under the table, beside the camera's name, as a dot beside each
// name on the Monitor, and as the camera page's Security card: the findings in plain words, "Check again" (POST cameras/:id/security/check,
// at most once a minute), "Fix with Set up for Camera Bridge" for what the setup can change, "Change it by hand" (manual-help.js) under what
// it can't, "Restart the camera now" while the camera waits for a restart (camera-setup.js restartControl), and the Internet guard (Watch:
// what it blocked today and in 24 hours; how to point the camera's DNS at Camera Bridge by hand while it is not watched; each name it blocked
// with how often, first and last, and what it likely is, guard-names.js) with the router help. The banner's "See what <camera> tried" opens
// the card (#/camera/<id>/security). Colour is never alone: the level's word is always shown or read out. Nothing here checks a camera by
// itself.
import { api } from '../api.js';
import { h, replace, svg } from '../dom.js';
import { icon } from '../icons.js';
import { timeAgo } from '../format.js';
import { describeGuardName } from '../guard-names.js';
import { putCamera, store } from '../store.js';
import { inlineError } from './common.js';
import { MANUAL_TEXT, manualHelpBlock, manualHelpView } from './manual-help.js';

/** The levels, worst first (the bridge's order). */
export const SECURITY_LEVELS = ['red', 'yellow', 'green', 'gold'];

/** Every word of the security levels, in one table. The levels' names are the bridge's (CameraSecurityLevel.title). */
export const SECURITY_TEXT = {
  title: 'Security',
  levels: { red: 'Outside access possible', yellow: 'Needs work', green: 'Good', gold: 'Local only' },
  colours: { red: 'Red', yellow: 'Yellow', green: 'Green', gold: 'Gold' },
  /** What each colour means (the owner's words, 2026-10-17). */
  meanings: {
    gold: 'Camera Bridge found no way in from outside, and its Internet guard saw nothing get out for a full day and has seen at least one lookup from it.',
    green: 'Its cloud is off; something Camera Bridge can’t confirm remains.',
    yellow: 'Camera Bridge found nothing that lets it in from outside, but something needs work: its cloud is on but not linked, its video plays '
      + 'without a password on your network, or Camera Bridge can’t read its cloud.',
    red: 'Its cloud, UPnP, dynamic DNS or RTMP push is on, or it only works through its maker’s cloud.',
  },
  legend: 'What do the colours mean?',
  goldNeedsGuard: 'Gold needs the Internet guard of Camera Bridge OS: on a bridge without it, Good is the best a camera can show.',
  checking: 'Checking…',
  notChecked: 'Not checked yet.',
  notCheckedMeaning: 'Not checked yet. Camera Bridge checks each camera a minute after it starts, again every day, and again soon when it didn’t answer. '
    + 'A camera that is turned off isn’t checked: it keeps the level of its last check, if it had one.',
  notCheckedCard: 'Not checked yet. Camera Bridge checks the camera a minute after it starts, and again every day.',
  turnedOff: 'Turn the camera on to check it.',
  checked: (when) => `Checked ${when}.`,
  /** Said once a check on demand finished, for a screen reader. */
  announced: (word) => `Checked: ${word}.`,
  checkAgain: 'Check again',
  checkNow: 'Check now',
  canChange: 'Set up for Camera Bridge can change this.',
  fix: 'Fix with Set up for Camera Bridge…',
  fixDesc: 'Shows each change first, and can put everything back.',
  failed: 'The check didn’t finish. Try again.',
  /** Said while the camera's AI switch is on and its service is not on the home network: the guard's level is about the camera's own traffic. */
  aiLeaves: (service) => `Its event pictures go to ${service} for AI descriptions.`,
};

/** The Internet guard's words, in one table (the bridge's InternetGuardText, BridgeEngine/Security/InternetGuard.swift, and the page's own). */
export const GUARD_TEXT = {
  name: 'Internet guard',
  /** Its levels. Seal is not built yet (stage 2): nothing on the page offers it. */
  watch: 'Watch',
  seal: 'Seal',
  watchStep: 'Watch its internet',
  /** The camera page's button: it opens Set up for Camera Bridge, which runs every step, Watch among them. */
  watchWithSetup: 'Set up for Camera Bridge (includes Watch)',
  watchWithSetupDesc: 'The whole setup runs, and it shows every change first.',
  sealStep: 'Seal it from the internet',
  notOnThisBridge: 'Camera Bridge OS watches cameras’ internet; this bridge does not.',
  notOnItsNetwork: 'Camera Bridge can watch only cameras on its own local network.',
  watching: 'Watching',
  notWatched: 'Not watched',
  notHere: 'Not on this bridge',
  whatWatchDoes: 'Watch points the camera’s internet lookups (its DNS) at Camera Bridge, which blocks every one and lists them here. The maker’s app '
    + 'then stops working away from home; Camera Bridge, Apple Home and your recordings keep working.',
  limit: 'Watch sees lookups by name only. A camera with a built-in internet address needs none, so to be sure, also block it in your router (below).',
  quiet: 'It made no internet lookups in the last 24 hours.',
  /** A watched camera whose attempts the guard blocks: the guard working, so it reads as a success. */
  blocked: (today, week) => {
    const attempts = (n) => `${n} attempt${n === 1 ? '' : 's'}`;
    return today > 0 ? `Blocked ${attempts(today)} today, ${week} in the last 7 days. Nothing got out.`
      : `Blocked ${attempts(week)} in the last 7 days, none today. Nothing got out.`;
  },
  blockedName: 'Blocked',
  names: 'The internet names it looked up (last 7 days)',
  times: (count) => `${count} time${count === 1 ? '' : 's'}`,
  /** Under the names when one of them is likely the maker's cloud: the guard sees names and times only, not who caused them, so the
   *  person can weigh their own use of the maker's app. */
  wasItYou: 'Cameras look these up on their own, and also when you use the maker’s phone app or website with them. If you used this camera’s '
    + 'app around one of these times, that may have been you.',
  cantWatch: 'Camera Bridge can’t change this camera’s settings, so it can’t watch it. Your router can keep it off the internet (below).',
  router: 'Your router can keep it off the internet (below).',
  cloudOnly: 'This camera needs its maker’s cloud to work with Camera Bridge, so it can’t be kept off the internet.',
};

/** A check reads the camera and asks for its video once without a password; it is never endless. */
export const SECURITY_CHECK_TIMEOUT_MS = 60_000;

const count = (value) => (Number.isFinite(value) && value > 0 ? Math.floor(value) : 0);

const readTime = (value) => (Number.isFinite(Date.parse(value)) ? Date.parse(value) : null);

/** The guard's part of the view: on a bridge without it (`guard` null) nothing is watched. Names newest first, one never seen last at the end. */
function guardView(guard, finding) {
  const sentence = typeof finding?.sentence === 'string' && finding.sentence ? finding.sentence : null;
  const manual = manualHelpView(finding?.manualHelp);
  if (!guard || typeof guard !== 'object') {
    return { onBridge: false, watched: false, today: 0, last24h: 0, last7d: 0, names: [], sentence: sentence ?? GUARD_TEXT.notOnThisBridge, running: false, manual: null };
  }
  const names = (Array.isArray(guard.names) ? guard.names : [])
    .filter((entry) => entry && typeof entry.name === 'string' && entry.name)
    .map((entry, index) => ({ name: entry.name, count: count(entry.count), first: readTime(entry.first), last: readTime(entry.last), index }))
    .sort((a, b) => (b.last ?? -Infinity) - (a.last ?? -Infinity) || a.index - b.index)
    .map(({ index, ...entry }) => entry);
  const watched = guard.watched === true;
  return { onBridge: true, watched, today: count(guard.today), last24h: count(guard.last24h), last7d: count(guard.last7d), names, sentence, running: finding?.state !== 'unknown',
    manual: watched ? null : manual };
}

/**
 * What the page shows for `camera`'s status.security: null until its first check (the bridge leaves the key out) or for a level the page
 * does not know, else
 *   level      'red' | 'yellow' | 'green' | 'gold', and its `word`
 *   summary    the bridge's sentence for the level; checkedAt in ms (null when unreadable)
 *   findings   the camera's, worst first as the bridge sent them, without the guard's: { feature, state, level, sentence, canChange, fixable,
 *              manual } (fixable: Set up for Camera Bridge can change it and it is not right yet; manual: the bridge's "Change it by hand",
 *              manual-help.js, or null); `fixable` lists those
 *   guard      { onBridge, watched, today, last24h, names: [{ name, count, first, last }] newest first (times in ms, null when the bridge
 *              does not say), sentence (the guard's finding), running,
 *              manual (how to point its DNS at Camera Bridge by hand while it is not watched, or null) }
 */
export function securityView(camera) {
  const security = camera?.status?.security;
  if (!security || typeof security !== 'object' || !SECURITY_LEVELS.includes(security.level)) return null;
  const all = (Array.isArray(security.findings) ? security.findings : []).filter((entry) => entry && typeof entry === 'object' && typeof entry.sentence === 'string' && entry.sentence);
  const findings = all.filter((entry) => entry.feature !== 'internetGuard').map((entry) => {
    const level = SECURITY_LEVELS.includes(entry.level) ? entry.level : null;
    const canChange = entry.canChange === true;
    return { feature: entry.feature, state: entry.state, level, sentence: entry.sentence, canChange, fixable: canChange && level !== null && level !== 'gold',
      manual: manualHelpView(entry.manualHelp) };
  });
  const checked = Date.parse(security.checkedAt);
  return {
    level: security.level,
    word: SECURITY_TEXT.levels[security.level],
    summary: typeof security.summary === 'string' ? security.summary : '',
    checkedAt: Number.isFinite(checked) ? checked : null,
    findings,
    fixable: findings.filter((entry) => entry.fixable),
    guard: guardView(security.guard, all.find((entry) => entry.feature === 'internetGuard')),
  };
}

/** The integrations whose cameras work only through their maker's cloud (the bridge's CloudDependentModels, by integration): blocking
 *  their internet would stop them in Camera Bridge too. */
const CLOUD_ONLY_SERVICES = new Set(['wyze', 'eufy', 'ring', 'nest', 'tuya']);

/**
 * Whether `host` (a URL's host name) is on the home network: a private (10/8, 172.16/12, 192.168/16), loopback (127/8) or link-local
 * (169.254/16) IPv4 address, the IPv6 loopback or link-local address, `localhost`, or a `.local` or `.lan` name.
 */
export function isHomeNetworkHost(host) {
  const name = String(host ?? '').trim().toLowerCase().replace(/^\[|\]$/g, '').replace(/\.$/, '');
  if (!name) return false;
  const four = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(name);
  if (four) {
    const [a, b, c, d] = four.slice(1).map(Number);
    if ([a, b, c, d].some((part) => part > 255)) return false;
    return a === 10 || a === 127 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 169 && b === 254);
  }
  if (name.includes(':')) return name === '::1' || /^fe[89ab][0-9a-f]?:/.test(name);
  return name === 'localhost' || name.endsWith('.local') || name.endsWith('.lan');
}

/**
 * Where a camera's event pictures go for AI descriptions when that is away from home: "Claude", or the host of an OpenAI-compatible
 * service that is not on the home network; null when no service is chosen, its address cannot be read, or it is at home. `ai` is GET settings' `ai`.
 */
export function picturesGoTo(ai) {
  if (ai?.provider === 'anthropic') return 'Claude';
  if (ai?.provider !== 'openAICompatible' || typeof ai.baseURL !== 'string') return null;
  let host;
  try { host = new URL(ai.baseURL).hostname; } catch { return null; }
  return host && !isHomeNetworkHost(host) ? host : null;
}

/** Whether `camera` reaches Camera Bridge only through its maker's cloud, so the page never tells anyone to block its internet. */
export function needsMakersCloud(camera) {
  return CLOUD_ONLY_SERVICES.has(camera?.integration?.service);
}

/** Whether a camera without a level yet is about to get one (the bridge checks every camera but the demo one, once it runs). */
function awaitsCheck(camera) {
  const connection = camera?.status?.connection;
  return camera?.isEnabled === true && camera.vendor !== 'demo' && connection !== 'offline' && connection !== 'disabled';
}

/** `camera` with `security` as its status.security: what the store gets after a check. */
export function withSecurity(camera, security) {
  return { ...camera, status: { ...camera.status, security } };
}

/** The sentence for a check that didn't happen: the bridge's own (429 too soon, 409 offline, 422 can't check), never a script's error text. */
export function securityErrorText(error) {
  const message = error && typeof error === 'object' && 'status' in error && typeof error.message === 'string' ? error.message.trim() : '';
  return message || SECURITY_TEXT.failed;
}

/**
 * The checks, one at a time for each camera. `check(camera)` resolves { camera } (the camera with the answer as its status.security, also given
 * to `apply`, which puts it in the page's store) or { message, retryAfter } (why it didn't happen, and the seconds the bridge said to wait);
 * null while that camera's check is on its way. The answer goes into the camera as the store has it when the answer comes (`current`): a check
 * can take a minute, and the event stream may have brought a newer status or a rename meanwhile. `deps` are for tests: send(path),
 * apply(camera), current(id).
 */
export function createSecurityChecks({
  send = (path) => api('POST', path, {}, { timeoutMs: SECURITY_CHECK_TIMEOUT_MS }),
  apply = putCamera,
  current = (id) => store.cameras.get(id),
} = {}) {
  const busy = new Set();
  return {
    busy: (id) => busy.has(id),
    async check(camera) {
      const id = camera?.id;
      if (!id || busy.has(id)) return null;
      busy.add(id);
      try {
        const answer = await send(`cameras/${id}/security/check`);
        if (!answer || typeof answer !== 'object' || !SECURITY_LEVELS.includes(answer.level)) return { message: SECURITY_TEXT.failed };
        const updated = withSecurity(current(id) ?? camera, answer);
        apply(updated);
        return { camera: updated };
      } catch (error) {
        const wait = Number.isFinite(error?.retryAfter) && error.retryAfter > 0 ? error.retryAfter : null;
        return { message: securityErrorText(error), retryAfter: wait };
      } finally {
        busy.delete(id);
      }
    },
  };
}

// MARK: The badge

const SHIELD = 'M12 2.6l7.6 2.9v6.1c0 4.9-3.2 8.4-7.6 9.8-4.4-1.4-7.6-4.9-7.6-9.8V5.5z';
/** The mark inside each level's shield, so the levels differ by more than colour: a lock, a tick, an exclamation mark, a cross. */
const MARKS = {
  gold: ['M9.6 11.2V9.6a2.4 2.4 0 0 1 4.8 0v1.6', 'M8.6 11.2h6.8v4.6H8.6z'],
  green: ['M8.6 12.3l2.4 2.4 4.4-4.6'],
  yellow: ['M12 7.6v4.8', 'M12 15.6v.1'],
  red: ['M9.6 9.4l4.8 4.8', 'M14.4 9.4l-4.8 4.8'],
};

function shield(level) {
  return svg('svg', { class: 'sec-shield', viewBox: '0 0 24 24', 'aria-hidden': 'true', focusable: 'false' },
    svg('path', { class: 'sec-shield-body', d: SHIELD }), ...MARKS[level].map((d) => svg('path', { class: 'sec-shield-mark', d })));
}

/** A level's badge: its shield and its word ("Local only"). `prefix` adds "Security: " for a screen reader, where nothing around says it. */
export function securityBadge(level, { prefix = false } = {}) {
  const word = SECURITY_TEXT.levels[level];
  if (!word) return null;
  return h('span', { class: 'sec-badge', dataset: { level }, title: `${SECURITY_TEXT.title}: ${word}` },
    shield(level), prefix ? h('span', { class: 'sr-only' }, `${SECURITY_TEXT.title}: `) : null, h('span', { class: 'sec-word' }, word));
}

// MARK: The Cameras page

/** The Cameras page's Security cell: the badge and the bridge's summary (cut to two lines, whole in its tooltip); "Checking…" for a camera
 *  about to be checked, nothing for one that is off, offline or the demo camera. */
export function securityCell(camera) {
  const view = securityView(camera);
  if (view) return [securityBadge(view.level), view.summary ? h('div', { class: 'cam-sub sec-summary', title: view.summary }, view.summary) : null];
  return awaitsCheck(camera) ? [h('span', { class: 'faint' }, SECURITY_TEXT.checking)] : [];
}

/** "What do the colours mean?" under the Cameras table: each level, best first, in the owner's words, and what "Checking…" is. */
export function securityLegend() {
  return h('details', { class: 'sec-legend' },
    h('summary', null, SECURITY_TEXT.legend),
    h('dl', null,
      [...SECURITY_LEVELS].reverse().map((level) => [
        h('dt', null, securityBadge(level)),
        h('dd', null, `${SECURITY_TEXT.colours[level]}. ${SECURITY_TEXT.meanings[level]}`)]),
      h('dt', null, h('span', { class: 'faint' }, SECURITY_TEXT.checking)),
      h('dd', null, SECURITY_TEXT.notCheckedMeaning)),
    h('p', { class: 'small muted' }, SECURITY_TEXT.goldNeedsGuard));
}

// MARK: The Monitor

const dots = new WeakMap();   // the name slot -> its security dot

/**
 * The Monitor's mark beside a tile's name (`slot`, the tile's name slot): the level's small shield with its own mark (so the levels differ by
 * shape, not colour alone), the level's name as its label and tooltip; none before the camera's first check. Drawn in place, and only its own
 * mark: other marks in the slot are left alone.
 */
export function drawSecurityDot(slot, camera) {
  const view = securityView(camera);
  let dot = dots.get(slot);
  if (!view) {
    if (dot) { dot.remove(); dots.delete(slot); }
    return;
  }
  if (!dot) {
    dot = h('span', { class: 'sec-dot', role: 'img' });
    slot.append(dot);
    dots.set(slot, dot);
  }
  if (dot.dataset.level === view.level) return;
  dot.dataset.level = view.level;
  replace(dot, shield(view.level));
  const words = `${SECURITY_TEXT.title}: ${view.word}`;
  dot.setAttribute('aria-label', words);
  dot.setAttribute('title', words);
}

// MARK: The camera page

function when(ms, now) {
  return h('time', { datetime: new Date(ms).toISOString(), title: new Date(ms).toLocaleString() }, timeAgo(ms, now));
}

/** A finding of the card; `help(key, view)` draws its "Change it by hand" (open as the person left it). */
function findingItem(entry, canSetUp, help = (_key, view) => manualHelpBlock(view)) {
  const word = entry.level ? SECURITY_TEXT.levels[entry.level] : null;
  return h('li', { class: 'sec-finding' },
    h('span', { class: 'sec-mark', dataset: entry.level ? { level: entry.level } : null, 'aria-hidden': 'true' }, entry.level ? shield(entry.level) : null),
    h('div', null, word ? h('span', { class: 'sr-only' }, `${word}: `) : null, h('span', null, entry.sentence),
      entry.fixable && canSetUp ? h('span', { class: 'sec-can-change' }, SECURITY_TEXT.canChange) : null,
      help(`${entry.feature}|${entry.sentence}`, entry.manual)));
}

/**
 * A name the guard blocked: the name, how many times, first and last (the first left out when it reads the same as the last), and what it
 * likely is (`explain(name)`, guard-names.js describeGuardName: { text, hint }).
 */
export function nameItem(entry, now, explain = (name) => describeGuardName(name)) {
  const what = explain(entry.name);
  const last = entry.last !== null ? timeAgo(entry.last, now) : null;
  const first = entry.first !== null && timeAgo(entry.first, now) !== last ? entry.first : null;
  return h('li', { class: 'sec-name' }, h('code', null, entry.name),
    h('span', { class: 'muted sec-name-when' }, GUARD_TEXT.times(entry.count), first !== null ? [' · first ', when(first, now)] : null,
      entry.last !== null ? [' · last ', when(entry.last, now)] : null),
    h('span', { class: 'sec-name-ok' }, GUARD_TEXT.blockedName),
    h('span', { class: 'sec-name-what' }, what.text, what.hint ? [' ', h('span', { class: 'muted' }, what.hint)] : null));
}

/**
 * The camera page's Security card: the level and its summary, when it was checked with "Check again", the findings, "Fix with Set up for
 * Camera Bridge" for what the setup can change, and the Internet guard (watching or not, what it blocked, "Watch its internet") ending with
 * `routerHelp(camera)` (camera-setup.js localOnlyCard; none for a camera that needs its maker's cloud). `canSetUp`: the setup works with this
 * camera; `openSetup()` opens its dialog. `restart(camera)` draws "Restart the camera now" (camera-setup.js restartControl) while the bridge
 * says the camera waits for a restart (`restartOffered`), made once and kept while it does. `aiSettings` (GET settings, or a promise of it)
 * lets the card say, while the camera's AI switch is on and the AI service is not on the home network, where its event pictures go; the
 * guard's badge and level are not changed by it. It follows the camera in place (`update(camera)`), its buttons kept (they keep the
 * keyboard), hidden for the demo camera. Returns { el, heading (its "Security", which can take the focus), update, destroy }.
 */
export function createSecurityCard(camera, {
  canSetUp = false, openSetup = null, routerHelp = null, restart = null, checks = createSecurityChecks(), now = () => Date.now(),
  setTimer = (fn, ms) => setTimeout(fn, ms), aiSettings = null,
} = {}) {
  let current = camera;
  let problem = '';
  let problemAt = 0;          // when the check that failed was asked: a result newer than this clears the problem
  let problemTimer = null;
  let announced = '';         // "Checked: Local only." once a check on demand finished
  let aiAway = null;          // where Settings says event pictures go when that is away from home (picturesGoTo), once Settings answered
  let drawn = '';
  let destroyed = false;
  const openHelp = new Set();   // the "Change it by hand" disclosures the person opened: the card draws again every minute and on each new status
  const help = (key, view, options = {}) => manualHelpBlock(view, { ...options, open: openHelp.has(key),
    onToggle: (open) => { if (open) openHelp.add(key); else openHelp.delete(key); } });
  const setUp = canSetUp && typeof openSetup === 'function';
  const cloudOnly = needsMakersCloud(camera);

  const badge = h('span', { class: 'sec-card-badge' });
  const summary = h('p', { class: 'desc' });
  const aiNote = h('p', { class: 'small sec-ai-note', hidden: true });
  const checked = h('span', { class: 'small muted' });
  const checkButton = h('button', { class: 'btn small', type: 'button', onclick: () => checkNow() });
  const state = h('span', { class: 'save-state', role: 'status', 'aria-live': 'polite' });
  const problemHost = h('div', { class: 'sec-problem' });
  const findings = h('ul', { class: 'sec-findings' });
  const fixRow = h('div', { class: 'row sec-fix' },
    h('button', { class: 'btn small primary', type: 'button', onclick: () => openSetup?.() }, SECURITY_TEXT.fix),
    h('span', { class: 'small muted' }, SECURITY_TEXT.fixDesc));
  const restartHost = h('div', { class: 'sec-restart' });
  let restartEl = null;   // made once while the camera waits for a restart, so a confirmation under way survives the card's redraws
  const guardPill = h('span', { class: 'pill' });
  const guardText = h('div', { class: 'sec-guard-text' });
  const watchRow = h('div', { class: 'row' }, h('button', { class: 'btn small', type: 'button', onclick: () => openSetup?.() }, `${GUARD_TEXT.watchWithSetup}…`),
    h('span', { class: 'small muted' }, GUARD_TEXT.watchWithSetupDesc));
  const names = h('div', { class: 'sec-names' });
  const guardHelp = h('div', { class: 'sec-guard-help' });   // "Point its DNS at Camera Bridge yourself", after the setup's button
  const guard = h('div', { class: 'sec-guard' },
    h('div', { class: 'row spread' }, h('h3', { class: 'section-title' }, GUARD_TEXT.name), guardPill), guardText, watchRow, guardHelp, names);
  // The heading takes the focus when the banner's "See what <camera> tried" brings the card into view (camera.js).
  const heading = h('h2', { tabindex: '-1' }, SECURITY_TEXT.title);
  const el = h('div', { class: 'card sec-card' },
    h('div', { class: 'row spread' }, heading, badge),
    summary, aiNote, h('div', { class: 'row sec-checked' }, checked, checkButton, state), problemHost, findings, fixRow, restartHost, guard,
    routerHelp && !cloudOnly ? routerHelp(camera) : null);

  function drawGuard(view, at) {
    const g = view?.guard;
    guardPill.hidden = !g;
    watchRow.hidden = true;
    replace(names);
    replace(guardHelp);
    if (!g) { replace(guardText, h('p', { class: 'small muted' }, SECURITY_TEXT.notChecked)); return; }
    const line = (text) => h('p', { class: 'small' }, text);
    if (!g.onBridge) {
      guardPill.className = 'pill idle';
      guardPill.textContent = GUARD_TEXT.notHere;
      replace(guardText, line(g.sentence), line(cloudOnly ? GUARD_TEXT.cloudOnly : GUARD_TEXT.router));
      return;
    }
    if (!g.watched) {
      guardPill.className = 'pill idle';
      guardPill.textContent = GUARD_TEXT.notWatched;
      replace(guardText, g.sentence ? line(g.sentence) : null, cloudOnly ? line(GUARD_TEXT.cloudOnly)
        : [line(GUARD_TEXT.whatWatchDoes), setUp ? null : line(GUARD_TEXT.cantWatch)]);
      watchRow.hidden = !setUp;
      if (!cloudOnly) replace(guardHelp, help('internetGuard', g.manual, { summary: MANUAL_TEXT.watchSummary }));
      return;
    }
    guardPill.className = `pill ${g.running ? 'live' : 'warning'}`;
    guardPill.textContent = GUARD_TEXT.watching;
    // Blocked attempts are the guard working: a success line, not the bridge's warning-style sentence (which says the same for 24 hours).
    const tried = g.today > 0 || g.last24h > 0 || g.last7d > 0;
    const said = tried && g.running ? null : g.sentence ?? (tried ? null : GUARD_TEXT.quiet);
    replace(guardText, said ? line(said) : null,
      tried ? h('p', { class: 'small sec-guard-ok' }, icon('check'), GUARD_TEXT.blocked(g.today, Math.max(g.last7d, g.last24h))) : null,
      h('p', { class: 'small muted' }, GUARD_TEXT.limit));
    const described = new Map(g.names.map((entry) => [entry.name, describeGuardName(entry.name, { camera: current, canSetUp: setUp })]));
    const makersCloud = [...described.values()].some((what) => what.kind === 'cloud');
    if (g.names.length) {
      replace(names, h('p', { class: 'small muted' }, GUARD_TEXT.names),
        h('ul', { class: 'events' }, g.names.map((entry) => nameItem(entry, at, (name) => described.get(name)))),
        makersCloud ? h('p', { class: 'small muted sec-was-it-you' }, GUARD_TEXT.wasItYou) : null);
    }
  }

  function draw() {
    const view = securityView(current);
    const busy = checks.busy(current.id);
    const at = now();
    // What the names' explanations read of the camera (its maker, its setup's clock step) is part of what is drawn, and where its AI
    // pictures go while its switch is on.
    const leaving = current.aiDescriptions === true ? aiAway : null;
    const key = JSON.stringify([view, busy, problem, announced, current.isEnabled, current.vendor, current.manufacturer, current.setupState?.steps,
      leaving, current.restartOffered === true, Math.floor(at / 60_000)]);
    if (key === drawn) return;
    drawn = key;
    el.hidden = current.vendor === 'demo';
    replace(badge, view ? securityBadge(view.level) : null);
    summary.textContent = view ? view.summary : current.isEnabled ? SECURITY_TEXT.notCheckedCard : SECURITY_TEXT.turnedOff;
    aiNote.hidden = !leaving;
    aiNote.textContent = leaving ? SECURITY_TEXT.aiLeaves(leaving) : '';
    replace(checked, view?.checkedAt !== null && view?.checkedAt !== undefined ? ['Checked ', when(view.checkedAt, at), '.'] : null);
    checkButton.textContent = view ? SECURITY_TEXT.checkAgain : SECURITY_TEXT.checkNow;
    checkButton.hidden = !current.isEnabled;
    if (busy) checkButton.setAttribute('aria-disabled', 'true');
    else checkButton.removeAttribute('aria-disabled');
    el.setAttribute('aria-busy', String(busy));
    state.textContent = busy ? SECURITY_TEXT.checking : announced;
    replace(problemHost, problem ? inlineError(problem) : null);
    replace(findings, (view?.findings ?? []).map((entry) => findingItem(entry, setUp, help)));
    findings.hidden = !view?.findings.length;
    fixRow.hidden = !(setUp && view?.fixable.length);
    if (current.restartOffered !== true) restartEl = null;
    else if (!restartEl && typeof restart === 'function') restartEl = restart(current);
    if (restartHost.firstChild !== restartEl) replace(restartHost, restartEl);
    restartHost.hidden = !restartEl;
    drawGuard(view, at);
  }

  function clearProblem() {
    problem = '';
    if (problemTimer !== null) clearTimeout(problemTimer);
    problemTimer = null;
  }

  async function checkNow() {
    const target = current;
    if (destroyed || !target.isEnabled || checks.busy(target.id)) return;
    clearProblem();
    announced = '';
    const asked = now();
    const pending = checks.check(target);
    draw();
    const result = await pending;
    if (destroyed) return;
    if (result?.camera && result.camera.id === current.id) {
      current = withSecurity(current, result.camera.status.security);
      announced = SECURITY_TEXT.announced(SECURITY_TEXT.levels[result.camera.status.security.level]);
    }
    if (result?.message) {
      problem = result.message;
      problemAt = asked;
      // "Try again in a minute": the sentence goes when the wait the bridge named is over.
      if (result.retryAfter) problemTimer = setTimer(() => { problemTimer = null; if (destroyed) return; problem = ''; draw(); }, result.retryAfter * 1000);
    }
    draw();
  }

  draw();
  if (aiSettings) {
    Promise.resolve(aiSettings).then((answer) => {
      aiAway = picturesGoTo(answer?.ai);
      if (!destroyed) draw();
    }, () => { /* Settings could not be read: no line */ });
  }
  return {
    el,
    heading,
    update(next) {
      if (destroyed || !next || next.id !== current.id) return;
      current = next;
      // A result newer than the failed check (the engine's own, through the event stream) is the answer: the error no longer holds.
      const checkedAt = securityView(next)?.checkedAt;
      if (problem && checkedAt !== null && checkedAt !== undefined && checkedAt > problemAt) clearProblem();
      draw();
    },
    destroy() { destroyed = true; clearProblem(); },
  };
}
