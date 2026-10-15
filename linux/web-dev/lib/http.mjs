// The small HTTP pieces the dev server shares: the API's error type, JSON answers, body reading and the request checks the daemon makes
// (BridgeWeb/WebApp.swift hostAllowed, originAllowed, the cookie).

import { createHash, timingSafeEqual } from 'node:crypto';

export const COOKIE_NAME = 'cb_session';

/** A problem the API answers with: a status, a code for the page's code, a sentence for the person (never a path or a secret). */
export class ApiError extends Error {
  constructor(status, code, message, { field = null, headers = {} } = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.field = field;
    this.headers = headers;
  }

  static invalid(message, field = null) {
    return new ApiError(400, 'invalid', message, { field });
  }

  static notFound(message = 'That doesn’t exist.') {
    return new ApiError(404, 'not_found', message);
  }
}

export const json = (value, status = 200, headers = {}) => ({ status, headers: { 'Content-Type': 'application/json; charset=utf-8', ...headers }, body: Buffer.from(JSON.stringify(value)) });
export const bytes = (data, type, headers = {}) => ({ status: 200, headers: { 'Content-Type': type, ...headers }, body: data });
export const empty = (status = 204, headers = {}) => ({ status, headers, body: null });

export function errorResponse(error) {
  const body = { error: error.code, message: error.message };
  if (error.field) body.field = error.field;
  return json(body, error.status, error.headers);
}

/** Reads the request body (at most `limit` bytes; more is a 413 as the daemon's limits say). */
export async function readBody(request, limit = 1_048_576) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > limit) throw new ApiError(413, 'too_large', 'That request is too large.');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

/** The body as a JSON object; anything else is 400 invalid. */
export function parseObject(body) {
  let value;
  try {
    value = JSON.parse(body.toString('utf8'));
  } catch {
    throw ApiError.invalid('The request isn’t valid JSON.');
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw ApiError.invalid('The request isn’t what was expected.');
  return value;
}

export function constantTimeEqual(a, b) {
  const x = createHash('sha256').update(String(a)).digest();
  const y = createHash('sha256').update(String(b)).digest();
  return timingSafeEqual(x, y);
}

export function parseCookies(header = '') {
  const cookies = {};
  for (const part of header.split(';')) {
    const at = part.indexOf('=');
    if (at > 0) cookies[part.slice(0, at).trim()] = part.slice(at + 1).trim();
  }
  return cookies;
}

/** The host name in a Host header: no port, no brackets. */
export function hostName(header) {
  if (!header) return '';
  if (header.startsWith('[')) return header.slice(1, header.indexOf(']')).toLowerCase();
  return header.split(':')[0].toLowerCase();
}

/** Whether the Host header may reach the bridge: its IP address, its .local name, localhost, a name on the local network (WebApp.hostAllowed). */
export function hostAllowed(request, extra = []) {
  const header = request.headers.host;
  if (!header) return request.httpVersion === '1.0';
  const name = hostName(header);
  if (!name) return false;
  if (extra.some((entry) => entry.toLowerCase() === name)) return true;
  if (name === 'localhost' || name.endsWith('.local') || name.endsWith('.local.') || name.endsWith('.home.arpa')) return true;
  if (name.includes(':')) return /^[0-9a-f:.%a-z]+$/i.test(name);
  const parts = name.split('.');
  if (parts.length === 4 && parts.every((part) => /^\d{1,3}$/.test(part) && Number(part) <= 255)) return true;
  if (!name.includes('.')) return /^[\p{L}\p{N}_-]+$/u.test(name);
  return false;
}

const authority = (text) => {
  const value = text.toLowerCase().trim();
  return value.endsWith(':80') ? value.slice(0, -3) : value;
};

/** A request that changes something must come from this site (WebApp.originAllowed). */
export function originAllowed(request) {
  const origin = request.headers.origin;
  if (origin !== undefined) {
    const at = origin.indexOf('://');
    if (at < 0 || !request.headers.host || origin.slice(0, at).toLowerCase() !== 'http') return false;
    return authority(origin.slice(at + 3)) === authority(request.headers.host);
  }
  const site = request.headers['sec-fetch-site'];
  if (site !== undefined) return ['same-origin', 'none'].includes(site.toLowerCase());
  return true;
}

export const isLoopback = (address = '') => address === '::1' || address === '127.0.0.1' || address.startsWith('::ffff:127.');

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
