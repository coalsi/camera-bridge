// Names and ids that must be the same as the engine's (docs/superpowers/plans/2026-10-10-nvr/T00-contracts.md, B.2: ArchiveIdentity).

const FNV_OFFSET = 0xcbf29ce484222325n;
const FNV_PRIME = 0x100000001b3n;
const MASK64 = 0xffffffffffffffffn;

/** FNV-1a, 64 bit, over the UTF-8 bytes of `text`; a BigInt. */
export function fnv1a64(text) {
  let hash = FNV_OFFSET;
  for (const byte of Buffer.from(text, 'utf8')) hash = ((hash ^ BigInt(byte)) * FNV_PRIME) & MASK64;
  return hash;
}

/** The first 12 characters of the hash's 16-digit lowercase hex (its high 48 bits) of the segment path. */
export function fileKey(segment) {
  return fnv1a64(segment).toString(16).padStart(16, '0').slice(0, 12);
}

export const fragmentId = (key, index) => `${key}.${index}`;

const FRAGMENT_ID = /^([0-9a-f]{12})\.(0|[1-9][0-9]{0,6})$/;

/** `{ fileKey, index }` for `<12 lowercase hex>.<index>` (an index of 1 to 7 digits, no leading zero); null for anything else. */
export function parseFragmentId(id) {
  const match = FRAGMENT_ID.exec(id);
  return match ? { fileKey: match[1], index: Number(match[2]) } : null;
}

/** "<camera directory>/<yyyy-MM-dd>/<HH-mm-ss>" in UTC (the box's zone), "-N" appended for the Nth file that starts in one second. */
export function segmentName(cameraDirectory, startMs, suffix = 0) {
  const iso = new Date(Math.floor(startMs / 1000) * 1000).toISOString();
  return `${cameraDirectory}/${iso.slice(0, 10)}/${iso.slice(11, 19).replaceAll(':', '-')}${suffix > 1 ? `-${suffix}` : ''}`;
}
