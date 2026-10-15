// A `fetch` for page modules running in Node (api.js and the modules built on it): relative URLs go to the dev server, and the session cookie
// the server sets is sent back, as a browser does for credentials: 'same-origin'. Capture the real fetch first: installFakeBrowser replaces it.

const realFetch = globalThis.fetch;

export function cookieFetch(base) {
  let cookie = null;
  const wrapped = async (input, init = {}) => {
    const url = typeof input === 'string' && input.startsWith('/') ? `${base}${input}` : input;
    const headers = new Headers(init.headers);
    if (cookie && init.credentials !== 'omit') headers.set('Cookie', cookie);
    const response = await realFetch(url, { ...init, headers });
    for (const line of response.headers.getSetCookie()) {
      const pair = line.split(';')[0];
      cookie = pair.endsWith('=') ? null : pair;
    }
    return response;
  };
  wrapped.signOut = () => { cookie = null; };
  return wrapped;
}
