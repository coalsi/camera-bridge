import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import http from "node:http";
import { EventEmitter } from "node:events";
import { spawnSync } from "node:child_process";
import { StateDir } from "../src/statedir.js";
import { Bridge } from "../src/bridge.js";
import { createServer } from "../src/server.js";
import { FakeBackend } from "../src/backend-fake.js";
import { setSink } from "../src/log.js";

export const TOKEN = "test-token-0123456789abcdef";

export function findFfmpeg() {
  for (const p of [process.env.CB_EUFY_FFMPEG, "/usr/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]) {
    if (p && spawnSync(p, ["-version"]).status === 0) return p;
  }
  return undefined;
}

export function tempDir() {
  return mkdtempSync(join(tmpdir(), "eufy-bridge-test-"));
}

/** Capture log lines while a test runs. */
export function captureLog() {
  const lines = [];
  const prev = setSink((l) => lines.push(l));
  return { lines, restore: () => setSink(prev) };
}

export async function startApp({ backend, dir, hubOptions, pingMs, fake } = {}) {
  dir ??= tempDir();
  const state = new StateDir(join(dir, "state"));
  const ffmpeg = findFfmpeg();
  backend ??= new FakeBackend({ state, ffmpeg, wakeMs: 200 });
  const bridge = new Bridge({ backend, state, ffmpeg, hubOptions });
  const server = createServer({ bridge, token: TOKEN, fake: fake ?? (backend instanceof FakeBackend ? backend : undefined), pingMs });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  await bridge.init();
  const port = server.address().port;
  return {
    dir,
    state,
    bridge,
    backend,
    server,
    port,
    async close() {
      await bridge.close();
      for (const r of server.eventClients) r.destroy();
      server.closeAllConnections?.();
      await new Promise((r) => server.close(r));
    },
    cleanup() {
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

export function request(port, method, path, { token = TOKEN, body, headers = {} } = {}) {
  return new Promise((resolve, reject) => {
    const h = { ...headers };
    if (token !== null) h.authorization = `Bearer ${token}`;
    const data = body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body);
    if (data) h["content-type"] = "application/json";
    const req = http.request({ host: "127.0.0.1", port, method, path, headers: h }, (res) => {
      const chunks = [];
      res.on("data", (d) => chunks.push(d));
      res.on("end", () => {
        const buf = Buffer.concat(chunks);
        let json;
        try {
          json = JSON.parse(buf.toString("utf8"));
        } catch {
          json = undefined;
        }
        resolve({ status: res.statusCode, headers: res.headers, buf, json });
      });
    });
    req.on("error", reject);
    if (data) req.write(data);
    req.end();
  });
}

/** Open a streaming GET; resolves with {res, req, chunks} once headers arrive. */
export function openStream(port, path) {
  return new Promise((resolve, reject) => {
    const req = http.get({ host: "127.0.0.1", port, path, agent: false }, (res) => {
      const chunks = [];
      res.on("data", (d) => chunks.push(d));
      resolve({ req, res, chunks, bytes: () => Buffer.concat(chunks) });
    });
    req.on("error", reject);
  });
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export async function waitFor(fn, ms = 5000, step = 20) {
  const end = Date.now() + ms;
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (Date.now() > end) throw new Error("timed out waiting");
    await sleep(step);
  }
}

// A minimal, structurally valid H.264 access unit generator (not decodable pictures; enough for the
// muxer, the hub and go2rtc-style parsers that look at NAL types and parameter sets).
const SPS = Buffer.from("6742c01e95a0280bfe5c05b808080a000007d00001d4c1", "hex");
const PPS = Buffer.from("68ce3c80", "hex");
export function fakeAu(keyframe, n = 0) {
  const sc = Buffer.from([0, 0, 0, 1]);
  const slice = Buffer.alloc(400, n & 0xff);
  slice[0] = keyframe ? 0x65 : 0x41;
  slice[1] = 0x88;
  return keyframe ? Buffer.concat([sc, SPS, sc, PPS, sc, slice]) : Buffer.concat([sc, slice]);
}

export function adtsFrame() {
  // AAC-LC, 16 kHz (index 8), mono, 20-byte frame.
  const len = 20;
  const h = Buffer.from([0xff, 0xf1, (1 << 6) | (8 << 2) | 0, (1 << 6) | ((len >> 11) & 3), (len >> 3) & 0xff, ((len & 7) << 5) | 0x1f, 0xfc]);
  return Buffer.concat([h, Buffer.alloc(len - 7, 0x21)]);
}

/** A backend with a scripted camera: counts opens/stops, emits synthetic frames at 15 fps. */
export class MockBackend extends EventEmitter {
  constructor({ wakeMs = 50, sendVideo = true, sendAudio = true } = {}) {
    super();
    this.opens = 0;
    this.stops = [];
    this.wakeMs = wakeMs;
    this.sendVideo = sendVideo;
    this.sendAudio = sendAudio;
    this.signed = true;
  }
  async restore() {
    return { account: "mock@example.com" };
  }
  async begin() {
    return { kind: "ok" };
  }
  async captcha() {
    return { kind: "ok" };
  }
  async verify() {
    return { kind: "ok" };
  }
  async signOut() {}
  async devices() {
    return [{ serial: "T8134MOCK0000001", name: "Mock", model: "T8134", type: 63, online: true, livestream: true }];
  }
  async hasCamera(s) {
    return s === "T8134MOCK0000001";
  }
  async storedSnapshot() {
    return null;
  }
  async openLive() {
    this.opens++;
    const src = new EventEmitter();
    let n = 0;
    let timer;
    const start = setTimeout(() => {
      timer = setInterval(() => {
        if (this.sendAudio) src.emit("audio", { codec: "aac-lc", data: adtsFrame() });
        if (this.sendVideo) src.emit("video", { data: fakeAu(n % 15 === 0, n), keyframe: n % 15 === 0, codec: "h264" });
        n++;
      }, 66);
    }, this.wakeMs);
    src.stop = () => {
      clearTimeout(start);
      clearInterval(timer);
      this.stops.push(Date.now());
    };
    return src;
  }
  async close() {}
}
