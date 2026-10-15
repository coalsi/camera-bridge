// The API client: JSON over fetch with the session cookie (HttpOnly, so the page never sees it) and the anti-forgery token.

export class ApiError extends Error {
  /** `extra`: { retryAfter?: seconds (the Retry-After header), next?: milliseconds (the X-CB-Next header) } */
  constructor(status, code, message, field, extra = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.field = field || null;
    this.retryAfter = Number.isFinite(extra.retryAfter) ? extra.retryAfter : null;
    this.next = Number.isFinite(extra.next) ? extra.next : null;
  }
}

let csrfToken = '';
const listeners = new Set();

const NETWORK_MESSAGE = 'The bridge didn’t answer. Check that it is on and that this device is on the same network.';
const TIMEOUT_MESSAGE = 'The bridge took too long to answer.';

/** Called with 'unauthorized' when a request finds the session gone, or 'setup' when the bridge needs its first-run setup. */
export function onAuthChange(fn) { listeners.add(fn); return () => listeners.delete(fn); }
/** Tells every listener what `api()` and `getBytes()` found: 'unauthorized' or 'setup'. */
export function notifyAuth(kind) { for (const fn of [...listeners]) fn(kind); }
export function setCSRFToken(token) { csrfToken = token || ''; }

function parseSeconds(value) {
  if (value === null || value === undefined || !/^\d{1,6}$/.test(value.trim())) return null;
  return Number(value);
}

function parseMilliseconds(value) {
  if (value === null || value === undefined || !/^\d{1,15}$/.test(value.trim())) return null;
  return Number(value);
}

function failure(response, data) {
  const error = new ApiError(response.status, data?.error || 'error', data?.message || `Something went wrong (${response.status}).`, data?.field, {
    retryAfter: parseSeconds(response.headers.get('Retry-After')),
    next: parseMilliseconds(response.headers.get('X-CB-Next')),
  });
  if (response.status === 401 && error.code === 'unauthorized') notifyAuth('unauthorized');
  if (response.status === 403 && error.code === 'setup_required') notifyAuth('setup');
  return error;
}

async function send(url, init) {
  try {
    return await fetch(url, init);
  } catch (error) {
    if (error.name === 'AbortError') throw error;
    throw new ApiError(0, 'network', NETWORK_MESSAGE);
  }
}

/** Runs `run(signal)` under the caller's signal and an optional deadline. A deadline that passes is ApiError(0, 'timeout'). */
async function withDeadline({ signal, timeoutMs }, run) {
  if (!signal && !timeoutMs) return run(undefined);
  const controller = new AbortController();
  let timedOut = false;
  const forward = () => controller.abort();
  if (signal) {
    if (signal.aborted) controller.abort();
    else signal.addEventListener('abort', forward, { once: true });
  }
  const timer = timeoutMs ? setTimeout(() => { timedOut = true; controller.abort(); }, timeoutMs) : null;
  try {
    return await run(controller.signal);
  } catch (error) {
    if (timedOut) throw new ApiError(0, 'timeout', TIMEOUT_MESSAGE);
    throw error;
  } finally {
    if (timer) clearTimeout(timer);
    if (signal) signal.removeEventListener('abort', forward);
  }
}

export async function api(method, path, body, { signal, timeoutMs } = {}) {
  const headers = { Accept: 'application/json' };
  const init = { method, headers, credentials: 'same-origin', cache: 'no-store' };
  if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(body);
  }
  if (method !== 'GET' && method !== 'HEAD') headers['X-CSRF-Token'] = csrfToken;
  return withDeadline({ signal, timeoutMs }, async (deadlineSignal) => {
    const response = await send(`/api/v1/${path}`, { ...init, signal: deadlineSignal });
    if (response.status === 204) return null;
    const type = response.headers.get('Content-Type') || '';
    const data = type.includes('json') ? await response.json().catch(() => null) : await response.text();
    if (!response.ok) throw failure(response, data);
    return data;
  });
}

/**
 * GET /api/v1/<path> for media: resolves { data: ArrayBuffer, headers: Headers }. Same cookie, same 401 handling as `api()`, no CSRF header
 * (GET needs none). A JSON error body becomes an ApiError whose `retryAfter` (seconds) and `next` (ms) come from Retry-After and X-CB-Next.
 */
export async function getBytes(path, { signal, timeoutMs } = {}) {
  const init = { method: 'GET', headers: { Accept: 'video/mp4, application/json;q=0.9' }, credentials: 'same-origin', cache: 'no-store' };
  return withDeadline({ signal, timeoutMs }, async (deadlineSignal) => {
    const response = await send(`/api/v1/${path}`, { ...init, signal: deadlineSignal });
    if (!response.ok) {
      const type = response.headers.get('Content-Type') || '';
      const data = type.includes('json') ? await response.json().catch(() => null) : null;
      throw failure(response, data);
    }
    return { data: await response.arrayBuffer(), headers: response.headers };
  });
}

/**
 * GET /api/v1/<path> as a stream that stays open (the live video): resolves the readable body once the answer started. Same cookie and 401
 * handling as `api()`; no deadline (it is meant to run until `signal` aborts it).
 */
export async function openStream(path, { signal } = {}) {
  const response = await send(`/api/v1/${path}`, { method: 'GET', headers: { Accept: 'application/octet-stream, application/json;q=0.9' }, credentials: 'same-origin', cache: 'no-store', signal });
  if (!response.ok || !response.body) {
    const type = response.headers.get('Content-Type') || '';
    const data = type.includes('json') ? await response.json().catch(() => null) : null;
    throw failure(response, data);
  }
  return response.body;
}

export const get = (path, options) => api('GET', path, undefined, options);
export const post = (path, body) => api('POST', path, body ?? {});
export const patch = (path, body) => api('PATCH', path, body);
export const del = (path) => api('DELETE', path);
