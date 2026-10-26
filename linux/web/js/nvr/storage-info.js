// What can be said about where recordings are stored: the menus' choices, sizes in words, how fast the storage fills and how long it lasts,
// and everything the Recording card shows. Plain functions over the bridge's answers (no page needed, so they are tested on their own).
import { sizeText } from '../format.js';

export const KEEP_DAY_CHOICES = [1, 3, 7, 14, 30, 90];
export const MAX_SIZE_CHOICES_GB = [100, 250, 500, 1000, 2000, 4000, 8000];

const DAY_MS = 86_400_000;
/** One kilobit a second for a day is 10,800,000 bytes (1000 / 8 x 86,400): 4 Mbps is 43.2 GB a day. */
export const BYTES_PER_KBPS_DAY = 10_800_000;
/** The rate is measured from what is stored once at least this much time is recorded, else worked out from the cameras' bit rates. */
export const MEASURED_AFTER_MS = 3_600_000;

// MARK: Words and numbers

/** The choices of a menu, with a stored value that is not among them added in its place. */
export function withCurrent(choices, current) {
  const all = new Set(choices);
  if (Number.isFinite(current)) all.add(current);
  return [...all].sort((a, b) => a - b);
}

// "43 GB", "2.4 TB" (format.js: the archive drive's card, which loads at start-up, says sizes the same way).
export { sizeText };

export const keepLabel = (days) => (days === 1 ? '1 day' : `${days} days`);
export const sizeLabel = (gb) => (gb >= 1000 && gb % 100 === 0 ? `${gb / 1000} TB` : `${gb} GB`);

/** "about 2.4 days", rounded down so that a figure just under the number of days chosen never reads as equal to it. */
function holdsText(days) {
  if (days < 1) return 'less than a day';
  const shown = days < 10 ? Math.floor(days * 10) / 10 : Math.floor(days);
  return `about ${shown === 1 ? '1 day' : `${shown} days`}`;
}

/** The bytes a day the recordings take: measured from what is stored, else from the recording cameras' bit rates; null when neither is known. */
export function dailyRate(storage, cameras) {
  const span = storage.oldest !== null && storage.newest !== null ? storage.newest - storage.oldest : 0;
  if (span >= MEASURED_AFTER_MS && storage.usedBytes > 0) return { perDay: storage.usedBytes / (span / DAY_MS), measured: true };
  let kbps = 0;
  for (const camera of cameras) {
    if (camera.nvrEnabled === true) kbps += camera.status?.mainStreamInfo?.bitrateKbps || 0;
  }
  return kbps > 0 ? { perDay: kbps * BYTES_PER_KBPS_DAY, measured: false } : null;
}

/** "About 43 GB a day. This storage holds about 2.3 days, ..." or null when it cannot be said yet. */
export function capacityCaption(storage, rate) {
  if (!rate || storage.totalBytes === 0) return null;
  const perDay = sizeText(rate.perDay);
  const basis = rate.measured ? '' : ' (worked out from the cameras’ bit rates)';
  const holds = Math.min(storage.effectiveMaxBytes, storage.roomBytes) / rate.perDay;
  if (holds >= storage.keepDays) {
    return `About ${perDay} a day${basis}. Keeping ${keepLabel(storage.keepDays)} takes about ${sizeText(rate.perDay * storage.keepDays)}, which fits.`;
  }
  return `About ${perDay} a day${basis}. This storage holds ${holdsText(holds)}, fewer than the ${keepLabel(storage.keepDays)} you chose, so older recordings are deleted sooner.`;
}

/** The bridge's sentence for a limit that would delete recordings, without the instruction to API clients at its end. */
export function deleteSentence(message) {
  const text = String(message || '').replace(/\s*Send confirm to continue\.?\s*$/, '').trim();
  return text || 'This will delete the oldest recordings.';
}

/** "260 GB free of 460 GB · room for about 240 GB of recordings" for a row of the location dialog. */
export function describeLocation(location) {
  const parts = [];
  if (typeof location.freeBytes === 'number' && typeof location.totalBytes === 'number') parts.push(`${sizeText(location.freeBytes)} free of ${sizeText(location.totalBytes)}`);
  if (typeof location.roomBytes === 'number') parts.push(`room for about ${sizeText(location.roomBytes)} of recordings`);
  return parts.join(' · ');
}

/** Everything the Recording card says, worked out from GET nvr/storage and the cameras; the card only puts it on the page. */
export function describeStorage(storage, cameras) {
  const hasFolder = storage.location !== null;
  const stateOK = storage.state === 'ok';
  const reserved = storage.floorBytes > 0 ? `Camera Bridge keeps ${sizeText(storage.floorBytes)} free for updates and settings, and pauses recording below that.` : null;
  const chosen = storage.maxSizeGB * 1e9;
  const effective = hasFolder && storage.totalBytes > 0 && storage.effectiveMaxBytes < chosen
    ? `This drive can hold only ${sizeText(storage.effectiveMaxBytes)} of recordings, less than the ${sizeLabel(storage.maxSizeGB)} you chose, so that is the limit.`
    : null;
  return {
    hasFolder,
    problem: hasFolder && !stateOK ? (storage.message || 'Recording is paused.') : null,
    location: storage.label || 'Another folder',
    recordingCameras: storage.recordingCameras,
    used: sizeText(storage.usedBytes),
    free: storage.totalBytes > 0 ? `${sizeText(storage.freeBytes)} of ${sizeText(storage.totalBytes)}` : '—',
    usedFraction: storage.totalBytes > 0 ? Math.min(1, storage.usedBytes / storage.totalBytes) : 0,
    barLabel: storage.totalBytes > 0 ? `Recordings use ${sizeText(storage.usedBytes)} of this ${sizeText(storage.totalBytes)} drive; ${sizeText(storage.freeBytes)} is free.` : 'No measurement yet.',
    oldest: storage.oldest,
    newest: storage.newest,
    reserved,
    effective,
    caption: capacityCaption(storage, dailyRate(storage, cameras)),
  };
}

