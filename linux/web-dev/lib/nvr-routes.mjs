// The NVR routes R1 to R12 of T00 (Part C.5), answered from the virtual archive. Same paths, same order of checks, same error codes and sentences
// as the daemon's WebApp+NVR.swift is specified to have; the scenario switches (state.mjs) make the failure answers reachable.

import { spawn } from 'node:child_process';
import { ApiError, bytes, json, sleep } from './http.mjs';
import { parseFragmentId } from './identity.mjs';
import { BUILTIN, KEEP_DAYS_RANGE, MAX_SIZE_RANGE, SENTENCES } from './state.mjs';

const UUID = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;
const TIME_MIN = 978_307_200_000; // 2001
const TIME_MAX = 4_102_444_800_000; // 2100
const MAX_LEAD_IN_PARTS = 64;

// ---- input ------------------------------------------------------------------------------------------------------------------------

function cameraParam(ctx) {
  if (!UUID.test(ctx.params.id)) throw ApiError.notFound('There is no camera with this identifier.');
  return ctx.params.id.toUpperCase();
}

/** An epoch time in ms from a query value: 1 to 15 digits within 2001 to 2100. */
function timeParam(query, name) {
  const text = query.get(name);
  if (text === null || !/^\d{1,15}$/.test(text)) throw ApiError.invalid(`“${name}” must be a time in milliseconds.`, name);
  const value = Number(text);
  if (value < TIME_MIN || value > TIME_MAX) throw ApiError.invalid(`“${name}” is outside the accepted range.`, name);
  return value;
}

function integerParam(query, name, [low, high], fallback) {
  const text = query.get(name);
  if (text === null) return fallback;
  if (!/^\d{1,9}$/.test(text) || Number(text) < low || Number(text) > high) throw ApiError.invalid(`“${name}” must be from ${low} to ${high}.`, name);
  return Number(text);
}

function fragmentIdParam(text, name) {
  if (!parseFragmentId(text ?? '')) throw ApiError.invalid(`“${name}” isn’t a fragment id.`, name);
  return text;
}

// ---- gates and admission (T00 C.3) -----------------------------------------------------------------------------------

function ready(app) {
  if (!app.state.hasArchive) throw new ApiError(503, 'archive_unavailable', 'Recordings aren’t available on this bridge.');
  if (!app.state.isReady) throw new ApiError(503, 'archive_unavailable', 'The recordings are loading. Try again in a moment.', { headers: { 'Retry-After': '2' } });
}

/** Runs `work` holding an archive slot: 8 in all and 6 per peer address, no queue; the next gets 429 busy at once. */
async function withSlot(app, ctx, work) {
  ready(app);
  const { slots, config } = app;
  const mine = slots.byAddress.get(ctx.address) ?? 0;
  if (slots.total >= config.maximumArchiveReads || mine >= config.maximumArchiveReadsPerAddress) {
    throw new ApiError(429, 'busy', 'The bridge is busy. Try again in a moment.', { headers: { 'Retry-After': '1' } });
  }
  slots.total += 1;
  slots.byAddress.set(ctx.address, mine + 1);
  slots.peakTotal = Math.max(slots.peakTotal, slots.total);
  slots.peakByAddress = Math.max(slots.peakByAddress, mine + 1);
  try {
    await sleep(config.latencyMs + Math.random() * config.jitterMs);
    return await work();
  } finally {
    slots.total -= 1;
    const left = (slots.byAddress.get(ctx.address) ?? 1) - 1;
    if (left <= 0) slots.byAddress.delete(ctx.address);
    else slots.byAddress.set(ctx.address, left);
  }
}

/** What a read of recorded bytes does in the current scenario: a gone drive, a stalled one, or nothing. */
async function checkReads(app) {
  const { reads } = app.state.effects;
  if (reads === 'gone') throw new ApiError(410, 'gone', 'That part of the recording isn’t available.');
  if (reads === 'stall') {
    await sleep(app.config.stallReadMs);
    throw new ApiError(504, 'drive_slow', 'The recordings drive is slow to answer.', { headers: { 'Retry-After': '2' } });
  }
}

async function throttle(app, length) {
  if (app.config.throttleMbps > 0) await sleep((length * 8) / (app.config.throttleMbps * 1000));
}

// ---- shared answers ---------------------------------------------------------------------------------------------------------------

const partJson = (fragment) => ({ id: fragment.id, file: fragment.file.key, start: fragment.start, end: fragment.end, bytes: fragment.bytes, key: fragment.key });

/** `files` for the parts of one answer: the facts a surface needs per file, `initId` naming a part of that file in the answer. */
function filesJson(archive, fragments) {
  const files = {};
  for (const fragment of fragments) {
    if (files[fragment.file.key]) continue;
    files[fragment.file.key] = { ...archive.fileInfo(fragment.file), initId: fragment.id };
  }
  return files;
}

/** The fragment holding the keyframe that governs `fragment` (itself when it holds one); null when retention took it. */
function keyFragmentOf(reader, cameraId, fragment) {
  if (fragment.backToKey === 0) return fragment;
  return reader.byId(cameraId, `${fragment.file.key}.${fragment.index - fragment.backToKey}`);
}

const gone = () => new ApiError(410, 'gone', 'That part of the recording is no longer there.');

// ---- R1 to R4: storage and camera flags -------------------------------------------------------------------------------------------

function storage(app) {
  return json(app.state.storage());
}

function locations(app) {
  return json(app.state.locations());
}

async function patchStorage(app, ctx) {
  const body = ctx.body;
  const { state, config } = app;
  const wanted = {};
  for (const [name, range] of [['keepDays', KEEP_DAYS_RANGE], ['maxSizeGB', MAX_SIZE_RANGE]]) {
    if (body[name] === undefined) continue;
    if (!Number.isInteger(body[name])) throw ApiError.invalid(`“${name}” has the wrong kind of value.`, name);
    if (body[name] < range[0] || body[name] > range[1]) throw ApiError.invalid(`“${name}” must be from ${range[0]} to ${range[1]}.`, name);
    wanted[name] = body[name];
  }
  if (body.location !== undefined && typeof body.location !== 'string') throw ApiError.invalid('“location” has the wrong kind of value.', 'location');
  if (body.confirm !== undefined && typeof body.confirm !== 'boolean') throw ApiError.invalid('“confirm” has the wrong kind of value.', 'confirm');
  if (body.location === undefined && !Object.keys(wanted).length) throw ApiError.invalid('Nothing to change.');
  if (body.location !== undefined && body.location !== BUILTIN.id) throw new ApiError(422, 'folder_rejected', 'Choose one of the listed locations.');
  // the box inspects the folder when the location changes; the dev server also does when a scenario has made the folder a problem, so those answers can be seen
  if (body.location !== undefined && (state.settings.nvrFolder !== BUILTIN.path || state.effects.folder)) {
    const { folder } = state.effects;
    if (folder === 'stalled') {
      await sleep(config.stallFolderMs);
      throw new ApiError(504, 'drive_slow', 'The drive isn’t answering.', { headers: { 'Retry-After': '2' } });
    }
    if (folder === 'missing') throw new ApiError(422, 'folder_rejected', SENTENCES.notFound);
    if (folder === 'readOnly') throw new ApiError(422, 'folder_rejected', SENTENCES.cannotWrite);
  }
  const deleting = state.deletionFor(wanted);
  if (deleting !== null && body.confirm !== true) {
    throw new ApiError(409, 'confirm_required', `This will delete about ${deleting} GB of the oldest recordings. Send confirm to continue.`, { field: 'confirm' });
  }
  if (body.location !== undefined) {
    state.settings.nvrFolder = BUILTIN.path;
    if (state.scenario === 'noFolder') state.setScenario('ok');
  }
  if (wanted.keepDays !== undefined) state.settings.nvrKeepDays = wanted.keepDays;
  if (wanted.maxSizeGB !== undefined) state.settings.nvrMaxSizeGB = wanted.maxSizeGB;
  state.syncRecording();
  state.trim();
  return json(state.storage());
}

async function patchCamera(app, ctx) {
  const id = cameraParam(ctx);
  const body = ctx.body;
  for (const name of ['enabled', 'recordSound']) {
    if (body[name] !== undefined && typeof body[name] !== 'boolean') throw ApiError.invalid(`“${name}” has the wrong kind of value.`, name);
  }
  if (body.enabled === undefined && body.recordSound === undefined) throw ApiError.invalid('Nothing to change.');
  const camera = app.state.cameras.get(id);
  if (!camera) throw ApiError.notFound('There is no camera with this identifier.');
  if (body.enabled === true && !camera.configuration.nvrEnabled && app.state.settings.nvrFolder === null) {
    throw new ApiError(409, 'folder_required', 'Choose where to store recordings first.');
  }
  app.state.setNVR(camera, { enabled: body.enabled, recordSound: body.recordSound });
  return json(app.state.cameraResource(camera));
}

// ---- R5, R6: catalog and activity -----------------------------------------------------------------------------------------------

function cameras(app) {
  ready(app);
  const { state } = app;
  const reader = state.reader;
  const list = [];
  for (const id of state.cameras.keys()) {
    const extent = reader.extent(id);
    if (extent) list.push({ id, oldest: extent.oldest, newest: extent.newest, typicalGOP: extent.typicalGOP });
  }
  return json({ serverTime: state.serverNow(), catalogVersion: reader.version, cameras: list });
}

async function activity(app, ctx) {
  const { query } = ctx;
  // T00 R6, as WebApp+NVRCatalog.swift reads it: every item must be a camera id (an empty item is not one), the same id again, in either letter case, is the
  // same camera (the first one keeps its place), and the limit of 16 counts the different ones.
  const items = (query.get('cameras') ?? '').split(',');
  if (!items.every((item) => UUID.test(item))) throw ApiError.invalid('“cameras” lists camera identifiers separated by commas.', 'cameras');
  const names = [...new Set(items.map((item) => item.toUpperCase()))];
  if (names.length > 16) throw ApiError.invalid('Ask for 1 to 16 cameras at a time.', 'cameras');
  const from = timeParam(query, 'from');
  const binMs = integerParam(query, 'binMs', [1000, 86_400_000], undefined);
  const bins = integerParam(query, 'bins', [1, 2000], undefined);
  if (binMs === undefined) throw ApiError.invalid('“binMs” is missing.', 'binMs');
  if (bins === undefined) throw ApiError.invalid('“bins” is missing.', 'bins');
  if (bins * binMs > 31 * 86_400_000) throw ApiError.invalid('The range may be at most 31 days.', 'bins');
  return withSlot(app, ctx, async () => {
    const reader = app.state.reader;
    const snapped = Math.floor(from / binMs) * binMs;
    const byCamera = {};
    for (const id of names) byCamera[id] = reader.activity(id, snapped, binMs, bins);
    return json({ from: snapped, binMs, bins, serverTime: app.state.serverNow(), catalogVersion: reader.version, byCamera });
  });
}

// ---- the cameras' events (GET nvr/events) -------------------------------------------------------------------------------------------

/**
 * The first `limit` of `sorted` (newest first), never splitting a millisecond, as ArchiveEventLog.page does on the bridge: the events of one
 * start are all in this page or all in the next (asked with to = the oldest start here); when they are the whole page, it holds them all.
 */
export function eventPage(sorted, limit) {
  if (sorted.length <= limit) return sorted;
  const boundary = sorted[limit - 1].start;
  if (sorted[limit].start !== boundary) return sorted.slice(0, limit);
  const newer = sorted.filter((event) => event.start > boundary);
  return newer.length ? newer : sorted.filter((event) => event.start === boundary);
}

async function events(app, ctx) {
  const { query } = ctx;
  // As WebApp+NVRCatalog.swift reads it: the cameras as for activity, then from and to (to after from, at most 31 days), then limit.
  const items = (query.get('cameras') ?? '').split(',');
  if (!items.every((item) => UUID.test(item))) throw ApiError.invalid('“cameras” lists camera identifiers separated by commas.', 'cameras');
  const names = [...new Set(items.map((item) => item.toUpperCase()))];
  if (names.length > 16) throw ApiError.invalid('Ask for 1 to 16 cameras at a time.', 'cameras');
  const from = timeParam(query, 'from');
  const to = timeParam(query, 'to');
  if (to <= from) throw ApiError.invalid('“to” comes after “from”.', 'to');
  if (to - from > 31 * 86_400_000) throw ApiError.invalid('Ask for at most 31 days at a time.', 'to');
  const limit = integerParam(query, 'limit', [1, 1000], 200);
  return withSlot(app, ctx, async () => {
    const { state } = app;
    // As the store answers: nothing without a place for recordings, "try again" (never an empty page) while the folder is missing.
    if (state.settings.nvrFolder === null) return json({ from, to, serverTime: state.serverNow(), more: false, events: [] });
    if (state.effects.folder === 'missing') {
      throw new ApiError(503, 'archive_unavailable', 'The recordings drive isn’t connected.', { headers: { 'Retry-After': '5' } });
    }
    const found = [];
    for (const id of names) {
      const camera = state.cameras.get(id);
      if (camera) found.push(...state.archivedEvents(camera, from, to));
    }
    found.sort((a, b) => b.start - a.start || (a.cameraID < b.cameraID ? -1 : a.cameraID > b.cameraID ? 1 : 0) || (a.id < b.id ? -1 : 1));
    const page = eventPage(found, limit);
    return json({ from, to, serverTime: state.serverNow(), more: page.length < found.length, events: page });
  });
}

// ---- R7: fragments --------------------------------------------------------------------------------------------------------------------

function afterParts(reader, id, previous, count) {
  const parts = [];
  let last = previous;
  while (parts.length < count) {
    const next = reader.startingAfter(id, last.start);
    if (!next) break;
    parts.push(next);
    last = next;
  }
  return parts;
}

async function fragments(app, ctx) {
  const id = cameraParam(ctx);
  const { query } = ctx;
  if (query.has('at') === query.has('after')) throw ApiError.invalid('Use either “at” or “after”.');
  const mode = query.has('at')
    ? { at: timeParam(query, 'at'), ahead: integerParam(query, 'ahead', [0, 16], 2) }
    : { after: fragmentIdParam(query.get('after'), 'after'), limit: integerParam(query, 'limit', [1, 64], 8) };
  return withSlot(app, ctx, async () => {
    const { state } = app;
    const reader = state.reader;
    const serverTime = state.serverNow();
    if (mode.after !== undefined) {
      const anchor = reader.byId(id, mode.after);
      if (!anchor) throw gone();
      const parts = afterParts(reader, id, anchor, mode.limit);
      return json({ serverTime, parts: parts.map(partJson), files: filesJson(reader, parts) });
    }
    const target = reader.containing(id, mode.at);
    if (!target) {
      const extent = reader.extent(id);
      let reason = 'gap';
      if (!extent) reason = 'empty';
      else if (mode.at < extent.oldest) reason = 'beforeStart';
      else if (mode.at >= extent.newest) reason = 'afterEnd';
      const next = reason === 'gap' ? (reader.startingAfter(id, mode.at)?.start ?? null) : null;
      return json({ serverTime, found: false, at: mode.at, reason, next, newest: extent?.newest ?? null });
    }
    const key = keyFragmentOf(reader, id, target);
    if (!key) throw gone();
    let parts = [key];
    let exact = true;
    let targetIndex = 0;
    if (target.index - key.index + 1 > MAX_LEAD_IN_PARTS) {
      exact = false;
    } else {
      for (let n = key.index + 1; n <= target.index; n += 1) parts.push(reader.byId(id, `${key.file.key}.${n}`));
      targetIndex = target.index - key.index;
      if (parts.includes(null)) throw gone();
    }
    parts = parts.concat(afterParts(reader, id, parts.at(-1), mode.ahead));
    return json({ serverTime, found: true, at: mode.at, exact, targetIndex, parts: parts.map(partJson), files: filesJson(reader, parts) });
  });
}

// ---- R8 to R10: bytes -----------------------------------------------------------------------------------------------------------------------

function notOnHead(ctx) {
  if (ctx.request.method === 'HEAD') throw new ApiError(405, 'method_not_allowed', 'That isn’t possible here.', { headers: { Allow: 'GET' } });
}

async function fragmentBytes(app, ctx, part) {
  const id = cameraParam(ctx);
  notOnHead(ctx);
  const fid = fragmentIdParam(ctx.params.fid, 'fid');
  return withSlot(app, ctx, async () => {
    const fragment = app.state.reader.byId(id, fid);
    if (!fragment) throw gone();
    await checkReads(app);
    const data = part === 'init' ? app.state.reader.readInit(fragment) : app.state.reader.readFragment(fragment);
    await throttle(app, data.length);
    return bytes(data, 'video/mp4');
  });
}

async function keyframe(app, ctx) {
  const id = cameraParam(ctx);
  notOnHead(ctx);
  const at = timeParam(ctx.query, 'at');
  return withSlot(app, ctx, async () => {
    const { state } = app;
    const reader = state.reader;
    const target = reader.containing(id, at);
    if (!target) {
      const next = reader.startingAfter(id, at);
      throw new ApiError(404, 'gap', 'There is no recording at that time.', { headers: next ? { 'X-CB-Next': String(next.start) } : {} });
    }
    const key = keyFragmentOf(reader, id, target);
    if (!key) throw gone();
    await checkReads(app);
    const info = reader.fileInfo(key.file);
    const data = reader.readFragment(key);
    await throttle(app, data.length);
    const part = { id: key.id, file: key.file.key, start: key.start, end: key.end, mime: info.mime, width: info.width, height: info.height, anchor: info.anchor, initId: key.id };
    return bytes(data, 'video/mp4', { 'X-CB-Part': JSON.stringify(part) });
  });
}

// ---- R11, R12: the keyframe fix (second tier) ------------------------------------------------------------------------------------------------

async function optimize(app, ctx) {
  const id = cameraParam(ctx);
  if (ctx.body.confirm !== true) throw ApiError.invalid('Send confirm: true to go on.', 'confirm');
  const camera = app.state.cameras.get(id);
  if (!camera) throw ApiError.notFound('There is no camera with this identifier.');
  if (camera.optimizing) throw new ApiError(409, 'optimize_busy', 'This camera is already being optimized.');
  camera.optimizing = true;
  try {
    await sleep(app.config.optimizeMs);
    const applied = camera.optimized ? [] : [{ id: 'keyframe-interval', title: 'Keyframe interval set to 2 seconds' }, { id: 'bitrate-cap', title: 'Bit rate limited to 6 Mbps' }];
    if (!camera.optimized) app.state.optimize(camera, true);
    return json({ applied, failed: [], canUndo: true, mayNeedRecordingReEnabled: false, scoreBefore: 62, scoreAfter: 94 });
  } finally {
    camera.optimizing = false;
  }
}

function undoOptimize(app, ctx) {
  const id = cameraParam(ctx);
  const camera = app.state.cameras.get(id);
  if (!camera) throw ApiError.notFound('There is no camera with this identifier.');
  if (!camera.optimized) throw new ApiError(422, 'optimize_failed', 'There is nothing to undo.');
  app.state.optimize(camera, false);
  return { status: 204, headers: {}, body: null };
}

// ---- saved clips: the plan and the download (WebApp+NVRClip.swift), enough for the clip bar -------------------------------------------
// One part per recording file the range touches (the bridge splits a clip where the recording's format changes); the download is the file's
// init and fragments as they are. `labels` and `straighten` are taken and ignored here; `speed` (a time-lapse) runs ffmpeg as the bridge does:
// key pictures only, `speed` times as fast at 30 pictures a second, no sound.

const MAX_CLIP_MS = 7_200_000;
const TIMELAPSE_SPEEDS = [30, 60, 120, 300];

/** The fragments of [from, to), from the key picture before `from`, grouped by file: [[fragment, …], …]. */
function clipGroups(reader, id, from, to) {
  if (to <= from) throw ApiError.invalid('The clip must end after it starts.', 'to');
  if (to - from > MAX_CLIP_MS) throw new ApiError(422, 'too_long', 'A clip can be at most 2 hours for each camera. Choose a shorter time.');
  const first = reader.containing(id, from);
  let fragment = first ? keyFragmentOf(reader, id, first) : reader.startingAfter(id, from);
  const groups = [];
  while (fragment && fragment.start < to) {
    if (!groups.length || groups.at(-1)[0].file !== fragment.file) {
      if (!fragment.key) { fragment = reader.startingAfter(id, fragment.start); continue; }    // a new file starts at a key picture
      groups.push([]);
    }
    groups.at(-1).push(fragment);
    fragment = reader.startingAfter(id, fragment.start);
  }
  if (!groups.length) throw new ApiError(404, 'gap', 'Nothing was recorded in this time.');
  return groups;
}

const clipName = (camera, group, speed) => {
  const stamp = new Date(group[0].start).toISOString().slice(0, 19).replace('T', ' ').replaceAll(':', '.');
  return `${camera} ${stamp}${speed ? ` time-lapse ${speed}x` : ''}.mp4`;
};

async function clipPlan(app, ctx) {
  const id = cameraParam(ctx);
  const from = timeParam(ctx.query, 'from');
  const to = timeParam(ctx.query, 'to');
  return withSlot(app, ctx, async () => {
    const camera = app.state.cameras.get(id);
    if (!camera) throw ApiError.notFound('There is no camera with this identifier.');
    const groups = clipGroups(app.state.reader, id, from, to);
    const parts = groups.map((group, index) => ({
      index: index + 1, start: group[0].start, end: group.at(-1).end, leadInMs: Math.max(0, from - group[0].start),
      bytes: group.reduce((sum, fragment) => sum + fragment.bytes, 0), samples: 0, fileName: clipName(camera.configuration.name, group, 0),
    }));
    return json({ camera: id, cameraName: camera.configuration.name, parts, gaps: [], soundOmitted: false,
      bytes: parts.reduce((sum, part) => sum + part.bytes, 0), durationMs: to - from });
  });
}

/** `data` through ffmpeg as a time-lapse at `speed`; resolves the MP4. */
function timelapse(data, speed) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.env.CB_FFMPEG || 'ffmpeg', ['-hide_banner', '-loglevel', 'error', '-nostdin', '-skip_frame', 'nokey', '-i', 'pipe:0',
      '-map', '0:v:0', '-vf', `setpts=(PTS-STARTPTS)/${speed},fps=30`, '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23', '-pix_fmt', 'yuv420p', '-an',
      '-movflags', 'frag_keyframe+empty_moov+default_base_moof', '-f', 'mp4', 'pipe:1'], { stdio: ['pipe', 'pipe', 'ignore'] });
    const out = [];
    child.stdout.on('data', (chunk) => out.push(chunk));
    child.on('error', () => reject(new ApiError(501, 'unsupported', 'This bridge has no video converter for time-lapse clips.')));
    child.on('close', (code) => (code === 0 ? resolve(Buffer.concat(out)) : reject(new ApiError(502, 'unreadable', 'The clip couldn’t be converted.'))));
    child.stdin.on('error', () => {});
    child.stdin.end(data);
  });
}

async function clip(app, ctx) {
  const id = cameraParam(ctx);
  notOnHead(ctx);
  const from = timeParam(ctx.query, 'from');
  const to = timeParam(ctx.query, 'to');
  const part = integerParam(ctx.query, 'part', [1, 64], 1);
  const speedText = ctx.query.get('speed');
  if (speedText !== null && !TIMELAPSE_SPEEDS.includes(Number(speedText))) throw ApiError.invalid('Give “speed” as 30, 60, 120 or 300.', 'speed');
  const speed = speedText === null ? 0 : Number(speedText);
  return withSlot(app, ctx, async () => {
    const camera = app.state.cameras.get(id);
    if (!camera) throw ApiError.notFound('There is no camera with this identifier.');
    const group = clipGroups(app.state.reader, id, from, to)[part - 1];
    if (!group) throw ApiError.notFound(`The clip has no part ${part}.`);
    await checkReads(app);
    const reader = app.state.reader;
    let data = Buffer.concat([Buffer.from(reader.readInit(group[0])), ...group.map((fragment) => Buffer.from(reader.readFragment(fragment)))]);
    if (speed) data = await timelapse(data, speed);
    const name = clipName(camera.configuration.name, group, speed).replace(/[^\x20-\x7e]|["\\/]/g, '_');
    return bytes(data, 'video/mp4', { 'Cache-Control': 'no-store', 'Content-Disposition': `attachment; filename="${name}"` });
  });
}

/** The route table entries (method, pattern under /api/v1, handler). All are session routes. */
export const NVR_ROUTES = [
  ['GET', 'nvr/storage', storage, false],
  ['GET', 'nvr/storage/locations', locations, false],
  ['PATCH', 'nvr/storage', patchStorage, true],
  ['PATCH', 'cameras/:id/nvr', patchCamera, true],
  ['GET', 'nvr/cameras', cameras, false],
  ['GET', 'nvr/activity', activity, false],
  ['GET', 'nvr/events', events, false],
  ['GET', 'nvr/cameras/:id/fragments', fragments, false],
  ['GET', 'nvr/cameras/:id/fragments/:fid', (app, ctx) => fragmentBytes(app, ctx, 'fragment'), false],
  ['GET', 'nvr/cameras/:id/fragments/:fid/init', (app, ctx) => fragmentBytes(app, ctx, 'init'), false],
  ['GET', 'nvr/cameras/:id/keyframe', keyframe, false],
  ['GET', 'nvr/cameras/:id/clip-plan', clipPlan, false],
  ['GET', 'nvr/cameras/:id/clip', clip, false],
  ['POST', 'cameras/:id/optimize', optimize, true],
  ['POST', 'cameras/:id/optimize/undo', undoOptimize, false],
];
