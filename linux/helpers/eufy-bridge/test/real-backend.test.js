// The real backend against a scripted stand-in for the SDK: checks what we ask of the SDK (identity,
// stores, no stored password, live options, budget extension, stop) and how its answers map onto
// the contract. The SDK itself is verified only against the real cloud and camera.
import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { RealBackend } from "../src/backend-real.js";
import { startApp, request, openStream, waitFor, TOKEN, fakeAu, adtsFrame, captureLog, tempDir } from "./helpers.js";
import { StateDir } from "../src/statedir.js";

class SessionExpiredError extends Error {
  constructor(m, o = {}) {
    super(m);
    this.name = "SessionExpiredError";
    this.contended = !!o.contended;
  }
}
const LoginStatus = { Ok: "ok", Captcha: "captcha", TwoFactor: "2fa" };

function makeSdk(log) {
  class EufyMega extends EventEmitter {
    constructor(opts) {
      super();
      this.opts = opts;
      log.clients.push(this);
    }
    async login() {
      log.calls.push(["login", this.opts.password === "" ? "" : "pw"]);
      const s = this.opts.store.load();
      if (s?.authToken) return { status: "ok", session: { restored: true } };
      if (this.opts.password === "") throw new Error("no credentials");
      return { status: "captcha", image: "data:image/png;base64,AAAA", retry: false };
    }
    async solveCaptcha(answer) {
      log.calls.push(["captcha", answer]);
      if (answer !== "ABCD") return { status: "captcha", image: "data:image/png;base64,BBBB", retry: true };
      return { status: "2fa", method: "email" };
    }
    async submitVerifyCode(code) {
      log.calls.push(["code", code]);
      this.opts.store.save({ authToken: "AUTHTOKEN0123456789abcdef", shareKey: "00112233445566778899aabbccddeeff", openudid: this.opts.openudid });
      return { status: "ok", session: {} };
    }
    async waitForRealtime() {
      return { state: "ready", push: { required: 1, ready: 1, failed: 0, pending: 0 } };
    }
    async getDevices() {
      if (log.expire) throw new SessionExpiredError("gone");
      return [
        { sn: "T8134ABCDEFG0001", name: "Porch", model: "T8134", raw: { device_type: 63, main_sw_version: "3.4.5" }, lastSeenMs: Date.now() - 60_000 },
        { sn: "T8010STATION0001", name: "Base", model: "T8010", raw: { device_type: 0 } },
      ];
    }
    async getDevice(sn) {
      const camera = sn.startsWith("T8134")
        ? () => ({
            live: async (opts) => {
              log.liveOpts.push(opts);
              const s = new EventEmitter();
              s.stop = () => log.calls.push(["stream.stop"]);
              log.streams.push(s);
              return s;
            },
            snapshotStored: async () => {
              throw new Error("not-observed");
            },
          })
        : undefined;
      return {
        sn,
        name: sn.startsWith("T8134") ? "Porch" : "Base",
        has: (c) => c === "battery" && sn.startsWith("T8134"),
        getProperty: (n) => ({ battery: { value: 64 }, charging: { value: false }, wifiRssi: { value: -58 } })[n],
        camera,
        info: () => ({ firmwareVersion: "3.4.5", deviceType: 63 }),
      };
    }
    async disconnect() {
      log.calls.push(["disconnect"]);
    }
    async logout() {
      log.calls.push(["logout"]);
      this.opts.store.clear();
    }
  }
  return { EufyMega, LoginStatus, SessionExpiredError };
}

function newLog() {
  return { clients: [], calls: [], liveOpts: [], streams: [], expire: false };
}

test("real backend: sign-in steps, identity, no password on disk, device mapping", async () => {
  const log = newLog();
  const dir = tempDir();
  const state = new StateDir(join(dir, "state"));
  const backend = new RealBackend({ state, sdk: makeSdk(log) });
  const app = await startApp({ backend, dir });
  try {
    let r = await request(app.port, "POST", "/sign-in", { body: { email: "guest@example.com", password: "Sup3r-Secret-PW", country: "us" } });
    assert.equal(r.json.state, "needsCaptcha");
    const c = log.clients[0].opts;
    assert.equal(c.countryCode, "US");
    assert.match(c.openudid, /^[0-9a-f]{16}$/);
    assert.ok(c.p2pIdleMs <= 60_000, "battery camera P2P detaches after a short idle");
    assert.deepEqual(c.prewarmEvents, []);
    r = await request(app.port, "POST", "/captcha", { body: { id: r.json.captcha.id, answer: "nope" } });
    assert.equal(r.json.state, "needsCaptcha");
    r = await request(app.port, "POST", "/captcha", { body: { id: r.json.captcha.id, answer: "ABCD" } });
    assert.equal(r.json.state, "needsCode");
    assert.equal(r.json.codeSentTo, "guest@example.com");
    r = await request(app.port, "POST", "/verify", { body: { code: "654321" } });
    assert.deepEqual(r.json, { state: "signedIn", account: "guest@example.com" });

    for (const f of readdirSync(join(dir, "state"))) {
      assert.ok(!readFileSync(join(dir, "state", f), "utf8").includes("Sup3r-Secret-PW"), `password in ${f}`);
    }
    const ident = JSON.parse(readFileSync(join(dir, "state", "identity.json"), "utf8"));
    assert.equal(ident.openudid, c.openudid);

    const d = await request(app.port, "GET", "/devices");
    assert.deepEqual(d.json.devices, [
      { serial: "T8134ABCDEFG0001", name: "Porch", model: "T8134", type: 63, online: true, livestream: true, battery: 64, charging: false, wifiRSSI: -58, firmware: "3.4.5" },
    ]);
  } finally {
    await app.close();
  }

  // Restart: restored from the token, rebuilt without a password, same identity.
  const log2 = newLog();
  const state2 = new StateDir(join(dir, "state"));
  const app2 = await startApp({ backend: new RealBackend({ state: state2, sdk: makeSdk(log2) }), dir });
  try {
    assert.equal((await request(app2.port, "GET", "/status")).json.state, "signedIn");
    assert.equal(log2.clients[0].opts.password, "");
    assert.equal(log2.clients[0].opts.email, "guest@example.com");
    assert.match(log2.clients[0].opts.openudid, /^[0-9a-f]{16}$/);
    // The token is then rejected and cannot be renewed without the password: sign in again.
    log2.expire = true;
    const d = await request(app2.port, "GET", "/devices");
    assert.equal(d.status, 502);
    await waitFor(async () => (await request(app2.port, "GET", "/status")).json.state === "signedOut");
    assert.match((await request(app2.port, "GET", "/status")).json.error, /sign in again/i);
  } finally {
    await app2.close();
    app2.cleanup();
  }
});

test("real backend: live view options, budget extension, stop, codec remembered", async () => {
  const log = newLog();
  const cap = captureLog();
  const dir = tempDir();
  const state = new StateDir(join(dir, "state"));
  state.writeJSON("meta.json", { email: "guest@example.com", country: "US" });
  state.writeJSON("session.json", { authToken: "AUTHTOKEN0123456789abcdef" });
  const app = await startApp({ backend: new RealBackend({ state, sdk: makeSdk(log) }), dir });
  try {
    const pending = openStream(app.port, `/stream/${TOKEN}/T8134ABCDEFG0001`); // headers come with the first video
    await waitFor(() => log.streams.length === 1);
    const opts = log.liveOpts[0];
    assert.ok(opts.lingerMs <= 4000, "the SDK stops the pull soon after we detach");
    assert.ok(opts.signal instanceof AbortSignal);
    const s = log.streams[0];
    let n = 0;
    const t = setInterval(() => {
      s.emit("audio", { codec: "aac-lc", data: adtsFrame() });
      s.emit("video", { data: fakeAu(n % 15 === 0, n), keyframe: n % 15 === 0, codec: "h264" });
      n++;
    }, 30);
    let extended = 0;
    s.emit("budget", { graceMs: 10_000, extend: () => extended++ });
    assert.equal(extended, 1, "budget extended while someone watches");
    const client = await pending;
    await waitFor(() => client.bytes().length > 10_000);
    assert.equal(client.res.headers["content-type"], "video/mp2t");
    client.req.destroy();
    await waitFor(() => log.calls.some((c) => c[0] === "stream.stop"), 5000);
    clearInterval(t);
    const d = await request(app.port, "GET", "/devices");
    assert.equal(d.json.devices[0].codec, "h264");
    assert.ok(cap.lines.some((l) => l.startsWith("cb-eufy event=first_video serial=T8134ABCDEFG0001")));
    // A camera that never sends video ends with the SDK's start error.
    const r = request(app.port, "GET", `/stream/${TOKEN}/T8134ABCDEFG0001`, { token: null });
    await waitFor(() => log.streams.length === 2);
    const e = new Error("no keyframe");
    e.name = "LiveStreamStartError";
    log.streams[1].emit("error", e);
    assert.equal((await r).status, 503);
    // Not a camera / unknown.
    assert.equal((await request(app.port, "GET", `/stream/${TOKEN}/T8010STATION0001`, { token: null })).status, 404);
  } finally {
    await app.close();
    cap.restore();
    app.cleanup();
  }
});

test("real backend: sign-out logs out and forgets session, push and account files", async () => {
  const log = newLog();
  const dir = tempDir();
  const state = new StateDir(join(dir, "state"));
  state.writeJSON("meta.json", { email: "guest@example.com", country: "US" });
  state.writeJSON("session.json", { authToken: "AUTHTOKEN0123456789abcdef" });
  state.writeJSON("push.json", { creds: {} });
  const app = await startApp({ backend: new RealBackend({ state, sdk: makeSdk(log) }), dir });
  try {
    assert.equal((await request(app.port, "GET", "/status")).json.state, "signedIn");
    assert.deepEqual((await request(app.port, "POST", "/sign-out")).json, { state: "signedOut" });
    assert.ok(log.calls.some((c) => c[0] === "logout"));
    const left = readdirSync(join(dir, "state"));
    assert.deepEqual(left.filter((f) => ["session.json", "push.json", "meta.json"].includes(f)), []);
  } finally {
    await app.close();
    app.cleanup();
  }
});
