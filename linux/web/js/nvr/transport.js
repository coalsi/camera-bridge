// The recordings' transport: one picture back, Play or Pause, one picture forward, the time of the playhead, the speed menu in its four groups
// (nvr/speed.js) and the keyboard help. The Monitor (screens/nvr.js) and Sky Watcher's clip player (screens/sky-player.js) both build theirs
// here, so the two look, read and work alike. It draws what the grid controller's view says (screens/nvr-controller.js `transport`); what a
// press does is the caller's. No timers, no requests.
import { h, replace } from '../dom.js';
import { icon } from '../icons.js';
import { SPEED_GROUPS, isTimelapse, speedDescription, speedLabel } from './speed.js';

function setData(el, name, value) {
  if (el.dataset[name] !== value) el.dataset[name] = value;
}

function setText(el, text) {
  if (el.textContent !== text) el.textContent = text;
}

/**
 * -> { playButton, frameBackButton, frameForwardButton, readout, speedSelect, speedGroup, keysHelp, render(transport, { atLive, text }) }
 *   onPlay()           Play or Pause was pressed
 *   onStep(direction)  one picture back (-1) or forward (+1)
 *   onSpeed(rate)      a speed was chosen in the menu
 *   keyMap             [[keys, what they do]]: the keyboard help's lines
 * render(transport): the controller's `transport` (mode, playing, canPlay, canStep, canSpeed, rate); `atLive` hides what live has no use for
 * (Play, the steps, the speed), `text` is the readout's words.
 */
export function createTransport({ onPlay, onStep, onSpeed, keyMap = [] }) {
  const playButton = h('button', { class: 'btn primary', type: 'button', onclick: () => onPlay(), title: 'Play or pause (Space)' }, icon('play'), h('span', null, 'Play'));
  playButton.dataset.playing = 'false';
  // One picture back or forward (← and → while paused): a step pauses first and never plays.
  const frameBackButton = h('button', { class: 'btn small nvr-frame', type: 'button', 'aria-label': 'One picture back', title: 'One picture back (← while paused)',
    dataset: { nvr: 'frame-back' }, onclick: () => onStep(-1) }, icon('frameBack'));
  const frameForwardButton = h('button', { class: 'btn small nvr-frame', type: 'button', 'aria-label': 'One picture forward', title: 'One picture forward (→ while paused)',
    dataset: { nvr: 'frame-forward' }, onclick: () => onStep(1) }, icon('frameForward'));
  const readout = h('span', { class: 'nvr-readout', role: 'timer', 'aria-live': 'off' });
  // Playback speed while a recording plays or stands; live is always 1×. One menu in four groups (nvr/speed.js); the keys , and . step it.
  // A new speed while paused waits for Play.
  const speedSelect = h('select', { class: 'nvr-speed', 'aria-label': 'Playback speed', title: 'Playback speed (, slower, . faster)', dataset: { nvr: 'speed' },
    onchange: (event) => { onSpeed(Number(event.target.value)); event.target.blur(); } },
  SPEED_GROUPS.map((group) => h('optgroup', { label: group.label },
    group.speeds.map((rate) => h('option', { value: String(rate), title: speedDescription(rate) },
      group.id === 'lapse' ? `${speedLabel(rate)}  ·  ${speedDescription(rate).replace('Time-lapse: ', '').split(',')[0]}` : speedLabel(rate))))));
  const speedGroup = h('label', { class: 'nvr-speed-group', hidden: true }, h('span', { class: 'sr-only' }, 'Speed'), speedSelect);
  // The page's keys, one click away.
  const keysHelp = h('details', { class: 'nvr-keys' },
    h('summary', { class: 'btn small', title: 'Keyboard shortcuts', 'aria-label': 'Keyboard shortcuts' }, icon('keyboard')),
    h('dl', { class: 'nvr-keys-list' }, keyMap.map(([keys, words]) => [h('dt', null, h('kbd', null, keys)), h('dd', null, words)])));

  function render(t, { atLive = false, text = '' } = {}) {
    if (playButton.dataset.playing !== String(t.playing)) {
      replace(playButton, icon(t.playing ? 'pause' : 'play'), h('span', null, t.playing ? 'Pause' : 'Play'));
      playButton.dataset.playing = String(t.playing);
    }
    playButton.hidden = atLive;
    playButton.disabled = !t.canPlay;
    setData(readout, 'live', String(atLive));
    setText(readout, text);
    speedGroup.hidden = atLive || !t.canSpeed;
    if (speedSelect.value !== String(t.rate)) speedSelect.value = String(t.rate);
    speedSelect.title = `${speedDescription(t.rate)} (, slower, . faster)${t.mode === 'paused' ? '. Paused: the speed applies on Play' : ''}`;
    setData(speedSelect, 'lapse', String(isTimelapse(t.rate)));
    for (const button of [frameBackButton, frameForwardButton]) { button.hidden = atLive; button.disabled = !t.canStep; }
    setData(readout, 'held', String(t.mode === 'paused'));
  }

  return { playButton, frameBackButton, frameForwardButton, readout, speedSelect, speedGroup, keysHelp, render };
}
