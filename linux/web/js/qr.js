// The page's own QR codes: Settings › Away from home shows a WireGuard device's configuration once, as a code the device's app scans, and
// that configuration holds the device's private key, so it is drawn here and never sent anywhere to be drawn. A port of
// BridgeWeb/QRCode.swift (ISO/IEC 18004, byte mode, error correction L or M; the steps of Project Nayuki's reference implementation),
// extended from version 10 to version 20, since a configuration of about 290 bytes needs version 13 or 14 at M. The steps, the tables for
// versions 1 to 10 and the choice of mask are the Swift encoder's, so the same text gives the same code: QRCodeTests runs this file with
// `node` and compares the two module for module, and has Core Image read back the codes of versions 11 to 20. Like QRCode.swift it is
// derived from Project Nayuki's QR Code generator library (Copyright (c) Project Nayuki, MIT License,
// https://www.nayuki.io/page/qr-code-generator-library), whose copyright and permission notice are in THIRD_PARTY_LICENSES.md. Pure:
// nothing here touches the page.

// The error correction codewords per block and the number of blocks, per version (index 0 unused). Versions 1 to 10 are QRCode.swift's, 11
// to 20 are ISO/IEC 18004's table 9.
const ECC_PER_BLOCK = {
  L: [, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28],
  M: [, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26],
};
const BLOCKS = {
  L: [, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8],
  M: [, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16],
};
/** The format information's error correction field: L is 01, M is 00. */
const FORMAT_BITS = { L: 1, M: 0 };
const MAXIMUM_VERSION = 20;

/**
 * The QR code of `text` (its UTF-8 bytes, in byte mode) at error correction `level` ('L' or 'M'), in the smallest version that holds it:
 * { version, size, mask, modules }, where `modules` is a Uint8Array of size × size, row by row, 1 for a dark module. A text longer than
 * version 20 holds is a RangeError('too long').
 */
export function encodeQR(text, { level = 'M' } = {}) {
  if (!Object.hasOwn(FORMAT_BITS, level)) throw new RangeError(`level ${level}`);
  const data = new TextEncoder().encode(String(text));
  let version = 1;
  let capacityBits = 0;
  for (;;) {
    const countBits = version < 10 ? 8 : 16;
    capacityBits = dataCodewords(version, level) * 8;
    if (4 + countBits + data.length * 8 <= capacityBits) break;
    version += 1;
    if (version > MAXIMUM_VERSION) throw new RangeError('too long');
  }
  // Data bits: mode 0100 (bytes), the character count, the bytes, the terminator, then padding to the capacity.
  const bits = [];
  const append = (value, count) => { for (let shift = count - 1; shift >= 0; shift -= 1) bits.push((value >>> shift) & 1); };
  append(0b0100, 4);
  append(data.length, version < 10 ? 8 : 16);
  for (const byte of data) append(byte, 8);
  append(0, Math.min(4, capacityBits - bits.length));
  append(0, (8 - (bits.length % 8)) % 8);
  for (let pad = 0xEC; bits.length < capacityBits; pad ^= 0xEC ^ 0x11) append(pad, 8);
  const codewords = new Uint8Array(bits.length / 8);
  bits.forEach((bit, index) => { if (bit) codewords[index >>> 3] |= 0x80 >>> (index & 7); });

  const all = addErrorCorrectionAndInterleave(codewords, version, level);
  const size = version * 4 + 17;
  const grid = new Grid(size);
  grid.drawFunctionPatterns(version, FORMAT_BITS[level]);
  grid.drawCodewords(all);
  // The mask with the lowest penalty, the first of equals, as the Swift encoder chooses it.
  let bestMask = 0;
  let bestPenalty = Infinity;
  for (let candidate = 0; candidate < 8; candidate += 1) {
    grid.applyMask(candidate);
    grid.drawFormatBits(candidate, FORMAT_BITS[level]);
    const penalty = grid.penaltyScore();
    if (penalty < bestPenalty) {
      bestPenalty = penalty;
      bestMask = candidate;
    }
    grid.applyMask(candidate);   // undone: a mask is an exclusive or
  }
  grid.applyMask(bestMask);
  grid.drawFormatBits(bestMask, FORMAT_BITS[level]);
  return { version, size, mask: bestMask, modules: grid.modules };
}

/**
 * The dark modules of `code` as one SVG path, a run of dark modules at a time, row by row, `quietZone` modules in from the top left: the path
 * QRCode.svg() draws, for a viewBox of size + 2 × quietZone a side.
 */
export function qrPath(code, quietZone = 4) {
  const { size, modules } = code;
  let path = '';
  for (let y = 0; y < size; y += 1) {
    let x = 0;
    while (x < size) {
      if (!modules[y * size + x]) {
        x += 1;
        continue;
      }
      let end = x;
      while (end < size && modules[y * size + end]) end += 1;
      path += `M${x + quietZone},${y + quietZone}h${end - x}v1h-${end - x}z`;
      x = end;
    }
  }
  return path;
}

// MARK: Capacity

function rawModules(version) {
  let result = (16 * version + 128) * version + 64;
  if (version >= 2) {
    const alignments = Math.floor(version / 7) + 2;
    result -= (25 * alignments - 10) * alignments - 55;
    if (version >= 7) result -= 36;
  }
  return result;
}

function dataCodewords(version, level) {
  return Math.floor(rawModules(version) / 8) - ECC_PER_BLOCK[level][version] * BLOCKS[level][version];
}

function addErrorCorrectionAndInterleave(data, version, level) {
  const blocks = BLOCKS[level][version];
  const eccLength = ECC_PER_BLOCK[level][version];
  const rawCodewords = Math.floor(rawModules(version) / 8);
  const shortBlocks = blocks - (rawCodewords % blocks);
  const shortLength = Math.floor(rawCodewords / blocks);
  const divisor = reedSolomonDivisor(eccLength);
  const result = [];
  let offset = 0;
  for (let index = 0; index < blocks; index += 1) {
    const length = shortLength - eccLength + (index < shortBlocks ? 0 : 1);
    const chunk = Array.from(data.subarray(offset, offset + length));
    offset += length;
    const ecc = reedSolomonRemainder(chunk, divisor);
    // A placeholder keeps the short blocks as long as the others while they are interleaved.
    result.push([...chunk, ...(index < shortBlocks ? [0] : []), ...ecc]);
  }
  const interleaved = [];
  for (let column = 0; column < result[0].length; column += 1) {
    result.forEach((block, index) => {
      // The placeholder of a short block is skipped.
      if (column === shortLength - eccLength && index < shortBlocks) return;
      interleaved.push(block[column]);
    });
  }
  return interleaved;
}

// MARK: Reed-Solomon over GF(256), modulo 0x11D

function multiply(x, y) {
  let z = 0;
  for (let bit = 7; bit >= 0; bit -= 1) {
    z = (z << 1) ^ ((z >>> 7) * 0x11D);
    z ^= ((y >>> bit) & 1) * x;
  }
  return z & 0xFF;
}

function reedSolomonDivisor(degree) {
  const result = new Array(degree).fill(0);
  result[degree - 1] = 1;
  let root = 1;
  for (let i = 0; i < degree; i += 1) {
    for (let j = 0; j < degree; j += 1) {
      result[j] = multiply(result[j], root);
      if (j + 1 < degree) result[j] ^= result[j + 1];
    }
    root = multiply(root, 0x02);
  }
  return result;
}

function reedSolomonRemainder(data, divisor) {
  const result = new Array(divisor.length).fill(0);
  for (const byte of data) {
    const factor = byte ^ result.shift();
    result.push(0);
    divisor.forEach((coefficient, index) => { result[index] ^= multiply(coefficient, factor); });
  }
  return result;
}

// MARK: Drawing

class Grid {
  constructor(size) {
    this.size = size;
    this.modules = new Uint8Array(size * size);
    /** The modules of the finder, timing, alignment, format and version patterns, which the data and the masks leave alone. */
    this.function = new Uint8Array(size * size);
  }

  set(x, y, dark, isFunction = true) {
    this.modules[y * this.size + x] = dark ? 1 : 0;
    if (isFunction) this.function[y * this.size + x] = 1;
  }

  dark(x, y) {
    return this.modules[y * this.size + x] === 1;
  }

  drawFunctionPatterns(version, formatBits) {
    const { size } = this;
    for (let i = 0; i < size; i += 1) {
      this.set(6, i, i % 2 === 0);
      this.set(i, 6, i % 2 === 0);
    }
    this.drawFinder(3, 3);
    this.drawFinder(size - 4, 3);
    this.drawFinder(3, size - 4);
    const positions = alignmentPositions(version);
    const last = positions.length - 1;
    positions.forEach((x, i) => positions.forEach((y, j) => {
      // Not where a finder is.
      if ((i === 0 && j === 0) || (i === 0 && j === last) || (i === last && j === 0)) return;
      this.drawAlignment(x, y);
    }));
    this.drawFormatBits(0, formatBits);   // marks the format modules as a pattern; the chosen mask's bits are drawn last
    this.drawVersion(version);
  }

  drawFinder(cx, cy) {
    for (let dy = -4; dy <= 4; dy += 1) {
      for (let dx = -4; dx <= 4; dx += 1) {
        const x = cx + dx;
        const y = cy + dy;
        if (x < 0 || x >= this.size || y < 0 || y >= this.size) continue;
        const distance = Math.max(Math.abs(dx), Math.abs(dy));
        this.set(x, y, distance !== 2 && distance !== 4);
      }
    }
  }

  drawAlignment(cx, cy) {
    for (let dy = -2; dy <= 2; dy += 1) {
      for (let dx = -2; dx <= 2; dx += 1) this.set(cx + dx, cy + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
    }
  }

  drawFormatBits(mask, formatBits) {
    const { size } = this;
    const data = (formatBits << 3) | mask;
    let remainder = data;
    for (let i = 0; i < 10; i += 1) remainder = (remainder << 1) ^ ((remainder >>> 9) * 0x537);
    const bits = ((data << 10) | remainder) ^ 0x5412;
    const bit = (i) => ((bits >>> i) & 1) === 1;
    for (let i = 0; i <= 5; i += 1) this.set(8, i, bit(i));
    this.set(8, 7, bit(6));
    this.set(8, 8, bit(7));
    this.set(7, 8, bit(8));
    for (let i = 9; i < 15; i += 1) this.set(14 - i, 8, bit(i));
    for (let i = 0; i < 8; i += 1) this.set(size - 1 - i, 8, bit(i));
    for (let i = 8; i < 15; i += 1) this.set(8, size - 15 + i, bit(i));
    this.set(8, size - 8, true);
  }

  drawVersion(version) {
    if (version < 7) return;
    let remainder = version;
    for (let i = 0; i < 12; i += 1) remainder = (remainder << 1) ^ ((remainder >>> 11) * 0x1F25);
    const bits = (version << 12) | remainder;
    for (let i = 0; i < 18; i += 1) {
      const dark = ((bits >>> i) & 1) === 1;
      const a = this.size - 11 + (i % 3);
      const b = Math.floor(i / 3);
      this.set(a, b, dark);
      this.set(b, a, dark);
    }
  }

  drawCodewords(data) {
    const { size } = this;
    let index = 0;
    for (let right = size - 1; right >= 1; right -= 2) {
      if (right === 6) right = 5;   // the vertical timing pattern's column is skipped
      const upward = ((right + 1) & 2) === 0;
      for (let vertical = 0; vertical < size; vertical += 1) {
        for (let j = 0; j < 2; j += 1) {
          const x = right - j;
          const y = upward ? size - 1 - vertical : vertical;
          if (!this.function[y * size + x] && index < data.length * 8) {
            this.modules[y * size + x] = (data[index >>> 3] >>> (7 - (index & 7))) & 1;
            index += 1;
          }
        }
      }
    }
  }

  applyMask(mask) {
    const { size } = this;
    for (let y = 0; y < size; y += 1) {
      for (let x = 0; x < size; x += 1) {
        if (this.function[y * size + x]) continue;
        let invert;
        switch (mask) {
          case 0: invert = (x + y) % 2 === 0; break;
          case 1: invert = y % 2 === 0; break;
          case 2: invert = x % 3 === 0; break;
          case 3: invert = (x + y) % 3 === 0; break;
          case 4: invert = (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0; break;
          case 5: invert = ((x * y) % 2) + ((x * y) % 3) === 0; break;
          case 6: invert = (((x * y) % 2) + ((x * y) % 3)) % 2 === 0; break;
          default: invert = (((x + y) % 2) + ((x * y) % 3)) % 2 === 0;
        }
        if (invert) this.modules[y * size + x] ^= 1;
      }
    }
  }

  /** The standard's penalty: runs of five or more, finder-like 1:1:3:1:1 patterns, 2 × 2 blocks of one colour and the dark/light balance. */
  penaltyScore() {
    const { size } = this;
    let result = 0;
    // Rows, then columns.
    for (let pass = 0; pass < 2; pass += 1) {
      for (let a = 0; a < size; a += 1) {
        let runColor = false;
        let runLength = 0;
        const history = [0, 0, 0, 0, 0, 0, 0];
        for (let b = 0; b < size; b += 1) {
          const color = pass === 0 ? this.dark(b, a) : this.dark(a, b);
          if (color === runColor) {
            runLength += 1;
            if (runLength === 5) result += 3;
            else if (runLength > 5) result += 1;
          } else {
            this.addHistory(runLength, history);
            if (!runColor) result += this.patternCount(history) * 40;
            runColor = color;
            runLength = 1;
          }
        }
        let length = runLength;
        if (runColor) {   // the dark run that ends the row
          this.addHistory(length, history);
          length = 0;
        }
        length += size;   // the light border after the row
        this.addHistory(length, history);
        result += this.patternCount(history) * 40;
      }
    }
    for (let y = 0; y < size - 1; y += 1) {
      for (let x = 0; x < size - 1; x += 1) {
        const color = this.dark(x, y);
        if (color === this.dark(x + 1, y) && color === this.dark(x, y + 1) && color === this.dark(x + 1, y + 1)) result += 3;
      }
    }
    let darkCount = 0;
    for (const module of this.modules) darkCount += module;
    const total = size * size;
    const k = Math.floor((Math.abs(darkCount * 20 - total * 10) + total - 1) / total) - 1;
    result += Math.max(0, k) * 10;
    return result;
  }

  addHistory(runLength, history) {
    let length = runLength;
    if (history[0] === 0) length += this.size;   // the light border before the row
    history.pop();
    history.unshift(length);
  }

  patternCount(history) {
    const n = history[1];
    const core = n > 0 && history[2] === n && history[3] === n * 3 && history[4] === n && history[5] === n;
    return (core && history[0] >= n * 4 && history[6] >= n ? 1 : 0) + (core && history[6] >= n * 4 && history[0] >= n ? 1 : 0);
  }
}

/**
 * The centres of the alignment patterns along one side, the first and last beside the finders. The step is ISO/IEC 18004's for every version
 * up to 20, the most this encoder makes; of all 40 versions the formula misses only version 32's (26).
 */
function alignmentPositions(version) {
  if (version === 1) return [];
  const count = Math.floor(version / 7) + 2;
  const size = version * 4 + 17;
  const step = Math.floor((version * 4 + count * 2 + 1) / (count * 2 - 2)) * 2;
  const result = [6];
  for (let position = size - 7; result.length < count; position -= step) result.splice(1, 0, position);
  return result;
}
