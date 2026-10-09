// The log, live: the bridge's own words about what it is doing, newest at the bottom.
import { h, replace } from '../dom.js';
import { icon } from '../icons.js';
import { clock } from '../format.js';
import { store } from '../store.js';

const MAX_LINES = 2000;

export function renderLogs() {
  let level = 'info';
  let search = '';
  let camera = '';
  let paused = false;
  let source = null;
  const lines = [];
  const view = h('div', { class: 'log-view', tabindex: '0', role: 'log', 'aria-label': 'Log lines', 'aria-live': 'off' });
  const empty = h('p', { class: 'muted small' }, 'Waiting for log lines…');
  const status = h('span', { class: 'small muted', role: 'status' });
  let stick = true;

  view.addEventListener('scroll', () => { stick = view.scrollTop + view.clientHeight >= view.scrollHeight - 24; });

  function cameraName(id) {
    return id ? store.cameras.get(id)?.name || id.slice(0, 8) : '';
  }

  function matches(line) {
    if (camera && line.cameraID !== camera) return false;
    if (!search) return true;
    const text = `${line.category} ${line.message} ${cameraName(line.cameraID)}`.toLowerCase();
    return text.includes(search.toLowerCase());
  }

  function lineElement(line) {
    const name = cameraName(line.cameraID);
    return h('div', { class: `log-line ${line.level}` },
      h('span', { class: 't' }, clock(line.date)), h('span', { class: 'lv' }, line.level), h('span', { class: 'c' }, name ? `${line.category} · ${name}` : line.category), h('span', { class: 'm' }, line.message));
  }

  function renderAll() {
    const shown = lines.filter(matches);
    replace(view, shown.length ? shown.map(lineElement) : empty);
    if (stick) view.scrollTop = view.scrollHeight;
    replace(status, paused ? 'Paused. New lines are held back.' : `${shown.length} line${shown.length === 1 ? '' : 's'}`);
  }

  const pending = [];
  function add(line) {
    if (paused) { pending.push(line); return; }
    lines.push(line);
    if (lines.length > MAX_LINES) lines.splice(0, lines.length - MAX_LINES);
    if (matches(line)) {
      if (view.firstChild === empty) replace(view);
      view.append(lineElement(line));
      while (view.children.length > MAX_LINES) view.firstChild.remove();
      if (stick) view.scrollTop = view.scrollHeight;
      replace(status, `${lines.filter(matches).length} lines`);
    }
  }

  function connect() {
    source?.close();
    lines.length = 0;
    pending.length = 0;
    replace(view, empty);
    source = new EventSource(`/api/v1/logs?limit=500&level=${level}`);
    source.addEventListener('log', (event) => { try { add(JSON.parse(event.data)); } catch { /* skip a damaged line */ } });
    source.addEventListener('open', () => renderAll());
  }

  const levelSelect = h('select', { 'aria-label': 'Detail', onchange: (e) => { level = e.target.value; connect(); } },
    [['error', 'Errors'], ['warning', 'Warnings and up'], ['notice', 'Notices and up'], ['info', 'Normal'], ['debug', 'Everything']].map(([v, t]) => h('option', { value: v, selected: v === level }, t)));
  const cameraSelect = h('select', { 'aria-label': 'Camera', onchange: (e) => { camera = e.target.value; renderAll(); } },
    h('option', { value: '' }, 'All cameras'), [...store.cameras.values()].map((c) => h('option', { value: c.id }, c.name)));
  const searchInput = h('input', { type: 'search', placeholder: 'Search the log', 'aria-label': 'Search the log', oninput: (e) => { search = e.target.value; renderAll(); } });
  const pauseButton = h('button', { class: 'btn small', type: 'button', onclick: () => {
    paused = !paused;
    if (!paused) { for (const line of pending.splice(0)) add(line); }
    replace(pauseButton, icon(paused ? 'play' : 'pause'), paused ? 'Resume' : 'Pause');
    renderAll();
  } }, icon('pause'), 'Pause');

  connect();
  return {
    el: h('div', null,
      h('div', { class: 'page-head' }, h('h1', null, 'Log'),
        h('div', { class: 'actions' }, h('a', { class: 'btn small', href: '/api/v1/diagnostics', download: '' }, icon('download'), 'Download diagnostics'))),
      h('p', { class: 'lede' }, 'What the bridge is doing, as it happens. Passwords and tokens never appear here.'),
      h('div', { class: 'log-toolbar' }, levelSelect, cameraSelect, searchInput, pauseButton,
        h('button', { class: 'btn small ghost', type: 'button', onclick: () => { lines.length = 0; renderAll(); } }, 'Clear view'), status),
      view),
    destroy() { source?.close(); },
  };
}
