// The close-up rule of Sky Watcher's cards (screens/sky-model.js closeUpRect and thumbRect) as a list of cases, for the box's Swift copy of it
// (Packages/CameraBridgeKit/Sources/BridgeEngine/Sky/SkyCloseUp.swift) to be tested against: the thumbnail the box cuts must be the rectangle the page
// draws the light's path in, to the pixel. The page's functions are the reference; the cases are theirs.
//
//   node linux/web-tests/support/sky-closeup-vectors.mjs     writes Packages/CameraBridgeKit/Tests/BridgeEngineTests/Fixtures/sky-closeup-vectors.json
//
// sky-model.test.mjs fails when the file is not what this makes now; Swift's `SkyCloseUpTests` reads it and checks every case.
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { closeUpRect, thumbRect } from '../../web/js/screens/sky-model.js';

export const VECTORS_PATH = join(dirname(fileURLToPath(import.meta.url)), '../../../Packages/CameraBridgeKit/Tests/BridgeEngineTests/Fixtures/sky-closeup-vectors.json');

/** The sizes of the pictures the cases are for: the box keeps stills at most 1920 wide, in the camera's own shape. */
const PICTURES = [[1920, 1080], [1920, 852], [1920, 540], [1920, 1086], [1920, 1440], [1280, 720], [640, 360], [400, 177], [2560, 1440], [3840, 1080], [4256, 1888], [1921, 853]];

/** Small numbers from a seed (mulberry32), so that the cases are the same every time. */
function seeded(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6D2B79F5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const four = (value) => Math.round(value * 1e4) / 1e4;

/** { about, cases: [{ path: [[x, y]], picture: [width, height], closeUp, thumb }] }: closeUp is closeUpRect's answer, thumb thumbRect's (null: none). */
export function makeCloseUpVectors() {
  const paths = [
    [[0.5, 0.5]], [[0, 0]], [[1, 1]], [[1, 0]], [[0, 1]], [[0.98, 0.97], [0.995, 0.99]], [[0.01, 0.5], [0.03, 0.52]], [[0.5, 0.3]],
    [[0.45, 0.4], [0.5, 0.42], [0.55, 0.45]], [[0.1, 0.2], [0.3, 0.25]], [[0.2, 0.3], [0.7, 0.6]], [[0.05, 0.1], [0.95, 0.9]], [[0.5, 0.1], [0.5, 0.9]],
    [[0.1, 0.5], [0.9, 0.5]], [[-0.2, 0.5], [0.1, 0.6]], [[0.9, 0.5], [1.3, 0.6]], [[0.3333, 0.3333], [0.3334, 0.3334]], [[0.9999, 0.5]], [[0.5, 0.0001]],
    [[0.25, 0.25], [0.26, 0.26], [0.27, 0.24], [0.28, 0.25], [0.29, 0.26]], [],
  ];
  const cases = [];
  const add = (path, picture) => {
    const points = path.map(([x, y], i) => [i, x, y]);
    cases.push({
      path, picture, closeUp: closeUpRect(points, picture[0], picture[1]), thumb: thumbRect(points, picture[0], picture[1]),
    });
  };
  for (const picture of PICTURES) for (const path of paths) add(path, picture);

  const rand = seeded(20261026);
  const spreads = [0.001, 0.02, 0.05, 0.1, 0.2, 0.35, 0.6, 0.95];
  for (let i = 0; i < 160; i += 1) {
    const picture = PICTURES[Math.floor(rand() * PICTURES.length)];
    const spread = spreads[Math.floor(rand() * spreads.length)];
    const cx = rand();
    const cy = rand();
    const count = 1 + Math.floor(rand() * 5);
    const path = Array.from({ length: count }, () => [four(cx + (rand() - 0.5) * spread), four(cy + (rand() - 0.5) * spread * 0.6)]);
    add(path, picture);
  }
  return {
    about: 'Cases for the close-up rule of the Sky Watcher cards: path [[x, y]] (0 to 1 of the picture), picture [width, height] in pixels, closeUp (sky-model.js closeUpRect) and thumb (thumbRect, whole pixels), null for none. Made by linux/web-tests/support/sky-closeup-vectors.mjs.',
    cases,
  };
}

/** The file as it is written: one case to a line, so that a change shows in a diff. */
export function vectorsText(vectors = makeCloseUpVectors()) {
  return `{\n"about": ${JSON.stringify(vectors.about)},\n"cases": [\n${vectors.cases.map((one) => JSON.stringify(one)).join(',\n')}\n]\n}\n`;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  writeFileSync(VECTORS_PATH, vectorsText());
  process.stdout.write(`${VECTORS_PATH}\n`);
}
