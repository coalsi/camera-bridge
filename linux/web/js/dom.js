// Tiny DOM helpers. Everything is built with the DOM API (never innerHTML), so nothing a camera or a log line says can become markup.

const SVG_NS = 'http://www.w3.org/2000/svg';

/** h('div', { class: 'card', onclick }, 'text', [child, child]) */
export function h(tag, attrs, ...children) {
  const el = document.createElement(tag);
  for (const [name, value] of Object.entries(attrs || {})) {
    if (value === undefined || value === null || value === false) continue;
    if (name === 'class') el.className = value;
    else if (name.startsWith('on') && typeof value === 'function') el.addEventListener(name.slice(2).toLowerCase(), value);
    else if (name === 'value' || name === 'checked' || name === 'disabled' || name === 'selected' || name === 'hidden' || name === 'open') el[name] = value;
    else if (name === 'dataset') Object.assign(el.dataset, value);
    else el.setAttribute(name, value === true ? '' : String(value));
  }
  append(el, children);
  return el;
}

export function append(parent, children) {
  for (const child of children.flat(Infinity)) {
    if (child === null || child === undefined || child === false) continue;
    parent.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return parent;
}

export function clear(el) {
  while (el.firstChild) el.removeChild(el.firstChild);
  return el;
}

export function replace(el, ...children) {
  clear(el);
  return append(el, children);
}

export function svg(tag, attrs, ...children) {
  const el = document.createElementNS(SVG_NS, tag);
  for (const [name, value] of Object.entries(attrs || {})) el.setAttribute(name, String(value));
  append(el, children);
  return el;
}

/** The server's QR code (an SVG document string) as a node, parsed rather than injected. */
export function parseSVG(text) {
  const doc = new DOMParser().parseFromString(text, 'image/svg+xml');
  const root = doc.documentElement;
  if (!root || root.localName !== 'svg' || doc.querySelector('parsererror')) return document.createTextNode('');
  for (const bad of root.querySelectorAll('script, foreignObject, image, a, use')) bad.remove();
  return document.importNode(root, true);
}

export function debounce(fn, wait) {
  let timer;
  const wrapped = (...args) => {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...args), wait);
  };
  wrapped.flush = (...args) => { clearTimeout(timer); fn(...args); };
  wrapped.cancel = () => clearTimeout(timer);
  return wrapped;
}

let toastSeq = 0;
/** A short message at the bottom of the screen (announced to screen readers). */
export function toast(message, kind = '', ms = 4500) {
  const host = document.getElementById('toasts');
  if (!host) return;
  const el = h('div', { class: `toast ${kind}`, dataset: { id: String(++toastSeq) } }, message);
  host.append(el);
  while (host.children.length > 3) host.firstChild.remove();
  setTimeout(() => el.remove(), ms);
}

/** A native modal dialog. `build(close)` returns the content; resolves with whatever `close` was given. */
export function modal(build, { label } = {}) {
  return new Promise((resolve) => {
    const dialog = h('dialog', { 'aria-label': label || null });
    let result;
    const close = (value) => { result = value; dialog.close(); };
    append(dialog, [build(close)]);
    dialog.addEventListener('close', () => { dialog.remove(); resolve(result); });
    dialog.addEventListener('cancel', () => { result = undefined; });
    document.body.append(dialog);
    dialog.showModal();
    const first = dialog.querySelector('[autofocus]') || dialog.querySelector('input, select, button');
    if (first) first.focus();
  });
}

/** Asks before something that cannot be undone. Resolves true when confirmed. */
export function confirmDialog({ title, body, confirm = 'OK', cancel = 'Cancel', danger = false, requireCheck = null }) {
  return modal((close) => {
    const check = requireCheck ? h('input', { type: 'checkbox', id: 'confirm-check' }) : null;
    const go = h('button', { class: `btn ${danger ? 'danger' : 'primary'}`, type: 'button', disabled: !!requireCheck, onclick: () => close(true) }, confirm);
    if (check) check.addEventListener('change', () => { go.disabled = !check.checked; });
    return h('form', { method: 'dialog', onsubmit: (e) => e.preventDefault() },
      h('h2', null, title),
      h('div', { class: 'muted' }, body),
      requireCheck ? h('label', { class: 'check-row', for: 'confirm-check' }, check, h('span', { class: 'text' }, requireCheck)) : null,
      h('div', { class: 'buttons' },
        h('button', { class: 'btn', type: 'button', autofocus: true, onclick: () => close(false) }, cancel), go));
  }, { label: title }).then((value) => value === true);
}

/**
 * "Your Camera Bridge password": the bridge asks for it again before it erases a disk, resets itself or opens SSH. Its refusal (403
 * `password_required` or `wrong_password`, 429 after too many tries) is said under the field. -> { el, input, say(text) }
 */
function passwordField() {
  const input = h('input', { type: 'password', id: 'dialog-password', autocomplete: 'current-password', required: true, 'aria-describedby': 'dialog-password-problem' });
  const problem = h('span', { class: 'error', id: 'dialog-password-problem', role: 'alert', hidden: true });
  return {
    input,
    el: h('div', { class: 'field' }, h('label', { for: 'dialog-password' }, 'Your Camera Bridge password'), input, problem),
    say(text) { problem.textContent = text || ''; problem.hidden = !text; },
  };
}

/** A refusal about the password itself (said beside the field); anything else is said above the buttons. */
const aboutPassword = (error) => error?.status === 429 || (error?.status === 403 && (error.code === 'password_required' || error.code === 'wrong_password'));

/**
 * The confirm of a dialog that sends its request itself (`submit(password)`): the button waits meanwhile, a refusal is said in the dialog (a
 * wrong password beside the field) and the dialog stays open to try again or cancel; `done()` closes it once the bridge took the request.
 */
function submitter({ submit, go, password, problem, done }) {
  let busy = false;
  return async () => {
    if (busy) return;
    busy = true;
    go.disabled = true;
    password?.say('');
    problem.textContent = '';
    problem.hidden = true;
    try {
      await submit(password ? password.input.value : undefined);
      done();
    } catch (error) {
      const text = error?.message || 'Something went wrong.';
      if (password && aboutPassword(error)) {
        password.say(text);
        password.input.focus();
        password.input.select?.();
      } else {
        problem.textContent = text;
        problem.hidden = false;
      }
    } finally {
      busy = false;
      go.disabled = false;
    }
  };
}

/**
 * Collects a line of text (for example a new name), or several lines with `multiline`. Resolves the text, or undefined when cancelled.
 * `password`: the field for the administrator password too; `submit(text, password)`: the dialog sends the request itself and stays open on a
 * refusal (see submitter).
 */
export function promptDialog({ title, body, label, value = '', confirm = 'Save', type = 'text', autocomplete = 'off', multiline = false, placeholder = null,
  password = false, submit = null }) {
  return modal((close) => {
    const input = multiline
      ? h('textarea', { id: 'prompt-input', value, autocomplete, autofocus: true, rows: 5, spellcheck: 'false', placeholder })
      : h('input', { type, id: 'prompt-input', value, autocomplete, autofocus: true, placeholder });
    const secret = password ? passwordField() : null;
    const problem = h('p', { class: 'small dialog-problem', role: 'alert', hidden: true });
    const go = h('button', { class: 'btn primary', type: 'submit' }, confirm);
    const send = submit ? submitter({ submit: (pass) => submit(input.value, pass), go, password: secret, problem, done: () => close(input.value) }) : null;
    return h('form', { onsubmit: (e) => { e.preventDefault(); if (send) send(); else close(input.value); } },
      h('h2', null, title),
      body ? h('p', { class: 'muted' }, body) : null,
      h('div', { class: 'field' }, h('label', { for: 'prompt-input' }, label), input),
      secret?.el, problem,
      h('div', { class: 'buttons' },
        h('button', { class: 'btn', type: 'button', onclick: () => close(undefined) }, 'Cancel'), go));
  }, { label: title });
}

/**
 * Asks for a typed sentence before something that erases data. The button stays off until the text typed is exactly `phrase`
 * (the system checks the same sentence again). Resolves true when confirmed.
 * `password`: the field for the administrator password too (the button also waits for it); `submit(password)`: the dialog sends the request
 * itself, and stays open with the bridge's sentence when it refuses (a wrong password beside the field).
 */
export function phraseDialog({ title, body, phrase, confirm = 'Confirm', password = false, submit = null }) {
  return modal((close) => {
    const input = h('input', { type: 'text', id: 'phrase-input', autocomplete: 'off', autocapitalize: 'off', spellcheck: 'false', autofocus: true, 'aria-describedby': 'phrase-text' });
    const secret = password ? passwordField() : null;
    const problem = h('p', { class: 'small dialog-problem', role: 'alert', hidden: true });
    const go = h('button', { class: 'btn danger', type: 'submit', disabled: true }, confirm);
    const ready = () => input.value === phrase && (!secret || Boolean(secret.input.value));
    const check = () => { go.disabled = !ready(); };
    input.addEventListener('input', check);
    secret?.input.addEventListener('input', check);
    const send = submit ? submitter({ submit, go, password: secret, problem, done: () => close(true) }) : null;
    return h('form', { onsubmit: (e) => {
      e.preventDefault();
      if (!ready()) return;
      if (send) send(); else close(true);
    } },
      h('h2', null, title),
      h('div', { class: 'muted' }, body),
      h('p', { class: 'muted' }, 'Type this sentence exactly to go on:'),
      h('code', { class: 'phrase', id: 'phrase-text' }, phrase),
      h('div', { class: 'field' }, h('label', { for: 'phrase-input', class: 'sr-only' }, 'The sentence'), input),
      secret?.el, problem,
      h('div', { class: 'buttons' },
        h('button', { class: 'btn', type: 'button', onclick: () => close(false) }, 'Cancel'), go));
  }, { label: title }).then((value) => value === true);
}

export function spinner() {
  return h('span', { class: 'spinner', role: 'status', 'aria-label': 'Working' });
}
