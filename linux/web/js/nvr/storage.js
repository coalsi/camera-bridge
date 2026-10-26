// Where recordings are stored: the dialog that asks where, and the Recording card in Settings. The numbers and sentences they show come from
// storage-info.js.
import { get, patch } from '../api.js';
import { confirmDialog, h, modal, replace, spinner, toast } from '../dom.js';
import { icon } from '../icons.js';
import { cameraList } from '../store.js';
import { inlineError } from '../screens/common.js';
import { ARCHIVE_PURPOSE, describeArchive } from '../screens/archive-drive-card.js';
import { KEEP_DAY_CHOICES, MAX_SIZE_CHOICES_GB, deleteSentence, describeLocation, describeStorage, keepLabel, sizeLabel, withCurrent } from './storage-info.js';

const when = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' });
const whenText = (ms) => (ms === null || ms === undefined ? 'Nothing recorded yet' : when.format(new Date(ms)));

// MARK: The dialog

const LEDE = {
  record: 'Choose a place first, then Record turns on.',
  banner: 'Recording is waiting for a place to save video.',
  settings: 'New recordings are saved here. Recordings already saved stay where they are.',
};

let dialogSequence = 0;

/**
 * "Where should recordings be stored?" Resolves true once the bridge has accepted a place (the PATCH is made here, so a refusal can be
 * shown in the dialog and the person can try again), false when the dialog was cancelled or there is nowhere to choose.
 */
export function chooseStorage({ reason = 'settings' } = {}) {
  const name = `nvr-location-${++dialogSequence}`;
  return modal((close) => {
    const lede = h('p', { class: 'muted' }, LEDE[reason] || LEDE.settings);
    const body = h('div', { class: 'nvr-choose' });
    const message = h('p', { class: 'nvr-error', role: 'alert', hidden: true });
    const choose = h('button', { class: 'btn primary', type: 'submit', disabled: true }, 'Choose');
    const cancel = h('button', { class: 'btn', type: 'button', onclick: () => close(false) }, 'Cancel');
    let busy = false;

    const picked = () => body.querySelector(`input[name="${name}"]:checked`)?.value || null;
    const showMessage = (text) => { message.textContent = text || ''; message.hidden = !text; };
    const setBusy = (on) => {
      busy = on;
      choose.disabled = on || !picked();
      cancel.disabled = on;
      for (const input of body.querySelectorAll('input')) input.disabled = on || input.dataset.unusable === 'yes';
    };

    function draw(locations) {
      if (!locations.length) {
        lede.hidden = true;
        replace(body, h('p', null, 'This bridge has no place to store recordings.'));
        replace(cancel, 'Close');
        choose.hidden = true;
        cancel.focus();
        return;
      }
      const first = locations.find((location) => location.current && location.writable) || locations.find((location) => location.writable);
      replace(body, locations.map((location) => h('label', { class: 'choice' },
        h('input', { type: 'radio', name, value: location.id, checked: Boolean(first) && location.id === first.id, disabled: !location.writable, dataset: { unusable: location.writable ? 'no' : 'yes' },
          onchange: () => { choose.disabled = busy || !picked(); } }),
        h('span', { class: 'text' },
          h('span', { class: 'title' }, location.label, location.current ? ' ' : null, location.current ? h('span', { class: 'pill plain info' }, 'In use') : null),
          describeLocation(location) ? h('span', { class: 'desc' }, describeLocation(location)) : null,
          h('span', { class: 'desc mono' }, location.path),
          location.problem ? h('span', { class: 'desc rec-problem' }, location.problem) : null,
          location.warning ? h('span', { class: 'desc nvr-warning' }, location.warning) : null))));
      choose.disabled = !picked();
      (body.querySelector('input:checked') || choose).focus();
    }

    async function load() {
      replace(body, h('div', { class: 'checking' }, spinner(), h('span', null, 'Checking the storage…')));
      try {
        draw((await get('nvr/storage/locations')).locations || []);
      } catch (error) {
        if (error.status === 401) { close(false); return; }
        replace(body, inlineError(error.message), h('button', { class: 'btn small', type: 'button', onclick: load }, 'Try again'));
      }
    }

    async function submit(event) {
      event.preventDefault();
      const location = picked();
      if (!location || busy) return;
      setBusy(true);
      showMessage('');
      try {
        await patch('nvr/storage', { location });
        close(true);
      } catch (error) {
        if (error.status === 401) { close(false); return; }
        showMessage(error.message);   // a refused folder keeps the dialog open with the bridge's sentence
        setBusy(false);
      }
    }

    // Escape must not close the dialog while the choice is being sent: the answer would be lost.
    queueMicrotask(() => body.closest('dialog')?.addEventListener('cancel', (event) => { if (busy) event.preventDefault(); }));
    load();
    return h('form', { onsubmit: submit },
      h('h2', null, 'Where should recordings be stored?'), lede, body, message,
      h('div', { class: 'buttons' }, cancel, choose));
  }, { label: 'Where should recordings be stored?' }).then((value) => value === true);
}

// MARK: The Settings card

/** The card looks again at the bridge this often while it is on the page. */
export const POLL_MS = 10000;

function fillSelect(select, choices, current, label) {
  const signature = `${choices.join(',')}|${current}`;
  if (select.dataset.signature !== signature) {
    select.dataset.signature = signature;
    replace(select, choices.map((value) => h('option', { value: String(value) }, label(value))));
  }
  select.value = String(current);
}

function selectRow(id, text, select) {
  select.id = id;
  return h('div', { class: 'field' }, h('label', { for: id }, text), select);
}

/**
 * The Recording card for Settings: { el, refresh(), destroy() }. Built once; Settings puts the same element back every time it redraws,
 * so the 10 second refresh keeps running. The elements are updated in place, so an open menu is not closed by a refresh.
 */
export function storageCard() {
  let last = null;       // the newest answer of GET nvr/storage
  let busy = false;      // a change is being sent
  let destroyed = false;
  let loadedAt = 0;
  let sequence = 0;
  const heading = h('h2', { tabindex: '-1' }, 'Recording');
  const problem = h('div', { role: 'status' });
  const empty = h('div', { hidden: true },
    h('p', { class: 'muted' }, 'No place to store recordings is chosen yet. Choose one, then turn Record on for a camera.'));
  const values = Object.fromEntries(['location', 'cameras', 'used', 'free', 'oldest', 'newest'].map((key) => [key, h('dd')]));
  const bar = h('div', { class: 'rec-usage', role: 'img' }, h('div', { class: 'fill' }));
  const reserved = h('p', { class: 'small muted' });
  const effective = h('p', { class: 'small muted' });
  const caption = h('p', { class: 'small muted' });
  // The archive drive, where older recordings move when this drive fills (shown only where the bridge has one).
  const archiveValues = Object.fromEntries(['status', 'used', 'free', 'oldest', 'moving'].map((key) => [key, h('dd')]));
  const archiveNote = h('p', { class: 'small muted' });
  const archiveBox = h('div', { class: 'rec-archive', hidden: true },
    h('h3', null, 'Archive drive'), h('p', { class: 'small muted' }, ARCHIVE_PURPOSE),
    h('dl', { class: 'kv' },
      h('dt', null, 'State'), archiveValues.status, h('dt', null, 'Used'), archiveValues.used, h('dt', null, 'Free'), archiveValues.free,
      h('dt', null, 'Goes back to'), archiveValues.oldest, h('dt', null, 'Moving now'), archiveValues.moving),
    archiveNote);
  const keepSelect = h('select', { onchange: () => change({ keepDays: Number(keepSelect.value) }) });
  const sizeSelect = h('select', { onchange: () => change({ maxSizeGB: Number(sizeSelect.value) }) });
  const details = h('div', { hidden: true },
    h('dl', { class: 'kv' },
      h('dt', null, 'Saved on'), values.location, h('dt', null, 'Cameras recording'), values.cameras, h('dt', null, 'Used'), values.used,
      h('dt', null, 'Free'), values.free, h('dt', null, 'Oldest'), values.oldest, h('dt', null, 'Newest'), values.newest),
    bar, reserved, effective,
    h('div', { class: 'inline-fields' }, selectRow('nvr-keep', 'Keep for', keepSelect), selectRow('nvr-size', 'Maximum size', sizeSelect)),
    caption, archiveBox);
  const chooseButton = h('button', { class: 'btn', type: 'button', onclick: async () => { if (await chooseStorage({ reason: 'settings' })) refresh(); } },
    'Choose where to record…');
  const el = h('section', { class: 'card nvr-card', id: 'recording-card', 'aria-labelledby': 'recording-heading' },
    heading, h('p', { class: 'desc' }, 'Where video is saved and how long it is kept. These limits cover every camera that has Record turned on, together: the oldest recordings go first.'),
    problem, empty, details,
    h('div', { class: 'row' }, chooseButton),
    h('p', { class: 'small muted' }, 'A factory reset erases recordings.'));
  heading.id = 'recording-heading';

  function render(storage) {
    last = storage;
    const view = describeStorage(storage, cameraList());
    empty.hidden = view.hasFolder;
    details.hidden = !view.hasFolder;
    if (problem.dataset.text !== (view.problem || '')) {   // only when the words change, so a screen reader does not read the same warning every 10 seconds
      problem.dataset.text = view.problem || '';
      replace(problem, view.problem ? h('div', { class: 'banner warning' }, icon('alert'), h('div', { class: 'text' }, view.problem)) : null);
    }
    values.location.textContent = view.location;
    values.cameras.textContent = String(view.recordingCameras);
    values.used.textContent = view.used;
    values.free.textContent = view.free;
    values.oldest.textContent = whenText(view.oldest);
    values.newest.textContent = whenText(view.newest);
    bar.setAttribute('aria-label', view.barLabel);
    bar.firstChild.style.width = `${Math.round(view.usedFraction * 1000) / 10}%`;
    for (const [node, text] of [[reserved, view.reserved], [effective, view.effective], [caption, view.caption]]) {
      node.textContent = text || '';
      node.hidden = !text;
    }
    const archive = describeArchive(storage.archive ?? null, { when: whenText });
    archiveBox.hidden = !archive;
    if (archive) {
      for (const key of Object.keys(archiveValues)) archiveValues[key].textContent = archive[key];
      const note = [archive.connected ? null : archive.message, archive.waiting].filter(Boolean).join(' ');
      archiveNote.textContent = note;
      archiveNote.hidden = !note;
    }
    fillSelect(keepSelect, withCurrent(KEEP_DAY_CHOICES, storage.keepDays), storage.keepDays, keepLabel);
    fillSelect(sizeSelect, withCurrent(MAX_SIZE_CHOICES_GB, storage.maxSizeGB), storage.maxSizeGB, sizeLabel);
  }

  function setBusy(on) {
    busy = on;
    keepSelect.disabled = on;
    sizeSelect.disabled = on;
    chooseButton.disabled = on;
  }

  async function refresh() {
    if (destroyed || busy) return;
    const mine = ++sequence;
    try {
      const storage = await get('nvr/storage');
      if (destroyed || busy || mine !== sequence) return;
      loadedAt = Date.now();
      render(storage);
    } catch (error) {
      if (destroyed || error.status === 401) return;
      if (!last) replace(problem, inlineError(error.status === 404 ? 'This version of Camera Bridge doesn’t record video.' : error.message));
    }
  }

  async function change(partial) {
    if (busy) return;
    setBusy(true);
    sequence += 1;   // an older refresh must not overwrite this change
    try {
      let storage;
      let deleted = false;
      try {
        storage = await patch('nvr/storage', partial);
      } catch (error) {
        if (!(error.status === 409 && error.code === 'confirm_required')) throw error;
        const sure = await confirmDialog({
          title: 'Delete older recordings?', body: `${deleteSentence(error.message)} This can’t be undone.`, confirm: 'Delete and apply', danger: true,
        });
        if (!sure) { render(last); return; }
        storage = await patch('nvr/storage', { ...partial, confirm: true });
        deleted = true;
      }
      loadedAt = Date.now();
      render(storage);
      toast(deleted ? 'Saved. The older recordings are deleted within a minute.' : 'Saved.', 'ok');
    } catch (error) {
      if (error.status !== 401) toast(error.message, 'error');
      if (last) render(last);
    } finally {
      setBusy(false);
    }
  }

  // Look again every 10 seconds while the page is in view, and at once when it comes back into view after a while.
  const timer = setInterval(() => { if (!document.hidden && el.isConnected && Date.now() - loadedAt >= POLL_MS - 500) refresh(); }, POLL_MS);
  const onVisible = () => { if (!document.hidden && el.isConnected && Date.now() - loadedAt >= POLL_MS) refresh(); };
  document.addEventListener('visibilitychange', onVisible);
  refresh();

  return {
    el,
    refresh,
    destroy() {
      destroyed = true;
      clearInterval(timer);
      document.removeEventListener('visibilitychange', onVisible);
    },
  };
}
