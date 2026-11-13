// The page's own QR codes (js/qr.js): a port of BridgeWeb/QRCode.swift, extended from version 10 to version 20 so that a WireGuard
// configuration fits. Pure: no browser. QRCodeTests (Swift, on a Mac with `node` on the PATH) checks that the page's codes are the Swift
// encoder's, module for module, and that Core Image reads back the larger ones.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { encodeQR, qrPath } from '../web/js/qr.js';

const dark = (code, x, y) => code.modules[y * code.size + x] === 1;
const repeat = (count, letter = 'a') => letter.repeat(count);

test('a Home setup code fits version 2', () => {
  const code = encodeQR('X-HM://00GW95DQA7OSX');
  assert.equal(code.version, 2);
  assert.equal(code.size, 25);
  assert.ok(code.modules instanceof Uint8Array, 'one byte per module');
  assert.equal(code.modules.length, 625);
  assert.ok(code.modules.every((module) => module === 0 || module === 1), '1 is dark, 0 is light');
  assert.ok(Number.isInteger(code.mask) && code.mask >= 0 && code.mask < 8, `mask ${code.mask}`);
});

test('the version grows with the message, to 20', () => {
  // The byte capacities of ISO/IEC 18004 at level M: 14 bytes fill version 1, 213 version 10, 666 version 20.
  for (const [length, version] of [[1, 1], [14, 1], [15, 2], [213, 10], [251, 11], [331, 13], [362, 14], [666, 20]]) {
    assert.equal(encodeQR(repeat(length)).version, version, `${length} characters`);
  }
  assert.throws(() => encodeQR(repeat(667)), (error) => error instanceof RangeError && error.message === 'too long');
  assert.equal(encodeQR(repeat(17), { level: 'L' }).version, 1, 'level L holds 17 bytes in version 1');
  assert.equal(encodeQR(repeat(17), { level: 'M' }).version, 2);
  assert.equal(encodeQR(repeat(17)).version, 2, 'M by default');
  assert.equal(encodeQR(repeat(666)).size, 97, 'version 20 is 97 modules a side');
  assert.equal(encodeQR('é').version, 1, 'counted in UTF-8 bytes');
  assert.equal(encodeQR(repeat(7, 'é')).version, 1, '14 bytes');
  assert.equal(encodeQR(repeat(8, 'é')).version, 2, '16 bytes');
});

test('the finder and timing patterns are in place', () => {
  for (const code of [encodeQR('X-HM://0081YCYEP3QXO'), encodeQR(repeat(666))]) {
    for (const [originX, originY] of [[0, 0], [code.size - 7, 0], [0, code.size - 7]]) {
      for (let y = 0; y < 7; y += 1) {
        for (let x = 0; x < 7; x += 1) {
          // The outer ring (3) is dark, the ring inside it (2) light, the 3x3 centre dark.
          const ring = Math.max(Math.abs(x - 3), Math.abs(y - 3));
          assert.equal(dark(code, originX + x, originY + y), ring !== 2, `version ${code.version}: finder at ${originX},${originY} module ${x},${y}`);
        }
      }
    }
    // The timing patterns alternate between the finders, and the module above the lower-left finder's light border is always dark.
    for (let index = 8; index < code.size - 8; index += 1) {
      assert.equal(dark(code, index, 6), index % 2 === 0, `version ${code.version}: row 6 at ${index}`);
      assert.equal(dark(code, 6, index), index % 2 === 0, `version ${code.version}: column 6 at ${index}`);
    }
    assert.ok(dark(code, 8, code.size - 8));
  }
});

test('from version 7 the version information is drawn', () => {
  // 122 bytes at M are version 7, 362 bytes version 14; their 18-bit version words are ISO/IEC 18004's (Annex D).
  for (const [length, version, word] of [[122, 7, 0x07C94], [362, 14, 0x0E60D]]) {
    const code = encodeQR(repeat(length));
    assert.equal(code.version, version);
    let upperRight = 0;
    let lowerLeft = 0;
    for (let i = 0; i < 18; i += 1) {
      const a = code.size - 11 + (i % 3);
      const b = Math.floor(i / 3);
      if (dark(code, a, b)) upperRight |= 1 << i;   // x near the right edge, y near the top
      if (dark(code, b, a)) lowerLeft |= 1 << i;    // x near the left edge, y near the bottom
    }
    assert.equal(upperRight, word, `version ${version} beside the upper-right finder: ${upperRight.toString(16)}`);
    assert.equal(lowerLeft, word, `version ${version} above the lower-left finder: ${lowerLeft.toString(16)}`);
  }
});

test('the same message gives the same code', () => {
  assert.deepEqual(encodeQR('X-HM://00GW95DQA7OSX'), encodeQR('X-HM://00GW95DQA7OSX'));
  assert.notDeepEqual(encodeQR('X-HM://00GW95DQA7OSX').modules, encodeQR('X-HM://00GW95DQA7OSY').modules);
  assert.notDeepEqual(encodeQR(repeat(17), { level: 'L' }), encodeQR(repeat(17), { level: 'M' }));
});

test('the path covers exactly the dark modules', () => {
  for (const code of [encodeQR('X-HM://00GW95DQA7OSX'), encodeQR(repeat(300))]) {
    for (const quietZone of [4, 0]) {
      const path = qrPath(code, quietZone);
      // One run of dark modules a piece, a row at a time, the way QRCode.svg() draws it.
      assert.match(path, /^(?:M\d+,\d+h\d+v1h-\d+z)+$/);
      const drawn = new Uint8Array(code.size * code.size);
      for (const [, x, y, width, back] of path.matchAll(/M(\d+),(\d+)h(\d+)v1h-(\d+)z/g)) {
        assert.equal(width, back, 'each run closes on itself');
        for (let at = 0; at < Number(width); at += 1) {
          const column = Number(x) - quietZone + at;
          const row = Number(y) - quietZone;
          assert.equal(drawn[row * code.size + column], 0, `module ${column},${row} drawn twice`);
          drawn[row * code.size + column] = 1;
        }
      }
      assert.deepEqual(drawn, code.modules, `version ${code.version}, quiet zone ${quietZone}`);
    }
  }
  assert.equal(qrPath(encodeQR('X-HM://00GW95DQA7OSX')), qrPath(encodeQR('X-HM://00GW95DQA7OSX'), 4), 'a quiet zone of 4 by default');
  assert.ok(qrPath(encodeQR('X-HM://00GW95DQA7OSX')).startsWith('M4,4h7v1h-7z'), 'the first row starts with the upper-left finder, after the quiet zone');
});

/** Task 5's configuration (AwayRules.wireGuardConfig): no DNS and no keepalive, the box's address as the endpoint. */
const wireGuardConfig = ({ privateKey, address, boxPublicKey, endpoint, allowedIPs }) =>
  `[Interface]\nPrivateKey = ${privateKey}\nAddress = ${address}/32\nMTU = 1280\n\n[Peer]\nPublicKey = ${boxPublicKey}\nAllowedIPs = ${allowedIPs.join(', ')}\nEndpoint = ${endpoint}\n`;

test('a WireGuard configuration fits', () => {
  // Keys are 44 characters of base64; these two are counting patterns, not anybody's keys.
  const privateKey = Buffer.from(Array.from({ length: 32 }, (_, i) => i)).toString('base64');
  const boxPublicKey = Buffer.from(Array.from({ length: 32 }, (_, i) => 32 + i)).toString('base64');
  assert.equal(privateKey.length, 44);
  assert.equal(boxPublicKey.length, 44);
  const usual = wireGuardConfig({ privateKey, boxPublicKey, address: '10.123.45.2', endpoint: '[2001:db8:4:7000:1a2b:3c4d:5e6f:7a8b]:51820',
    allowedIPs: ['10.123.45.1/32', '192.0.2.10/32'] });
  // The longest one: every address as long as it can be written.
  const longest = wireGuardConfig({ privateKey, boxPublicKey, address: '10.254.254.254', endpoint: '[2001:db8:ffff:ffff:ffff:ffff:ffff:ffff]:51820',
    allowedIPs: ['10.254.254.1/32', '198.51.100.200/32'] });
  for (const config of [usual, longest]) {
    const code = encodeQR(config);
    assert.ok(code.version <= 14, `${Buffer.byteLength(config)} bytes need version ${code.version} at M`);
  }
});
