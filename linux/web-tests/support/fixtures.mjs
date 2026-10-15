// The fixture clips for tests: where they are, and making them when they are not (sh linux/web-dev/make-fixtures.sh, which needs ffmpeg).
// A test file that needs them does `const fixtures = ensureFixtures();` and passes `{ skip: fixtures.skip }` to `test(...)`.

import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { fixturesPresent, loadFixtures } from '../../web-dev/lib/fixtures.mjs';

const here = dirname(fileURLToPath(import.meta.url));
export const WEB_DEV = join(here, '../../web-dev');
export const WEB_ROOT = join(here, '../../web');
export const FIXTURE_DIR = process.env.CB_FIXTURE_DIR || join(WEB_DEV, 'fixtures');

let cached = null;

/** { directory } when the fixtures are there (made now if need be), else { skip: 'why' }. */
export function ensureFixtures() {
  if (cached) return cached;
  if (!fixturesPresent(FIXTURE_DIR)) {
    const made = spawnSync('sh', [join(WEB_DEV, 'make-fixtures.sh')], { encoding: 'utf8', env: { ...process.env, CB_FIXTURE_DIR: FIXTURE_DIR } });
    if (made.status !== 0 || !fixturesPresent(FIXTURE_DIR)) {
      cached = { skip: `the fixtures are missing and make-fixtures.sh could not make them: ${(made.stderr || made.stdout || '').trim().split('\n').pop()}` };
      return cached;
    }
  }
  cached = { directory: FIXTURE_DIR };
  return cached;
}

let loaded = null;
export function fixtureSet() {
  loaded ??= loadFixtures(ensureFixtures().directory);
  return loaded;
}

export const hasFfprobe = spawnSync('ffprobe', ['-version'], { encoding: 'utf8' }).status === 0;
