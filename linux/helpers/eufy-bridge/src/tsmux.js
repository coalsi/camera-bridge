// A small MPEG-TS muxer for one live stream: H.264 or H.265 video (Annex-B access units) plus optional
// AAC (ADTS frames) or G.711 A-law audio.
//
// Why not ffmpeg: the camera's media carries no timestamps, video and audio arrive on separate
// callbacks, and an ffmpeg fed two pipes blocks probing one while the other fills — a camera that
// sends no audio would stall the picture. Muxing here costs no CPU, starts on the first keyframe with
// no probe delay, and stamps each unit with its arrival time.
//
// Output is chunked per access unit; each chunk says whether a reader may start on it (`keyframe`),
// and every keyframe chunk is preceded by PAT + PMT, so a reader joining mid-stream starts cleanly.

const PACKET = 188;
const PID_PMT = 0x1000;
const PID_VIDEO = 0x100;
const PID_AUDIO = 0x101;

export const STREAM_TYPE = { h264: 0x1b, h265: 0x24, aac: 0x0f, pcma: 0x90 };

// CRC-32/MPEG-2
const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i << 24;
    for (let j = 0; j < 8; j++) c = c & 0x80000000 ? (c << 1) ^ 0x04c11db7 : c << 1;
    t[i] = c >>> 0;
  }
  return t;
})();

export function crc32mpeg(buf) {
  let crc = 0xffffffff;
  for (const b of buf) crc = ((crc << 8) ^ CRC_TABLE[((crc >>> 24) ^ b) & 0xff]) >>> 0;
  return crc >>> 0;
}

function psiPacket(pid, tableBytes, cc) {
  const pkt = Buffer.alloc(PACKET, 0xff);
  pkt[0] = 0x47;
  pkt[1] = 0x40 | ((pid >> 8) & 0x1f);
  pkt[2] = pid & 0xff;
  pkt[3] = 0x10 | (cc & 0x0f);
  pkt[4] = 0; // pointer field
  tableBytes.copy(pkt, 5);
  return pkt;
}

function section(tableId, idExt, body) {
  // table_id, section_syntax(1) '0' reserved(2) length(12), id_ext(16), reserved(2) version(5) cni(1), sec#, last#
  const len = 5 + body.length + 4;
  const head = Buffer.from([tableId, 0xb0 | ((len >> 8) & 0x0f), len & 0xff, idExt >> 8, idExt & 0xff, 0xc1, 0, 0]);
  const noCrc = Buffer.concat([head, body]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32mpeg(noCrc));
  return Buffer.concat([noCrc, crc]);
}

function writePts(buf, off, marker, ts) {
  // 33-bit timestamp in 5 bytes
  const hi = Math.floor(ts / 2 ** 30) & 0x07;
  const mid = Math.floor(ts / 2 ** 15) & 0x7fff;
  const lo = ts & 0x7fff;
  buf[off] = (marker << 4) | (hi << 1) | 1;
  buf[off + 1] = mid >> 7;
  buf[off + 2] = ((mid & 0x7f) << 1) | 1;
  buf[off + 3] = lo >> 7;
  buf[off + 4] = ((lo & 0x7f) << 1) | 1;
}

/** Split an Annex-B buffer into NAL units (without start codes). */
export function splitNals(data) {
  const nals = [];
  let i = 0;
  let start = -1;
  const n = data.length;
  while (i + 2 < n) {
    if (data[i] === 0 && data[i + 1] === 0 && (data[i + 2] === 1 || (data[i + 2] === 0 && i + 3 < n && data[i + 3] === 1))) {
      const scLen = data[i + 2] === 1 ? 3 : 4;
      if (start >= 0) {
        let end = i;
        nals.push(data.subarray(start, end));
      }
      i += scLen;
      start = i;
    } else {
      i++;
    }
  }
  if (start >= 0 && start < n) nals.push(data.subarray(start));
  return nals.filter((x) => x.length > 0);
}

export function nalType(codec, nal) {
  return codec === "h265" ? (nal[0] >> 1) & 0x3f : nal[0] & 0x1f;
}

const SC = Buffer.from([0, 0, 0, 1]);

/**
 * Keeps the latest parameter sets and makes every keyframe self-contained (VPS/SPS/PPS in front),
 * and prefixes an access unit delimiter for H.264 so each PES is one clean access unit.
 */
export class ParamSetCache {
  constructor() {
    this.sets = new Map(); // type -> Buffer (nal without start code)
  }

  /** @returns {Buffer} Annex-B access unit, completed with parameter sets on keyframes. */
  prepare(codec, data, keyframe) {
    const nals = splitNals(data);
    const paramTypes = codec === "h265" ? [32, 33, 34] : [7, 8];
    const present = new Set();
    for (const nal of nals) {
      const t = nalType(codec, nal);
      if (paramTypes.includes(t)) {
        this.sets.set(t, Buffer.from(nal));
        present.add(t);
      }
    }
    const parts = [];
    if (codec === "h264" && !(nals.length && nalType(codec, nals[0]) === 9)) parts.push(SC, Buffer.from([0x09, 0xf0]));
    if (keyframe) {
      for (const t of paramTypes) {
        if (!present.has(t) && this.sets.has(t)) parts.push(SC, this.sets.get(t));
      }
    }
    for (const nal of nals) parts.push(SC, nal);
    return Buffer.concat(parts);
  }

  has(codec) {
    return codec === "h265" ? this.sets.has(33) && this.sets.has(34) : this.sets.has(7) && this.sets.has(8);
  }
}

/** Split a buffer of concatenated ADTS frames. Returns the frames and any trailing partial bytes. */
export function splitAdts(buf) {
  const frames = [];
  let i = 0;
  while (i + 7 <= buf.length) {
    if (buf[i] !== 0xff || (buf[i + 1] & 0xf0) !== 0xf0) {
      i++;
      continue;
    }
    const len = ((buf[i + 3] & 0x03) << 11) | (buf[i + 4] << 3) | (buf[i + 5] >> 5);
    if (len < 7) {
      i++;
      continue;
    }
    if (i + len > buf.length) break;
    frames.push(buf.subarray(i, i + len));
    i += len;
  }
  return { frames, rest: buf.subarray(i) };
}

const ADTS_RATES = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350];

export function adtsSampleRate(frame) {
  return ADTS_RATES[(frame[2] >> 2) & 0x0f] ?? 16000;
}

export class TsMuxer {
  /**
   * @param {{video: "h264"|"h265", audio?: "aac"|"pcma"}} tracks
   */
  constructor(tracks) {
    this.tracks = tracks;
    this.cc = new Map();
    this.lastVideoPts = -1;
    this.lastAudioPts = -1;
    this.audioNext = -1;
    this.avgMs = 66;
    this.lastArrival = undefined;
  }

  nextCc(pid) {
    const c = ((this.cc.get(pid) ?? -1) + 1) & 0x0f;
    this.cc.set(pid, c);
    return c;
  }

  psi() {
    const pat = section(0x00, 1, Buffer.from([0x00, 0x01, 0xe0 | (PID_PMT >> 8), PID_PMT & 0xff]));
    const streams = [
      Buffer.from([STREAM_TYPE[this.tracks.video], 0xe0 | (PID_VIDEO >> 8), PID_VIDEO & 0xff, 0xf0, 0x00]),
    ];
    if (this.tracks.audio) {
      streams.push(Buffer.from([STREAM_TYPE[this.tracks.audio], 0xe0 | (PID_AUDIO >> 8), PID_AUDIO & 0xff, 0xf0, 0x00]));
    }
    const pmtBody = Buffer.concat([Buffer.from([0xe0 | (PID_VIDEO >> 8), PID_VIDEO & 0xff, 0xf0, 0x00]), ...streams]);
    const pmt = section(0x02, 1, pmtBody);
    return Buffer.concat([psiPacket(0, pat, this.nextCc(0)), psiPacket(PID_PMT, pmt, this.nextCc(PID_PMT))]);
  }

  /** Packetize one PES. */
  pes(pid, streamId, payload, pts, pcr, randomAccess) {
    const hdr = Buffer.alloc(14);
    hdr[0] = 0;
    hdr[1] = 0;
    hdr[2] = 1;
    hdr[3] = streamId;
    const pesLen = payload.length + 8;
    // A bounded length lets a reader finish the unit as soon as it has it (go2rtc does); video longer
    // than the 16-bit field allows uses 0 ("unbounded"), which ISO 13818-1 permits for video.
    const lenField = pesLen <= 0xffff ? pesLen : 0;
    hdr.writeUInt16BE(lenField, 4);
    hdr[6] = 0x80 | 0x04; // marker '10', data_alignment_indicator
    hdr[7] = 0x80; // PTS only
    hdr[8] = 5;
    writePts(hdr, 9, 0x2, pts);
    const data = Buffer.concat([hdr, payload]);

    const packets = [];
    let off = 0;
    let first = true;
    while (off < data.length) {
      const pkt = Buffer.alloc(PACKET, 0xff);
      pkt[0] = 0x47;
      pkt[1] = (first ? 0x40 : 0) | ((pid >> 8) & 0x1f);
      pkt[2] = pid & 0xff;
      // Adaptation field bytes after its length byte: flags (+ PCR), then stuffing.
      let af = null;
      if (first && (pcr !== undefined || randomAccess)) {
        af = [(randomAccess ? 0x40 : 0) | (pcr !== undefined ? 0x10 : 0)];
        if (pcr !== undefined) {
          af.push(
            Math.floor(pcr / 2 ** 25) & 0xff,
            Math.floor(pcr / 2 ** 17) & 0xff,
            Math.floor(pcr / 2 ** 9) & 0xff,
            Math.floor(pcr / 2) & 0xff,
            ((pcr & 1) << 7) | 0x7e,
            0x00,
          );
        }
      }
      const remaining = data.length - off;
      const room = 184 - (af ? 1 + af.length : 0);
      if (remaining < room) {
        const stuff = room - remaining;
        if (af) af.push(...Array(stuff).fill(0xff));
        else if (stuff === 1) af = [];
        else af = [0x00, ...Array(stuff - 2).fill(0xff)];
      }
      let p = 4;
      if (af) {
        pkt[3] = 0x30 | this.nextCc(pid);
        pkt[4] = af.length;
        Buffer.from(af).copy(pkt, 5);
        p = 5 + af.length;
      } else {
        pkt[3] = 0x10 | this.nextCc(pid);
      }
      const take = Math.min(PACKET - p, remaining);
      data.copy(pkt, p, off, off + take);
      off += take;
      packets.push(pkt);
      first = false;
    }
    return Buffer.concat(packets);
  }

  /** 90 kHz timestamp from milliseconds, kept strictly increasing per stream. */
  static ts90(ms) {
    return Math.round(ms * 90);
  }

  /**
   * @param {Buffer} au Annex-B access unit (already completed with parameter sets on keyframes)
   * @param {boolean} keyframe
   * @param {number} ms arrival time, ms since the stream's origin
   * @returns {Buffer}
   */
  video(au, keyframe, ms) {
    // Arrival time, but never closer to the previous frame than 0.8 of the average frame interval:
    // frames that arrive in a burst (one datagram run, one pipe read) still get distinct, ordered times.
    // The average is a slow moving average seeded at 15 fps (what eufy cameras send), so a burst barely
    // moves it.
    if (this.lastArrival !== undefined) {
      const d = Math.min(Math.max(ms - this.lastArrival, 0), 1000);
      this.avgMs = this.avgMs * 0.95 + d * 0.05;
    }
    this.lastArrival = ms;
    const minGap = Math.round(Math.min(Math.max(this.avgMs, 20), 200) * 72); // 0.8 of the interval, in 90 kHz ticks
    const arrival = TsMuxer.ts90(ms) + 90_000; // +1 s so audio stamped slightly earlier never goes negative
    let pts = arrival;
    if (this.lastVideoPts >= 0 && pts < this.lastVideoPts + minGap) pts = this.lastVideoPts + minGap;
    if (pts - arrival > 45_000) pts = Math.max(arrival, this.lastVideoPts + 1); // never run > 0.5 s ahead
    this.lastVideoPts = pts;
    const pcr = Math.max(0, pts - 9_000); // PCR 100 ms behind PTS
    const body = this.pes(PID_VIDEO, 0xe0, au, pts % 2 ** 33, pcr % 2 ** 33, keyframe);
    return keyframe ? Buffer.concat([this.psi(), body]) : body;
  }

  /**
   * @param {Buffer} frame one ADTS frame (aac) or a run of A-law bytes (pcma)
   * @param {number} ms arrival time
   */
  audio(frame, ms) {
    if (!this.tracks.audio) return Buffer.alloc(0);
    const arrival = TsMuxer.ts90(ms) + 90_000;
    // Smooth AAC timing: frames are 1024 samples; follow the sample clock unless arrival drifts > 250 ms.
    let pts = arrival;
    if (this.audioNext >= 0 && Math.abs(arrival - this.audioNext) < 22_500) pts = this.audioNext;
    if (pts <= this.lastAudioPts) pts = this.lastAudioPts + 1;
    const dur = this.tracks.audio === "aac" ? Math.round((1024 * 90_000) / adtsSampleRate(frame)) : Math.round((frame.length * 90_000) / 8000);
    this.audioNext = pts + dur;
    this.lastAudioPts = pts;
    return this.pes(PID_AUDIO, 0xc0, frame, pts % 2 ** 33, undefined, false);
  }
}
