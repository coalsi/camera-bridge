// Powering the machine off from the page: System › Restart and power off, and the power button in the top bar.
import { post } from './api.js';
import { confirmDialog, toast } from './dom.js';

/** Asks first; true when the person said yes. */
export function askToPowerOff() {
  return confirmDialog({
    title: 'Power off the bridge?',
    body: 'Recording stops and your cameras are unavailable in the Home app until you switch the machine on again with its power button.',
    confirm: 'Power off', danger: true,
  });
}

/** Tells the bridge to power off (throws when it refuses). */
export async function powerOff() {
  await post('system/poweroff', { confirm: true });
  toast('Powering off. You can unplug it when its light has gone out.', 'ok', 8000);
}
