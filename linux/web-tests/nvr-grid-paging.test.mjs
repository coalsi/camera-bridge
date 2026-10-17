import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  parseEpochMs, resolveTileCount, chosenTileCount, pageCount, clampPage, pageSlice, pageRanges, gridPath, watchPath, chooseWaveformCameras,
} from '../web/js/screens/nvr-model.js';

const id = (n) => `00000000-0000-4000-8000-00000000000${n}`;
const T0 = 1760099000000;

// MARK: route, tile count, paging, paths

test('parseEpochMs accepts only whole milliseconds inside the API range', () => {
  assert.equal(parseEpochMs('1760099000000'), 1760099000000);
  assert.equal(parseEpochMs(1760099000000), 1760099000000);
  for (const bad of [undefined, null, '', 'abc', '17600990000x', '1.5', '-1', '123', '978307199999', '4102444800001', '1760099000000000']) {
    assert.equal(parseEpochMs(bad), null, String(bad));
  }
});

test('the tile count is the query, then the stored value, then 9 (2 on a phone), always 1 to 16', () => {
  assert.equal(resolveTileCount({}), 9);
  assert.equal(resolveTileCount({ viewportWidth: 390 }), 2);
  assert.equal(resolveTileCount({ viewportWidth: 640 }), 2);
  assert.equal(resolveTileCount({ viewportWidth: 641 }), 9);
  assert.equal(resolveTileCount({ query: '16', stored: '3', viewportWidth: 390 }), 16);
  assert.equal(resolveTileCount({ query: null, stored: '12' }), 12);
  for (const bad of ['0', '17', '-2', 'abc', '', '2.5', ' ']) {
    assert.equal(resolveTileCount({ query: bad, stored: '6' }), 6, `query ${JSON.stringify(bad)}`);
    assert.equal(resolveTileCount({ query: null, stored: bad }), 9, `stored ${JSON.stringify(bad)}`);
  }
});

test('paging: 9 cameras at 4 a page are 3 pages of 4, 4 and 1; the page is clamped', () => {
  const list = Array.from({ length: 9 }, (_, i) => i);
  assert.equal(pageCount(9, 4), 3);
  assert.deepEqual(pageSlice(list, 0, 4), [0, 1, 2, 3]);
  assert.deepEqual(pageSlice(list, 1, 4), [4, 5, 6, 7]);
  assert.deepEqual(pageSlice(list, 2, 4), [8]);
  assert.deepEqual(pageSlice(list, 7, 4), [8]);
  assert.deepEqual(pageSlice(list, -3, 4), [0, 1, 2, 3]);
  assert.equal(clampPage(Number.NaN, 9, 4), 0);
  assert.equal(pageCount(0, 4), 1);
  assert.deepEqual(pageSlice([], 0, 4), []);
  assert.equal(pageCount(8, 4), 2);
});

test('a tile count counts as chosen only when the query or the stored value is one', () => {
  assert.equal(chosenTileCount({}), null);
  assert.equal(chosenTileCount({ query: '12' }), 12);
  assert.equal(chosenTileCount({ query: 'abc', stored: '4' }), 4);
  assert.equal(chosenTileCount({ query: null, stored: '17' }), null);
});

test('pages as ranges: fixed sizes, or the lengths the mosaic gives, the rest in fixed pages', () => {
  assert.deepEqual(pageRanges(9, 4), [[0, 4], [4, 8], [8, 9]]);
  assert.deepEqual(pageRanges(0, 4), [[0, 0]], 'an empty bridge has one empty page');
  assert.deepEqual(pageRanges(9, 4, [3, 4, 2]), [[0, 3], [3, 7], [7, 9]]);
  assert.deepEqual(pageRanges(9, 4, [5]), [[0, 5], [5, 9]], 'lengths that stop short: the rest in pages of perPage');
  assert.deepEqual(pageRanges(5, 4, [3, 4, 2]), [[0, 3], [3, 5]], 'lengths past the end stop at the last camera');
  assert.deepEqual(pageRanges(9, 4, [3, 0, 2]), [[0, 4], [4, 8], [8, 9]], 'a length that is not a whole number above 0: fixed pages');
  assert.deepEqual(pageRanges(9, 4, 'x'), [[0, 4], [4, 8], [8, 9]]);
  assert.deepEqual(pageRanges(3, 4, []), [[0, 3]]);
});

test('the grid and watch paths carry a time only when it is a real one', () => {
  assert.equal(gridPath(null), '/nvr');
  assert.equal(gridPath(T0 + 0.4), `/nvr/${T0}`);
  assert.equal(gridPath(5), '/nvr');
  assert.equal(gridPath(Number.NaN), '/nvr');
  assert.equal(watchPath(id(1), null), `/camera/${id(1)}/watch`);
  assert.equal(watchPath(id(1), T0), `/camera/${id(1)}/watch/${T0}`);
  assert.throws(() => watchPath('../x', T0), RangeError);
  assert.throws(() => watchPath(`${id(1)}/../`, null), RangeError);
});

test('the waveform takes the cameras that have recordings, in list order, at most 16', () => {
  const cameras = Array.from({ length: 20 }, (_, i) => ({ id: `c${i}` }));
  const withFootage = new Set(cameras.map((c) => c.id).filter((_, i) => i !== 3));
  const chosen = chooseWaveformCameras(cameras, (cid) => (withFootage.has(cid) ? { oldest: 1 } : null));
  assert.equal(chosen.ids.length, 16);
  assert.equal(chosen.ids.includes('c3'), false);
  assert.equal(chosen.ids[0], 'c0');
  assert.equal(chosen.truncated, true);
  assert.deepEqual(chooseWaveformCameras(cameras.slice(0, 2), () => null), { ids: [], truncated: false });
});
