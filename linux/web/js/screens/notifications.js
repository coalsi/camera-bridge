// The Notifications page: everything that was a notification, newest first, kept by the bridge (a log of the last 500 or 90 days), so an
// old one is still readable after the notice itself is gone. A filter by section, "Mark all as read", and opening the page marks what it
// shows as read (the unread ones stay marked while the page is open, so you can see what was new).
import { get, post } from '../api.js';
import { h, replace, toast } from '../dom.js';
import { icon } from '../icons.js';
import { notificationActions, notificationIcon, relativeTime, setUnread } from '../notifications.js';
import { subscribe } from '../store.js';

export const SECTIONS = [
  { id: 'all', label: 'All' },
  { id: 'security', label: 'Security' },
  { id: 'recording', label: 'Recording' },
  { id: 'cameras', label: 'Cameras' },
  { id: 'system', label: 'System' },
];

const EMPTY = {
  all: 'Nothing yet. When Camera Bridge has something to tell you, it shows here and slides in for a few seconds.',
};

export function renderNotifications() {
  let entries = [];
  let section = 'all';
  let loaded = false;
  let failed = '';
  let destroyed = false;
  const wasUnread = new Set();   // marked while this page is open, whatever the bridge says now

  const filters = h('div', { class: 'notif-filters', role: 'group', 'aria-label': 'Show' });
  const list = h('div', { class: 'notif-list' });
  const markAll = h('button', { class: 'btn', type: 'button', onclick: () => markRead(null) }, 'Mark all as read');

  function shownEntries() {
    return section === 'all' ? entries : entries.filter((entry) => entry.category === section);
  }

  function item(entry) {
    const actions = notificationActions(entry);
    const unread = wasUnread.has(entry.id);
    return h('article', { class: `card notif-item ${entry.severity === 'warning' ? 'warning' : 'info'}${unread ? ' unread' : ''}` },
      icon(notificationIcon(entry)),
      h('div', { class: 'notif-text' },
        h('div', { class: 'notif-head' }, h('span', { class: 'notif-title' }, entry.title),
          h('time', { class: 'notif-time', datetime: entry.date, title: new Date(entry.date).toLocaleString() }, relativeTime(entry.date))),
        h('p', { class: 'notif-detail' }, entry.detail),
        actions.length ? h('div', { class: 'actions' }, h('button', { class: 'btn small', type: 'button', onclick: actions[0].run }, actions[0].label)) : null));
  }

  function draw() {
    replace(filters, SECTIONS.map(({ id, label }) => h('button', {
      class: `chip${id === section ? ' on' : ''}`, type: 'button', 'aria-pressed': String(id === section), onclick: () => { section = id; draw(); } }, label)));
    markAll.hidden = !entries.some((entry) => !entry.read);
    const shown = shownEntries();
    if (!loaded) replace(list, h('p', { class: 'muted', role: 'status' }, failed || 'Loading…'));
    else if (!shown.length) {
      replace(list, h('div', { class: 'empty card' }, h('h2', null, 'Nothing yet'),
        h('p', null, section === 'all' ? EMPTY.all : `Nothing in ${SECTIONS.find((s) => s.id === section).label} yet.`)));
    } else replace(list, shown.map(item));
  }

  async function markRead(ids) {
    try {
      const answer = await post('notifications/read', ids ? { ids } : {});
      setUnread(answer?.unread);
      if (!ids) for (const entry of entries) entry.read = true;
      else for (const entry of entries) if (ids.includes(entry.id)) entry.read = true;
      if (!destroyed) draw();
    } catch (error) {
      toast(error.message, 'error');
    }
  }

  async function load({ first = false } = {}) {
    try {
      const answer = await get('notifications');
      if (destroyed) return;
      entries = Array.isArray(answer?.notifications) ? answer.notifications : [];
      loaded = true;
      failed = '';
      setUnread(answer?.unread);
      const fresh = entries.filter((entry) => !entry.read);
      for (const entry of fresh) wasUnread.add(entry.id);
      draw();
      if (fresh.length) await markRead(fresh.map((entry) => entry.id));
    } catch (error) {
      if (destroyed) return;
      if (first) failed = error.message;
      draw();
    }
  }

  const el = h('div', null,
    h('div', { class: 'page-head' }, h('h1', null, 'Notifications'), h('div', { class: 'actions' }, markAll)),
    filters, list);
  draw();
  load({ first: true });
  // A new notification while the page is open joins the list.
  const stop = subscribe((kind) => { if (kind === 'notices') load(); });
  return { el, destroy() { destroyed = true; stop(); } };
}
