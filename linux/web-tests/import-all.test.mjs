// Imports every module of the page, as a browser would at start-up (linking errors, a missing export, a syntax error, a top-level statement
// that throws), and checks that index.html points at files that exist.
//
// Every module except app.js is imported in plain Node, with no browser at all: nothing may touch `document`, `window` or `localStorage`
// while it is being imported (do it inside a function), so that the pure modules can be tested without a DOM. app.js starts the page, so it
// is imported last, in a fake browser.

import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { mock, test } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { installFakeBrowser } from './support/fake-browser.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '../web');
const urlOf = (file) => pathToFileURL(join(root, file)).href;

function modules(directory = 'js') {
  return readdirSync(join(root, directory), { withFileTypes: true }).flatMap((entry) => {
    const path = `${directory}/${entry.name}`;
    return entry.isDirectory() ? modules(path) : entry.name.endsWith('.js') ? [path] : [];
  }).sort();
}

const pure = () => modules().filter((file) => file !== 'js/app.js');

test('every module except app.js imports in plain Node: nothing touches the browser while it is being imported', async () => {
  for (const name of ['window', 'document', 'localStorage']) assert.equal(typeof globalThis[name], 'undefined', `${name} exists in this process: the test would prove nothing`);
  const files = pure();
  assert.ok(files.length >= 14, `only ${files.length} modules found under linux/web/js`);
  const failures = [];
  for (const file of files) {
    try {
      await import(urlOf(file));
    } catch (error) {
      failures.push(`${file}: ${error.name}: ${error.message}`);
    }
  }
  assert.deepEqual(failures, [], `modules that fail to import (a ReferenceError for document, window or localStorage means a statement outside any function):\n${failures.join('\n')}`);
});

test('every module except app.js exports something', async () => {
  const empty = [];
  for (const file of pure()) {
    if (Object.keys(await import(urlOf(file))).length === 0) empty.push(file);
  }
  assert.deepEqual(empty, [], 'modules without an export (a module that only has side effects belongs in app.js)');
});

test('index.html links only files that exist, and loads one module script and the theme boot script', () => {
  const html = readFileSync(join(root, 'index.html'), 'utf8');
  const references = [...html.matchAll(/\s(?:src|href)\s*=\s*["']([^"'#]+)["']/g)].map((match) => match[1]).filter((value) => value.startsWith('/'));
  assert.ok(references.includes('/js/app.js'), 'index.html does not load /js/app.js');
  const missing = references.filter((reference) => !existsSync(join(root, reference.slice(1).split('?')[0])));   // `?v=` versions a file, it is not part of its name
  assert.deepEqual(missing, [], `index.html points at missing files: ${missing.join(', ')}`);
  // One module (the page) and one plain script before the stylesheet (theme-boot.js: the chosen appearance, before the first paint).
  assert.equal([...html.matchAll(/<script\b[^>]*type="module"/g)].length, 1, 'index.html has more than one module script');
  assert.equal([...html.matchAll(/<script\b/g)].length, 2, 'index.html has a script besides the page and theme-boot.js');
  assert.match(html, /<script type="module" src="\/js\/app\.js">/);
});

test('app.js starts the page: with no bridge to talk to, it shows its own error card and asks again by itself, a little later each time', async () => {
  const browser = installFakeBrowser();
  // The page's own timers are the test's: its next try waits on one, which would otherwise keep this process open.
  mock.timers.enable({ apis: ['setTimeout'] });
  let asked = 0;
  globalThis.fetch = async () => { asked += 1; throw new TypeError('fetch failed (no bridge in this test)'); };
  const settle = async () => { for (let i = 0; i < 10; i += 1) await new Promise((resolve) => setImmediate(resolve)); };
  try {
    await import(urlOf('js/app.js'));
    await settle();
    const text = browser.document.getElementById('app').textContent;
    assert.match(text, /Can’t reach the bridge/);
    assert.match(text, /Trying again by itself/);
    assert.match(text, /Try again/);
    assert.equal(asked, 1);
    mock.timers.tick(4_999);
    await settle();
    assert.equal(asked, 1, 'not before 5 s');
    mock.timers.tick(1);
    await settle();
    assert.equal(asked, 2, 'a box that is still starting is asked again after 5 s');
    mock.timers.tick(9_999);
    await settle();
    assert.equal(asked, 2, 'then after 10 s');
    mock.timers.tick(1);
    await settle();
    assert.equal(asked, 3);
  } finally {
    mock.timers.reset();
    browser.restore();
  }
});
