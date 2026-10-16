// One live stream per camera, shared by every HTTP client reading it.
//
// The first client opens the camera's livestream; the last one leaving stops it at once (the SDK then
// sends the stop within its short linger). Output is MPEG-TS built by TsMuxer, starting on a keyframe;
// a client joining a running stream is primed with the current GOP so it gets a picture at once.

import { EventEmitter } from "node:events";
import { performance } from "node:perf_hooks";
import { log, errorText } from "./log.js";
import { ParamSetCache, TsMuxer, splitAdts } from "./tsmux.js";

const MAX_GOP_BYTES = 6 * 1024 * 1024;
const SLOW_CLIENT_BYTES = 4 * 1024 * 1024;

export const TS_CONTENT_TYPE = "video/mp2t";

function audioTrackFor(codec) {
  if (codec === "aac-lc" || codec === "aac") return "aac";
  if (codec === "g711a") return "pcma";
  return undefined; // aac-eld cannot be carried as ADTS in MPEG-TS
}

export class StreamHub extends EventEmitter {
  /**
   * @param {{
   *   serial: string,
   *   openSource: (serial: string) => Promise<import("node:events").EventEmitter & {stop(): void}>,
   *   firstVideoTimeoutMs?: number,
   *   stallMs?: number,
   *   audioWaitMs?: number,
   *   onKeyframe?: (au: Buffer, codec: string) => void,
   * }} opts
   */
  constructor(opts) {
    super();
    this.serial = opts.serial;
    this.openSource = opts.openSource;
    this.firstVideoTimeoutMs = opts.firstVideoTimeoutMs ?? 20_000;
    this.stallMs = opts.stallMs ?? 15_000;
    this.audioWaitMs = opts.audioWaitMs ?? 1_000;
    this.onKeyframe = opts.onKeyframe;
    this.clients = new Set();
    this.generation = 0;
    this.reset();
  }

  reset() {
    this.source = null;
    this.running = false;
    this.muxer = null;
    this.params = new ParamSetCache();
    this.pendingVideo = [];
    this.audioCodec = undefined;
    this.audioRest = Buffer.alloc(0);
    this.audioDropNoted = false;
    this.gop = [];
    this.gopBytes = 0;
    this.origin = 0;
    this.lastVideoAt = 0;
    this.firstVideoLogged = false;
    this.videoCodec = undefined;
    clearTimeout(this.audioWaitTimer);
    clearInterval(this.stallTimer);
  }

  get clientCount() {
    return this.clients.size;
  }

  /** Attach an HTTP response. Resolves nothing; the response is ended by the hub. */
  addClient(res) {
    const client = { res, headersSent: false, waitKey: true, timer: null };
    this.clients.add(client);
    client.timer = setTimeout(() => {
      if (!client.headersSent) this.endClient(client, 503, "The camera didn't send video within 20 seconds.");
    }, this.firstVideoTimeoutMs);
    res.on("close", () => this.removeClient(client));
    if (!this.running) this.start();
    else if (this.gop.length) {
      for (const chunk of this.gop) this.writeTo(client, chunk);
    }
    return client;
  }

  removeClient(client) {
    if (!this.clients.delete(client)) return;
    clearTimeout(client.timer);
    if (this.clients.size === 0 && this.running) this.stop("no_clients");
  }

  endClient(client, status, message) {
    clearTimeout(client.timer);
    const { res } = client;
    this.clients.delete(client);
    try {
      if (!client.headersSent && !res.headersSent) {
        const body = JSON.stringify({ error: message });
        res.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Content-Length": Buffer.byteLength(body) });
        res.end(body);
      } else {
        res.end();
      }
    } catch {
      /* socket gone */
    }
    if (this.clients.size === 0 && this.running) this.stop("no_clients");
  }

  endAll(status, message) {
    for (const c of [...this.clients]) this.endClient(c, status, message);
  }

  start() {
    this.running = true;
    const gen = ++this.generation;
    this.origin = performance.now();
    log("stream_start", { serial: this.serial, clients: this.clients.size });
    this.openSource(this.serial).then(
      (source) => {
        if (gen !== this.generation || !this.running) {
          try {
            source.stop();
          } catch {
            /* ignore */
          }
          return;
        }
        this.source = source;
        source.on("video", (f) => gen === this.generation && this.onVideo(f));
        source.on("audio", (f) => gen === this.generation && this.onAudio(f));
        source.on("error", (e) => {
          if (gen !== this.generation) return;
          log("error", { serial: this.serial, where: "stream", error: errorText(e) });
        });
        source.on("end", (reason) => {
          if (gen !== this.generation) return;
          this.finish(reason ? String(reason) : "source_ended", 503, "The camera stream ended.");
        });
      },
      (err) => {
        if (gen !== this.generation) return;
        log("error", { serial: this.serial, where: "stream_open", error: errorText(err) });
        this.finish("open_failed", 503, `The camera stream couldn't start: ${errorText(err)}`);
      },
    );
    this.stallTimer = setInterval(() => {
      if (this.lastVideoAt && performance.now() - this.lastVideoAt > this.stallMs) {
        log("stall", { serial: this.serial, silentMs: Math.round(performance.now() - this.lastVideoAt) });
        this.finish("stall", 503, "The camera stopped sending video.");
      }
    }, 1000);
    this.stallTimer.unref?.();
  }

  /** End every client and stop the source. */
  finish(reason, status, message) {
    if (this.running) this.stop(reason, this.clients.size);
    this.endAll(status, message);
  }

  stop(reason, clients = this.clients.size) {
    if (!this.running) return;
    this.generation++;
    const source = this.source;
    const ranMs = Math.round(performance.now() - this.origin);
    this.reset();
    if (source) {
      try {
        source.stop();
      } catch (e) {
        log("error", { serial: this.serial, where: "stream_stop", error: errorText(e) });
      }
    }
    log("stream_end", { serial: this.serial, reason, clients, ms: ranMs });
    this.emit("idle");
  }

  now() {
    return performance.now() - this.origin;
  }

  onAudio(frame) {
    const track = audioTrackFor(frame.codec);
    if (!track) {
      if (!this.audioDropNoted) {
        this.audioDropNoted = true;
        log("audio_skipped", { serial: this.serial, codec: frame.codec });
      }
      return;
    }
    if (!this.audioCodec) this.audioCodec = track;
    if (!this.muxer || this.muxer.tracks.audio !== track) return;
    const t = this.now();
    if (track === "aac") {
      const { frames, rest } = splitAdts(this.audioRest.length ? Buffer.concat([this.audioRest, frame.data]) : frame.data);
      this.audioRest = rest.length > 8192 ? Buffer.alloc(0) : Buffer.from(rest);
      for (const f of frames) this.broadcast({ buf: this.muxer.audio(f, t), keyframe: false });
    } else {
      this.broadcast({ buf: this.muxer.audio(frame.data, t), keyframe: false });
    }
  }

  onVideo(frame) {
    const t = this.now();
    this.lastVideoAt = performance.now();
    const codec = frame.codec === "h265" ? "h265" : frame.codec === "h264" ? "h264" : null;
    if (!codec) {
      log("error", { serial: this.serial, where: "stream", error: `unsupported video codec ${frame.codec}` });
      this.finish("unsupported_codec", 503, "The camera sends a video format this helper can't carry.");
      return;
    }
    const au = this.params.prepare(codec, frame.data, frame.keyframe);
    if (frame.keyframe) {
      try {
        this.onKeyframe?.(au, codec);
      } catch {
        /* snapshot is best effort */
      }
    }
    if (!this.muxer) {
      if (!frame.keyframe && this.pendingVideo.length === 0) return; // start on a keyframe
      if (frame.keyframe && !this.params.has(codec) && this.pendingVideo.length === 0) return;
      this.pendingVideo.push({ au, keyframe: frame.keyframe, t, codec });
      if (this.audioCodec) this.openMuxer();
      else if (!this.audioWaitTimer) {
        this.audioWaitTimer = setTimeout(() => this.running && !this.muxer && this.openMuxer(), this.audioWaitMs);
      }
      return;
    }
    if (codec !== this.muxer.tracks.video) {
      log("error", { serial: this.serial, where: "stream", error: `codec changed mid-stream to ${codec}` });
      this.finish("codec_changed", 503, "The camera changed video format.");
      return;
    }
    this.emitVideo(au, frame.keyframe, t);
  }

  openMuxer() {
    clearTimeout(this.audioWaitTimer);
    const first = this.pendingVideo[0];
    if (!first) return;
    this.videoCodec = first.codec;
    this.muxer = new TsMuxer({ video: first.codec, audio: this.audioCodec });
    log("first_video", {
      serial: this.serial,
      ms: Math.round(first.t),
      codec: first.codec,
      audio: this.audioCodec ?? "none",
    });
    this.emit("first_video", { codec: first.codec, audio: this.audioCodec });
    const pending = this.pendingVideo;
    this.pendingVideo = [];
    for (const v of pending) this.emitVideo(v.au, v.keyframe, v.t);
  }

  emitVideo(au, keyframe, t) {
    const chunk = { buf: this.muxer.video(au, keyframe, t), keyframe };
    if (keyframe) {
      this.gop = [];
      this.gopBytes = 0;
    }
    if (this.gopBytes + chunk.buf.length <= MAX_GOP_BYTES) {
      this.gop.push(chunk);
      this.gopBytes += chunk.buf.length;
    }
    this.broadcast(chunk);
  }

  broadcast(chunk) {
    if (chunk.keyframe) {
      // keep audio after the GOP start too, so a primed client hears sound
    } else if (this.gop.length && !this.gop.includes(chunk) && this.gopBytes + chunk.buf.length <= MAX_GOP_BYTES) {
      this.gop.push(chunk);
      this.gopBytes += chunk.buf.length;
    }
    for (const c of this.clients) this.writeTo(c, chunk);
  }

  writeTo(client, chunk) {
    const { res } = client;
    if (res.destroyed || res.writableEnded) return;
    if (client.waitKey) {
      if (!chunk.keyframe) return;
      client.waitKey = false;
    }
    if (res.writableLength > SLOW_CLIENT_BYTES) {
      client.waitKey = true; // drop to the next keyframe rather than buffer without bound
      return;
    }
    if (!client.headersSent) {
      client.headersSent = true;
      clearTimeout(client.timer);
      res.writeHead(200, {
        "Content-Type": TS_CONTENT_TYPE,
        "Cache-Control": "no-store",
        "X-Content-Type-Options": "nosniff",
      });
      res.flushHeaders?.();
    }
    res.write(chunk.buf);
  }
}
