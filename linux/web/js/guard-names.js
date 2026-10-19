// What an internet name a camera looked up likely is, in plain words, for the names the Internet guard blocked on the Security card
// (screens/security.js). One small table of name patterns, checked in order: a time server, a check that the internet is there, a
// well-known general service (Apple, Google, Amazon, Microsoft, Cloudflare, Akamai, Fastly: never put down to the camera's maker), a
// dynamic DNS service, a firmware or app update check, the camera maker's cloud or phone-app connection (named when the name or the camera
// says which maker), else a name Camera Bridge does not recognize. It is a guess from the name alone: the guard sees which names a camera
// asks for and when, never what it would have sent or why. Pure: no DOM, so it imports in plain Node.

/** The words, in one table. */
export const GUARD_NAME_TEXT = {
  time: 'Likely a time server: the camera asks it for the time.',
  connectivity: 'Likely a check that the internet can be reached.',
  general: 'Likely a general internet service (not the camera maker’s).',
  ddns: 'Likely a dynamic DNS service, which keeps a name pointing at your home’s internet address.',
  update: (maker) => `Likely ${maker ? `${maker}’s` : 'a'} firmware or app update check.`,
  cloud: (maker) => `Likely ${maker ? `${maker}’s` : 'the camera maker’s'} cloud or phone-app connection.`,
  unknown: 'Not one Camera Bridge recognizes.',
  /** After a time server, for a camera Set up for Camera Bridge works with whose clock it has not set from the bridge yet. */
  timeHint: 'Set up for Camera Bridge can point its clock at the bridge instead.',
};

/**
 * The camera makers Camera Bridge knows by the words their names carry, the maker as shown: `words` anywhere in a part of the name (they
 * are long enough not to turn up inside other words), `exact` only as a word of its own ("tapo", never "tapology" or "metapod").
 */
export const GUARD_MAKERS = [
  { maker: 'Hikvision', words: ['hik-connect', 'hikconnect', 'hikvision', 'hik-online', 'hikcentral', 'hik-partner'] },
  { maker: 'EZVIZ', words: ['ezviz'] },
  { maker: 'Reolink', words: ['reolink'] },
  { maker: 'TP-Link', words: ['tp-link', 'tplink'], exact: ['tapo'] },
  { maker: 'Wyze', words: ['wyze'] },
  { maker: 'Meari', words: ['meari', 'cloudedge'] },
  { maker: 'Dahua', words: ['dahua', 'easy4ip', 'imoulife', 'lechange'] },
  { maker: 'Amcrest', words: ['amcrest'] },
];

/** Well-known general internet services: a name that is one of these, or under one, is theirs, whoever's camera asked. */
export const GENERAL_SERVICES = [
  'apple.com', 'icloud.com', 'apple-dns.net', 'aaplimg.com', 'mzstatic.com', 'cdn-apple.com',
  'google.com', 'googleapis.com', 'gstatic.com', 'googleusercontent.com', 'gvt1.com', 'gvt2.com', 'youtube.com',
  'amazon.com', 'amazonaws.com', 'cloudfront.net',
  'microsoft.com', 'azure.com', 'azureedge.net', 'azurewebsites.net', 'windows.com', 'windows.net', 'live.com', 'msn.com', 'bing.com',
  'cloudflare.com', 'cloudflare.net', 'cloudflare-dns.com', 'one.one.one.one',
  'akamai.net', 'akamaiedge.net', 'akamaized.net', 'akamaihd.net', 'akamaitechnologies.com', 'edgekey.net', 'edgesuite.net',
  'fastly.net', 'fastly.com', 'fastlylb.net',
];

/**
 * The kinds of name, in the order they are tried. `words` is tested against each word of the name (its parts split at dots, dashes and
 * underscores, without trailing digits: "ntp1" is "ntp"; the "*" of an id the bridge hid is no word); `names` against the whole name as
 * shown, "*" included; `domains` match the whole name or a name under one of them. A time server or a connectivity check at a general
 * service is still that (it names no maker); everything after the general services could name the camera's maker, so they come first.
 * A name of a maker above that matches none of these is the maker's cloud.
 */
export const GUARD_NAME_KINDS = [
  { kind: 'time', words: /^(?:s?ntp|time|timeserver|timesync|ntpserver)$/ },
  { kind: 'connectivity', words: /^(?:connectivitycheck|connectivity|captive|captiveportal|detectportal|connecttest|msftconnecttest|msftncsi|ncsi|nmcheck|netcheck|networkcheck)$/,
    names: /^(?:www\.)?(?:google|baidu|qq|bing|amazon|apple|msn|yahoo|163)\.com$/ },
  { kind: 'general', domains: GENERAL_SERVICES },
  { kind: 'ddns', words: /^(?:ddns|dyndns|dynu|noip|duckdns)$/ },
  { kind: 'update', words: /update|upgrade|firmware|^f?ota$/ },
  { kind: 'cloud', words: /p2p|^(?:cloud|push|relay)s?$|^(?:iot|iotc|iotcplatform|stun|turn|mqtt|xmpp|tutk|kalay|throughtek)$/ },
];

/** What the camera's own details say of its maker; nil for a name that says nothing ("ONVIF", "IPCAM"). */
const GENERIC_MAKER = /^(?:onvif|generic|general|ipcam|ip ?camera|ipc|camera|cam|unknown|none|n\/a|default|-+)$/i;
const VENDOR_MAKERS = { hikvision: 'Hikvision', reolink: 'Reolink', amcrest: 'Amcrest', doorbird: 'DoorBird' };

/** The words of `text` (lowercase): split at anything but letters and digits, without trailing digits. */
const wordsOf = (text) => text.split(/[^a-z0-9]+/).map((word) => word.replace(/\d+$/, '')).filter(Boolean);

/** The maker of the table that `text` (lowercase: a part of a name, or a manufacturer) names, or null. */
function knownMaker(text) {
  const own = wordsOf(text);
  return GUARD_MAKERS.find((entry) => entry.words.some((word) => text.includes(word)) || (entry.exact ?? []).some((word) => own.includes(word)))?.maker ?? null;
}

/** The name as shown, lowercase. */
const shownName = (name) => String(name ?? '').toLowerCase();

/** The parts of `name` (lowercase, the "*" of an id the bridge hid left out). */
function labels(name) {
  return shownName(name).split('.').filter((label) => label && label !== '*');
}

/** The words of `name`: each part split at dashes and underscores, without its trailing digits. */
function words(name) {
  return labels(name).flatMap((label) => label.split(/[-_]+/)).map((word) => word.replace(/\d+$/, '')).filter(Boolean);
}

/** The maker a name belongs to by its words (GUARD_MAKERS), or null. */
export function makerOfName(name) {
  for (const label of labels(name)) {
    const maker = knownMaker(label);
    if (maker) return maker;
  }
  return null;
}

/** The maker of `camera` as the page knows it: its manufacturer when that names one, else its type's maker; null when neither says. */
export function makerOfCamera(camera) {
  const told = typeof camera?.manufacturer === 'string' ? camera.manufacturer.trim() : '';
  const known = told ? knownMaker(told.toLowerCase()) : null;
  if (known) return known;
  if (typeof camera?.vendor === 'string' && Object.hasOwn(VENDOR_MAKERS, camera.vendor)) return VENDOR_MAKERS[camera.vendor];
  return told && told.length <= 40 && !GENERIC_MAKER.test(told) ? told : null;
}

/** The kind of `name`: 'time', 'connectivity', 'general', 'ddns', 'update', 'cloud' or 'unknown'. */
export function guardNameKind(name) {
  const all = words(name);
  const whole = shownName(name);
  for (const entry of GUARD_NAME_KINDS) {
    if (entry.words && all.some((word) => entry.words.test(word))) return entry.kind;
    if (entry.names?.test(whole)) return entry.kind;
    if (entry.domains?.some((domain) => whole === domain || whole.endsWith(`.${domain}`))) return entry.kind;
  }
  return makerOfName(name) ? 'cloud' : 'unknown';
}

/** Whether Set up for Camera Bridge already took the camera's clock to the bridge, or found it there, or could not (its last record of
 *  "Time from the bridge"). */
function clockStepTaken(camera) {
  const steps = Array.isArray(camera?.setupState?.steps) ? camera.setupState.steps : [];
  const last = steps.filter((step) => step?.id === 'timeSource').at(-1);
  return Boolean(last) && !['notRun', 'restored', 'willChange'].includes(last.status);
}

/**
 * What `name` likely is, for `camera`: { kind, maker, text, hint }. `maker` only for the maker's cloud (the maker the name names, else the
 * camera's) and for an update check whose name names its maker; a general service, a time server and the rest name none. `hint` is said
 * after a time server when `canSetUp` (Set up for Camera Bridge works with the camera here) and the setup has not taken its clock step
 * yet; else null.
 */
export function describeGuardName(name, { camera = null, canSetUp = false } = {}) {
  const kind = guardNameKind(name);
  const maker = kind === 'cloud' ? makerOfName(name) ?? makerOfCamera(camera) : kind === 'update' ? makerOfName(name) : null;
  const text = kind === 'cloud' || kind === 'update' ? GUARD_NAME_TEXT[kind](maker) : GUARD_NAME_TEXT[kind];
  const hint = kind === 'time' && canSetUp && !clockStepTaken(camera) ? GUARD_NAME_TEXT.timeHint : null;
  return { kind, maker, text, hint };
}
