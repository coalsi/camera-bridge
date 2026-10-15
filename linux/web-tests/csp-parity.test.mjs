// The dev server's security headers are a copy of the daemon's. This test reads the daemon's source and fails when the two differ, so
// a change to BridgeWeb/WebApp.swift (T04's media-src, or any later one) cannot leave the dev tools, and everything tested against
// them, behind. Skipped when the Swift sources are not there (the tests were copied out of the repository).

import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { CSP, SECURITY_HEADERS } from '../web-dev/lib/security.mjs';

const swiftPath = join(dirname(fileURLToPath(import.meta.url)), '../../Packages/CameraBridgeKit/Sources/BridgeWeb/WebApp.swift');

/** The body of `static func addSecurityHeaders`, as text. */
function securityHeadersBody() {
  const source = readFileSync(swiftPath, 'utf8');
  const start = source.indexOf('static func addSecurityHeaders');
  assert.ok(start >= 0, 'WebApp.swift no longer has addSecurityHeaders: update this test and the dev server together');
  const open = source.indexOf('{', start);
  let depth = 0;
  for (let i = open; i < source.length; i += 1) {
    if (source[i] === '{') depth += 1;
    else if (source[i] === '}' && --depth === 0) return source.slice(open + 1, i);
  }
  throw new Error('addSecurityHeaders is not closed');
}

/** `"a" + "b"` string literals joined, escapes undone. */
const joinLiterals = (text) => [...text.matchAll(/"((?:[^"\\]|\\.)*)"/g)].map((match) => match[1].replace(/\\"/g, '"').replace(/\\\\/g, '\\')).join('');

test('the dev server sends the security headers the daemon sends', { skip: !existsSync(swiftPath) && 'the Swift sources are not here' }, () => {
  const body = securityHeadersBody();
  const assignments = [...body.matchAll(/response\.headers\["([A-Za-z-]+)"\]\s*=\s*((?:"(?:[^"\\]|\\.)*"\s*\+?\s*)+)/g)].map((match) => [match[1], joinLiterals(match[2])]);
  const daemon = Object.fromEntries(assignments);
  assert.ok(Object.keys(daemon).length >= 6, `found only ${Object.keys(daemon).join(', ')} in addSecurityHeaders`);
  const csp = daemon['Content-Security-Policy'];
  // T04 adds `media-src 'self' blob:` after img-src; before it lands, the daemon is the dev server's CSP without that one directive
  const expected = csp.includes('media-src') ? CSP : CSP.replace(" media-src 'self' blob:;", '');
  assert.equal(csp, expected, 'the Content-Security-Policy of the daemon and of the dev server differ');
  for (const [name, value] of Object.entries(SECURITY_HEADERS)) {
    if (name === 'Content-Security-Policy') continue;
    assert.equal(daemon[name], value, `the header ${name} differs between the daemon and the dev server`);
  }
  // Cache-Control is the one conditional header: an /api/ answer is `no-store` unless its handler said otherwise (withSecurityHeaders does the same)
  assert.equal(daemon['Cache-Control'], 'no-store', 'the daemon no longer defaults API answers to no-store');
  for (const name of Object.keys(daemon)) assert.ok(name === 'Cache-Control' || name in SECURITY_HEADERS, `the daemon sets ${name}, which the dev server does not`);
});

test('the dev server\'s CSP is the one T00 C.8 gives, with exactly one directive more than the daemon had', () => {
  const before = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; font-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'";
  assert.equal(CSP.replace(" media-src 'self' blob:;", ''), before);
  assert.equal(CSP.split('; ').length, before.split('; ').length + 1);
});
