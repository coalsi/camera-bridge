// Latest picture per camera, served without waking it: the newest of a push thumbnail the SDK retained,
// or the last keyframe of a live view decoded to JPEG by ffmpeg. Kept in memory and in the state dir
// (snap-<serial>.jpg) so a restart still has one.

import { spawn } from "node:child_process";
import { log, errorText } from "./log.js";

export const SERIAL_RE = /^[A-Za-z0-9_-]{4,40}$/;
const DECODE_EVERY_MS = 15_000;

export function isJpeg(buf) {
  return Buffer.isBuffer(buf) && buf.length > 4 && buf[0] === 0xff && buf[1] === 0xd8;
}

/** Decode one Annex-B keyframe to JPEG with ffmpeg. */
export function decodeKeyframe(ffmpeg, au, codec, timeoutMs = 10_000) {
  return new Promise((resolve, reject) => {
    const args = [
      "-hide_banner",
      "-loglevel",
      "error",
      "-f",
      codec === "h265" ? "hevc" : "h264",
      "-i",
      "pipe:0",
      "-frames:v",
      "1",
      "-q:v",
      "4",
      "-f",
      "image2",
      "-c:v",
      "mjpeg",
      "pipe:1",
    ];
    const p = spawn(ffmpeg, args, { stdio: ["pipe", "pipe", "pipe"] });
    const out = [];
    let err = "";
    const timer = setTimeout(() => p.kill("SIGKILL"), timeoutMs);
    p.stdout.on("data", (d) => out.push(d));
    p.stderr.on("data", (d) => (err = (err + d).slice(-500)));
    p.on("error", (e) => {
      clearTimeout(timer);
      reject(e);
    });
    p.on("close", (code) => {
      clearTimeout(timer);
      const jpeg = Buffer.concat(out);
      if (isJpeg(jpeg)) resolve(jpeg);
      else reject(new Error(`ffmpeg could not decode the keyframe (exit ${code}): ${err.trim()}`));
    });
    p.stdin.on("error", () => {});
    p.stdin.end(au);
  });
}

export class SnapshotCache {
  constructor({ state, ffmpeg }) {
    this.state = state;
    this.ffmpeg = ffmpeg;
    this.mem = new Map(); // serial -> {jpeg, at}
    this.lastDecode = new Map();
    this.decoding = new Set();
  }

  get(serial) {
    if (!SERIAL_RE.test(serial)) return null;
    let e = this.mem.get(serial);
    if (!e) {
      const b = this.state.readBuffer(`snap-${serial}.jpg`);
      if (isJpeg(b)) {
        e = { jpeg: b, at: 0 };
        this.mem.set(serial, e);
      }
    }
    return e ?? null;
  }

  put(serial, jpeg, at = Date.now()) {
    if (!SERIAL_RE.test(serial) || !isJpeg(jpeg)) return;
    const cur = this.mem.get(serial);
    if (cur && cur.at > at) return;
    if (cur && cur.jpeg.equals(jpeg)) return;
    this.mem.set(serial, { jpeg, at });
    try {
      this.state.write(`snap-${serial}.jpg`, jpeg);
    } catch (e) {
      log("error", { serial, where: "snapshot_save", error: errorText(e) });
    }
  }

  /** Called with every keyframe of a live view; decodes one now and then. */
  fromKeyframe(serial, au, codec) {
    if (!this.ffmpeg || this.decoding.has(serial)) return;
    const last = this.lastDecode.get(serial) ?? 0;
    if (Date.now() - last < DECODE_EVERY_MS) return;
    this.lastDecode.set(serial, Date.now());
    this.decoding.add(serial);
    const at = Date.now();
    decodeKeyframe(this.ffmpeg, Buffer.from(au), codec)
      .then((jpeg) => this.put(serial, jpeg, at))
      .catch((e) => log("error", { serial, where: "snapshot_decode", error: errorText(e) }))
      .finally(() => this.decoding.delete(serial));
  }

  clear() {
    for (const name of this.state.list()) if (/^snap-.*\.jpg$/.test(name)) this.state.remove(name);
    this.mem.clear();
    this.lastDecode.clear();
  }
}
