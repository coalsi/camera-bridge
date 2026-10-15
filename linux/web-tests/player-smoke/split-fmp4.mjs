// Splits a fragmented MP4 into init.mp4 and one file per moof+mdat, with a manifest (tfdt, duration, key, bytes, mime). No dependencies.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';

const [input, outDir] = process.argv.slice(2);
const data = readFileSync(input);
const view = new DataView(data.buffer, data.byteOffset, data.byteLength);

function boxes(start, end) {
  const out = [];
  let at = start;
  while (at + 8 <= end) {
    let size = view.getUint32(at);
    const type = data.toString('latin1', at + 4, at + 8);
    let header = 8;
    if (size === 1) { size = Number(view.getBigUint64(at + 8)); header = 16; }
    if (size === 0) size = end - at;
    out.push({ type, start: at, end: at + size, body: at + header });
    at += size;
  }
  return out;
}

const top = boxes(0, data.length);
const moov = top.find((b) => b.type === 'moov');
const ftyp = top.find((b) => b.type === 'ftyp');
const initEnd = moov.end;
const find = (list, type) => list.find((b) => b.type === type);
const children = (b) => boxes(b.body, b.end);

// timescale from mdhd, default sample duration from trex
const trak = find(children(moov), 'trak');
const mdia = find(children(trak), 'mdia');
const mdhd = find(children(mdia), 'mdhd');
const timescale = view.getUint32(mdhd.body + (view.getUint8(mdhd.body) === 1 ? 20 : 12));
const mvex = find(children(moov), 'mvex');
const trex = mvex ? find(children(mvex), 'trex') : null;
const trexDuration = trex ? view.getUint32(trex.body + 12) : 0;
const initBytes = data.subarray(0, initEnd);
const avc = initBytes.indexOf('avcC', 0, 'latin1');
const mime = `video/mp4; codecs="avc1.${[1, 2, 3].map((i) => initBytes[avc + 4 + i].toString(16).padStart(2, '0')).join('')}"`;
const width = view.getUint16(initBytes.indexOf('avc1', 0, 'latin1') + 4 + 24);
const height = view.getUint16(initBytes.indexOf('avc1', 0, 'latin1') + 4 + 26);

mkdirSync(outDir, { recursive: true });
writeFileSync(`${outDir}/init.mp4`, initBytes);

const segments = [];
for (let i = 0; i < top.length; i += 1) {
  if (top[i].type !== 'moof') continue;
  const moof = top[i];
  const mdat = top[i + 1];
  const traf = find(children(moof), 'traf');
  const parts = children(traf);
  const tfhd = find(parts, 'tfhd');
  const tfdt = find(parts, 'tfdt');
  const trun = find(parts, 'trun');
  const tfhdFlags = view.getUint32(tfhd.body) & 0xffffff;
  let p = tfhd.body + 8;
  if (tfhdFlags & 0x1) p += 8;
  if (tfhdFlags & 0x2) p += 4;
  if (tfhdFlags & 0x8) p += 4;
  const defaultDuration = tfhdFlags & 0x8 ? view.getUint32(p - 4) : trexDuration;
  if (tfhdFlags & 0x10) p += 4;
  const defaultFlags = tfhdFlags & 0x20 ? view.getUint32(p) : (trex ? view.getUint32(trex.body + 20) : 0);
  const decode = view.getUint8(tfdt.body) === 1 ? Number(view.getBigUint64(tfdt.body + 4)) : view.getUint32(tfdt.body + 4);
  const flags = view.getUint32(trun.body) & 0xffffff;
  const count = view.getUint32(trun.body + 4);
  let q = trun.body + 8;
  if (flags & 0x1) q += 4;
  let firstFlags = null;
  if (flags & 0x4) { firstFlags = view.getUint32(q); q += 4; }
  let total = 0;
  let key = false;
  for (let s = 0; s < count; s += 1) {
    let duration = defaultDuration;
    if (flags & 0x100) { duration = view.getUint32(q); q += 4; }
    if (flags & 0x200) q += 4;
    let sampleFlags = null;
    if (flags & 0x400) { sampleFlags = view.getUint32(q); q += 4; }
    if (flags & 0x800) q += 4;
    if (s === 0) key = !((firstFlags ?? sampleFlags ?? defaultFlags) & 0x10000);
    total += duration;
  }
  const name = `seg-${String(segments.length).padStart(3, '0')}.m4s`;
  writeFileSync(`${outDir}/${name}`, data.subarray(moof.start, mdat.end));
  segments.push({ file: name, tfdtTicks: decode, durationTicks: total, key, bytes: mdat.end - moof.start });
}
writeFileSync(`${outDir}/manifest.json`, JSON.stringify({ timescale, mime, width, height, segments }, null, 1));
console.log(outDir, segments.length, 'segments', mime, width, 'x', height, 'timescale', timescale, 'first', JSON.stringify(segments[0]), 'last', JSON.stringify(segments.at(-1)));
