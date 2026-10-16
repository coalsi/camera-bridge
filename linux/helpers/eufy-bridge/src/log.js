// Status lines on stderr: `cb-eufy event=<name> key=value …`.
//
// Everything that reaches stderr goes through scrub(): registered secrets (the API token, a password or
// code while a sign-in is in flight, captcha answers) are replaced by "***", and anything that has the
// shape of a credential (long hex/base64 runs, bearer/token/key/password assignments, signed URL query
// strings) is redacted as well, because SDK error text is not ours and may carry any of them.

const secrets = new Set();

/** Register a value that must never appear in a log line (ignored when short or empty). */
export function addSecret(value) {
  if (typeof value === "string" && value.length >= 4) secrets.add(value);
}

/** Forget a value registered with addSecret (once the sign-in step that needed it is over). */
export function removeSecret(value) {
  secrets.delete(value);
}

function escapeRegExp(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** Remove secrets and credential-shaped text from a string meant for a person or a log. */
export function scrub(input) {
  let s = String(input ?? "");
  // Longest first, so a secret containing another is removed whole.
  for (const v of [...secrets].sort((a, b) => b.length - a.length)) {
    s = s.replace(new RegExp(escapeRegExp(v), "g"), "***");
  }
  // key=value / "key":"value" / key: value for credential-ish keys.
  s = s.replace(
    /((?:auth[_-]?token|x-auth-token|gtoken|token|password|passwd|secret|private[_-]?key|ecc_private_key|share[_-]?key|session[_-]?key|authorization|answer|verify[_-]?code|captcha[_-]?id)["']?\s*[:=]\s*["']?)(bearer\s+)?[^\s"',;}&]+/gi,
    "$1***",
  );
  s = s.replace(/\bbearer\s+[A-Za-z0-9._~+/=-]+/gi, "Bearer ***");
  // Signed URLs: keep scheme/host/path, drop the query.
  s = s.replace(/(https?:\/\/[^\s?"']+)\?[^\s"']*/gi, "$1?…");
  // Long hex (keys, tokens) and long base64/base64url runs.
  s = s.replace(/\b[0-9a-f]{24,}\b/gi, "[redacted]");
  s = s.replace(/[A-Za-z0-9+/_-]{40,}={0,2}/g, "[redacted]");
  // data: URLs (captcha images) are noise and could carry anything.
  s = s.replace(/data:[a-z]+\/[a-z0-9.+-]+;base64,[A-Za-z0-9+/=]*/gi, "data:…");
  return s;
}

function formatValue(v) {
  const s = scrub(v === undefined || v === null ? "" : typeof v === "object" ? JSON.stringify(v) : String(v))
    .replace(/[\r\n]+/g, " ")
    .slice(0, 400);
  if (s === "" || /[\s"=]/.test(s)) return `"${s.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
  return s;
}

/** Render one status line (exported for tests). */
export function formatLine(event, fields = {}) {
  let line = `cb-eufy event=${event}`;
  for (const [k, v] of Object.entries(fields)) {
    if (v === undefined) continue;
    line += ` ${k}=${formatValue(v)}`;
  }
  return line;
}

let sink = (line) => process.stderr.write(line + "\n");

/** Replace the output sink (tests). Returns the previous one. */
export function setSink(fn) {
  const prev = sink;
  sink = fn;
  return prev;
}

/** Write one status line. */
export function log(event, fields) {
  sink(formatLine(event, fields));
}

/** A person-readable sentence from any thrown value, scrubbed. */
export function errorText(err) {
  const msg = err instanceof Error ? err.message : String(err);
  return scrub(msg).slice(0, 300);
}
