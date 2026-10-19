// Settings › AI descriptions: the AI service that writes a short sentence for each event (Claude, or any service that speaks the OpenAI chat
// API at an address, a model at home among them), its model, the daily limit, the write-only key, the day's counts and the last problem, and
// Try it on one camera. GET settings' `ai` says what is saved: the key only as `keySaved` and its last four characters (`keyHint`, null for a
// key too short to show any of). PATCH settings {ai} saves the rest; PUT ai/key takes the key, DELETE ai/key forgets it, and POST ai/try
// describes a camera's pictures of now. The bridge forgets the saved key when the service changes, or the OpenAI-compatible address names
// another server, so a save sends the settings first and the key only once the bridge has them.
import { del, get, patch, post, put } from '../api.js';
import { confirmDialog, h, replace, toast } from '../dom.js';
import { icon } from '../icons.js';
import { cameraList, subscribe } from '../store.js';
import { field, inlineError } from './common.js';

/** Claude's model when nothing else is chosen: the quickest and cheapest one that sees pictures. */
export const CLAUDE_MODEL = 'claude-haiku-5-5';
const LIMIT = { min: 1, max: 5000, standard: 200 };
const PROVIDERS = new Set(['anthropic', 'openAICompatible']);
const RECORDING_LINK = 'Settings › Recording';

/** Every word the card shows, in one place. */
export const AI_TEXT = {
  title: 'AI descriptions',
  desc: 'A short sentence for each event, written by the AI service you choose. Turn it on for each camera on the camera’s page.',
  whatLeaves: 'For each event on a camera with AI descriptions on, up to five still pictures from around the event are sent to the service you choose. No video, no sound, nothing else.',
  service: 'Service',
  providers: [['', 'Off'], ['anthropic', 'Claude (Anthropic)'], ['openAICompatible', 'OpenAI-compatible']],
  serviceHint: 'OpenAI-compatible: OpenAI itself, OpenRouter, or a model at home such as Ollama or LM Studio, which keeps the pictures on your network.',
  keyGoes: 'Changing the service removes the saved key.',
  keyGoesOff: 'Turning it off removes the saved key.',
  address: 'Address',
  addressHint: 'Like https://api.openai.com/v1, or http://192.168.77.10:11434/v1 for a model at home, which may need no key.',
  addressStripped: 'Saved without “/chat/completions” at the end: the bridge adds it itself.',
  model: 'Model',
  modelHint: 'The service’s name for a model that can see pictures.',
  claudeModelHint: 'Leave it on the default unless you know another model works with Camera Bridge.',
  dailyLimit: 'Daily limit',
  limitHint: 'Descriptions a day, for all cameras together. Once it is reached, events are kept without a description until midnight.',
  limitRange: `The daily limit is ${LIMIT.min} to ${LIMIT.max} descriptions.`,
  key: 'API key',
  keyHint: 'It stays on this bridge and is never shown again.',
  keySaved: (hint) => (hint ? `Key saved (…${hint})` : 'Key saved'),
  replace: 'Replace',
  remove: 'Remove',
  removeTitle: 'Remove the key?',
  removeBody: 'The bridge forgets it. A service that needs a key describes nothing until one is saved again.',
  removeConfirm: 'Remove the key',
  keyRemoved: 'Key removed.',
  save: 'Save',
  saved: 'Saved.',
  nothingToSave: 'Nothing to change.',
  keySavedNotRead: 'Key saved; reload the page to see it.',
  failed: 'That didn’t work. Try again.',
  counts: (today, limit, week) => `Today: ${today} of ${limit} · last 7 days: ${week}`,
  limitReached: 'Today’s limit is reached. Events are kept without a description until midnight.',
  paused: 'Paused: the key was refused. Save a new key to start again.',
  needsKey: 'Claude needs a key: events are described once it is saved.',
  lastProblem: 'Last problem',
  recordings: `AI descriptions need a place for recordings (${RECORDING_LINK}).`,
  tryIt: 'Try it',
  tryCamera: 'Camera',
  tryNote: 'Try it sends this camera’s current pictures to the service now, even when its AI switch is off.',
  trying: 'Trying… this takes a few seconds.',
  took: (seconds) => `Took ${Math.round(seconds * 10) / 10} s`,
  noCameras: 'Add a camera to try it.',
};

/**
 * An OpenAI-compatible address as it is saved: trimmed, and without the "/chat/completions" a pasted endpoint ends with (the bridge adds
 * it itself). `stripped` says whether that end was taken off.
 */
export function cleanAddress(text) {
  const trimmed = String(text ?? '').trim();
  const end = /\/chat\/completions\/?$/i.exec(trimmed);
  if (!end) return { address: trimmed, stripped: false };
  return { address: trimmed.slice(0, end.index).replace(/\/+$/, ''), stripped: true };
}

/**
 * What the card shows from GET settings' `ai`:
 *   provider      'anthropic', 'openAICompatible' or null (off)
 *   model, baseURL ('' when none), dailyLimit
 *   key           "Key saved (…0000)", "Key saved" for a key too short for a hint, or null when none is saved
 *   counts        "Today: N of LIMIT · last 7 days: M"; this and the rest are null while no service is chosen
 *   limitReached, paused, needsKey, recordings   a sentence each, or null
 *   lastError     { message, at } (at: the ISO time, or null) or null: a description that worked since does not clear it
 */
export function aiSettingsView(settings) {
  const ai = settings?.ai ?? {};
  const provider = PROVIDERS.has(ai.provider) ? ai.provider : null;
  const on = provider !== null;
  const dailyLimit = Number.isInteger(ai.dailyLimit) ? ai.dailyLimit : LIMIT.standard;
  const count = (n) => (Number.isFinite(n) ? n : 0);
  return {
    provider,
    model: typeof ai.model === 'string' ? ai.model : CLAUDE_MODEL,
    baseURL: typeof ai.baseURL === 'string' ? ai.baseURL : '',
    dailyLimit,
    key: ai.keySaved ? AI_TEXT.keySaved(typeof ai.keyHint === 'string' ? ai.keyHint : null) : null,
    counts: on ? AI_TEXT.counts(count(ai.today), dailyLimit, count(ai.last7Days)) : null,
    limitReached: on && ai.limitReached ? AI_TEXT.limitReached : null,
    paused: on && ai.paused ? AI_TEXT.paused : null,
    needsKey: provider === 'anthropic' && !ai.keySaved ? AI_TEXT.needsKey : null,
    lastError: on && typeof ai.lastError === 'string' && ai.lastError ? { message: ai.lastError, at: typeof ai.lastErrorAt === 'string' ? ai.lastErrorAt : null } : null,
    recordings: on && ai.needsRecordingsFolder ? AI_TEXT.recordings : null,
  };
}

/** "http://host:80": the server an address names (the scheme's own port when none is written), or null for one that cannot be read. */
function serverOf(address) {
  try {
    const url = new URL(address);
    return `${url.protocol}//${url.hostname}:${url.port || (url.protocol === 'https:' ? '443' : '80')}`;
  } catch {
    return null;
  }
}

const sameChoice = (a, b) => a.provider === b.provider && a.model === b.model && a.baseURL === b.baseURL && a.dailyLimit === b.dailyLimit;

/** The words for a request that did not work: the bridge's sentence, never a script's own error text. */
function errorText(error) {
  const message = error && typeof error === 'object' && 'status' in error && typeof error.message === 'string' ? error.message.trim() : '';
  return message || AI_TEXT.failed;
}

/** A banner that is part of the card (not an alert: it is there when the page opens). */
function notice(kind, ...content) {
  return h('div', { class: `banner ${kind}` }, icon('alert'), h('div', { class: 'text' }, content));
}

/**
 * The banners for what keeps events from being described, one list for Settings and the camera page's AI card so both say the same in
 * the same order: the pause after a refused key, the key Claude needs, then the place for recordings. `view` is aiSettingsView().
 * `keyNotes: false` leaves out the pause and the key (a camera whose switch is off); `fix()`, when given, makes a way to fix those two,
 * put after each (the camera page's link to Settings).
 */
export function aiNotices(view, { keyNotes = true, fix = null } = {}) {
  const [before, after] = AI_TEXT.recordings.split(RECORDING_LINK);
  const fixable = (text) => (fix ? [text, ' ', fix()] : [text]);
  return [
    keyNotes && view.paused ? notice('error', ...fixable(view.paused)) : null,
    keyNotes && view.needsKey ? notice('warning', ...fixable(view.needsKey)) : null,
    view.recordings ? notice('warning', before, h('a', { href: '#/settings/recording' }, RECORDING_LINK), after) : null,
  ];
}

/** "Oct 19, 2026, 9:05 AM" in a <time>, or nothing for a time that cannot be read. */
function when(iso) {
  const date = iso ? new Date(iso) : null;
  if (!date || Number.isNaN(date.getTime())) return null;
  return h('time', { datetime: iso, title: date.toLocaleString() }, date.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }));
}

/**
 * The card: { el, update(settings), destroy() }. `update` takes settings the rest of the page got (its own saves answer with all of them):
 * what is being typed stays unless the saved AI choice itself changed. The card tells the page what its own requests brought back
 * (`onSettings`), and follows the page's cameras for Try it until `destroy`.
 * `deps` are for tests: save(ai), saveKey(key), removeKey(), reload(), tryIt(cameraID), cameras(), watchCameras(fn) → stop, confirm(),
 * onSettings(settings), notify(text, kind).
 */
export function createAISettingsCard(initial, {
  save = (ai) => patch('settings', { ai }),
  saveKey = (key) => put('ai/key', { key }),
  removeKey = () => del('ai/key'),
  reload = () => get('settings'),
  tryIt = (cameraID) => post('ai/try', { cameraID }),
  cameras = () => cameraList().filter((camera) => camera.isEnabled !== false),
  watchCameras = (fn) => subscribe((kind) => { if (kind === 'camera' || kind === 'removed') fn(); }),
  confirm = () => confirmDialog({ title: AI_TEXT.removeTitle, body: AI_TEXT.removeBody, confirm: AI_TEXT.removeConfirm, danger: true }),
  onSettings = () => {},
  notify = toast,
} = {}) {
  let saved = aiSettingsView(initial);
  let replacing = false;   // Replace was pressed: the key field shows although a key is saved
  let keyMode = null;      // what the key area shows: 'field', or the saved key's words
  let busy = false;        // a save or a removal is on its way
  let problem = null;      // why the last save or removal did not work
  let stripped = false;    // the last save took "/chat/completions" off the address
  let trial = null;        // Try it: { running } | { summary, seconds } | { message }
  let shownTrial;          // the try the answer area shows (it is a live region: drawn again only for a new one)
  let tryCamera = null;    // the camera chosen for Try it
  let cameraKey = null;    // the cameras the list was made from

  const provider = h('select', { dataset: { ai: 'provider' }, onchange: providerChanged },
    AI_TEXT.providers.map(([value, text]) => h('option', { value }, text)));
  const model = h('input', { type: 'text', dataset: { ai: 'model' }, maxlength: 100, autocomplete: 'off', autocapitalize: 'off', spellcheck: 'false' });
  const address = h('input', { type: 'url', dataset: { ai: 'baseURL' }, maxlength: 500, autocomplete: 'off', autocapitalize: 'off', spellcheck: 'false',
    placeholder: 'https://api.openai.com/v1', oninput: () => { stripped = false; drawKey(); } });
  const limit = h('input', { type: 'number', dataset: { ai: 'dailyLimit' }, min: LIMIT.min, max: LIMIT.max, step: 1 });
  const key = h('input', { type: 'password', dataset: { ai: 'key' }, value: '', autocomplete: 'off', autocapitalize: 'off', spellcheck: 'false' });
  const keyField = field(AI_TEXT.key, key, { hint: AI_TEXT.keyHint });

  const status = h('div', { class: 'ai-status' });
  const serviceNote = h('p', { class: 'small muted ai-note', hidden: true });
  const strippedNote = h('p', { class: 'small muted ai-note', hidden: true }, AI_TEXT.addressStripped);
  const addressBox = h('div', null, field(AI_TEXT.address, address, { hint: AI_TEXT.addressHint }), strippedNote);
  const keyArea = h('div');
  const claudeModelNote = h('span', { class: 'hint', hidden: true }, AI_TEXT.claudeModelHint);
  const modelField = field(AI_TEXT.model, model, { hint: AI_TEXT.modelHint });
  modelField.append(claudeModelNote);   // under Claude's model field only
  const details = h('div', null, addressBox, modelField,
    field(AI_TEXT.dailyLimit, limit, { hint: AI_TEXT.limitHint }), keyArea);
  const problemArea = h('div');
  const saveButton = h('button', { class: 'btn primary', type: 'submit' }, AI_TEXT.save);

  const cameraSelect = h('select', { dataset: { ai: 'tryCamera' }, onchange: () => { tryCamera = cameraSelect.value; } });
  const tryButton = h('button', { class: 'btn', type: 'button', onclick: runTry }, AI_TEXT.tryIt);
  const tryResult = h('div', { class: 'ai-try-result', role: 'status' });
  const tryWith = h('div', null, field(AI_TEXT.tryCamera, cameraSelect), h('p', { class: 'small muted' }, AI_TEXT.tryNote),
    h('div', { class: 'row' }, tryButton), tryResult);
  const tryNone = h('p', { class: 'small muted' }, AI_TEXT.noCameras);
  const tryArea = h('div', { class: 'ai-try' }, h('h3', null, AI_TEXT.tryIt), tryWith, tryNone);

  const el = h('form', { class: 'card ai-card', onsubmit: submit },
    h('h2', { tabindex: '-1' }, AI_TEXT.title),   // #/settings/ai puts the keyboard here
    h('p', { class: 'desc' }, AI_TEXT.desc),
    h('p', { class: 'ai-what-leaves' }, AI_TEXT.whatLeaves),
    status,
    field(AI_TEXT.service, provider, { hint: AI_TEXT.serviceHint }), serviceNote,
    details, problemArea,
    h('div', { class: 'row' }, saveButton),
    tryArea);

  const chosen = () => provider.value || null;

  /** Whether saving what is chosen makes the bridge forget the saved key: another service, or another server for the OpenAI-compatible one. */
  function keyGoes() {
    if (!saved.key) return false;
    if (chosen() !== saved.provider) return true;
    if (chosen() !== 'openAICompatible') return false;
    const next = serverOf(cleanAddress(address.value).address);
    return !next || next !== serverOf(saved.baseURL);
  }

  /** The controls show what is saved. */
  function fill() {
    provider.value = saved.provider ?? '';
    model.value = saved.model;
    address.value = saved.baseURL;
    limit.value = String(saved.dailyLimit);
  }

  function providerChanged() {
    const next = chosen();
    key.value = '';   // a key typed for one service is never sent to another (the bridge keeps a key for one service only)
    if (next === saved.provider) {
      model.value = saved.model;
      address.value = saved.baseURL;
    } else if (next === 'anthropic' && !/^claude/i.test(model.value.trim())) {
      model.value = CLAUDE_MODEL;
    } else if (next === 'openAICompatible' && model.value.trim() === CLAUDE_MODEL) {
      model.value = '';
    }
    stripped = false;
    draw();
  }

  function drawStatus() {
    if (!saved.provider) return replace(status);
    const at = saved.lastError ? when(saved.lastError.at) : null;
    const problemLine = saved.lastError
      ? h('p', { class: 'small ai-last-error' }, AI_TEXT.lastProblem, at ? [' (', at, ')'] : null, ': ', saved.lastError.message)
      : null;
    return replace(status,
      aiNotices(saved),
      h('p', { class: 'ai-counts' }, saved.counts),
      saved.limitReached ? h('p', { class: 'small' }, saved.limitReached) : null,
      problemLine);
  }

  function drawKey() {
    const goes = keyGoes();
    serviceNote.hidden = !goes;
    serviceNote.textContent = chosen() ? AI_TEXT.keyGoes : AI_TEXT.keyGoesOff;
    const mode = !saved.key || replacing || goes ? 'field' : saved.key;
    if (mode === keyMode) return;
    keyMode = mode;
    if (mode === 'field') return replace(keyArea, keyField);
    return replace(keyArea, h('div', { class: 'field' }, h('span', { class: 'label' }, AI_TEXT.key),
      h('div', { class: 'ai-key' }, h('span', null, saved.key),
        h('button', { class: 'btn small', type: 'button', onclick: startReplacing }, AI_TEXT.replace),
        h('button', { class: 'btn small danger', type: 'button', onclick: removeSavedKey }, AI_TEXT.remove))));
  }

  function drawTrial() {
    const running = !!trial?.running;
    if (running) tryButton.setAttribute('aria-disabled', 'true');
    else tryButton.removeAttribute('aria-disabled');
    if (trial === shownTrial) return null;
    shownTrial = trial;
    if (!trial) return replace(tryResult);
    if (running) return replace(tryResult, h('p', { class: 'small muted' }, AI_TEXT.trying));
    if (trial.message) return replace(tryResult, notice('error', trial.message));   // no alert inside this status region
    return replace(tryResult, h('p', { class: 'ai-try-summary' }, trial.summary),
      Number.isFinite(trial.seconds) ? h('p', { class: 'small muted' }, AI_TEXT.took(trial.seconds)) : null);
  }

  /** The cameras to try (the list is made again only when they changed), or a word that there are none. */
  function drawCameras() {
    tryArea.hidden = !saved.provider;
    const list = saved.provider ? cameras() : [];
    if (!list.some((camera) => camera.id === tryCamera)) tryCamera = list[0]?.id ?? null;
    const listKey = list.map((camera) => `${camera.id} ${camera.name}`).join('\n');
    if (listKey !== cameraKey) {
      cameraKey = listKey;
      replace(cameraSelect, list.map((camera) => h('option', { value: camera.id, selected: camera.id === tryCamera }, camera.name)));
    }
    if (tryCamera) cameraSelect.value = tryCamera;
    tryWith.hidden = !list.length;
    tryNone.hidden = list.length > 0;
  }

  function draw() {
    const next = chosen();
    details.hidden = !next;
    addressBox.hidden = next !== 'openAICompatible';
    strippedNote.hidden = !stripped;
    claudeModelNote.hidden = next !== 'anthropic';
    model.placeholder = next === 'openAICompatible' ? 'llava' : CLAUDE_MODEL;
    drawStatus();
    drawKey();
    replace(problemArea, problem ? inlineError(problem) : null);
    if (busy) { el.setAttribute('aria-busy', 'true'); saveButton.setAttribute('aria-disabled', 'true'); }
    else { el.removeAttribute('aria-busy'); saveButton.removeAttribute('aria-disabled'); }
    drawCameras();
    drawTrial();
  }

  /** Takes settings the bridge answered with; `reset` puts the controls back to what is saved even when the choice is the same. */
  function adopt(settings, reset) {
    const next = aiSettingsView(settings);
    const changed = !sameChoice(next, saved);
    saved = next;
    if (changed && !trial?.running) trial = null;   // the answer was about the service saved before
    if (reset || changed) fill();
    draw();
  }

  function heard(settings, reset) {
    onSettings(settings);
    adopt(settings, reset);
  }

  /** What a save sends: only what differs from what is saved ({} when nothing does), or { error }. */
  function plan() {
    const next = chosen();
    if (!next) return { body: saved.provider ? { provider: null } : {} };
    const body = {};
    if (next !== saved.provider) body.provider = next;
    const name = model.value.trim();
    if (name !== saved.model) body.model = name;
    const cleaned = cleanAddress(address.value);
    if (next === 'openAICompatible' && cleaned.address !== saved.baseURL) body.baseURL = cleaned.address || null;
    const count = Number(limit.value);
    if (!limit.value.trim() || !Number.isInteger(count) || count < LIMIT.min || count > LIMIT.max) return { error: AI_TEXT.limitRange };
    if (count !== saved.dailyLimit) body.dailyLimit = count;
    return { body, stripped: next === 'openAICompatible' && cleaned.stripped, address: cleaned.address };
  }

  async function submit(event) {
    event.preventDefault();
    if (busy) return;
    const chosenPlan = plan();
    problem = chosenPlan.error ?? null;
    if (problem) return draw();
    const typed = keyMode === 'field' && chosen() && key.value.trim() ? key.value : null;
    stripped = !!chosenPlan.stripped;
    if (stripped) address.value = chosenPlan.address;
    const changes = Object.keys(chosenPlan.body).length > 0;
    if (!changes && !typed) {
      replacing = false;
      draw();
      return notify(AI_TEXT.nothingToSave);
    }
    busy = true;
    draw();
    let answer = null;
    let keySaved = false;
    try {
      // The settings first: a new service makes the bridge forget the saved key, so a key sent before them would be lost.
      if (changes) answer = await save(chosenPlan.body);
      if (typed) {
        await saveKey(typed);
        key.value = '';
        keySaved = true;
        answer = await reload();
      }
      replacing = false;
      notify(AI_TEXT.saved, 'ok');
    } catch (error) {
      // The key is on the bridge even when what it has could not be read back.
      problem = keySaved ? AI_TEXT.keySavedNotRead : errorText(error);
      if (!answer) stripped = false;   // the address was not saved
    }
    busy = false;
    if (answer) heard(answer, true);
    else draw();
  }

  function startReplacing() {
    replacing = true;
    key.value = '';
    drawKey();
    key.focus();
  }

  async function removeSavedKey() {
    if (busy || !(await confirm())) return;
    busy = true;
    problem = null;
    draw();
    let answer = null;
    try {
      await removeKey();
      answer = await reload();
      replacing = false;
      notify(AI_TEXT.keyRemoved, 'ok');
    } catch (error) {
      problem = errorText(error);
    }
    busy = false;
    if (answer) heard(answer, false);
    else draw();
  }

  async function runTry() {
    if (trial?.running || !tryCamera) return;
    trial = { running: true };
    drawTrial();
    try {
      const answer = await tryIt(tryCamera);
      trial = { summary: typeof answer?.summary === 'string' ? answer.summary : '', seconds: Number(answer?.seconds) };
    } catch (error) {
      trial = { message: errorText(error) };
    }
    drawTrial();
    // A try counts toward the day, and one that works lifts a pause: the status is read again.
    try { heard(await reload(), false); } catch { /* the status stays as it was */ }
  }

  fill();
  draw();
  const stopWatching = watchCameras(drawCameras);
  return { el, update: (settings) => adopt(settings, false), destroy: stopWatching };
}
