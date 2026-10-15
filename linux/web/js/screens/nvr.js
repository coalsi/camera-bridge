// The Monitor (#/, and #/nvr/<epoch ms> while looking back): every camera of a page as a tile on one shared playhead, one clock and one
// combined timeline.
// It opens on snapshots: no MediaSource, decoder or byte fetch exists until the first scrub, Play or tile open. The rules are in
// nvr-model.js (pure) and nvr-controller.js (no DOM); this file builds the session, the cells and the DOM, and draws what the controller says.
import { get, getBytes } from '../api.js';
import { h, replace } from '../dom.js';
import { icon } from '../icons.js';
import { cameraList, subscribe } from '../store.js';
import { stampText } from '../stamp.js';
import { createLivePlayer, liveSupported, openLive } from '../live/mux.js';
import { createWallEvents } from './wall-events.js';
import { showLabel } from '../labels.js';
import { createFetcher } from '../nvr/fetcher.js';
import { createCatalog } from '../nvr/catalog.js';
import { PlaybackClock } from '../nvr/clock.js';
import { createSession } from '../nvr/session.js';
import { createCell } from '../nvr/cell.js';
import { MseSurface } from '../nvr/surface.js';
import { createTimeline } from '../nvr/timeline/view.js';
import { PRESETS } from '../nvr/timeline/viewport.js';
import { banners } from './banners.js';
import {
  PAGE_SIZES, GRID_LEAD_LIMIT_BYTES, budgetedCell, createKeyDispatcher, createSnapshotScheduler, createTokenBucket, keyAction, parseEpochMs, resolveTileCount, sameLocalDay,
} from './nvr-model.js';
import { createGridController } from './nvr-controller.js';
import { createClip } from '../nvr/clip.js';
import { createRecordingSound, soundSupported } from '../nvr/sound.js';

const PRESET_LABELS = { '10m': '10 min', '1h': '1 hour', '6h': '6 hours', '24h': '24 hours', all: 'All' };
const DEFAULT_PRESET = '1h';
const MODE_WORDS = { snapshots: 'Showing live pictures', live: 'Live', paused: 'Paused', playing: 'Playing' };
const SNAPSHOT_GUARD_MS = 10_000;
const dayFormat = new Intl.DateTimeFormat(undefined, { weekday: 'short', day: 'numeric', month: 'short' });
/** The grid sizes as the wall's display menu names them. */
const GRID_LABELS = { 4: 'Grid 2 × 2', 6: 'Grid 3 × 2', 9: 'Grid 3 × 3', 12: 'Grid 4 × 3', 16: 'Grid 4 × 4' };

const timeFormat = new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit', second: '2-digit' });
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

export function renderNVR({ params, navigate, setTitle }) {
  setTitle('Monitor');
  const initialMs = parseEpochMs(params?.[0]);
  const perPage = resolveTileCount({ query: readQuery('tiles'), stored: readStored('cb.nvr.tiles'), viewportWidth: window.innerWidth });
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

  function makeCell(cameraId) {
    const cell = createCell({
      cameraId, stage: stageFor(cameraId), catalog, fetcher, clock: playbackClock,
      createSurface: (options) => new MseSurface(options), leadLimitBytes: GRID_LEAD_LIMIT_BYTES, getPause: pauseOf,
    });
    return budgetedCell(cell, { id: cameraId, dispatcher, onRequest: () => controller?.noteRequest() });
  }

  const session = createSession({ catalog, fetcher, clock: playbackClock, createCell: makeCell, tileCap: perPage });
  // The recordings' sound of the camera chosen with its speaker, beside the picture while the playhead plays (nvr/sound.js).
  const recordingSound = playable && soundSupported() ? createRecordingSound({ catalog, fetcher, clock: playbackClock }) : null;

  // Saving a clip: the playhead is the end (the newest recorded moment while live or on snapshots). On the wall the person ticks the cameras (any
  // of every page); with one camera filling the wall, the clip is that camera's.
  const clip = createClip({
    cameras: () => cameraList().filter((camera) => soloId === null || camera.id === soloId).map((camera) => ({ id: camera.id, name: camera.name })),
    endMs: () => { const t = controller?.view().transport; return !t || t.mode === 'snapshots' || t.mode === 'live' ? catalog.serverNow() : t.positionMs; },
    onChange: () => { if (controller) render(); },
  });

  // MARK: Snapshots

  function loadSnapshot(id) {
    return new Promise((resolve) => {
      const parts = tileParts.get(id);
      if (!parts) { resolve(false); return; }
      const back = parts.snaps[parts.front === 0 ? 1 : 0];
      const front = parts.snaps[parts.front];
      let finished = false;
      const finish = (ok) => {
        if (finished) return;
        finished = true;
        clearTimeout(guard);
        back.onload = null;
        back.onerror = null;
        resolve(ok);
      };
      const guard = setTimeout(() => finish(false), SNAPSHOT_GUARD_MS);
      back.onload = () => {
        if (destroyed || tileParts.get(id) !== parts) { finish(false); return; }
        parts.front = parts.front === 0 ? 1 : 0;
        setData(back, 'front', 'true');
        setData(front, 'front', 'false');
        front.removeAttribute('src');
        parts.snapshotLoaded = true;
        parts.snapshotAt = stampText();
        parts.snapshotMs = Date.now();
        applySnapshotVisibility(parts);
        drawLabel(parts);
        finish(true);
      };
      back.onerror = () => finish(false);
      back.src = `/api/v1/cameras/${id}/snapshot?t=${Date.now()}`;
    });
  }

  // The wall refreshes its pictures every 2 s (one at a time) while they are snapshots; tiles playing live video or a recording ask for none.
  const snapshots = createSnapshotScheduler({ load: loadSnapshot, intervalMs: 2000,
    shouldRefresh: (id) => tileParts.get(id)?.look?.refresh === true && tileParts.get(id)?.el.dataset.livevideo !== 'true' });

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
    // The camera's sound while the wall is live: one camera at a time (a click on another moves it there).
    const sound = h('button', { class: 'nvr-sound', type: 'button', hidden: true, onclick: (event) => { event.stopPropagation(); setAudible(audibleId === tile.id ? null : tile.id); } });
    const media = h('div', { class: 'nvr-media' }, snaps, liveVideo, stageFor(tile.id), note, caption, label, sound, h('div', { class: 'nvr-badges' }, flag, busy, chip));
    const el = h('article', { class: 'nvr-tile', dataset: { id: tile.id, state: 'snapshot', video: 'false', focus: 'false', snapshot: 'hidden', livevideo: 'false', alert: '' }, 'aria-label': tile.name },
      media, h('div', { class: 'nvr-tile-bar' }, h('h3', null, link)), summary);
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
      liveVideo, flag, label, sound, player: null, alertTimer: null, snapshotMs: null };
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
    setText(parts.summary, tile.summary);
  }

  function renderTiles(view) {
    const wanted = new Set(view.tiles.map((tile) => tile.id));
    for (const [id, parts] of tileParts) {
      if (!wanted.has(id)) { parts.player?.destroy(); clearTimeout(parts.alertTimer); parts.el.remove(); tileParts.delete(id); stages.delete(id); }
    }
    view.tiles.forEach((tile, index) => {
      let parts = tileParts.get(tile.id);
      if (!parts) { parts = buildTile(tile); tileParts.set(tile.id, parts); }
      if (grid.children[index] !== parts.el) grid.insertBefore(parts.el, grid.children[index] ?? null);
      updateTile(parts, tile, view.transport.mode !== 'snapshots');
    });
    if (soloId !== null && !wanted.has(soloId)) soloId = null;   // the camera left the page
    for (const [id, parts] of tileParts) parts.el.hidden = soloId !== null && id !== soloId;
    setData(grid, 'count', soloId !== null ? '1' : String(Math.max(1, Math.min(perPage, view.total))));
    setData(grid, 'solo', String(soloId !== null));
    allButton.hidden = soloId === null;
    cameraLink.hidden = soloId === null;
    if (soloId !== null) cameraLink.setAttribute('href', `#/camera/${soloId}`);
    grid.hidden = view.noCameras;
    emptyHost.hidden = !view.noCameras;
  }

  // MARK: Transport, pager, notice

  const playButton = h('button', { class: 'btn primary', type: 'button', onclick: () => controller.togglePlay() }, icon('play'), h('span', null, 'Play'));
  playButton.dataset.playing = 'false';
  // At the live edge there is nothing to play (the wall is live video): the row says Live. Looking back in the recordings, Play/Pause and
  // Back to live appear.
  const liveButton = h('button', { class: 'btn primary', type: 'button', onclick: () => controller.goLive() }, icon('back'), 'Back to live');
  const readout = h('span', { class: 'nvr-readout', role: 'timer', 'aria-live': 'off' });
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
    return `${day}${timeFormat.format(transport.positionMs)}`;
  }

  function renderTransport(view) {
    const t = view.transport;
    if (playButton.dataset.playing !== String(t.playing)) {
      replace(playButton, icon(t.playing ? 'pause' : 'play'), h('span', null, t.playing ? 'Pause' : 'Play'));
      playButton.dataset.playing = String(t.playing);
    }
    const atLive = t.mode === 'snapshots' || t.mode === 'live';
    playButton.hidden = atLive;
    playButton.disabled = !t.canPlay;
    liveButton.hidden = atLive;
    liveButton.disabled = !t.canGoLive;
    setData(readout, 'live', String(atLive));
    setText(readout, readoutText(t));
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
  // Cameras per page. Changing it is kept on this browser and the screen is drawn again (the grid takes its size when it is made).
  const sizes = [...new Set([...PAGE_SIZES, perPage])].sort((a, b) => a - b);
  const sizeSelect = h('select', { class: 'nvr-size', 'aria-label': 'Cameras per page', onchange: (event) => {
    writeStored('cb.nvr.tiles', event.target.value);
    window.dispatchEvent(new HashChangeEvent('hashchange'));
  } }, sizes.map((size) => h('option', { value: String(size), selected: size === perPage }, GRID_LABELS[size] ?? `${size} cameras`)));
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
  }

  // MARK: Live stream (real video while live)

  // Every tile on the page plays its camera's live video over one request (js/live/mux.js) while the wall is live (always, where the browser
  // can; else the tiles stay live pictures); dragging the timeline into the recordings stops it (the players show the recordings), Back to
  // live starts it again.
  const liveOn = liveSupported();
  let audibleId = null;   // the camera whose sound plays (none after a page load: browsers play sound only after a click)
  let liveQuality = readStored('cb.monitor.quality') === 'main' ? 'main' : 'sub';
  let live = null;   // { request, ids }
  const qualitySelect = h('select', { class: 'mon-quality', 'aria-label': 'Live quality', onchange: (event) => {
    liveQuality = event.target.value === 'main' ? 'main' : 'sub';
    writeStored('cb.monitor.quality', liveQuality);
    stopLive();
    render();
  } }, h('option', { value: 'sub', selected: liveQuality === 'sub' }, 'Smooth'), h('option', { value: 'main', selected: liveQuality === 'main' }, 'Full quality'));

  function stopLive() {
    live?.request.close();
    live = null;
    for (const parts of tileParts.values()) {
      parts.player?.destroy();
      parts.player = null;
      setData(parts.el, 'livevideo', 'false');
    }
  }

  function startLive(ids, stream = liveQuality) {
    stopLive();
    const ordered = ids.map((id) => tileParts.get(id)).filter(Boolean);
    for (const parts of ordered) {
      parts.player = createLivePlayer(parts.liveVideo, {
        onPlaying: () => { setData(parts.el, 'livevideo', 'true'); },
        onProblem: () => { setData(parts.el, 'livevideo', 'false'); },
      });
      parts.player.setMuted(parts.el.dataset.id !== audibleId);
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

  function syncLive(view) {
    const liveMode = view.transport.mode === 'live' || view.transport.mode === 'snapshots';
    const ids = soloId !== null ? [soloId] : view.tiles.map((tile) => tile.id);
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

  // MARK: Events, clock, full screen

  const events = createWallEvents({
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
  }

  function tickClock() {
    if (destroyed) return;
    setText(bigClock, stampText());
    for (const parts of tileParts.values()) drawLabel(parts);
  }
  const clockTimer = setInterval(tickClock, 1000);

  // MARK: The page

  const grid = h('div', { class: 'nvr-grid', dataset: { count: String(perPage) } });
  const emptyHost = h('div', { class: 'mon-none', hidden: true },
    h('p', null, 'No cameras yet.'), h('a', { class: 'btn primary', href: '#/add' }, icon('plus'), 'Add a camera'));
  const bannerHost = banners();
  const el = h('section', { class: 'monitor nvr-page', 'aria-label': 'Monitor' },
    h('div', { class: 'mon-head' },
      h('h1', null, 'Monitor'), allButton, cameraLink, bigClock,
      h('div', { class: 'mon-actions' }, liveOn ? qualitySelect : null, sizeSelect, events.soundButton, fullButton)),
    events.banners, bannerHost, notice, grid, emptyHost,
    h('div', { class: 'mon-bottom' },
      h('div', { class: 'mon-timeline nvr-controls' },
        h('div', { class: 'nvr-transport' }, playButton, liveButton, readout, clip.button,
          h('div', { class: 'nvr-grid-presets', role: 'group', 'aria-label': 'Timeline range' }, presetButtons),
          h('nav', { class: 'nvr-pager', 'aria-label': 'Camera pages' }, prevButton, pageLabel, nextButton)),
        clip.el,
        timelineHost),
      h('div', { class: 'mon-activity' }, h('div', { class: 'mon-timeline-head' }, h('strong', null, 'Events')), events.list)),
    announcer);

  let lastView = null;

  function render() {
    if (destroyed) return;
    const view = controller.view();
    lastView = view;
    renderTiles(view);
    syncLive(view);
    renderTransport(view);
    renderPager(view);
    renderNotice(view);
    announce(view);
    clip.tick();
    snapshots.poke();
    if (pendingFocus !== null) {
      // Back from the watch screen: the tile that was opened gets the keyboard focus again (app.js focuses <main> before this first draw).
      tileParts.get(pendingFocus)?.link.focus({ preventScroll: true });
      pendingFocus = null;
    }
  }

  controller = createGridController({
    session, catalog, listCameras: cameraList,
    subscribeCameras: (fn) => subscribe((kind) => { if (kind === 'camera' || kind === 'removed') fn(); }),
    perPage, initialMs, initialPage: memory.page, initialFocus: memory.focusId, playable,
    navigate, replaceHash: (path) => { try { history.replaceState(history.state, '', `#${path}`); } catch { /* the address stays as it is */ } },
    remember: (state) => { remembered = { ...remembered, ...state }; },
    formatTime: clockText, now: () => Date.now(),
    setWaveformCameras: (ids) => timeline.setCameras(ids), setSnapshotIds: (ids) => snapshots.setIds(ids), pokeSnapshots: () => snapshots.poke(),
  });
  const stopRendering = controller.subscribe(render);
  const stopModel = timeline.model?.onChange?.(() => { if (!destroyed) syncPresets(); });

  // MARK: Keys and visibility

  function onKeyDown(event) {
    const target = event.target instanceof Element ? event.target : null;
    const typing = Boolean(target?.closest('input, select, textarea, [contenteditable=""], [contenteditable="true"]')) || Boolean(document.querySelector('dialog[open]'));
    const activatable = Boolean(target?.closest('button, a[href], summary, [role="button"], [role="switch"], [role="tab"], [role="menuitem"]'));
    if (!typing && clip.key(event)) { event.preventDefault(); event.stopImmediatePropagation(); return; }
    if (!typing && event.key === 'Escape' && soloId !== null && !document.fullscreenElement) { event.preventDefault(); setSolo(null); return; }
    const action = keyAction(event, { typing, activatable });
    if (!action || !controller.canAct()) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    controller.key(action);
  }

  function onVisibility() {
    if (document.hidden) { snapshots.pause(); controller.suspend(); } else { snapshots.resume(); controller.resume(); }
  }

  document.addEventListener('keydown', onKeyDown, true);
  document.addEventListener('visibilitychange', onVisibility);
  document.addEventListener('fullscreenchange', showFullScreen);
  showFullScreen();
  tickClock();

  catalog.start();
  controller.start().catch((error) => console.error(error));

  return {
    el,
    destroy() {
      if (destroyed) return;
      destroyed = true;
      document.removeEventListener('keydown', onKeyDown, true);
      document.removeEventListener('visibilitychange', onVisibility);
      document.removeEventListener('fullscreenchange', showFullScreen);
      if (document.fullscreenElement === el) document.exitFullscreen?.();
      clearInterval(clockTimer);
      stopLive();
      events.destroy();
      for (const parts of tileParts.values()) clearTimeout(parts.alertTimer);
      stopRendering();
      if (typeof stopModel === 'function') stopModel();
      controller.destroy();
      clip.destroy();
      recordingSound?.destroy();
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
