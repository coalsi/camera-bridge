// nvr/clip.js: the words and the address of a clip (the flow itself is DOM and is looked at in the browser).
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { MINIMUM_MS, WORDS, clipUrl, durationText, rangeText } from '../web/js/nvr/clip.js';

describe('clip words', () => {
  it('writes a duration as m:ss or h:mm:ss', () => {
    assert.equal(durationText(5_000), '0:05');
    assert.equal(durationText(65_400), '1:05');
    assert.equal(durationText(3_723_000), '1:02:03');
  });

  it('names the date of the end only when it is another day', () => {
    const start = new Date(2026, 9, 13, 23, 50, 0).getTime();
    const sameDay = rangeText(start, new Date(2026, 9, 13, 23, 59, 0).getTime());
    const nextDay = rangeText(start, new Date(2026, 9, 14, 0, 10, 0).getTime());
    assert.match(sameDay, / to \d{1,2}:\d{2}:\d{2}/);
    assert.ok(!/Oct.*to .*Oct/.test(sameDay));
    assert.ok(/Oct.* to .*14/.test(nextDay) || /14.* to .*14/.test(nextDay), nextDay);
  });

  it('builds the address of a part from whole milliseconds and an encoded zone', () => {
    assert.equal(clipUrl('abc', 1000.4, 2000.6, 2, 'Europe/Berlin'), '/api/v1/nvr/cameras/abc/clip?from=1000&to=2001&tz=Europe%2FBerlin&part=2');
  });

  it('shares the sentences with the Mac app', () => {
    assert.equal(MINIMUM_MS, 1000);
    assert.equal(WORDS.tooShort, 'Move the end at least 1 second from the start.');
    assert.equal(WORDS.nothing, 'Nothing was recorded in this time.');
  });
});
