// The appearance setting (Auto, Light, Dark): the light colours exist twice in style.css (chosen Light, and Auto on a light device) and
// must stay equal; both pages load /theme-boot.js before the stylesheet, so a chosen appearance never flashes the other one.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { THEMES, THEME_INFO, currentTheme, nextTheme } from '../web/js/theme.js';

const web = join(dirname(fileURLToPath(import.meta.url)), '../web');
const css = readFileSync(join(web, 'style.css'), 'utf8');

/** The custom properties declared in the rule that starts at `selector` (the first `{` after it to its `}`). */
function tokens(selector, from = 0) {
  const start = css.indexOf(selector, from);
  assert.ok(start >= 0, `${selector} is in style.css`);
  const body = css.slice(css.indexOf('{', start) + 1, css.indexOf('}', start));
  return Object.fromEntries([...body.matchAll(/(--[\w-]+)\s*:\s*([^;]+);/g)].map((m) => [m[1], m[2].trim()]));
}

test('the light colours are the same whether chosen or followed from the device', () => {
  const chosen = tokens(':root[data-theme="light"] {');
  const followed = tokens(':root:not([data-theme="dark"]) {', css.indexOf('@media (prefers-color-scheme: light)'));
  assert.ok(Object.keys(chosen).length >= 15, 'the light block sets the colours');
  assert.deepEqual(followed, chosen);
  const dark = tokens(':root {');
  for (const name of Object.keys(chosen)) assert.ok(name in dark, `${name} has a dark value too`);
});

test('both pages apply the chosen appearance before the stylesheet, from a plain script', () => {
  for (const page of ['index.html', 'setup.html']) {
    const html = readFileSync(join(web, page), 'utf8');
    const boot = html.indexOf('<script src="/theme-boot.js"></script>');
    assert.ok(boot >= 0 && boot < html.indexOf('/style.css'), `${page} loads /theme-boot.js before style.css`);
  }
});

test('Dark → Light → Auto → Dark, and Dark (the default) without storage', () => {
  assert.deepEqual(THEMES, ['dark', 'light', 'auto']);
  assert.deepEqual(THEMES.map(nextTheme), ['light', 'auto', 'dark']);
  for (const theme of THEMES) assert.ok(THEME_INFO[theme].label && THEME_INFO[theme].icon);
  assert.equal(currentTheme(), 'dark', 'no localStorage in plain Node: Dark, no exception');
});
