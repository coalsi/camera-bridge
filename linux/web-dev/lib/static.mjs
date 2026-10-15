// Serves linux/web the way BridgeWeb/StaticFiles.swift does: GET and HEAD only, `/` is index.html, no listing and no fallback page, a path
// is decoded once and may not contain dot-leading or empty segments, backslashes or NUL, symbolic links may not lead out of the directory,
// a strong ETag answers If-None-Match with 304, pages, scripts and styles are `no-cache`, images and fonts may be kept for a day.

import { createHash } from 'node:crypto';
import { readFile, realpath, stat } from 'node:fs/promises';
import { extname, join, sep } from 'node:path';

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.htm': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.webmanifest': 'application/manifest+json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.txt': 'text/plain; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
};
const LONG_CACHE = new Set(['.png', '.jpg', '.jpeg', '.svg', '.ico', '.woff2', '.webp']);

/** The file a request path names, relative to the directory; null for anything that is not a plain path below it. */
export function relativePath(rawPath) {
  if (!rawPath.startsWith('/')) return null;
  let decoded;
  try {
    decoded = decodeURIComponent(rawPath);
  } catch {
    return null;
  }
  if (decoded.includes('\0') || decoded.includes('\\')) return null;
  const segments = (decoded === '/' ? '/index.html' : decoded).split('/').slice(1);
  if (!segments.length || segments.some((segment) => segment === '' || segment.startsWith('.'))) return null;
  return segments.join('/');
}

export function createStaticFiles(directory) {
  const rootPromise = realpath(directory);
  const cache = new Map();
  return async function respond(request, path) {
    if (request.method !== 'GET' && request.method !== 'HEAD') return { status: 405, headers: { Allow: 'GET, HEAD' }, body: null };
    const root = await rootPromise;
    const relative = relativePath(path);
    if (!relative) return notFound();
    let resolved;
    try {
      resolved = await realpath(join(root, relative));
    } catch {
      return notFound();
    }
    if (!resolved.startsWith(root + sep)) return notFound();
    const info = await stat(resolved).catch(() => null);
    if (!info || !info.isFile() || info.size > 8 * 1024 * 1024) return notFound();
    let entry = cache.get(resolved);
    if (!entry || entry.mtimeMs !== info.mtimeMs || entry.size !== info.size) {
      const data = await readFile(resolved);
      entry = { data, mtimeMs: info.mtimeMs, size: info.size, etag: `"${createHash('sha256').update(data).digest('hex').slice(0, 16)}"`, modified: info.mtime.toUTCString() };
      cache.set(resolved, entry);
    }
    const extension = extname(relative).toLowerCase();
    const headers = {
      'Content-Type': TYPES[extension] ?? 'application/octet-stream',
      ETag: entry.etag,
      'X-Content-Type-Options': 'nosniff',
      'Cache-Control': LONG_CACHE.has(extension) ? 'public, max-age=86400' : 'no-cache',
      'Last-Modified': entry.modified,
    };
    const match = request.headers['if-none-match'];
    if (match && (match.trim() === '*' || match.split(',').some((candidate) => [entry.etag, `W/${entry.etag}`].includes(candidate.trim())))) {
      return { status: 304, headers, body: null };
    }
    return { status: 200, headers, body: entry.data };
  };
}

const notFound = () => ({ status: 404, headers: { 'Content-Type': 'text/plain; charset=utf-8' }, body: Buffer.from('Not found\n') });
