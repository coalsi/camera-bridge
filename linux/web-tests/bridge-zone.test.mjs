// One label everywhere: the page says every time in the bridge's time zone (store.js bridgeZone), not the browser's. This process runs in Tokyo
// (TZ), the bridge is in Phoenix: the Monitor's clock and labels, the Events page's "Today" and day groups, the Log and the clips' file names all
// follow Phoenix.
process.env.TZ = 'Asia/Tokyo';

const { test } = await import('node:test');
const assert = (await import('node:assert/strict')).default;
const { bridgeZone, setBridgeZone, store, subscribe } = await import('../web/js/store.js');
const { stampText } = await import('../web/js/stamp.js');
const { labelLine } = await import('../web/js/labels.js');
const { clock, dateTime, timeOfDay } = await import('../web/js/format.js');
const { aiSettingsView } = await import('../web/js/screens/ai-settings.js');
const { emptyFilters, filterEvents, groupByDay, queryRange } = await import('../web/js/screens/events-model.js');
const { rangeText } = await import('../web/js/nvr/clip.js');
const {
  browserZone, sameClock, sameZonedDay, startOfZonedDay, zoneShortName, zonedDayKey, zonedInputs, zonedInstant, zonedParts,
} = await import('../web/js/zone.js');

const PHOENIX = 'America/Phoenix';
// 2026-10-31 23:30 in Phoenix (UTC−7) is 2026-11-01 06:30 UTC and 15:30 in Tokyo: another day in each.
const LATE = Date.UTC(2026, 10, 1, 6, 30, 0);

test('this test really runs in another zone than the bridge’s', () => {
  assert.equal(browserZone(), 'Asia/Tokyo');
  assert.equal(new Date(LATE).getHours(), 15, 'Tokyo');
});

test('the bridge’s zone is the browser’s until the settings say another; an unknown name counts as none', () => {
  setBridgeZone(null);
  assert.equal(bridgeZone(), 'Asia/Tokyo');
  const seen = [];
  const off = subscribe((kind) => { if (kind === 'zone') seen.push(store.timeZone); });
  setBridgeZone(PHOENIX);
  assert.equal(bridgeZone(), PHOENIX);
  setBridgeZone(PHOENIX);
  setBridgeZone('Not/AZone');
  assert.equal(bridgeZone(), 'Asia/Tokyo');
  setBridgeZone(PHOENIX);
  off();
  assert.deepEqual(seen, [PHOENIX, null, PHOENIX], 'told once per change');
});

test('the clock on every picture and the video label tell the bridge’s time', () => {
  setBridgeZone(PHOENIX);
  assert.match(stampText(LATE), /Sat.*31 Oct|Sat.*Oct 31/);
  assert.match(stampText(LATE), /11:30:00\s?PM/);
  const camera = { name: 'Front', timestampOverlay: { use24Hour: true } };
  assert.match(labelLine(camera, LATE), /^Front {2}\| {2}Sat, Oct 31 {2}23:30:00$/);
  assert.match(clock(LATE), /23:30:00|11:30:00/, 'the Log');
  assert.match(dateTime(LATE), /Oct 31, 2026/, 'storage and archive');
  assert.match(timeOfDay(LATE), /^(11:30\sPM|23:30)$/);
  assert.match(aiSettingsView({ ai: { provider: 'anthropic', retryAt: new Date(LATE).toISOString() } }).retry, /trying again at (11:30\sPM|23:30)\.$/,
    'when AI descriptions try the service again');
  assert.equal(clock('not a time'), '');
  assert.equal(timeOfDay('not a time'), '');
});

test('the Events page: "Today" starts at the bridge’s midnight, and the days are the bridge’s', () => {
  setBridgeZone(PHOENIX);
  const midnight = Date.UTC(2026, 9, 31, 7, 0, 0);   // 2026-10-31 00:00 in Phoenix
  assert.equal(queryRange({ ...emptyFilters(), range: 'today' }, LATE, PHOENIX).fromMs, midnight);
  const events = [
    { at: LATE - 60_000, cameraId: 'a', label: 'Motion', description: null },            // 23:29 on the 31st
    { at: midnight - 60_000, cameraId: 'a', label: 'Motion', description: null },        // 23:59 on the 30th
    { at: midnight - 25 * 3_600_000, cameraId: 'a', label: 'Motion', description: null },  // the 29th
  ];
  assert.equal(filterEvents(events, { ...emptyFilters(), range: 'today' }, { now: LATE, zone: PHOENIX }).length, 1);
  const groups = groupByDay(events, LATE, PHOENIX);
  assert.deepEqual(groups.map((group) => group.label.startsWith('Today') || group.label.startsWith('Yesterday') ? group.label : 'date'), ['Today', 'Yesterday', 'date']);
  assert.match(groups[2].label, /Thursday/, '29 October 2026 was a Thursday in Phoenix');
  // In Tokyo the same three are on the 1st, the 31st and the 30th, so the groups would be different: they are not.
  assert.notEqual(new Date(LATE).getDate(), 31);
});

test('a clip’s range is said in the bridge’s zone, the end naming its date only on another day', () => {
  setBridgeZone(PHOENIX);
  assert.match(rangeText(LATE - 600_000, LATE), /^Oct 31, 11:20:00\s?PM to 11:30:00\s?PM$|^31 Oct, 23:20:00 to 23:30:00$/);
  assert.match(rangeText(LATE, LATE + 3_600_000), /to Nov 1, 12:30:00\s?AM$|to 1 Nov, 00:30:00$/);
});

test('zone helpers: days, midnights, the short name and the date and time fields', () => {
  assert.equal(zonedDayKey(LATE, PHOENIX), '2026-10-31');
  assert.equal(zonedDayKey(LATE, 'Asia/Tokyo'), '2026-11-01');
  assert.equal(sameZonedDay(LATE, LATE - 23 * 3_600_000, PHOENIX), true);
  assert.equal(startOfZonedDay(LATE, PHOENIX), Date.UTC(2026, 9, 31, 7));
  assert.equal(zoneShortName(PHOENIX, LATE, 'en-US'), 'MST');
  assert.equal(sameClock(PHOENIX, 'America/Denver', Date.UTC(2026, 0, 15)), true, 'Denver keeps Phoenix’s time in winter');
  assert.equal(sameClock(PHOENIX, 'America/Denver', Date.UTC(2026, 6, 15)), false, 'not in summer');
  assert.deepEqual(zonedInputs(LATE, PHOENIX), { date: '2026-10-31', time: '23:30' });
  assert.equal(zonedInstant('2026-10-31', '23:30', PHOENIX), LATE);
  assert.equal(zonedInstant('2026-10-31', '23:30:15', PHOENIX), LATE + 15_000);
  assert.equal(zonedInstant('31/10/2026', '23:30', PHOENIX), null);
  assert.equal(zonedInstant('2026-10-31', '25:00', PHOENIX), null);
});

test('a time typed in a zone that changes its clocks: the hour that comes twice is the first, the hour that is skipped moves on', () => {
  const LA = 'America/Los_Angeles';
  // 2026-11-01 01:30 happens twice in Los Angeles (PDT, then PST): the first.
  assert.equal(zonedInstant('2026-11-01', '01:30', LA), Date.UTC(2026, 10, 1, 8, 30));
  // 2026-03-08 02:30 does not exist there: an hour on, 03:30 PDT.
  assert.equal(zonedInstant('2026-03-08', '02:30', LA), Date.UTC(2026, 2, 8, 10, 30));
  const p = zonedParts(zonedInstant('2026-03-08', '02:30', LA), LA);
  assert.deepEqual([p.hour, p.minute], [3, 30]);
  assert.equal(zonedInstant('2026-03-08', '03:30', LA), Date.UTC(2026, 2, 8, 10, 30));
  assert.equal(zonedInstant('2026-07-01', '12:00', LA), Date.UTC(2026, 6, 1, 19, 0));
});
