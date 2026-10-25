// The Sky Watcher page's Setup panel (screens/sky-card.js createSkySettingsCard, loaded by screens/sky-setup.js): where the box is, the flight
// feed with "Find a feed", and the AI's daily limit; a `<details>` that is open until the box has a place. They used to be a section of the
// Settings page, which no longer has one. In the fake browser with fake requests.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { after, before, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';

let browser;
let page;
let ApiError;
before(async () => {
  browser = installFakeBrowser();
  ({ ApiError } = await import('../web/js/api.js'));
  page = await import('../web/js/screens/sky-card.js');
});
after(() => browser?.restore());

const FEED = 'http://192.168.77.20/tar1090/data/aircraft.json';
const settingsWith = (sky) => ({ bridgeName: 'Bridge', sky: { location: null, flightFeedURL: null, aiDailyLimit: 50, ...sky } });
const PLACE = { latitude: 40, longitude: -100, heightMeters: 0 };

function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const visible = (node) => { for (let n = node; n; n = n.parentNode) if (n.hidden) return false; return true; };
const field = (root, name) => all(root, (node) => node.dataset?.field === name)[0];
const button = (root, text) => all(root, (node) => node.localName === 'button' && node.textContent === text && visible(node))[0];
const alerts = (root) => all(root, (node) => node.getAttribute?.('role') === 'alert' && visible(node)).map((node) => node.textContent).filter(Boolean);
function shown(root) {
  const parts = [];
  const walk = (node) => { if (node.hidden) return; if (node.data !== undefined) parts.push(node.data); for (const child of node.childNodes ?? []) walk(child); };
  walk(root);
  return parts.join(' ').replace(/\s+/g, ' ');
}
const settle = async () => { for (let i = 0; i < 6; i += 1) await new Promise((resolve) => setImmediate(resolve)); };
const type = (input, value) => { input.value = value; input.dispatchEvent({ type: 'input', target: input }); };

function cardWith(settings, { feeds = [FEED], refusals = [], geolocate, open } = {}) {
  const calls = { saves: [], finds: 0, adopted: [] };
  const card = page.createSkySettingsCard(settings, {
    save: async (partial) => {
      calls.saves.push(partial);
      const error = refusals.shift();
      if (error) throw error;
      return settingsWith({ ...settings.sky, ...partial, ...('location' in partial && partial.location ? { location: { ...partial.location, heightMeters: 0 } } : {}) });
    },
    find: async () => { calls.finds += 1; if (feeds instanceof Error) throw feeds; return { feeds }; },
    onSettings: (next) => calls.adopted.push(next),
    geolocate,
    open,   // undefined: the card’s own rule (open until the box has a place)
  });
  return { card, calls, refusals };
}

test('the card is the Setup panel: where the box is, the flight feed and the AI’s limit, as the bridge has them', () => {
  const { card } = cardWith(settingsWith({ location: PLACE, flightFeedURL: FEED, aiDailyLimit: 80 }), { open: true });
  assert.equal(all(card.el, (node) => node.localName === 'h2')[0].textContent, 'Setup');
  const text = shown(card.el);
  assert.match(text, /Where the box is/);
  assert.match(text, /Kept only on this box\./);
  assert.match(text, /Flight feed/);
  assert.match(text, /Asking the AI/);
  assert.match(text, /Most questions a day/);
  assert.equal(field(card.el, 'latitude').value, '40');
  assert.equal(field(card.el, 'longitude').value, '-100');
  assert.equal(field(card.el, 'feed').value, FEED);
  assert.equal(field(card.el, 'limit').value, '80');
  assert.ok(button(card.el, 'Use this browser’s location'));
  assert.ok(button(card.el, 'Find a feed'));
  assert.doesNotMatch(card.el.textContent, /Sky detector/i);
  const empty = cardWith(settingsWith({}));
  assert.equal(field(empty.card.el, 'latitude').value, '');
  assert.equal(field(empty.card.el, 'feed').value, '');
  assert.equal(field(empty.card.el, 'limit').value, '50', 'the bridge’s own default');
  assert.equal(button(empty.card.el, 'Remove the location'), undefined, 'nothing to remove');
});

test('the panel is a details that is open until the box has a place, and folded away after that', () => {
  const none = cardWith(settingsWith({}));
  assert.equal(none.card.el.localName, 'details');
  assert.equal(none.card.el.open, true, 'no place yet: open');
  assert.equal(all(none.card.el, (node) => node.localName === 'summary')[0].childNodes[0].localName, 'h2', 'the title is what is left when it is folded');
  const placed = cardWith(settingsWith({ location: PLACE }));
  assert.equal(placed.card.el.open, false, 'a place is set: folded');
  assert.match(shown(placed.card.el), /Setup/);
  // The person can open and fold it either way; saving does not fold it for them.
  placed.card.el.open = true;
  assert.equal(field(placed.card.el, 'latitude').value, '40');
  // `open` says it outright.
  assert.equal(cardWith(settingsWith({ location: PLACE }), { open: true }).card.el.open, true);
  assert.equal(cardWith(settingsWith({}), { open: false }).card.el.open, false);
  // A place that is not one is no place.
  assert.equal(cardWith({ sky: { location: { latitude: 'north', longitude: 5 } } }).card.el.open, true);
  assert.equal(cardWith({}).card.el.open, true, 'settings with no sky at all');
});

test('saving the location sends the place and says so; a place that is not one sends nothing; removing it sends null', async () => {
  const { card, calls } = cardWith(settingsWith({}));
  type(field(card.el, 'latitude'), '41.5');
  type(field(card.el, 'longitude'), '-100.25');
  button(card.el, 'Save the location').click();
  await settle();
  assert.deepEqual(calls.saves, [{ location: { latitude: 41.5, longitude: -100.25 } }]);
  assert.match(shown(card.el), /The location is saved on this box\./);
  assert.equal(calls.adopted.length, 1, 'the page takes the settings the bridge answered with');
  assert.ok(button(card.el, 'Remove the location'), 'now there is one to remove');

  type(field(card.el, 'latitude'), '95');
  button(card.el, 'Save the location').click();
  await settle();
  assert.equal(calls.saves.length, 1);
  assert.match(shown(card.el), /Latitude is a number from −90 to 90\./);

  type(field(card.el, 'latitude'), '');
  type(field(card.el, 'longitude'), '');
  button(card.el, 'Save the location').click();
  await settle();
  assert.equal(calls.saves.length, 1, 'both empty is not a place: it is removing one');
  button(card.el, 'Remove the location').click();
  await settle();
  assert.deepEqual(calls.saves.at(-1), { location: null });
  assert.match(shown(card.el), /The location is removed\./);
  assert.equal(field(card.el, 'latitude').value, '');
});

test('the browser’s location fills the fields, and a refusal says to type it in', async () => {
  const grant = { getCurrentPosition(ok) { ok({ coords: { latitude: 40.123456, longitude: -100.654321 } }); } };
  const { card, calls } = cardWith(settingsWith({}), { geolocate: grant });
  button(card.el, 'Use this browser’s location').click();
  await settle();
  assert.equal(field(card.el, 'latitude').value, '40.1235');
  assert.equal(field(card.el, 'longitude').value, '-100.6543');
  assert.deepEqual(calls.saves, [], 'it fills the fields; Save keeps them');
  const deny = cardWith(settingsWith({}), { geolocate: { getCurrentPosition(ok, fail) { fail({ code: 1 }); } } });
  button(deny.card.el, 'Use this browser’s location').click();
  await settle();
  assert.match(shown(deny.card.el), /This browser didn’t share its location\. Type it in instead\./);
});

test('the feed is saved, or taken off; Find a feed lists what answers on the network and Use this one keeps it', async () => {
  const { card, calls } = cardWith(settingsWith({ location: PLACE }), { feeds: [FEED, 'http://192.168.77.31:8080/data/aircraft.json'] });
  type(field(card.el, 'feed'), `  ${FEED}  `);
  button(card.el, 'Save').click();
  await settle();
  assert.deepEqual(calls.saves.at(-1), { flightFeedURL: FEED }, 'trimmed');
  type(field(card.el, 'feed'), '');
  button(card.el, 'Save').click();
  await settle();
  assert.deepEqual(calls.saves.at(-1), { flightFeedURL: null }, 'empty takes it off');

  button(card.el, 'Find a feed').click();
  await settle();
  assert.equal(calls.finds, 1);
  const found = all(card.el, (node) => node.localName === 'li' && visible(node) && /192\.168\.77\./.test(node.textContent)).map((node) => node.textContent);
  assert.equal(found.length, 2);
  assert.match(found[0], new RegExp(FEED.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  const use = all(card.el, (node) => node.localName === 'button' && node.textContent === 'Use this one' && visible(node));
  assert.equal(use.length, 2);
  use[1].click();
  await settle();
  assert.deepEqual(calls.saves.at(-1), { flightFeedURL: 'http://192.168.77.31:8080/data/aircraft.json' });
  assert.equal(field(card.el, 'feed').value, 'http://192.168.77.31:8080/data/aircraft.json');

  const none = cardWith(settingsWith({}), { feeds: [] });
  button(none.card.el, 'Find a feed').click();
  await settle();
  assert.match(shown(none.card.el), /No flight feed answered on your network\. Type its address in if you have one\./);

  const broken = cardWith(settingsWith({}), { feeds: new ApiError(0, 'network', 'The bridge didn’t answer.') });
  button(broken.card.el, 'Find a feed').click();
  await settle();
  assert.deepEqual(alerts(broken.card.el), ['The bridge didn’t answer.']);
});

test('what the bridge refuses is said in place, and the card keeps what was typed', async () => {
  const { card, calls, refusals } = cardWith(settingsWith({}));
  refusals.push(new ApiError(400, 'invalid', 'The flight feed’s address must start with http:// or https:// and name a computer.', 'sky.flightFeedURL'));
  type(field(card.el, 'feed'), 'ftp://x');
  button(card.el, 'Save').click();
  await settle();
  assert.deepEqual(alerts(card.el), ['The flight feed’s address must start with http:// or https:// and name a computer.']);
  assert.equal(field(card.el, 'feed').value, 'ftp://x', 'what was typed stays to be corrected');
  assert.equal(calls.saves.length, 1);

  // Settings answered again by the page's own draw: what is being typed is not overwritten.
  card.update(settingsWith({ flightFeedURL: null }));
  assert.equal(field(card.el, 'feed').value, 'ftp://x');
  type(field(card.el, 'feed'), FEED);
  button(card.el, 'Save').click();
  await settle();
  assert.deepEqual(alerts(card.el), []);
  card.update(settingsWith({ flightFeedURL: FEED, location: PLACE }));
  assert.equal(field(card.el, 'feed').value, FEED);
  assert.equal(field(card.el, 'latitude').value, '40', 'another browser’s change shows when nothing is being typed');
});

test('the AI’s daily limit is saved as a whole number from 1 to 1,000, and anything else is said in place and sends nothing', async () => {
  const { card, calls } = cardWith(settingsWith({ location: PLACE }), { open: true });
  const group = all(card.el, (node) => node.localName === 'fieldset').find((node) => node.childNodes[0].textContent === 'Asking the AI');
  assert.ok(group, 'a group about the AI');
  const save = button(group, 'Save the limit');
  assert.ok(save, 'its own button, not a second “Save”');
  type(field(card.el, 'limit'), ' 80 ');
  save.click();
  await settle();
  assert.deepEqual(calls.saves, [{ aiDailyLimit: 80 }]);
  assert.match(shown(card.el), /The limit is saved\./);
  assert.equal(field(card.el, 'limit').value, '80');
  assert.equal(calls.adopted.length, 1, 'the page takes the settings the bridge answered with');

  for (const bad of ['', '0', '1001', '-5', '5.5', 'many', '1e3', '12 days']) {
    type(field(card.el, 'limit'), bad);
    save.click();
    await settle();
    assert.deepEqual(alerts(card.el), ['Use a whole number from 1 to 1,000.'], JSON.stringify(bad));
    assert.equal(calls.saves.length, 1, `${JSON.stringify(bad)} sends nothing`);
  }
  for (const good of ['1', '1000', '50']) {
    type(field(card.el, 'limit'), good);
    save.click();
    await settle();
    assert.deepEqual(calls.saves.at(-1), { aiDailyLimit: Number(good) });
    assert.deepEqual(alerts(card.el), [], 'a good number takes the sentence away');
  }
});

test('the bridge’s refusal of the limit is said in place and what was typed stays; another browser’s change shows when nothing is being typed', async () => {
  const { card, calls, refusals } = cardWith(settingsWith({}));
  const save = button(card.el, 'Save the limit');
  refusals.push(new ApiError(400, 'invalid', 'The Sky Watcher’s daily limit for asking the AI is 1 to 1,000.', 'sky.aiDailyLimit'));
  type(field(card.el, 'limit'), '20');
  save.click();
  await settle();
  assert.deepEqual(alerts(card.el), ['The Sky Watcher’s daily limit for asking the AI is 1 to 1,000.']);
  assert.equal(field(card.el, 'limit').value, '20');
  assert.equal(calls.saves.length, 1);
  card.update(settingsWith({ aiDailyLimit: 70 }));
  assert.equal(field(card.el, 'limit').value, '20', 'what is being typed is not overwritten');
  save.click();
  await settle();
  assert.deepEqual(alerts(card.el), []);
  card.update(settingsWith({ aiDailyLimit: 70 }));
  assert.equal(field(card.el, 'limit').value, '70', 'nothing typed: the bridge’s word shows');
  assert.match(shown(card.el), /Set up the AI service in Settings/);
  assert.equal(all(card.el, (node) => node.localName === 'a' && node.textContent === 'Set up the AI service in Settings')[0].getAttribute('href'), '#/settings/ai');
});

test('the Settings page no longer has a Sky Watcher section: its setup is on the Sky Watcher page', async () => {
  const { renderSettings } = await import('../web/js/screens/settings.js');
  const realFetch = globalThis.fetch;
  const sent = [];
  const current = { ...settingsWith({ location: PLACE, flightFeedURL: FEED }), timeZone: 'UTC', logLevel: 'info', basePort: 21100, sensorsBridgePort: 21190, webhookEnabled: false, ai: { provider: null, keySaved: false } };
  globalThis.fetch = async (url, init = {}) => {
    sent.push(`${init.method ?? 'GET'} ${String(url).replace('/api/v1/', '')}`);
    if (String(url).endsWith('/api/v1/settings')) return new Response(JSON.stringify(current), { status: 200, headers: { 'Content-Type': 'application/json' } });
    throw new TypeError('fetch failed (no bridge in this test)');
  };
  let screen = null;
  try {
    screen = renderSettings({ params: [], setTitle: () => {} });
    for (let i = 0; i < 20; i += 1) await settle();
    const titles = all(screen.el, (node) => node.classList?.contains('section-title')).map((node) => node.textContent);
    assert.deepEqual(titles, ['General', 'Video and recording', 'Apple Home and other systems', 'AI', 'Troubleshooting'], 'the sections, in order');
    assert.equal(titles.indexOf('AI') + 1, titles.indexOf('Troubleshooting'), 'the AI section still sits right before Troubleshooting');
    assert.equal(all(screen.el, (node) => node.classList?.contains('sky-settings-card')).length, 0, 'no card of the Sky Watcher');
    assert.doesNotMatch(shown(screen.el), /Sky Watcher|Find a feed|Where the box is|Flight feed/);
    assert.equal(all(screen.el, (node) => node.dataset?.field === 'latitude').length, 0);
  } finally {
    screen?.destroy();
    globalThis.fetch = realFetch;
  }
});

test('Settings does not load the Sky Watcher’s card at all', () => {
  const source = readFileSync(new URL('../web/js/screens/settings.js', import.meta.url), 'utf8');
  assert.doesNotMatch(source, /sky-card\.js|createSkySettingsCard|skyCard/);
  assert.doesNotMatch(source, /section\('Sky Watcher'/);
});
