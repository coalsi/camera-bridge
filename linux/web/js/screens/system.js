// The system under the bridge: what runs, updates, SSH, restarting, resetting, and installing to the machine's own disk.
// Camera Bridge OS does these as requests to a root helper, so the long ones (an update, an installation) are followed by asking
// /system again every few seconds.
import { get, post } from '../api.js';
import { confirmDialog, h, phraseDialog, promptDialog, replace, spinner, toast } from '../dom.js';
import { icon } from '../icons.js';
import { bytes, duration, timeAgo } from '../format.js';
import { store } from '../store.js';
import { banners } from './banners.js';
import { inlineError, switchRow } from './common.js';

const MODES = {
  installed: 'Camera Bridge OS',
  installer: 'Running from the installer stick',
  development: 'Running as a program (development)',
};

const INSTALL_STEPS = {
  checking: 'Checking the disk',
  stopping: 'Stopping the bridge to copy its data',
  partitioning: 'Erasing and partitioning the disk',
  copying: 'Copying the system (a few minutes)',
  'boot-entry': 'Making the disk bootable',
  done: 'Done',
};

const POLL_MS = 3000;
const MAX_POLLS = 800;   // about 40 minutes: an update on a slow line

export function renderSystem() {
  const root = h('div', { class: 'stack' });
  const bannerHost = banners();
  let info = null;
  let status = null;
  let update = null;
  let disks = null;
  let copyData = true;
  let busy = '';
  let destroyed = false;
  let pollTimer = null;
  let polls = 0;

  const working = () => update?.state === 'downloading' || update?.state === 'checking'
    || info?.install?.state === 'running' || info?.install?.state === 'queued';

  async function load() {
    try {
      [info, status] = await Promise.all([get('system'), get('status')]);
      update = info.update || null;
    } catch (error) {
      replace(root, inlineError(error.message));
      return;
    }
    if (!destroyed) { draw(); schedulePoll(); }
  }

  /** While something long runs on the system's side, look again every few seconds (and stop when it ends, or after a while). */
  function schedulePoll() {
    clearTimeout(pollTimer);
    if (destroyed || !working() || polls >= MAX_POLLS) return;
    pollTimer = setTimeout(async () => {
      polls += 1;
      try {
        info = await get('system');
        update = info.update || null;
      } catch (error) {
        // The bridge may be restarting (an installation that copies settings stops it): keep trying.
      }
      if (destroyed) return;
      draw();
      schedulePoll();
    }, POLL_MS);
  }

  async function run(name, work) {
    busy = name;
    draw();
    try { await work(); } catch (error) { toast(error.message, 'error'); }
    busy = '';
    if (!destroyed) { draw(); schedulePoll(); }
  }

  async function refresh() {
    info = await get('system');
    update = info.update || null;
  }

  function aboutCard() {
    const row = (k, v) => v ? [h('dt', null, k), h('dd', null, v)] : null;
    return h('div', { class: 'card' }, h('h2', null, info.product),
      h('dl', { class: 'kv' },
        row('Version', `${info.version}${info.build && info.build !== 'development' ? ` (${info.build})` : ''}`),
        row('Mode', MODES[info.mode] || info.mode), row('System', info.osName), row('Machine', info.hardware), row('Name on the network', info.hostname ? `${info.hostname.replace(/\.local\.?$/, '')}.local` : null),
        row('Bridge running for', duration(status.uptimeSeconds)),
        row('Cameras', `${status.cameras.total} (${status.cameras.online} live, ${status.cameras.paired} in Apple Home)`)),
      h('div', { class: 'row' },
        store.bridge.state === 'paused'
          ? h('button', { class: 'btn', type: 'button', onclick: () => run('resume', () => post('bridge/resume')) }, icon('play'), 'Resume bridge')
          : h('button', { class: 'btn', type: 'button', onclick: () => run('pause', () => post('bridge/pause')) }, icon('pause'), 'Pause bridge'),
        h('a', { class: 'btn', href: '/api/v1/diagnostics', download: '' }, icon('download'), 'Download diagnostics')));
  }

  function updateCard() {
    const state = update?.state;
    let message = null;
    if (state === 'downloading') {
      message = h('div', { class: 'banner info', role: 'status' }, spinner(), h('div', { class: 'text' }, h('span', { class: 'title' }, update.latest ? `Installing version ${update.latest}` : 'Installing the update'),
        update.message || 'Downloading, checking and writing the update. Cameras keep working meanwhile.'));
    } else if (state === 'checking') {
      message = h('div', { class: 'banner info', role: 'status' }, spinner(), h('div', { class: 'text' }, 'Looking for updates…'));
    } else if (state === 'error') {
      message = h('div', { class: 'banner error', role: 'alert' }, icon('alert'), h('div', { class: 'text' }, update.message || 'The update did not work.'));
    } else if (update?.available) {
      message = h('div', { class: 'banner info' }, icon('info'), h('div', { class: 'text' }, h('span', { class: 'title' }, `Version ${update.latest} is available`), update.notes || 'It installs next to the system you are running and takes effect when you restart.'));
    } else if (update?.checked) {
      message = h('p', { class: 'muted' }, `You have the latest version. Checked ${timeAgo(update.checked)}.`);
    } else if (update?.message) {
      message = h('p', { class: 'muted' }, update.message);
    }
    if (state === 'ready' || update?.rebootRequired) {
      message = h('div', { class: 'banner ok' }, icon('check'), h('div', { class: 'text' }, h('span', { class: 'title' }, 'The update is installed'), 'Restart the bridge to start using it. If it doesn’t come up healthy, the bridge goes back to this version by itself.'));
    }
    const idle = !busy && !working();
    return h('div', { class: 'card' }, h('h2', null, 'Updates'),
      h('p', { class: 'desc' }, 'Updates are written to a spare copy of the system and checked on the next start, so a bad update can’t leave you without a working bridge. Your cameras and settings are kept apart from the system.'),
      !info.canUpdate ? h('p', { class: 'muted' }, 'Updates are handled by the Camera Bridge OS image. This copy runs as a plain program.') : [message,
        h('div', { class: 'row' },
          h('button', { class: 'btn', type: 'button', disabled: !idle, onclick: () => run('check', async () => { update = await post('system/update', { action: 'check' }); await refresh(); }) }, busy === 'check' ? spinner() : icon('refresh'), 'Check for updates'),
          update?.available && !update.rebootRequired && state !== 'downloading' ? h('button', { class: 'btn primary', type: 'button', disabled: !idle, onclick: async () => {
            if (await confirmDialog({ title: `Install version ${update.latest}?`, body: 'It downloads, installs, and waits for you to restart the bridge. Cameras keep working meanwhile.', confirm: 'Install update' })) {
              run('apply', async () => { update = await post('system/update', { action: 'apply' }); });
            }
          } }, busy === 'apply' ? spinner() : icon('download'), 'Install update') : null),
        info.canManage && typeof info.automaticUpdates === 'boolean'
          ? switchRow({
            title: 'Install updates automatically', desc: 'The bridge checks every day, installs a new version and restarts at 03:00 UTC.', checked: info.automaticUpdates, disabled: !!busy,
            onchange: (enabled) => run('auto', async () => { info = await post('system/auto-update', { enabled }); update = info.update || null; toast(enabled ? 'Automatic updates are on.' : 'Automatic updates are off.', 'ok'); }),
          }) : null]);
  }

  async function reboot() {
    const ok = await confirmDialog({ title: 'Restart the bridge?', body: 'Your cameras are unavailable in the Home app for a minute or two while it restarts.', confirm: 'Restart', danger: true });
    if (!ok) return;
    run('reboot', async () => {
      await post('system/reboot', { confirm: true });
      toast('Restarting. This page reconnects when the bridge is back.', 'ok', 8000);
    });
  }

  async function powerOff() {
    const ok = await confirmDialog({ title: 'Switch the bridge off?', body: 'Your cameras are unavailable in the Home app until you switch it on again at the machine.', confirm: 'Switch off', danger: true });
    if (!ok) return;
    run('poweroff', async () => {
      await post('system/poweroff', { confirm: true });
      toast('Switching off. You can unplug it when the lights have gone out.', 'ok', 8000);
    });
  }

  function restartCard() {
    return h('div', { class: 'card' }, h('h2', null, 'Restart and switch off'), h('p', { class: 'desc' }, 'A restart takes a minute or two.'),
      h('div', { class: 'row' },
        h('button', { class: 'btn danger', type: 'button', disabled: !info.canReboot || !!busy, onclick: reboot }, busy === 'reboot' ? spinner() : icon('power'), 'Restart the bridge…'),
        info.canManage ? h('button', { class: 'btn', type: 'button', disabled: !!busy, onclick: powerOff }, busy === 'poweroff' ? spinner() : icon('power'), 'Switch off…') : null),
      !info.canReboot ? h('p', { class: 'small muted' }, 'Not available when running as a plain program.') : null);
  }

  // SSH -----------------------------------------------------------------------------------------------------------------

  async function enableSSH() {
    const keys = await promptDialog({
      title: 'Turn on SSH', multiline: true, label: 'Your public key',
      body: 'Paste the public key (the line from your .pub file) of each computer that may sign in as root. Only key login works, never a password. You can paste up to 20 keys, one per line.',
      placeholder: 'ssh-ed25519 AAAA… you@computer', confirm: 'Turn on SSH',
    });
    if (keys === undefined) return;
    run('ssh', async () => {
      info = await post('system/ssh', { enabled: true, authorizedKeys: keys });
      toast('SSH is on. Sign in as root with your key.', 'ok');
    });
  }

  async function disableSSH() {
    run('ssh', async () => {
      info = await post('system/ssh', { enabled: false });
      toast('SSH is off.', 'ok');
    });
  }

  function sshCard() {
    if (!info.canManage || typeof info.sshEnabled !== 'boolean') return null;
    return h('div', { class: 'card' }, h('h2', null, 'SSH'),
      h('p', { class: 'desc' }, 'SSH lets you sign in to the bridge from a terminal, for example to look at the log. It is off unless you turn it on, and only your own key can sign in.'),
      h('div', { class: 'row' },
        h('span', { class: `pill ${info.sshEnabled ? 'live' : 'idle'}` }, info.sshEnabled ? 'On' : 'Off'),
        info.sshEnabled
          ? [h('button', { class: 'btn', type: 'button', disabled: !!busy, onclick: enableSSH }, 'Replace keys…'), h('button', { class: 'btn', type: 'button', disabled: !!busy, onclick: disableSSH }, busy === 'ssh' ? spinner() : null, 'Turn off SSH')]
          : h('button', { class: 'btn', type: 'button', disabled: !!busy, onclick: enableSSH }, busy === 'ssh' ? spinner() : null, 'Turn on SSH…')));
  }

  // Installing to a disk --------------------------------------------------------------------------------------------------

  async function loadDisks() {
    await run('disks', async () => { disks = (await get('system/disks')).disks; });
  }

  function installProgress() {
    const progress = info.install;
    if (!progress) return null;
    if (progress.state === 'running' || progress.state === 'queued') {
      return h('div', { class: 'banner info install-progress', role: 'status' }, spinner(), h('div', { class: 'text' },
        h('span', { class: 'title' }, `Installing${progress.device ? ` to ${progress.device}` : ''}`), INSTALL_STEPS[progress.step] || progress.message || 'Working…',
        h('div', { class: 'small muted' }, 'This page may lose contact while the bridge copies its data. It keeps trying.')));
    }
    if (progress.state === 'ok' && progress.step === 'done') {
      return h('div', { class: 'banner ok install-progress', role: 'status' }, icon('check'), h('div', { class: 'text' }, h('span', { class: 'title' }, 'The system is installed on the disk'),
        progress.message || 'Remove the USB stick, then start the machine again.'));
    }
    if (progress.state === 'failed') {
      return h('div', { class: 'banner error install-progress', role: 'alert' }, icon('alert'), h('div', { class: 'text' }, h('span', { class: 'title' }, 'The installation did not finish'), progress.message || 'Nothing was changed on the disk you chose, or it can be tried again.'));
    }
    return null;
  }

  function installCard() {
    if (!info.canInstall) return null;
    const installing = info.install?.state === 'running' || info.install?.state === 'queued';
    return h('div', { class: 'card' }, h('h2', null, 'Install to a disk in this machine'),
      h('p', { class: 'desc' }, 'Running from a USB stick? Copy Camera Bridge OS to the machine’s own disk to run faster and without the stick. Everything on that disk is erased. The disk the bridge is running from is never offered.'),
      installProgress(),
      switchRow({ title: 'Copy my cameras, settings and Home pairings', desc: 'Off: the new system starts empty and you set it up again. Do not run the stick again afterwards if you copy them.', checked: copyData, disabled: !!busy || installing, onchange: (v) => { copyData = v; } }),
      disks === null
        ? h('button', { class: 'btn', type: 'button', disabled: !!busy || installing, onclick: loadDisks }, busy === 'disks' ? spinner() : icon('search'), 'Find disks')
        : disks.length === 0 ? h('p', { class: 'muted' }, 'No other disk was found.')
          : h('div', { class: 'found' }, disks.map((disk) => h('div', { class: 'card disk' },
            h('div', null, h('strong', null, disk.name), h('div', { class: 'small muted' }, [disk.model, bytes(disk.sizeBytes), disk.note].filter(Boolean).join(' · ')),
              disk.eligible ? null : h('div', { class: 'small problems' }, disk.problems.join('. '))),
            disk.eligible ? h('button', { class: 'btn danger', type: 'button', disabled: !!busy || installing, onclick: () => install(disk) }, 'Install here…') : null))));
  }

  async function install(disk) {
    const phrase = disk.phrase || `ERASE ALL DATA ON ${disk.name}`;
    const ok = await phraseDialog({
      title: `Install to ${disk.name}?`, phrase, confirm: 'Erase the disk and install',
      body: `Everything on ${disk.name}${disk.model ? ` (${disk.model}, ${bytes(disk.sizeBytes)})` : ''} will be erased, then Camera Bridge OS is copied there${copyData ? ', with your cameras, settings and pairings' : ', empty'}. This can’t be undone. When it is done the machine switches off: remove the stick, then start it again.`,
    });
    if (!ok) return;
    run('install', async () => {
      await post('system/install', { targetID: disk.id, phrase, copyData });
      await refresh();
      toast('Installing. Remove the stick when the bridge says it is done, then start it from the disk.', 'ok', 10000);
    });
  }

  // Factory reset -----------------------------------------------------------------------------------------------------------

  async function factoryReset() {
    const ok = await phraseDialog({
      title: 'Erase all settings?', phrase: 'RESET', confirm: 'Erase everything and restart',
      body: 'This removes every camera, your password and all Home pairings from this bridge, then restarts it as new. Add the bridge to Apple Home again afterwards (remove the old one from Home first). Your cameras themselves are not touched.',
    });
    if (!ok) return;
    run('reset', async () => {
      await post('system/factory-reset', { confirm: 'RESET' });
      toast('Resetting. The bridge restarts and shows the first-run page.', 'ok', 10000);
    });
  }

  function resetCard() {
    if (!info.canManage) return null;
    return h('div', { class: 'card' }, h('h2', null, 'Start over'),
      h('p', { class: 'desc' }, 'Erase all settings, camera passwords and Home pairings and set the bridge up again from the beginning.'),
      h('button', { class: 'btn danger', type: 'button', disabled: !!busy, onclick: factoryReset }, busy === 'reset' ? spinner() : icon('trash'), 'Factory reset…'));
  }

  function draw() {
    replace(root, aboutCard(), updateCard(), sshCard(), restartCard(), installCard(), resetCard());
  }

  replace(root, h('div', { class: 'checking' }, spinner()));
  load();
  return { el: h('div', null, h('div', { class: 'page-head' }, h('h1', null, 'System')), bannerHost, root), destroy() { destroyed = true; clearTimeout(pollTimer); bannerHost.destroy(); } };
}
