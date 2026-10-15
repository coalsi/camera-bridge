// Saving a clip (export-clip design, section 6): Save clip starts it at the playhead, the playhead is the end, Export saves it. One flow for the
// camera's watch screen and for the NVR grid. The engine plans and writes the files (GET /nvr/cameras/:id/clip-plan and /clip); this keeps the
// choice, asks for the plan of each chosen camera as the end moves, and starts the downloads, one file after the other.
import { get } from '../api.js';
import { h, replace } from '../dom.js';
import { icon } from '../icons.js';
import { bytes } from '../format.js';

export const MINIMUM_MS = 1000;
const PLAN_DELAY_MS = 350;
const DOWNLOAD_GAP_MS = 900;
const timeFormat = new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit', second: '2-digit' });
const dayFormat = new Intl.DateTimeFormat(undefined, { day: 'numeric', month: 'short' });

export const WORDS = {
  tooShort: 'Move the end at least 1 second from the start.',
  planning: 'Working out the clip…',
  nothing: 'Nothing was recorded in this time.',
  sound: 'The recording’s sound couldn’t be added to this clip.',
};

/** "14:20:01 to 14:25:12", the end naming its date only when it is on another day. */
export function rangeText(fromMs, toMs) {
  const sameDay = new Date(fromMs).toDateString() === new Date(toMs).toDateString();
  const from = `${dayFormat.format(fromMs)}, ${timeFormat.format(fromMs)}`;
  return `${from} to ${sameDay ? timeFormat.format(toMs) : `${dayFormat.format(toMs)}, ${timeFormat.format(toMs)}`}`;
}

export function durationText(ms) {
  const total = Math.round(ms / 1000);
  const hours = Math.floor(total / 3600), minutes = Math.floor(total / 60) % 60, seconds = total % 60;
  const two = (n) => String(n).padStart(2, '0');
  return hours > 0 ? `${hours}:${two(minutes)}:${two(seconds)}` : `${minutes}:${two(seconds)}`;
}

export function clipUrl(cameraId, fromMs, toMs, part, zone, labels = false) {
  return `/api/v1/nvr/cameras/${cameraId}/clip?from=${Math.round(fromMs)}&to=${Math.round(toMs)}&tz=${encodeURIComponent(zone)}&part=${part}${labels ? '&labels=1' : ''}`;
}

function readLabels() {
  try { return localStorage.getItem('cb.clip.labels') !== '0'; } catch { return true; }
}

/**
 * createClip({ cameras, endMs, startNowMs, onChange, download })
 *   cameras()   -> [{ id, name }]: every camera a clip can be made of, in order
 *   endMs()     -> the playhead in epoch ms (the newest recorded moment while live)
 *   onChange()  -> called when the bar or the tile marks need drawing again
 *   download(url) -> starts one download (default: a hidden link)
 * -> { el, button, choosing, begin(), cancel(), toggle(id), includes(id), exportClip(), key(event), tick(), destroy() }
 */
export function createClip({ cameras, endMs, onChange = () => {}, download = startDownload }) {
  const zone = Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
  let startMs = null;
  let chosen = new Set();       // the cameras ticked for the clip (with one camera on offer, it is always that one)
  let plans = new Map();        // camera id -> { ok, plan | message }
  let planKey = '';
  let planTimer = null;
  let planToken = 0;
  let status = null;            // { kind: 'saving' | 'saved' | 'failed', text }
  let destroyed = false;

  const button = h('button', { class: 'btn small', type: 'button', onclick: () => begin(), dataset: { nvr: 'save-clip' }, title: 'Start a clip at the playhead (C)' },
    icon('scissors'), 'Save clip');
  const el = h('div', { class: 'nvr-clipbar', role: 'group', 'aria-label': 'Save a clip', hidden: true });

  // The bridge's label (name, date and time) burned into the saved clip: on by default; off saves the camera's video untouched (faster).
  let labels = readLabels();
  const choosing = () => startMs !== null;
  const list = () => cameras();
  const single = () => list().length === 1;
  const selected = () => list().filter((camera) => single() || chosen.has(camera.id));
  const includes = (id) => (single() && list()[0].id === id) || chosen.has(id);
  const range = () => { const end = endMs(); return startMs === null ? null : { from: Math.min(startMs, end), to: Math.max(startMs, end) }; };

  function begin() {
    if (status?.kind === 'saving') return;
    status = null;
    startMs = endMs();
    chosen = new Set();           // on the wall, the person ticks the cameras; one camera on the wall is the clip's
    plans = new Map();
    planKey = '';
    changed();
  }

  function cancel() {
    startMs = null;
    status = null;
    plans = new Map();
    planKey = '';
    clearTimeout(planTimer);
    planToken += 1;
    changed();
  }

  function toggle(id) {
    if (!choosing()) return;
    if (single() || !list().some((camera) => camera.id === id)) return;
    if (chosen.has(id)) chosen.delete(id); else chosen.add(id);
    planKey = '';
    changed();
  }

  function selectAll(on) { chosen = on ? new Set(list().map((camera) => camera.id)) : new Set(); planKey = ''; changed(); }

  function changed() { draw(); onChange(); }

  /** Asks for the plan of every chosen camera once the end has settled; called by the owner as the page redraws. */
  function tick() {
    if (!choosing() || destroyed) return;
    const r = range();
    if (r.to - r.from < MINIMUM_MS) { if (planKey !== 'short') { planKey = 'short'; plans = new Map(); draw(); } return; }
    if (!selected().length) { if (planKey !== 'none') { planKey = 'none'; plans = new Map(); draw(); } return; }
    const key = `${Math.round(r.from / 1000)}:${Math.round(r.to / 1000)}:${selected().map((camera) => camera.id).join(',')}`;
    if (key === planKey) return;
    planKey = key;
    clearTimeout(planTimer);
    const token = ++planToken;
    planTimer = setTimeout(() => planAll(token, r, selected()), PLAN_DELAY_MS);
    draw();
  }

  async function planAll(token, r, cams) {
    const next = new Map();
    for (const camera of cams) {
      if (token !== planToken || destroyed) return;
      try {
        next.set(camera.id, { ok: true, plan: await get(`nvr/cameras/${camera.id}/clip-plan?from=${Math.round(r.from)}&to=${Math.round(r.to)}&tz=${encodeURIComponent(zone)}`) });
      } catch (error) {
        next.set(camera.id, { ok: false, message: error.message || 'The clip can’t be planned.', status: error.status });
      }
    }
    if (token !== planToken || destroyed) return;
    plans = next;
    draw();
  }

  function totals() {
    let size = 0, parts = 0, problems = [], notes = [], quiet = [];
    for (const camera of selected()) {
      const planned = plans.get(camera.id);
      if (!planned) continue;
      if (!planned.ok) { (planned.status === 404 ? quiet : problems).push(planned.status === 404 ? camera.name : `${camera.name}: ${planned.message}`); continue; }
      size += planned.plan.bytes;
      parts += planned.plan.parts.length;
      if (planned.plan.soundOmitted) notes.push(WORDS.sound);
      for (const gap of planned.plan.gaps) {
        notes.push(gap.held
          ? `${camera.name}: the picture stays still from ${timeFormat.format(gap.from)} to ${timeFormat.format(gap.to)} (nothing was recorded).`
          : `${camera.name} had no recording from ${timeFormat.format(gap.from)} to ${timeFormat.format(gap.to)}; the clip skips it.`);
      }
    }
    return { size, parts, problems, notes: [...new Set(notes)], quiet };
  }

  function draw() {
    if (destroyed) return;
    button.setAttribute('aria-pressed', String(choosing()));
    if (!choosing() && !status) { el.hidden = true; replace(el); return; }
    el.hidden = false;
    if (status && !choosing()) { replace(el, h('span', { class: status.kind === 'failed' ? 'nvr-clip-failed' : '' }, status.text), h('button', { class: 'btn small', type: 'button', onclick: () => { status = null; draw(); } }, 'OK')); return; }
    const r = range();
    const short = r.to - r.from < MINIMUM_MS;
    const t = totals();
    const none = selected().length === 0;
    const waiting = !short && !none && plans.size === 0;
    const canExport = !short && !none && !waiting && t.parts > 0 && status?.kind !== 'saving';
    const cams = list();
    const lines = [];
    if (short) lines.push(WORDS.tooShort);
    else if (none) lines.push('Tick the cameras to save this clip for.');
    else if (waiting) lines.push(WORDS.planning);
    else {
      if (t.quiet.length) lines.push(t.quiet.length === selected().length ? WORDS.nothing : `${t.quiet.join(', ')}: ${WORDS.nothing.toLowerCase()}`);
      lines.push(...t.problems, ...t.notes);
    }
    replace(el,
      h('div', { class: 'nvr-clip-main' },
        icon('scissors'),
        h('strong', null, rangeText(r.from, r.to)),
        h('span', { class: 'muted' }, durationText(r.to - r.from)),
        t.size > 0 ? h('span', { class: 'muted' }, bytes(t.size)) : null,
        h('span', { class: 'nvr-clip-spacer' }),
        cams.length === 1 ? h('span', { class: 'muted small' }, cams[0].name) : null,
        h('label', { class: 'nvr-clip-labels', title: 'Burns the camera’s name and the date and time into the clip, the way the Monitor shows them. Takes longer to save.' },
          h('input', { type: 'checkbox', checked: labels, onchange: (event) => {
            labels = event.target.checked;
            try { localStorage.setItem('cb.clip.labels', labels ? '1' : '0'); } catch { /* not kept */ }
          } }), ' Name and time on the clip'),
        h('button', { class: 'btn small', type: 'button', onclick: cancel, title: 'Stop choosing a clip (Esc)' }, 'Cancel'),
        h('button', { class: 'btn small primary', type: 'button', disabled: !canExport, onclick: exportClip, title: 'Save the clip (Return)' }, 'Export clip')),
      cams.length > 1 ? h('div', { class: 'nvr-clip-cams', role: 'group', 'aria-label': 'Cameras in the clip' },
        cams.map((camera) => h('label', { class: 'nvr-clip-cam' },
          h('input', { type: 'checkbox', checked: chosen.has(camera.id), onchange: () => toggle(camera.id) }), ` ${camera.name}`)),
        h('button', { class: 'btn small', type: 'button', onclick: () => selectAll(selected().length < cams.length) }, selected().length < cams.length ? 'All' : 'None')) : null,
      h('p', { class: 'small muted nvr-clip-hint' }, 'Move the playhead to where the clip should end. It starts up to a few seconds before your start, on a key picture.'),
      lines.map((line) => h('p', { class: 'small nvr-clip-line' }, line)),
      status ? h('p', { class: 'small nvr-clip-line' }, status.text) : null);
  }

  async function exportClip() {
    const r = range();
    if (!r || r.to - r.from < MINIMUM_MS || status?.kind === 'saving') return;
    const files = [];
    for (const camera of selected()) {
      const planned = plans.get(camera.id);
      if (!planned?.ok) continue;
      for (const part of planned.plan.parts) files.push(clipUrl(camera.id, r.from, r.to, part.index, zone, labels));
    }
    if (files.length === 0) return;
    status = { kind: 'saving', text: files.length === 1 ? 'Saving the clip. Your browser shows the download.' : `Saving ${files.length} clips. Your browser may ask to allow several downloads.` };
    draw();
    for (const [index, url] of files.entries()) {
      if (destroyed) return;
      download(url);
      if (index < files.length - 1) await new Promise((resolve) => setTimeout(resolve, DOWNLOAD_GAP_MS));
    }
    status = { kind: 'saved', text: files.length === 1 ? 'The clip is being saved by your browser.' : `${files.length} clips are being saved by your browser.` };
    startMs = null;
    changed();
  }

  /** C, Esc and Return; true when the key was used. `event.target` buttons keep their own Return. */
  function key(event) {
    if (event.metaKey || event.ctrlKey || event.altKey) return false;
    const k = event.key;
    if ((k === 'c' || k === 'C') && !event.shiftKey) { begin(); return true; }
    if (!choosing()) return false;
    if (k === 'Escape') { cancel(); return true; }
    if (k === 'Enter' && !event.target?.closest?.('button, a[href]')) { exportClip(); return true; }
    return false;
  }

  function destroy() { destroyed = true; clearTimeout(planTimer); planToken += 1; }

  draw();
  return { el, button, choosing, begin, cancel, toggle, includes, exportClip, key, tick, destroy };
}

function startDownload(url) {
  const link = h('a', { href: url, download: '', hidden: true });
  document.body.append(link);
  link.click();
  link.remove();
}
