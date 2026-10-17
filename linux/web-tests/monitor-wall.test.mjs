// The Monitor wall's shape (screens/nvr-layout.js): the grid sizes keep their columns and rows with empty cells, the mosaic packs cameras by
// their picture's shape, and the wall's choices are kept on this browser.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  DEFAULT_ASPECT, DEFAULT_MOSAIC_MIN_WIDTH, MOSAIC_MAX_TILES, MOSAIC_MIN_WIDTHS, PACK_SLACK, WALL_GAP, WALL_KEYS,
  gridShape, layoutMosaicPage, packMosaic, packingBox, pictureAspect, pictureFit, readWallPrefs, wallCells, writeWallPref,
} from '../web/js/screens/nvr-layout.js';
import { PAGE_SIZES } from '../web/js/screens/nvr-model.js';
import { makeStorage } from './support/fake-browser.mjs';

const WIDE = 16 / 9;

// MARK: Grid shape

test('each grid size keeps its columns and rows: 2 × 2, 3 × 2, 3 × 3, 4 × 3 and 4 × 4', () => {
  assert.deepEqual(PAGE_SIZES.map((size) => [size, gridShape(size)]), [
    [4, { cols: 2, rows: 2 }], [6, { cols: 3, rows: 2 }], [9, { cols: 3, rows: 3 }], [12, { cols: 4, rows: 3 }], [16, { cols: 4, rows: 4 }],
  ]);
  assert.deepEqual(gridShape(1), { cols: 1, rows: 1 });
  assert.deepEqual(gridShape(2), { cols: 2, rows: 1 });
  assert.deepEqual(gridShape(5), { cols: 3, rows: 2 });
  for (let n = 1; n <= 16; n += 1) assert.ok(gridShape(n).cols * gridShape(n).rows >= n, `${n} cameras fit their grid`);
  assert.deepEqual(gridShape(0), { cols: 1, rows: 1 });
  assert.deepEqual(gridShape(40), { cols: 4, rows: 4 });
});

test('a chosen grid with fewer cameras keeps its shape and fills the rest with empty cells', () => {
  assert.deepEqual(wallCells({ perPage: 16, chosen: true, tiles: 5, total: 5 }), { count: 16, cols: 4, rows: 4, vacant: 11 });
  assert.deepEqual(wallCells({ perPage: 12, chosen: true, tiles: 7, total: 7 }), { count: 12, cols: 4, rows: 3, vacant: 5 });
  assert.deepEqual(wallCells({ perPage: 12, chosen: true, tiles: 12, total: 30 }), { count: 12, cols: 4, rows: 3, vacant: 0 });
  // Nothing chosen (the default of nine): the grid takes the cameras' shape, and keeps it on the last page.
  assert.deepEqual(wallCells({ perPage: 9, chosen: false, tiles: 2, total: 2 }), { count: 2, cols: 2, rows: 1, vacant: 0 });
  assert.deepEqual(wallCells({ perPage: 9, chosen: false, tiles: 1, total: 10 }), { count: 9, cols: 3, rows: 3, vacant: 8 });
  assert.deepEqual(wallCells({ perPage: 9, chosen: false, tiles: 0, total: 0 }), { count: 1, cols: 1, rows: 1, vacant: 1 });
});

test('monitor.css gives every tile count the columns and rows gridShape says', () => {
  const css = readFileSync(new URL('../web/monitor.css', import.meta.url), 'utf8');
  const rules = new Map();
  for (const match of css.matchAll(/\.monitor \.nvr-grid\[data-count="(\d+)"\] \{ --nvr-cols: (\d+); --nvr-rows: (\d+); \}/g)) {
    rules.set(Number(match[1]), { cols: Number(match[2]), rows: Number(match[3]) });
  }
  for (let n = 1; n <= 16; n += 1) assert.deepEqual(rules.get(n), gridShape(n), `data-count="${n}"`);
});

// MARK: The picture's shape

test('a camera’s shape is its main stream’s, else its sub stream’s, else a picture seen on the page, else 16:9', () => {
  const status = (main, sub) => ({ status: { mainStreamInfo: main, subStreamInfo: sub } });
  assert.equal(pictureAspect(status({ codec: 'h264', width: 2560, height: 1920 }, { codec: 'h264', width: 640, height: 360 })), 4 / 3);
  assert.equal(pictureAspect(status(null, { codec: 'h264', width: 640, height: 360 })), 16 / 9);
  assert.equal(pictureAspect(status(null, null), { width: 1440, height: 1920 }), 0.75);
  assert.equal(pictureAspect(status({ width: 0, height: 1080 }, { width: 'x', height: 2 }), { width: 1920, height: Number.NaN }), DEFAULT_ASPECT);
  assert.equal(pictureAspect(undefined), DEFAULT_ASPECT);
  assert.equal(pictureAspect({}), DEFAULT_ASPECT);
  assert.equal(DEFAULT_ASPECT, WIDE);
});

// MARK: Mosaic

/** The tiles of a page by row (a row is one `top`), top to bottom. */
function rowsOf(tiles) {
  const rows = new Map();
  for (const tile of tiles) rows.set(tile.top, [...(rows.get(tile.top) ?? []), tile]);
  return [...rows.entries()].sort((a, b) => a[0] - b[0]).map((entry) => entry[1]);
}

/**
 * Checks a page's tiles: whole pixels, inside the box, none overlapping, each with its picture's shape (to the pixel the rounding takes), every
 * row one height, and as large as they can be: every row fills the width (justified), or the rows fill the height.
 */
function checkPage(tiles, aspects, box, gap = 8) {
  assert.equal(tiles.length, aspects.length);
  tiles.forEach((tile, i) => {
    for (const key of ['left', 'top', 'width', 'height']) assert.ok(Number.isInteger(tile[key]), `tile ${i} ${key} is whole pixels`);
    assert.ok(tile.left >= 0 && tile.top >= 0, `tile ${i} starts inside`);
    assert.ok(tile.left + tile.width <= box.width, `tile ${i} ends inside across (${tile.left} + ${tile.width} > ${box.width})`);
    assert.ok(tile.top + tile.height <= box.height, `tile ${i} ends inside down (${tile.top} + ${tile.height} > ${box.height})`);
    assert.ok(tile.width > 0 && tile.height > 0, `tile ${i} has a size`);
    assert.ok(Math.abs(tile.width - aspects[i] * tile.height) <= aspects[i] + 1, `tile ${i} keeps its shape (${tile.width} × ${tile.height}, ${aspects[i]})`);
    for (let j = 0; j < i; j += 1) {
      const other = tiles[j];
      const apart = tile.left >= other.left + other.width || other.left >= tile.left + tile.width || tile.top >= other.top + other.height || other.top >= tile.top + tile.height;
      assert.ok(apart, `tiles ${j} and ${i} do not overlap`);
    }
  });
  if (tiles.length === 0) return;
  const rows = rowsOf(tiles);
  for (const row of rows) assert.equal(new Set(row.map((tile) => tile.height)).size, 1, 'a row is one height');
  const widths = rows.map((row) => row.reduce((sum, tile) => sum + tile.width, 0) + (row.length - 1) * gap);
  const used = rows.reduce((sum, row) => sum + row[0].height, 0) + (rows.length - 1) * gap;
  const acrossFull = rows.every((row, r) => widths[r] >= box.width - row.length - 1);
  const downFull = used >= box.height - rows.length - 1;
  assert.ok(acrossFull || downFull, `the tiles fill the width (${widths.join(', ')} of ${box.width}) or the height (${used} of ${box.height})`);
}

test('four wide cameras on a wide wall are two rows of two that fill it', () => {
  const box = { width: 1608, height: 908 };
  const layout = layoutMosaicPage([WIDE, WIDE, WIDE, WIDE], { ...box, gap: 8, minWidth: 320 });
  assert.equal(layout.fits, true);
  checkPage(layout.tiles, [WIDE, WIDE, WIDE, WIDE], box);
  assert.deepEqual(layout.tiles.map((tile) => [tile.left, tile.top]), [[0, 0], [808, 0], [0, 458], [808, 458]]);
  for (const tile of layout.tiles) assert.ok(tile.width >= 799 && tile.height >= 449, `${tile.width} × ${tile.height}`);
});

test('one camera fills as much of the wall as its shape allows, centred', () => {
  const layout = layoutMosaicPage([4 / 3], { width: 1600, height: 900, gap: 8, minWidth: 640 });
  assert.equal(layout.tiles.length, 1);
  assert.deepEqual(layout.tiles[0], { index: 0, left: 200, top: 0, width: 1200, height: 900 });
  assert.equal(layoutMosaicPage([], { width: 1600, height: 900, gap: 8, minWidth: 320 }).tiles.length, 0);
});

test('rows are justified: on a tall wall every row of a mixed page fills the width', () => {
  const aspects = [WIDE, 4 / 3, 0.75, WIDE, 2, WIDE, 4 / 3];
  const box = { width: 1400, height: 1400 };
  const layout = layoutMosaicPage(aspects, { ...box, gap: WALL_GAP, minWidth: 240 });
  assert.equal(layout.fits, true);
  checkPage(layout.tiles, aspects, box, WALL_GAP);
  const rows = rowsOf(layout.tiles);
  assert.ok(rows.length > 1, 'more than one row');
  for (const row of rows) {
    const used = row.reduce((sum, tile) => sum + tile.width, 0) + (row.length - 1) * WALL_GAP;
    assert.ok(used >= box.width - row.length - 1, `the row is ${used} px of ${box.width}`);
  }
  assert.deepEqual(layout.tiles.map((tile) => tile.index), [0, 1, 2, 3, 4, 5, 6], 'in list order');
});

test('the mosaic never puts a tile under the chosen width: what does not fit goes on the next page', () => {
  const nine = Array(9).fill(WIDE);
  const box = { width: 1208, height: 700 };
  const big = packMosaic(nine, { ...box, gap: 8, minWidth: 480 });
  assert.deepEqual(big.pages.map((page) => [page.start, page.count]), [[0, 4], [4, 4], [8, 1]]);
  for (const page of big.pages) {
    checkPage(page.layout.tiles, nine.slice(page.start, page.start + page.count), box);
    for (const tile of page.layout.tiles) assert.ok(tile.width >= 480, `${tile.width} px`);
    assert.equal(page.layout.fits, true);
  }
  const small = packMosaic(nine, { ...box, gap: 8, minWidth: 240 });
  assert.deepEqual(small.pages.map((page) => page.count), [9], 'three rows of three fit at 240 px');
  checkPage(small.pages[0].layout.tiles, nine, box);
  assert.ok(small.pages[0].layout.tiles.every((tile) => tile.width >= 390), 'as large as they can be');
});

test('a page holds at most 16 cameras, every camera is on one page in list order', () => {
  const twenty = Array(20).fill(WIDE);
  const packed = packMosaic(twenty, { width: 4000, height: 3000, gap: 8, minWidth: 240 });
  assert.deepEqual(packed.pages.map((page) => page.count), [MOSAIC_MAX_TILES, 4]);
  assert.deepEqual(packed.pages.map((page) => page.start), [0, 16]);
  const capped = packMosaic(twenty, { width: 4000, height: 3000, gap: 8, minWidth: 240, maxPerPage: 6 });
  assert.deepEqual(capped.pages.map((page) => page.count), [6, 6, 6, 2]);
});

test('cameras of every shape keep theirs and stay inside a short wall', () => {
  const aspects = [WIDE, 0.75, 4 / 3, 32 / 9, 9 / 16, WIDE, 1, 4 / 3];
  for (const box of [{ width: 1200, height: 420 }, { width: 700, height: 900 }, { width: 1920, height: 760 }]) {
    for (const minWidth of MOSAIC_MIN_WIDTHS) {
      const packed = packMosaic(aspects, { ...box, gap: 8, minWidth });
      assert.equal(packed.pages.reduce((sum, page) => sum + page.count, 0), aspects.length, `${box.width}×${box.height} at ${minWidth}`);
      for (const page of packed.pages) {
        assert.ok(page.count >= 1);
        const own = aspects.slice(page.start, page.start + page.count);
        checkPage(page.layout.tiles, own, box);
        if (page.count > 1) for (const tile of page.layout.tiles) assert.ok(tile.width >= minWidth, `${tile.width} < ${minWidth}`);
      }
    }
  }
});

test('a wall narrower than the chosen width shows one camera a page, still inside the wall', () => {
  const packed = packMosaic([WIDE, WIDE, 4 / 3], { width: 300, height: 600, gap: 8, minWidth: 400 });
  assert.deepEqual(packed.pages.map((page) => page.count), [1, 1, 1]);
  for (const page of packed.pages) {
    assert.equal(page.layout.fits, false);
    checkPage(page.layout.tiles, [[WIDE, WIDE, 4 / 3][page.start]], { width: 300, height: 600 });
    assert.equal(page.layout.tiles[0].width, 300);
  }
});

// MARK: Packing again

test('the pages are packed again when the wall gets narrower, wider or shorter, or much taller; a little taller keeps them', () => {
  const box = { width: 1530, height: 426 };
  assert.deepEqual(packingBox(null, { width: 1530, height: 480 }), { width: 1530, height: 480 });
  assert.equal(packingBox(box, { width: 1530, height: 426 }), box);
  assert.equal(packingBox(box, { width: 1530, height: 480 }), box, 'a notice or a wrapped row that went away gives room, not new pages');
  assert.deepEqual(packingBox(box, { width: 1530, height: 426 + PACK_SLACK }), { width: 1530, height: 426 + PACK_SLACK });
  assert.deepEqual(packingBox(box, { width: 1530, height: 400 }), { width: 1530, height: 400 }, 'shorter: the tiles must fit');
  assert.deepEqual(packingBox(box, { width: 1200, height: 426 }), { width: 1200, height: 426 });
  assert.equal(packingBox(box, { width: 1530, height: 0 }), null, 'a wall with no height has no pages of its own: the grid stands in');
  assert.equal(packingBox(box, null), null);
  assert.ok(PACK_SLACK > 54 + 40, 'more than the notice (54 px with its gap) and a wrapped row of the transport');
});

test('a notice that comes and goes with the page’s cameras packs the wall once more, not again and again', () => {
  // Safari plays 4 recordings at a time: a page of more shows the notice above the wall, 54 px with its gap (the reviewer's case: a 1786 px
  // window, the wall 1530 px wide, Min 400, eight 16:9 cameras, a 480 px wall).
  const aspects = Array(8).fill(WIDE);
  let box = null;
  let notice = false;
  let packs = 0;
  const shown = [];
  for (let frame = 0; frame < 12; frame += 1) {
    const next = packingBox(box, { width: 1530, height: 480 - (notice ? 54 : 0) });
    if (next !== box) { box = next; packs += 1; }
    const first = packMosaic(aspects, { ...box, gap: WALL_GAP, minWidth: 400 }).pages[0].count;
    shown.push(first);
    notice = first > 4;
  }
  assert.ok(packs <= 2, `packed ${packs} times`);
  assert.equal(new Set(shown.slice(2)).size, 1, `the page settles (${shown.join(', ')})`);
});

test('a mosaic tile shows its whole picture: its shape is the main stream’s, but Smooth plays the sub stream, often of another shape', () => {
  assert.equal(pictureFit({ solo: false, mosaic: true, chosen: 'fill' }), 'fit');
  assert.equal(pictureFit({ solo: true, mosaic: false, chosen: 'fill' }), 'fit', 'one camera on its own: the zoom maps the whole picture');
  assert.equal(pictureFit({ solo: false, mosaic: false, chosen: 'fill' }), 'fill', 'a grid: the person’s choice');
  assert.equal(pictureFit({ solo: false, mosaic: false, chosen: 'fit' }), 'fit');
  const nvr = readFileSync(new URL('../web/js/screens/nvr.js', import.meta.url), 'utf8');
  assert.match(nvr, /setData\(grid, 'fit', pictureFit\(/, 'the Monitor takes it from there');
});

test('the mosaic never draws over the controls under it, and the security mark moves away from a name in the top-left label', () => {
  const css = readFileSync(new URL('../web/monitor.css', import.meta.url), 'utf8');
  assert.match(css, /\.monitor \.nvr-grid\[data-layout="mosaic"\] \{[^}]*overflow: hidden/, 'a stale layout is clipped to the wall');
  assert.match(css, /\.nvr-tile\[data-labelname="true"\]\[data-labelpos="topLeft"\] \.nvr-tile-bar \{[^}]*justify-content: flex-end/);
  const nvr = readFileSync(new URL('../web/js/screens/nvr.js', import.meta.url), 'utf8');
  assert.match(nvr, /setData\(parts\.el, 'labelpos'/);
});

test('a wall that has no size yet packs nothing (the page then uses its fixed pages)', () => {
  assert.equal(packMosaic([WIDE], { width: 0, height: 600, minWidth: 320 }), null);
  assert.equal(packMosaic([WIDE], { width: 800, height: Number.NaN, minWidth: 320 }), null);
  assert.deepEqual(packMosaic([], { width: 800, height: 600, minWidth: 320 }).pages, []);
  const odd = packMosaic([Number.NaN, -1, 0, Infinity], { width: 1600, height: 900, gap: 8, minWidth: 240 });
  assert.equal(odd.pages[0].count, 4, 'a shape that makes no sense counts as 16:9');
  checkPage(odd.pages[0].layout.tiles, [WIDE, WIDE, WIDE, WIDE], { width: 1600, height: 900 });
});

// MARK: Choices kept on this browser

function storageFns(storage = makeStorage()) {
  return {
    storage,
    read: (key) => { try { return storage.getItem(key); } catch { return null; } },
    write: (key, value) => { try { storage.setItem(key, value); } catch { /* blocked */ } },
  };
}

test('with nothing kept the wall is a grid of nine (two on a phone), fitted, Full quality, mosaic at 320 px', () => {
  const { read } = storageFns();
  assert.deepEqual(readWallPrefs(read), { layout: 'grid', tiles: 9, tilesChosen: false, minWidth: DEFAULT_MOSAIC_MIN_WIDTH, fit: 'fit', quality: 'main' });
  assert.equal(readWallPrefs(read, { viewportWidth: 390 }).tiles, 2);
  assert.equal(DEFAULT_MOSAIC_MIN_WIDTH, 320);
  assert.deepEqual(MOSAIC_MIN_WIDTHS, [240, 320, 400, 480, 640]);
});

test('every choice is kept and read back the next time the Monitor opens', () => {
  const { storage, read, write } = storageFns();
  assert.equal(writeWallPref(write, 'quality', 'sub'), 'sub');
  assert.equal(writeWallPref(write, 'layout', 'mosaic'), 'mosaic');
  assert.equal(writeWallPref(write, 'minWidth', 480), 480);
  assert.equal(writeWallPref(write, 'fit', 'fill'), 'fill');
  assert.equal(writeWallPref(write, 'tiles', '12'), 12);
  assert.deepEqual(readWallPrefs(read), { layout: 'mosaic', tiles: 12, tilesChosen: true, minWidth: 480, fit: 'fill', quality: 'sub' });
  assert.equal(storage.getItem(WALL_KEYS.quality), 'sub');
  assert.equal(storage.getItem(WALL_KEYS.tiles), '12');
  assert.equal(WALL_KEYS.tiles, 'cb.nvr.tiles', 'the grid size keeps the key it always had');
  assert.equal(WALL_KEYS.quality, 'cb.monitor.quality', 'and so does the live quality');
  assert.equal(writeWallPref(write, 'quality', 'main'), 'main');
  assert.equal(readWallPrefs(read).quality, 'main');
  assert.equal(writeWallPref(write, 'layout', 'grid'), 'grid');
  assert.equal(readWallPrefs(read).layout, 'grid');
});

test('a value that makes no sense is not kept, and one found in storage counts as nothing kept', () => {
  const { storage, read, write } = storageFns();
  for (const [name, value] of [['quality', 'ultra'], ['layout', 'spiral'], ['minWidth', 100], ['minWidth', '320px'], ['fit', 'stretch'], ['tiles', 17], ['tiles', 'abc'], ['nothing', 1]]) {
    assert.equal(writeWallPref(write, name, value), null, `${name} ${value}`);
  }
  assert.equal(storage.length, 0);
  for (const key of Object.values(WALL_KEYS)) storage.setItem(key, 'garbage');
  assert.deepEqual(readWallPrefs(read), { layout: 'grid', tiles: 9, tilesChosen: false, minWidth: 320, fit: 'fit', quality: 'main' });
});

test('?tiles= wins over what is kept and shows that grid', () => {
  const { read, write } = storageFns();
  writeWallPref(write, 'layout', 'mosaic');
  writeWallPref(write, 'tiles', 4);
  assert.deepEqual(readWallPrefs(read, { query: '16' }), { layout: 'grid', tiles: 16, tilesChosen: true, minWidth: 320, fit: 'fit', quality: 'main' });
  assert.equal(readWallPrefs(read, { query: 'x' }).layout, 'mosaic', 'a query that is not a tile count changes nothing');
});

test('blocked storage: the wall opens with the defaults and a choice simply is not kept', () => {
  const { read, write } = storageFns(makeStorage({ broken: true }));
  assert.equal(writeWallPref(write, 'quality', 'sub'), 'sub');
  assert.deepEqual(readWallPrefs(read), { layout: 'grid', tiles: 9, tilesChosen: false, minWidth: 320, fit: 'fit', quality: 'main' });
});
