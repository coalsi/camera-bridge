# Tests for the web interface

No npm, no install: Node 22 or newer. From the repository root:

```
sh linux/web-tests/run.sh                         # everything (makes the fixture clips first; they need ffmpeg)
sh linux/web-tests/run.sh --test-name-pattern=lint
node --test "linux/web-tests/**/*.test.mjs"       # the same, without the fixtures step (quote the pattern)
node linux/web-dev/lint.mjs [dir]                 # the house rules for linux/web (CSP-safe code, no stray fetch, lazy NVR code)
```

Every `*.test.mjs` file is a test file; anything else in this directory (`lint.mjs`, which forwards to `linux/web-dev/lint.mjs`, and `support/`) is a helper. On Node 24 `node --test <directory>` does not work (it tries to run the directory as a module): use `run.sh` or the quoted pattern. Files that need the
clips start with `const fixtures = ensureFixtures()` and pass `{ skip: fixtures.skip }`, so a machine without ffmpeg skips them with a reason.

`import-all.test.mjs` imports every module of the page, `app.js` excepted, in plain Node with no browser at all: nothing may touch
`document`, `window` or `localStorage` while it is imported. `support/fake-browser.mjs` is just enough browser to start the page (`app.js`)
or build elements in a test (a small DOM, storage that can be broken, a refusing `fetch`); `support/dev-server.mjs` starts the dev archive server on a free port with quick timers; `support/cookie-fetch.mjs` makes
`api.js` talk to it with a session cookie. Pure modules (planner, clock, viewport, ticks, fetcher) need none of these.

`linux/package.json` says `"type": "module"` for everything under `linux/`, so Node reads the page's `.js` files as modules (without it
Node 22.0 to 22.6 cannot import them, and later versions warn).
