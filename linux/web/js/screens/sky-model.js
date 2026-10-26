// Sky Watcher's words and numbers, with no page in them: every sentence of the camera page's card and of the sky log, the direction, speed,
// blink and shape of a light in plain words, the summary and the conditions line, the hours with more lights than were logged, the aim, the dots
// of the night's strip, the grid's kinds, filters, sorts and hours (and how they are written in the address), a path in picture coordinates, and
// the addresses. Nothing here touches the document or sends a request.
//
// One camera cannot tell how far away something is, so nothing here ever claims a real size, distance or speed: a speed is only ever "faster
// across the sky than planes at that height".

/**
 * The sky page's address (#/sky, #/sky/<camera>, with ?night=yyyy-MM-dd&view=night|day&entry=<id> and the grid's kinds=…&sort=…&pictures=1);
 * app.js routes it, sky-log.js reads it.
 */
export const SKY_ROUTE = /^sky(?:\/([0-9A-Fa-f-]{36}))?(?:\?(.*))?$/;

/** Every sentence of the card and the log that does not carry a number. The name is Sky Watcher everywhere. */
export const SKY_TEXT = {
  menu: 'Sky Watcher',
  page: 'Sky Watcher',
  card: {
    title: 'Sky Watcher',
    switchTitle: 'Watch the sky',
    switchDesc: 'For a camera that looks at the sky. Camera Bridge logs everything that crosses it — planes, satellites, meteors, bugs and birds — and tells you only about what it can’t explain. One camera can’t tell how far away something is, so it compares how things move across the sky; it never guesses a real size or speed.',
    leaves: 'It works without the internet. When the internet is there, Camera Bridge can also download satellite orbits once a day and ask free online services for flights and weather in a wide area around you, never your exact spot. Still pictures of what it can’t explain go to your AI service if you set one up. Nothing leaves the box while it’s off.',
    locationTitle: 'Where the box is',
    locationKept: 'Kept only on this box.',
    useBrowser: 'Use this browser’s location',
    finding: 'Asking this browser…',
    notShared: 'Your browser didn’t share its location. Type it in instead: latitude and longitude, with a minus sign for west.',
    latitude: 'Latitude',
    longitude: 'Longitude',
    latitudeRange: 'Latitude is a number from −90 to 90.',
    longitudeRange: 'Longitude is a number from −180 to 180.',
    needLocation: 'Set where the box is first.',
    needFolder: 'Choose a recordings folder first: the sky log is kept with the recordings.',
    folderLink: 'Settings › Recording',
    pluginLink: 'Open Plugins',
    facingTitle: 'Which way the camera faces',
    tiltTitle: 'Tilt above the horizon',
    tiltHint: 'How far above the horizon the middle of the picture points: 0–90°.',
    groundTitle: 'Ground and horizon at the bottom',
    groundHint: 'How much of the bottom of the picture is ground or horizon: 0–60 %.',
    lensTitle: 'Lens layout',
    lensSingle: 'One lens',
    lensDual: 'Two lenses side by side',
    lensHint: 'A very wide picture is usually two lenses stitched together.',
    start: 'Start watching',
    working: 'Working…',
    aimMore: 'It gets more exact by itself over a few nights.',
    looseFlights: 'Flight matching is loose until the aim is good.',
    openLog: 'Open the sky log',
    waiting: 'Starting…',
    failed: 'That didn’t work. Try again in a moment.',
  },
  settings: {
    title: 'Setup',
    gist: 'Where the box is, the flight feed and the AI limit',
    desc: 'Where the box is, where it can find flights near you, and how often it may ask the AI. They are used only while Sky Watcher is on for a camera.',
    loading: 'Loading the setup…',
    retry: 'Try again',
    feedTitle: 'Flight feed',
    feedLabel: 'Address of the feed',
    feedHint: 'An aircraft.json from dump1090, readsb, tar1090 or PiAware on your network, for example http://192.168.77.20/tar1090/data/aircraft.json. Without one, Camera Bridge asks a free online service.',
    find: 'Find a feed',
    finding: 'Looking on your network…',
    noFeeds: 'No flight feed answered on your network. Type its address in if you have one.',
    useFeed: 'Use this one',
    save: 'Save',
    saved: 'Saved.',
    saveLocation: 'Save the location',
    removeLocation: 'Remove the location',
    locationSaved: 'The location is saved on this box.',
    locationRemoved: 'The location is removed.',
    aiTitle: 'Asking the AI',
    aiLabel: 'Most questions a day',
    aiHint: 'How many times a day Sky Watcher may show your AI service a light it can’t explain: 1 to 1,000.',
    aiSetup: 'Set up the AI service in Settings',
    aiRange: 'Use a whole number from 1 to 1,000.',
    saveLimit: 'Save the limit',
    aiSaved: 'The limit is saved.',
  },
  log: {
    titlePrefix: 'Sky log · ',
    night: 'Night',
    day: 'Day',
    earlier: 'Earlier',
    later: 'Later',
    camera: 'Camera',
    nothingUnexplained: 'Nothing unexplained. Everything that crossed the sky was a plane, a satellite, a meteor, a bug or a bird.',
    nothingAtAll: 'Nothing crossed the sky in this time.',
    noMatch: 'No lights match these filters.',
    noPictures: 'None of these lights has a picture.',
    clearFilters: 'Clear filters',
    all: 'All',
    show: 'Show',
    withPicture: 'With picture',
    sort: 'Sort',
    goTo: 'Go to',
    thatWasA: 'That was a…',
    download: 'Download clip',
    noPicture: 'No picture kept',
    probable: 'probably a plane',
    yours: 'You said what this was',
    open: 'Open the recording',
    status: 'Status',
    loading: 'Loading the sky log…',
    retry: 'Try again',
    off: 'Sky Watcher is off',
    offHelp: 'Switch it on in Plugins, then turn it on for a camera that looks at the sky.',
    toPlugins: 'Go to Plugins',
    noCameraOn: 'Turn on Sky Watcher in a camera’s settings',
    pickCamera: 'Open the camera that looks at the sky and switch on “Watch the sky”.',
    noCameras: 'Add the camera that looks at the sky first.',
    addCamera: 'Add a camera',
    toCameras: 'Go to your cameras',
    removed: 'This camera was removed',
    cameraOff: 'Sky Watcher is off for this camera.',
    turnOn: 'Turn it on',
    ai: 'AI',
    larger: 'Looks larger than planes and satellites do there',
    brighter: 'Looks brighter than planes and satellites do there',
    tonight: 'Tonight so far',
    notSaved: 'That didn’t save. Try again in a moment.',
    failed: 'The sky log couldn’t be read. Try again in a moment.',
    playerFailed: 'The player couldn’t open. Try again in a moment.',
    kinds: { track: 'Moving light', newLight: 'New light', flash: 'Flash' },
    movingTogether: 'Moving together',
    showEveryLight: 'Show every light again',
    showTogether: 'Show only the lights that moved together',
    sortedLater: 'Sorted later',
    sortedLaterWhy: 'Logged before the rules; they sorted it when this night was read.',
  },
  // The clip player (sky-player.js): the recording around one light, in a modal on the sky log.
  player: {
    close: 'Close',
    details: 'About this light',
    zoom: 'Zoom to the light',
    zoomHint: 'Zoom in on the light where it is now, then drag to move or scroll to zoom',
    hideMarker: 'Hide marker',
    showMarker: 'Show marker',
    hideMarkerHint: 'Hide the ring and the path, to see the light itself (M)',
    showMarkerHint: 'Show the ring and the path again (M)',
    markerKey: 'Hide or show the marker',
    wholeKey: 'The whole picture again (double-click too)',
    escKey: 'Zoomed in: the whole picture again. Otherwise: close',
    watch: 'Watch on the Monitor',
    position: 'Where in the recording',
    light: 'The light',
    widenOne: '±1 min',
    widenFive: '±5 min',
    widenOneLabel: 'A minute more before and after',
    widenFiveLabel: 'Five minutes more before and after',
    narrow: 'Back to 15 s',
    missingTitle: 'There’s no recording of this moment',
    missingBody: 'It may have been removed to make room for newer recordings.',
    driveTitle: 'The recordings drive isn’t connected',
    driveBody: 'Connect it again to play this moment.',
    unreachableTitle: 'The recordings can’t be reached right now',
    unreachableBody: 'Try again in a moment.',
    loadingTitle: 'The recordings are loading',
    loadingBody: 'This takes a moment after the box starts.',
    unplayableTitle: 'This browser can’t play recordings',
    unplayableBody: 'Safari, or Chrome on a Mac, can play them.',
    still: 'Here’s the still picture Sky Watcher kept.',
    retry: 'Try again',
  },
};

const finite = (value) => (typeof value === 'number' && Number.isFinite(value) ? value : null);

/** A time as epoch milliseconds, which is how the bridge sends them: a number as it is, an ISO date's text read as a date; null for anything else. */
export function toMs(value) {
  if (typeof value === 'number') return Number.isFinite(value) ? value : null;
  if (typeof value === 'string' && value.trim()) {
    const ms = Date.parse(value);
    return Number.isFinite(ms) ? ms : null;
  }
  return null;
}
const asNumber = (value, fallback = 0) => finite(value) ?? fallback;
const plural = (n, one, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

// MARK: Direction, speed, blinking, shape

const COMPASS_WORDS = ['north', 'northeast', 'east', 'southeast', 'south', 'southwest', 'west', 'northwest'];

/** The eight-point compass word for an azimuth in degrees from true north, clockwise: 312 → "northwest"; '' for no number. */
export function compassWord(azimuth) {
  const value = finite(azimuth);
  if (value === null) return '';
  return COMPASS_WORDS[Math.round((((value % 360) + 360) % 360) / 45) % 8];
}

/** Where a light was: (312, 8) → "low in the northwest, 8° up", (45, 30) → "in the northeast, 30° up", (10, 75) → "high in the north, 75° up". */
export function directionText(azimuth, elevation) {
  const word = compassWord(azimuth);
  if (!word) return '';
  const height = finite(elevation);
  if (height === null) return `in the ${word}`;
  const up = Math.max(0, Math.round(height));
  const where = up < 15 ? 'low in the' : up >= 60 ? 'high in the' : 'in the';
  return `${where} ${word}, ${up}° up`;
}

/**
 * How fast a light crossed the sky against planes at that height, never in a real speed: 6.1 → "about 6× faster across the sky than planes at
 * that height", 0.9 → "about as fast across the sky as planes at that height", 0.5 → "slower across the sky than planes at that height";
 * '' when there is no comparison.
 */
export function speedText(ratio) {
  const value = finite(ratio);
  if (value === null || value <= 0) return '';
  if (value < 0.75) return 'slower across the sky than planes at that height';
  if (value < 1.25) return 'about as fast across the sky as planes at that height';
  const times = value >= 5 ? Math.round(value) : Number(value.toFixed(1));
  return `about ${times}× faster across the sky than planes at that height`;
}

/** Whether a light blinks and how often: "Blinks about once a second", "… 2 times a second", "… once every 3 seconds", "Steady (doesn’t blink)". */
export function blinkText(blinks, rate) {
  if (blinks !== true) return 'Steady (doesn’t blink)';
  const hertz = finite(rate);
  if (hertz === null || hertz <= 0) return 'Blinks';
  if (hertz >= 2 / 3) {
    const times = Math.max(1, Math.round(hertz));
    return times === 1 ? 'Blinks about once a second' : `Blinks about ${times} times a second`;
  }
  return `Blinks about once every ${Math.round(1 / hertz)} seconds`;
}

const SHAPES = { straight: 'Straight', curved: 'Curved', suddenStop: 'Stops suddenly', sharpTurn: 'Turns sharply' };

/** The shape of a light's path: "Straight", "Curved", "Stops suddenly" or "Turns sharply"; '' for one the page does not know. */
export function shapeText(shape) {
  return Object.hasOwn(SHAPES, shape) ? SHAPES[shape] : '';
}

/** How long a light was followed: "under a second", "4.2 seconds", "12 seconds", "2 minutes". */
export function durationText(seconds) {
  const value = finite(seconds);
  if (value === null || value < 0) return '';
  if (value < 1) return 'under a second';
  if (value < 10) return plural(Number(value.toFixed(1)), 'second');
  if (value < 90) return plural(Math.round(value), 'second');
  return plural(Math.round(value / 60), 'minute');
}

// MARK: The summary

/** The kinds the counts, the strip's dots and the groups share, in the order they are shown. */
export const BUCKETS = ['unexplained', 'planes', 'satellites', 'meteors', 'bugsAndBirds', 'notSure'];

/**
 * "Last night: 1 unexplained, 214 explained" (night view) or "Today: …" (day view), "1,906" with its comma. `when` replaces the first word for
 * another time, such as "Tonight so far" or "Night of Sat, Oct 24".
 */
export function summaryText(counts, view, when = null) {
  const lead = when || (view === 'day' ? 'Today' : 'Last night');
  const number = (value) => asNumber(value).toLocaleString('en-US');
  return `${lead}: ${number(counts?.unexplained)} unexplained, ${number(counts?.explained)} explained`;
}

/** The word beside a number in the counts row: 1 plane, 2 planes; 1 bug or bird, 2 bugs and birds. */
export function countLabel(bucket, n) {
  const one = n === 1;
  switch (bucket) {
    case 'unexplained': return 'unexplained';
    case 'planes': return one ? 'plane' : 'planes';
    case 'satellites': return one ? 'satellite' : 'satellites';
    case 'meteors': return one ? 'meteor' : 'meteors';
    case 'bugsAndBirds': return one ? 'bug or bird' : 'bugs and birds';
    default: return 'not sure';
  }
}

// MARK: Times (the box's clock: the zone is the bridge's, so the page says the same 3 AM wherever it is read)

const clocks = new Map();

/** { hour: '3', minute: '12', second: '08', dayPeriod: 'AM' } for `ms` in `zone` (this computer's zone when `zone` is not one). */
function clockParts(ms, zone) {
  const key = zone || '';
  if (!clocks.has(key)) {
    const make = (timeZone) => new Intl.DateTimeFormat('en-US', { timeZone, hour: 'numeric', minute: '2-digit', second: '2-digit', hourCycle: 'h12' });
    let format;
    try { format = make(zone || undefined); } catch { format = make(undefined); }
    clocks.set(key, format);
  }
  const out = {};
  for (const part of clocks.get(key).formatToParts(ms)) out[part.type] = part.value;
  return out;
}

/** "3:12 AM", or "3:12:08 AM" with `seconds`. */
export function timeText(ms, zone, { seconds = false } = {}) {
  if (!Number.isFinite(ms)) return '';
  const p = clockParts(ms, zone);
  return `${p.hour}:${p.minute}${seconds ? `:${p.second}` : ''} ${p.dayPeriod}`;
}

/** "3 AM" or "1:30 AM"; without the AM or PM when `period` is false. */
function hourText(p, period = true) {
  return `${p.hour}${p.minute === '00' ? '' : `:${p.minute}`}${period ? ` ${p.dayPeriod}` : ''}`;
}

/** The start of the clock hour that `ms` falls in, in `zone` (epoch ms): the grid's hours are the box's, as its strip's marks are. */
export function hourStart(ms, zone) {
  const p = clockParts(ms, zone);
  return ms - (Number(p.minute) * 60 + Number(p.second)) * 1000 - (((ms % 1000) + 1000) % 1000);
}

/** An hour's heading in the grid: "9 PM", "12 AM". */
export function hourLabel(ms, zone) {
  return hourText(clockParts(hourStart(ms, zone), zone));
}

const DAY_NAME = /^(\d{4})-(\d{2})-(\d{2})$/;

/** The UTC midnight of a night's name ("yyyy-MM-dd"), or null. */
function dayStart(name) {
  const found = typeof name === 'string' ? DAY_NAME.exec(name) : null;
  if (!found) return null;
  const ms = Date.UTC(Number(found[1]), Number(found[2]) - 1, Number(found[3]));
  return new Date(ms).toISOString().slice(0, 10) === name ? ms : null;
}

/** "Sat, Oct 24" for the name "2026-10-24" (a name is a calendar date, so no zone is involved); '' for a name that is not one. */
export function dayLabel(name) {
  const ms = dayStart(name);
  return ms === null ? '' : new Date(ms).toLocaleDateString('en-US', { timeZone: 'UTC', weekday: 'short', month: 'short', day: 'numeric' });
}

/** The name `days` after (or before, when negative) a night's name; null for a name that is not one. */
export function shiftDate(name, days) {
  const ms = dayStart(name);
  return ms === null ? null : new Date(ms + days * 86_400_000).toISOString().slice(0, 10);
}

/** The capped hours the bridge sent, read safely: [{ hour, count }] in the order of the hours, without what is not an hour and a count. */
function cappedHours(capped) {
  return (Array.isArray(capped) ? capped : [])
    .map((item) => ({ hour: toMs(item?.hour), count: finite(item?.count) }))
    .filter((item) => item.hour !== null && item.count !== null && item.count >= 1)
    .sort((a, b) => a.hour - b.hour);
}

/** "212 more lights weren’t logged (busy hour)", "1 more light wasn’t logged (busy hour)". */
function cappedWords(count) {
  const whole = Math.round(count);
  return `${whole === 1 ? '1 more light wasn’t' : `${whole.toLocaleString('en-US')} more lights weren’t`} logged (busy hour)`;
}

/**
 * The hours in which the box followed more lights than it logs (at most 200 an hour), each as a note in the box's hours: "4 PM: 212 more lights
 * weren’t logged (busy hour)", in the order of the hours. What is not an hour and a count says nothing.
 */
export function cappedText(capped, zone) {
  return cappedHours(capped).map(({ hour, count }) => `${hourText(clockParts(hour, zone))}: ${cappedWords(count)}`);
}

/**
 * The same notes for the grid's hour headings: the start of each clock hour in the box's zone (hourStart) -> "212 more lights weren’t logged
 * (busy hour)". Two notes of one hour (a box that restarted in it) add up.
 */
export function cappedByHour(capped, zone) {
  const counts = new Map();
  for (const { hour, count } of cappedHours(capped)) {
    const start = hourStart(hour, zone);
    counts.set(start, (counts.get(start) ?? 0) + count);
  }
  return new Map([...counts].map(([hour, count]) => [hour, cappedWords(count)]));
}

const CONDITION_WORDS = { clear: 'clear', cloudy: 'cloudy', notVisible: 'sky not visible', unknown: 'sky conditions unknown' };

/**
 * The sky's conditions as one line: "☁︎ clear until 3 AM; sky not visible 3–5 AM". Spans of one state that touch are one; the first is said
 * "until" its end, the rest as ranges; one span alone is "all night" (or "all day"); a night nothing is known of says nothing.
 */
export function conditionsText(conditions, zone, view = 'night') {
  const spans = (Array.isArray(conditions) ? conditions : [])
    .map((span) => ({ from: toMs(span?.from), to: toMs(span?.to), state: span?.state }))
    .filter((span) => span.from !== null && span.to !== null && span.to > span.from && Object.hasOwn(CONDITION_WORDS, span.state))
    .sort((a, b) => a.from - b.from);
  const merged = [];
  for (const span of spans) {
    const last = merged.at(-1);
    if (last && last.state === span.state && span.from <= last.to) last.to = Math.max(last.to, span.to);
    else merged.push({ ...span });
  }
  if (!merged.some((span) => span.state !== 'unknown')) return '';
  const range = (span) => {
    const from = clockParts(span.from, zone);
    const to = clockParts(span.to, zone);
    return `${hourText(from, from.dayPeriod !== to.dayPeriod)}–${hourText(to)}`;
  };
  const parts = merged.length === 1
    ? [`${CONDITION_WORDS[merged[0].state]} all ${view === 'day' ? 'day' : 'night'}`]
    : merged.map((span, index) => (index === 0 ? `${CONDITION_WORDS[span.state]} until ${hourText(clockParts(span.to, zone))}` : `${CONDITION_WORDS[span.state]} ${range(span)}`));
  return `☁︎ ${parts.join('; ')}`;
}

// MARK: The aim, learning and the stream

const QUALITIES = new Set(['rough', 'good', 'precise']);

/** A residual in pixels as it is said: 14.2 → "14", 1.8 → "1.8", 2 → "2". */
const pixels = (value) => (value >= 10 ? String(Math.round(value)) : String(Number(value.toFixed(1))));

/** One aim, as "precise, 214 stars matched, 1.8 px"; just "rough" while it is rough. */
function aimWords(aim) {
  const quality = QUALITIES.has(aim?.quality) ? aim.quality : 'rough';
  if (quality === 'rough') return 'rough';
  const planes = asNumber(aim.planes);
  const stars = asNumber(aim.stars);
  const byStars = quality === 'precise' || (planes === 0 && stars > 0);
  const matched = byStars ? `${plural(stars, 'star')} matched` : `${plural(planes, 'plane')} matched`;
  const residual = finite(aim.residualPixels);
  return `${quality}, ${matched}${residual === null ? '' : `, ${pixels(residual)} px`}`;
}

/** "Aim: rough", "Aim: good, 23 planes matched, 14 px", "Aim: precise, 214 stars matched, 1.8 px". */
export function aimText(aim) {
  return `Aim: ${aimWords(aim)}`;
}

/**
 * The aim as lines for the card and the log: one for a single lens, "Left lens: …" and "Right lens: …" for two. `layout` ('single' | 'dual') is
 * what the camera is set to; the lenses the box reports decide when it says nothing.
 */
export function aimLines(aim, layout = null) {
  const lenses = Array.isArray(aim?.lenses) ? aim.lenses : [];
  if (layout === 'dual' || (layout !== 'single' && lenses.length >= 2)) {
    return [`Left lens: ${aimWords(lenses[0])}`, `Right lens: ${aimWords(lenses[1])}`];
  }
  return [aimText(aim)];
}

const PLANES_NEEDED = 30;
const SATELLITES_NEEDED = 10;

/** "Still learning this sky: 12 of 30 planes matched. No alerts until then."; '' once the box is ready (or has not said). */
export function learningText(learning) {
  if (learning?.ready !== false) return '';
  const planes = asNumber(learning.planes);
  const planesNeeded = asNumber(learning.planesNeeded, PLANES_NEEDED);
  if (planes < planesNeeded) return `Still learning this sky: ${planes} of ${planesNeeded} ${planesNeeded === 1 ? 'plane' : 'planes'} matched. No alerts until then.`;
  const satellites = asNumber(learning.satellites);
  const satellitesNeeded = asNumber(learning.satellitesNeeded, SATELLITES_NEEDED);
  return `Still learning this sky: ${satellites} of ${satellitesNeeded} ${satellitesNeeded === 1 ? 'satellite' : 'satellites'} matched. No alerts until then.`;
}

/** The stream the detector watches: "Watching the main stream at 1920 px, 5 pictures a second"; '' with no status (the detector is off). */
export function streamText(sky) {
  if (!sky || typeof sky !== 'object') return '';
  if (sky.running === false) return 'Not watching right now';
  const stream = sky.stream === 'main' || sky.stream === 'sub' ? sky.stream : null;
  const width = finite(sky.analysisWidth);
  const rate = finite(sky.picturesPerSecond);
  if (!stream || width === null || rate === null || rate <= 0) return SKY_TEXT.card.waiting;
  const each = Number(rate.toFixed(1));
  return `Watching the ${stream} stream at ${Math.round(width)} px, ${each} ${each === 1 ? 'picture' : 'pictures'} a second`;
}

/**
 * The sentence for a change the bridge refused (an ApiError: "Turn on Sky Watcher in Plugins first.", "Set where the box is first.", "Choose a
 * recordings folder first: …", "Battery cameras can’t …"), else a plain one (never a script's own error text), and what is missing: 'plugin',
 * 'location', 'folder' or null.
 */
export function refusalOf(error) {
  const message = error && typeof error === 'object' && 'status' in error && typeof error.message === 'string' ? error.message.trim() : '';
  if (!message) return { text: SKY_TEXT.card.failed, needs: null };
  const field = typeof error.field === 'string' ? error.field : '';
  let needs = null;
  if (/^plugins\./i.test(field) || /^Turn on Sky Watcher in Plugins/i.test(message)) needs = 'plugin';
  else if (/location/i.test(field) || /^Set where the box is/i.test(message)) needs = 'location';
  else if (/folder/i.test(field) || /recordings folder/i.test(message)) needs = 'folder';
  return { text: message, needs };
}

// MARK: The cameras

/** The cameras that have Sky Watcher on (their own switch; the plugin being on is a separate thing, `pluginOn('sky')`). */
export function skyWatching(cameras) {
  return (Array.isArray(cameras) ? cameras : []).filter((camera) => camera?.skyDetector?.enabled === true);
}

/** The picture is as wide as two pictures side by side (2 to 1 or more): the stitched view of a camera with two lenses. */
function pictureIsWide(camera) {
  const info = camera?.status?.mainStreamInfo;
  return Number.isFinite(info?.width) && Number.isFinite(info?.height) && info.height > 0 && info.width / info.height >= 2;
}

/** The camera's lens layout: what it was set to, else two lenses for a wide stitched picture and one lens for the rest. */
export function defaultLensLayout(camera) {
  const saved = camera?.skyDetector?.lensLayout;
  if (saved === 'single' || saved === 'dual') return saved;
  return pictureIsWide(camera) ? 'dual' : 'single';
}

/** The compass buttons: N … NW with the degrees each means. */
export const COMPASS = [['N', 0, 'north'], ['NE', 45, 'northeast'], ['E', 90, 'east'], ['SE', 135, 'southeast'], ['S', 180, 'south'], ['SW', 225, 'southwest'], ['W', 270, 'west'], ['NW', 315, 'northwest']];

/** The compass button nearest a facing in degrees (0 for no number). */
export function compassIndex(facing) {
  const value = finite(facing);
  return value === null ? 0 : Math.round((((value % 360) + 360) % 360) / 45) % 8;
}

// MARK: Entries

/** The correction buttons: the value the bridge takes, and the word on the button. */
export const CORRECTIONS = [['plane', 'Plane'], ['bird', 'Bird'], ['bug', 'Bug'], ['satellite', 'Satellite'], ['meteor', 'Meteor'], ['notSure', 'Not sure']];

/** "You said: bird. Camera Bridge learns from this." */
export function correctionText(label) {
  const word = label === 'notSure' ? 'not sure' : label;
  return `You said: ${word}. Camera Bridge learns from this.`;
}

/** The kind of an entry for the counts, the dots and the groups: its display label's group, or "not sure" when the person doubted an explained one. */
export function entryBucket(entry) {
  const label = entry?.display ?? entry?.label;
  switch (label) {
    case 'plane': case 'probablePlane': return entry?.correction === 'notSure' ? 'notSure' : 'planes';
    case 'satellite': case 'probableSatellite': case 'satelliteFlare': return entry?.correction === 'notSure' ? 'notSure' : 'satellites';
    case 'meteor': return entry?.correction === 'notSure' ? 'notSure' : 'meteors';
    case 'bug': case 'bird': return entry?.correction === 'notSure' ? 'notSure' : 'bugsAndBirds';
    default: return 'unexplained';   // "unexplained", or a label this page does not know yet: shown, not hidden
  }
}

const MEASURE_NUMBERS = ['azimuth', 'elevation', 'azimuthEnd', 'elevationEnd', 'duration', 'speed', 'acceleration', 'turnRate', 'maxTurn', 'straightness', 'sizeDegrees', 'brightness', 'focus'];
const MAX_PATH = 256;
/** How interesting an unexplained light is (the bridge's guide), the most first. */
export const PRIORITIES = Object.freeze(['high', 'medium', 'low']);
const MAX_REASONS = 8;
/** The bridge's own words for a light that moved with others: the page says "1 of 3 moving together" instead. */
const TOGETHER = 'Several lights moving together';

/** An entry's id as the bridge makes them (letters, digits, - and _, at most 64): it names the entry's picture in an address. */
const ENTRY_ID = /^[A-Za-z0-9_-]{1,64}$/;
const isEntryID = (value) => typeof value === 'string' && ENTRY_ID.test(value);

/** The part of a joined light whose picture is its, read safely: { id, path }, or null (a light the log kept whole, or one with no picture). */
function readStillPart(value) {
  return value && typeof value === 'object' && isEntryID(value.id) ? { id: value.id, path: readPath(value.path) } : null;
}

/**
 * How many pieces a light was seen in, when more than one: "1 light, seen in 15 parts". The box joins the pieces of one light (a plane whose light faded
 * for a few seconds, a light crossing the seam of a camera's two lenses, one followed twice) into one entry; '' for a light seen whole.
 */
export function piecesText(entry) {
  const pieces = entry?.pieces;
  return Number.isInteger(pieces) && pieces > 1 ? `1 light, seen in ${pieces.toLocaleString('en-US')} parts` : '';
}

/** The points of a path as { t, x, y }, from objects or [t, x, y] triples; what is not numbers is left out. */
function readPath(path) {
  const points = [];
  for (const point of Array.isArray(path) ? path : []) {
    const [t, x, y] = Array.isArray(point) ? point : [point?.t, point?.x, point?.y];
    if (finite(t) !== null && finite(x) !== null && finite(y) !== null) points.push({ t, x, y });
    if (points.length >= MAX_PATH) break;
  }
  return points;
}

/**
 * An entry as the bridge sent it, read safely: numbers are numbers, lists are lists, the display label and the Watch time are filled in. A light the box
 * joined from pieces has `pieces` (1 for one seen whole), `parts` (the ids of the lights the log kept that it was joined from) and `stillPart` (the part
 * whose picture is its: { id, path }; null for a light the log kept whole, or one with no picture).
 */
export function normalizeEntry(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const id = typeof raw.id === 'string' && raw.id ? raw.id : null;
  const start = toMs(raw.start);
  if (id === null || start === null) return null;
  const label = typeof raw.label === 'string' && raw.label ? raw.label : 'unexplained';
  const measures = {};
  for (const name of MEASURE_NUMBERS) if (finite(raw.measures?.[name]) !== null) measures[name] = raw.measures[name];
  measures.blinks = raw.measures?.blinks === true;
  measures.blinkRate = finite(raw.measures?.blinkRate);
  measures.shape = typeof raw.measures?.shape === 'string' ? raw.measures.shape : null;
  const sentence = typeof raw.ai?.sentence === 'string' ? raw.ai.sentence.trim() : '';
  return {
    id,
    camera: typeof raw.camera === 'string' ? raw.camera : null,
    kind: typeof raw.kind === 'string' && raw.kind ? raw.kind : 'track',
    start,
    end: Math.max(start, toMs(raw.end) ?? start),
    path: readPath(raw.path),
    measures,
    label,
    display: typeof raw.display === 'string' && raw.display ? raw.display : label,
    by: typeof raw.by === 'string' ? raw.by : null,
    detail: typeof raw.detail === 'string' && raw.detail.trim() ? raw.detail.trim() : null,
    unusual: Array.isArray(raw.unusual) ? raw.unusual.filter((reason) => typeof reason === 'string') : [],
    speedVsPlanes: finite(raw.speedVsPlanes),
    candidate: raw.candidate === true,
    alerted: raw.alerted === true,
    hasStill: raw.hasStill === true,
    ai: sentence ? { kind: typeof raw.ai.kind === 'string' ? raw.ai.kind : null, sentence, model: typeof raw.ai.model === 'string' ? raw.ai.model : null, at: toMs(raw.ai.at) } : null,
    correction: typeof raw.correction === 'string' && raw.correction ? raw.correction : null,
    watch: toMs(raw.watch) ?? start - 3000,
    priority: PRIORITIES.includes(raw.priority) ? raw.priority : null,
    reasons: (Array.isArray(raw.reasons) ? raw.reasons : []).filter((reason) => typeof reason === 'string' && reason.trim()).map((reason) => reason.trim()).slice(0, MAX_REASONS),
    group: typeof raw.group === 'string' && raw.group ? raw.group : null,
    doubtful: raw.doubtful === true,
    // Logged before the rules, and sorted by them as the bridge read the night (its label, by, detail and the guide's fields are theirs).
    sortedLater: raw.sortedLater === true,
    pieces: Number.isInteger(raw.pieces) && raw.pieces >= 1 ? raw.pieces : 1,
    parts: (Array.isArray(raw.parts) ? raw.parts : []).filter(isEntryID),
    stillPart: readStillPart(raw.stillPart),
  };
}

/** An unexplained light's priority ('high', 'medium', 'low'): null for an explained one (the person's word included) and one logged before the guide. */
export function priorityOf(entry) {
  return entryBucket(entry) === 'unexplained' && PRIORITIES.includes(entry?.priority) ? entry.priority : null;
}

/** The badge's word: "High", "Medium", "Low". */
export function priorityWord(priority) {
  return { high: 'High', medium: 'Medium', low: 'Low' }[priority] ?? '';
}

/** The lights that moved together, by group: Map(group -> the ids of its lights, by the time they began). Only unexplained ones count. */
export function groupsOf(entries) {
  const groups = new Map();
  const list = (Array.isArray(entries) ? entries : []).filter((entry) => entry?.group && entryBucket(entry) === 'unexplained');
  for (const entry of [...list].sort((a, b) => a.start - b.start || (a.id < b.id ? -1 : 1))) {
    if (!groups.has(entry.group)) groups.set(entry.group, []);
    groups.get(entry.group).push(entry.id);
  }
  for (const [group, ids] of groups) if (ids.length < 2) groups.delete(group);
  return groups;
}

/** "1 of 3 moving together": which of its group a light is; '' for one in none. */
export function groupText(entry, groups) {
  const ids = entry?.group ? groups?.get(entry.group) : null;
  const at = ids ? ids.indexOf(entry.id) : -1;
  return at >= 0 ? `${at + 1} of ${ids.length} moving together` : '';
}

/** An unexplained light's reasons as the page shows them (its group's words for its own), the most telling first; none for an explained one. */
export function reasonsOf(entry, groups) {
  if (entryBucket(entry) !== 'unexplained') return [];
  const together = groupText(entry, groups);
  return (entry?.reasons ?? []).map((reason) => (reason === TOGETHER ? together : reason)).filter(Boolean);
}

/** The counts of a list of entries, as the bridge counts them (used when it sends none): "explained" is every entry that is not unexplained. */
export function countEntries(entries) {
  const counts = { unexplained: 0, planes: 0, satellites: 0, meteors: 0, bugsAndBirds: 0, notSure: 0, explained: 0 };
  for (const entry of Array.isArray(entries) ? entries : []) {
    const bucket = entryBucket(entry);
    counts[bucket] += 1;
    if (bucket !== 'unexplained') counts.explained += 1;
  }
  return counts;
}

/** The counts after one entry changed kind (a correction): that entry moves between two counts; "explained" changes only when it was or became unexplained. */
export function countsAfter(counts, before, after) {
  if (!counts || typeof counts !== 'object') return null;
  const from = entryBucket(before);
  const to = entryBucket(after);
  const next = { ...counts };
  if (from === to) return next;
  next[from] = Math.max(0, asNumber(next[from]) - 1);
  next[to] = asNumber(next[to]) + 1;
  if (from === 'unexplained') next.explained = asNumber(next.explained) + 1;
  if (to === 'unexplained') next.explained = Math.max(0, asNumber(next.explained) - 1);
  return next;
}

// MARK: The strip and the groups

/** A dot for each entry: x by time across the window (0 to 1), y by height (0 the top of the sky, 1 the horizon), its kind, and whether it is unexplained. */
export function stripDots(entries, from, to) {
  if (!Array.isArray(entries) || !(to > from)) return [];
  return entries.filter((entry) => entry && finite(entry.start) !== null).map((entry) => {
    const rising = finite(entry.measures?.elevation);
    const setting = finite(entry.measures?.elevationEnd);
    const height = rising === null ? setting : setting === null ? rising : (rising + setting) / 2;
    const kind = entryBucket(entry);
    return {
      id: entry.id,
      x: Math.min(1, Math.max(0, (entry.start - from) / (to - from))),
      y: height === null ? 1 : 1 - Math.min(90, Math.max(0, height)) / 90,
      kind,
      unexplained: kind === 'unexplained',
    };
  });
}

/** The strip's hour marks, { x, label }, on the zone's own hours: every hour to 8 hours across, every two to 18, else every three; none near the ends. */
export function stripTicks(from, to, zone) {
  const span = to - from;
  if (!(span >= 3_600_000)) return [];
  const step = span > 18 * 3_600_000 ? 3 : span > 8 * 3_600_000 ? 2 : 1;
  const first = from + ((60 - Number(clockParts(from, zone).minute)) % 60) * 60_000;
  const ticks = [];
  for (let at = first; at < to; at += 3_600_000) {
    const p = clockParts(at, zone);
    if (p.minute !== '00') continue;
    const hour24 = (Number(p.hour) % 12) + (p.dayPeriod === 'PM' ? 12 : 0);
    const x = (at - from) / span;
    if (hour24 % step === 0 && x >= 0.14 && x <= 0.86) ticks.push({ x, label: `${p.hour} ${p.dayPeriod}` });
  }
  return ticks;
}

// MARK: The grid: kinds, filters, sorts and hours

/**
 * The kind chips over the grid, in order: the name the address uses, and the words on the chip. Planes include the probable ones, satellites
 * their flares, and "Bugs & birds" both (entryBucket); an explained light the person was not sure of is under none of them. "Corrected by you"
 * is every entry the person said something about.
 */
export const GRID_KINDS = Object.freeze([['unexplained', 'Unexplained'], ['high', 'High priority'], ['planes', 'Planes'], ['satellites', 'Satellites'], ['meteors', 'Meteors'],
  ['bugs', 'Bugs & birds'], ['corrected', 'Corrected by you']]);
const KIND_NAMES = GRID_KINDS.map(([name]) => name);
const CHIP_OF_BUCKET = { unexplained: 'unexplained', planes: 'planes', satellites: 'satellites', meteors: 'meteors', bugsAndBirds: 'bugs' };

/** The grid's orders: the name the address uses, and the words in the menu. */
export const GRID_SORTS = Object.freeze([['newest', 'Newest first'], ['oldest', 'Oldest first'], ['priority', 'Priority'], ['longest', 'Longest'], ['fastest', 'Fastest across the sky']]);
const SORT_NAMES = new Set(GRID_SORTS.map(([name]) => name));

/** Whether an order is by time (the grid then has its hours' headings), rather than by how long or how fast. */
export const isTimeSort = (sort) => sort === 'newest' || sort === 'oldest';

/** The kind chip an entry is under: 'unexplained', 'planes', 'satellites', 'meteors' or 'bugs'; null for an explained light the person doubted. */
export function kindChip(entry) {
  return CHIP_OF_BUCKET[entryBucket(entry)] ?? null;
}

const KIND_WORDS = { unexplained: 'Unexplained', plane: 'Plane', probablePlane: 'Probably a plane', satellite: 'Satellite', probableSatellite: 'Probable satellite',
  satelliteFlare: 'Satellite flare', meteor: 'Meteor', bug: 'Bug', bird: 'Bird' };

/** What an entry is, in a word or three, for its card: "Unexplained", "Plane", "Probably a plane", "Satellite flare", "Bird", "Not sure", … */
export function kindWord(entry) {
  const bucket = entryBucket(entry);
  if (bucket === 'unexplained') return KIND_WORDS.unexplained;
  if (bucket === 'notSure') return 'Not sure';
  return KIND_WORDS[entry?.display ?? entry?.label] ?? KIND_WORDS.unexplained;
}

/**
 * Whether the grid shows an entry: it is under one of the chips that are on (none on: every entry; several: any of them; High priority: an
 * unexplained light the guide ranked high), it has a still when `pictures` is on, and it is one of the lights of `group` when one is named.
 */
export function matchesFilters(entry, { kinds = [], pictures = false, group = null } = {}) {
  if (!entry || (pictures && entry.hasStill !== true)) return false;
  if (group && (entry.group !== group || entryBucket(entry) !== 'unexplained')) return false;
  if (!kinds.length) return true;
  return kinds.some((kind) => (kind === 'corrected' ? Boolean(entry.correction) : kind === 'high' ? priorityOf(entry) === 'high' : kindChip(entry) === kind));
}

/** The number on each chip, for a night: { all, unexplained, high, planes, satellites, meteors, bugs, corrected }. */
export function chipCounts(entries) {
  const counts = { all: 0, unexplained: 0, high: 0, planes: 0, satellites: 0, meteors: 0, bugs: 0, corrected: 0 };
  for (const entry of Array.isArray(entries) ? entries : []) {
    if (!entry) continue;
    counts.all += 1;
    const chip = kindChip(entry);
    if (chip) counts[chip] += 1;
    if (priorityOf(entry) === 'high') counts.high += 1;
    if (entry.correction) counts.corrected += 1;
  }
  return counts;
}

/** How long a light was followed, in seconds: its own measure, else from its start to its end. */
export function lastedSeconds(entry) {
  const measured = finite(entry?.measures?.duration);
  if (measured !== null && measured >= 0) return measured;
  return Math.max(0, ((finite(entry?.end) ?? 0) - (finite(entry?.start) ?? 0)) / 1000);
}

/**
 * The entries in an order (a new list): by time, oldest or newest first; by priority (high, medium, low, then the lights without one, each the
 * newest first); the longest first; or the fastest across the sky first, by `measures.speed` (degrees of sky a second), those without one last.
 * Ties go by time.
 */
export function sortEntries(entries, sort) {
  const list = (Array.isArray(entries) ? entries : []).filter(Boolean);
  const byTime = (a, b) => a.start - b.start || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
  if (sort === 'newest') return list.sort((a, b) => byTime(b, a));
  if (sort === 'priority') {
    const rank = (entry) => { const at = PRIORITIES.indexOf(priorityOf(entry)); return at < 0 ? PRIORITIES.length : at; };
    return list.sort((a, b) => rank(a) - rank(b) || byTime(b, a));
  }
  if (sort === 'longest') return list.sort((a, b) => lastedSeconds(b) - lastedSeconds(a) || byTime(a, b));
  if (sort === 'fastest') {
    const speed = (entry) => finite(entry.measures?.speed);
    return list.sort((a, b) => {
      const x = speed(a);
      const y = speed(b);
      if (x === null || y === null) return Number(x === null) - Number(y === null) || byTime(a, b);
      return y - x || byTime(a, b);
    });
  }
  return list.sort(byTime);
}

/**
 * The order a night opens in when the person has not chosen one: inside Unexplained (or High priority) the priority, when the night's lights
 * have one (`ranked`; a night logged before the guide has none); else the newest first while it is still going, and the oldest first (from
 * dusk) after.
 */
export function defaultSort(window, now, kinds = [], ranked = true) {
  if (ranked && Array.isArray(kinds) && kinds.length && kinds.every((kind) => kind === 'unexplained' || kind === 'high')) return 'priority';
  const from = finite(window?.from);
  const to = finite(window?.to);
  return from !== null && to !== null && from <= now && now < to ? 'newest' : 'oldest';
}

const orderKinds = (kinds) => KIND_NAMES.filter((name) => kinds.includes(name));

/** What the filters and the order are, read safely (from the address or a browser's memory): { kinds, sort (null: not chosen), pictures }. */
export function gridChoice(value) {
  const kinds = Array.isArray(value?.kinds) ? orderKinds(value.kinds) : [];
  return { kinds, sort: SORT_NAMES.has(value?.sort) ? value.sort : null, pictures: value?.pictures === true };
}

/**
 * The grid's part of the address, `kinds=unexplained,planes&sort=fastest&pictures=1`, read: { kinds, sort, pictures, given }; `given` says
 * whether the address said anything about them (else the browser's memory is used). What is not a kind or an order is left out.
 */
export function readGridQuery(query) {
  const found = query instanceof URLSearchParams ? query : new URLSearchParams(typeof query === 'string' ? query : '');
  const kinds = (found.get('kinds') ?? '').split(',').map((name) => name.trim());
  return { ...gridChoice({ kinds, sort: found.get('sort'), pictures: found.get('pictures') === '1' }), given: ['kinds', 'sort', 'pictures'].some((name) => found.has(name)) };
}

/** The lights the address narrows the grid to (`group=g-…`: those that moved together), read safely; null for none. */
export function readGroupQuery(query) {
  const found = query instanceof URLSearchParams ? query : new URLSearchParams(typeof query === 'string' ? query : '');
  const group = found.get('group');
  return group && /^g-[A-Za-z0-9_-]{1,72}$/.test(group) ? group : null;
}

/** The grid's part of the address for a choice: ['kinds=unexplained,planes', 'sort=fastest', 'pictures=1'], or [] for every kind in the night's own order. */
export function gridQuery(choice) {
  const { kinds, sort, pictures } = gridChoice(choice);
  return [kinds.length ? `kinds=${kinds.join(',')}` : null, sort ? `sort=${sort}` : null, pictures ? 'pictures=1' : null].filter(Boolean);
}

/**
 * Entries (in the order given, which is by time) in the clock hours they began in, in the box's zone: [{ hour, label, entries }] in the order the
 * hours come. The fall's repeated hour is two hours, each with its own start.
 */
export function hourGroups(entries, zone) {
  const groups = [];
  let group = null;
  for (const entry of Array.isArray(entries) ? entries : []) {
    // A clock hour is an hour long in every zone, so a light within the last one's hour is in it: the zone is asked once an hour, not once a light.
    if (!(group && entry.start >= group.hour && entry.start < group.hour + 3_600_000)) {
      const hour = hourStart(entry.start, zone);
      group = groups.find((known) => known.hour === hour) ?? null;
      if (!group) {
        group = { hour, label: hourText(clockParts(hour, zone)), entries: [] };
        groups.push(group);
      }
    }
    group.entries.push(entry);
  }
  return groups;
}

const SHAPE_WORDS = { straight: 'straight', curved: 'curved', suddenStop: 'stops suddenly', sharpTurn: 'turns sharply' };
const POINT_WORDS = { newLight: 'new light', flash: 'flash' };

/**
 * An unexplained light's line on its card: where it was, then that it blinked or the shape of its path (a light that did not move: what it was):
 * "Northwest, 8° up · blinks", "North, 24° up · new light", "East, 30° up · stops suddenly". With `how` false, only where: "Southwest, 40° up".
 */
export function shortLine(entry, { how = true } = {}) {
  const m = entry?.measures ?? {};
  const word = compassWord(m.azimuth);
  const up = finite(m.elevation);
  const where = word ? `${word[0].toUpperCase()}${word.slice(1)}${up === null ? '' : `, ${Math.max(0, Math.round(up))}° up`}` : '';
  if (!how) return where;
  const what = m.blinks === true ? 'blinks' : entry?.kind === 'track' || !entry?.kind ? SHAPE_WORDS[m.shape] ?? '' : POINT_WORDS[entry.kind] ?? '';
  return [where, what].filter(Boolean).join(' · ');
}

/**
 * A card's line under its time: an unexplained light's first reason (its group, "1 of 3 moving together", for one that moved with others), or,
 * logged before the guide, its shortLine; else what the box matched it to (a flight, a satellite's name, the rule), or where it was.
 */
export function cardLine(entry, groups = null) {
  if (entryBucket(entry) === 'unexplained') return reasonsOf(entry, groups)[0] ?? shortLine(entry);
  return entry?.detail || shortLine(entry, { how: false });
}

/** How long a light lasted, for the corner of its card: "<1 s", "4.2 s", "12 s", "2 min". */
export function durationShort(seconds) {
  const value = finite(seconds);
  if (value === null || value < 0) return '';
  if (value < 1) return '<1 s';
  if (value < 10) return `${Number(value.toFixed(1))} s`;
  if (value < 90) return `${Math.round(value)} s`;
  return `${Math.round(value / 60)} min`;
}

// MARK: The path, the links

const MAX_DRAWN = 64;
const round2 = (value) => String(Math.round(value * 100) / 100);

/** A path in picture coordinates for an SVG polyline over a still of `width` × `height`: "40,35.4 120,44.25". At most 64 points are drawn. */
export function pathPoints(path, width, height) {
  if (!(width > 0 && height > 0)) return '';
  const points = readPath(path);
  const drawn = points.length <= MAX_DRAWN ? points : Array.from({ length: MAX_DRAWN }, (_, i) => points[Math.round((i * (points.length - 1)) / (MAX_DRAWN - 1))]);
  return drawn.map((point) => `${round2(point.x * width)},${round2(point.y * height)}`).join(' ');
}

/** The close-up's shape and its smallest size, in the still's own pixels (a still is the whole picture, 1920 wide), and its padding. */
export const CLOSE_UP = Object.freeze({ aspect: 16 / 9, minWidth: 160, minHeight: 90, pad: 0.5 });

/**
 * The close-up of a still of `width` × `height`: the rectangle of the picture, in its own pixels, around the light's path. The path's box with
 * half its size more on every side, at least 160 × 90, of the close-up's 16:9 shape, as big as the picture at most, and inside it (moved in
 * from an edge or a corner, never cut). A single point is a box of no size: the smallest close-up, centred on it. -> { x, y, width, height },
 * or null when there is no close-up to give: no picture size yet, no point, or a light that crossed more of the sky than a close-up holds (the
 * whole picture is its view).
 */
export function closeUpRect(path, width, height, { aspect = CLOSE_UP.aspect, minWidth = CLOSE_UP.minWidth, minHeight = CLOSE_UP.minHeight, pad = CLOSE_UP.pad } = {}) {
  if (!(width > 0 && height > 0)) return null;
  const points = readPath(path);
  if (!points.length) return null;
  const xs = points.map((point) => Math.min(1, Math.max(0, point.x)) * width);
  const ys = points.map((point) => Math.min(1, Math.max(0, point.y)) * height);
  const left = Math.min(...xs);
  const right = Math.max(...xs);
  const top = Math.min(...ys);
  const bottom = Math.max(...ys);
  let w = Math.max((right - left) * (1 + 2 * pad), minWidth);
  let h = Math.max((bottom - top) * (1 + 2 * pad), minHeight);
  if (w / h > aspect) h = w / aspect;
  else w = h * aspect;
  const fit = Math.min(1, width / w, height / h);   // no bigger than the picture, in the same shape
  w *= fit;
  h *= fit;
  if (right - left > w + 0.01 || bottom - top > h + 0.01) return null;
  const x = Math.min(Math.max((left + right) / 2 - w / 2, 0), width - w);
  const y = Math.min(Math.max((top + bottom) / 2 - h / 2, 0), height - h);
  return { x: Number(round2(x)), y: Number(round2(y)), width: Number(round2(w)), height: Number(round2(h)) };
}

// MARK: The thumbnail

/** How wide a card's thumbnail is at most, in pixels: what the box makes for `GET …/still?size=thumb`. */
export const THUMB_WIDTH = 480;

/**
 * The part of a still of `width` × `height` that the box cuts for a card's thumbnail: the close-up (closeUpRect) in whole pixels, moved in
 * from an edge rather than cut by rounding. The box has the same rule in Swift (SkyCloseUp.swift, tested against this one case by case:
 * linux/web-tests/support/sky-closeup-vectors.mjs), so the path drawn over the thumbnail lies where the light was. null when the light has no
 * close-up (the thumbnail is then all of the picture).
 */
export function thumbRect(path, width, height, options) {
  const rect = closeUpRect(path, width, height, options);
  if (!rect) return null;
  const w = Math.min(width, Math.max(1, Math.round(rect.width)));
  const h = Math.min(height, Math.max(1, Math.round(rect.height)));
  return { x: Math.min(Math.max(0, Math.round(rect.x)), width - w), y: Math.min(Math.max(0, Math.round(rect.y)), height - h), width: w, height: h };
}

/** Whether two shapes (width over height) are the same to a pixel or two. */
const sameShape = (a, b) => Math.abs(a - b) <= 0.03 * b;

/**
 * What a card's picture is, from its size once it has arrived, when a thumbnail was asked for. `natural` is { width, height } of the image, `picture`
 * the size of the still it was cut from ({ width, height }, or null when the night did not say) and `path` the light's. One of:
 *   { mode: 'crop', rect, picture }   the close-up the box cut (rect: its place in the still, whole pixels): it fills the card, and the path is drawn in rect
 *   { mode: 'whole', picture }        all of the picture, at its own size or smaller (the thumbnail of a light that crossed the sky, or the full still the
 *                                     box answers with when it cannot make a thumbnail): `picture` is the size the path is drawn in
 *   null                              neither (the picture changed shape since the night began, or there is no size to tell): ask for the full still
 */
export function thumbGeometry(path, natural, picture) {
  const width = natural?.width;
  const height = natural?.height;
  if (!(width > 0 && height > 0)) return null;
  if (width > THUMB_WIDTH) return { mode: 'whole', picture: { width, height } };   // bigger than the box makes a thumbnail: the full still, its own size is the truth
  if (!(picture?.width > 0 && picture?.height > 0)) return null;
  const rect = thumbRect(path, picture.width, picture.height);
  if (rect && width <= rect.width + 1 && sameShape(width / height, rect.width / rect.height)) return { mode: 'crop', rect, picture };
  if (sameShape(width / height, picture.width / picture.height)) return { mode: 'whole', picture };
  return null;
}

/** The Watch screen at the entry's moment, three seconds early (the box says which millisecond). */
export function watchAddress(cameraID, entry) {
  return `#/camera/${cameraID}/watch/${Math.round(entry.watch ?? entry.start - 3000)}`;
}

/** The recording from three seconds before the entry to three seconds after it, as one download. */
export function clipAddress(cameraID, entry, zone) {
  return `/api/v1/nvr/cameras/${encodeURIComponent(cameraID)}/clip?from=${Math.round(entry.start - 3000)}&to=${Math.round(entry.end + 3000)}&tz=${encodeURIComponent(zone || 'UTC')}&part=1`;
}
