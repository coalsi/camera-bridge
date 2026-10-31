// Settings › Security: the browsers signed in to this bridge (GET auth/sessions: { sessions: [{ id, browser, address, created, lastSeen,
// current }] }, the one used last first), each "Safari on iPhone · 192.0.2.31 · last seen 2 min ago" with "This browser" on the one in use,
// and Sign out (DELETE auth/sessions/:id, asked first). Signing this browser out takes the page back to the sign-in page. Times in the tooltips
// are the bridge's (store.js bridgeZone).
import { del, get } from '../api.js';
import { confirmDialog, h, replace } from '../dom.js';
import { dateTime } from '../format.js';
import { relativeTime } from '../notifications.js';

const ms = (value) => (typeof value === 'number' ? value : Date.parse(value));

/** "Safari on iPhone · 192.0.2.31 · last seen 2 min ago" (no address for a browser signed in before addresses were kept). */
export function sessionLine(session, now = Date.now()) {
  const at = ms(session.lastSeen);
  const seen = Number.isFinite(at) ? relativeTime(new Date(at).toISOString(), now) : '';
  return [session.browser || 'A browser', session.address || null, seen ? `last seen ${seen === 'now' ? 'just now' : seen}` : null].filter(Boolean).join(' · ');
}

/**
 * The card -> { el, refresh(), destroy() }.
 *   load()         GET auth/sessions; signOut(id) DELETE auth/sessions/:id; confirm(question) asks
 *   signedOut()    this browser was signed out: back to the sign-in page
 */
export function createSessionsCard({ load = () => get('auth/sessions'), signOut = (id) => del(`auth/sessions/${encodeURIComponent(id)}`), confirm = confirmDialog,
  signedOut = () => { location.hash = '#/'; location.reload(); }, now = () => Date.now() } = {}) {
  const list = h('ul', { class: 'session-list' });
  const problem = h('p', { class: 'small session-problem', role: 'alert', hidden: true });
  const el = h('section', { class: 'card sessions-card', 'aria-labelledby': 'sessions-heading' },
    h('h2', { id: 'sessions-heading' }, 'Signed-in browsers'),
    h('p', { class: 'desc' }, 'Every browser that is signed in to this bridge. Sign out one you don’t know or no longer use; it needs the password to come back.'),
    problem, list);
  let sessions = [];
  let destroyed = false;

  function say(text) {
    problem.textContent = text || '';
    problem.hidden = !text;
  }

  function row(session) {
    const signedIn = Number.isFinite(ms(session.created)) ? `Signed in ${dateTime(ms(session.created))}` : '';
    const lastSeen = Number.isFinite(ms(session.lastSeen)) ? `last seen ${dateTime(ms(session.lastSeen))}` : '';
    return h('li', { class: 'session-item', dataset: { id: session.id, current: String(session.current === true) } },
      h('div', { class: 'session-text', title: [signedIn, lastSeen].filter(Boolean).join(', ') },
        h('span', { class: 'session-line' }, sessionLine(session, now())),
        session.current ? h('span', { class: 'pill live session-current' }, 'This browser') : null),
      h('button', { class: 'btn small', type: 'button', 'aria-label': `Sign out ${session.current ? 'this browser' : session.browser || 'that browser'}`, onclick: () => end(session) }, 'Sign out'));
  }

  function draw() {
    if (destroyed) return;
    replace(list, sessions.map(row));
  }

  async function refresh() {
    try {
      const answer = await load();
      if (destroyed) return;
      sessions = Array.isArray(answer?.sessions) ? answer.sessions : [];
      say('');
      draw();
    } catch (error) {
      if (!destroyed) say(error?.message || 'The signed-in browsers can’t be read right now.');
    }
  }

  async function end(session) {
    const current = session.current === true;
    const sure = await confirm(current
      ? { title: 'Sign out of this browser?', body: 'You’ll need the password to come back.', confirm: 'Sign out', danger: true }
      : { title: `Sign out ${session.browser || 'that browser'}?`, body: `${sessionLine(session, now())}. That browser needs the password to come back.`, confirm: 'Sign out', danger: true });
    if (!sure || destroyed) return;
    try {
      await signOut(session.id);
    } catch (error) {
      if (error?.status !== 404) { say(error?.message || 'That browser couldn’t be signed out.'); return; }   // 404: already signed out
    }
    if (current) { signedOut(); return; }
    sessions = sessions.filter((other) => other.id !== session.id);
    say('');
    draw();
    refresh();
  }

  refresh();
  return { el, refresh, destroy() { destroyed = true; } };
}
