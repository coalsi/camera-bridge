// The headers camerabridged puts on every answer (BridgeWeb/WebApp.swift addSecurityHeaders, with T00 C.8's one added directive).
// conformance.mjs and the tests compare against these; a daemon that differs is wrong, or this file is out of date.

export const CSP = [
  "default-src 'none'",
  "script-src 'self'",
  "style-src 'self'",
  "img-src 'self' data:",
  "media-src 'self' blob:",
  "connect-src 'self'",
  "font-src 'self'",
  "manifest-src 'self'",
  "base-uri 'none'",
  "form-action 'self'",
  "frame-ancestors 'none'",
].join('; ');

export const SECURITY_HEADERS = {
  'Content-Security-Policy': CSP,
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Referrer-Policy': 'no-referrer',
  'Cross-Origin-Opener-Policy': 'same-origin',
  'Cross-Origin-Resource-Policy': 'same-origin',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=(self), payment=(), usb=()',
};

/** The headers every answer gets; an /api/ answer is never cached unless its handler said otherwise. */
export function withSecurityHeaders(headers, isAPI) {
  const result = { ...headers, ...SECURITY_HEADERS };
  if (isAPI && !Object.keys(result).some((name) => name.toLowerCase() === 'cache-control')) result['Cache-Control'] = 'no-store';
  return result;
}
