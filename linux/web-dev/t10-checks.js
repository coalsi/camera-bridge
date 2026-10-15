// T10 browser checks: evaluate this file AFTER t10-drive.js, inside the open watch screen. It returns a report:
//   { summary: { passed, failed, skipped }, checks: [{ name, status: 'pass' | 'fail' | 'skip', detail }] }
// It touches the screen the way a person does (pointer events, key presses, clicks) and reads only the DOM and the screen's debug hook.
// It reads no cookie, no storage and no response body. It never applies the smart-codec fix unless window.__t10Options.allowApply is true
// (do that only against a demo camera or the smoke harness). The last check signs the page out (it makes /api/v1/ answer 401), so run it last.
(async () => {
  const t = window.__t10;
  const options = window.__t10Options || {};
  const checks = [];
  const record = (name, status, detail) => checks.push({ name, status, detail });
  async function check(name, body) {
    try {
      const result = await body();
      if (result && result.skip) record(name, 'skip', result.skip);
      else if (result && result.fail) record(name, 'fail', result.fail);
      else record(name, 'pass', result && result.detail !== undefined ? result.detail : null);
    } catch (error) {
      record(name, 'fail', String(error && error.message ? error.message : error));
    }
  }
  const expect = (condition, message) => { if (!condition) throw new Error(message); };
  let session; let catalog; let model;
  const cameraId = document.querySelector('[data-nvr="watch"]').dataset.camera;
  function rehook() {
    ({ session, catalog } = t.hook());
    model = t.hook().timeline.model;
    t.instrument();
  }
  rehook();
  const calls = () => session.__t10;
  const since = (n) => calls().calls.slice(n);

  await check('the stage shows a picture and the track is a slider', async () => {
    await t.sleep(500);
    const slider = t.track();
    expect(t.litPixels() > 0, 'the stage is blank');
    expect(slider.getAttribute('role') === 'slider' && slider.getAttribute('tabindex') === '0', 'role or tabindex');
    for (const name of ['aria-valuemin', 'aria-valuemax', 'aria-valuenow']) expect(Number.isFinite(Number(slider.getAttribute(name))), `${name} is not a number`);
    expect((slider.getAttribute('aria-valuetext') || '').length > 3, 'aria-valuetext is empty');
    return { detail: slider.getAttribute('aria-valuetext') };
  });

  await check('five presets: one pressed at a time, windows grow 10 min < 1 h < 6 h < 24 h <= All', async () => {
    const widths = {};
    for (const preset of ['10m', '1h', '6h', '24h', 'all']) {
      document.querySelector(`.nvr-preset[data-preset="${preset}"]`).click();
      await t.sleep(120);
      const pressed = [...document.querySelectorAll('.nvr-preset[aria-pressed="true"]')].map((b) => b.dataset.preset);
      expect(pressed.length === 1 && pressed[0] === preset, `pressed after ${preset}: ${pressed}`);
      widths[preset] = model.viewport.durationMs;
    }
    expect(widths['10m'] < widths['1h'] && widths['1h'] < widths['6h'] && widths['6h'] < widths['24h'] && widths['24h'] <= widths.all + 1, JSON.stringify(widths));
    document.querySelector('.nvr-preset[data-preset="1h"]').click();
    await t.sleep(120);
    return { detail: widths };
  });

  await check('ctrl+wheel zooms and is consumed, a plain wheel scrolls the page, shift+wheel pans', async () => {
    const before = model.viewport;
    const zoom = t.wheel({ ctrlKey: true, deltaY: -200 });
    await t.sleep(50);
    expect(zoom.defaultPrevented && model.viewport.durationMs < before.durationMs, 'ctrl+wheel did not zoom in');
    expect(t.wheel({ deltaY: 100 }).defaultPrevented === false, 'a plain wheel was consumed');
    const start = model.viewport.startMs;
    expect(t.wheel({ shiftKey: true, deltaY: 120 }).defaultPrevented, 'shift+wheel was not consumed');
    await t.sleep(50);
    expect(model.viewport.startMs !== start, 'shift+wheel did not pan');
    expect(document.querySelector('.nvr-preset[aria-pressed="true"]') === null, 'a hand-made window still highlights a preset');
    document.querySelector('.nvr-preset[data-preset="1h"]').click();
    await t.sleep(100);
  });

  await check('a 120 Hz drag: one scrub per animation frame, release ends once, an event costs under 0.3 ms', async () => {
    const r = await t.drag({ from: 0.8, to: 0.2, hz: 120, durationMs: 2000 });
    expect(r.events >= 200, `only ${r.events} events`);
    expect(r.maxScrubsPerFrame === 1, `${r.maxScrubsPerFrame} scrubs in one frame`);
    expect(r.scrubs <= r.frames + 1, `${r.scrubs} scrubs in ${r.frames} frames`);
    expect(r.endedOnce, 'endScrub was not called exactly once');
    expect(r.meanEventMs <= 0.3, `mean ${r.meanEventMs} ms per pointer event`);
    expect(r.blankFrames === 0, `${r.blankFrames} blank frames`);
    return { detail: r };
  });

  await check('release plays', async () => {
    const ok = await t.waitFor(() => session.mode === 'playing' || session.mode === 'live', 1500);
    expect(ok, `mode is ${session.mode}`);
    return { detail: session.mode };
  });

  await check('an exact picture arrives after the pointer rests (without releasing)', async () => {
    document.querySelector('.nvr-preset[data-preset="6h"]').click();
    await t.sleep(150);
    const r = await t.drag({ from: 0.7, to: 0.3, hz: 120, durationMs: 400, release: false });
    const cell = session.cell(cameraId);
    const ok = await t.waitFor(() => cell && ['recorded', 'coarse', 'gap'].includes(cell.coverage.kind), 1500);
    expect(ok, `coverage is ${cell && cell.coverage.kind} 1.5 s after the last move`);
    const kind = cell.coverage.kind;
    t.release();
    await t.sleep(100);
    return { detail: { kind, scrubs: r.scrubs } };
  });

  await check('a click on the track moves the playhead there and plays', async () => {
    const before = calls().calls.length;
    const { position } = await t.tap({ at: 0.45 });
    const names = since(before).map((c) => c.name);
    expect(names.join() === 'beginScrub,scrub,endScrub', `calls: ${names}`);
    expect(position >= model.oldestMs - 1 && position <= catalog.serverNow(), 'position outside the recordings');
  });

  await check('Go live', async () => {
    document.querySelector('[data-nvr="go-live"]').click();
    const ok = await t.waitFor(() => session.mode === 'live', 1500);
    expect(ok, `mode is ${session.mode}`);
    const settled = await t.waitFor(() => document.querySelector('[data-nvr="go-live"]').disabled && /Live/.test(document.querySelector('.watch-ago').textContent), 1000);
    expect(settled, 'Go live is still enabled while live, or the readout does not say Live');
  });

  await check('keys: arrows, shift, alt, space, L, and nothing while typing', async () => {
    const start = calls().calls.length;
    t.key('ArrowLeft'); t.key('ArrowRight', { shiftKey: true }); t.key('ArrowLeft', { altKey: true }); t.key(' '); t.key('l');
    await t.sleep(150);
    const seen = since(start);
    const seeks = seen.filter((c) => c.name === 'seek').map((c) => c.args[0]);
    expect(seeks.join() === '-1000,10000,-60000', `seeks: ${seeks}`);
    expect(seen.some((c) => c.name === 'togglePlay') && seen.some((c) => c.name === 'goLive'), 'Space or L did nothing');
    const input = document.body.appendChild(document.createElement('input'));
    input.focus();
    const typing = calls().calls.length;
    input.dispatchEvent(new KeyboardEvent('keydown', { key: ' ', bubbles: true, cancelable: true }));
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true, cancelable: true }));
    input.remove();
    expect(calls().calls.length === typing, 'a key in a text field reached the player');
  });

  await check('100 scripted scrubs show no blank frame', async () => {
    const r = await t.scrubStorm({ count: 100, settleMs: 60 });
    expect(r.blankFrames === 0, `${r.blankFrames} blank frames in ${r.samples} samples`);
    return { detail: r };
  });

  await check('a release inside a gap offers the next recording and jumps there', async () => {
    const gap = await t.findGap(cameraId);
    if (!gap) return { skip: 'no gap in the recordings of this camera (use a scenario that has one)' };
    document.querySelector('.nvr-preset[data-preset="all"]').click();
    await t.sleep(200);
    const middle = Math.round((gap.fromMs + gap.toMs) / 2);
    session.beginScrub(); session.scrub(middle); session.endScrub();
    session.pause();
    const shown = await t.waitFor(() => document.querySelector('.watch-overlay:not([hidden]) strong')?.textContent.startsWith('No recording at'), 2500);
    expect(shown, `overlay: ${t.state().overlay}`);
    const jump = [...document.querySelectorAll('.watch-overlay button')].find((b) => b.textContent.includes('Jump'));
    expect(jump, 'no Jump button');
    jump.click();
    await t.sleep(600);
    // findGap works in one-minute bins, so its end is only right to within a minute
    expect(session.position >= gap.toMs - 65_000 && session.position <= gap.toMs + 10_000, `position ${Math.round(session.position - gap.toMs)} ms from the end of the gap`);
    return { detail: { gapMinutes: Math.round((gap.toMs - gap.fromMs) / 60000) } };
  });

  await check('releasing before the oldest recording clamps and says so', async () => {
    document.querySelector('.nvr-preset[data-preset="all"]').click();
    await t.sleep(200);
    const rect = t.track().getBoundingClientRect();
    const make = (type, x) => new PointerEvent(type, { pointerId: 9, pointerType: 'mouse', isPrimary: true, button: 0, buttons: type === 'pointerup' ? 0 : 1, clientX: x, clientY: rect.top + 40, bubbles: true, cancelable: true });
    t.track().dispatchEvent(make('pointerdown', rect.left + rect.width * 0.4));
    t.track().dispatchEvent(make('pointermove', rect.left - 60));
    t.track().dispatchEvent(make('pointerup', rect.left - 60));
    await t.sleep(500);
    expect(document.querySelector('.watch-caption-text').textContent === 'This is the oldest recording', `caption: ${document.querySelector('.watch-caption-text').textContent}`);
    expect(session.position - model.oldestMs < 4000, `position is ${Math.round(session.position - model.oldestMs)} ms after the oldest recording`);
  });

  await check('the address follows the playhead (within 3 s), so a reload comes back to it', async () => {
    document.querySelector('.nvr-preset[data-preset="6h"]').click();
    session.beginScrub(); session.scrub(catalog.serverNow() - 90 * 60000); session.endScrub(); session.pause();
    const ok = await t.waitFor(() => { const m = location.hash.match(/\/watch\/(\d+)$/); return m && Math.abs(Number(m[1]) - session.position) < 5000; }, 3500);
    expect(ok, `address ${location.hash}`);
  });

  await check('long key-frame interval: caption, and the fix dialog opens and cancels without sending anything', async () => {
    const block = document.querySelector('.watch-gop');
    if (block.hidden) return { skip: 'this camera has no long key-frame interval (typicalGOP is 4 s or less)' };
    const posts = [];
    const original = window.fetch;
    window.fetch = (input, init) => { if ((init && init.method) === 'POST') posts.push(typeof input === 'string' ? input : input.url); return original(input, init); };
    try {
      block.querySelector('.btn').click();
      await t.sleep(200);
      const dialog = document.querySelector('dialog[open]');
      expect(dialog && dialog.querySelector('h2').textContent === 'Make scrubbing smoother?', 'the dialog did not open');
      expect(document.activeElement.textContent === 'Cancel', 'the safe button is not focused');
      [...dialog.querySelectorAll('.btn')].find((b) => b.textContent === 'Cancel').click();
      await t.sleep(150);
      expect(!document.querySelector('dialog'), 'the dialog is still open');
      expect(posts.length === 0, `a POST was sent: ${posts}`);
      if (options.allowApply) {
        block.querySelector('.btn').click();
        await t.sleep(150);
        [...document.querySelectorAll('dialog .btn')].find((b) => b.textContent === 'Apply changes').click();
        await t.waitFor(() => /Camera settings changed|Nothing was changed|Nothing could be changed/.test(document.querySelector('dialog h2')?.textContent || ''), 90000, 200);
        const title = document.querySelector('dialog h2').textContent;
        [...document.querySelectorAll('dialog .btn')].find((b) => b.textContent === 'Done' || b.textContent === 'Close').click();
        await t.sleep(150);
        return { detail: { applied: title, posts } };
      }
    } finally { window.fetch = original; }
  });

  await check('Escape goes back to the camera page (and the screen can be opened again)', async () => {
    window.__navigated = null;
    const camera = `#/camera/${cameraId}`;
    t.key('Escape');
    const went = await t.waitFor(() => window.__navigated === `/camera/${cameraId}` || location.hash === camera, 1500);
    expect(went, `neither navigate() nor the address changed (${location.hash})`);
    if (location.hash === camera) {              // the real router left the screen: open it again for the next check
      location.hash = `${camera}/watch`;
      const back = await t.waitFor(() => window.__cbWatch && window.__cbWatch.session !== session, 3000);
      expect(back, 'the watch screen did not open again');
      rehook();
      await t.sleep(500);
    }
  });

  await check('opening live with a healthy recorder starts live video by itself, once; with the recorder paused it asks for nothing', async () => {
    // The real session decodes nothing until it is asked: a watch screen that only waited showed "Loading" for ever in the Mac dev-daemon run.
    // In the smoke harness a fresh mount is window.__mount and the fake session counts goLive() itself. Against a real page (T07's dev server,
    // the box) the screen is mounted again by leaving the route and coming back, and the calls are counted where the real session makes them,
    // in PlaybackClock.goLive (nothing but startLive() calls it while a screen opens).
    const harness = typeof window.__mount === 'function';
    let goLiveCalls = () => window.__cbWatch.session.goLiveCalls;
    let restore = () => {};
    let mount = async () => window.__mount([cameraId]);
    if (!harness) {
      const { PlaybackClock } = await import('/js/nvr/clock.js');
      const original = PlaybackClock.prototype.goLive;
      let calls = 0;
      PlaybackClock.prototype.goLive = function countedGoLive(...args) { calls += 1; return original.apply(this, args); };
      restore = () => { PlaybackClock.prototype.goLive = original; };
      goLiveCalls = () => calls;
      mount = async () => {
        calls = 0;
        location.hash = '#/';
        await t.waitFor(() => !document.querySelector('[data-nvr="watch"]'), 3000);
        location.hash = `#/camera/${cameraId}/watch`;
        await t.waitFor(() => document.querySelector('[data-nvr="watch"]') && window.__cbWatch, 3000);
      };
    }
    const { store } = await import('/js/store.js');
    const camera = store.cameras.get(cameraId);
    const saved = camera.status.nvr.state;
    try {
      await mount();                                               // a fresh mount, no click
      await t.sleep(900);
      const first = window.__cbWatch.session;
      expect(goLiveCalls() === 1, `a fresh mount called goLive ${goLiveCalls()} times (expected 1)`);
      expect(first.mode === 'live', `the mode is ${first.mode}`);
      if (!harness) {
        const shown = await t.waitFor(() => first.cell(cameraId).coverage.kind === 'live', 8000);
        expect(shown, `the cell never said live (it says ${first.cell(cameraId).coverage.kind})`);
      }
      await t.sleep(900);
      expect(goLiveCalls() === 1, `the 250 ms refresh called goLive again (${goLiveCalls()})`);
      camera.status.nvr.state = 'paused';                          // the recorder is not healthy: the slideshow is the live picture
      await mount();
      await t.sleep(900);
      const asked = goLiveCalls();
      expect(asked === 0, `a paused recorder still got ${asked} goLive call(s)`);
      return { detail: { healthy: 1, notHealthy: asked, harness } };
    } finally {
      camera.status.nvr.state = saved;
      restore();
      await mount();                                               // leave a mounted screen for the next check
      await t.sleep(600);
      rehook();
    }
  });

  await check('a 401 signs the page out and the watch screen stops asking', async () => {
    const guard = t.forceUnauthorized();
    guard.trigger();
    const gone = await t.waitFor(() => !document.querySelector('[data-nvr="watch"]') && !window.__cbWatch, 4000);
    const seenAtSignOut = guard.seen.afterTrigger;
    await t.sleep(3000);
    const extra = guard.seen.afterTrigger - seenAtSignOut;
    guard.restore();
    expect(gone, 'the watch screen is still mounted after a 401');
    expect(extra <= 2, `${extra} more /api/v1/ requests after the sign-out`);
    return { detail: { requestsUntilSignOut: seenAtSignOut, requestsAfter: extra } };
  });

  const summary = { passed: 0, failed: 0, skipped: 0 };
  for (const c of checks) summary[c.status === 'pass' ? 'passed' : c.status === 'fail' ? 'failed' : 'skipped'] += 1;
  return { summary, checks };
})()
