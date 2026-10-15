import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { lex, lintSource, lintTree, ownedClasses } from '../web-dev/lint.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const found = (source, file = 'js/x.js') => lintSource(file, source).map((finding) => finding.rule);

test('the lexer: comments and strings are not code, template expressions and regular expressions are told apart', () => {
  assert.deepEqual(found('// el.innerHTML = x\n/* eval(1) \n el.outerHTML */ const a = 1;'), []);
  assert.deepEqual(found("const s = 'innerHTML'; const t = \"eval(1)\"; const u = 'it\\'s innerHTML';"), []);
  assert.deepEqual(found('const t = `innerHTML eval(1)`;'), [], 'template text');
  assert.deepEqual(found('const t = `a ${el.innerHTML} b`;'), ['inner-html'], 'a template expression is code');
  assert.deepEqual(found('const t = `a ${ `b ${x.outerHTML}` } c`;'), ['inner-html'], 'nested templates');
  assert.deepEqual(found('const r = /\\/\\/ innerHTML/g; el.innerHTML = 1;'), ['inner-html'], 'a regular expression is not a comment');
  assert.deepEqual(found('const q = a / b / c; el.innerHTML = 1;'), ['inner-html'], 'division is not a regular expression');
  assert.deepEqual(found('if (/innerHTML/.test(x)) { y(); }'), [], 'a regular expression after a parenthesis');
  assert.deepEqual(found('const half = total / 2; // el.innerHTML is not code'), [], 'division after an identifier, then a comment');
  assert.deepEqual(found('const q = a / b / c; const s = "x"; el.innerHTML = 1;'), ['inner-html'], 'two divisions, then code');
  assert.deepEqual(found('const w = (a + b) / 2; const z = arr[0] / 3; const n = 8 / 2; // eval(1)'), [], 'division after ) ] and a number');
  assert.deepEqual(found('function f(x) { return /innerHTML|eval\\(/.test(x); }'), [], 'a regular expression after return');
  assert.deepEqual(found("const t = typeof /x/; el.innerHTML = 1;"), ['inner-html'], 'a regular expression after typeof');
  assert.deepEqual(found("const r = x ? /[/]innerHTML/ : 1; el.innerHTML = 2;"), ['inner-html'], 'a slash inside a character class');
  const { code, bare } = lex("a = 'x'; // c\nb = `t${1}`;");
  assert.equal(code.length, "a = 'x'; // c\nb = `t${1}`;".length);
  assert.equal(code, "a = 'x';     \nb = `t${1}`;");
  assert.equal(bare, "a = ' ';     \nb = ` ${1}`;");
});

test('rules: each bad line is found by its rule, and by that one only', () => {
  const bad = {
    'inner-html': 'el.innerHTML = x;',
    'insert-adjacent-html': "el.insertAdjacentHTML('beforeend', x);",
    'document-write': 'document.write(x);',
    eval: 'const r = eval(x);',
    'new-function': "const f = new Function('a', 'return a');",
    'set-attribute-style': "el.setAttribute('style', 'color: red');",
    'inline-style-markup': "const m = '<div style=\"x\">';",
    'network-outside-api': "const r = await fetch('/x');",
    'web-codecs': "const d = new VideoDecoder({ output() {}, error() {} });",
    'secure-context-api': 'const id = crypto.randomUUID();',
    'worker-or-wasm': "const w = new Worker('/w.js');",
    'remote-module': "import('https://cdn.example/x.js');",
    'bare-import': "import lodash from 'lodash';",
    'h-style-attribute': "h('div', { class: 'a', style: 'width: 3px' }, 'x');",
  };
  for (const [rule, source] of Object.entries(bad)) assert.deepEqual(found(source), [rule], rule);
});

test('rules: lines that look similar but are fine', () => {
  const fine = [
    "el.style.width = '3px'; el.style.setProperty('--x', '1');",
    "el.setAttribute('class', 'x'); el.setAttribute('aria-label', 'style');",
    "h('div', { class: 'a', dataset: { style: 'x' } }, 'style: x');",
    "const o = { style: 'x' };",
    "api.fetch('/x'); this.fetch(1); const fetchAll = 1; fetchAll();",
    "const text = 'Use innerHTML? No.';",
    "const kind = x instanceof Function; const t = typeof Function;",
    "if (typeof MediaSource !== 'undefined') {} if (window.isSecureContext) {}",
    "const u = crypto.getRandomValues(new Uint8Array(4));",
    "import { a } from './a.js'; import('./b.js'); export { c } from '../c.js';",
    "const url = 'http://www.w3.org/2000/svg';",
    'const style = 1; const x = { style };',
  ];
  for (const source of fine) assert.deepEqual(found(source), [], source);
  assert.deepEqual(found("fetch('/x');", 'js/api.js'), [], 'js/api.js is where fetch lives');
  assert.deepEqual(found("fetch('/x');", 'js/nvr/api.js'), ['network-outside-api'], 'only that one file');
});

test('lint-allow silences a rule on its line and the next, with a reason', () => {
  assert.deepEqual(found("// lint-allow inner-html: the QR code is parsed by DOMParser first\nel.innerHTML = x;"), []);
  assert.deepEqual(found('el.innerHTML = x; // lint-allow inner-html: measured, see issue 12'), []);
  assert.deepEqual(found('// lint-allow inner-html:\nel.innerHTML = x;'), ['inner-html'], 'no reason, no allowance');
  assert.deepEqual(found('// lint-allow eval: because\nel.innerHTML = x;'), ['inner-html'], 'another rule');
  assert.deepEqual(found('// lint-allow inner-html: x\n\nel.innerHTML = x;'), ['inner-html'], 'only the next line');
});

test('findings carry the line and column', () => {
  const [finding] = lintSource('js/x.js', 'a();\n  b.innerHTML = 1;\n');
  assert.deepEqual([finding.line, finding.column, finding.rule], [2, 5, 'inner-html']);
});

test('html and css rules', () => {
  const html = '<!-- <script>x()</script> --><script>x()</script><div onclick="a()" style="x"><img src="https://x.example/a.png"><style>a{}</style><a href="javascript:void(0)">x</a><script type="module" src="/js/app.js"></script>';
  assert.deepEqual(lintSource('index.html', html).map((finding) => finding.rule).sort(), ['inline-handler', 'inline-script', 'javascript-url', 'remote-url', 'style-attribute', 'style-element']);
  assert.deepEqual(lintSource('index.html', '<link rel="stylesheet" href="/style.css"><script type="module" src="/js/app.js"></script>'), []);
  const css = '/* @import "x"; */ @import "a.css"; a { background: url(https://x.example/a.png); b: url("/mark.svg"); c: url(data:image/png;base64,AAAA) }';
  assert.deepEqual(lintSource('style.css', css).map((finding) => finding.rule), ['css-import', 'remote-url']);
});

function tree(files) {
  const root = mkdtempSync(join(tmpdir(), 'cb-lint-'));
  for (const [path, text] of Object.entries(files)) { mkdirSync(dirname(join(root, path)), { recursive: true }); writeFileSync(join(root, path), text); }
  return root;
}

test('graph: the sign-in page may not reach NVR code by a static import, a missing file is found, lite.js imports nothing', () => {
  const root = tree({
    'index.html': '<script type="module" src="/js/app.js"></script>',
    'js/app.js': "import { cameras } from './screens/cameras.js';\nimport('./screens/watch.js');\nimport './nvr/lite.js';\nimport './nope.js';",
    'js/screens/cameras.js': "import { ui } from '../nvr/ui.js';\nexport const cameras = 1;",
    'js/nvr/lite.js': "import { x } from './util.js';\nexport function hasNVR() { return import('./ui.js'); }",
    'js/nvr/util.js': 'export const x = 1;',
    'js/nvr/ui.js': "import { y } from './record.js';\nexport const ui = 1;",
    'js/nvr/record.js': 'export const y = 1;',
    'js/screens/watch.js': "import { y } from '../nvr/record.js';\nexport const watch = 1;",
  });
  try {
    const findings = lintTree(root).map((finding) => `${finding.file} ${finding.rule}`);
    assert.deepEqual(findings, [
      'js/app.js import-missing',
      'js/nvr/lite.js lazy-only', // lite.js reaches nvr/util.js at start-up
      'js/nvr/lite.js lite-imports',
      'js/screens/cameras.js lazy-only',
    ]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('graph: a lazy page that imports NVR code dynamically is fine, and so is nvr/lite.js alone', () => {
  const root = tree({
    'js/app.js': "import { hasNVR } from './nvr/lite.js';\nconst lazy = () => import('./screens/watch.js');\nimport './screens/camera.js';",
    'js/screens/camera.js': "import { hasNVR, loadNVR } from '../nvr/lite.js';\nimport { createPreview } from './preview.js';\nexport const c = 1;",
    'js/screens/preview.js': 'export const createPreview = 1;',
    'js/screens/watch.js': "import { y } from '../nvr/record.js';\nexport const w = 1;",
    'js/nvr/lite.js': "export const hasNVR = (c) => c.nvrEnabled === true;\nexport const loadNVR = () => import('./ui.js');",
    'js/nvr/ui.js': 'export const ui = 1;',
    'js/nvr/record.js': 'export const y = 1;',
  });
  try {
    assert.deepEqual(lintTree(root), []);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('stylesheets: a class styled by two of the three NVR stylesheets is found (they are linked on every page), a shared descendant is not', () => {
  const root = tree({
    'nvr-record.css': '.rec-usage { height: 8px; }\n.nvr-bar { margin: 14px 0; }\n.rec-usage .fill { width: 0; }\n@media (max-width: 600px) { .rec-note { margin: 0; } }\n',
    'nvr-watch.css': '.watch-badges .pill { color: red; }\n.nvr-problem, .watch-note { color: orange; }\n',
    'nvr-grid.css': '.nvr-bar { padding: 8px; }\n.nvr-badges .pill { color: red; }\n@keyframes spin { from { opacity: 0; } to { opacity: 1; } }\n.nvr-grid .nvr-problem { color: red; }\n',
  });
  try {
    const findings = lintTree(root);
    assert.deepEqual(findings.map((finding) => `${finding.file}:${finding.line} ${finding.rule}`), ['nvr-grid.css:1 css-class-shared']);
    assert.match(findings[0].message, /^\.nvr-bar is also styled in nvr-record\.css/);
    assert.deepEqual([...ownedClasses('.a .b, .c:hover > .d { x: 1 } @media (x) { .e .a { y: 2 } } @keyframes k { from { z: 1 } }').keys()], ['a', 'c', 'e']);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
  const clean = tree({ 'nvr-record.css': '.rec-usage { height: 8px; }\n', 'nvr-watch.css': '.watch-stage { x: 1 }\n', 'nvr-grid.css': '.nvr-tile-bar { x: 1 }\n' });
  try {
    assert.deepEqual(lintTree(clean), []);
  } finally {
    rmSync(clean, { recursive: true, force: true });
  }
});

test('the page as it is: linux/web has no findings', () => {
  const findings = lintTree(join(here, '../web'));
  assert.deepEqual(findings.map((finding) => `${finding.file}:${finding.line} ${finding.rule}`), []);
});

test('the lexer reads every JavaScript file of the page and its tools: same length, same lines, balanced brackets', () => {
  // A construct the lexer misreads (a regular expression after `}`, say) unbalances the brackets of the view with strings blanked;
  // the rules would then be unreliable for that file, so this fails and says which, and lint.mjs is fixed (or the construct avoided).
  const walk = (directory) => readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    return entry.isDirectory() ? (['fixtures', 'node_modules'].includes(entry.name) ? [] : walk(path)) : /\.m?js$/.test(entry.name) ? [path] : [];
  });
  const count = (text, character) => text.split(character).length - 1;
  const problems = [];
  const files = ['../web', '../web-dev', '.'].flatMap((directory) => walk(join(here, directory)));
  for (const file of files) {
    const source = readFileSync(file, 'utf8');
    const { code, bare } = lex(source);
    if (code.length !== source.length || bare.length !== source.length || count(code, '\n') !== count(source, '\n')) problems.push(`${file}: length or lines`);
    for (const [open, close] of [['{', '}'], ['(', ')'], ['[', ']']]) {
      if (count(bare, open) !== count(bare, close)) problems.push(`${file}: ${open}${close} ${count(bare, open)} against ${count(bare, close)}`);
    }
  }
  assert.ok(files.length >= 30, `only ${files.length} files were read`);
  assert.deepEqual(problems, []);
});

test('the dev tools and the tests import only node: modules and relative files (no npm)', () => {
  const files = (directory) => readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    // `player-smoke`: T08's browser pages import the page's own modules by absolute URL (/js/api.js); a browser loads them, Node never runs them
    return entry.isDirectory() ? (['fixtures', 'player-smoke'].includes(entry.name) ? [] : files(path)) : entry.name.endsWith('.mjs') ? [path] : [];
  });
  const found = [];
  const offenders = [];
  for (const file of [...files(join(here, '../web-dev')), ...files(here)]) {
    const { code, bare } = lex(readFileSync(file, 'utf8'));
    // an import outside a string: its quotes are empty in `bare`, its text is in `code`
    for (const match of bare.matchAll(/(?:\bimport\s*\(\s*|\bfrom\s+|\bimport\s+)(['"])( *)\1/g)) {
      const at = match.index + match[0].length - match[2].length - 1;
      const specifier = code.slice(at, at + match[2].length);
      found.push(specifier);
      if (!specifier.startsWith('node:') && !specifier.startsWith('.')) offenders.push(`${file}: ${specifier}`);
    }
  }
  assert.ok(found.length > 60, `only ${found.length} imports were read: the check is not looking`);
  assert.deepEqual(offenders, []);
});

test('the command line: exit status 1 and one line per finding, 0 and "No findings." when clean, from either path', () => {
  const bad = tree({ 'js/x.js': 'el.innerHTML = 1;\n' });
  const good = tree({ 'js/x.js': 'export const a = 1;\n' });
  try {
    for (const script of [join(here, '../web-dev/lint.mjs'), join(here, 'lint.mjs')]) {
      const failing = spawnSync(process.execPath, [script, bad], { encoding: 'utf8' });
      assert.equal(failing.status, 1, script);
      assert.match(failing.stdout, /^js\/x\.js:1:4 {2}inner-html {2}/m);
      const passing = spawnSync(process.execPath, [script, good], { encoding: 'utf8' });
      assert.deepEqual([passing.status, passing.stdout.trim()], [0, 'No findings.'], script);
      assert.equal(spawnSync(process.execPath, [script, join(good, 'missing')], { encoding: 'utf8' }).status, 2, script);
    }
  } finally {
    rmSync(bad, { recursive: true, force: true });
    rmSync(good, { recursive: true, force: true });
  }
});
