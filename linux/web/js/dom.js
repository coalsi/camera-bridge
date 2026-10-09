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

/** Collects a line of text (for example a new name), or several lines with `multiline`. Resolves the text, or undefined when cancelled. */
export function promptDialog({ title, body, label, value = '', confirm = 'Save', type = 'text', autocomplete = 'off', multiline = false, placeholder = null }) {
  return modal((close) => {
    const input = multiline
      ? h('textarea', { id: 'prompt-input', value, autocomplete, autofocus: true, rows: 5, spellcheck: 'false', placeholder })
      : h('input', { type, id: 'prompt-input', value, autocomplete, autofocus: true, placeholder });
    return h('form', { onsubmit: (e) => { e.preventDefault(); close(input.value); } },
      h('h2', null, title),
      body ? h('p', { class: 'muted' }, body) : null,
      h('div', { class: 'field' }, h('label', { for: 'prompt-input' }, label), input),
      h('div', { class: 'buttons' },
        h('button', { class: 'btn', type: 'button', onclick: () => close(undefined) }, 'Cancel'),
        h('button', { class: 'btn primary', type: 'submit' }, confirm)));
  }, { label: title });
}

/**
 * Asks for a typed sentence before something that erases data. The button stays off until the text typed is exactly `phrase`
 * (the system checks the same sentence again). Resolves true when confirmed.
 */
export function phraseDialog({ title, body, phrase, confirm = 'Confirm' }) {
  return modal((close) => {
    const input = h('input', { type: 'text', id: 'phrase-input', autocomplete: 'off', autocapitalize: 'off', spellcheck: 'false', autofocus: true, 'aria-describedby': 'phrase-text' });
    const go = h('button', { class: 'btn danger', type: 'submit', disabled: true }, confirm);
    input.addEventListener('input', () => { go.disabled = input.value !== phrase; });
    return h('form', { onsubmit: (e) => { e.preventDefault(); if (input.value === phrase) close(true); } },
      h('h2', null, title),
      h('div', { class: 'muted' }, body),
      h('p', { class: 'muted' }, 'Type this sentence exactly to go on:'),
      h('code', { class: 'phrase', id: 'phrase-text' }, phrase),
      h('div', { class: 'field' }, h('label', { for: 'phrase-input', class: 'sr-only' }, 'The sentence'), input),
      h('div', { class: 'buttons' },
        h('button', { class: 'btn', type: 'button', onclick: () => close(false) }, 'Cancel'), go));
  }, { label: title }).then((value) => value === true);
}

export function spinner() {
  return h('span', { class: 'spinner', role: 'status', 'aria-label': 'Working' });
}
