// The API client: JSON over fetch with the session cookie (HttpOnly, so the page never sees it) and the anti-forgery token.

export class ApiError extends Error {
  constructor(status, code, message, field) {
    super(message);
    this.status = status;
    this.code = code;
    this.field = field || null;
  }
}

let csrfToken = '';
const listeners = new Set();

/** Called with 'unauthorized' when a request finds the session gone, or 'setup' when the bridge needs its first-run setup. */
export function onAuthChange(fn) { listeners.add(fn); return () => listeners.delete(fn); }
export function setCSRFToken(token) { csrfToken = token || ''; }

export async function api(method, path, body, { signal } = {}) {
  const headers = { Accept: 'application/json' };
  const init = { method, headers, credentials: 'same-origin', cache: 'no-store', signal };
  if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(body);
  }
  if (method !== 'GET' && method !== 'HEAD') headers['X-CSRF-Token'] = csrfToken;
  let response;
  try {
    response = await fetch(`/api/v1/${path}`, init);
  } catch (error) {
    if (error.name === 'AbortError') throw error;
    throw new ApiError(0, 'network', 'The bridge didn’t answer. Check that it is on and that this device is on the same network.');
  }
  if (response.status === 204) return null;
  const type = response.headers.get('Content-Type') || '';
  const data = type.includes('json') ? await response.json().catch(() => null) : await response.text();
  if (!response.ok) {
    const error = new ApiError(response.status, data?.error || 'error', data?.message || `Something went wrong (${response.status}).`, data?.field);
    if (response.status === 401 && error.code === 'unauthorized') listeners.forEach((fn) => fn('unauthorized'));
    if (response.status === 403 && error.code === 'setup_required') listeners.forEach((fn) => fn('setup'));
    throw error;
  }
  return data;
}

export const get = (path, options) => api('GET', path, undefined, options);
export const post = (path, body) => api('POST', path, body ?? {});
export const patch = (path, body) => api('PATCH', path, body);
export const del = (path) => api('DELETE', path);
