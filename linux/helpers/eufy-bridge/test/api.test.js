import { test } from "node:test";
import assert from "node:assert/strict";
import { statSync } from "node:fs";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import http from "node:http";
import { startApp, request, openStream, sleep, waitFor, captureLog, MockBackend, TOKEN, findFfmpeg, tempDir } from "./helpers.js";
import { FAKE_SERIAL } from "../src/backend-fake.js";

test("auth: missing or wrong token is 401 everywhere; right token passes", async () => {
  const app = await startApp();
  try {
    for (const [m, p] of [["GET", "/status"], ["GET", "/devices"], ["GET", "/events"], ["POST", "/sign-in"], ["POST", "/captcha"], ["POST", "/verify"], ["POST", "/sign-out"], ["POST", "/fake/motion"]]) {
      assert.equal((await request(app.port, m, p, { token: null })).status, 401, `${m} ${p} without token`);
      assert.equal((await request(app.port, m, p, { token: "wrong-token-0000000000" })).status, 401, `${m} ${p} wrong token`);
    }
    assert.equal((await request(app.port, "GET", "/status", { token: null, headers: { authorization: "Basic abc" } })).status, 401);
    assert.equal((await request(app.port, "GET", `/stream/wrong-token-0000000000/${FAKE_SERIAL}`, { token: null })).status, 401);
    assert.equal((await request(app.port, "GET", `/snapshot/wrong-token-0000000000/${FAKE_SERIAL}`, { token: null })).status, 401);
    assert.equal((await request(app.port, "GET", `/stream//${FAKE_SERIAL}`, { token: null })).status, 404);
    const ok = await request(app.port, "GET", "/status");
    assert.equal(ok.status, 200);
    assert.match(ok.headers["content-type"], /application\/json/);
    assert.deepEqual(ok.json, { state: "signedOut" });
    assert.equal((await request(app.port, "GET", "/nope")).status, 404);
    assert.equal((await request(app.port, "GET", "/sign-in")).status, 405);
    assert.equal((await request(app.port, "POST", "/sign-in", { body: "{not json" })).status, 400);
    assert.equal((await request(app.port, "GET", "/devices")).status, 409, "devices before sign-in");
  } finally {
    await app.close();
    app.cleanup();
  }
});

test("fake sign-in: plain, captcha, code, wrong answers, sign-out, and restart keeps the session", async () => {
  const cap = captureLog();
  let now = new Date(2026, 9, 16, 9, 0).getTime(); // 09:00 local: on its battery
  const app = await startApp({ clock: () => now });
  try {
    let r = await request(app.port, "POST", "/sign-in", { body: { email: "owner@example.com", password: "captcha", country: "US" } });
    assert.equal(r.json.state, "needsCaptcha");
    assert.equal(r.json.account, "owner@example.com");
    assert.match(r.json.captcha.image, /^data:image\/png;base64,/);
    const id = r.json.captcha.id;
    assert.equal((await request(app.port, "POST", "/captcha", { body: { id: "stale", answer: "1234" } })).status, 409);
    r = await request(app.port, "POST", "/captcha", { body: { id, answer: "0000" } });
    assert.equal(r.json.state, "needsCaptcha");
    assert.ok(r.json.error);
    assert.notEqual(r.json.captcha.id, id, "a new picture gets a new id");
    r = await request(app.port, "POST", "/captcha", { body: { id: r.json.captcha.id, answer: "1234" } });
    assert.deepEqual(r.json, { state: "signedIn", account: "owner@example.com" });

    r = await request(app.port, "POST", "/sign-out");
    assert.deepEqual(r.json, { state: "signedOut" });

    r = await request(app.port, "POST", "/sign-in", { body: { email: "owner@example.com", password: "code" } });
    assert.equal(r.json.state, "needsCode");
    assert.equal(r.json.codeSentTo, "owner@example.com");
    assert.equal((await request(app.port, "POST", "/verify", { body: { code: "12" } })).status, 400);
    r = await request(app.port, "POST", "/verify", { body: { code: "999999" } });
    assert.equal(r.json.state, "needsCode");
    assert.ok(r.json.error);
    r = await request(app.port, "POST", "/verify", { body: { code: "123456" } });
    assert.equal(r.json.state, "signedIn");

    let d = await request(app.port, "GET", "/devices");
    assert.deepEqual(d.json, {
      devices: [{ serial: "T8134FAKE0000001", name: "Fake SoloCam", model: "T8134", type: 63, online: true, battery: 87, charging: false, chargingSource: null, livestream: true, codec: "h264" }],
    });
    now = new Date(2026, 9, 16, 12, 30).getTime(); // midday: charging from its solar panel
    d = await request(app.port, "GET", "/devices");
    assert.equal(d.json.devices[0].charging, true);
    assert.equal(d.json.devices[0].chargingSource, "solar");

    const sess = join(app.dir, "state", "session.json");
    assert.equal(statSync(sess).mode & 0o777, 0o600);
    assert.equal(statSync(join(app.dir, "state")).mode & 0o777, 0o700);

    // The state log follows /status.
    const states = cap.lines.filter((l) => l.startsWith("cb-eufy event=state ")).map((l) => l.split("state=")[1]);
    assert.deepEqual(states, ["signedOut", "signingIn", "needsCaptcha", "signingIn", "needsCaptcha", "signingIn", "signedIn", "signedOut", "signingIn", "needsCode", "signingIn", "needsCode", "signingIn", "signedIn"]);
    assert.ok(!cap.lines.some((l) => /1234|123456|999999/.test(l)), "no codes or answers in the log");
  } finally {
    await app.close();
    cap.restore();
  }
  // Restart on the same state dir: signed in without a new sign-in.
  const app2 = await startApp({ dir: app.dir });
  try {
    const r = await request(app2.port, "GET", "/status");
    assert.equal(r.json.state, "signedIn");
    assert.equal(r.json.account, "owner@example.com");
    await request(app2.port, "POST", "/sign-out");
  } finally {
    await app2.close();
  }
  const app3 = await startApp({ dir: app.dir });
  try {
    assert.equal((await request(app3.port, "GET", "/status")).json.state, "signedOut", "sign-out forgot the session");
  } finally {
    await app3.close();
    app.cleanup();
  }
});

test("events: hello first, a motion line on POST /fake/motion, pings, and a stderr line per event", async () => {
  const cap = captureLog();
  const app = await startApp({ pingMs: 300 });
  try {
    await request(app.port, "POST", "/sign-in", { body: { email: "a@example.com", password: "pw" } });
    const lines = [];
    const req = http.get({ host: "127.0.0.1", port: app.port, path: "/events", headers: { authorization: `Bearer ${TOKEN}` } }, (res) => {
      assert.equal(res.statusCode, 200);
      assert.match(res.headers["content-type"], /application\/x-ndjson/);
      let buf = "";
      res.on("data", (d) => {
        buf += d;
        let i;
        while ((i = buf.indexOf("\n")) >= 0) {
          lines.push(JSON.parse(buf.slice(0, i)));
          buf = buf.slice(i + 1);
        }
      });
    });
    await waitFor(() => lines.length >= 1);
    assert.equal(lines[0].kind, "hello");
    assert.equal((await request(app.port, "POST", "/fake/motion")).status, 200);
    const motion = await waitFor(() => lines.find((l) => l.kind === "motion"));
    assert.equal(motion.serial, FAKE_SERIAL);
    assert.ok(!Number.isNaN(Date.parse(motion.at)) && motion.at.endsWith("Z"));
    assert.deepEqual(Object.keys(motion).sort(), ["at", "kind", "serial"]);
    await waitFor(() => lines.find((l) => l.kind === "ping"), 3000);
    req.destroy();
    const line = cap.lines.find((l) => l.startsWith("cb-eufy event=camera "));
    assert.match(line, /^cb-eufy event=camera serial=T8134FAKE0000001 kind=motion at=\d{4}-\d\d-\d\dT[\d:.]+Z$/);
  } finally {
    await app.close();
    cap.restore();
    app.cleanup();
  }
});

test("stream: clients share one livestream; the last one leaving stops it within 5 s", async () => {
  const backend = new MockBackend();
  const cap = captureLog();
  const app = await startApp({ backend });
  try {
    const path = `/stream/${TOKEN}/T8134MOCK0000001`;
    const a = await openStream(app.port, path);
    assert.equal(a.res.statusCode, 200);
    assert.equal(a.res.headers["content-type"], "video/mp2t");
    const b = await openStream(app.port, path);
    await waitFor(() => a.bytes().length > 20_000 && b.bytes().length > 5_000);
    assert.equal(backend.opens, 1, "one livestream for two clients");
    assert.equal(a.bytes()[0], 0x47);
    assert.equal(b.bytes()[0], 0x47, "late joiner starts on a TS packet");
    // the late joiner starts with PAT
    assert.equal(((b.bytes()[1] & 0x1f) << 8) | b.bytes()[2], 0);
    a.req.destroy();
    await sleep(500);
    assert.equal(backend.stops.length, 0, "still one reader");
    const t0 = Date.now();
    b.req.destroy();
    await waitFor(() => backend.stops.length === 1, 5000);
    assert.ok(Date.now() - t0 < 5000);
    assert.ok(cap.lines.some((l) => /event=stream_end serial=T8134MOCK0000001 reason=no_clients/.test(l)));
    // a new reader opens a new livestream
    const c = await openStream(app.port, path);
    await waitFor(() => c.bytes().length > 1000);
    assert.equal(backend.opens, 2);
    c.req.destroy();
    await waitFor(() => backend.stops.length === 2);
    assert.equal((await request(app.port, "GET", `/stream/${TOKEN}/UNKNOWN0000`, { token: null })).status, 404);
  } finally {
    await app.close();
    cap.restore();
    app.cleanup();
  }
});

test("stream: no video within the deadline is HTTP 503 and the camera is released", async () => {
  const backend = new MockBackend({ sendVideo: false });
  const app = await startApp({ backend, hubOptions: { firstVideoTimeoutMs: 600 } });
  try {
    const t0 = Date.now();
    const r = await request(app.port, "GET", `/stream/${TOKEN}/T8134MOCK0000001`, { token: null });
    assert.equal(r.status, 503);
    assert.ok(r.json.error);
    assert.ok(Date.now() - t0 >= 550);
    await waitFor(() => backend.stops.length === 1);
  } finally {
    await app.close();
    app.cleanup();
  }
});

test("stream: video without audio still starts (audio track omitted)", async () => {
  const backend = new MockBackend({ sendAudio: false });
  const app = await startApp({ backend });
  try {
    const a = await openStream(app.port, `/stream/${TOKEN}/T8134MOCK0000001`);
    await waitFor(() => a.bytes().length > 5000, 4000);
    a.req.destroy();
  } finally {
    await app.close();
    app.cleanup();
  }
});

const ffmpeg = findFfmpeg();
const ffprobe = ffmpeg ? ffmpeg.replace(/ffmpeg$/, "ffprobe") : undefined;

test("fake mode stream: ffmpeg-generated H.264 + AAC in MPEG-TS that ffprobe reads; snapshot is a JPEG", { skip: !ffmpeg && "no ffmpeg" }, async () => {
  const app = await startApp();
  try {
    await request(app.port, "POST", "/sign-in", { body: { email: "a@example.com", password: "pw" } });
    await waitFor(async () => (await request(app.port, "GET", `/snapshot/${TOKEN}/${FAKE_SERIAL}`, { token: null })).status === 200, 5000);
    const snap = await request(app.port, "GET", `/snapshot/${TOKEN}/${FAKE_SERIAL}`, { token: null });
    assert.equal(snap.headers["content-type"], "image/jpeg");
    assert.equal(snap.buf[0], 0xff);
    assert.equal(snap.buf[1], 0xd8);
    const s = await openStream(app.port, `/stream/${TOKEN}/${FAKE_SERIAL}`);
    await sleep(5000);
    s.req.destroy();
    const file = join(tempDir(), "fake.ts");
    writeFileSync(file, s.bytes());
    const p = spawnSync(ffprobe, ["-v", "error", "-show_entries", "stream=codec_name,width,height,sample_rate", "-of", "json", file], { encoding: "utf8" });
    const streams = JSON.parse(p.stdout).streams;
    assert.deepEqual(streams.map((x) => x.codec_name).sort(), ["aac", "h264"]);
    const v = streams.find((x) => x.codec_name === "h264");
    assert.equal(v.width, 1280);
    assert.equal(v.height, 720);
    const dec = spawnSync(ffmpeg, ["-v", "error", "-i", file, "-f", "null", "-"], { encoding: "utf8" });
    assert.equal(dec.status, 0);
    // ffmpeg's null output re-times frames on its frame-rate guess and warns about equal DTS there;
    // that is ffmpeg's re-encode, not the stream. Anything else is a real decode problem.
    const problems = dec.stderr.split("\n").filter((l) => l.trim() && !/non monotonically increasing dts|Last message repeated/.test(l));
    assert.deepEqual(problems, []);
    const remux = spawnSync(ffmpeg, ["-v", "error", "-i", file, "-c", "copy", "-f", "mp4", "-y", file + ".mp4"], { encoding: "utf8" });
    assert.equal(remux.status, 0);
    assert.equal(remux.stderr.trim(), "", "clean -c copy remux");
  } finally {
    await app.close();
    app.cleanup();
  }
});
