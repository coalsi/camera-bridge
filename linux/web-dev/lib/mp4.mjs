// A small ISO base media file reader for the dev tools: boxes, the init segment's facts (codec string, size, timescale) and the
// index of a fragmented file's fragments. Dependency free. It reads only what the recorder's files and ffmpeg's fragmented output
// have in common; anything it does not understand throws Mp4Error, it never returns a guess.

export class Mp4Error extends Error {
  constructor(message) {
    super(message);
    this.name = 'Mp4Error';
  }
}

/** Runs a reader; a read past the end of the bytes (a RangeError from Buffer) is an Mp4Error like any other malformed input. */
const checked = (read) => (...args) => {
  try {
    return read(...args);
  } catch (error) {
    if (error instanceof RangeError) throw new Mp4Error(`the bytes are cut off (${error.code ?? error.message})`);
    throw error;
  }
};

const u16 = (b, o) => b.readUInt16BE(o);
const u32 = (b, o) => b.readUInt32BE(o);
const u64 = (b, o) => Number(b.readBigUInt64BE(o));
const fourcc = (b, o) => b.toString('latin1', o, o + 4);

/**
 * The boxes in buf[start, end): { type, start, size, bodyStart, end }. A size of 0 runs to `end`, a size of 1 is followed by a 64-bit size.
 * A box that is smaller than its header or runs past `end` throws.
 */
export function readBoxes(buf, start = 0, end = buf.length) {
  const result = [];
  let offset = start;
  while (offset < end) {
    if (end - offset < 8) throw new Mp4Error(`a box header is cut off at ${offset}`);
    let size = u32(buf, offset);
    const type = fourcc(buf, offset + 4);
    let header = 8;
    if (size === 1) {
      if (end - offset < 16) throw new Mp4Error(`the 64-bit size of '${type}' is cut off at ${offset}`);
      size = u64(buf, offset + 8);
      header = 16;
    } else if (size === 0) {
      size = end - offset;
    }
    if (size < header || offset + size > end) throw new Mp4Error(`box '${type}' at ${offset} has the size ${size}, which does not fit`);
    result.push({ type, start: offset, size, bodyStart: offset + header, end: offset + size });
    offset += size;
  }
  return result;
}

export const child = (buf, box, type) => readBoxes(buf, box.bodyStart, box.end).find((b) => b.type === type) || null;
export const children = (buf, box, type) => readBoxes(buf, box.bodyStart, box.end).filter((b) => b.type === type);

function need(box, what) {
  if (!box) throw new Mp4Error(`the file has no ${what}`);
  return box;
}

/** `avc1.4d0032`: the profile, the constraint flags and the level of an avcC record (the string ffprobe calls mime_codec_string). */
export function avcCodecString(avcC) {
  return `avc1.${[avcC[1], avcC[2], avcC[3]].map((n) => n.toString(16).padStart(2, '0')).join('')}`;
}

/** `hvc1.1.6.L93.B0`: ISO 14496-15 annex E, from an hvcC record. */
export function hevcCodecString(hvcC, fourccName = 'hvc1') {
  const profileSpace = ['', 'A', 'B', 'C'][hvcC[1] >> 6];
  const tier = (hvcC[1] >> 5) & 1 ? 'H' : 'L';
  const profile = hvcC[1] & 0x1f;
  let compatibility = u32(hvcC, 2);
  let reversed = 0;
  for (let i = 0; i < 32; i += 1) {
    reversed = ((reversed << 1) | (compatibility & 1)) >>> 0;
    compatibility >>>= 1;
  }
  const constraints = [...hvcC.subarray(6, 12)];
  while (constraints.length > 1 && constraints[constraints.length - 1] === 0) constraints.pop();
  return [fourccName, `${profileSpace}${profile}`, reversed.toString(16), `${tier}${hvcC[12]}`, ...constraints.map((n) => n.toString(16).toUpperCase())].join('.');
}

/**
 * Reads the init segment `buf` (ftyp + moov): the single video track's codec, size, timescale and the defaults a fragment falls back to.
 * Throws when there is no video track; `hasAudio` says whether the file has a second, audio track.
 */
function parseInitUnchecked(buf) {
  const top = readBoxes(buf);
  const moov = need(top.find((b) => b.type === 'moov'), 'moov');
  let video = null;
  let hasAudio = false;
  for (const trak of children(buf, moov, 'trak')) {
    const mdia = need(child(buf, trak, 'mdia'), 'mdia');
    const handler = fourcc(buf, need(child(buf, mdia, 'hdlr'), 'hdlr').bodyStart + 8);
    if (handler === 'soun') hasAudio = true;
    if (handler !== 'vide' || video) continue;
    const tkhd = need(child(buf, trak, 'tkhd'), 'tkhd');
    const mdhd = need(child(buf, mdia, 'mdhd'), 'mdhd');
    const timescale = u32(buf, mdhd.bodyStart + (buf[mdhd.bodyStart] === 1 ? 20 : 12));
    const stsd = need(child(buf, need(child(buf, need(child(buf, mdia, 'minf'), 'minf'), 'stbl'), 'stbl'), 'stsd'), 'stsd');
    const entry = readBoxes(buf, stsd.bodyStart + 8, stsd.end)[0];
    if (!entry) throw new Mp4Error('the video track has no sample entry');
    const width = u16(buf, entry.bodyStart + 24);
    const height = u16(buf, entry.bodyStart + 26);
    const config = readBoxes(buf, entry.bodyStart + 78, entry.end);
    const avcC = config.find((b) => b.type === 'avcC');
    const hvcC = config.find((b) => b.type === 'hvcC');
    let mime;
    if (avcC) mime = avcCodecString(buf.subarray(avcC.bodyStart, avcC.end));
    else if (hvcC) mime = hevcCodecString(buf.subarray(hvcC.bodyStart, hvcC.end), entry.type === 'hev1' ? 'hev1' : 'hvc1');
    else throw new Mp4Error(`the sample entry '${entry.type}' has no avcC or hvcC`);
    video = { trackId: u32(buf, tkhd.bodyStart + (buf[tkhd.bodyStart] === 1 ? 20 : 12)), timescale, width, height, codec: mime, mime: `video/mp4; codecs="${mime}"` };
  }
  if (!video) throw new Mp4Error('the file has no video track');
  const trex = child(buf, need(child(buf, moov, 'mvex'), 'mvex'), 'trex');
  const defaults = trex
    ? { duration: u32(buf, trex.bodyStart + 8), size: u32(buf, trex.bodyStart + 12), flags: u32(buf, trex.bodyStart + 16) }
    : { duration: 0, size: 0, flags: 0 };
  return { ...video, hasAudio, defaults, initLength: moov.end };
}

/**
 * One fragment: where its moof and mdat are, its first media time, how long it is, whether it starts with a keyframe and how many
 * samples it has. `tfdtOffset` is where the 32- or 64-bit base media decode time sits, for patchBaseDecodeTime.
 */
function parseFragmentUnchecked(buf, moof, mdat, defaults) {
  const traf = need(child(buf, moof, 'traf'), 'traf');
  const tfhd = need(child(buf, traf, 'tfhd'), 'tfhd');
  const tfhdFlags = u32(buf, tfhd.bodyStart) & 0xffffff;
  let cursor = tfhd.bodyStart + 8;
  if (tfhdFlags & 0x1) cursor += 8;
  if (tfhdFlags & 0x2) cursor += 4;
  const defaultDuration = tfhdFlags & 0x8 ? u32(buf, (cursor += 4) - 4) : defaults.duration;
  const defaultSize = tfhdFlags & 0x10 ? u32(buf, (cursor += 4) - 4) : defaults.size;
  const defaultFlags = tfhdFlags & 0x20 ? u32(buf, (cursor += 4) - 4) : defaults.flags;
  const tfdt = need(child(buf, traf, 'tfdt'), 'tfdt');
  const tfdtVersion = buf[tfdt.bodyStart];
  const baseDecodeTime = tfdtVersion === 1 ? u64(buf, tfdt.bodyStart + 4) : u32(buf, tfdt.bodyStart + 4);
  let samples = 0;
  let duration = 0;
  let firstFlags = null;
  let firstSize = 0;
  for (const trun of children(buf, traf, 'trun')) {
    const flags = u32(buf, trun.bodyStart) & 0xffffff;
    const count = u32(buf, trun.bodyStart + 4);
    let at = trun.bodyStart + 8;
    if (flags & 0x1) at += 4;
    let first = null;
    if (flags & 0x4) {
      first = u32(buf, at);
      at += 4;
    }
    const stride = (flags & 0x100 ? 4 : 0) + (flags & 0x200 ? 4 : 0) + (flags & 0x400 ? 4 : 0) + (flags & 0x800 ? 4 : 0);
    if (at + count * stride > trun.end) throw new Mp4Error('a trun is shorter than its sample count');
    for (let i = 0; i < count; i += 1) {
      let entry = at + i * stride;
      let sampleDuration = defaultDuration;
      if (flags & 0x100) { sampleDuration = u32(buf, entry); entry += 4; }
      let sampleSize = defaultSize;
      if (flags & 0x200) { sampleSize = u32(buf, entry); entry += 4; }
      let sampleFlags = defaultFlags;
      if (flags & 0x400) { sampleFlags = u32(buf, entry); entry += 4; }
      if (samples === 0 && i === 0) {
        firstFlags = first ?? sampleFlags;
        firstSize = sampleSize;
      }
      duration += sampleDuration;
    }
    samples += count;
  }
  if (samples === 0) throw new Mp4Error('a fragment has no samples');
  return {
    moofStart: moof.start,
    end: mdat.end,
    bytes: mdat.end - moof.start,
    baseDecodeTime,
    duration,
    samples,
    key: (firstFlags & 0x00010000) === 0,
    firstSampleSize: firstSize,
    tfdtOffset: tfdt.bodyStart + 4,
    tfdtWide: tfdtVersion === 1,
  };
}

/** Every fragment of a fragmented file in order (a moof must be followed by its mdat; other top-level boxes are skipped). */
function parseFileUnchecked(buf) {
  const init = parseInitUnchecked(buf);
  const fragments = [];
  const top = readBoxes(buf);
  for (let i = 0; i < top.length; i += 1) {
    if (top[i].type !== 'moof') continue;
    if (!top[i + 1] || top[i + 1].type !== 'mdat') throw new Mp4Error(`the moof at ${top[i].start} is not followed by an mdat`);
    fragments.push(parseFragmentUnchecked(buf, top[i], top[i + 1], init.defaults));
  }
  if (!fragments.length) throw new Mp4Error('the file has no fragments');
  return { init, initBytes: buf.subarray(0, init.initLength), fragments };
}

/** A copy of one fragment (buf[fragment.moofStart, fragment.end)) whose base media decode time is `ticks`. */
function withBaseDecodeTimeUnchecked(buf, fragment, ticks) {
  const copy = Buffer.from(buf.subarray(fragment.moofStart, fragment.end));
  const at = fragment.tfdtOffset - fragment.moofStart;
  if (fragment.tfdtWide) copy.writeBigUInt64BE(BigInt(ticks), at);
  else if (ticks > 0xffffffff) throw new Mp4Error('the base media decode time does not fit a version 0 tfdt');
  else copy.writeUInt32BE(ticks, at);
  return copy;
}

export const parseInit = checked(parseInitUnchecked);
export const parseFragment = checked(parseFragmentUnchecked);
export const parseFile = checked(parseFileUnchecked);
export const withBaseDecodeTime = checked(withBaseDecodeTimeUnchecked);
