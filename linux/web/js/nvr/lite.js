// The only NVR module the rest of the page imports when it loads. It is small on purpose: everything else under js/nvr/ is
// fetched on demand, so a mistake in that code can take the recording screens down but never the sign-in page or the camera list.

/** The camera records to the bridge's storage (its Record switch is on). */
export function hasNVR(camera) {
  return camera?.nvrEnabled === true;
}

/** The bridge reports the recording fields at all. A bridge that is too old to record leaves them out, and then no Record control is shown. */
export function nvrSupported(camera) {
  return typeof camera?.nvrEnabled === 'boolean';
}

export const RETRY_AFTER_MS = 15000;

/**
 * Makes `load()`: it imports once and remembers the module; if the import fails it resolves null (and logs the first failure only),
 * and tries again no sooner than RETRY_AFTER_MS later, so a bridge that was restarting at that moment is not held against the page for good.
 */
export function createLoader(importer, { now = Date.now, log = (...args) => console.error(...args) } = {}) {
  let ready = null;
  let inflight = null;
  let failedAt = null;
  let logged = false;
  return function load() {
    if (ready) return Promise.resolve(ready);
    if (inflight) return inflight;
    if (failedAt !== null && now() - failedAt < RETRY_AFTER_MS) return Promise.resolve(null);
    inflight = Promise.resolve().then(importer).then((loaded) => {
      ready = loaded;
      failedAt = null;
      return loaded;
    }, (error) => {
      failedAt = now();
      if (!logged) { logged = true; log('The recording screens did not load.', error); }
      return null;
    }).finally(() => { inflight = null; });
    return inflight;
  };
}

/** The dynamic aggregator (ui.js), or null when it could not be loaded. Callers show nothing for null and carry on. */
export const loadNVR = createLoader(() => import('./ui.js'));
