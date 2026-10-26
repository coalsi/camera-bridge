// The Archive drive card of the System page: where older recordings move when the box's own disk fills. The drives come from the same list as the
// recording drive's (GET system/archive-drives, the system's view of each disk for an archive); what the archive holds and what moves now come from
// GET nvr/storage (`archive`). The System page owns the requests; this only builds the card.
import { h, spinner } from '../dom.js';
import { icon } from '../icons.js';
import { bytes, sizeText } from '../format.js';

// MARK: The words (the Recording card in Settings says the same)

/** What the archive drive is for, in the page's words. */
export const ARCHIVE_PURPOSE = 'Older recordings move here when the box’s own disk fills, instead of being deleted.';

const ARCHIVE_STATUS = {
  connected: 'Connected',
  notConnected: 'Not connected',
  notAnswering: 'Not answering',
  failing: 'Not working',
  refused: 'Not in use',
};

/**
 * Everything a card says about the archive drive, from the `archive` of GET nvr/storage (null: this bridge has no archive drive). `when(ms)` turns a
 * time into words (the cards pass their date format). Plain values, so the cards only put them on the page.
 */
export function describeArchive(archive, { when = (ms) => new Date(ms).toISOString(), cameraName = (move) => move.cameraName } = {}) {
  if (!archive) return null;
  const connected = archive.state === 'connected';
  const measured = archive.totalBytes > 0;
  const move = archive.moving;
  const percent = move && move.bytes > 0 ? Math.min(100, Math.floor((move.doneBytes / move.bytes) * 100)) : 0;
  const name = move ? (cameraName(move) || 'a camera') : null;
  return {
    connected,
    status: ARCHIVE_STATUS[archive.state] || ARCHIVE_STATUS.notConnected,
    message: archive.message || null,
    used: sizeText(archive.usedBytes || 0),
    free: connected && measured ? `${sizeText(archive.freeBytes)} of ${sizeText(archive.totalBytes)}` : '—',
    oldest: archive.oldest === null || archive.oldest === undefined ? 'Nothing moved here yet' : when(archive.oldest),
    moving: move ? `Moving ${name}’s recording from ${when(move.start)} (${percent}%)` : connected ? 'Nothing right now' : '—',
    waiting: archive.waitingFiles > 0 ? `${archive.waitingFiles === 1 ? '1 more recording waits' : `${archive.waitingFiles} more recordings wait`} to move (${sizeText(archive.waitingBytes || 0)})` : null,
    moved: archive.movedFiles > 0 ? `${archive.movedFiles === 1 ? '1 recording' : `${archive.movedFiles} recordings`} (${sizeText(archive.movedBytes || 0)}) moved here since the bridge started` : null,
  };
}

/** What the system says about the choice (status/archive-drive.json). */
export const ARCHIVE_STATES = {
  none: 'No archive drive is chosen. When the box’s own disk fills, its oldest recordings are deleted.',
  mounted: 'The archive drive is in place.',
  missing: 'The archive drive isn’t plugged in. Its recordings play again when it is back; until then the box deletes its oldest recordings when its disk fills.',
  working: 'Setting up the archive drive…',
  failed: 'The last attempt did not work.',
};

const when = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' });

/** The sentence a person types to erase a disk for the archive: the same as for the recording drive and the installer. */
export function archivePhrase(disk) { return disk.phrase || `ERASE ALL DATA ON ${disk.name}`; }

/**
 * The card. `archives`: the answer of GET system/archive-drives, or null before the person asked; `storage`: the newest GET nvr/storage (or null);
 * `busy`: the page's running action; `cameraName(id)`; `load()`, `use(disk, keepData)`, `forget()`: the page's actions.
 */
export function archiveCardFor({ archives = null, storage = null, busy = '', cameraName = () => null, load, use, forget }) {
  const view = describeArchive(storage?.archive ?? null, { when: (ms) => when.format(new Date(ms)), cameraName: (move) => move.cameraName || cameraName(move.cameraID) });
  const chosen = archives && (archives.state === 'mounted' || archives.state === 'missing');
  const row = (k, v) => (v ? [h('dt', null, k), h('dd', null, v)] : null);
  return h('div', { class: 'card archive-drive' }, h('h2', null, 'Archive drive'),
    h('p', { class: 'desc' }, `${ARCHIVE_PURPOSE} Plug in a drive (USB or SATA, a hard disk or an SSD), then find it here. It is erased when you choose it, unless it already is a Camera Bridge archive drive.`),
    view ? [
      h('dl', { class: 'kv' },
        row('Archive drive', view.status), row('Used', view.used), row('Free', view.free), row('Goes back to', view.oldest), row('Moving now', view.moving)),
      view.message ? h('p', { class: view.connected ? 'muted' : 'small problems' }, view.message) : null,
      view.waiting ? h('p', { class: 'small muted' }, view.waiting) : null,
      view.moved ? h('p', { class: 'small muted' }, view.moved) : null,
    ] : null,
    archives ? h('p', { class: archives.state === 'failed' ? 'problems' : 'muted' }, ARCHIVE_STATES[archives.state] || '', archives.state === 'failed' && archives.message ? ` ${archives.message}` : '') : null,
    archives === null
      ? h('button', { class: 'btn', type: 'button', disabled: !!busy, onclick: load }, busy === 'archives' ? spinner() : icon('search'), 'Find drives')
      : [
        archives.drives.length === 0 ? h('p', { class: 'muted' }, 'No other drive was found. Plug one in and look again.')
          : h('div', { class: 'found' }, archives.drives.map((disk) => h('div', { class: 'card disk' },
            h('div', null, h('strong', null, disk.name),
              h('div', { class: 'small muted' }, [disk.model, bytes(disk.sizeBytes), disk.isArchiveDrive ? 'a Camera Bridge archive drive' : disk.note].filter(Boolean).join(' · ')),
              disk.eligible ? null : h('div', { class: 'small problems' }, disk.problems.join('. '))),
            disk.eligible && disk.inUse !== true ? h('div', { class: 'row' },
              disk.isArchiveDrive ? h('button', { class: 'btn', type: 'button', disabled: !!busy, onclick: () => use(disk, true) }, 'Use as archive') : null,
              h('button', { class: `btn ${disk.isArchiveDrive ? 'danger' : 'primary'}`, type: 'button', disabled: !!busy, onclick: () => use(disk, false) },
                disk.isArchiveDrive ? 'Erase and use as archive…' : 'Use as archive…')) : null,
            disk.inUse === true ? h('span', { class: 'small muted' }, 'the archive drive now') : null))),
        h('div', { class: 'row' },
          h('button', { class: 'btn', type: 'button', disabled: !!busy, onclick: load }, busy === 'archives' ? spinner() : icon('search'), 'Look again'),
          chosen ? h('button', { class: 'btn', type: 'button', disabled: !!busy, onclick: forget }, 'Stop using the archive drive…') : null)]);
}
