// Settings › Video label (screens/settings.js labelsCardFor): a change sends only the setting changed, to every camera. Turning on seconds
// must not also copy the first camera's corner, size or "In Apple Home's video" onto the others (that last one makes the bridge convert their
// video, a large silent jump in work for the box).
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { installFakeBrowser } from './support/fake-browser.mjs';

let browser;
let labelsCardFor;
let sharedLabelStyle;
before(async () => {
  browser = installFakeBrowser();
  ({ labelsCardFor, sharedLabelStyle } = await import('../web/js/screens/settings.js'));
});
after(() => browser?.restore());

function all(root, match) {
  const out = [];
  const walk = (node) => { for (const child of node.childNodes ?? []) { if (child.tagName && match(child)) out.push(child); walk(child); } };
  walk(root);
  return out;
}
const text = (node) => node.textContent;
/** The switch whose row is titled `title`. */
function switchTitled(card, title) {
  const row = all(card, (node) => node.localName === 'label' && node.className === 'switch-row').find((label) => all(label, (n) => n.className === 'title')[0]?.textContent === title);
  return all(row, (node) => node.localName === 'input')[0];
}
function flip(input, checked) {
  input.checked = checked;
  input.dispatchEvent({ type: 'change', target: input });
}

const HOME = { enabled: true, position: 'bottomLeft', size: 'large', showCameraName: true, showDate: true, showSeconds: false, use24Hour: false };
const PLAIN = { enabled: false, position: 'topRight', size: 'medium', showCameraName: true, showDate: true, showSeconds: false, use24Hour: false };

test('a change sends that one setting to every camera, never the first camera’s others', () => {
  const sent = [];
  const cameras = [{ id: 'A', name: 'Porch', timestampOverlay: HOME }, { id: 'B', name: 'Garage', timestampOverlay: PLAIN }, { id: 'C', name: 'Side', timestampOverlay: PLAIN }];
  const card = labelsCardFor(cameras, { apply: (partial) => sent.push(partial) });
  flip(switchTitled(card, 'Seconds'), true);
  assert.deepEqual(sent, [{ showSeconds: true }]);
  flip(switchTitled(card, '24-hour time'), true);
  assert.deepEqual(sent.at(-1), { use24Hour: true });
  const corner = all(card, (node) => node.localName === 'select')[0];
  corner.value = 'topLeft';
  corner.dispatchEvent({ type: 'change', target: corner });
  assert.deepEqual(sent.at(-1), { position: 'topLeft' });
  assert.ok(sent.every((partial) => !('enabled' in partial)), 'Apple Home’s video is left as each camera has it');
});

test('where the cameras differ the card says so, and shows what most of them have', () => {
  const cameras = [{ id: 'A', timestampOverlay: HOME }, { id: 'B', timestampOverlay: PLAIN }, { id: 'C', timestampOverlay: PLAIN }];
  const { style, differ } = sharedLabelStyle(cameras);
  assert.equal(style.enabled, false, 'two of three have it off');
  assert.equal(style.position, 'topRight');
  assert.deepEqual([...differ].sort(), ['enabled', 'position', 'size']);
  const card = labelsCardFor(cameras, { apply: () => {} });
  assert.match(text(card), /Your cameras don’t all have the same label/);
  assert.equal(Boolean(switchTitled(card, 'In Apple Home’s video').checked), false);
  assert.match(text(card), /Not the same on every camera/);
});

test('cameras that agree show no such note; a camera with no settings has the bridge’s defaults', () => {
  const defaults = { ...PLAIN, showSeconds: true };
  const same = sharedLabelStyle([{ timestampOverlay: defaults }, { timestampOverlay: {} }, {}]);
  assert.equal(same.differ.size, 0);
  assert.deepEqual(same.style, defaults);
  const card = labelsCardFor([{ id: 'A', timestampOverlay: PLAIN }], { apply: () => {} });
  assert.doesNotMatch(text(card), /don’t all have the same label/);
});
