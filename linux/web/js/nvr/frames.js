// Frame by frame: how long one picture of a recording lasts (read from its MP4 boxes) and where a step of one picture lands. No DOM.
//
// A recording's frame time is in its fragments: the init segment's `mdhd` gives the video track's timescale, and a fragment's `trun` (or its
// `tfhd`, or the init's `trex`) gives each picture's duration in that timescale. The bridge writes a duration for every sample; ffmpeg writes a
// default. A step lands in the middle of the next (or previous) picture, so rounding never shows the same picture twice or skips one.

/** One picture's length when the recording does not say (20 pictures a second, what most of the owner's cameras send). */
export const DEFAULT_FRAME_MS = 50;
const MIN_FRAME_MS = 4;          // 250 pictures a second
const MAX_FRAME_MS = 1000;       // 1 picture a second

function u32(view, at) { return view.getUint32(at); }

/** The boxes in `view` from `start` to `end`: [{ type, start (of the payload), end }]. */
function boxes(view, start, end) {
  const out = [];
  let at = start;
  while (at + 8 <= end) {
    let size = u32(view, at);
    const type = String.fromCharCode(view.getUint8(at + 4), view.getUint8(at + 5), view.getUint8(at + 6), view.getUint8(at + 7));
    let header = 8;
    if (size === 1) {
      if (at + 16 > end) break;
      size = Number(view.getBigUint64(at + 8));
      header = 16;
    } else if (size === 0) {
      size = end - at;
    }
    if (size < header || at + size > end) break;
    out.push({ type, start: at + header, end: at + size });
    at += size;
  }
  return out;
}

const child = (view, box, type) => boxes(view, box.start, box.end).find((b) => b.type === type) ?? null;
const children = (view, box, type) => boxes(view, box.start, box.end).filter((b) => b.type === type);

function asView(bytes) {
  if (!bytes) return null;
  if (bytes instanceof DataView) return bytes;
  if (bytes instanceof ArrayBuffer) return new DataView(bytes);
  if (ArrayBuffer.isView(bytes)) return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return null;
}

/** The video track of an init segment: { trackId, timescale, defaultDuration } (defaultDuration from mvex/trex, 0 when none), or null. */
export function readVideoTrack(initBytes) {
  const view = asView(initBytes);
  if (!view) return null;
  try {
    const moov = boxes(view, 0, view.byteLength).find((b) => b.type === 'moov');
    if (!moov) return null;
    for (const trak of children(view, moov, 'trak')) {
      const tkhd = child(view, trak, 'tkhd');
      const mdia = child(view, trak, 'mdia');
      if (!tkhd || !mdia) continue;
      const hdlr = child(view, mdia, 'hdlr');
      const mdhd = child(view, mdia, 'mdhd');
      if (!hdlr || !mdhd) continue;
      const handler = String.fromCharCode(...[0, 1, 2, 3].map((i) => view.getUint8(hdlr.start + 8 + i)));
      if (handler !== 'vide') continue;
      const tkhdVersion = view.getUint8(tkhd.start);
      const trackId = u32(view, tkhd.start + (tkhdVersion === 1 ? 20 : 12));
      const mdhdVersion = view.getUint8(mdhd.start);
      const timescale = u32(view, mdhd.start + (mdhdVersion === 1 ? 20 : 12));
      let defaultDuration = 0;
      const mvex = child(view, moov, 'mvex');
      for (const trex of mvex ? children(view, mvex, 'trex') : []) {
        if (u32(view, trex.start + 4) === trackId) defaultDuration = u32(view, trex.start + 12);
      }
      return timescale > 0 ? { trackId, timescale, defaultDuration } : null;
    }
  } catch { /* a box that runs past the end: not a recording we can read */ }
  return null;
}

/** The middle picture duration (in the track's timescale) of the fragment's samples of `track`, or null. */
export function fragmentSampleDuration(fragmentBytes, track) {
  const view = asView(fragmentBytes);
  if (!view || !track) return null;
  try {
    const durations = [];
    for (const moof of boxes(view, 0, view.byteLength).filter((b) => b.type === 'moof')) {
      for (const traf of children(view, moof, 'traf')) {
        const tfhd = child(view, traf, 'tfhd');
        if (!tfhd || u32(view, tfhd.start + 4) !== track.trackId) continue;
        const tfFlags = u32(view, tfhd.start) & 0xffffff;
        let at = tfhd.start + 8;
        if (tfFlags & 0x01) at += 8;           // base_data_offset
        if (tfFlags & 0x02) at += 4;           // sample_description_index
        const fallback = tfFlags & 0x08 ? u32(view, at) : track.defaultDuration;
        for (const trun of children(view, traf, 'trun')) {
          const flags = u32(view, trun.start) & 0xffffff;
          const count = u32(view, trun.start + 4);
          let pos = trun.start + 8;
          if (flags & 0x01) pos += 4;          // data_offset
          if (flags & 0x04) pos += 4;          // first_sample_flags
          const stride = [0x100, 0x200, 0x400, 0x800].filter((bit) => flags & bit).length * 4;
          for (let i = 0; i < count && pos + stride <= trun.end; i += 1) {
            durations.push(flags & 0x100 ? u32(view, pos) : fallback);
            pos += stride;
          }
        }
      }
    }
    const usable = durations.filter((d) => d > 0).sort((a, b) => a - b);
    return usable.length ? usable[Math.floor(usable.length / 2)] : null;
  } catch {
    return null;
  }
}

/** One picture's length in ms from an init segment and a fragment of its file, or null when they do not say (or say something implausible). */
export function frameDurationMs(initBytes, fragmentBytes) {
  const track = readVideoTrack(initBytes);
  const ticks = fragmentSampleDuration(fragmentBytes, track);
  if (!track || !ticks) return null;
  const ms = (ticks / track.timescale) * 1000;
  return ms >= MIN_FRAME_MS && ms <= MAX_FRAME_MS ? ms : null;
}

/**
 * Where a step of one picture lands: `direction` +1 (the next picture) or -1 (the one before), from the playhead `positionMs`.
 * `shownMs` is the start of the picture on screen when the browser said exactly (requestVideoFrameCallback's mediaTime), else null: the step
 * then takes the playhead as the middle of the picture on screen. Either way it lands in the middle of the picture it steps to.
 */
export function frameStepTarget({ positionMs, shownMs = null, frameMs = DEFAULT_FRAME_MS, direction }) {
  const frame = Number.isFinite(frameMs) && frameMs > 0 ? frameMs : DEFAULT_FRAME_MS;
  const step = direction < 0 ? -1 : 1;
  // A shown picture far from the playhead is an older one (the playhead moved since): it says nothing about where the playhead is.
  const exact = Number.isFinite(shownMs) && Math.abs(positionMs - shownMs) < frame * 1.5;
  const start = exact ? shownMs : positionMs - frame / 2;
  return start + step * frame + frame / 2;
}
