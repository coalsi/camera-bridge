// End-to-end proof that pair-oracle.mjs works: it pairs with the HAP-NodeJS reference accessory
// (reference-accessory.mjs), which must stay on loopback (127.0.0.1 TCP only, no UDP / mDNS). The fault cases
// start their own reference accessory with --fault so the oracle has to catch a misbehaving accessory.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import net from "node:net";

import { SETUP_CODE as setupCode, accessoryScript, runOracle, startReferenceAccessory, waitForEvent } from "./support.mjs";

let accessory;
let ready;

before(async () => {
    accessory = await startReferenceAccessory(["--motion-interval-ms", "400"]);
    ready = accessory.ready;
});

after(() => accessory?.stop());

const stepNames = summary => summary?.steps?.map(step => step.name);
const FULL_RUN = ["pairSetup", "pairVerify", "listPairings", "getAccessories", "readCharacteristics", "subscribeMotion", "events",
    "unsubscribeMotion", "removePairing", "verifyRemoved"];

/** Starts a reference accessory with extra arguments for one test and stops it afterwards. */
async function withAccessory(extraArgs, body) {
    const faulty = await startReferenceAccessory(extraArgs);
    try { return await body(faulty); } finally { faulty.stop(); }
}

test("reference accessory reports a loopback endpoint and a camera setup URI", () => {
    assert.equal(ready.host, "127.0.0.1");
    assert.ok(ready.port > 0);
    assert.equal(ready.category, 17);
    assert.match(ready.setupURI, /^X-HM:\/\/[0-9A-Z]{13}$/);
    assert.match(ready.deviceId, /^([0-9A-F]{2}:){5}[0-9A-F]{2}$/);
    assert.deepEqual(ready.faults, [], "the shared accessory runs without injected faults");
});

test("reference accessory listens on 127.0.0.1 only and opens no UDP sockets", { skip: !fs.existsSync("/usr/sbin/lsof") }, () => {
    const result = spawnSync("/usr/sbin/lsof", ["-nP", "-a", "-p", String(accessory.child.pid), "-i"], { encoding: "utf8" });
    const lines = result.stdout.split("\n").slice(1).filter(Boolean);
    const listeners = lines.filter(l => /\(LISTEN\)/.test(l));
    assert.ok(listeners.length >= 1, result.stdout);
    for (const line of listeners) assert.match(line, /TCP 127\.0\.0\.1:\d+ \(LISTEN\)/, line);
    assert.deepEqual(lines.filter(l => /\bUDP\b/.test(l)), [], "no UDP sockets (no mDNS)");
});

test("reference accessory rejects a bad --fault", () => {
    for (const fault of ["subscribe=0", "subscribe=-1", "subscribe=-70413", "resubscribe", ""]) {
        const result = spawnSync(process.execPath, [accessoryScript, "--port", "0", "--fault", fault, "--lifetime-s", "1"],
            { encoding: "utf8", timeout: 10_000 });
        assert.equal(result.status, 2, `--fault ${fault}: ${result.stderr}`);
    }
});

test("pair-oracle rejects bad usage with exit 2", async () => {
    assert.equal((await runOracle([])).status, 2);
    assert.equal((await runOracle(["127.0.0.1", "notaport", setupCode])).status, 2);
    assert.equal((await runOracle(["127.0.0.1", "1234", "12-34"])).status, 2);
});

test("pair-oracle exits 1 when nothing listens", async () => {
    const server = net.createServer();
    await new Promise(r => server.listen(0, "127.0.0.1", r));
    const { port } = server.address();
    await new Promise(r => server.close(r));
    const result = await runOracle(["127.0.0.1", String(port), setupCode, "--seconds", "1", "--timeout-ms", "3000"]);
    assert.equal(result.status, 1, result.stdout + result.stderr);
    assert.equal(result.summary?.ok, false);
    assert.equal(result.summary?.failedStep, "pairSetup");
    assert.deepEqual(result.summary?.cleanup, { needed: false }, "no pairing was created, so nothing to clean up");
});

test("pair-oracle exits 1 with a wrong setup code", async () => {
    const result = await runOracle([ready.host, String(ready.port), "111-22-333", "--seconds", "1"]);
    assert.equal(result.status, 1, result.stdout + result.stderr);
    assert.equal(result.summary?.ok, false);
    assert.equal(result.summary?.failedStep, "pairSetup");
    assert.ok(!result.stdout.includes("111-22-333"), "the setup code is not echoed");
});

test("pair-oracle pairs, verifies, reads, receives MotionDetected events and removes the pairing", async () => {
    const result = await runOracle([ready.host, String(ready.port), setupCode, "--seconds", "3", "--min-events", "2"]);
    assert.equal(result.status, 0, result.stdout + result.stderr);
    const s = result.summary;
    assert.equal(s.ok, true);
    assert.deepEqual(stepNames(s), FULL_RUN);
    assert.ok(s.steps.every(step => step.ok), JSON.stringify(s.steps));
    assert.equal(s.accessory.deviceId, ready.deviceId);
    assert.ok(s.accessories.count >= 1);
    assert.ok(s.accessories.services >= 8, "camera + recording + motion services");
    assert.ok(s.reads.readable >= 20);
    assert.equal(s.reads.failed, 0, JSON.stringify(s.reads));
    assert.ok(s.reads.expectedErrors.some(e => e.type === "209" && e.status === -70402),
        "SelectedCameraRecordingConfiguration read before selection → -70402");
    assert.ok(s.motion.characteristics.length >= 1);
    const subscribe = s.steps.find(step => step.name === "subscribeMotion");
    assert.ok([204, 207].includes(subscribe.status), JSON.stringify(subscribe));
    assert.ok(s.events.length >= 2, JSON.stringify(s.events));
    assert.ok(s.events.every(e => typeof e.value === "boolean" || e.value === 0 || e.value === 1));
    assert.equal(s.pairings.admins, 1);
    assert.match(s.steps.find(step => step.name === "verifyRemoved").rejected, /^M[24]: Error: 2$/);
    assert.deepEqual(s.cleanup, { needed: false });
    assert.ok(!result.stdout.includes(setupCode), "the setup code is not echoed");
    assert.ok(!/LTSK|LTPK|privateKey/i.test(result.stdout), "no key material in the summary");
    // the reference accessory saw the pairing come and go
    assert.match(accessory.stdout(), /"event":"paired"/);
    assert.match(accessory.stdout(), /"event":"unpaired"/);
});

test("pair-oracle also pairs with PairSetupWithAuth (Method 1, hap-controller's default)", async () => {
    const result = await runOracle([ready.host, String(ready.port), setupCode, "--method", "1", "--seconds", "1"]);
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.equal(result.summary.oracle.pairMethod, "PairSetupWithAuth (1)");
    assert.deepEqual(stepNames(result.summary), FULL_RUN);
});

test("pair-oracle exits 1 when the accessory refuses the MotionDetected subscription (207 -70406), and unpairs itself", async () => {
    await withAccessory(["--fault", "subscribe=-70406", "--motion-interval-ms", "200"], async faulty => {
        const { host, port } = faulty.ready;
        assert.deepEqual(faulty.ready.faults, ["subscribe=-70406"]);
        const result = await runOracle([host, String(port), setupCode, "--seconds", "1"]);
        assert.equal(result.status, 1, result.stdout + result.stderr);
        assert.equal(result.summary?.ok, false);
        assert.equal(result.summary?.failedStep, "subscribeMotion");
        assert.match(result.summary.error, /status -70406/);
        assert.deepEqual(result.summary.events, [], "no events counted for a refused subscription");
        // the failed run removed the pairing it created, so the accessory can be paired again
        assert.equal(result.summary.cleanup?.needed, true);
        assert.equal(result.summary.cleanup?.removed, true, JSON.stringify(result.summary.cleanup));
        await waitForEvent(faulty, events => events.some(e => e.event === "unpaired"));
        const again = await runOracle([host, String(port), setupCode, "--seconds", "1"]);
        assert.equal(again.summary?.failedStep, "subscribeMotion", "the second run pairs again instead of failing pair-setup");
        assert.equal(again.summary?.cleanup?.removed, true);
    });
});

test("pair-oracle exits 1 when the accessory refuses the MotionDetected unsubscription (207 -70402)", async () => {
    await withAccessory(["--fault", "unsubscribe=-70402", "--motion-interval-ms", "200"], async faulty => {
        const result = await runOracle([faulty.ready.host, String(faulty.ready.port), setupCode, "--seconds", "1"]);
        assert.equal(result.status, 1, result.stdout + result.stderr);
        assert.equal(result.summary?.failedStep, "unsubscribeMotion");
        assert.match(result.summary.error, /status -70402/);
        assert.equal(result.summary.cleanup?.removed, true, JSON.stringify(result.summary.cleanup));
        await waitForEvent(faulty, events => events.some(e => e.event === "unpaired"));
    });
});

test("pair-oracle exits 1 when the accessory stops listening after unpairing instead of refusing pair-verify", async () => {
    await withAccessory(["--fault", "close-on-unpair", "--motion-interval-ms", "0"], async faulty => {
        const result = await runOracle([faulty.ready.host, String(faulty.ready.port), setupCode, "--seconds", "0"]);
        assert.equal(result.status, 1, result.stdout + result.stderr);
        assert.equal(result.summary?.failedStep, "verifyRemoved");
        assert.match(result.summary.error, /ECONNREFUSED/);
        assert.equal(result.summary.steps.find(step => step.name === "removePairing")?.ok, true);
        assert.deepEqual(result.summary.cleanup, { needed: false }, "removePairing succeeded, so there is nothing to clean up");
    });
});
