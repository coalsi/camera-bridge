// The shape of the Monitor's wall (screens/nvr.js): the grid sizes with their columns and rows, the mosaic that packs the cameras by their
// pictures' shape, and the wall's choices kept on this browser. No DOM and no globals, so Node tests run it as is.
import { MAX_TILES, chosenTileCount, resolveTileCount } from './nvr-model.js';

/** The space between tiles, in px (monitor.css `.monitor .nvr-grid { gap }`). */
export const WALL_GAP = 8;
/** The mosaic's "how many cameras go across" choices. */
export const MOSAIC_ACROSS = [2, 3, 4];
export const DEFAULT_MOSAIC_ACROSS = 3;
/** The old choice, "no tile narrower than" (px), is no longer offered; a kept one is read as the nearest count (`acrossFromMinWidth`). */
const LEGACY_MIN_WIDTHS = { 240: 4, 320: 3, 400: 3, 480: 2, 640: 2 };
export const acrossFromMinWidth = (value) => (/^[0-9]+$/.test(String(value)) ? LEGACY_MIN_WIDTHS[Number(value)] ?? null : null);
/** A page of the mosaic holds at most this many cameras (the session and the live request take 16). */
export const MOSAIC_MAX_TILES = MAX_TILES;
/** The shape of a picture nothing is known about. */
export const DEFAULT_ASPECT = 16 / 9;
/** Where the wall's choices are kept (localStorage). The grid size and the live quality keep the keys they always had. */
export const WALL_KEYS = Object.freeze({
  tiles: 'cb.nvr.tiles', layout: 'cb.monitor.layout', across: 'cb.monitor.mosaicAcross', legacyMinWidth: 'cb.monitor.mosaicMinWidth', fit: 'cb.monitor.fit', quality: 'cb.monitor.quality',
});

const MIN_ASPECT = 0.2;   // a stream that says it is narrower or wider than this is read as that (a stray size cannot make a sliver)
const MAX_ASPECT = 6;
const EPSILON = 1e-6;     // 449.99999999 is 450 px

// MARK: Grid

/** Columns and rows of a grid of `count` cameras: 2 across up to 4, 3 up to 9, 4 above (4 × 4 at most). */
export function gridShape(count) {
  const n = Math.min(Math.max(1, Math.trunc(count) || 1), MAX_TILES);
  const cols = n === 1 ? 1 : n <= 4 ? 2 : n <= 9 ? 3 : 4;
  return { cols, rows: Math.ceil(n / cols) };
}

/**
 * The cells of the grid on screen. A grid the person chose keeps its shape whatever the number of cameras; with nothing chosen it takes the
 * cameras' shape (up to the default size) and keeps it on the last page. `vacant`: the empty cells after the tiles.
 */
export function wallCells({ perPage, chosen = false, tiles = 0, total = 0 }) {
  const count = Math.max(1, chosen ? perPage : Math.min(perPage, total));
  const { cols, rows } = gridShape(count);
  return { count, cols, rows, vacant: Math.max(0, cols * rows - tiles) };
}

// MARK: The picture's shape

function ratioOf(size) {
  const width = Number(size?.width);
  const height = Number(size?.height);
  if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) return null;
  return Math.min(MAX_ASPECT, Math.max(MIN_ASPECT, width / height));
}

/**
 * Width over height of a camera's picture: its main stream (status.mainStreamInfo), else its sub stream, else `seen` (a picture the page has
 * shown: a recording's or the live video's size, or a snapshot's), else 16:9.
 */
export function pictureAspect(camera, seen = null) {
  return ratioOf(camera?.status?.mainStreamInfo) ?? ratioOf(camera?.status?.subStreamInfo) ?? ratioOf(seen) ?? DEFAULT_ASPECT;
}

const usableAspect = (a) => (Number.isFinite(a) && a > 0 ? Math.min(MAX_ASPECT, Math.max(MIN_ASPECT, a)) : DEFAULT_ASPECT);

// MARK: Mosaic

/**
 * For every number of rows, the cut of `aspects` (in order) into that many rows that are together the least tall when each row fills `width`:
 * balanced rows. Returns a list of cuts, each a list of [from, to) per row.
 */
function balancedCuts(aspects, width, gap) {
  const n = aspects.length;
  const prefix = [0];
  for (const a of aspects) prefix.push(prefix[prefix.length - 1] + a);
  const rowHeight = (i, j) => {
    const room = width - (j - i - 1) * gap;
    return room > 0 ? room / (prefix[j] - prefix[i]) : Infinity;
  };
  // least[r][j]: the least height of the first j pictures in r rows; from[r][j]: where the last of those rows starts.
  const least = [[0, ...Array(n).fill(Infinity)]];
  const from = [[]];
  const cuts = [];
  for (let r = 1; r <= n; r += 1) {
    least[r] = Array(n + 1).fill(Infinity);
    from[r] = Array(n + 1).fill(-1);
    for (let j = r; j <= n; j += 1) {
      for (let i = r - 1; i < j; i += 1) {
        const height = least[r - 1][i] + rowHeight(i, j);
        if (height < least[r][j]) { least[r][j] = height; from[r][j] = i; }
      }
    }
    if (!Number.isFinite(least[r][n])) continue;
    const rows = [];
    for (let k = r, j = n; k >= 1; k -= 1) { const i = from[k][j]; rows.unshift([i, j]); j = i; }
    cuts.push(rows);
  }
  return cuts;
}

/** The tiles of one cut: each row as tall as fills the width, all of them made smaller together when they are taller than the wall; centred. */
function place(aspects, rows, { width, height, gap, across = 0 }) {
  const natural = rows.map(([i, j]) => (width - (j - i - 1) * gap) / aspects.slice(i, j).reduce((sum, a) => sum + a, 0));
  // A last row with fewer cameras than the others is not stretched to the full width: it is no taller than the row above, and centred.
  const last = rows.length - 1;
  if (across > 0 && last > 0 && rows[last][1] - rows[last][0] < across) natural[last] = Math.min(natural[last], natural[last - 1]);
  const room = height - (rows.length - 1) * gap;
  if (room <= 0) return null;
  const scale = Math.min(1, room / natural.reduce((sum, h) => sum + h, 0));
  const heights = natural.map((h) => Math.floor(h * scale + EPSILON));
  if (heights.some((h) => h < 1)) return null;
  const used = heights.reduce((sum, h) => sum + h, 0) + (rows.length - 1) * gap;
  const tiles = [];
  let top = Math.floor((height - used) / 2);
  let smallest = Infinity;
  let area = 0;
  rows.forEach(([i, j], r) => {
    const exact = natural[r] * scale;
    const widths = aspects.slice(i, j).map((a) => Math.max(1, Math.floor(a * exact + EPSILON)));
    let left = Math.floor((width - widths.reduce((sum, w) => sum + w, 0) - (j - i - 1) * gap) / 2);
    widths.forEach((w, k) => {
      tiles.push({ index: i + k, left: Math.max(0, left), top, width: w, height: heights[r] });
      smallest = Math.min(smallest, w);
      area += w * heights[r];
      left += w + gap;
    });
    top += heights[r] + gap;
  });
  return { tiles, smallest, area, scale };
}

/**
 * One page of the mosaic: `aspects` (width / height of each picture, in order) in rows of `across` cameras (the last row may hold fewer), each
 * row justified to the width with every picture in its own shape, all inside `width` × `height` (px).
 * -> { fits, tiles: [{ index, left, top, width, height }] }, whole pixels; `fits` false: the rows are taller than the wall and were made
 * smaller together.
 */
export function layoutMosaicPage(aspects, { width, height, gap = WALL_GAP, across = DEFAULT_MOSAIC_ACROSS }) {
  const own = aspects.map(usableAspect);
  if (own.length === 0) return { fits: true, tiles: [] };
  const rows = [];
  for (let i = 0; i < own.length; i += across) rows.push([i, Math.min(own.length, i + across)]);
  const layout = place(own, rows, { width, height, gap, across });
  return { fits: layout !== null && layout.scale >= 1 - EPSILON, tiles: layout?.tiles ?? [] };
}

/**
 * The whole mosaic: as many cameras on each page as fit (at most `maxPerPage`, at least one row), in list order. A page ends on a full row
 * (a multiple of `across`) unless it holds the last cameras, so only the last row of the mosaic is short.
 * -> { pages: [{ start, count, layout }] } (layout as layoutMosaicPage gives it), or null while the wall has no size.
 */
export function packMosaic(aspects, { width, height, gap = WALL_GAP, across = DEFAULT_MOSAIC_ACROSS, maxPerPage = MOSAIC_MAX_TILES }) {
  if (![width, height].every((v) => Number.isFinite(v) && v > 0)) return null;
  const options = { width, height, gap, across };
  const pages = [];
  for (let start = 0; start < aspects.length;) {
    const remaining = aspects.length - start;
    const most = Math.min(Math.max(across, maxPerPage), remaining);
    let chosen = null;
    const counts = [];
    for (let count = Math.min(across, remaining); count <= most; count += across) counts.push(count);
    if (remaining <= most && !counts.includes(remaining)) counts.push(remaining);
    for (const count of counts) {
      const layout = layoutMosaicPage(aspects.slice(start, start + count), options);
      if (layout.fits || chosen === null) chosen = { start, count, layout };    // one row goes on a page even when it is too tall
    }
    pages.push(chosen);
    start += chosen.count;
  }
  return { pages };
}

/** How much taller the wall may get before the mosaic is packed again, in px: more than the notice above the wall (54 px with its gap) and a
 *  wrapped row of the transport, which come and go with the page's cameras. */
export const PACK_SLACK = 96;

/**
 * The box the mosaic's pages are packed into, from the one they were packed into (`previous`) and the wall's size now (`measured`): the new
 * size when the width changed, the wall got shorter (the tiles must fit) or `slack` px or more taller; else `previous` itself, so a notice or a
 * wrapped row that the new pages hide does not pack the wall again, and again (the tiles are still placed in the wall as it is: they only get
 * larger). nil for a wall without a size (no pages of its own: the grid's stand in).
 */
export function packingBox(previous, measured, slack = PACK_SLACK) {
  if (!measured || !(measured.width > 0 && measured.height > 0)) return null;
  if (!previous || previous.width !== measured.width || measured.height < previous.height || measured.height - previous.height >= slack) {
    return { width: measured.width, height: measured.height };
  }
  return previous;
}

/** How a picture sits in its tile: whole (`fit`) for one camera on its own and in the mosaic (a tile has the main stream's shape, but live video
 *  in Smooth is the sub stream, often of another shape, and is never cut), else the grid's choice (`chosen`). */
export function pictureFit({ solo, mosaic, chosen }) {
  return solo || mosaic ? 'fit' : chosen === 'fill' ? 'fill' : 'fit';
}

// MARK: Choices kept on this browser

const VALUES = {
  layout: (value) => (value === 'grid' || value === 'mosaic' ? value : null),
  tiles: (value) => chosenTileCount({ stored: String(value) }),
  across: (value) => (/^[0-9]+$/.test(String(value)) && MOSAIC_ACROSS.includes(Number(value)) ? Number(value) : null),
  legacyMinWidth: acrossFromMinWidth,
  fit: (value) => (value === 'fit' || value === 'fill' ? value : null),
  quality: (value) => (value === 'main' || value === 'sub' ? value : null),
};

/**
 * The wall's choices: `read(key)` gives the kept text or null (nvr.js readStored). A value that makes no sense counts as nothing kept.
 * `?tiles=` (`query`) shows that grid. -> { layout: 'grid' | 'mosaic', tiles, tilesChosen, across, fit: 'fit' | 'fill', quality: 'main' | 'sub' }
 * (live video in Full quality unless Smooth was chosen).
 */
export function readWallPrefs(read, { query = null, viewportWidth = Infinity } = {}) {
  const stored = (name) => VALUES[name](read(WALL_KEYS[name]));
  const queried = chosenTileCount({ query });
  const tilesText = read(WALL_KEYS.tiles);
  return {
    layout: queried !== null ? 'grid' : stored('layout') ?? 'grid',
    tiles: resolveTileCount({ query, stored: tilesText, viewportWidth }),
    tilesChosen: chosenTileCount({ query, stored: tilesText }) !== null,
    across: stored('across') ?? stored('legacyMinWidth') ?? DEFAULT_MOSAIC_ACROSS,
    fit: stored('fit') ?? 'fit',
    quality: stored('quality') ?? 'main',
  };
}

/** Keeps one choice (`name`: layout, tiles, across, fit, quality) with `write(key, text)`. Returns the value kept, or null for one that makes no sense. */
export function writeWallPref(write, name, value) {
  const valid = Object.hasOwn(VALUES, name) && name !== 'legacyMinWidth' ? VALUES[name](value) : null;
  if (valid !== null) write(WALL_KEYS[name], String(valid));
  return valid;
}
