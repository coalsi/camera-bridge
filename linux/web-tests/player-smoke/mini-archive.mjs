// A stand-in for the archive routes of T00 C.5 (R5, R7 to R10), made of two fixtures: one camera, "CAM-1", with file A (gop8, 1280x720, 24 s,
// a keyframe every 8 s) that started an hour ago, a gap (6 s unless told otherwise), and file B (high1080, 1920x1080 with another codec string, 10 s, a keyframe every
// 2 s). It answers with the same route code the Node tests use (player-fakes/fake-archive.mjs) and the real bytes of the clips. No sign-in,
// no CSRF: it is for the browser smoke test only.
import { readFileSync } from 'node:fs';
import { ApiError } from '../../web/js/api.js';
import { createArchive, isBytesPath, routeBytes, routeJson } from '../player-fakes/fake-archive.mjs';

export const FILE_A = 'a1b2c3d4e5f6';
export const FILE_B = 'b2c3d4e5f6a1';
export const GAP_MS = 6000;

export function createMiniArchive(fixturesDir, { now = Date.now, gapMs = GAP_MS } = {}) {
  const manifest = (name) => JSON.parse(readFileSync(`${fixturesDir}/${name}/manifest.json`, 'utf8'));
  const a = manifest('gop8');
  const b = manifest('high1080');
  const lengthMs = (m) => (m.segments.reduce((sum, s) => sum + s.durationTicks, 0) / m.timescale) * 1000;
  const boot = now();
  const startA = boot - 3_600_000;
  const startB = startA + lengthMs(a) + gapMs;
  const archive = createArchive({
    timers: { now: () => now() - boot },
    serverEpochAtZero: boot,
    cameraId: 'CAM-1',
    files: [
      { key: FILE_A, startMs: startA, parts: a.segments.length, gop: 4, mime: a.mime, width: a.width, height: a.height, mediaStartTicks: 0 },
      { key: FILE_B, startMs: startB, parts: b.segments.length, gop: 1, mime: b.mime, width: b.width, height: b.height, mediaStartTicks: 0 },
    ],
  });
  const folder = (fileKey) => (fileKey === FILE_A ? 'gop8' : 'high1080');
  const bytes = (path) => { const file = readFileSync(path); return file.buffer.slice(file.byteOffset, file.byteOffset + file.byteLength); };
  archive.mediaBytes = (part) => bytes(`${fixturesDir}/${folder(part.file)}/seg-${String(part.index).padStart(3, '0')}.m4s`);
  archive.initBytes = (fileKey) => bytes(`${fixturesDir}/${folder(fileKey)}/init.mp4`);
  return { archive, gapMs, startA, endA: startA + lengthMs(a), startB, endB: startB + lengthMs(b) };
}

/** Answers GET /api/v1/<path> for node:http: { status, headers, body }. */
export function answer(archive, path) {
  try {
    if (isBytesPath(path)) {
      const { data, headers } = routeBytes([archive], path);
      return { status: 200, headers: Object.fromEntries(headers), body: Buffer.from(data) };
    }
    return { status: 200, headers: { 'Content-Type': 'application/json' }, body: Buffer.from(JSON.stringify(routeJson([archive], path))) };
  } catch (error) {
    if (!(error instanceof ApiError)) throw error;
    const headers = { 'Content-Type': 'application/json' };
    if (Number.isFinite(error.next)) headers['X-CB-Next'] = String(error.next);
    if (Number.isFinite(error.retryAfter)) headers['Retry-After'] = String(error.retryAfter);
    return { status: error.status, headers, body: Buffer.from(JSON.stringify({ error: error.code, message: error.message, field: error.field })) };
  }
}

/** Where the clips start and end, for the page: GET /smoke/layout.json. */
export function layout(info) {
  return { startA: info.startA, endA: info.endA, startB: info.startB, endB: info.endB, gapMs: info.gapMs, fileA: FILE_A, fileB: FILE_B };
}
