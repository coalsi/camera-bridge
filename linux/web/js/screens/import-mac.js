// Settings › Move from Camera Bridge for Mac: the Mac app's backup file (Settings › Backup › Export…) read here, its cameras shown, their
// passwords typed (the file never holds them), and the cameras added to this bridge. POST import/mac-backup/preview and import/mac-backup.
import { post } from '../api.js';
import { h, replace, spinner, toast } from '../dom.js';

/** The passwords to send: one for every camera, or each camera's own (empty ones left out). */
export function passwordsFor(cameras, { shared, each }) {
  const result = {};
  for (const camera of cameras) {
    if (camera.alreadySetUp) continue;
    const value = shared !== null ? shared : (each[camera.id] ?? '');
    if (value) result[camera.id] = value;
  }
  return result;
}

/** One line about how an import went. */
export function importSummary(result) {
  const parts = [];
  if (result.added.length) parts.push(`${result.added.length === 1 ? '1 camera' : `${result.added.length} cameras`} added`);
  if (result.addedOff.length) parts.push(`${result.addedOff.join(', ')} added turned off (no password)`);
  if (result.alreadySetUp.length) parts.push(`${result.alreadySetUp.join(', ')} already here`);
  if (result.failed.length) parts.push(`not added: ${result.failed.map((failure) => `${failure.name} (${failure.message})`).join(', ')}`);
  return parts.length ? `${parts.join('; ')}.` : 'Nothing to import.';
}

export function importMacCard() {
  const el = h('div', { class: 'card', id: 'import-mac' });
  let file = null;
  let preview = null;
  let busy = false;
  let shared = true;

  const chooser = h('input', { type: 'file', accept: '.camerabridge-backup,application/json,.json', hidden: true });
  chooser.addEventListener('change', async () => {
    const chosen = chooser.files?.[0];
    chooser.value = '';
    if (!chosen) return;
    try {
      file = JSON.parse(await chosen.text());
    } catch {
      toast('This file isn’t a Camera Bridge backup.', 'error');
      return;
    }
    busy = true;
    draw();
    try {
      preview = await post('import/mac-backup/preview', { file });
    } catch (error) {
      toast(error.message, 'error');
      file = null;
    }
    busy = false;
    draw();
  });

  function draw() {
    const intro = h('p', { class: 'desc' },
      'Moving from the Mac app? On the Mac open Camera Bridge › Settings › Backup › Export…, then choose that file here. Your cameras, their addresses, user names and options come across; type their passwords below (the file never holds them). Recording stays on for the cameras that recorded on the Mac.');
    if (!preview) {
      replace(el, h('h2', null, 'Move from Camera Bridge for Mac'), intro, chooser,
        h('button', { class: 'btn', type: 'button', disabled: busy, onclick: () => chooser.click() }, busy ? spinner() : null, 'Choose the backup file…'));
      return;
    }
    const fresh = preview.cameras.filter((camera) => !camera.alreadySetUp);
    const sharedInput = h('input', { type: 'password', autocomplete: 'off', placeholder: 'The password of every camera' });
    const inputs = new Map();
    const toggle = h('input', { type: 'checkbox', checked: shared });
    toggle.addEventListener('change', () => { shared = toggle.checked; draw(); });
    const rows = preview.cameras.map((camera) => {
      const input = h('input', { type: 'password', autocomplete: 'off', placeholder: 'Password', hidden: shared || camera.alreadySetUp });
      inputs.set(camera.id, input);
      return h('div', { class: 'card disk' },
        h('div', null, h('strong', null, camera.name),
          h('div', { class: 'small muted' }, [camera.host, camera.username ? `user ${camera.username}` : null, camera.record ? 'Record on' : null,
            camera.alreadySetUp ? 'already on this bridge' : null].filter(Boolean).join(' · '))),
        camera.alreadySetUp ? null : input);
    });
    async function run() {
      busy = true;
      draw();
      try {
        const each = Object.fromEntries([...inputs].map(([id, input]) => [id, input.value]));
        const result = await post('import/mac-backup', { file, passwords: passwordsFor(preview.cameras, { shared: shared ? sharedInput.value : null, each }) });
        toast(importSummary(result) + (result.recordingPlaceChosen ? ' Recordings go to this box’s storage (System › Recording drive to use a drive).' : ''),
          result.failed.length ? 'error' : 'ok', 15000);
        preview = null;
        file = null;
      } catch (error) {
        toast(error.message, 'error');
      }
      busy = false;
      draw();
    }
    replace(el, h('h2', null, 'Move from Camera Bridge for Mac'), intro,
      h('p', null, `${preview.cameras.length === 1 ? '1 camera' : `${preview.cameras.length} cameras`} in the backup${preview.appVersion ? ` from Camera Bridge ${preview.appVersion}` : ''}.`
        + (preview.unreadable ? ` ${preview.unreadable} could not be read.` : '')),
      fresh.length > 1 ? h('label', { class: 'setup-check' }, toggle, ' The same password for every camera') : null,
      shared && fresh.length > 0 ? sharedInput : null,
      h('div', { class: 'found' }, rows),
      h('div', { class: 'row' },
        h('button', { class: 'btn', type: 'button', disabled: busy, onclick: () => { preview = null; file = null; draw(); } }, 'Cancel'),
        h('button', { class: 'btn primary', type: 'button', disabled: busy || fresh.length === 0, onclick: run }, busy ? spinner() : null,
          fresh.length === 1 ? 'Import 1 camera' : `Import ${fresh.length} cameras`)),
      h('p', { class: 'small muted' }, 'A camera without a password is added turned off; type its password on its page later. Once the cameras run here, turn off recording in the Mac app (or quit it), add this bridge in the Home app, and remove the Mac’s bridge there.'));
  }

  draw();
  return el;
}
