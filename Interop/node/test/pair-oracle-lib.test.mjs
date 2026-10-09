// Unit tests for the oracle's verdict helpers (lib/pair-oracle.mjs) and the tests' JSON-line reader.
import { test } from "node:test";
import assert from "node:assert/strict";

import { characteristicWriteProblems, isPairVerifyRefusal } from "../lib/pair-oracle.mjs";
import { hapController } from "../lib/hap-nodejs.mjs";
import { jsonLineSplitter } from "./support.mjs";

const ids = ["1.10", "1.20"];
const multi = characteristics => ({ statusCode: 207, body: Buffer.from(JSON.stringify({ characteristics })) });

test("characteristic write: 204 is accepted", () => {
    assert.deepEqual(characteristicWriteProblems({ statusCode: 204, body: Buffer.alloc(0) }, ids), []);
});

test("characteristic write: 207 with status 0 for every requested id is accepted", () => {
    assert.deepEqual(characteristicWriteProblems(multi([{ aid: 1, iid: 10, status: 0 }, { aid: 1, iid: 20, status: 0 }]), ids), []);
});

test("characteristic write: 207 with a per-characteristic error is a failure", () => {
    const problems = characteristicWriteProblems(multi([{ aid: 1, iid: 10, status: 0 }, { aid: 1, iid: 20, status: -70406 }]), ids);
    assert.deepEqual(problems, ["1.20: status -70406"]);
    assert.deepEqual(characteristicWriteProblems(multi([{ aid: 1, iid: 10, status: -70402 }]), ["1.10"]), ["1.10: status -70402"]);
});

test("characteristic write: a 207 entry without a status, a missing id or an unrequested id is a failure", () => {
    assert.deepEqual(characteristicWriteProblems(multi([{ aid: 1, iid: 10 }, { aid: 1, iid: 20, status: 0 }]), ids), ["1.10: no status"]);
    assert.deepEqual(characteristicWriteProblems(multi([{ aid: 1, iid: 10, status: 0 }]), ids), ["1.20: missing from the 207 response"]);
    assert.deepEqual(characteristicWriteProblems(multi([{ aid: 1, iid: 10, status: 0 }, { aid: 1, iid: 20, status: 0 }, { aid: 1, iid: 30, status: 0 }]), ids),
        ["1.30: not in the request"]);
});

test("characteristic write: a malformed 207 body or any other HTTP status is a failure", () => {
    assert.deepEqual(characteristicWriteProblems({ statusCode: 207, body: Buffer.from("not json") }, ids), ["207 body is not JSON"]);
    assert.deepEqual(characteristicWriteProblems({ statusCode: 207, body: Buffer.alloc(0) }, ids), ["207 body is not JSON"]);
    assert.deepEqual(characteristicWriteProblems({ statusCode: 207, body: Buffer.from("{}") }, ids), ["207 body has no characteristics array"]);
    assert.deepEqual(characteristicWriteProblems({ statusCode: 200, body: Buffer.from("{}") }, ids), ["HTTP 200, expected 204 or 207"]);
    assert.deepEqual(characteristicWriteProblems({ statusCode: 400, body: Buffer.from('{"status":-70410}') }, ids), ["HTTP 400, expected 204 or 207"]);
    assert.deepEqual(characteristicWriteProblems(undefined, ids), ["HTTP undefined, expected 204 or 207"]);
});

test("pair-verify refusal: only kTLVError_Authentication (2) at M2/M4 counts", () => {
    const { HomekitControllerError } = hapController();
    assert.equal(isPairVerifyRefusal(new HomekitControllerError("M4: Error: 2", 2)), true);
    assert.equal(isPairVerifyRefusal(new HomekitControllerError("M2: Error: 2", 2)), true);
    assert.equal(isPairVerifyRefusal(new HomekitControllerError("M4: Error: 1", 1)), false, "kTLVError_Unknown");
    assert.equal(isPairVerifyRefusal(new HomekitControllerError("M4: Error: 6", 6)), false, "kTLVError_Unavailable");
    assert.equal(isPairVerifyRefusal(new HomekitControllerError("Get failed with status 2", 2)), false);
    assert.equal(isPairVerifyRefusal(Object.assign(new Error("connect ECONNREFUSED 127.0.0.1:1"), { code: "ECONNREFUSED" })), false);
    assert.equal(isPairVerifyRefusal(new Error("M2: Wrong accessory pairing ID")), false);
    assert.equal(isPairVerifyRefusal(new Error("M4: Error: 2")), false, "no TLV status code attached");
    assert.equal(isPairVerifyRefusal(undefined), false);
});

test("jsonLineSplitter waits for the newline of a split line and parses each line once", () => {
    const seen = [];
    const split = jsonLineSplitter(value => seen.push(value));
    split('{"event":"re');
    assert.deepEqual(seen, [], "a partial line is not parsed (and does not throw)");
    split('ady","port":1}\n{"event":"paired"}\n');
    split("progress text\n{broken json}\n");
    split('{"event":"unpaired"}\n{"event":');
    assert.deepEqual(seen, [{ event: "ready", port: 1 }, { event: "paired" }, { event: "unpaired" }]);
});
