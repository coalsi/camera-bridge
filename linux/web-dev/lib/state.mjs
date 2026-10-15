// What the dev server knows: the cameras (configuration and the NVR flags), the recordings settings, the scenario, and the answers
// the NVR routes build from them (storage numbers, per-camera recording status, the banner). The words are the engine's
// (T00 B.3 ArchivePause, ArchiveFolderError, C.6, C.7), apostrophes included.

import { CAMERA_DEFINITIONS, cameraConfiguration, DAY } from './cameras.mjs';
import { VirtualArchive } from './archive.mjs';

export const BUILTIN = { id: 'builtin', label: 'This box’s storage', path: '/var/lib/camera-bridge/recordings' };
export const GIB = 1_073_741_824;
export const GB = 1_000_000_000;
export const LOW_SPACE_MARGIN = 5 * GIB; // ArchiveConstants.lowSpaceMarginBytes
export const OTHER_BYTES = 40 * GB; // what the system, settings and the journal use on the data partition
export const OPTIMIZE_GAP_MS = 3000;
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
    this.reset(scenario);
  }

  serverNow() {
    return this.baseClock() + this.clockOffset;
  }

  /** Back to the start: the seeded history, every camera as its definition says, the settings at their defaults. */
  reset(scenario = 'ok') {
    clearTimeout(this.loadingTimer);
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
        lastEvent: null,
        lastEventDate: null,
        lastError: null,
        recentEvents: [],
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
    };
  }

  cameraList() {
    return [...this.cameras.values()];
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

  /** The banner (T00 C.7): one storage notice at most, only while a camera records. */
  notices() {
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
