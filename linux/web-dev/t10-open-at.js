// T10 browser check: open the watch screen at an address with a time (#/camera/<id>/watch/<epoch ms>), evaluate t10-drive.js, then this file.
// The screen must be paused at that time and show a picture. Returns { mode, positionOffByMs, layer, lit }.
(async () => {
  await window.__t10.sleep(1500);
  const asked = Number(location.hash.match(/\/watch\/(\d+)/)?.[1]);
  const state = window.__t10.state();
  return { mode: state.mode, positionOffByMs: Math.round(state.positionMs - asked), layer: state.layer, lit: state.lit };
})()
