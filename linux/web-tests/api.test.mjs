// api.js: getBytes, notifyAuth, timeoutMs and the extras on ApiError (NVR task T08, first commit).
import { afterEach, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { ApiError, api, get, getBytes, notifyAuth, onAuthChange, put, setCSRFToken } from '../web/js/api.js';

const realFetch = globalThis.fetch;
let calls = [];

function stub(handler) {
  calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url, init });
    return handler(url, init);
  };
}

const json = (status, body, headers = {}) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...headers } });

afterEach(() => { globalThis.fetch = realFetch; });

describe('ApiError', () => {
  it('carries the status, code, field and the two header extras', () => {
    const error = new ApiError(429, 'busy', 'Busy.', undefined, { retryAfter: 1, next: 1760000000000 });
    assert.equal(error.status, 429);
    assert.equal(error.code, 'busy');
    assert.equal(error.message, 'Busy.');
    assert.equal(error.field, null);
    assert.equal(error.retryAfter, 1);
    assert.equal(error.next, 1760000000000);
  });

  it('defaults the extras to null', () => {
    const error = new ApiError(404, 'not_found', 'No.', 'id');
    assert.equal(error.field, 'id');
    assert.equal(error.retryAfter, null);
    assert.equal(error.next, null);
  });
});

describe('api()', () => {
  it('sends GET with the cookie, without a token', async () => {
    stub(() => json(200, { ok: true }));
    setCSRFToken('token-1');
    assert.deepEqual(await get('status'), { ok: true });
    assert.equal(calls[0].url, '/api/v1/status');
    assert.equal(calls[0].init.method, 'GET');
    assert.equal(calls[0].init.credentials, 'same-origin');
    assert.equal(calls[0].init.cache, 'no-store');
    assert.equal(calls[0].init.headers['X-CSRF-Token'], undefined);
  });

  it('sends PATCH with the token and a JSON body', async () => {
    stub(() => json(200, { done: 1 }));
    setCSRFToken('token-2');
    await api('PATCH', 'cameras/1/nvr', { enabled: true });
    assert.equal(calls[0].init.headers['X-CSRF-Token'], 'token-2');
    assert.equal(calls[0].init.headers['Content-Type'], 'application/json');
    assert.equal(calls[0].init.body, '{"enabled":true}');
  });

  it('sends PUT (the AI key) with the token and a JSON body, and takes a 204', async () => {
    stub(() => new Response(null, { status: 204 }));
    setCSRFToken('token-4');
    assert.equal(await put('ai/key', { key: 'sk-test-0000' }), null);
    assert.equal(calls[0].url, '/api/v1/ai/key');
    assert.equal(calls[0].init.method, 'PUT');
    assert.equal(calls[0].init.headers['X-CSRF-Token'], 'token-4');
    assert.equal(calls[0].init.headers['Content-Type'], 'application/json');
    assert.equal(calls[0].init.body, '{"key":"sk-test-0000"}');
  });

  it('turns an error answer into an ApiError with the headers parsed', async () => {
    stub(() => json(429, { error: 'busy', message: 'Too many.', field: null }, { 'Retry-After': '2', 'X-CB-Next': '1760000001234' }));
    await assert.rejects(get('nvr/cameras'), (error) => {
      assert.ok(error instanceof ApiError);
      assert.equal(error.status, 429);
      assert.equal(error.code, 'busy');
      assert.equal(error.retryAfter, 2);
      assert.equal(error.next, 1760000001234);
      return true;
    });
  });

  it('ignores a Retry-After that is a date, and a negative or fractional X-CB-Next', async () => {
    stub(() => json(503, { error: 'archive_unavailable', message: 'Loading.' }, { 'Retry-After': 'Wed, 21 Oct 2026 07:28:00 GMT', 'X-CB-Next': '-5' }));
    await assert.rejects(get('nvr/cameras'), (error) => error.retryAfter === null && error.next === null);
  });

  it('notifies on 401 unauthorized and on 403 setup_required, and only on those', async () => {
    const seen = [];
    const off = onAuthChange((kind) => seen.push(kind));
    stub(() => json(401, { error: 'unauthorized', message: 'Sign in.' }));
    await assert.rejects(get('cameras'));
    stub(() => json(403, { error: 'setup_required', message: 'Set up.' }));
    await assert.rejects(get('cameras'));
    stub(() => json(403, { error: 'csrf', message: 'No.' }));
    await assert.rejects(get('cameras'));
    stub(() => json(401, { error: 'bad_login', message: 'No.' }));
    await assert.rejects(get('cameras'));
    off();
    assert.deepEqual(seen, ['unauthorized', 'setup']);
  });

  it('maps a failed fetch to ApiError(0, network)', async () => {
    stub(() => { throw new TypeError('Failed to fetch'); });
    await assert.rejects(get('status'), (error) => error.status === 0 && error.code === 'network');
  });

  it('keeps an AbortError from the caller as it is', async () => {
    const controller = new AbortController();
    stub((url, init) => new Promise((resolve, reject) => {
      init.signal.addEventListener('abort', () => reject(Object.assign(new Error('aborted'), { name: 'AbortError' })));
    }));
    const pending = get('status', { signal: controller.signal });
    controller.abort();
    await assert.rejects(pending, (error) => error.name === 'AbortError');
  });

  it('gives up after timeoutMs with ApiError(0, timeout)', async () => {
    let seenSignal;
    stub((url, init) => new Promise((resolve, reject) => {
      seenSignal = init.signal;
      init.signal.addEventListener('abort', () => reject(Object.assign(new Error('aborted'), { name: 'AbortError' })));
    }));
    await assert.rejects(get('status', { timeoutMs: 25 }), (error) => error.status === 0 && error.code === 'timeout');
    assert.equal(seenSignal.aborted, true);
  });

  it('answers null for 204', async () => {
    stub(() => new Response(null, { status: 204 }));
    assert.equal(await api('POST', 'cameras/1/optimize/undo', {}), null);
  });
});

describe('getBytes()', () => {
  it('resolves the bytes and the headers, with the cookie and no token', async () => {
    const payload = Uint8Array.from([1, 2, 3, 4, 5]);
    stub(() => new Response(payload, { status: 200, headers: { 'Content-Type': 'video/mp4', 'X-CB-Part': '{"id":"a1b2c3d4e5f6.3"}' } }));
    setCSRFToken('token-3');
    const { data, headers } = await getBytes('nvr/cameras/CAM/fragments/a1b2c3d4e5f6.3');
    assert.ok(data instanceof ArrayBuffer);
    assert.deepEqual([...new Uint8Array(data)], [1, 2, 3, 4, 5]);
    assert.equal(headers.get('X-CB-Part'), '{"id":"a1b2c3d4e5f6.3"}');
    assert.equal(calls[0].url, '/api/v1/nvr/cameras/CAM/fragments/a1b2c3d4e5f6.3');
    assert.equal(calls[0].init.method, 'GET');
    assert.equal(calls[0].init.credentials, 'same-origin');
    assert.equal(calls[0].init.cache, 'no-store');
    assert.equal(calls[0].init.headers['X-CSRF-Token'], undefined);
    assert.equal(calls[0].init.headers['Content-Type'], undefined);
    assert.equal(calls[0].init.body, undefined);
  });

  it('turns a JSON error into an ApiError with Retry-After and X-CB-Next', async () => {
    stub(() => json(404, { error: 'gap', message: 'No recording then.' }, { 'X-CB-Next': '1760000099000' }));
    await assert.rejects(getBytes('nvr/cameras/CAM/keyframe?at=1760000000000'), (error) => {
      assert.equal(error.status, 404);
      assert.equal(error.code, 'gap');
      assert.equal(error.next, 1760000099000);
      assert.equal(error.retryAfter, null);
      return true;
    });
    stub(() => json(504, { error: 'drive_slow', message: 'Slow.' }, { 'Retry-After': '2' }));
    await assert.rejects(getBytes('nvr/cameras/CAM/fragments/a1b2c3d4e5f6.3'), (error) => error.code === 'drive_slow' && error.retryAfter === 2);
  });

  it('survives an error without a JSON body', async () => {
    stub(() => new Response('Bad gateway', { status: 502, headers: { 'Content-Type': 'text/plain' } }));
    await assert.rejects(getBytes('nvr/cameras/CAM/fragments/a1b2c3d4e5f6.3'), (error) => {
      assert.equal(error.status, 502);
      assert.equal(error.code, 'error');
      assert.equal(error.message, 'Something went wrong (502).');
      return true;
    });
  });

  it('notifies on 401 unauthorized like api()', async () => {
    const seen = [];
    const off = onAuthChange((kind) => seen.push(kind));
    stub(() => json(401, { error: 'unauthorized', message: 'Sign in.' }));
    await assert.rejects(getBytes('nvr/cameras/CAM/fragments/a1b2c3d4e5f6.3'));
    off();
    assert.deepEqual(seen, ['unauthorized']);
  });

  it('maps a failed fetch to ApiError(0, network)', async () => {
    stub(() => { throw new TypeError('Failed to fetch'); });
    await assert.rejects(getBytes('nvr/cameras/CAM/keyframe?at=1760000000000'), (error) => error.status === 0 && error.code === 'network');
  });

  it('times out while the body is still arriving', async () => {
    stub((url, init) => {
      const body = new ReadableStream({
        start(controller) {
          controller.enqueue(new Uint8Array(8));
          init.signal.addEventListener('abort', () => controller.error(Object.assign(new Error('aborted'), { name: 'AbortError' })));
        },
      });
      return new Response(body, { status: 200, headers: { 'Content-Type': 'video/mp4' } });
    });
    await assert.rejects(getBytes('nvr/cameras/CAM/fragments/a1b2c3d4e5f6.3', { timeoutMs: 25 }), (error) => error.status === 0 && error.code === 'timeout');
  });
});

describe('notifyAuth()', () => {
  it('calls every listener, and a listener that unsubscribes stops hearing', () => {
    const a = [];
    const b = [];
    const offA = onAuthChange((kind) => a.push(kind));
    const offB = onAuthChange((kind) => b.push(kind));
    notifyAuth('unauthorized');
    offA();
    notifyAuth('setup');
    offB();
    notifyAuth('unauthorized');
    assert.deepEqual(a, ['unauthorized']);
    assert.deepEqual(b, ['unauthorized', 'setup']);
  });
});
