// The real backend: one Eufy account through @mega-yfue/eufy-sdk (the v6 "mega" cloud, P2P, FCM push).
//
// Persisted in the state dir (all 0600):
//   identity.json  this install's openudid (random, made once, kept across sign-outs) — the token is
//                  bound to it, and a stable one keeps Eufy from treating every restart as a new phone
//   session.json   the SDK's session record: auth token, ECDH share key + key ident, region, ids, expiry
//   push.json      the SDK's FCM credentials + seen push ids
//   meta.json      the account email + country (needed to rebuild the client without a password)
// The password is never written. While this process lives the SDK holds it in memory and silently signs
// in again when Eufy rejects the token; after a restart it has only the token, so a token Eufy ends
// surfaces as "sign in again" (sessionLost).

import { EventEmitter } from "node:events";
import { randomBytes } from "node:crypto";
import * as realSdk from "@mega-yfue/eufy-sdk";
import { log, scrub, errorText } from "./log.js";

const DEVICE_LIST_TTL_MS = 30_000;
/** A battery station's P2P session closes this long after the last use, so the camera can sleep. */
const P2P_IDLE_MS = 20_000;
/** The SDK keeps the shared pull this long after our consumer detaches (a quick re-open reuses it). */
const LIVE_LINGER_MS = 1_000;
const LIVE_OPEN_TIMEOUT_MS = 20_000;
/** No cloud report for this long → reported offline. A heuristic: the SDK deliberately has no online flag. */
const OFFLINE_AFTER_MS = 24 * 3600_000;

const EVENT_KIND = {
  motion: "motion",
  personDetected: "person",
  strangerDetected: "person",
  doorbellPress: "ring",
};

function sdkLogger() {
  const last = new Map();
  const emit = (level, args) => {
    const msg = scrub(args.map((a) => (a instanceof Error ? a.message : typeof a === "string" ? a : JSON.stringify(a))).join(" "));
    const now = Date.now();
    if ((last.get(msg) ?? 0) > now - 60_000) return; // the same line at most once a minute
    last.set(msg, now);
    if (last.size > 500) last.clear();
    log("sdk", { level, msg });
  };
  return {
    debug: () => {},
    info: () => {},
    warn: (...a) => emit("warn", a),
    error: (...a) => emit("error", a),
  };
}

function num(v) {
  const n = typeof v === "number" ? v : typeof v === "string" && v.trim() !== "" ? Number(v) : NaN;
  return Number.isFinite(n) ? n : undefined;
}

function propValue(dev, name) {
  try {
    return dev.getProperty?.(name)?.value;
  } catch {
    return undefined;
  }
}

let EufyMega, LoginStatus, SessionExpiredError;
function useSdk(sdk) {
  ({ EufyMega, LoginStatus, SessionExpiredError } = sdk);
}
useSdk(realSdk);

export class RealBackend extends EventEmitter {
  /** @param {{state: any, ffmpeg?: string, sdk?: any}} opts  `sdk` replaces the SDK module (tests). */
  constructor({ state, ffmpeg, sdk }) {
    super();
    if (sdk) useSdk(sdk);
    this.state = state;
    this.ffmpeg = ffmpeg;
    this.client = null;
    this.account = null;
    this.deviceCache = new Map(); // sn -> Device (bound)
    this.listCache = null; // {at, list}
    this.onlineSeen = new Map();
    this.codecs = this.state.readJSON("codecs.json") ?? {};
    this.liveSources = new Set();
  }

  openudid() {
    const id = this.state.readJSON("identity.json");
    if (id && typeof id.openudid === "string" && /^[0-9a-f]{16}$/.test(id.openudid)) return id.openudid;
    const openudid = randomBytes(8).toString("hex");
    this.state.writeJSON("identity.json", { openudid, createdAt: new Date().toISOString() });
    return openudid;
  }

  makeClient(email, password, country) {
    const client = new EufyMega({
      email,
      password,
      countryCode: country,
      openudid: this.openudid(),
      store: this.state.jsonStore("session.json"),
      pushStore: this.state.jsonStore("push.json"),
      ffmpegPath: this.ffmpeg,
      p2pIdleMs: P2P_IDLE_MS,
      prewarmEvents: [],
      logger: sdkLogger(),
    });
    client.on("error", (e) => {
      if (e instanceof SessionExpiredError) return;
      log("error", { where: "sdk", error: errorText(e) });
    });
    client.on("sessionExpired", (e) => this.lost(e));
    client.on("pushConnect", () => this.emit("push", { ok: true }));
    client.on("pushDisconnect", () => this.emit("push", { ok: false, problem: "Lost the connection for motion alerts; reconnecting." }));
    client.on("event", (e) => this.onSdkEvent(e));
    client.on("deviceState", (s) => this.onDeviceState(s));
    return client;
  }

  lost(e) {
    if (this.losing) return;
    this.losing = true;
    const why = e?.contended
      ? "Eufy ended this session, probably because the account signed in somewhere else with the same identity. Sign in again."
      : "Eufy ended the session. Sign in again.";
    this.teardown(false).then(() => {
      this.state.remove("session.json");
      this.losing = false;
      this.emit("sessionLost", why);
    });
  }

  onSdkEvent(e) {
    const kind = EVENT_KIND[e?.eventName];
    const serial = e?.deviceSn;
    if (!kind || typeof serial !== "string") return;
    this.emit("camera", { serial, kind, at: new Date().toISOString() });
    // The SDK fetches the push thumbnail itself; pick it up once it has landed.
    for (const ms of [4_000, 12_000]) {
      const t = setTimeout(() => this.pullStored(serial), ms);
      t.unref?.();
    }
  }

  onDeviceState(s) {
    if (!s?.sn) return;
    const online = s.lastSeenMs === undefined || Date.now() - s.lastSeenMs < OFFLINE_AFTER_MS;
    this.noteOnline(s.sn, online);
  }

  noteOnline(serial, online) {
    const prev = this.onlineSeen.get(serial);
    this.onlineSeen.set(serial, online);
    if (prev !== undefined && prev !== online) {
      this.emit("camera", { serial, kind: online ? "online" : "offline", at: new Date().toISOString() });
    }
  }

  async pullStored(serial) {
    const jpeg = await this.storedSnapshot(serial).catch(() => null);
    if (jpeg) this.emit("snapshot", { serial, jpeg, at: Date.now() });
  }

  afterLogin() {
    this.client
      .waitForRealtime({ timeoutMs: 30_000 })
      .then((r) => {
        if (r.push.ready > 0) this.emit("push", { ok: true });
        else if (r.push.failed > 0) this.emit("push", { ok: false, problem: "Couldn't register for Eufy motion alerts; live view still works." });
        else this.emit("push", { ok: false, problem: "Motion alerts are still connecting." });
      })
      .catch((e) => this.emit("push", { ok: false, problem: `Motion alerts unavailable: ${errorText(e)}` }));
  }

  async restore() {
    const meta = this.state.readJSON("meta.json");
    const session = this.state.readJSON("session.json");
    if (!meta?.email || !session?.authToken) return null;
    // No password: the SDK can use the stored token but cannot sign in again by itself.
    this.client = this.makeClient(meta.email, "", meta.country || "US");
    const r = await this.client.login();
    if (r.status !== LoginStatus.Ok) {
      await this.teardown(false);
      return null;
    }
    this.account = meta.email;
    this.afterLogin();
    return { account: meta.email };
  }

  step(r, email) {
    if (r.status === LoginStatus.Ok) {
      this.state.writeJSON("meta.json", { email, country: this.country, signedInAt: new Date().toISOString() });
      this.account = email;
      this.afterLogin();
      return { kind: "ok" };
    }
    if (r.status === LoginStatus.Captcha) return { kind: "captcha", image: r.image, retry: !!r.retry };
    if (r.status === LoginStatus.TwoFactor) return { kind: "code", sentTo: email };
    throw new Error(`unexpected sign-in result ${r.status}`);
  }

  async begin({ email, password, country }) {
    await this.teardown(false);
    // A fresh sign-in was asked for: drop any stored session first, or the SDK would just restore it.
    this.state.remove("session.json");
    this.state.remove("meta.json");
    this.country = country;
    this.email = email;
    this.client = this.makeClient(email, password, country);
    return this.step(await this.client.login({ messageType: 2 }), email);
  }

  async captcha(answer) {
    if (!this.client) throw new Error("no sign-in in progress");
    return this.step(await this.client.solveCaptcha(answer, { messageType: 2 }), this.email);
  }

  async verify(code) {
    if (!this.client) throw new Error("no sign-in in progress");
    return this.step(await this.client.submitVerifyCode(code), this.email);
  }

  async teardown(clear) {
    for (const s of [...this.liveSources]) s.stop();
    const c = this.client;
    this.client = null;
    this.account = null;
    this.deviceCache.clear();
    this.listCache = null;
    if (!c) return;
    try {
      if (clear) await c.logout();
      else await c.disconnect();
    } catch (e) {
      log("error", { where: "disconnect", error: errorText(e) });
    }
    c.removeAllListeners();
    c.on("error", () => {});
  }

  async signOut() {
    await this.teardown(true);
    for (const f of ["session.json", "push.json", "meta.json", "codecs.json"]) this.state.remove(f);
    this.codecs = {};
    this.onlineSeen.clear();
  }

  requireClient() {
    if (!this.client || !this.account) throw new Error("not signed in");
    return this.client;
  }

  async device(sn) {
    let d = this.deviceCache.get(sn);
    if (!d) {
      d = await this.requireClient().getDevice(sn);
      this.deviceCache.set(sn, d);
    }
    return d;
  }

  async rawList() {
    if (this.listCache && Date.now() - this.listCache.at < DEVICE_LIST_TTL_MS) return this.listCache.list;
    let list;
    try {
      list = await this.requireClient().getDevices();
    } catch (e) {
      if (e instanceof SessionExpiredError) this.lost(e);
      throw e;
    }
    this.listCache = { at: Date.now(), list };
    return list;
  }

  async devices() {
    const list = await this.rawList();
    const out = [];
    for (const rec of list) {
      let dev;
      try {
        dev = await this.device(rec.sn);
      } catch (e) {
        if (e instanceof SessionExpiredError) throw e;
        log("error", { where: "device", serial: rec.sn, error: errorText(e) });
        continue;
      }
      let cam;
      try {
        cam = dev.camera?.();
      } catch {
        cam = undefined;
      }
      if (!cam) continue; // stations, sensors, locks: not cameras
      const raw = rec.raw && typeof rec.raw === "object" ? rec.raw : {};
      let info;
      try {
        info = dev.info?.();
      } catch {
        info = undefined;
      }
      const online = rec.lastSeenMs === undefined || Date.now() - rec.lastSeenMs < OFFLINE_AFTER_MS;
      this.noteOnline(rec.sn, online);
      const d = {
        serial: rec.sn,
        name: dev.name || rec.name || rec.sn,
        model: rec.model || dev.model || "",
        type: num(raw.device_type) ?? num(info?.deviceType) ?? -1,
        online,
        livestream: typeof cam.live === "function",
      };
      const battery = num(propValue(dev, "battery"));
      if (dev.has?.("battery") && battery !== undefined && battery >= 0 && battery <= 100) d.battery = battery;
      const charging = propValue(dev, "charging");
      if (typeof charging === "boolean") d.charging = charging;
      const rssi = num(propValue(dev, "wifiRssi")) ?? num(propValue(dev, "rssi"));
      if (rssi !== undefined && rssi < 0) d.wifiRSSI = rssi;
      const fw = info?.firmwareVersion ?? raw.main_sw_version;
      if (typeof fw === "string" && fw) d.firmware = fw;
      const codec = this.codecs[rec.sn];
      if (codec === "h264" || codec === "h265") d.codec = codec;
      out.push(d);
    }
    return out;
  }

  async hasCamera(serial) {
    const list = await this.rawList();
    if (!list.some((r) => r.sn === serial)) return false;
    const dev = await this.device(serial);
    return !!dev.camera?.()?.live;
  }

  async storedSnapshot(serial) {
    if (!this.client) return null;
    const dev = await this.device(serial);
    const cam = dev.camera?.();
    if (!cam?.snapshotStored) return null;
    try {
      const jpeg = await cam.snapshotStored();
      return Buffer.isBuffer(jpeg) ? jpeg : null;
    } catch {
      return null;
    }
  }

  noteCodec(serial, codec) {
    if (this.codecs[serial] === codec) return;
    this.codecs[serial] = codec;
    try {
      this.state.writeJSON("codecs.json", this.codecs);
    } catch {
      /* best effort */
    }
  }

  async openLive(serial) {
    const dev = await this.device(serial);
    const cam = dev.camera?.();
    if (!cam?.live) throw new Error("This camera has no live view.");
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(new Error("The camera didn't answer within 20 seconds.")), LIVE_OPEN_TIMEOUT_MS);
    let stream;
    try {
      // The SDK picks the start command from the topology: a standalone camera such as the SoloCam S220
      // (type 63) owns its P2P session and gets CMD_CONTROL_PAYLOAD/START_LIVE with the 1139 keepalive;
      // a HomeBase-attached one gets CMD_SET_PAYLOAD {cmd:1003}. The power budget follows the battery
      // capability; we extend it for as long as anyone is watching.
      stream = await cam.live({ lingerMs: LIVE_LINGER_MS, signal: ac.signal });
    } finally {
      clearTimeout(timer);
    }
    const src = new EventEmitter();
    let stopped = false;
    src.stop = () => {
      if (stopped) return;
      stopped = true;
      this.liveSources.delete(src);
      try {
        stream.stop();
      } catch (e) {
        log("error", { serial, where: "live_stop", error: errorText(e) });
      }
    };
    this.liveSources.add(src);
    stream.on("video", (f) => {
      if (stopped) return;
      if (f.keyframe && (f.codec === "h264" || f.codec === "h265")) this.noteCodec(serial, f.codec);
      src.emit("video", f);
    });
    stream.on("audio", (f) => !stopped && src.emit("audio", f));
    stream.on("budget", (notice) => {
      if (stopped) return;
      notice.extend();
      log("budget_extended", { serial });
    });
    stream.on("error", (e) => {
      if (stopped) return;
      src.emit("error", e);
      if (e?.name === "LiveStreamStartError" || e?.name === "CameraDisabledError") {
        src.stop();
        src.emit("end", e.name === "CameraDisabledError" ? "camera_disabled" : "no_video");
      }
    });
    stream.on("stop", () => {
      if (stopped) return;
      stopped = true;
      this.liveSources.delete(src);
      src.emit("end", "camera_stopped");
    });
    return src;
  }

  async close() {
    await this.teardown(false);
  }
}
