// Settings › Security › Apple TV: the Apple TVs that can watch this bridge (GET viewers: { viewers: [{ id, name, device, created, lastSeen,
// address }] }, dates ISO 8601, the one used last first), each "Living Room · Apple TV 4K (3rd generation)" with "Added Oct 28, 2026, 2:00 PM ·
// last used 2 min ago from 192.0.2.40" under it, and Remove (DELETE viewers/:id, asked first). "Add an Apple TV" takes the 8 letters the TV shows
// (POST viewers/approve { code }: 201 { viewer }; 404 no_such_code, 409 too_many_viewers and 500 storage come with their own sentence, which the
// card says as it is). The TV's QR code is #/pair/<code> (PAIR_ROUTE): Settings opens at this card with the code filled in and the keyboard on
// Add (fill). The page never adds a TV by itself: a link alone must not add someone else's, so the owner presses Add. Times are the bridge's
// (store.js bridgeZone).
import { del, get, post } from '../api.js';
import { confirmDialog, h, replace } from '../dom.js';
import { dateTime } from '../format.js';
import { relativeTime } from '../notifications.js';
import { field, inlineError } from './common.js';

/** The address in an Apple TV's QR code without its `#/`: `pair/BCDF-GHJK`, the code (group 1) as typed. `pair/sensors` is the sensors bridge's. */
export const PAIR_ROUTE = /^pair\/([A-Za-z]{4}[- ]?[A-Za-z]{4})$/;

export const isPairPath = (path) => PAIR_ROUTE.test(path);

/** "BCDF-GHJK" from 8 letters in any case, whatever spaces and dashes were typed between them (any space, any dash such as an en dash, and the minus
 *  sign, as a phone's keyboard or a pasted line may make them); '' for anything else. */
export function tidyCode(text) {
  const letters = String(text ?? '').replace(/[\s\p{Pd}\u2212]/gu, '');
  return /^[A-Za-z]{8}$/.test(letters) ? `${letters.slice(0, 4)}-${letters.slice(4)}`.toUpperCase() : '';
}

const ms = (value) => (typeof value === 'number' ? value : Date.parse(value));
const nameOf = (viewer) => viewer.name || 'Apple TV';

/** "Living Room · Apple TV 4K (3rd generation)": the name and the model the TV gave (the name alone when it gave none). */
export function viewerTitle(viewer) {
  return [nameOf(viewer), viewer.device || null].filter(Boolean).join(' · ');
}

/** "Added Oct 28, 2026, 2:00 PM · last used 2 min ago from 192.0.2.40", or "… · not used yet". */
export function viewerUse(viewer, now = Date.now()) {
  const added = dateTime(ms(viewer.created));
  const at = ms(viewer.lastSeen);
  let used = 'not used yet';
  if (Number.isFinite(at)) {
    const ago = relativeTime(new Date(at).toISOString(), now);
    used = `last used ${ago === 'now' ? 'just now' : ago === 'Yesterday' ? 'yesterday' : ago}${viewer.address ? ` from ${viewer.address}` : ''}`;
  }
  return [added ? `Added ${added}` : null, used].filter(Boolean).join(' · ');
}

/**
 * The card -> { el, refresh(), fill(code), destroy() }.
 *   load()         GET viewers; approve(code) POST viewers/approve; remove(id) DELETE viewers/:id; confirm(question) asks
 *   onApproved()   a TV was added (Settings leaves the #/pair address, so a reload does not fill the code again)
 *   fill(code)     puts the code a link carried in the field, as ABCD-EFGH, with the keyboard on Add; it adds nothing
 */
export function createViewersCard({ load = () => get('viewers'), approve = (code) => post('viewers/approve', { code }),
  remove = (id) => del('viewers/' + encodeURIComponent(id)), confirm = confirmDialog, now = () => Date.now(), onApproved = () => {} } = {}) {
  const list = h('ul', { class: 'viewer-list stack', hidden: true });
  const empty = h('p', { class: 'small muted viewer-empty', hidden: true }, 'No Apple TV is added yet.');   // said only once the list was read
  const code = h('input', { type: 'text', placeholder: 'BCDF-GHJK', autocomplete: 'off', autocapitalize: 'characters', autocorrect: 'off', spellcheck: 'false' });
  const add = h('button', { class: 'btn', type: 'submit' }, 'Add');
  const problem = h('div', { class: 'viewer-problem', hidden: true });   // what went wrong, as a banner between the field and its button, as the password card does
  const form = h('form', { class: 'viewer-add', onsubmit: (event) => { event.preventDefault(); send(); } },
    field('Add an Apple TV', code, { hint: 'Open Camera Bridge on the Apple TV and enter the code it shows.' }), problem, add);
  const status = h('p', { class: 'small muted viewer-status', role: 'status' });
  const el = h('section', { class: 'card viewers-card', 'aria-labelledby': 'viewers-heading' },
    h('h2', { id: 'viewers-heading' }, 'Apple TV'),
    h('p', { class: 'desc' }, 'Apple TVs with the Camera Bridge app. Each one can watch your cameras, live and recorded, and move cameras that pan and tilt. It can’t change anything else, and it never needs the password.'),
    list, empty, form, status);
  let viewers = [];
  let busy = false;       // an approval is out: Add is dimmed (aria-disabled, which keeps the keyboard on it) and presses are ignored
  let destroyed = false;

  function sayProblem(text) {
    replace(problem, text ? inlineError(text) : null);
    problem.hidden = !text;
  }

  function row(viewer) {
    return h('li', { class: 'viewer-item row spread', dataset: { id: viewer.id } },
      h('div', { class: 'viewer-text' },
        h('strong', { class: 'viewer-title' }, viewerTitle(viewer)),
        h('div', { class: 'small muted viewer-use' }, viewerUse(viewer, now()))),
      h('button', { class: 'btn small', type: 'button', 'aria-label': `Remove ${nameOf(viewer)}`, onclick: () => end(viewer) }, 'Remove'));
  }

  function draw() {
    if (destroyed) return;
    replace(list, viewers.map(row));
    list.hidden = viewers.length === 0;
    empty.hidden = viewers.length > 0;
  }

  async function refresh() {
    try {
      const answer = await load();
      if (destroyed) return;
      viewers = Array.isArray(answer?.viewers) ? answer.viewers : [];
      sayProblem('');
      draw();
    } catch (error) {
      if (!destroyed) sayProblem(error?.message || 'The Apple TVs can’t be read right now.');
    }
  }

  /** Add: the code in the field goes to the bridge. A refusal (no such code, too many TVs, no room on the disk) is said and the code stays. */
  async function send() {
    if (busy || destroyed) return;
    sayProblem('');
    status.textContent = '';
    const letters = tidyCode(code.value);
    if (!letters) { sayProblem('Enter the 8 letters the Apple TV shows.'); return; }
    busy = true;
    add.setAttribute('aria-disabled', 'true');
    let answer;
    try {
      answer = await approve(letters);
    } catch (error) {
      if (!destroyed) sayProblem(error?.message || 'That Apple TV couldn’t be added.');
      return;
    } finally {
      busy = false;
      add.removeAttribute('aria-disabled');
    }
    if (destroyed) return;
    code.value = '';
    status.textContent = `${nameOf(answer?.viewer ?? {})} can watch your cameras now.`;
    onApproved(answer?.viewer);
    await refresh();
  }

  async function end(viewer) {
    const sure = await confirm({ title: `Remove ${nameOf(viewer)}?`, body: `${viewerTitle(viewer)}. It stops showing your cameras at once and needs a new code to come back.`, confirm: 'Remove', danger: true });
    if (!sure || destroyed) return;
    try {
      await remove(viewer.id);
    } catch (error) {
      if (error?.status !== 404) { sayProblem(error?.message || 'That Apple TV couldn’t be removed.'); return; }   // 404: it is gone already
    }
    viewers = viewers.filter((other) => other.id !== viewer.id);
    sayProblem('');
    status.textContent = '';
    draw();
    refresh();
  }

  function fill(text) {
    const letters = tidyCode(text);
    if (!letters || destroyed) return;
    code.value = letters;
    add.focus({ preventScroll: true });
  }

  refresh();
  return { el, refresh, fill, destroy() { destroyed = true; } };
}
