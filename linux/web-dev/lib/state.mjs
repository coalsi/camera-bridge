// What the dev server knows: the cameras (configuration and the NVR flags), the recordings settings, the scenario, and the answers
// the NVR routes build from them (storage numbers, per-camera recording status, the banner). The words are the engine's
// (T00 B.3 ArchivePause, ArchiveFolderError, C.6, C.7), apostrophes included.

import { CAMERA_DEFINITIONS, cameraConfiguration, DAY } from './cameras.mjs';
import { VirtualArchive } from './archive.mjs';
import { nightVisionStatus } from './night-vision.mjs';
import { securityStatus } from './camera-security.mjs';
import { NotificationLog, categoryOf, keyOf } from './notifications.mjs';

export const BUILTIN = { id: 'builtin', label: 'This box’s storage', path: '/var/lib/camera-bridge/recordings' };
export const GIB = 1_073_741_824;
export const GB = 1_000_000_000;
export const LOW_SPACE_MARGIN = 5 * GIB; // ArchiveConstants.lowSpaceMarginBytes
export const OTHER_BYTES = 40 * GB; // what the system, settings and the journal use on the data partition
export const OPTIMIZE_GAP_MS = 3000;
/** What a made-up AI service said, by event kind: { summary, kind, concern } as the box's `description`. */
const AI_SAMPLES = {
  Person: [
    { summary: 'A person in a red jacket walks up the path to the front door', kind: 'person', concern: 'routine' },
    { summary: 'Someone tries the door handle and looks through the window', kind: 'person', concern: 'alarm' },
    { summary: 'A courier leaves a parcel by the door', kind: 'delivery', concern: 'routine' },
    { summary: 'A person lingers by the side gate for a while', kind: 'person', concern: 'unusual' },
  ],
  Vehicle: [
    { summary: 'A white van parks across the end of the driveway', kind: 'vehicle', concern: 'unusual' },
    { summary: 'A car drives past without stopping', kind: 'vehicle', concern: 'routine' },
    { summary: 'A car reverses into the driveway', kind: 'vehicle', concern: 'routine' },
    { summary: 'A truck idles at the gate', kind: 'vehicle', concern: 'unusual' },
  ],
  Motion: [
    { summary: 'Leaves blow across the porch', kind: 'nothing', concern: 'routine' },
    { summary: 'A cat crosses the yard', kind: 'animal', concern: 'routine' },
    { summary: 'Shadows move on the lawn', kind: 'other', concern: 'routine' },
    { summary: 'Branches sway in the wind', kind: 'nothing', concern: 'routine' },
  ],
};
export const LIVE_GRACE_MS = 120_000; // ArchiveStore.eventLiveGraceMs: an event this new of a recording camera counts as recorded
export const KEEP_DAYS_RANGE = [1, 365];
export const MAX_SIZE_RANGE = [10, 100_000];

export const SENTENCES = {
  noFolder: 'Choose where to store recordings.',
  folderMissing: 'The recordings folder isn’t available. Reconnect the drive or choose another folder.',
  diskFull: 'There isn’t enough free space on the recordings drive.',
  cannotWrite: 'Camera Bridge can’t write to that folder.',
  notAnswering: 'The drive isn’t answering.',
  notFound: 'That folder doesn’t exist. Create it first, or choose another one.',
};

/**
 * Scenario -> what it does. pause: why recording stopped (ArchivePause); reads: how fragment bytes answer ('gone' = 410, 'stall' = a
 * wait, then 504); empty: the folder has no recordings; archive: false = the daemon has no archive at all; ready: false = still loading.
 */
export const SCENARIOS = {
  ok: {},
  noFolder: { pause: { code: 'noFolder', readable: SENTENCES.noFolder }, empty: true },
  folderMissing: { pause: { code: 'folderMissing', readable: SENTENCES.folderMissing }, reads: 'gone', folder: 'missing' },
  diskFull: { pause: { code: 'diskFull', readable: SENTENCES.diskFull }, space: 'full' },
  lowSpace: { space: 'low' },
  notWritable: { pause: { code: 'notWritable', readable: SENTENCES.cannotWrite }, folder: 'readOnly' },
  stalled: { pause: { code: 'notWritable', readable: SENTENCES.notAnswering }, reads: 'stall', folder: 'stalled' },
  noArchive: { archive: false },
  loading: { ready: false, waiting: 'loading the recordings' },
};

export const isoSeconds = (ms) => new Date(Math.floor(ms / 1000) * 1000).toISOString().replace('.000Z', 'Z');
const round10MB = (value) => Math.round(value / 10_000_000) * 10_000_000;

export class DevState {
  /** `definitions` are the cameras (cameras.mjs); a test may give fewer or different ones, for example one that began 20 seconds ago. */
  constructor({ fixtures, clock = Date.now, diskGB = 512, loadingMs = 3000, scenario = 'ok', definitions = CAMERA_DEFINITIONS }) {
    this.definitions = definitions;
    this.baseClock = clock;
    this.clockOffset = 0;
    this.diskBytes = diskGB * GB;
    this.loadingMs = loadingMs;
    this.fixtures = fixtures;
    this.noticeDates = new Map();
    this.notifications = new NotificationLog();
    this.reset(scenario);
  }

  serverNow() {
    return this.baseClock() + this.clockOffset;
  }

  /** Back to the start: the seeded history, every camera as its definition says, the settings at their defaults. */
  reset(scenario = 'ok') {
    clearTimeout(this.loadingTimer);
    this.notifications = new NotificationLog();
    this.archive = new VirtualArchive({ fixtures: this.fixtures, definitions: this.definitions, clock: () => this.serverNow() });
    this.archive.seed();
    this.settings = { nvrFolder: BUILTIN.path, nvrKeepDays: 7, nvrMaxSizeGB: 500 };
    this.cameras = new Map(this.definitions.map((definition) => [definition.id, { definition, configuration: cameraConfiguration(definition), optimized: false, optimizing: false }]));
    this.scenario = 'ok';
    this.trim(); // a pretend drive smaller than three days of footage keeps what fits, as the janitor would at start
    this.setScenario(scenario);
  }

  // ---- scenario ------------------------------------------------------------------------------------------------------------

  get effects() {
    return SCENARIOS[this.scenario];
  }

  /** Why recording is paused now (null: it is not). A missing folder setting is `noFolder` whatever the scenario. */
  pause() {
    if (this.settings.nvrFolder === null) return SCENARIOS.noFolder.pause;
    return this.effects.pause ?? null;
  }

  get hasArchive() {
    return this.effects.archive !== false;
  }

  get isReady() {
    return this.effects.ready !== false;
  }

  setScenario(name) {
    if (!(name in SCENARIOS)) throw new RangeError(`unknown scenario ${name}`);
    clearTimeout(this.loadingTimer);
    this.scenario = name;
    if (name === 'noFolder') this.settings.nvrFolder = null;
    else if (this.settings.nvrFolder === null) this.settings.nvrFolder = BUILTIN.path;
    if (name === 'loading') {
      this.loadingTimer = setTimeout(() => this.setScenario('ok'), this.loadingMs);
      this.loadingTimer.unref();
    }
    this.syncRecording();
  }

  /** Opens or closes each camera's run so that the archive matches "record is on and nothing is wrong". */
  syncRecording() {
    for (const camera of this.cameras.values()) {
      const should = camera.configuration.nvrEnabled && !this.pause() && this.isReady;
      const id = camera.definition.id;
      if (should && !this.archive.isRecording(id)) this.archive.openRun(id, this.serverNow(), { sound: camera.configuration.nvrRecordSound && camera.configuration.audioEnabled });
      else if (!should && this.archive.isRecording(id)) this.archive.closeRun(id);
    }
  }

  /** The archive as the routes see it: nothing in a folder that was never chosen. */
  get reader() {
    return this.effects.empty || this.settings.nvrFolder === null ? EMPTY_READER : this.archive;
  }

  // ---- cameras -----------------------------------------------------------------------------------------------------------------

  nvrStatus(camera) {
    const { configuration, definition } = camera;
    if (!configuration.nvrEnabled) return { state: 'off', detail: null, pause: null, notes: [] };
    const notes = [];
    if (configuration.nvrRecordSound && !configuration.audioEnabled) notes.push({ id: 'sound', text: 'sound could not be recorded' });
    const gop = this.reader === EMPTY_READER ? null : this.archive.extent(definition.id)?.typicalGOP;
    if (gop && gop > 10) notes.push({ id: 'keyframe', text: `keyframe every ${Math.round(gop)} s: scrubbing is slow` });
    const pause = this.pause();
    if (!this.isReady) return { state: 'waiting', detail: this.effects.waiting, pause: null, notes };
    if (pause) return { state: 'paused', detail: pause.readable, pause: pause.code, notes };
    return { state: 'recording', detail: null, pause: null, notes };
  }

  cameraResource(camera) {
    const { configuration, definition } = camera;
    const fixtureName = typeof definition.fixture === 'string' ? definition.fixture : 'gop2';
    const fixture = this.fixtures.get(fixtureName);
    const recentEvents = this.recentEvents(camera);
    const nightVision = nightVisionStatus(camera);
    const security = securityStatus(camera, this.serverNow());
    return {
      ...configuration,
      status: {
        connection: configuration.isEnabled ? 'online' : 'disabled',
        connectionReason: null,
        summary: configuration.isEnabled ? 'Live · Not Paired' : 'Disabled',
        eventChannelConnected: true,
        videoSummary: `${fixture.info.codec.startsWith('hvc1') ? 'HEVC' : 'H.264'} ${fixture.info.width}×${fixture.info.height} · 25 fps`,
        paired: definition.index % 2 === 1,
        hapPort: configuration.hapPort,
        motion: false,
        recordingEnabled: false,
        recordingNow: false,
        liveViewers: 0,
        appViewers: 0,
        panTilt: definition.panTilt === true,
        zoom: definition.zoom === true,
        ...(nightVision ? { nightVision } : {}),
        lastEvent: recentEvents.at(-1)?.name ?? null,
        lastEventDate: recentEvents.at(-1)?.date ?? null,
        lastError: null,
        recentEvents,
        ...(definition.battery ? { battery: { ...definition.battery } } : {}),
        ...(security ? { security } : {}),
        subStreamProblem: null,
        liveSessions: [],
        recordingSession: null,
        mainStreamInfo: { codec: fixture.info.codec.startsWith('hvc1') ? 'hevc' : 'h264', width: fixture.info.width, height: fixture.info.height, fps: 25, bitrateKbps: fixture.bitrateKbps },
        subStreamInfo: null,
        eventsNote: null,
        homeKitNote: null,
        nvr: this.nvrStatus(camera),
      },
      vendorName: 'ONVIF',
      kindName: configuration.kind === 'doorbell' ? 'Video Doorbell' : 'Camera',
      motionSourceName: 'Camera Events',
      address: configuration.endpoint.host,
      // The bridge's verdict (BridgeEngine.internetWatchDone); here only the pretend setup's "Watch its internet" makes it.
      internetWatched: (configuration.setupState?.steps ?? []).some((step) => step.id === 'internetWatch' && (step.status === 'done' || step.status === 'alreadyRight')),
    };
  }

  cameraList() {
    return [...this.cameras.values()];
  }

  /**
   * status.recentEvents of a camera, as the bridge keeps them (the newest 20 rising edges, oldest first): a made-up event every 8 to 24
   * minutes (the camera's index sets the pace), plus those sent with POST /__dev/event. Deterministic, so a reload shows the same list.
   */
  recentEvents(camera) {
    const { definition, configuration } = camera;
    if (!configuration.isEnabled) return [];
    const period = (6 + definition.index * 2) * 60_000;
    const offset = definition.index * 97_000;
    const names = definition.kind === 'doorbell' ? ['Motion', 'Doorbell ring', 'Person', 'Motion'] : ['Motion', 'Person', 'Motion', 'Vehicle'];
    const out = [];
    for (let slot = Math.floor((this.serverNow() - offset) / period), k = 0; k < 20; k += 1, slot -= 1) {
      out.push({ name: names[((slot % 4) + 4) % 4], date: new Date(slot * period + offset).toISOString() });
    }
    out.push(...(camera.sentEvents ?? []));
    return out.sort((a, b) => Date.parse(a.date) - Date.parse(b.date)).slice(-20);
  }

  /** POST /__dev/event: the event joins the camera's recent events and the archive's events (a motion ends after `seconds`, a ring at once). */
  noteEvent(camera, name, seconds = 0) {
    const at = this.serverNow();
    const video = this.reader !== EMPTY_READER && this.archive.isRecording(camera.definition.id);   // the event log's `video`: the recorder was writing
    camera.sentEvents = [...(camera.sentEvents ?? []), { name, date: new Date(at).toISOString() }].slice(-20);
    camera.sentArchive = [...(camera.sentArchive ?? []), { id: `dev-${at.toString(16)}-${(camera.sentArchive?.length ?? 0) + 1}`, name, start: at, end: at + seconds * 1000, video }]
      .slice(-500);
  }

  /**
   * GET nvr/events for one camera: what the bridge's event log would hold, the same made-up schedule as recentEvents over the last
   * seven days (each event lasts 8 to 62 s, a doorbell ring none), plus those sent with POST /__dev/event. `recorded`, as the bridge
   * answers it: the virtual archive holds video at the event's start, or the event began less than LIVE_GRACE_MS ago while the camera's
   * recorder was writing (its fragment may not be readable yet). Oldest first; the route sorts and cuts.
   */
  archivedEvents(camera, fromMs, toMs) {
    const { definition, configuration } = camera;
    if (!configuration.isEnabled) return [];
    const now = this.serverNow();
    const period = (6 + definition.index * 2) * 60_000;
    const offset = definition.index * 97_000;
    const names = definition.kind === 'doorbell' ? ['Motion', 'Doorbell ring', 'Person', 'Motion'] : ['Motion', 'Person', 'Motion', 'Vehicle'];
    const reader = this.reader;
    const recording = reader !== EMPTY_READER && this.archive.isRecording(definition.id);
    const out = [];
    const first = Math.ceil((Math.max(fromMs, now - 7 * 86_400_000) - offset) / period);
    const last = Math.floor((Math.min(toMs - 1, now) - offset) / period);
    const recordedAt = (start, video) => reader.containing(definition.id, start) !== null || reader.containing(definition.id, start + 3000) !== null
      || (video && start >= now - LIVE_GRACE_MS);
    for (let slot = first; slot <= last; slot += 1) {
      const name = names[((slot % 4) + 4) % 4];
      const start = slot * period + offset;
      const end = name === 'Doorbell ring' ? start : start + (8 + (((slot % 7) + 7) % 7) * 9) * 1000;
      const event = { id: `${start.toString(16)}-${definition.index}`, cameraID: definition.id, kind: name, start, end: end <= now ? end : null, recorded: recordedAt(start, recording) };
      const said = slot % 3 === 0 ? AI_SAMPLES[name]?.[((slot / 3) % 4 + 4) % 4 | 0] : null;   // every third event was described (the box leaves the key out until one is)
      if (said) event.description = said;
      out.push(event);
    }
    for (const sent of camera.sentArchive ?? []) {
      if (sent.start < fromMs || sent.start >= toMs) continue;
      out.push({ id: sent.id, cameraID: definition.id, kind: sent.name, start: sent.start, end: sent.end <= now ? sent.end : null, recorded: recordedAt(sent.start, sent.video === true) });
    }
    return out;
  }

  /** `PATCH /cameras/:id/nvr`: the engine's setNVR, which never restarts the camera. A sound change makes a new run, like a new recorder. */
  setNVR(camera, { enabled, recordSound }) {
    const { configuration, definition } = camera;
    if (enabled !== undefined) configuration.nvrEnabled = enabled;
    if (recordSound !== undefined) {
      const changed = configuration.nvrRecordSound !== recordSound;
      configuration.nvrRecordSound = recordSound;
      if (changed && this.archive.isRecording(definition.id)) this.archive.closeRun(definition.id);
    }
    this.syncRecording();
  }

  /** The keyframe fix and its undo: the ingest restarts (a short gap), and files recorded afterwards use the new keyframe interval. */
  optimize(camera, on) {
    const id = camera.definition.id;
    camera.optimized = on;
    const restart = this.archive.isRecording(id);
    if (restart) this.archive.closeRun(id);
    this.archive.setFixtureFrom(id, this.serverNow() + OPTIMIZE_GAP_MS, on ? 'gop2' : null);
    if (restart) {
      const timer = setTimeout(() => this.syncRecording(), OPTIMIZE_GAP_MS);
      timer.unref();
    }
  }

  // ---- storage ---------------------------------------------------------------------------------------------------------------------

  floorBytes() {
    return Math.max(8 * GIB, Math.floor(this.diskBytes / 20));
  }

  /** ArchiveStorageStatus as numbers (zeros while no folder is chosen), rounded to 10 MB. */
  storageNumbers() {
    if (this.settings.nvrFolder === null) return { usedBytes: 0, freeBytes: 0, totalBytes: 0, floorBytes: 0, oldest: null, newest: null };
    const total = this.diskBytes;
    const floor = this.floorBytes();
    const used = this.archive.usedBytes();
    let free = Math.max(0, total - OTHER_BYTES - used);
    if (this.effects.space === 'full') free = Math.max(0, floor - GB);
    if (this.effects.space === 'low') free = floor + Math.floor(3.2 * GB);
    let oldest = null;
    let newest = null;
    for (const id of this.cameras.keys()) {
      const extent = this.archive.extent(id);
      if (!extent) continue;
      oldest = oldest === null ? extent.oldest : Math.min(oldest, extent.oldest);
      newest = newest === null ? extent.newest : Math.max(newest, extent.newest);
    }
    return { usedBytes: round10MB(used), freeBytes: round10MB(free), totalBytes: total, floorBytes: floor, oldest, newest };
  }

  /** R1: the body of `GET /nvr/storage`. */
  storage() {
    const numbers = this.storageNumbers();
    const pause = this.pause();
    const spare = Math.max(0, numbers.freeBytes - numbers.floorBytes);
    const folder = this.settings.nvrFolder;
    return {
      location: folder === null ? null : folder === BUILTIN.path ? 'builtin' : 'other',
      label: folder === BUILTIN.path ? BUILTIN.label : null,
      state: pause ? pause.code : 'ok',
      message: pause ? pause.readable : null,
      recordingCameras: this.cameraList().filter((camera) => camera.configuration.nvrEnabled).length,
      keepDays: this.settings.nvrKeepDays,
      maxSizeGB: this.settings.nvrMaxSizeGB,
      limits: { keepDays: KEEP_DAYS_RANGE, maxSizeGB: MAX_SIZE_RANGE },
      usedBytes: numbers.usedBytes,
      freeBytes: numbers.freeBytes,
      totalBytes: numbers.totalBytes,
      floorBytes: numbers.floorBytes,
      roomBytes: numbers.usedBytes + spare,
      effectiveMaxBytes: Math.min(this.settings.nvrMaxSizeGB * GB, Math.max(0, numbers.totalBytes - 2 * numbers.floorBytes)),
      oldest: numbers.oldest,
      newest: numbers.newest,
    };
  }

  /** R2: the locations the chooser lists (the box has one). */
  locations() {
    const numbers = this.storageNumbers();
    const current = this.settings.nvrFolder === BUILTIN.path;
    const folder = this.effects.folder;
    const problem = folder === 'missing' ? SENTENCES.notFound : folder === 'readOnly' ? SENTENCES.cannotWrite : folder === 'stalled' ? SENTENCES.notAnswering : null;
    const usable = !problem;
    const spare = Math.max(0, numbers.freeBytes - numbers.floorBytes);
    const free = usable ? (current ? numbers.freeBytes : this.diskBytes - OTHER_BYTES - this.archive.usedBytes()) : null;
    const room = usable && current ? numbers.usedBytes + spare : null;
    const small = usable ? (room ?? free) : null;
    return {
      locations: [{
        id: BUILTIN.id,
        label: BUILTIN.label,
        path: BUILTIN.path,
        current,
        writable: usable,
        freeBytes: usable ? round10MB(free) : null,
        totalBytes: usable ? this.diskBytes : null,
        roomBytes: room,
        problem,
        warning: small !== null && small < 100 * GB ? `Small drive: room for about ${Math.floor(small / GB)} GB` : null,
      }],
    };
  }

  /** What changing the limits would delete (T00 C.5, R3 step 4): null when nothing, else the whole-GB figure the sentence uses. */
  deletionFor({ keepDays, maxSizeGB }) {
    const numbers = this.storageNumbers();
    const now = this.serverNow();
    const stricterDays = keepDays !== undefined && keepDays < this.settings.nvrKeepDays;
    const stricterSize = maxSizeGB !== undefined && maxSizeGB < this.settings.nvrMaxSizeGB;
    if (!stricterDays && !stricterSize) return null;
    const days = keepDays ?? this.settings.nvrKeepDays;
    const size = maxSizeGB ?? this.settings.nvrMaxSizeGB;
    const cutoff = now - days * DAY;
    const wouldDelete = numbers.usedBytes > size * GB || (numbers.oldest !== null && numbers.oldest < cutoff);
    if (!wouldDelete) return null;
    const sizeExcess = Math.max(0, numbers.usedBytes - size * GB);
    const span = (numbers.newest ?? 0) - (numbers.oldest ?? 0);
    const share = span > 0 ? Math.min(1, Math.max(0, (cutoff - numbers.oldest) / span)) : 0;
    return Math.max(1, Math.round(Math.max(sizeExcess, numbers.usedBytes * share) / GB));
  }

  /** The janitor, run at once: files that ended before keepDays go, then the oldest until the archive fits. */
  trim() {
    if (this.settings.nvrFolder === null) return;
    this.archive.dropEndedBefore(this.serverNow() - this.settings.nvrKeepDays * DAY);
    const numbers = this.storageNumbers();
    const maximum = Math.min(this.settings.nvrMaxSizeGB * GB, Math.max(0, numbers.totalBytes - 2 * numbers.floorBytes));
    this.archive.dropOldestUntil(maximum);
  }

  // ---- notices ---------------------------------------------------------------------------------------------------------------------------

  /** What is a notification now (the bridge's NoticeResource list): the storage notice, only while a camera records, then what the Internet guard
   *  found (a watched camera seen trying the internet: blocked, said once). Each carries its `category` and `key`. */
  notices() {
    const guard = this.cameraList().filter((camera) => camera.definition.security === 'trying').map((camera) => ({
      id: `guard-tried-${camera.definition.id}`, kind: 'internetGuard', severity: 'info', title: `${camera.definition.name} tried to reach the internet`,
      detail: 'Camera Bridge blocked it. Nothing got out.', cameraID: camera.definition.id, cameraName: camera.definition.name,
      date: isoSeconds(this.serverNow()), action: 'open-camera',
    }));
    return [...this.storageNotices(), ...guard].map((notice) => ({ ...notice, category: categoryOf(notice.kind), key: keyOf(notice) }));
  }

  storageNotices() {
    if (!this.cameraList().some((camera) => camera.configuration.nvrEnabled)) return [];
    const pause = this.pause();
    const numbers = this.storageNumbers();
    const spare = Math.max(0, numbers.freeBytes - numbers.floorBytes);
    let notice = null;
    if (pause) {
      notice = { title: 'Recording Can’t Continue', detail: pause.readable, action: pause.code === 'noFolder' ? 'choose-folder' : 'open-settings' };
    } else if (spare < LOW_SPACE_MARGIN) {
      notice = { title: 'Recording Storage Almost Full', detail: `About ${Math.floor(spare / GB)} GB are left before recording pauses.`, action: 'open-settings' };
    }
    if (!notice) return [];
    const key = `${notice.title}|${notice.detail}`;
    if (!this.noticeDates.has(key)) this.noticeDates.set(key, this.serverNow());
    return [{ id: 'nvr-storage', kind: 'nvrStorage', severity: 'warning', ...notice, cameraID: null, cameraName: null, date: isoSeconds(this.noticeDates.get(key)) }];
  }
}

/** What the routes read when the folder was never chosen: a store with nothing in it. */
export const EMPTY_READER = {
  refresh() {},
  extent: () => null,
  containing: () => null,
  startingAfter: () => null,
  byId: () => null,
  get version() {
    return 0;
  },
  activity: (id, from, binMs, bins) => ({ typical: null, complete: true, coverage: new Array(bins).fill(0), level: new Array(bins).fill(0) }),
};
