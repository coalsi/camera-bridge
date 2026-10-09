// Tests for goldens.mjs: brief §3 goldens are reproduced by HAP-NodeJS / fast-srp-hap, generation is
// deterministic, and the committed fixtures under Packages/CameraBridgeKit/Tests are up to date.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { sections, render, defaultTestsDirectory } from "../lib/goldens/index.mjs";
import { hn } from "../lib/hap-nodejs.mjs";
import { hdsTags, encodeCanonical, fromJSONValue } from "../lib/goldens/hds-values.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const script = path.join(here, "..", "goldens.mjs");

const generated = Object.fromEntries(Object.entries(sections).map(([name, section]) => [name, section.generate()]));

test("every section has a fixture path under Tests/<Module>Tests/Fixtures", () => {
    assert.deepEqual(Object.keys(sections).sort(), ["camera", "hds-codec", "hds-frames", "setup-payload", "srp", "tlv8"]);
    for (const [name, section] of Object.entries(sections)) {
        assert.match(section.file, /^[A-Za-z]+Tests\/Fixtures\/[a-z0-9-]+\.json$/, name);
    }
});

test("generation is deterministic", () => {
    for (const [name, section] of Object.entries(sections)) {
        assert.equal(render(section.generate()), render(generated[name]), name);
    }
});

test("every fixture names its generator and source", () => {
    for (const [name, value] of Object.entries(generated)) {
        const text = JSON.stringify(value);
        assert.match(text, /goldens\.mjs/, `${name} must say how it was generated`);
    }
});

test("brief §3.3 setup URI and setup hash goldens", () => {
    const setup = generated["setup-payload"];
    const uri = (code, setupID, category) =>
        setup.uris.find(u => u.code === code && u.setupID === setupID && u.category === category)?.uri;
    assert.equal(uri("031-45-154", "7OSX", 17), "X-HM://00GW95DQA7OSX");
    assert.equal(uri("031-45-154", "7OSX", 18), "X-HM://00HVRPEPU7OSX");
    const sh = setup.setupHashes.find(h => h.setupID === "7OSX" && h.deviceID === "CC:22:3D:E3:CE:F3");
    assert.equal(sh?.hash, "7JWHTA==");
    assert.ok(setup.uris.length >= 10);
    assert.ok(setup.uris.every(u => /^X-HM:\/\/[0-9A-Z]{9}[0-9A-Z]{4}$/.test(u.uri)));
});

test("brief §3.2 TLV8 300-byte fragmentation golden", () => {
    const tlv8 = generated.tlv8;
    const split = tlv8.encode.find(c => c.items.length === 1 && c.items[0].type === 5 && c.items[0].value.length === 600);
    assert.ok(split, "a 300-byte type-5 case exists");
    assert.equal(split.encoded.slice(0, 4), "05ff");
    assert.equal(split.encoded.slice(257 * 2, 259 * 2), "052d");
    // every encode case round-trips through the decode section
    for (const c of tlv8.encode) {
        const d = tlv8.decode.find(x => x.encoded === c.encoded);
        assert.ok(d, `decode case for ${c.name}`);
    }
    assert.ok(tlv8.invalid.some(c => c.error === "truncated"));
    assert.ok(tlv8.invalid.some(c => c.error === "invalidLength"));
    assert.ok(tlv8.lists.some(c => c.separator === 0xff));
    assert.ok(tlv8.lists.some(c => c.separator === 0x00));
});

test("brief §3.8 HDS header goldens", () => {
    const frames = generated["hds-frames"];
    const header = name => frames.messages.find(m => m.name === name)?.header;
    assert.equal(header("dataSend data event (initialization chunk)").slice(0),
        "e24870726f746f636f6c486461746153656e64456576656e744464617461");
    assert.equal(header("control hello response"),
        "e44870726f746f636f6c47636f6e74726f6c48726573706f6e73654568656c6c6f42696433d20400000000000046737461747573330000000000000000");
    for (const m of frames.messages) {
        const headerLength = parseInt(m.payload.slice(0, 2), 16);
        assert.equal(m.payload.slice(2, 2 + headerLength * 2), m.header, m.name);
    }
    assert.ok(frames.keys.length >= 2);
    assert.ok(frames.frames.length >= 3);
});

test("HDS codec cases cover every tag class the encoder emits", () => {
    const codec = generated["hds-codec"];
    const firstTags = new Set(codec.values.map(c => parseInt(c.encoded.slice(0, 2), 16)));
    const expectTag = (tag, why) => assert.ok(firstTags.has(tag), `${why} (0x${tag.toString(16)})`);
    expectTag(0x01, "true"); expectTag(0x02, "false"); expectTag(0x04, "null"); expectTag(0x05, "uuid");
    expectTag(0x06, "date"); expectTag(0x07, "-1"); expectTag(0x08, "0"); expectTag(0x2f, "39");
    expectTag(0x30, "int8"); expectTag(0x31, "int16"); expectTag(0x32, "int32"); expectTag(0x33, "int64");
    expectTag(0x36, "float64"); expectTag(0x40, "empty string"); expectTag(0x60, "32-byte string");
    expectTag(0x61, "string length8"); expectTag(0x62, "string length16"); expectTag(0x70, "empty data");
    expectTag(0x90, "32-byte data"); expectTag(0x91, "data length8"); expectTag(0x92, "data length16");
    expectTag(0xd0, "empty array"); expectTag(0xde, "14-element array"); expectTag(0xdf, "terminated array");
    expectTag(0xe0, "empty dictionary"); expectTag(0xee, "14-entry dictionary"); expectTag(0xef, "terminated dictionary");
    // the canonical encoder never emits back-reference ("compression") tags
    for (const c of codec.values) {
        const tags = hdsTags(Buffer.from(c.encoded, "hex"));
        assert.ok(tags.every(t => t < 0xa0 || t > 0xcf), c.name);
    }
    const decodeTags = new Set(codec.decodeOnly.flatMap(c => hdsTags(Buffer.from(c.encoded, "hex"))));
    for (const tag of [0x30, 0x33, 0x35, 0x61, 0x62, 0x63, 0x64, 0x6f, 0x91, 0x93, 0x94, 0x9f, 0xa0, 0xa1, 0xdf, 0xef]) {
        assert.ok(decodeTags.has(tag), `a decode-only case uses tag 0x${tag.toString(16)}`);
    }
    for (const c of codec.decodeOnly) {
        assert.notEqual(c.encoded, encodeCanonical(fromJSONValue(c.value)).toString("hex"), `${c.name} is not the canonical form`);
    }
    assert.ok(codec.invalid.length >= 3);
});

test("HDS canonical encodings are read back by HAP-NodeJS's parser unless a documented HN bug applies", () => {
    for (const c of generated["hds-codec"].values) {
        if (c.hapNodeJS.readerRoundTrip === false) {
            assert.match(c.note ?? "", /HAP-NodeJS/, `${c.name} must document why HN cannot read it`);
        }
        if (c.hapNodeJS.writer !== c.encoded) {
            assert.match(c.note ?? "", /HAP-NodeJS/, `${c.name} must document why HN writes something else`);
        }
    }
    // the ordinary cases (small ints, strings, dicts, …) must agree with HN byte for byte
    const agreeing = generated["hds-codec"].values.filter(c => c.hapNodeJS.writer === c.encoded && c.hapNodeJS.readerRoundTrip);
    assert.ok(agreeing.length >= 30, `only ${agreeing.length} cases agree with HAP-NodeJS`);
});

test("brief §3.5/§3.7 camera TLV goldens are reproduced by HAP-NodeJS controllers", () => {
    const camera = generated.camera;
    const briefStreaming = camera.streaming.find(c => c.name.startsWith("brief"));
    assert.equal(briefStreaming.supportedVideoStreamConfiguration,
        "013e010100021d0101000000010101000001010202010000000201010000020102030100030b010280070202380403011e0000030b010200050202d00203011e");
    assert.equal(briefStreaming.supportedRTPConfiguration, "020100");
    const briefRecording = camera.recording.find(c => c.name.startsWith("brief"));
    assert.equal(briefRecording.supportedCameraRecordingConfiguration, "0104a00f000002080100000000000000030b01010002060104a00f0000");
    assert.equal(briefRecording.supportedVideoRecordingConfiguration, "01180101000206010102020102030b010280070202380403011e");
    assert.equal(camera.dataStreamTransport.supportedDataStreamTransportConfiguration, "0103010100");
    assert.equal(camera.setupEndpointsDefault, "020102");
    const v1Camera = camera.recording.find(c => c.name === "v1 camera");
    const v1Doorbell = camera.recording.find(c => c.name === "v1 doorbell");
    assert.equal(v1Camera.options.eventTriggers, 1);
    assert.equal(v1Doorbell.options.eventTriggers, 3);
    assert.ok(v1Camera.supportedCameraRecordingConfiguration.startsWith("0104a00f0000020801000000"));
    assert.ok(v1Doorbell.supportedCameraRecordingConfiguration.startsWith("0104a00f0000020803000000"));
    assert.ok(camera.streaming.some(c => c.name === "v1 default"));
    assert.ok(camera.selectedRecordingConfiguration.length >= 1);
});

test("camera streaming goldens decode (HAP-NodeJS decodeWithLists) to the options they claim", () => {
    const { tlv } = hn();
    for (const c of generated.camera.streaming) {
        const top = tlv.decodeWithLists(Buffer.from(c.supportedVideoStreamConfiguration, "hex"));
        const codecConfig = tlv.decodeWithLists(top[1]);
        const attrs = [codecConfig[3]].flat();
        const resolutions = attrs.map(a => {
            const d = tlv.decodeWithLists(a);
            return [d[1].readUInt16LE(0), d[2].readUInt16LE(0), d[3].readUInt8(0)];
        });
        assert.deepEqual(resolutions, c.options.resolutions, c.name);
        const params = tlv.decodeWithLists(codecConfig[2]);
        assert.deepEqual([params[1]].flat().map(b => b[0]), c.options.profiles, c.name);
        assert.deepEqual([params[2]].flat().map(b => b[0]), c.options.levels, c.name);
    }
});

test("camera option cases are buildable from the HAPCamera contract types unless marked decodeOnly", () => {
    const camera = generated.camera;
    // CameraStreamingOptions has audioCodecs [(codec, sampleRates)] and no comfort-noise field: only channels 1,
    // bitrate mode 0 (variable) and comfort noise off are reachable through it.
    const reachable = c => !c.options.comfortNoise && c.options.audioCodecs.every(a => a.channels === 1 && a.bitrateMode === 0);
    for (const c of camera.streaming) {
        assert.equal(c.decodeOnly === true, !reachable(c), `${c.name}: decodeOnly must be set exactly when the contract cannot build the options`);
        if (c.decodeOnly !== undefined) assert.equal(c.decodeOnly, true, `${c.name}: decodeOnly is only ever true`);
    }
    assert.ok(camera.streaming.filter(c => c.decodeOnly).every(c => c.options.comfortNoise), "only the comfort-noise case is decode-only");
    assert.ok(camera.streaming.filter(c => !c.decodeOnly).length >= 5, "the encoder targets outnumber the parser-only case");
    // CameraRecordingOptions has no bitrate mode; isDoorbell is CameraControllerConfiguration.isDoorbell
    for (const c of camera.recording) {
        assert.equal(c.options.audioBitrateMode, 0, c.name);
        assert.equal(c.decodeOnly, undefined, c.name);
        assert.equal(c.options.eventTriggers, c.options.isDoorbell ? 3 : 1, c.name);
    }
    const notes = camera.notes.join("\n");
    assert.match(notes, /decodeOnly/);
    assert.match(notes, /CameraControllerConfiguration\.isDoorbell/);
});

test("SRP vectors are identical to the committed srp.json and verify with fast-srp-hap", () => {
    const committed = fs.readFileSync(path.join(defaultTestsDirectory, sections.srp.file), "utf8");
    assert.equal(render(generated.srp), committed);
    assert.equal(generated.srp.vectors.length, 2);
});

test("goldens.mjs --check passes on the committed fixtures", () => {
    const result = spawnSync(process.execPath, [script, "--check"], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stdout + result.stderr);
});

test("goldens.mjs --check reports drift and a missing fixture", () => {
    const out = fs.mkdtempSync(path.join(os.tmpdir(), "cb-goldens-"));
    try {
        const write = spawnSync(process.execPath, [script, "tlv8", "srp", "--out", out], { encoding: "utf8" });
        assert.equal(write.status, 0, write.stdout + write.stderr);
        assert.ok(fs.existsSync(path.join(out, sections.tlv8.file)));
        const check = spawnSync(process.execPath, [script, "tlv8", "srp", "--check", "--out", out], { encoding: "utf8" });
        assert.equal(check.status, 0, check.stdout + check.stderr);
        fs.appendFileSync(path.join(out, sections.tlv8.file), " ");
        const drift = spawnSync(process.execPath, [script, "tlv8", "--check", "--out", out], { encoding: "utf8" });
        assert.equal(drift.status, 1);
        assert.match(drift.stdout + drift.stderr, /tlv8\.json/);
        const missing = spawnSync(process.execPath, [script, "camera", "--check", "--out", out], { encoding: "utf8" });
        assert.equal(missing.status, 1);
        const bad = spawnSync(process.execPath, [script, "nonsense"], { encoding: "utf8" });
        assert.equal(bad.status, 2);
    } finally {
        fs.rmSync(out, { recursive: true, force: true });
    }
});
