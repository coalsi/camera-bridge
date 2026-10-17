// Fake mode (CB_EUFY_FAKE=1): no network to Eufy. Behaves like the real backend as far as the HTTP API
// can tell — the session persists in the state dir across restarts, the camera "wakes" (2 s) only while
// someone reads the stream, video arrives as Annex-B access units and audio as ADTS frames exactly as
// the SDK delivers them, so the same hub and muxer run on it.

import { EventEmitter } from "node:events";
import { spawn, spawnSync } from "node:child_process";
import { log, errorText } from "./log.js";
import { splitAdts, splitNals, nalType } from "./tsmux.js";

export const FAKE_SERIAL = "T8134FAKE0000001";
export const FAKE_DEVICE = Object.freeze({
  serial: FAKE_SERIAL,
  name: "Fake SoloCam",
  model: "T8134",
  type: 63,
  online: true,
  battery: 87,
  livestream: true,
  codec: "h264",
});

const delay = (ms) => new Promise((r) => setTimeout(r, ms));

/** The fake camera charges from its solar panel from 10:00 to 15:59 (local time) and runs on its battery otherwise. */
export function fakeCharge(now = Date.now()) {
  const hour = new Date(now).getHours();
  return hour >= 10 && hour < 16 ? { charging: true, chargingSource: "solar" } : { charging: false, chargingSource: null };
}

function pickH264Encoder(ffmpeg) {
  try {
    const r = spawnSync(ffmpeg, ["-hide_banner", "-encoders"], { encoding: "utf8", timeout: 10_000 });
    const out = r.stdout || "";
    if (/\blibx264\b/.test(out)) return ["-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-profile:v", "main", "-x264-params", "keyint=30:min-keyint=30:scenecut=0:bframes=0:repeat-headers=1"];
    if (/\blibopenh264\b/.test(out)) return ["-c:v", "libopenh264", "-g", "30", "-bf", "0"];
  } catch {
    /* fall through */
  }
  return ["-c:v", "h264", "-g", "30", "-bf", "0"];
}

/** Splits an Annex-B byte stream (with AUD NALs) into access units. */
export class AnnexBSplitter {
  constructor(onUnit) {
    this.buf = Buffer.alloc(0);
    this.onUnit = onUnit;
  }

  push(chunk) {
    this.buf = this.buf.length ? Buffer.concat([this.buf, chunk]) : chunk;
    // Find AUD start codes (00 00 00 01 09 / 00 00 01 09); emit everything before the last one.
    const starts = [];
    for (let i = 0; i + 4 < this.buf.length; i++) {
      if (this.buf[i] === 0 && this.buf[i + 1] === 0) {
        if (this.buf[i + 2] === 1 && (this.buf[i + 3] & 0x1f) === 9) starts.push(i > 0 && this.buf[i - 1] === 0 ? i - 1 : i);
      }
    }
    if (starts.length < 2) return;
    for (let k = 0; k < starts.length - 1; k++) this.emitUnit(this.buf.subarray(starts[k], starts[k + 1]));
    this.buf = Buffer.from(this.buf.subarray(starts[starts.length - 1]));
  }

  emitUnit(au) {
    const nals = splitNals(au);
    const keyframe = nals.some((n) => nalType("h264", n) === 5);
    this.onUnit({ data: Buffer.from(au), keyframe, codec: "h264", width: 1280, height: 720 });
  }
}

export class FakeBackend extends EventEmitter {
  /** @param {{clock?: () => number}} opts  `clock` (ms since the epoch) decides when the fake camera charges (tests). */
  constructor({ state, ffmpeg, wakeMs = 2000, motionEveryMs = 60_000, clock = Date.now }) {
    super();
    this.clock = clock;
    this.state = state;
    this.ffmpeg = ffmpeg;
    this.wakeMs = wakeMs;
    this.motionEveryMs = motionEveryMs;
    this.pending = null;
    this.session = null;
    this.live = new Set();
    this.encoder = null;
    this.fakeMagic = new Set(["captcha", "code"]);
  }

  async restore() {
    const s = this.state.readJSON("session.json");
    if (s?.fake && typeof s.email === "string") {
      this.session = s;
      this.afterSignIn();
      return { account: s.email };
    }
    return null;
  }

  afterSignIn() {
    clearInterval(this.motionTimer);
    this.motionTimer = setInterval(() => this.motion(FAKE_SERIAL), this.motionEveryMs);
    this.motionTimer.unref?.();
    setTimeout(() => this.emit("push", { ok: true }), 50);
    this.makeThumbnail();
  }

  makeThumbnail() {
    if (!this.ffmpeg) return;
    const p = spawn(this.ffmpeg, ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=1", "-frames:v", "1", "-f", "image2", "-c:v", "mjpeg", "pipe:1"], {
      stdio: ["ignore", "pipe", "ignore"],
    });
    const out = [];
    p.stdout.on("data", (d) => out.push(d));
    p.on("error", () => {});
    p.on("close", () => {
      const jpeg = Buffer.concat(out);
      if (jpeg.length > 2 && jpeg[0] === 0xff && jpeg[1] === 0xd8) this.emit("snapshot", { serial: FAKE_SERIAL, jpeg, at: Date.now() - 60_000 });
    });
  }

  motion(serial = FAKE_SERIAL) {
    if (!this.session) return false;
    this.emit("camera", { serial, kind: "motion", at: new Date().toISOString() });
    return true;
  }

  persist(email) {
    this.session = { fake: true, email, savedAt: Date.now() };
    this.state.writeJSON("session.json", this.session);
    this.afterSignIn();
  }

  async begin({ email, password }) {
    await delay(150);
    this.state.remove("session.json");
    this.session = null;
    if (password === "captcha") {
      this.pending = { email, need: "captcha" };
      return { kind: "captcha", image: FAKE_CAPTCHA_PNG, retry: false };
    }
    if (password === "code") {
      this.pending = { email, need: "code" };
      return { kind: "code", sentTo: email };
    }
    this.persist(email);
    return { kind: "ok" };
  }

  async captcha(answer) {
    await delay(100);
    if (this.pending?.need !== "captcha") throw new Error("no pending captcha");
    if (answer !== "1234") return { kind: "captcha", image: FAKE_CAPTCHA_PNG, retry: true };
    const { email } = this.pending;
    this.pending = null;
    this.persist(email);
    return { kind: "ok" };
  }

  async verify(code) {
    await delay(100);
    if (this.pending?.need !== "code") throw new Error("no pending verification code");
    if (code !== "123456") return { kind: "code", sentTo: this.pending.email };
    const { email } = this.pending;
    this.pending = null;
    this.persist(email);
    return { kind: "ok" };
  }

  async signOut() {
    for (const s of [...this.live]) s.stop();
    clearInterval(this.motionTimer);
    this.session = null;
    this.pending = null;
    this.state.remove("session.json");
  }

  async devices() {
    if (!this.session) throw new Error("not signed in");
    await delay(50);
    const { charging, chargingSource } = fakeCharge(this.clock());
    const { livestream, codec, ...rest } = FAKE_DEVICE;
    return [{ ...rest, charging, chargingSource, livestream, codec }];
  }

  async hasCamera(serial) {
    return !!this.session && serial === FAKE_SERIAL;
  }

  async storedSnapshot() {
    return null;
  }

  async openLive(serial) {
    if (!this.ffmpeg) throw new Error("fake mode needs ffmpeg (CB_EUFY_FFMPEG)");
    if (serial !== FAKE_SERIAL) throw new Error("unknown camera");
    this.encoder ??= pickH264Encoder(this.ffmpeg);
    const src = new EventEmitter();
    const procs = [];
    let stopped = false;
    let wakeTimer;
    const backend = this;
    src.stop = () => {
      if (stopped) return;
      stopped = true;
      clearTimeout(wakeTimer);
      for (const p of procs) {
        try {
          p.kill("SIGKILL");
        } catch {
          /* gone */
        }
      }
      backend.live.delete(src);
      log("fake_camera", { serial, camera: "asleep" });
    };
    this.live.add(src);
    log("fake_camera", { serial, camera: "waking" });
    wakeTimer = setTimeout(() => {
      if (stopped) return;
      log("fake_camera", { serial, camera: "awake" });
      const common = ["-hide_banner", "-loglevel", "error", "-nostdin", "-re"];
      const video = spawn(
        this.ffmpeg,
        [...common, "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=15", "-pix_fmt", "yuv420p", ...this.encoder, "-b:v", "1500k", "-bsf:v", "h264_metadata=aud=insert", "-f", "h264", "pipe:1"],
        { stdio: ["ignore", "pipe", "pipe"] },
      );
      const audio = spawn(
        this.ffmpeg,
        [...common, "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=16000", "-ac", "1", "-c:a", "aac", "-b:a", "32k", "-f", "adts", "pipe:1"],
        { stdio: ["ignore", "pipe", "pipe"] },
      );
      procs.push(video, audio);
      const splitter = new AnnexBSplitter((f) => !stopped && src.emit("video", f));
      video.stdout.on("data", (d) => splitter.push(d));
      let rest = Buffer.alloc(0);
      audio.stdout.on("data", (d) => {
        const r = splitAdts(rest.length ? Buffer.concat([rest, d]) : d);
        rest = Buffer.from(r.rest);
        for (const f of r.frames) if (!stopped) src.emit("audio", { codec: "aac-lc", data: Buffer.from(f) });
      });
      for (const [name, p] of [["video", video], ["audio", audio]]) {
        let err = "";
        p.stderr.on("data", (d) => (err = (err + d).slice(-400)));
        p.on("error", (e) => !stopped && src.emit("error", e));
        p.on("close", (code) => {
          if (stopped) return;
          src.emit("error", new Error(`fake ${name} generator exited (${code}): ${err.trim()}`));
          src.stop();
          src.emit("end", "camera_stopped");
        });
      }
    }, this.wakeMs);
    return src;
  }

  async close() {
    for (const s of [...this.live]) s.stop();
    clearInterval(this.motionTimer);
  }
}

// A 1x1 PNG is enough to exercise the captcha flow; the real one is a 4-character picture.
const FAKE_CAPTCHA_PNG =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

export { errorText };
