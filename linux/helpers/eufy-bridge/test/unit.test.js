import { test } from "node:test";
import assert from "node:assert/strict";
import { readConfig, ConfigError } from "../src/config.js";
import { scrub, addSecret, removeSecret, formatLine } from "../src/log.js";
import { TsMuxer, crc32mpeg, splitAdts, splitNals, ParamSetCache } from "../src/tsmux.js";
import { fakeAu, adtsFrame } from "./helpers.js";

test("config: loopback only, token and state dir required", () => {
  const base = { CB_EUFY_LISTEN: "127.0.0.1:8123", CB_EUFY_TOKEN: "0123456789abcdefXYZ", CB_EUFY_STATE_DIR: "/tmp/x" };
  assert.equal(readConfig(base).port, 8123);
  assert.equal(readConfig(base).fake, false);
  assert.equal(readConfig({ ...base, CB_EUFY_FAKE: "1" }).fake, true);
  for (const listen of ["0.0.0.0:8123", "192.0.2.2:80", "localhost:80", "127.0.0.1", "127.0.0.1:0", "127.0.0.1:70000", "[::1]:80", ""]) {
    assert.throws(() => readConfig({ ...base, CB_EUFY_LISTEN: listen }), ConfigError, listen);
  }
  assert.throws(() => readConfig({ ...base, CB_EUFY_TOKEN: "short" }), ConfigError);
  assert.throws(() => readConfig({ ...base, CB_EUFY_TOKEN: "has/slash/0123456789" }), ConfigError);
  assert.throws(() => readConfig({ ...base, CB_EUFY_STATE_DIR: "relative/dir" }), ConfigError);
  assert.throws(() => readConfig({ ...base, CB_EUFY_FFMPEG: "/nonexistent/ffmpeg" }), ConfigError);
  assert.throws(() => readConfig({ ...base, CB_EUFY_FAKE: "yes" }), ConfigError);
});

test("log: registered secrets and credential-shaped text are scrubbed", () => {
  addSecret("hunter2-password");
  addSecret("482913");
  try {
    const s = scrub("login failed for hunter2-password with code 482913");
    assert.ok(!s.includes("hunter2-password"));
    assert.ok(!s.includes("482913"));
  } finally {
    removeSecret("hunter2-password");
    removeSecret("482913");
  }
  const cases = [
    ['{"auth_token":"abcDEF123456"}', "abcDEF123456"],
    ["x-auth-token: tok_abcdef0987", "tok_abcdef0987"],
    ["Authorization: Bearer abc.def.ghi", "abc.def.ghi"],
    ["password=s3cr3t!", "s3cr3t!"],
    ["share_key=00112233445566778899aabbccddeeff", "00112233445566778899aabbccddeeff"],
    ["key 00112233445566778899aabbccddeeff00112233", "00112233445566778899aabbccddeeff00112233"],
    ["https://cdn.example.com/a.jpg?X-Amz-Signature=abc123&Expires=1", "X-Amz-Signature"],
    ["blob QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZnaGlqa2xtbm9w end", "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZnaGlqa2xtbm9w"],
    ['"ecc_private_key":"MHcCAQEEIBx"', "MHcCAQEEIBx"],
    ['{"answer":"7KQ2"}', "7KQ2"],
  ];
  for (const [input, secret] of cases) assert.ok(!scrub(input).includes(secret), `${input} -> ${scrub(input)}`);
  // Ordinary text survives.
  assert.equal(scrub("The camera T8134FAKE0000001 stopped."), "The camera T8134FAKE0000001 stopped.");
});

test("log: status line format quotes values with spaces and never leaks the token", () => {
  addSecret("tok-AAAAAAAAAAAAAAAA");
  try {
    assert.equal(formatLine("stream_start", { serial: "T1", clients: 2 }), "cb-eufy event=stream_start serial=T1 clients=2");
    assert.equal(formatLine("error", { error: 'bad "thing" happened' }), 'cb-eufy event=error error="bad \\"thing\\" happened"');
    assert.ok(!formatLine("error", { error: "url /stream/tok-AAAAAAAAAAAAAAAA/T1" }).includes("tok-AAAA"));
    assert.ok(!formatLine("x", { a: "line1\nline2" }).includes("\n"));
  } finally {
    removeSecret("tok-AAAAAAAAAAAAAAAA");
  }
});

function parseTs(buf) {
  assert.equal(buf.length % 188, 0, "TS is a whole number of packets");
  const pids = new Map();
  for (let i = 0; i < buf.length; i += 188) {
    assert.equal(buf[i], 0x47, `sync byte at ${i}`);
    const pid = ((buf[i + 1] & 0x1f) << 8) | buf[i + 2];
    pids.set(pid, (pids.get(pid) ?? 0) + 1);
  }
  return pids;
}

test("tsmux: PAT/PMT with valid CRCs, video and audio PIDs, keyframes start with PSI", () => {
  const params = new ParamSetCache();
  const mux = new TsMuxer({ video: "h264", audio: "aac" });
  const key = mux.video(params.prepare("h264", fakeAu(true), true), true, 0);
  const pids = parseTs(key);
  assert.ok(pids.has(0) && pids.has(0x1000) && pids.has(0x100));
  // PAT section CRC
  const pat = key.subarray(5, 5 + 3 + ((key[6] & 0x0f) << 8 | key[7]));
  assert.equal(crc32mpeg(pat), 0, "CRC over section incl. CRC is 0");
  const pmtPkt = key.subarray(188);
  const pmt = pmtPkt.subarray(5, 5 + 3 + ((pmtPkt[6] & 0x0f) << 8 | pmtPkt[7]));
  assert.equal(crc32mpeg(pmt), 0);
  assert.ok(pmt.includes(0x1b) && pmt.includes(0x0f), "PMT lists H.264 and AAC");
  const delta = mux.video(params.prepare("h264", fakeAu(false), false), false, 66);
  assert.ok(!parseTs(delta).has(0), "delta frames carry no PAT");
  const a = mux.audio(adtsFrame(), 70);
  assert.deepEqual([...parseTs(a).keys()], [0x101]);
  // big access unit (> 64 KiB) uses unbounded PES length and still packetizes
  const big = Buffer.concat([Buffer.from([0, 0, 0, 1, 0x65]), Buffer.alloc(100_000, 7)]);
  parseTs(mux.video(params.prepare("h264", big, true), true, 133));
});

test("tsmux: keyframes are completed with cached SPS/PPS; timestamps increase", () => {
  const params = new ParamSetCache();
  params.prepare("h264", fakeAu(true), true);
  const bare = Buffer.concat([Buffer.from([0, 0, 0, 1, 0x65, 0x88]), Buffer.alloc(50)]);
  const out = params.prepare("h264", bare, true);
  const types = splitNals(out).map((n) => n[0] & 0x1f);
  assert.deepEqual(types, [9, 7, 8, 5]);
  const mux = new TsMuxer({ video: "h264" });
  const ptsOf = (b) => {
    const p = b.indexOf(Buffer.from([0, 0, 1, 0xe0]));
    const x = b.subarray(p + 9, p + 14);
    return ((x[0] >> 1) & 7) * 2 ** 30 + ((x[1] << 7) | (x[2] >> 1)) * 2 ** 15 + ((x[3] << 7) | (x[4] >> 1));
  };
  const p1 = ptsOf(mux.video(out, true, 0));
  const p2 = ptsOf(mux.video(out, true, 0)); // same arrival time (a burst)
  const p3 = ptsOf(mux.video(out, true, 66));
  assert.ok(p2 > p1 && p3 > p2);
});

test("tsmux: ADTS splitting keeps partial frames for the next chunk", () => {
  const f = adtsFrame();
  const buf = Buffer.concat([f, f, f.subarray(0, 9)]);
  const { frames, rest } = splitAdts(buf);
  assert.equal(frames.length, 2);
  assert.equal(rest.length, 9);
});
