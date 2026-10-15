// The page-wide scheduler for requests to the recordings routes.
//
// A browser keeps six connections per host over plain HTTP, and the event stream and a preview picture use two of them, so the page never
// has more than `caps.bytes` media requests (3) and `caps.json` JSON requests (1) in flight, however many tiles it shows. The server keeps
// answering a request after the page lost interest and holds its admission slot until the engine's 5 s deadline, so a request is never
// aborted to cancel it: a newer request with the same key replaces an OLDER ONE THAT HAS NOT STARTED, and the result of one that has
// started is simply not used. The only aborts are destroy() and a request stuck beyond STUCK_MS (api.js does that one through `timeoutMs`).

export const STUCK_MS = 8000;
const RETRY_DELAYS_MS = [1000, 2000, 4000];
const MAX_RETRY_AFTER_MS = 10_000;

function named(name, message) {
  const error = new Error(message);
  error.name = name;
  return error;
}

/** The error a request gets when a newer request with the same key took its place before it started. Callers ignore it. */
export const supersededError = () => named('Superseded', 'A newer request replaced this one.');
/** The error every pending request gets from destroy(). Callers ignore it. */
export const destroyedError = () => named('AbortError', 'The fetcher was destroyed.');

function isRetriable(error) {
  return error && (error.status === 429 || error.status === 503 || error.status === 504 || (error.status === 0 && error.code === 'network'));
}

function retryDelay(error, attempt) {
  if (Number.isFinite(error.retryAfter)) return Math.min(Math.max(error.retryAfter * 1000, 0), MAX_RETRY_AFTER_MS);
  return RETRY_DELAYS_MS[attempt];
}

export function createFetcher({ get, getBytes, sleep, caps = { bytes: 3, json: 1 } }) {
  const controller = new AbortController();
  const queue = [];                          // requests that are not running: state 'queued' or 'backoff'
  const running = { bytes: 0, json: 0 };
  const busy = new Set();                    // `${kind}:${key}` of the requests in flight
  let sequence = 0;
  let isDestroyed = false;

  const slot = (request) => `${request.kind}:${request.key}`;

  function pick(kind) {
    let best = null;
    for (const request of queue) {
      if (request.kind !== kind || request.state !== 'queued') continue;
      if (request.key != null && busy.has(slot(request))) continue;      // one request in flight per key
      if (!best || request.priority > best.priority || (request.priority === best.priority && request.seq < best.seq)) best = request;
    }
    return best;
  }

  function pump() {
    if (isDestroyed) return;
    for (const kind of ['bytes', 'json']) {
      while (running[kind] < caps[kind]) {
        const next = pick(kind);
        if (!next) break;
        start(next);
      }
    }
  }

  function finish(request) {
    running[request.kind] -= 1;
    if (request.key != null) busy.delete(slot(request));
  }

  function start(request) {
    queue.splice(queue.indexOf(request), 1);
    request.state = 'inflight';
    running[request.kind] += 1;
    if (request.key != null) busy.add(slot(request));
    let promise;
    try {
      promise = Promise.resolve((request.kind === 'bytes' ? getBytes : get)(request.path, { signal: controller.signal, timeoutMs: STUCK_MS }));
    } catch (error) {
      promise = Promise.reject(error);
    }
    promise.then(
      (value) => { finish(request); request.resolve(value); pump(); },
      (error) => { finish(request); fail(request, error); pump(); },
    );
  }

  function fail(request, error) {
    if (!isDestroyed && isRetriable(error) && request.attempt < RETRY_DELAYS_MS.length) {
      const delay = retryDelay(error, request.attempt);
      request.attempt += 1;
      request.state = 'backoff';              // not running: its slot is free and a newer request with the same key may replace it
      queue.push(request);
      sleep(delay).then(() => {
        if (request.state !== 'backoff') return;
        request.state = 'queued';
        pump();
      });
      return;
    }
    if (error && error.status === 410 && error.code !== 'gone') error.code = 'gone';
    request.reject(error);
  }

  function enqueue(kind, path, { key, priority = 0 } = {}) {
    if (isDestroyed) return Promise.reject(destroyedError());
    return new Promise((resolve, reject) => {
      if (key != null) supersede(key, kind);
      queue.push({ kind, path, key, priority, seq: (sequence += 1), attempt: 0, state: 'queued', resolve, reject });
      pump();
    });
  }

  function supersede(key, kind) {
    for (const request of [...queue]) {
      if (request.key !== key || (kind && request.kind !== kind)) continue;
      queue.splice(queue.indexOf(request), 1);
      request.reject(supersededError());
    }
  }

  return {
    json: (path, options) => enqueue('json', path, options),
    bytes: (path, options) => enqueue('bytes', path, options),
    supersede: (key) => supersede(key),
    stats: () => ({ bytesInFlight: running.bytes, jsonInFlight: running.json, queued: queue.length }),
    destroy() {
      if (isDestroyed) return;
      isDestroyed = true;
      for (const request of queue.splice(0)) request.reject(destroyedError());
      controller.abort();
    },
  };
}
