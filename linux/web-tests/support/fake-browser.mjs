// Just enough of a browser for Node to import and start the page's modules: a small DOM (nodes, elements, text, events, class lists),
// storage that can be switched off, a location, timers' neighbours (requestAnimationFrame), and a `fetch` that refuses. It is not a
// browser: nothing is laid out and nothing is parsed. Pure modules need none of it; screens that build elements may use it in tests.

export class FakeNode {
  constructor() { this.childNodes = []; this.parentNode = null; }
  get firstChild() { return this.childNodes[0] ?? null; }
  get lastChild() { return this.childNodes.at(-1) ?? null; }
  get children() { return this.childNodes.filter((node) => node instanceof FakeElement); }
  get isConnected() { let node = this; while (node.parentNode) node = node.parentNode; return node === document; }
  contains(node) { for (let at = node; at; at = at.parentNode) if (at === this) return true; return false; }
  append(...nodes) { for (const node of nodes) this.appendChild(typeof node === 'string' ? new FakeText(node) : node); }
  appendChild(node) { node.parentNode?.removeChild(node); node.parentNode = this; this.childNodes.push(node); return node; }
  insertBefore(node, before) {
    if (!before) return this.appendChild(node);
    if (before.parentNode !== this) throw new DOMException('The node before which the new node is to be inserted is not a child of this node.', 'NotFoundError');
    node.parentNode?.removeChild(node);
    this.childNodes.splice(this.childNodes.indexOf(before), 0, node);
    node.parentNode = this;
    return node;
  }
  removeChild(node) { const at = this.childNodes.indexOf(node); if (at >= 0) { this.childNodes.splice(at, 1); node.parentNode = null; } return node; }
  remove() { this.parentNode?.removeChild(this); }
  after(...nodes) {
    const parent = this.parentNode;
    if (!parent) return;
    const items = nodes.map((node) => (typeof node === 'string' ? new FakeText(node) : node));
    for (const node of items) node.parentNode?.removeChild(node);
    parent.childNodes.splice(parent.childNodes.indexOf(this) + 1, 0, ...items);
    for (const node of items) node.parentNode = parent;
  }
  get textContent() { return this.childNodes.map((node) => node.textContent).join(''); }
  set textContent(value) { this.childNodes.splice(0).forEach((node) => { node.parentNode = null; }); if (value) this.appendChild(new FakeText(String(value))); }
}

export class FakeText extends FakeNode {
  constructor(data) { super(); this.data = data; }
  get textContent() { return this.data; }
  set textContent(value) { this.data = String(value); }
}

export class FakeElement extends FakeNode {
  constructor(tagName) {
    super();
    this.tagName = tagName.toUpperCase();
    this.attributes = new Map();
    this.listeners = new Map();
    this.dataset = {};
    this.style = {};
    this.className = '';
    this.hidden = false;
    const element = this;
    this.classList = {
      add: (...names) => { element.className = [...new Set([...element.className.split(/\s+/).filter(Boolean), ...names])].join(' '); },
      remove: (...names) => { element.className = element.className.split(/\s+/).filter((name) => name && !names.includes(name)).join(' '); },
      toggle: (name, force) => { const has = element.className.split(/\s+/).includes(name); const want = force ?? !has; element.classList[want ? 'add' : 'remove'](name); return want; },
      contains: (name) => element.className.split(/\s+/).includes(name),
    };
  }
  get localName() { return this.tagName.toLowerCase(); }
  setAttribute(name, value) { this.attributes.set(name, String(value)); if (name === 'class') this.className = String(value); }
  getAttribute(name) { return this.attributes.has(name) ? this.attributes.get(name) : null; }
  removeAttribute(name) { this.attributes.delete(name); }
  hasAttribute(name) { return this.attributes.has(name); }
  addEventListener(type, fn) { if (!this.listeners.has(type)) this.listeners.set(type, new Set()); this.listeners.get(type).add(fn); }
  removeEventListener(type, fn) { this.listeners.get(type)?.delete(fn); }
  dispatchEvent(event) { for (const fn of this.listeners.get(event.type) ?? []) fn(event); return true; }
  focus() {}
  blur() {}
  click() { this.dispatchEvent({ type: 'click', target: this }); }
  querySelector() { return null; }
  querySelectorAll() { return []; }
  showModal() { this.open = true; }
  close() { this.open = false; this.dispatchEvent({ type: 'close' }); }
  getBoundingClientRect() { return { x: 0, y: 0, left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 }; }
}

/** localStorage that works, or that throws on every call (a private window, blocked site data). */
export function makeStorage({ broken = false } = {}) {
  const data = new Map();
  const guard = (fn) => (...args) => { if (broken) throw new DOMException('The operation is insecure.', 'SecurityError'); return fn(...args); };
  return {
    getItem: guard((key) => (data.has(key) ? data.get(key) : null)),
    setItem: guard((key, value) => { data.set(key, String(value)); }),
    removeItem: guard((key) => { data.delete(key); }),
    clear: guard(() => data.clear()),
    get length() { return data.size; },
  };
}

let document = null;

/**
 * Puts the fake browser on `target` (globalThis) and returns it with a `restore()`. `fetch` rejects like a bridge that is not there, so a
 * module that starts talking at once ends in its own "Can't reach the bridge" path instead of hanging.
 */
export function installFakeBrowser(target = globalThis, { storage = makeStorage(), hash = '' } = {}) {
  const saved = {};
  const define = (name, value) => { saved[name] = Object.getOwnPropertyDescriptor(target, name); Object.defineProperty(target, name, { value, configurable: true, writable: true }); };
  const registered = new Map();
  document = Object.assign(new FakeElement('#document'), {
    createElement: (tag) => new FakeElement(tag),
    createElementNS: (namespace, tag) => new FakeElement(tag),
    createTextNode: (data) => new FakeText(data),
    getElementById: (id) => { if (!registered.has(id)) { const el = new FakeElement('div'); el.setAttribute('id', id); registered.set(id, el); } return registered.get(id); },
    title: '',
    hidden: false,
    visibilityState: 'visible',
    head: new FakeElement('head'),
    body: new FakeElement('body'),
    documentElement: new FakeElement('html'),
  });
  document.isConnectedRoot = true;
  const location = { hash, hostname: '127.0.0.1', host: '127.0.0.1:8090', origin: 'http://127.0.0.1:8090', protocol: 'http:', pathname: '/', reload() {} };
  const windowObject = Object.assign(new FakeElement('#window'), { document, location, innerWidth: 1100, innerHeight: 800, devicePixelRatio: 1, scrollTo() {}, isSecureContext: false, matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }) });
  define('window', windowObject);
  define('document', document);
  define('Node', FakeNode);
  define('Element', FakeElement);
  define('HTMLElement', FakeElement);
  define('location', location);
  define('localStorage', storage);
  define('sessionStorage', makeStorage());
  define('requestAnimationFrame', (fn) => setTimeout(() => fn(performance.now()), 16));
  define('cancelAnimationFrame', (id) => clearTimeout(id));
  define('DOMParser', class { parseFromString() { return { documentElement: null, querySelector: () => null }; } });
  define('EventSource', class { constructor() { this.closed = false; } addEventListener() {} close() { this.closed = true; } });
  define('fetch', async () => { throw new TypeError('fetch failed (no bridge in this test)'); });
  if (!target.navigator) define('navigator', { userAgent: 'node', clipboard: undefined });
  return {
    document,
    restore() { for (const [name, descriptor] of Object.entries(saved)) { if (descriptor) Object.defineProperty(target, name, descriptor); else delete target[name]; } },
  };
}
