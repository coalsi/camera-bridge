// The loopback HTTP API. Every request carries the token: `Authorization: Bearer <token>`, except the
// stream and snapshot paths, which carry it in the path (go2rtc cannot send headers).

import http from "node:http";
import { createHash, timingSafeEqual } from "node:crypto";
import { HttpError } from "./bridge.js";
import { SERIAL_RE } from "./snapshots.js";
import { log, errorText } from "./log.js";

const MAX_BODY = 16 * 1024;
const PING_MS = 15_000;

function digest(s) {
  return createHash("sha256").update(String(s)).digest();
}

export function tokenMatches(expected, given) {
  if (typeof given !== "string" || given.length === 0) return false;
  return timingSafeEqual(digest(expected), digest(given));
}

function sendJSON(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
    "Cache-Control": "no-store",
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (d) => {
      size += d.length;
      if (size > MAX_BODY) {
        reject(new HttpError(413, "Request body too large."));
        req.destroy();
        return;
      }
      chunks.push(d);
    });
    req.on("end", () => {
      const text = Buffer.concat(chunks).toString("utf8").trim();
      if (!text) return resolve({});
      try {
        const v = JSON.parse(text);
        if (!v || typeof v !== "object" || Array.isArray(v)) return reject(new HttpError(400, "Body must be a JSON object."));
        resolve(v);
      } catch {
        reject(new HttpError(400, "Body is not valid JSON."));
      }
    });
    req.on("error", reject);
  });
}

/**
 * @param {{bridge: import("./bridge.js").Bridge, token: string, fake?: import("./backend-fake.js").FakeBackend}} deps
 */
export function createServer({ bridge, token, fake, pingMs = PING_MS }) {
  const eventClients = new Set();

  bridge.on("camera", (ev) => {
    const line = JSON.stringify({ serial: ev.serial, kind: ev.kind, at: ev.at }) + "\n";
    for (const res of eventClients) res.write(line);
  });

  const pinger = setInterval(() => {
    const line = JSON.stringify({ kind: "ping", at: new Date().toISOString() }) + "\n";
    for (const res of eventClients) res.write(line);
  }, pingMs);
  pinger.unref?.();

  async function route(req, res) {
    const url = new URL(req.url ?? "/", "http://127.0.0.1");
    const parts = url.pathname.split("/").filter(Boolean);
    const method = req.method ?? "GET";

    // Path-token routes.
    if (parts[0] === "stream" || parts[0] === "snapshot") {
      if (parts.length !== 3) throw new HttpError(404, "Not found.");
      if (!tokenMatches(token, decodeURIComponent(parts[1]))) throw new HttpError(401, "Wrong or missing token.");
      if (method !== "GET" && method !== "HEAD") throw new HttpError(405, "Use GET.");
      const serial = decodeURIComponent(parts[2]);
      if (!SERIAL_RE.test(serial)) throw new HttpError(404, "No camera with that serial.");
      if (parts[0] === "snapshot") {
        const jpeg = await bridge.snapshot(serial);
        if (!jpeg) throw new HttpError(404, "No picture from this camera yet.");
        res.writeHead(200, { "Content-Type": "image/jpeg", "Content-Length": jpeg.length, "Cache-Control": "no-store" });
        res.end(method === "HEAD" ? undefined : jpeg);
        return;
      }
      if (method === "HEAD") throw new HttpError(405, "Use GET.");
      req.socket.setNoDelay(true);
      await bridge.stream(serial, res);
      return;
    }

    const auth = req.headers.authorization ?? "";
    const m = /^Bearer\s+(\S+)$/i.exec(auth);
    if (!m || !tokenMatches(token, m[1])) throw new HttpError(401, "Wrong or missing token.");

    const key = `${method} /${parts.join("/")}`;
    switch (key) {
      case "GET /status":
        return sendJSON(res, 200, bridge.getStatus());
      case "POST /sign-in":
        return sendJSON(res, 200, await bridge.signIn(await readBody(req)));
      case "POST /captcha":
        return sendJSON(res, 200, await bridge.captcha(await readBody(req)));
      case "POST /verify":
        return sendJSON(res, 200, await bridge.verify(await readBody(req)));
      case "POST /sign-out":
        return sendJSON(res, 200, await bridge.signOut());
      case "GET /devices":
        return sendJSON(res, 200, { devices: await bridge.devices() });
      case "GET /events": {
        res.writeHead(200, {
          "Content-Type": "application/x-ndjson; charset=utf-8",
          "Cache-Control": "no-store",
          "X-Content-Type-Options": "nosniff",
        });
        res.write(JSON.stringify({ kind: "hello", at: new Date().toISOString() }) + "\n");
        eventClients.add(res);
        res.on("close", () => eventClients.delete(res));
        return;
      }
      case "POST /fake/motion": {
        if (!fake) throw new HttpError(404, "Not found.");
        const body = await readBody(req);
        const ok = fake.motion(typeof body.serial === "string" ? body.serial : undefined);
        if (!ok) throw new HttpError(409, "Sign in to Eufy first.");
        return sendJSON(res, 200, { ok: true });
      }
      default: {
        const known = ["status", "sign-in", "captcha", "verify", "sign-out", "devices", "events"];
        if (parts.length === 1 && known.includes(parts[0])) throw new HttpError(405, "Method not allowed.");
        throw new HttpError(404, "Not found.");
      }
    }
  }

  const server = http.createServer((req, res) => {
    route(req, res).catch((err) => {
      const status = err instanceof HttpError ? err.status : 500;
      if (!(err instanceof HttpError)) log("error", { where: "http", path: (req.url ?? "").split("/")[1], error: errorText(err) });
      if (res.headersSent) {
        res.end();
        return;
      }
      sendJSON(res, status, { error: err instanceof HttpError ? err.message : "Something went wrong in the Eufy helper." });
    });
  });
  server.keepAliveTimeout = 5_000;
  server.headersTimeout = 10_000;
  server.requestTimeout = 0; // streams are long-lived
  server.on("close", () => {
    clearInterval(pinger);
    for (const r of eventClients) r.end();
  });
  server.eventClients = eventClients;
  return server;
}
