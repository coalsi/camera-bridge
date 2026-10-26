// The Monitor (#/, and #/nvr/<epoch ms> while looking back): every camera of a page as a tile on one shared playhead, one clock and one
// combined timeline.
// It opens on snapshots: no MediaSource, decoder or byte fetch exists until the first scrub, Play or tile open. The rules are in
// nvr-model.js (pure) and nvr-controller.js (no DOM); this file builds the session, the cells and the DOM, and draws what the controller says.
import { get, getBytes } from '../api.js';
import { h, replace, svg, toast } from '../dom.js';
import { icon } from '../icons.js';
import { cameraList, saveCameraOrder, store, subscribe } from '../store.js';
import { placeAt } from '../camera-order.js';
import { attachReorder } from './nvr-reorder.js';
import { stampText } from '../stamp.js';
import { createLivePlayer, liveSupported, openLive } from '../live/mux.js';
import { createZoom } from '../live/zoom.js';
import { createStraightenedView, isOn } from '../live/straighten.js';
import { createPanTiltPad } from '../live/pan-tilt.js';
import { createMonitorSide, createNightVisionButtons } from './night-vision.js';
import { drawSecurityDot } from './security.js';
import { createWallEvents } from './wall-events.js';
import { batteryBadge, eventRange, pickAction } from './wall-events-model.js';
import { labelStyle, showLabel } from '../labels.js';
import { createFetcher } from '../nvr/fetcher.js';
import { createCatalog } from '../nvr/catalog.js';
import { PlaybackClock } from '../nvr/clock.js';
import { speedLabel } from '../nvr/speed.js';
import { createTransport } from '../nvr/transport.js';
import { createSession } from '../nvr/session.js';
import { createCell } from '../nvr/cell.js';
import { MseSurface } from '../nvr/surface.js';
import { createTimeline } from '../nvr/timeline/view.js';
import { PRESETS } from '../nvr/timeline/viewport.js';
import { banners } from './banners.js';
import {
  KEY_MAP, PAGE_SIZES, GRID_LEAD_LIMIT_BYTES, MEDIA_REQUESTS, MEDIA_REQUESTS_WHILE_LIVE, budgetedCell, createKeyDispatcher, createSnapshotScheduler, createTokenBucket, keyAction,
  loadPicture, parseEpochMs, sameLocalDay,
} from './nvr-model.js';
import {
  MOSAIC_ACROSS, MOSAIC_MAX_TILES, WALL_GAP, layoutMosaicPage, packMosaic, packingBox, pictureAspect, pictureFit, readWallPrefs, wallCells, writeWallPref,
} from './nvr-layout.js';
import { createGridController } from './nvr-controller.js';
import { createClip } from '../nvr/clip.js';
import { footageOf } from '../nvr/clip-range.js';
import { createRecordingSound, soundSupported } from '../nvr/sound.js';

const PRESET_LABELS = { '10m': '10 min', '1h': '1 hour', '6h': '6 hours', '24h': '24 hours', all: 'All' };
const DEFAULT_PRESET = '1h';
const MODE_WORDS = { snapshots: 'Showing live pictures', live: 'Live', paused: 'Paused', playing: 'Playing' };
const dayFormat = new Intl.DateTimeFormat(undefined, { weekday: 'short', day: 'numeric', month: 'short' });
/** The grid sizes as the wall's display menu names them. */
const GRID_LABELS = { 4: 'Grid 2 × 2', 6: 'Grid 3 × 2', 9: 'Grid 3 × 3', 12: 'Grid 4 × 3', 16: 'Grid 4 × 4' };
/** From this width the Monitor is exactly the window's height and the wall takes what the rows around it leave (monitor.css). */
const WALL_FIXED_QUERY = '(min-width: 900px)';

const timeFormat = new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit', second: '2-digit' });
/** Paused, the readout gives tenths of a second, for a precise review picture by picture. */
const tenthsFormat = new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit', second: '2-digit', fractionalSecondDigits: 1 });
/** The clock on a picture: day and time ("Tue 14 Oct · 6:27:14 PM"). */
function clockText(ms) {
  return stampText(ms);
}

// Where the person was, kept while the page is loaded: coming back from the watch screen finds the same page and tile.
let remembered = { page: 0, focusId: null, opened: null };

function readQuery(name) {
  try { return new URLSearchParams(location.search).get(name); } catch { return null; }
}

function readStored(key) {
  try { return localStorage.getItem(key); } catch { return null; }
}

function writeStored(key, value) {
  try { localStorage.setItem(key, value); } catch { /* storage may be blocked; the choice then lasts until the page closes */ }
}

function setData(el, name, value) {
  if (el.dataset[name] !== value) el.dataset[name] = value;
}

function setText(el, text) {
  if (el.textContent !== text) el.textContent = text;
}

/** A picture correction as text, to tell when it changed ('' while off). */
const correctionText = (c) => (isOn(c) ? `${Number(c.straighten) || 0},${Number(c.level) || 0}` : '');

export function renderNVR({ params, navigate, setTitle }) {
  setTitle('Monitor');
  const initialMs = parseEpochMs(params?.[0]);
  // #/nvr/<ms>?camera=<id>&play=1 (the Events page): that camera leads, and the wall plays from the time instead of standing there.
  const query = new URLSearchParams(params?.[1] ?? '');
  const queryCamera = /^[0-9A-Fa-f-]{36}$/.test(query.get('camera') ?? '') ? query.get('camera') : null;
  // A camera that is turned off has no live view and is not on the wall; only one named in the address (an Events row's recording) is, to play it.
  const wallCameras = () => cameraList().filter((camera) => camera.isEnabled !== false || camera.id === queryCamera);
  const playFromAddress = initialMs !== null && query.get('play') === '1';
  // The wall's choices on this browser (nvr-layout.js): a grid of a size, or the mosaic with its smallest width; Fit or Fill; the live quality.
  const prefs = readWallPrefs(readStored, { query: readQuery('tiles'), viewportWidth: window.innerWidth });
  const mosaic = prefs.layout === 'mosaic';
  // The mosaic's pages hold as many cameras as fit (up to 16): the session is made for 16, and the controller asks the mosaic for the pages.
  const perPage = mosaic ? MOSAIC_MAX_TILES : prefs.tiles;
  let fit = prefs.fit;
  let across = prefs.across;
  const playable = typeof window.MediaSource !== 'undefined' || typeof window.ManagedMediaSource !== 'undefined';
  const memory = remembered;
  remembered = { ...memory, opened: null };

  let destroyed = false;
  let controller = null;
  const stages = new Map();        // camera id -> the element a cell puts its <video> in
  const tileParts = new Map();     // camera id -> the tile's DOM
  const announced = { page: null, mode: null };
  let noticeKey = '';
  let pendingFocus = memory.opened;
  let activePreset = PRESETS.includes(readStored('cb.nvr.zoom')) ? readStored('cb.nvr.zoom') : DEFAULT_PRESET;

  // MARK: The player's parts (T08), wired once for the page

  const fetcher = createFetcher({ get, getBytes, sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)) });
  const catalog = createCatalog({ fetcher });
  const playbackClock = new PlaybackClock({ serverNow: () => catalog.serverNow() });
  const dispatcher = createKeyDispatcher({ bucket: createTokenBucket(), focused: () => controller?.focusedId ?? null });

  function stageFor(id) {
    if (!stages.has(id)) stages.set(id, h('div', { class: 'nvr-stage' }));
    return stages.get(id);
  }

  // status.nvr.pause of a camera, from the page's store (kept up to date by the camera events): 'folderMissing' tells the cell that a 410 means
  // the recordings drive is gone, not that retention removed a part (T08 D.6), so the tile keeps its picture and probes for the drive.
  const pauseOf = (id) => cameraList().find((camera) => camera.id === id)?.status?.nvr?.pause ?? null;
  // The camera's picture correction (its page's Straighten the picture), as the page's store has it.
  const correctionOf = (id) => store.cameras.get(id)?.pictureCorrection ?? null;

  function makeCell(cameraId) {
    const cell = createCell({
      cameraId, stage: stageFor(cameraId), catalog, fetcher, clock: playbackClock,
      createSurface: (options) => new MseSurface(options), leadLimitBytes: GRID_LEAD_LIMIT_BYTES, getPause: pauseOf, getCorrection: correctionOf,
    });
    return budgetedCell(cell, { id: cameraId, dispatcher, onRequest: () => controller?.noteRequest() });
  }

  const session = createSession({ catalog, fetcher, clock: playbackClock, createCell: makeCell, tileCap: perPage });
  // The recordings' sound of the camera chosen with its speaker, beside the picture while the playhead plays (nvr/sound.js).
  const recordingSound = playable && soundSupported() ? createRecordingSound({ catalog, fetcher, clock: playbackClock }) : null;

  // Saving a clip: the playhead is the end (the newest recorded moment while live or on snapshots). On the wall the person ticks the cameras (any
  // of every page); with one camera filling the wall, the clip is that camera's.
  const clipCameras = () => wallCameras().filter((camera) => soloId === null || camera.id === soloId);
  const clip = createClip({
    cameras: () => clipCameras().map((camera) => ({ id: camera.id, name: camera.name, pictureCorrection: camera.pictureCorrection })),
    // The range is drawn on the timeline as a red band, inside what the cameras on offer recorded.
    footage: () => footageOf(clipCameras().map((camera) => catalog.extent(camera.id))),
    timeline: { setClipRange: (range, onEdge) => timeline?.setClipRange(range, onEdge) },
    endMs: () => { const t = controller?.view().transport; return !t || t.mode === 'snapshots' || t.mode === 'live' ? catalog.serverNow() : t.positionMs; },
    onChange: () => { if (controller) render(); },
  });

  // MARK: Snapshots

  // A picture is an <img> load in a media slot of the page's budget (fetcher.js `slot`): it holds one of the browser's six connections like a
  // recording's part does, and one that takes too long is cancelled (loadPicture), not left loading.
  function loadSnapshot(id) {
    const parts = tileParts.get(id);
    if (!parts) return Promise.resolve(false);
    const back = parts.snaps[parts.front === 0 ? 1 : 0];
    const front = parts.snaps[parts.front];
    const load = () => loadPicture(back, `/api/v1/cameras/${id}/snapshot?t=${Date.now()}`);
    return fetcher.slot('bytes', load, { key: 'snapshot' }).catch(() => false).then((ok) => {
      if (!ok || destroyed || tileParts.get(id) !== parts) return false;
      parts.front = parts.front === 0 ? 1 : 0;
      setData(back, 'front', 'true');
      setData(front, 'front', 'false');
      front.removeAttribute('src');
      parts.snapshotLoaded = true;
      parts.snapshotAt = stampText();
      parts.snapshotMs = Date.now();
      applySnapshotVisibility(parts);
      drawLabel(parts);
      noteSize(id, back.naturalWidth, back.naturalHeight);
      return true;
    });
  }

  // The wall refreshes its pictures every 2 s (one at a time) while they are snapshots; tiles playing live video or a recording ask for none,
  // and neither do the tiles hidden behind the one camera opened on its own.
  const snapshots = createSnapshotScheduler({ load: loadSnapshot, intervalMs: 2000,
    shouldRefresh: (id) => {
      const parts = tileParts.get(id);
      return parts?.look?.refresh === true && parts.el.dataset.livevideo !== 'true' && !parts.el.hidden;
    } });

  function applySnapshotVisibility(parts) {
    const shown = parts.look?.snapshot === true && parts.snapshotLoaded;
    setData(parts.el, 'snapshot', shown ? 'shown' : 'hidden');
  }

  // MARK: Tiles

  function buildTile(tile) {
    const snaps = [
      h('img', { class: 'nvr-snap', alt: '', decoding: 'async', dataset: { front: 'true' } }),
      h('img', { class: 'nvr-snap', alt: '', decoding: 'async', dataset: { front: 'false' } }),
    ];
    const title = h('strong', { class: 'nvr-tile-note-title' });
    const detail = h('span', { class: 'nvr-tile-note-detail', hidden: true });
    const retry = h('button', { class: 'btn small nvr-retry', type: 'button', hidden: true, onclick: () => controller.retryTile() }, 'Try again');
    const note = h('div', { class: 'nvr-tile-note', hidden: true }, title, detail, retry);
    const busy = h('span', { class: 'nvr-busy', hidden: true }, h('span', { class: 'spinner', 'aria-hidden': 'true' }));
    const caption = h('span', { class: 'nvr-caption', hidden: true });
    const label = h('span', { class: 'video-label', hidden: true });   // the camera's name and the date and time, as the bridge burns them
    const link = h('a', { class: 'nvr-open', href: tile.href }, tile.name);
    const chip = h('span', { class: 'pill idle' });
    const summary = h('span', { class: 'sr-only' });
    const liveVideo = h('video', { class: 'nvr-live', muted: true, playsinline: true, 'aria-label': `Live video from ${tile.name}` });
    const flag = h('span', { class: 'mon-flag', hidden: true });
    const battery = h('span', { class: 'mon-battery', hidden: true });   // a camera with a battery: its level (status.battery)
    // The camera's sound while the wall is live: one camera at a time (a click on another moves it there).
    const sound = h('button', { class: 'nvr-sound', type: 'button', hidden: true, onclick: (event) => { event.stopPropagation(); setAudible(audibleId === tile.id ? null : tile.id); } });
    const media = h('div', { class: 'nvr-media' }, snaps, liveVideo, stageFor(tile.id), note, caption, label, sound, h('div', { class: 'nvr-badges' }, flag, battery, busy, chip));
    // Beside the name in the tile's bar: the place for small marks about the camera (drawNameMarks). Empty, it is hidden.
    const nameSlot = h('span', { class: 'nvr-name-slot', hidden: true });
    const el = h('article', { class: 'nvr-tile', dataset: { id: tile.id, state: 'snapshot', video: 'false', focus: 'false', snapshot: 'hidden', livevideo: 'false', alert: '' }, 'aria-label': tile.name },
      media, h('div', { class: 'nvr-tile-bar' }, h('h3', null, link), nameSlot), summary);
    // The picture's size as the page shows it (the live video, or a recording in the stage: media events reach the stage while capturing): the
    // mosaic's shape for a camera whose status gives no stream size.
    const sized = (event) => noteSize(tile.id, event.target.videoWidth, event.target.videoHeight);
    for (const type of ['loadedmetadata', 'resize']) {
      liveVideo.addEventListener(type, sized);
      stageFor(tile.id).addEventListener(type, sized, true);
    }
    el.addEventListener('click', (event) => {
      if (event.defaultPrevented || event.target === link || event.target.closest('button, a')) return;
      if (clip.choosing()) { event.preventDefault(); clip.toggle(tile.id); return; }
      setSolo(soloId === tile.id ? null : tile.id);   // a click fills the wall with this camera; another click shows them all again
    });
    el.addEventListener('pointerenter', () => controller.focus(tile.id));
    el.addEventListener('focusin', () => controller.focus(tile.id));
    link.addEventListener('click', (event) => {
      if (clip.choosing()) { event.preventDefault(); clip.toggle(tile.id); return; }
      if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      setSolo(soloId === tile.id ? null : tile.id);
    });
    return { el, media, snaps, front: 0, snapshotLoaded: false, link, chip, note, title, detail, retry, busy, caption, summary, look: null,
      liveVideo, flag, battery, batteryKey: '', label, sound, player: null, alertTimer: null, snapshotMs: null, nameSlot, placed: '',
      correction: null, straightened: null, straightenedAs: null };
  }

  /**
   * The tile's picture straightened as the camera's page says (js/live/straighten.js), followed in place when it is saved there (in this
   * browser or another), and drawn again when the wall's Fit or Fill changes (a canvas takes the picture's fit when it is drawn, and a paused
   * picture brings no frame): the live video's (straightenLive) and the recording's (the cell's). Nothing at all for a camera that is never
   * straightened. The snapshots come straightened from the bridge.
   */
  function drawCorrection(parts, camera) {
    const correction = camera?.pictureCorrection ?? null;
    const key = `${correctionText(correction)}|${grid.dataset.fit}`;
    if (key === parts.straightenedAs) return;
    parts.straightenedAs = key;
    parts.correction = correction;
    straightenLive(parts);
    session.cell(parts.el.dataset.id)?.setCorrection(correction);
  }

  /**
   * The live video straightened while a live player feeds it: its canvas sits right after the video with its classes, so the wall's rules
   * for the live video are the canvas's. Without a player the live video is hidden (the tile shows a picture or a recording), and the view
   * gives back its canvas and WebGL context (a page gets only so many).
   */
  function straightenLive(parts) {
    const correction = parts.player ? parts.correction : null;
    if (parts.straightened) parts.straightened.set(correction);
    else if (isOn(correction)) parts.straightened = createStraightenedView({ source: parts.liveVideo, correction });
  }

  /**
   * Marks beside a tile's name: `parts.nameSlot` (a <span class="nvr-name-slot"> after the name's heading in the tile's bar) is the place for a
   * small badge about `camera` (the store's camera, or null), drawn with the tile on every render: its security level's dot (security.js,
   * none before the camera's first check). The slot shows only when something is in it.
   */
  function drawNameMarks(parts, camera) {
    drawSecurityDot(parts.nameSlot, camera);
    parts.nameSlot.hidden = !camera || parts.nameSlot.childNodes.length === 0;
  }

  function updateTile(parts, tile, started) {
    const { look } = tile;
    parts.look = look;
    setData(parts.el, 'state', look.state);
    setData(parts.el, 'video', String(look.video));
    setData(parts.el, 'focus', String(tile.focused && started));
    setData(parts.el, 'clip', clip.choosing() ? (clip.includes(tile.id) ? 'in' : 'out') : '');
    if (!clip.choosing()) delete parts.el.dataset.clip;
    applySnapshotVisibility(parts);
    if (parts.link.getAttribute('href') !== tile.href) parts.link.setAttribute('href', tile.href);
    setText(parts.link, tile.name);
    parts.el.setAttribute('aria-label', tile.name);
    const chipClass = `pill ${look.chip.tone}`;
    if (parts.chip.className !== chipClass) parts.chip.className = chipClass;
    setText(parts.chip, look.chip.text);
    const hasPicture = look.video || (look.snapshot && parts.snapshotLoaded);
    parts.note.hidden = !look.note;
    if (look.note) {
      setText(parts.title, look.note.title);
      setText(parts.detail, look.note.detail ?? '');
      parts.detail.hidden = !look.note.detail;
      parts.retry.hidden = !look.note.action;
      setData(parts.note, 'tone', look.note.tone);
      setData(parts.note, 'place', hasPicture ? 'bottom' : 'center');
    }
    setData(parts.media, 'dim', String(Boolean(look.note) && hasPicture));
    parts.busy.hidden = !look.busy;
    parts.caption.hidden = true;   // the time is in the video label now (drawLabel); the caption only marks a coarse picture
    if (look.caption === 'coarse') { parts.caption.hidden = false; setText(parts.caption, 'Coarse picture'); }
    drawLabel(parts);
    drawSound(parts);
    drawBattery(parts);
    const camera = cameraList().find((candidate) => candidate.id === tile.id) ?? null;
    drawNameMarks(parts, camera);
    drawCorrection(parts, camera);
    setText(parts.summary, tile.summary);
  }

  function renderTiles(view) {
    const wanted = new Set(view.tiles.map((tile) => tile.id));
    for (const [id, parts] of tileParts) {
      if (!wanted.has(id)) { parts.player?.destroy(); parts.straightened?.destroy(); clearTimeout(parts.alertTimer); parts.el.remove(); tileParts.delete(id); stages.delete(id); }
    }
    if (soloId !== null && !wanted.has(soloId)) { soloId = null; zoom?.destroy(); zoom = null; }   // the camera left the page
    // Fit or Fill before the tiles: a straightened picture is drawn again when it changes (drawCorrection) and takes it then.
    setData(grid, 'fit', pictureFit({ solo: soloId !== null, mosaic, chosen: fit }));
    view.tiles.forEach((tile, index) => {
      let parts = tileParts.get(tile.id);
      if (!parts) { parts = buildTile(tile); tileParts.set(tile.id, parts); }
      if (grid.children[index] !== parts.el) grid.insertBefore(parts.el, grid.children[index] ?? null);
      updateTile(parts, tile, view.transport.mode !== 'snapshots');
      setData(parts.el, 'sleeps', String(sleeps(tile.id) && soloId !== tile.id));
    });
    for (const [id, parts] of tileParts) parts.el.hidden = soloId !== null && id !== soloId;
    drawShape(view);
    setData(grid, 'solo', String(soloId !== null));
    allButton.hidden = soloId === null;
    cameraLink.hidden = soloId === null;
    if (soloId !== null) cameraLink.setAttribute('href', `#/camera/${soloId}`);
    side.setCamera(soloId !== null ? cameraList().find((camera) => camera.id === soloId) ?? null : null);
    setData(bottom, 'ptz', String(!side.el.hidden));
    grid.hidden = view.noCameras;
    emptyHost.hidden = !view.noCameras;
  }

  // MARK: The wall's shape: grid cells, the mosaic, Fit or Fill

  const vacantCells = [];          // the plain empty cells after the tiles of a grid that has more cells than cameras
  const seenSizes = new Map();     // camera id -> { width, height } of a picture the page showed
  const wideQuery = window.matchMedia?.(WALL_FIXED_QUERY) ?? null;
  let wallBox = null;              // { width, height } of the wall as it is: where the tiles of the page on screen are placed
  let packBox = null;              // { width, height } the mosaic's pages are packed into (packingBox: a little more room keeps the pages)
  let paginatedKey = null;         // what the controller's pages were made from (mosaicKey)
  const packed = { key: null, lengths: null };
  const pageLayout = { key: null, layout: null };

  const aspectOf = (camera) => pictureAspect(camera, seenSizes.get(camera.id));
  /** Narrower than 900 px the Monitor grows with its content: the mosaic packs into the window's height, top-aligned. */
  const wallFixed = () => wideQuery?.matches ?? true;

  /** The wall's size now (0 × 0 and the like included: a short window can leave it no height); null while it is not on the page. */
  function measureWall() {
    if (!grid.isConnected || grid.hidden) return null;
    const width = grid.clientWidth;
    const height = wallFixed() ? grid.clientHeight : (document.documentElement.clientHeight || window.innerHeight);
    return { width, height };
  }

  /** Takes a measured size: the tiles' box is the wall as it is (none without a size: the grid stands in), the pages' box follows packingBox.
   *  Whether either changed. */
  function takeWallSize(measured) {
    const placed = measured && measured.width > 0 && measured.height > 0 ? measured : null;
    const pack = packingBox(packBox, measured);
    const changed = pack !== packBox || placed?.width !== wallBox?.width || placed?.height !== wallBox?.height;
    wallBox = placed;
    packBox = placed ? pack : null;
    return changed;
  }

  function mosaicKey(cameras) {
    if (!packBox) return 'unmeasured';
    return `${packBox.width}x${packBox.height}@${across}:${cameras.map((camera) => `${camera.id}=${aspectOf(camera).toFixed(3)}`).join(',')}`;
  }

  /** The controller's paginate: the mosaic's page lengths for the whole camera list, or null (a grid, or a wall not measured yet). */
  function mosaicPages(cameras) {
    if (!mosaic) return null;
    const key = mosaicKey(cameras);
    paginatedKey = key;
    if (!packBox) return null;
    if (packed.key !== key) {
      packed.key = key;
      packed.lengths = packMosaic(cameras.map(aspectOf), { ...packBox, gap: WALL_GAP, across })?.pages.map((page) => page.count) ?? null;
    }
    return packed.lengths;
  }

  /** The tiles of the page on screen, placed by the mosaic (the same packing as their page's). */
  function mosaicLayout(tiles) {
    const byId = new Map(cameraList().map((camera) => [camera.id, camera]));
    const aspects = tiles.map((tile) => (byId.has(tile.id) ? aspectOf(byId.get(tile.id)) : null));
    const key = `${wallBox.width}x${wallBox.height}@${across}:${aspects.map((a) => a?.toFixed(3)).join(',')}`;
    if (pageLayout.key !== key) {
      pageLayout.key = key;
      pageLayout.layout = layoutMosaicPage(aspects, { ...wallBox, gap: WALL_GAP, across });
    }
    return pageLayout.layout;
  }

  function placeTile(parts, rect, lift) {
    const key = rect ? `${rect.left},${rect.top - lift},${rect.width},${rect.height}` : '';
    if (parts.placed === key || !rect) return;
    parts.placed = key;
    parts.el.style.setProperty('--tile-x', `${rect.left}px`);
    parts.el.style.setProperty('--tile-y', `${rect.top - lift}px`);
    parts.el.style.setProperty('--tile-w', `${rect.width}px`);
    parts.el.style.setProperty('--tile-h', `${rect.height}px`);
  }

  /** Grid or mosaic, the cells of a grid (its empty ones after the tiles), the mosaic's places, and Fit or Fill for every picture. */
  function drawShape(view) {
    const solo = soloId !== null;
    const layoutName = mosaic && !solo && wallBox && packBox && view.tiles.length > 0 ? 'mosaic' : 'grid';
    setData(grid, 'layout', layoutName);
    // One camera on its own shows its whole picture (the zoom maps the fitted picture); a mosaic tile has its main stream's shape, but live
    // video in Smooth is the sub stream, often of another shape: whole too, never cut.
    setData(grid, 'fit', pictureFit({ solo, mosaic, chosen: fit }));
    let vacant = 0;
    if (solo) setData(grid, 'count', '1');
    else if (mosaic) setData(grid, 'count', String(Math.max(1, view.tiles.length)));
    else {
      const cells = wallCells({ perPage, chosen: prefs.tilesChosen, tiles: view.tiles.length, total: view.total });
      setData(grid, 'count', String(cells.count));
      vacant = view.noCameras ? 0 : cells.vacant;
    }
    while (vacantCells.length < vacant) vacantCells.push(h('div', { class: 'mon-vacant', 'aria-hidden': 'true' }));
    vacantCells.forEach((cell, i) => {
      const at = view.tiles.length + i;
      if (i >= vacant) cell.remove();
      else if (grid.children[at] !== cell) grid.insertBefore(cell, grid.children[at] ?? null);
    });
    if (layoutName !== 'mosaic') return;
    const layout = mosaicLayout(view.tiles);
    // Narrower than 900 px the wall is as tall as its rows, from the top.
    const lift = wallFixed() ? 0 : Math.min(...layout.tiles.map((rect) => rect.top));
    const bottom = Math.max(...layout.tiles.map((rect) => rect.top + rect.height)) - lift;
    view.tiles.forEach((tile, i) => { const parts = tileParts.get(tile.id); if (parts) placeTile(parts, layout.tiles[i], lift); });
    const height = `${bottom}px`;
    if (grid.style.getPropertyValue('--wall-height') !== height) grid.style.setProperty('--wall-height', height);
  }

  /** A picture of `id` the page showed is `width` × `height`: the mosaic takes it for a camera whose status gives no stream size. */
  function noteSize(id, width, height) {
    if (!(width > 0 && height > 0)) return;
    const was = seenSizes.get(id);
    if (was && was.width === width && was.height === height) return;
    seenSizes.set(id, { width, height });
    if (mosaic && controller) render();
  }

  // The wall's size (the window, full screen, a notice or the column beside the events coming and going): measured once a frame, and the
  // mosaic packed again when it changed.
  let layoutFrame = null;
  function layoutWall() {
    if (destroyed || !mosaic || layoutFrame !== null) return;
    layoutFrame = requestAnimationFrame(() => {
      layoutFrame = null;
      if (destroyed || soloId !== null) return;      // measured again when the wall shows every camera (setSolo)
      const next = measureWall();
      if (next && takeWallSize(next)) render();
    });
  }

  // MARK: Transport, pager, notice

  // Play or Pause, a picture back or forward, the readout, the speed menu and the keys' help: the transport Sky Watcher's clip player has too
  // (nvr/transport.js).
  const transport = createTransport({
    onPlay: () => controller.togglePlay(), onStep: (direction) => controller.stepFrame(direction), onSpeed: (rate) => controller.setSpeed(rate), keyMap: KEY_MAP,
  });
  const { playButton, frameBackButton, frameForwardButton, readout, speedGroup, keysHelp } = transport;
  // At the live edge there is nothing to play (the wall is live video): the row says Live. Looking back in the recordings, Play/Pause and
  // Live appear; Live sits at the right end of the row, over the timeline's live edge, and points that way.
  const liveButton = h('button', { class: 'btn primary nvr-golive', type: 'button', onclick: () => controller.goLive(), title: 'Back to live (L)',
    'aria-label': 'Back to live', dataset: { nvr: 'go-live' } }, h('span', null, 'Live'), icon('toLive'));
  const presetButtons = PRESETS.map((preset) => h('button', {
    class: 'btn small', type: 'button', 'aria-pressed': 'false', dataset: { preset },
    onclick: () => { activePreset = preset; writeStored('cb.nvr.zoom', preset); timeline.setPreset(preset); render(); },
  }, PRESET_LABELS[preset]));
  const timelineHost = h('div', { class: 'nvr-grid-timeline' });
  const timeline = createTimeline({ host: timelineHost, session, catalog });
  timelineHost.append(timeline.el);
  timeline.setPreset(activePreset);
  // T10's timeline brings its own preset buttons (and zoom); this page's transport row has the five presets, so the timeline's group is hidden to
  // keep one set. The zoom buttons stay. A timeline without that group is left as it is.
  const timelinePresets = timeline.el.querySelector('.nvr-preset')?.parentElement;     // the group of the timeline's preset buttons
  if (timelinePresets) timelinePresets.hidden = true;

  function readoutText(transport) {
    if (transport.mode === 'snapshots' || transport.mode === 'live') return live ? 'Live' : 'Live pictures';
    const day = sameLocalDay(transport.positionMs, catalog.serverNow()) ? '' : `${dayFormat.format(transport.positionMs)} `;
    const time = (transport.mode === 'paused' ? tenthsFormat : timeFormat).format(transport.positionMs);
    return `${day}${time}${transport.mode === 'playing' && transport.rate !== 1 ? `  ${speedLabel(transport.rate)}` : ''}`;
  }

  function renderTransport(view) {
    const t = view.transport;
    const atLive = t.mode === 'snapshots' || t.mode === 'live';
    transport.render(t, { atLive, text: readoutText(t) });
    liveButton.hidden = atLive;
    liveButton.disabled = !t.canGoLive;
    syncPresets();
  }

  // The timeline's own zoom buttons and wheel leave a preset (the model's preset becomes 'custom'): the pressed button follows the timeline.
  function syncPresets() {
    const shown = timeline.model?.preset ?? activePreset;
    for (const button of presetButtons) button.setAttribute('aria-pressed', String(button.dataset.preset === shown));
  }

  const prevButton = h('button', { class: 'btn small', type: 'button', 'aria-label': 'Previous cameras', onclick: () => controller.previousPage() }, icon('back'));
  const nextButton = h('button', { class: 'btn small', type: 'button', 'aria-label': 'Next cameras', onclick: () => controller.nextPage() }, icon('chevron'));
  const pageLabel = h('span', { class: 'nvr-page-label muted small' });
  // The wall's layout: a grid of a size, or the mosaic. Changing it is kept on this browser and the screen is drawn again (the session and the
  // grid take their size when they are made).
  const sizes = [...new Set([...PAGE_SIZES, prefs.tiles])].sort((a, b) => a - b);
  const sizeSelect = h('select', { class: 'nvr-size', 'aria-label': 'Wall layout', onchange: (event) => {
    if (event.target.value === 'mosaic') writeWallPref(writeStored, 'layout', 'mosaic');
    else { writeWallPref(writeStored, 'layout', 'grid'); writeWallPref(writeStored, 'tiles', event.target.value); }
    window.dispatchEvent(new HashChangeEvent('hashchange'));
  } },
  sizes.map((size) => h('option', { value: String(size), selected: !mosaic && size === prefs.tiles }, GRID_LABELS[size] ?? `${size} cameras`)),
  h('option', { value: 'mosaic', selected: mosaic }, 'Mosaic'));
  // The mosaic: how many cameras go across. The cameras that do not fit go on the next page.
  const acrossSelect = h('select', { class: 'mon-min-width', 'aria-label': 'Cameras across the mosaic', onchange: (event) => {
    across = writeWallPref(writeStored, 'across', event.target.value) ?? across;
    render();
  } }, MOSAIC_ACROSS.map((count) => h('option', { value: String(count), selected: count === across }, `Mosaic: ${count} across`)));
  // A grid's pictures: whole, with black bars where the shapes differ (Fit), or filling the tile, the edges cut (Fill).
  const fitSelect = h('select', { class: 'mon-fit', 'aria-label': 'Picture in each tile', onchange: (event) => {
    fit = writeWallPref(writeStored, 'fit', event.target.value) ?? fit;
    render();
  } }, h('option', { value: 'fit', selected: fit === 'fit' }, 'Fit: whole picture'), h('option', { value: 'fill', selected: fit === 'fill' }, 'Fill: no black bars'));
  function renderPager(view) {
    prevButton.disabled = view.page <= 0;
    nextButton.disabled = view.page >= view.pages - 1;
    setText(pageLabel, `Cameras ${view.first} to ${view.last} of ${view.total}`);
  }

  const notice = h('div', { class: 'nvr-notice', role: 'status', hidden: true });

  function noticeFor(view) {
    if (view.phase === 'unreachable') {
      return { key: 'unreachable', tone: 'warning', text: 'The recordings can’t be reached right now.', button: ['Try again', () => controller.retryCatalog()] };
    }
    if (!view.playable) {
      return { key: 'unplayable', tone: 'warning', text: 'This browser can’t play recordings. The snapshots and the timeline still work. Safari, or Chrome on a Mac, can play them.' };
    }
    if (view.noRecordings) {
      return { key: 'nothing', tone: 'info', text: 'Nothing is being recorded yet. Turn on Record for a camera to build a timeline.', link: ['Open the cameras', '#/cameras'] };
    }
    // Live pictures are snapshots now, so the playback limit only matters while the recordings play.
    if (view.limited && view.transport.mode !== 'live' && view.transport.mode !== 'snapshots') {
      const plays = view.playLimit === 1 ? 'one camera' : `${view.playLimit} cameras`;
      return { key: 'limited', tone: 'info', text: `This browser plays recordings for ${plays} at a time on this page. The other cameras stay on snapshots; open one to watch it.` };
    }
    if (view.waveform.truncated) return { key: 'truncated', tone: 'info', text: 'The timeline combines the first 16 cameras that have recordings.' };
    if (view.phase === 'connecting') return { key: 'connecting', tone: 'info', text: 'Getting the recordings…' };
    return null;
  }

  function renderNotice(view) {
    const next = noticeFor(view);
    const key = next?.key ?? '';
    if (key === noticeKey) return;
    noticeKey = key;
    notice.hidden = !next;
    if (!next) { replace(notice); return; }
    setData(notice, 'tone', next.tone);
    setData(notice, 'kind', next.key);
    replace(notice, h('span', null, next.text),
      next.button ? h('button', { class: 'btn small', type: 'button', onclick: next.button[1] }, next.button[0]) : null,
      next.link ? h('a', { class: 'btn small', href: next.link[1] }, next.link[0]) : null);
  }

  const announcer = h('div', { class: 'sr-only', role: 'status', 'aria-live': 'polite' });

  function announce(view) {
    const messages = [];
    if (view.page !== announced.page) {
      if (announced.page !== null) messages.push(`Showing cameras ${view.first} to ${view.last} of ${view.total}`);
      announced.page = view.page;
    }
    if (view.transport.mode !== announced.mode) {
      if (announced.mode !== null) messages.push(MODE_WORDS[view.transport.mode]);
      announced.mode = view.transport.mode;
    }
    if (messages.length > 0) announcer.textContent = messages.join('. ');
  }

  // MARK: One camera on the whole wall

  // A click on a tile makes that camera fill the wall, with every control of the wall still working (its recording plays, live video in full
  // quality); a second click, "All cameras" or Esc shows them all again.
  let soloId = null;
  const allButton = h('button', { class: 'btn small', type: 'button', hidden: true, onclick: () => setSolo(null) }, icon('back'), 'All cameras');
  const cameraLink = h('a', { class: 'btn small', hidden: true, href: '#/' }, icon('sliders'), 'Camera settings');

  function setSolo(id) {
    if (id === soloId) return;
    soloId = id;
    if (id !== null) controller.focus(id);
    if (clip.choosing()) clip.cancel();     // the cameras on offer changed: start the clip again
    controller.showOnly(id);                // the timeline: that camera's recordings alone, or every camera's again
    render();
    setZoom(id);
    if (id === null) layoutWall();           // the mosaic's wall may have changed size meanwhile
  }

  // Digital zoom on the camera that fills the wall (js/live/zoom.js, Sky Watcher's player has the same): drag a box, wheel or pinch, drag the
  // zoomed picture to move it; double-click, Esc or 0 for the whole picture.
  let zoom = null;
  function setZoom(id) {
    zoom?.destroy();
    zoom = null;
    const parts = id === null ? null : tileParts.get(id);
    if (!parts) return;
    zoom = createZoom({
      host: parts.media,
      // The picture on screen: a recording in its stage while one plays, else the live video; zoomed straightened as the camera's page says.
      getVideo: () => (parts.el.dataset.video === 'true' ? stageFor(id).querySelector('video') : parts.liveVideo),
      getCorrection: () => correctionOf(id),
      onActive: (zoomed) => setData(parts.el, 'zoomed', String(zoomed)),
    });
  }

  // MARK: Live stream (real video while live)

  // Every tile on the page plays its camera's live video over one request (js/live/mux.js) while the wall is live (always, where the browser
  // can; else the tiles stay live pictures); dragging the timeline into the recordings stops it (the players show the recordings), Back to
  // live starts it again.
  const liveOn = liveSupported();
  let audibleId = null;   // the camera whose sound plays (none after a page load: browsers play sound only after a click)
  let liveQuality = prefs.quality;   // Full quality (the main stream) unless Smooth was chosen on this browser
  let live = null;   // { request, ids }
  const qualitySelect = h('select', { class: 'mon-quality', 'aria-label': 'Live quality', onchange: (event) => {
    liveQuality = writeWallPref(writeStored, 'quality', event.target.value) ?? 'main';
    stopLive();
    render();
  } }, h('option', { value: 'main', selected: liveQuality === 'main' }, 'Full quality'), h('option', { value: 'sub', selected: liveQuality === 'sub' }, 'Smooth'));

  function stopLive() {
    live?.request.close();
    live = null;
    fetcher.setMediaCap(MEDIA_REQUESTS);
    for (const parts of tileParts.values()) {
      parts.player?.destroy();
      parts.player = null;
      setData(parts.el, 'livevideo', 'false');
      straightenLive(parts);
    }
  }

  function startLive(ids, stream = liveQuality) {
    stopLive();
    fetcher.setMediaCap(MEDIA_REQUESTS_WHILE_LIVE);      // the live request holds a connection of its own
    const ordered = ids.map((id) => tileParts.get(id)).filter(Boolean);
    for (const parts of ordered) {
      parts.player = createLivePlayer(parts.liveVideo, {
        onPlaying: () => { setData(parts.el, 'livevideo', 'true'); },
        onProblem: () => { setData(parts.el, 'livevideo', 'false'); },
      });
      parts.player.setMuted(parts.el.dataset.id !== audibleId);
      straightenLive(parts);
    }
    const audio = audibleId !== null && ids.includes(audibleId) ? [audibleId] : [];
    const request = openLive(ids, {
      stream, audio,
      onMessage: (index, message) => {
        const parts = ordered[index];
        if (!parts?.player) return;
        if (message.kind === 'meta') parts.player.meta(message.json);
        else if (message.kind === 'init') parts.player.init(message.bytes);
        else if (message.kind === 'delta' || message.kind === 'keyframe') parts.player.media(message.bytes, message.kind === 'keyframe');
        else if (message.kind === 'status') setData(parts.el, 'livevideo', 'false');
      },
    });
    live = { request, ids: ids.join(','), stream, audio: audio.join(',') };
  }

  /** A camera that sleeps between uses (a eufy battery camera): the wall shows its latest picture, and only the one camera opened on its own
   *  wakes it (a wall left open would otherwise keep it awake and drain it). */
  const sleeps = (id) => cameraList().find((camera) => camera.id === id)?.integration?.service === 'eufy';

  function syncLive(view) {
    const liveMode = view.transport.mode === 'live' || view.transport.mode === 'snapshots';
    const ids = soloId !== null ? [soloId] : view.tiles.map((tile) => tile.id).filter((id) => !sleeps(id));
    const stream = soloId !== null ? 'main' : liveQuality;   // one camera on the whole wall: its full picture
    const want = liveOn && liveMode && ids.length > 0;
    if (!want) { if (live) stopLive(); }
    else if (!live || live.ids !== ids.join(',') || live.stream !== stream || live.audio !== (audibleId !== null && ids.includes(audibleId) ? audibleId : '')) startLive(ids, stream);
  }

  /** Plays `id`'s sound (null: none). The live request starts again with that camera's sound in it. */
  function setAudible(id) {
    audibleId = id;
    recordingSound?.setCamera(id);
    render();
  }

  /** The speaker on a tile: live (with the live video) or the recordings' sound while they play; pressed for the camera that plays aloud. */
  function drawSound(parts) {
    const camera = cameraList().find((c) => c.id === parts.el.dataset.id);
    const atLive = !parts.look?.video;
    const show = camera?.audioEnabled !== false && (atLive ? liveOn : recordingSound !== null);
    parts.sound.hidden = !show;
    if (!show) return;
    const on = audibleId === parts.el.dataset.id;
    if (parts.sound.dataset.on !== String(on)) {
      replace(parts.sound, icon(on ? 'volume' : 'volumeOff'));
      parts.sound.dataset.on = String(on);
      parts.sound.setAttribute('aria-pressed', String(on));
      parts.sound.setAttribute('aria-label', `${on ? 'Mute' : 'Hear'} ${camera?.name ?? 'this camera'}`);
      parts.sound.title = on ? 'Mute' : 'Hear this camera';
    }
  }

  /** The battery badge of a camera that reports one (status.battery; another camera shows nothing): level, a bolt while charging, warning colour when low. */
  function drawBattery(parts) {
    const badge = batteryBadge(cameraList().find((c) => c.id === parts.el.dataset.id));
    const key = badge ? `${badge.level}|${badge.charging}|${badge.low}` : '';
    if (key === parts.batteryKey) return;
    parts.batteryKey = key;
    parts.battery.hidden = !badge;
    if (!badge) { replace(parts.battery); return; }
    setData(parts.battery, 'low', String(badge.low));
    setData(parts.battery, 'charging', String(badge.charging));
    const words = `Battery ${badge.text}${badge.charging ? ', charging' : ''}${badge.low ? ', low' : ''}`;
    parts.battery.setAttribute('aria-label', words);
    parts.battery.setAttribute('role', 'img');
    parts.battery.title = words;
    const fill = Math.max(1, Math.round((badge.level / 100) * 12));
    replace(parts.battery,
      svg('svg', { viewBox: '0 0 18 10', width: 18, height: 10, 'aria-hidden': 'true', focusable: 'false' },
        svg('rect', { x: 0.5, y: 0.5, width: 15, height: 9, rx: 2, fill: 'none', stroke: 'currentColor' }),
        svg('rect', { x: 16, y: 3, width: 1.6, height: 4, rx: 0.6, fill: 'currentColor' }),
        svg('rect', { x: 2, y: 2, width: fill, height: 6, rx: 1, fill: 'currentColor', class: 'mon-battery-fill' }),
        badge.charging ? svg('path', { d: 'M9 1.2 5.6 5.6h2.6L7 8.8l3.4-4.4H7.8z', class: 'mon-battery-bolt' }) : null),
      h('span', { 'aria-hidden': 'true' }, badge.text));
  }

  // MARK: Events, clock, full screen

  const events = createWallEvents({
    now: () => catalog.serverNow(),
    loadEvents: (query) => catalog.events(query),
    onChange: () => refreshEvents(),
    onPick: (event) => pickEvent(event),
    onAlert: (id, text, level) => {
      const parts = tileParts.get(id);
      if (!parts) return;
      setData(parts.el, 'alert', level);
      setText(parts.flag, text);
      parts.flag.hidden = false;
      clearTimeout(parts.alertTimer);
      parts.alertTimer = setTimeout(() => { setData(parts.el, 'alert', ''); parts.flag.hidden = true; }, 12_000);
    },
  });

  /** The events list follows the cameras on the wall (the one opened on its own, alone) and the timeline's range, as the timeline does. */
  function refreshEvents() {
    if (destroyed || !lastView) return;
    const model = timeline.model;
    events.update({
      cameraIds: soloId !== null ? [soloId] : lastView.tiles.map((tile) => tile.id),
      range: eventRange(model?.viewport, { following: model?.following === true }),
      extentOf: (id) => catalog.extent(id),
    });
  }

  /** A row of the list: the playhead a few seconds before the event, every camera of the wall (or the one opened on its own) playing. */
  function pickEvent(event) {
    const action = pickAction(event, { extent: catalog.extent(event.cameraId), soloId });
    if (!action) return;
    if (action.leaveSolo) setSolo(null);
    if (clip.choosing()) clip.cancel();
    controller.focus(event.cameraId);     // the event's camera leads: it has the recording, so its first frame starts the clock
    const held = lastView?.transport.holding === true;
    if (controller.playAt(action.targetMs)) {
      announcer.textContent = `${held ? 'Paused at' : 'Playing from'} ${timeFormat.format(action.targetMs)}, ${event.label} at ${event.cameraName}`;
    } else {
      events.select(null);
      announcer.textContent = lastView?.playable === false ? 'This browser can’t play recordings.' : 'The recordings aren’t ready yet. Try again in a moment.';
    }
  }

  const bigClock = h('span', { class: 'mon-big-clock', role: 'timer', 'aria-live': 'off' });
  const fullButton = h('button', { class: 'btn small', type: 'button', onclick: () => toggleFullScreen() });

  function toggleFullScreen() {
    if (document.fullscreenElement) document.exitFullscreen?.();
    else el.requestFullscreen?.().catch(() => {});
  }

  function showFullScreen() {
    const on = document.fullscreenElement === el;
    replace(fullButton, icon(on ? 'minimize' : 'maximize'), on ? 'Exit full screen' : 'Full screen');
  }

  /** The time the tile's picture shows: the playhead for a recording, now for live video, the snapshot's time for a snapshot. */
  function labelTime(parts) {
    if (parts.look?.video) return lastView?.transport.positionMs ?? null;
    if (parts.el.dataset.livevideo === 'true') return Date.now();
    if (parts.look?.snapshot && parts.snapshotLoaded) return parts.snapshotMs;
    return null;
  }

  function drawLabel(parts) {
    const camera = cameraList().find((c) => c.id === parts.el.dataset.id);
    showLabel(parts.label, camera, camera ? labelTime(parts) : null);
    // The label carries the name: the tile's own heading steps aside (it stays for screen readers and the keyboard), and the marks beside it
    // move away from a label at the top left (monitor.css).
    setData(parts.el, 'labelname', String(!parts.label.hidden && !!camera && labelStyle(camera).showCameraName));
    setData(parts.el, 'labelpos', camera ? labelStyle(camera).position : '');
  }

  function tickClock() {
    if (destroyed) return;
    setText(bigClock, stampText());
    for (const parts of tileParts.values()) drawLabel(parts);
  }
  const clockTimer = setInterval(tickClock, 1000);

  // MARK: The page

  const grid = h('div', { class: 'nvr-grid', dataset: { count: String(perPage) } });
  const orderNote = h('div', { class: 'sr-only', role: 'status', 'aria-live': 'polite' });   // says where a camera moved to
  const emptyHost = h('div', { class: 'mon-none', hidden: true },
    h('p', null, 'No cameras yet.'), h('a', { class: 'btn primary', href: '#/add' }, icon('plus'), 'Add a camera'));
  const bannerHost = banners();
  // Pan and tilt, and night vision: only for one camera opened on its own that has them, in a column beside the events.
  const side = createMonitorSide(createPanTiltPad(), createNightVisionButtons());
  const bottom = h('div', { class: 'mon-bottom' });
  const el = h('section', { class: 'monitor nvr-page', 'aria-label': 'Monitor' },
    h('div', { class: 'mon-head' },
      h('h1', null, 'Monitor'), allButton, cameraLink, bigClock,
      h('div', { class: 'mon-actions' }, liveOn ? qualitySelect : null, sizeSelect, mosaic ? acrossSelect : fitSelect, events.soundButton, fullButton)),
    events.banners, bannerHost, notice, grid, orderNote, emptyHost,
    replace(bottom,
      h('div', { class: 'mon-timeline nvr-controls' },
        h('div', { class: 'nvr-transport' }, frameBackButton, playButton, frameForwardButton, readout, speedGroup, clip.button,
          h('div', { class: 'nvr-grid-presets', role: 'group', 'aria-label': 'Timeline range' }, presetButtons),
          h('nav', { class: 'nvr-pager', 'aria-label': 'Camera pages' }, prevButton, pageLabel, nextButton), keysHelp, liveButton),
        clip.el,
        timelineHost),
      side.el,
      h('section', { class: 'mon-activity', 'aria-labelledby': 'mon-events-title' }, events.head, events.list)),
    announcer);

  let lastView = null;

  function render() {
    if (destroyed) return;
    if (mosaic && soloId === null) {
      // The first draw after the page is in place measures the wall; a new size, smallest width or picture shape makes new pages. Not while
      // one camera fills the wall: its column beside the events changes the wall's height, and new pages could take that camera away.
      if (!wallBox) takeWallSize(measureWall());
      if (mosaicKey(wallCameras()) !== paginatedKey) controller.relayout();
    }
    const view = controller.view();
    lastView = view;
    renderTiles(view);
    syncLive(view);
    renderTransport(view);
    renderPager(view);
    renderNotice(view);
    announce(view);
    clip.tick();
    refreshEvents();
    snapshots.poke();
    if (pendingFocus !== null) {
      // Back from the watch screen: the tile that was opened gets the keyboard focus again (app.js focuses <main> before this first draw).
      tileParts.get(pendingFocus)?.link.focus({ preventScroll: true });
      pendingFocus = null;
    }
  }

  controller = createGridController({
    session, catalog, listCameras: wallCameras,
    subscribeCameras: (fn) => subscribe((kind) => { if (kind === 'camera' || kind === 'removed' || kind === 'order') fn(); }),
    perPage, initialMs, initialPage: queryCamera ? 0 : memory.page, initialFocus: queryCamera ?? memory.focusId, playable, paginate: mosaicPages,
    navigate, replaceHash: (path) => { try { history.replaceState(history.state, '', `#${path}`); } catch { /* the address stays as it is */ } },
    remember: (state) => { remembered = { ...remembered, ...state }; },
    formatTime: clockText, now: () => Date.now(),
    setWaveformCameras: (ids) => timeline.setCameras(ids), setSnapshotIds: (ids) => snapshots.setIds(ids), pokeSnapshots: () => snapshots.poke(),
  });
  const stopRendering = controller.subscribe(render);
  const stopModel = timeline.model?.onChange?.(() => { if (!destroyed) { syncPresets(); refreshEvents(); } });

  // MARK: Keys and visibility

  function onKeyDown(event) {
    const target = event.target instanceof Element ? event.target : null;
    const typing = Boolean(target?.closest('input, select, textarea, [contenteditable=""], [contenteditable="true"]')) || Boolean(document.querySelector('dialog[open]'));
    const activatable = Boolean(target?.closest('button, a[href], summary, [role="button"], [role="switch"], [role="tab"], [role="menuitem"]'));
    // A handle of the clip's red band moves its end with the arrow keys (the timeline's own handler).
    if (target?.closest('[data-clip-edge]') && event.key !== 'Escape' && event.key !== 'Enter') return;
    if (!typing && clip.key(event)) { event.preventDefault(); event.stopImmediatePropagation(); return; }
    if (!typing && zoom?.key(event)) { event.preventDefault(); return; }     // Esc or 0 while zoomed: the whole picture again
    if (!typing && event.key === 'Escape' && soloId !== null && !document.fullscreenElement) { event.preventDefault(); setSolo(null); return; }
    // Alt + an arrow key on a focused tile moves the tile (attachReorder), not the timeline a minute.
    if (event.altKey && event.key.startsWith('Arrow') && target?.closest('.nvr-tile') && canReorder()) return;
    const action = keyAction(event, { typing, activatable });
    if (!action || !controller.canAct()) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    controller.key(action);
  }

  function onVisibility() {
    if (document.hidden) { snapshots.pause(); controller.suspend(); } else { snapshots.resume(); controller.resume(); }
  }

  // Moving the tiles: drag one onto another's place, or Alt + arrow on a focused tile. The whole new order is saved with one PATCH.
  function moveCamera(id, targetId) {
    const ids = cameraList().map((camera) => camera.id);
    const next = placeAt(ids, id, targetId);
    if (next === ids) return;
    saveCameraOrder(next, { onError: (error) => toast(`The camera order was not saved. ${error.message}`, 'error') });
    setTimeout(() => { if (!destroyed && (!document.activeElement || document.activeElement === document.body)) tileParts.get(id)?.link.focus(); }, 60);
  }
  function canReorder() { return soloId === null && !clip.choosing() && wallCameras().length > 1; }
  const stopReorder = attachReorder(grid, {
    tileId: (node) => node?.closest?.('.nvr-tile')?.dataset.id ?? null,
    targetAt: (x, y) => document.elementFromPoint(x, y)?.closest?.('.nvr-tile')?.dataset.id ?? null,
    mark: (id, kind) => { const parts = tileParts.get(id); if (parts) setData(parts.el, 'reorder', kind ?? ''); },
    enabled: canReorder,
    commit: (id, targetId) => {
      const shown = wallCameras();
      orderNote.textContent = `${nameOf(id)} moved to position ${shown.findIndex((camera) => camera.id === targetId) + 1} of ${shown.length}`;
      moveCamera(id, targetId);
    },
    step: (id, delta) => {
      const shown = wallCameras();
      const at = shown.findIndex((camera) => camera.id === id);
      const to = at + delta;
      if (at < 0) return null;
      if (to < 0 || to >= shown.length) return `${nameOf(id)} is already ${delta < 0 ? 'first' : 'last'}`;
      moveCamera(id, shown[to].id);
      return `${nameOf(id)} moved to position ${to + 1} of ${shown.length}`;
    },
    announce: (text) => { orderNote.textContent = text; },
  });
  const nameOf = (id) => cameraList().find((camera) => camera.id === id)?.name ?? 'Camera';

  document.addEventListener('keydown', onKeyDown, true);
  document.addEventListener('visibilitychange', onVisibility);
  document.addEventListener('fullscreenchange', showFullScreen);
  const wallObserver = mosaic && typeof ResizeObserver === 'function' ? new ResizeObserver(layoutWall) : null;
  wallObserver?.observe(grid);
  if (mosaic) {
    window.addEventListener('resize', layoutWall);
    wideQuery?.addEventListener?.('change', layoutWall);
  }
  showFullScreen();
  tickClock();

  catalog.start();
  controller.start().then(() => { if (playFromAddress && !destroyed) controller.playAt(initialMs); }).catch((error) => console.error(error));

  return {
    el,
    destroy() {
      if (destroyed) return;
      destroyed = true;
      stopReorder();
      document.removeEventListener('keydown', onKeyDown, true);
      document.removeEventListener('visibilitychange', onVisibility);
      document.removeEventListener('fullscreenchange', showFullScreen);
      wallObserver?.disconnect();
      window.removeEventListener('resize', layoutWall);
      wideQuery?.removeEventListener?.('change', layoutWall);
      if (layoutFrame !== null) cancelAnimationFrame(layoutFrame);
      if (document.fullscreenElement === el) document.exitFullscreen?.();
      clearInterval(clockTimer);
      stopLive();
      events.destroy();
      side.destroy();
      for (const parts of tileParts.values()) { clearTimeout(parts.alertTimer); parts.straightened?.destroy(); }
      stopRendering();
      if (typeof stopModel === 'function') stopModel();
      controller.destroy();
      clip.destroy();
      recordingSound?.destroy();
      zoom?.destroy();
      snapshots.destroy();
      dispatcher.destroy();
      timeline.destroy();
      session.destroy();
      catalog.stop();
      fetcher.destroy();
      bannerHost.destroy();
      tileParts.clear();
      stages.clear();
    },
  };
}
