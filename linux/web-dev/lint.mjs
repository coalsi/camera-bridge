#!/usr/bin/env node
// The page's house rules as a lint, for the code the daemon's Content-Security-Policy and the box's plain HTTP leave no room for:
//   node linux/web-dev/lint.mjs [directory]          default: linux/web      exit status 1 when anything is found
//   (linux/web-tests/lint.mjs forwards here: the plan names both directories)
//
// It reads JavaScript with a small lexer (comments and string contents are not code), HTML and CSS with patterns, and checks the module
// graph (the NVR code loads lazily, so a mistake in it cannot blank the sign-in page). A finding can be silenced where it is justified by
// `// lint-allow <rule>: <reason>` on the same line or the line above (the reason is required).

import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { dirname, extname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// ---- the lexer ---------------------------------------------------------------------------------------------------------------------

const REGEX_AFTER_WORD = new Set(['return', 'typeof', 'case', 'delete', 'void', 'throw', 'new', 'in', 'of', 'else', 'do', 'yield', 'await', 'instanceof']);
const REGEX_AFTER_CHAR = new Set([...'(,=:[!&|?{};+-*%<>~^']);

/**
 * Two views of `source`, both the same length with the same line breaks: `code` (comments blanked) and `bare` (comments blanked and the
 * insides of strings, template text and regular expressions blanked, so a word in a string is never mistaken for code).
 */
export function lex(source) {
  const code = [];
  const bare = [];
  const stack = []; // { type: 'tpl' } for template text, { type: 'expr', depth } for a ${ } inside one
  const n = source.length;
  let i = 0;
  let previous = '';
  let word = '';
  let previousWord = '';
  const keep = (ch) => { code.push(ch); bare.push(ch); };
  const blank = (ch) => { const c = ch === '\n' ? '\n' : ' '; code.push(c); bare.push(c); };
  const text = (ch) => { code.push(ch); bare.push(ch === '\n' ? '\n' : ' '); };
  const endWord = () => { if (word) { previousWord = word; word = ''; } };

  while (i < n) {
    const ch = source[i];
    const next = source[i + 1];
    const top = stack.at(-1);
    if (top?.type === 'tpl') {
      if (ch === '\\') { text(ch); if (i + 1 < n) text(source[i + 1]); i += 2; continue; }
      if (ch === '`') { keep(ch); stack.pop(); previous = '`'; i += 1; continue; }
      if (ch === '$' && next === '{') { keep('$'); keep('{'); stack.push({ type: 'expr', depth: 0 }); previous = '{'; i += 2; continue; }
      text(ch);
      i += 1;
      continue;
    }
    if (ch === '/' && next === '/') { endWord(); while (i < n && source[i] !== '\n') { blank(source[i]); i += 1; } continue; }
    if (ch === '/' && next === '*') {
      endWord();
      blank(ch); blank(next); i += 2;
      while (i < n && !(source[i] === '*' && source[i + 1] === '/')) { blank(source[i]); i += 1; }
      if (i < n) { blank('*'); blank('/'); i += 2; }
      continue;
    }
    if (ch === '"' || ch === "'") {
      endWord();
      keep(ch); i += 1;
      while (i < n && source[i] !== ch && source[i] !== '\n') {
        if (source[i] === '\\' && i + 1 < n) { text(source[i]); text(source[i + 1]); i += 2; } else { text(source[i]); i += 1; }
      }
      if (i < n && source[i] === ch) { keep(ch); i += 1; }
      previous = ch;
      continue;
    }
    if (ch === '`') { endWord(); keep(ch); stack.push({ type: 'tpl' }); i += 1; continue; }
    if (ch === '/') {
      endWord();
      const regex = previous === '' || REGEX_AFTER_CHAR.has(previous) || (previous === 'a' && REGEX_AFTER_WORD.has(previousWord));
      if (regex) {
        keep(ch); i += 1;
        let inClass = false;
        while (i < n && source[i] !== '\n') {
          const c = source[i];
          if (c === '\\' && i + 1 < n) { text(c); text(source[i + 1]); i += 2; continue; }
          if (c === '[') inClass = true;
          else if (c === ']') inClass = false;
          else if (c === '/' && !inClass) break;
          text(c); i += 1;
        }
        if (i < n && source[i] === '/') { keep('/'); i += 1; }
        while (i < n && /[a-z]/i.test(source[i])) { keep(source[i]); i += 1; }
        previous = ')';
        previousWord = '';
        continue;
      }
      keep(ch); previous = ch; i += 1;
      continue;
    }
    if (top?.type === 'expr') {
      if (ch === '{') top.depth += 1;
      else if (ch === '}') {
        if (top.depth === 0) { keep(ch); stack.pop(); i += 1; continue; }
        top.depth -= 1;
      }
    }
    keep(ch);
    if (/[\w$]/.test(ch)) {
      word += ch;
      previous = 'a'; // an identifier, a keyword or a number: a `/` after it divides, unless the word is `return`, `typeof` and the like
    } else {
      endWord();
      if (!/\s/.test(ch)) previous = ch;
    }
    i += 1;
  }
  return { code: code.join(''), bare: bare.join('') };
}

const blankComments = (source, pattern) => source.replace(pattern, (match) => match.replace(/[^\n]/g, ' '));

// ---- the rules -----------------------------------------------------------------------------------------------------------------------

/** [rule, view, pattern, message]; `bare` is code with strings blanked, `code` keeps strings. */
const JS_RULES = [
  ['inner-html', 'bare', /\b(?:innerHTML|outerHTML)\b/g, 'builds markup from text. Build the page with the DOM API (dom.js h()), so nothing a camera says can become markup'],
  ['insert-adjacent-html', 'bare', /\binsertAdjacentHTML\b/g, 'builds markup from text. Use the DOM API'],
  ['document-write', 'bare', /\bdocument\s*\.\s*write(?:ln)?\s*\(/g, 'document.write is not allowed'],
  ['eval', 'bare', /(?<![.\w$])eval\s*\(|\bwindow\s*\.\s*eval\b/g, 'eval needs unsafe-eval in the policy, which the page does not allow'],
  ['new-function', 'bare', /\bnew\s+Function\b|(?<![.\w$])Function\s*\(/g, 'the Function constructor needs unsafe-eval, which the page does not allow'],
  ['set-attribute-style', 'code', /\bsetAttribute\s*\(\s*['"`]style['"`]|\bsetAttributeNS\s*\(\s*[^,()]*,\s*['"`]style['"`]/gi, 'an inline style attribute is blocked by style-src \'self\'. Set el.style.x from script, or use a class'],
  ['inline-style-markup', 'code', /(?<![.\w$-])style\s*=\s*\\?["']/g, 'a style="..." attribute is blocked by style-src \'self\'. Set el.style.x from script, or use a class'],
  ['network-outside-api', 'bare', /(?<![.\w$])fetch\s*\(|\bwindow\s*\.\s*fetch\b|\bXMLHttpRequest\b|\bnavigator\s*\.\s*sendBeacon\b/g, 'network requests go through js/api.js (one place for the session, the CSRF token and the 401 handling)'],
  ['web-codecs', 'bare', /\b(?:VideoDecoder|AudioDecoder|EncodedVideoChunk|EncodedAudioChunk|ImageDecoder)\b/g, 'WebCodecs exist only in secure contexts, and the box serves plain HTTP. Decode with MediaSource'],
  ['secure-context-api', 'bare', /\bcrypto\s*\.\s*(?:randomUUID|subtle)\b/g, 'crypto.randomUUID and crypto.subtle exist only in secure contexts, and the box serves plain HTTP'],
  ['worker-or-wasm', 'bare', /\bnew\s+(?:Shared)?Worker\b|\bWebAssembly\b|\bimportScripts\s*\(|\bnavigator\s*\.\s*serviceWorker\b/g, 'the policy allows no worker and no WebAssembly'],
  ['remote-module', 'code', /(?:\bimport\s*\(\s*|\bfrom\s+|\bimport\s+)['"]https?:\/\//g, 'the page loads nothing from other hosts (no CDN)'],
  ['bare-import', 'code', /(?:\bimport\s*\(\s*|\bfrom\s+|\bimport\s+)['"](?![./]|https?:)[^'"]+['"]/g, 'a bare module name needs a bundler; the page has no build step. Import a file by relative path'],
];

const HTML_RULES = [
  ['inline-script', /<script(?![^>]*\ssrc\s*=)[^>]*>/gi, 'an inline script is blocked by script-src \'self\''],
  ['inline-handler', /\son[a-z]+\s*=/gi, 'an inline event handler is blocked by script-src \'self\''],
  ['style-attribute', /\sstyle\s*=/gi, 'a style attribute is blocked by style-src \'self\''],
  ['style-element', /<style[\s>]/gi, 'an inline style element is blocked by style-src \'self\''],
  ['javascript-url', /javascript\s*:/gi, 'a javascript: URL is blocked'],
  ['remote-url', /\s(?:src|href|action|poster)\s*=\s*["']?https?:\/\//gi, 'the page loads nothing from other hosts (no CDN)'],
];

const CSS_RULES = [
  ['css-import', /@import\b/g, 'a stylesheet import is a second request and may point anywhere; link each stylesheet in index.html'],
  ['remote-url', /url\(\s*["']?(?:https?:)?\/\//gi, 'the page loads nothing from other hosts (no fonts or images from a CDN)'],
];

/** Where `index` is in `source`: { line, column }, both counted from 1. */
function position(source, index) {
  const before = source.slice(0, index);
  const line = before.split('\n').length;
  return { line, column: index - before.lastIndexOf('\n') };
}

/** Where a `style` key sits in an object literal passed as the second argument of h('tag', {...}) or svg('tag', {...}). */
function styleKeysInHelpers(code, bare) {
  const found = [];
  const start = /(?<![.\w$])(?:h|svg)\s*\(\s*['"`][\w-]+['"`]\s*,\s*\{/g;
  for (let match = start.exec(code); match; match = start.exec(code)) {
    const open = match.index + match[0].length;
    let level = 0;
    let expectKey = true;
    for (let i = open; i < bare.length; i += 1) {
      const c = bare[i];
      if (/\s/.test(c)) continue;
      if (c === '{' || c === '(' || c === '[') { level += 1; expectKey = false; continue; }
      if (c === '}' || c === ')' || c === ']') { if (level === 0) break; level -= 1; continue; }
      if (level !== 0) continue;
      if (c === ',') { expectKey = true; continue; }
      if (!expectKey) continue;
      expectKey = false;
      let name;
      if (c === '"' || c === "'" || c === '`') {
        const end = bare.indexOf(c, i + 1);
        name = code.slice(i + 1, end);
        i = end;
      } else {
        name = /^[\w$]*/.exec(bare.slice(i))[0];
        i += Math.max(0, name.length - 1);
      }
      if (name === 'style') found.push(i);
    }
  }
  return found;
}

/** `lint-allow <rule>: <reason>` comments: the lines (and the line below) where a rule is silenced. */
function allowances(source) {
  const allowed = new Map();
  source.split('\n').forEach((text, index) => {
    for (const match of text.matchAll(/lint-allow\s+([a-z-]+)\s*:\s*\S/g)) {
      for (const line of [index + 1, index + 2]) allowed.set(`${line}:${match[1]}`, true);
    }
  });
  return allowed;
}

/** Findings for one file: [{ file, line, column, rule, message }]. `file` is relative to the linted directory (js/api.js is the one place for fetch). */
export function lintSource(file, source) {
  const findings = [];
  const extension = extname(file);
  const add = (rule, index, message) => findings.push({ file, ...position(source, index), rule, message });
  if (extension === '.js' || extension === '.mjs') {
    const { code, bare } = lex(source);
    for (const [rule, view, pattern, message] of JS_RULES) {
      if (rule === 'network-outside-api' && file.split(sep).join('/') === 'js/api.js') continue;
      for (const match of (view === 'bare' ? bare : code).matchAll(pattern)) add(rule, match.index, message);
    }
    for (const index of styleKeysInHelpers(code, bare)) add('h-style-attribute', index, 'h() and svg() set attributes with setAttribute, which the policy blocks for style. Set el.style.x from script, or use a class');
  } else if (extension === '.html' || extension === '.htm') {
    const text = blankComments(source, /<!--[\s\S]*?-->/g);
    for (const [rule, pattern, message] of HTML_RULES) for (const match of text.matchAll(pattern)) add(rule, match.index, message);
  } else if (extension === '.css') {
    const text = blankComments(source, /\/\*[\s\S]*?\*\//g);
    for (const [rule, pattern, message] of CSS_RULES) for (const match of text.matchAll(pattern)) add(rule, match.index, message);
  }
  const allowed = allowances(source);
  return findings.filter((finding) => !allowed.has(`${finding.line}:${finding.rule}`));
}

// ---- the module graph ---------------------------------------------------------------------------------------------------------------

const STATIC_IMPORT = /\b(?:import|export)\s+(?:[^'"()]*?\s+from\s+)?['"]([^'"]+)['"]/g;
const DYNAMIC_IMPORT = /\bimport\s*\(\s*['"]([^'"]+)['"]\s*\)/g;

/** Modules the sign-in page must not load: the NVR code is loaded lazily (T00 C.10), `js/nvr/lite.js` being the one static import of it. */
const LAZY_ONLY = (path) => (path.startsWith('js/nvr/') && path !== 'js/nvr/lite.js') || ['js/screens/watch.js', 'js/screens/nvr.js', 'js/screens/optimize-dialog.js'].includes(path);

/** The edges of the module graph of the `.js` files under `root`: { from, to, specifier, dynamic, index, source }. */
export function moduleEdges(root, files) {
  const edges = [];
  for (const file of files) {
    const source = readFileSync(join(root, file), 'utf8');
    const { code } = lex(source);
    for (const [pattern, dynamic] of [[STATIC_IMPORT, false], [DYNAMIC_IMPORT, true]]) {
      for (const match of code.matchAll(pattern)) {
        const specifier = match[1];
        const target = specifier.startsWith('.') ? relative(root, resolve(root, dirname(file), specifier)).split(sep).join('/') : null;
        edges.push({ from: file, to: target, specifier, dynamic, source, index: match.index });
      }
    }
  }
  return edges;
}

/** Findings about the graph: a missing file, the sign-in page reaching lazy code, lite.js importing anything. */
export function lintGraph(root, files) {
  const jsFiles = files.filter((file) => file.endsWith('.js') || file.endsWith('.mjs'));
  const edges = moduleEdges(root, jsFiles);
  const findings = [];
  const at = (edge, rule, message) => findings.push({ file: edge.from, ...position(edge.source, edge.index), rule, message });
  for (const edge of edges) {
    if (edge.to !== null && !existsSync(join(root, edge.to))) at(edge, 'import-missing', `${edge.specifier} does not exist`);
  }
  const reached = new Set();
  const queue = jsFiles.includes('js/app.js') ? ['js/app.js'] : [];
  while (queue.length) {
    const file = queue.shift();
    if (reached.has(file)) continue;
    reached.add(file);
    for (const edge of edges.filter((candidate) => candidate.from === file && !candidate.dynamic && candidate.to)) {
      if (LAZY_ONLY(edge.to)) at(edge, 'lazy-only', `${edge.to} is loaded at start-up through this import. NVR code loads lazily (import() from app.js lazy() or nvr/lite.js), so that a mistake in it cannot blank the sign-in page`);
      else queue.push(edge.to);
    }
  }
  for (const edge of edges.filter((candidate) => candidate.from === 'js/nvr/lite.js' && !candidate.dynamic)) at(edge, 'lite-imports', 'js/nvr/lite.js is imported at start-up and must import nothing statically');
  return findings;
}

// ---- the NVR stylesheets ---------------------------------------------------------------------------------------------------------------

/** index.html links these three on every page, in this order, so every rule in them is global: a class styled in two of them is one rule set to the other's. */
export const NVR_STYLESHEETS = ['nvr-record.css', 'nvr-watch.css', 'nvr-grid.css'];

/** The classes a stylesheet owns: the first class of each selector in a list (`.a .b, .c:hover` owns `a` and `c`), with the index of its first rule. */
export function ownedClasses(css) {
  const text = blankComments(css, /\/\*[\s\S]*?\*\//g);
  const owned = new Map();
  for (const match of text.matchAll(/([^{}]+)\{/g)) {
    if (match[1].trim().startsWith('@')) continue;                  // @media (...) {   @keyframes name {
    for (const part of match[1].split(',')) {
      const found = /\.([A-Za-z_][\w-]*)/.exec(part);
      if (found && !owned.has(found[1])) owned.set(found[1], match.index + match[1].indexOf(found[0]));
    }
  }
  return owned;
}

/** Findings about the NVR stylesheets present in `files` (paths relative to `root`): the later stylesheet is reported for a class both own. */
export function lintStylesheets(root, files) {
  const seen = new Map();                                            // class -> the stylesheet that owns it first
  const findings = [];
  for (const name of NVR_STYLESHEETS.filter((candidate) => files.includes(candidate))) {
    const source = readFileSync(join(root, name), 'utf8');
    for (const [className, index] of ownedClasses(source)) {
      if (seen.has(className)) {
        findings.push({ file: name, ...position(source, index), rule: 'css-class-shared', message: `.${className} is also styled in ${seen.get(className)}. The three NVR stylesheets are linked on every page, so each task keeps its own class prefix (rec-, watch-, nvr-tile-, nvr-grid-)` });
      } else {
        seen.set(className, name);
      }
    }
  }
  return findings;
}

// ---- the tree --------------------------------------------------------------------------------------------------------------------------

function listFiles(root, directory = '') {
  const result = [];
  for (const entry of readdirSync(join(root, directory), { withFileTypes: true })) {
    const path = directory ? `${directory}/${entry.name}` : entry.name;
    if (entry.isDirectory()) result.push(...(entry.name === 'node_modules' ? [] : listFiles(root, path)));
    else if (['.js', '.mjs', '.html', '.css'].includes(extname(entry.name))) result.push(path);
  }
  return result.sort();
}

/** Every finding under `root`, ordered by file and position. */
export function lintTree(root) {
  const files = listFiles(root);
  const findings = files.flatMap((file) => lintSource(file, readFileSync(join(root, file), 'utf8')));
  const graph = lintGraph(root, files).filter((finding) => !allowances(readFileSync(join(root, finding.file), 'utf8')).has(`${finding.line}:${finding.rule}`));
  return [...findings, ...graph, ...lintStylesheets(root, files)].sort((a, b) => (a.file < b.file ? -1 : a.file > b.file ? 1 : a.line - b.line || a.column - b.column));
}

export function main() {
  const here = dirname(fileURLToPath(import.meta.url));
  const root = resolve(process.argv[2] ?? join(here, '../web'));
  if (!existsSync(root)) { console.error(`There is no directory ${root}.`); process.exit(2); }
  const findings = lintTree(root);
  for (const finding of findings) console.log(`${finding.file}:${finding.line}:${finding.column}  ${finding.rule}  ${finding.message}`);
  console.log(findings.length ? `${findings.length} finding${findings.length === 1 ? '' : 's'}.` : 'No findings.');
  process.exit(findings.length ? 1 : 0);
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) main();
