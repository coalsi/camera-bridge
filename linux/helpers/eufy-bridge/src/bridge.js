// The account state machine shared by the real and the fake backend, plus the per-camera stream hubs,
// the snapshot cache and the event fan-out.
//
// A backend implements:
//   restore()                         -> Promise<{account} | null>    (persisted session, no sign-in)
//   begin({email,password,country})   -> Promise<Step>
//   captcha(answer)                   -> Promise<Step>
//   verify(code)                      -> Promise<Step>
//   signOut()                         -> Promise<void>                 (forget the session on disk)
//   devices()                         -> Promise<Device[]>
//   hasCamera(serial)                 -> Promise<boolean>
//   openLive(serial)                  -> Promise<Source>               (EventEmitter: video/audio/error/end; stop())
//   storedSnapshot(serial)            -> Promise<Buffer|null>          (passive; never wakes the camera)
//   close()                           -> Promise<void>
// and emits "camera" {serial, kind, at}, "push" {ok, problem?}, "sessionLost" (sentence).
// Step = {kind:"ok"} | {kind:"captcha", image} | {kind:"code", sentTo}.

import { EventEmitter } from "node:events";
import { randomBytes } from "node:crypto";
import { addSecret, removeSecret, log, errorText } from "./log.js";
import { StreamHub } from "./hub.js";
import { SnapshotCache } from "./snapshots.js";

const OP_TIMEOUT_MS = 90_000;

export class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

function withTimeout(p, ms, what) {
  let t;
  return Promise.race([
    p,
    new Promise((_, rej) => {
      t = setTimeout(() => rej(new Error(`${what} took too long; Eufy didn't answer.`)), ms);
      t.unref?.();
    }),
  ]).finally(() => clearTimeout(t));
}

export class Bridge extends EventEmitter {
  constructor({ backend, state, ffmpeg, hubOptions = {} }) {
    super();
    this.backend = backend;
    this.state = state;
    this.status = { state: "signedOut" };
    this.lastLoggedState = undefined;
    this.busy = false;
    this.pending = null; // {email, password, country} kept in memory only while a sign-in is in progress
    this.hubs = new Map();
    this.hubOptions = hubOptions;
    this.snapshots = new SnapshotCache({ state, ffmpeg });
    this.pushProblem = undefined;

    backend.on("camera", (ev) => this.cameraEvent(ev));
    backend.on("push", ({ ok, problem }) => {
      if (ok) {
        if (this.pushProblem !== undefined || !this.pushOkLogged) log("push_ok");
        this.pushOkLogged = true;
        this.pushProblem = undefined;
      } else {
        if (this.pushProblem !== problem) log("push_problem", { problem });
        this.pushProblem = problem;
      }
    });
    backend.on("sessionLost", (sentence) => {
      log("sign_in_needed", { reason: "session_ended" });
      this.stopAllStreams();
      this.set({ state: "signedOut", error: sentence });
    });
    backend.on("snapshot", ({ serial, jpeg, at }) => this.snapshots.put(serial, jpeg, at));
  }

  set(status) {
    this.status = status;
    if (status.state !== this.lastLoggedState) {
      this.lastLoggedState = status.state;
      log("state", { state: status.state });
    }
  }

  getStatus() {
    const s = { state: this.status.state };
    if (this.status.account) s.account = this.status.account;
    if (this.status.captcha) s.captcha = this.status.captcha;
    if (this.status.codeSentTo) s.codeSentTo = this.status.codeSentTo;
    if (this.status.error) s.error = this.status.error;
    if (this.status.state === "signedIn" && this.pushProblem) s.pushProblem = this.pushProblem;
    return s;
  }

  get signedIn() {
    return this.status.state === "signedIn";
  }

  async init() {
    try {
      const restored = await this.backend.restore();
      if (restored) {
        this.set({ state: "signedIn", account: restored.account });
        log("signed_in", { account: restored.account, restored: true });
        return;
      }
    } catch (e) {
      log("error", { where: "restore", error: errorText(e) });
    }
    this.set({ state: "signedOut" });
    log("sign_in_needed", { reason: "no_session" });
  }

  applyStep(step, email) {
    if (step.kind === "ok") {
      this.pending = null;
      this.set({ state: "signedIn", account: email });
      log("signed_in", { account: email });
    } else if (step.kind === "captcha") {
      this.set({
        state: "needsCaptcha",
        account: email,
        captcha: { id: randomBytes(8).toString("hex"), image: step.image },
        ...(step.retry ? { error: "That answer didn't match the picture. Try the new one." } : {}),
      });
      log("sign_in_needed", { reason: "captcha", account: email });
    } else if (step.kind === "code") {
      this.set({ state: "needsCode", account: email, codeSentTo: step.sentTo ?? email });
      log("sign_in_needed", { reason: "code", account: email });
    } else {
      throw new Error("unknown sign-in step");
    }
  }

  failSignIn(e, email) {
    const msg = errorText(e);
    log("error", { where: "sign_in", account: email, error: msg });
    this.pending = null;
    this.set({ state: "error", account: email, error: friendlySignInError(e) });
  }

  async run(fn) {
    if (this.busy) return; // a step is already in flight; the caller gets the current status
    this.busy = true;
    try {
      await fn();
    } finally {
      this.busy = false;
    }
  }

  async signIn({ email, password, country }) {
    if (typeof email !== "string" || !/^[^\s@]+@[^\s@]+$/.test(email.trim())) throw new HttpError(400, "Enter the email address of the Eufy account.");
    if (typeof password !== "string" || password.length === 0) throw new HttpError(400, "Enter the password of the Eufy account.");
    const cc = (typeof country === "string" && country ? country : "US").toUpperCase();
    if (!/^[A-Z]{2}$/.test(cc)) throw new HttpError(400, "country must be a two-letter code such as US.");
    email = email.trim();
    await this.run(async () => {
      this.stopAllStreams();
      // Fake mode's magic passwords are words that appear in log lines; masking them would garble the log.
      if (!this.backend.fakeMagic?.has(password)) addSecret(password);
      this.pending = { email, country: cc };
      const prevAccount = this.status.account;
      this.set({ state: "signingIn", account: email });
      try {
        if (prevAccount && prevAccount !== email) this.snapshots.clear();
        const step = await withTimeout(this.backend.begin({ email, password, country: cc }), OP_TIMEOUT_MS, "Signing in");
        this.applyStep(step, email);
      } catch (e) {
        this.failSignIn(e, email);
      } finally {
        removeSecret(password);
      }
    });
    return this.getStatus();
  }

  async captcha({ id, answer }) {
    if (this.status.state !== "needsCaptcha") throw new HttpError(409, "No picture check is waiting.");
    if (typeof answer !== "string" || !answer.trim()) throw new HttpError(400, "Type the characters from the picture.");
    if (id !== this.status.captcha?.id) throw new HttpError(409, "That picture has been replaced; answer the current one.");
    const email = this.status.account;
    await this.run(async () => {
      addSecret(answer);
      this.set({ state: "signingIn", account: email });
      try {
        const step = await withTimeout(this.backend.captcha(answer.trim()), OP_TIMEOUT_MS, "Checking the picture");
        this.applyStep(step, email);
      } catch (e) {
        this.failSignIn(e, email);
      } finally {
        removeSecret(answer);
      }
    });
    return this.getStatus();
  }

  async verify({ code }) {
    if (this.status.state !== "needsCode") throw new HttpError(409, "No verification code is waiting.");
    if (typeof code !== "string" || !/^\s*\d{4,8}\s*$/.test(code)) throw new HttpError(400, "Enter the code from the Eufy email.");
    const email = this.status.account;
    const sentTo = this.status.codeSentTo;
    await this.run(async () => {
      addSecret(code.trim());
      this.set({ state: "signingIn", account: email });
      try {
        const step = await withTimeout(this.backend.verify(code.trim()), OP_TIMEOUT_MS, "Checking the code");
        if (step.kind === "code") {
          this.set({ state: "needsCode", account: email, codeSentTo: step.sentTo ?? sentTo, error: "Eufy didn't accept that code." });
        } else this.applyStep(step, email);
      } catch (e) {
        if (isWrongCode(e)) {
          this.set({ state: "needsCode", account: email, codeSentTo: sentTo, error: "Eufy didn't accept that code. Check it and try again." });
          log("sign_in_needed", { reason: "code_rejected", account: email });
        } else this.failSignIn(e, email);
      } finally {
        removeSecret(code.trim());
      }
    });
    return this.getStatus();
  }

  async signOut() {
    await this.run(async () => {
      this.stopAllStreams();
      try {
        await withTimeout(this.backend.signOut(), 15_000, "Signing out");
      } catch (e) {
        log("error", { where: "sign_out", error: errorText(e) });
      }
      this.snapshots.clear();
      this.pending = null;
      this.pushProblem = undefined;
      this.pushOkLogged = false;
      this.set({ state: "signedOut" });
      log("sign_in_needed", { reason: "signed_out" });
    });
    return this.getStatus();
  }

  requireSignedIn() {
    if (!this.signedIn) throw new HttpError(409, "Sign in to Eufy first.");
  }

  async devices() {
    this.requireSignedIn();
    try {
      return await withTimeout(this.backend.devices(), 30_000, "Listing cameras");
    } catch (e) {
      if (e instanceof HttpError) throw e;
      log("error", { where: "devices", error: errorText(e) });
      throw new HttpError(502, `Couldn't get the camera list from Eufy: ${errorText(e)}`);
    }
  }

  hub(serial) {
    let h = this.hubs.get(serial);
    if (!h) {
      h = new StreamHub({
        serial,
        openSource: (s) => this.backend.openLive(s),
        onKeyframe: (au, codec) => this.snapshots.fromKeyframe(serial, au, codec),
        ...this.hubOptions,
      });
      h.on("idle", () => {
        if (h.clientCount === 0 && this.hubs.get(serial) === h) this.hubs.delete(serial);
      });
      this.hubs.set(serial, h);
    }
    return h;
  }

  async stream(serial, res) {
    if (!this.signedIn) throw new HttpError(503, "Sign in to Eufy first.");
    let known;
    try {
      known = await withTimeout(this.backend.hasCamera(serial), 20_000, "Looking up the camera");
    } catch (e) {
      throw new HttpError(503, `Couldn't reach Eufy: ${errorText(e)}`);
    }
    if (!known) throw new HttpError(404, "No camera with that serial on this account.");
    if (res.destroyed) return;
    this.hub(serial).addClient(res);
  }

  async snapshot(serial) {
    if (this.signedIn) {
      try {
        const jpeg = await withTimeout(this.backend.storedSnapshot(serial), 3_000, "snapshot");
        if (jpeg) this.snapshots.put(serial, jpeg, Date.now());
      } catch {
        /* passive; nothing retained */
      }
    }
    return this.snapshots.get(serial)?.jpeg ?? null;
  }

  stopAllStreams() {
    for (const h of this.hubs.values()) h.finish("signed_out", 503, "Signed out of Eufy.");
    this.hubs.clear();
  }

  cameraEvent({ serial, kind, at }) {
    const ev = { serial, kind, at: at ?? new Date().toISOString() };
    log("camera", ev);
    this.emit("camera", ev);
  }

  async close() {
    this.stopAllStreams();
    await this.backend.close().catch(() => {});
  }
}

function isWrongCode(e) {
  const m = String(e?.message ?? e).toLowerCase();
  return /verify[_ ]?code|verification code|code (is )?(wrong|invalid|incorrect|error|expired)|26052|26050/.test(m);
}

/** A sentence a person can act on, from an SDK/cloud failure. Never echoes credentials. */
export function friendlySignInError(e) {
  const raw = errorText(e);
  const m = raw.toLowerCase();
  if (/password|26006|26015|account or password|user ?name/.test(m)) return "Eufy didn't accept that email and password.";
  if (/too many|frequent|limit|26057|26058/.test(m)) return "Eufy is refusing sign-ins for now (too many attempts). Wait a while and try again.";
  if (/enotfound|eai_again|econnrefused|etimedout|network|fetch failed|took too long|socket/.test(m))
    return "Couldn't reach Eufy. Check the internet connection and try again.";
  return `Eufy sign-in failed: ${raw}`;
}
