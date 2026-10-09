// Unit tests for the canonical HDS value model used to write hds-codec.json / hds-frames.json.
// The canonical rules are plan W1-6 item 1 and research brief §3.8.
import { test } from "node:test";
import assert from "node:assert/strict";

import { V, encodeCanonical, decodeHDS, hdsTags, valuesEqual, toHAPNodeJS, fromHAPNodeJS, toJSONValue } from "../lib/goldens/hds-values.mjs";
import { hn } from "../lib/hap-nodejs.mjs";

const hex = v => encodeCanonical(v).toString("hex");

test("integers use the smallest canonical form", () => {
    assert.equal(hex(V.int(-1)), "07");
    assert.equal(hex(V.int(0)), "08");
    assert.equal(hex(V.int(39)), "2f");
    assert.equal(hex(V.int(40)), "3028");
    assert.equal(hex(V.int(-2)), "30fe");
    assert.equal(hex(V.int(127)), "307f");
    assert.equal(hex(V.int(-128)), "3080");
    assert.equal(hex(V.int(128)), "318000");
    assert.equal(hex(V.int(-32768)), "310080");
    assert.equal(hex(V.int(32768)), "3200800000");
    assert.equal(hex(V.int(-2147483648)), "3200000080");
    assert.equal(hex(V.int(2147483648)), "330000008000000000");
    assert.equal(hex(V.int(4294967296n)), "330000000001000000");
    assert.equal(hex(V.int(-9223372036854775808n)), "330000000000000080");
    assert.equal(hex(V.int(9223372036854775807n)), "33ffffffffffffff7f");
});

test("strings and data switch forms at 32 bytes, then by length width", () => {
    assert.equal(hex(V.string("")), "40");
    assert.equal(hex(V.string("abc")), "43616263");
    assert.equal(hex(V.string("a".repeat(32))).slice(0, 2), "60");
    assert.equal(hex(V.string("a".repeat(33))).slice(0, 4), "6121");
    assert.equal(hex(V.string("a".repeat(256))).slice(0, 6), "620001");
    assert.equal(hex(V.string("é")), "42c3a9");
    assert.equal(hex(V.data(Buffer.alloc(0))), "70");
    assert.equal(hex(V.data(Buffer.from([1, 2]))), "720102");
    assert.equal(hex(V.data(Buffer.alloc(33))).slice(0, 4), "9121");
    assert.equal(hex(V.data(Buffer.alloc(256))).slice(0, 6), "920001");
});

test("containers use count forms up to 14 items, then terminated forms", () => {
    const ints = n => Array.from({ length: n }, (_, i) => V.int(i));
    assert.equal(hex(V.array([])), "d0");
    assert.equal(hex(V.array(ints(14))).slice(0, 2), "de");
    const fifteen = hex(V.array(ints(15)));
    assert.equal(fifteen.slice(0, 2), "df");
    assert.equal(fifteen.slice(-2), "03");
    const dict = n => V.dict(Array.from({ length: n }, (_, i) => [`k${i}`, V.int(i)]));
    assert.equal(hex(dict(0)), "e0");
    assert.equal(hex(dict(14)).slice(0, 2), "ee");
    assert.equal(hex(dict(15)).slice(0, 2), "ef");
    assert.equal(hex(dict(15)).slice(-2), "03");
});

test("brief §3.8 dataSend event header golden", () => {
    const header = V.dict([["protocol", V.string("dataSend")], ["event", V.string("data")]]);
    assert.equal(hex(header), "e24870726f746f636f6c486461746153656e64456576656e744464617461");
});

test("uuid, date, float and bool encodings", () => {
    assert.equal(hex(V.uuid("00000022-0000-1000-8000-0026BB765291")), "050000002200001000800000" + "26bb765291");
    assert.equal(hex(V.date(0)), "06" + "0000000000000000");
    assert.equal(hex(V.float(1.5)), "36000000000000f83f");
    assert.equal(hex(V.float(2)), "360000000000000040");
    assert.equal(hex(V.bool(true)), "01");
    assert.equal(hex(V.bool(false)), "02");
    assert.equal(hex(V.null()), "04");
});

test("decodeHDS reads every form, including forms the encoder never emits", () => {
    const cases = [
        ["2f", V.int(39)],
        ["3005", V.int(5)],
        ["330500000000000000", V.int(5)],
        ["350000c03f", V.float(1.5)],
        ["6103616263", V.string("abc")],
        ["620300616263", V.string("abc")],
        ["6303000000616263", V.string("abc")],
        ["640300000000000000616263", V.string("abc")],
        ["6f61626300", V.string("abc")],
        ["720102", V.data(Buffer.from([1, 2]))],
        ["9f010203", V.data(Buffer.from([1, 2]))],
        ["df080903", V.array([V.int(0), V.int(1)])],
        ["ef4161416103", V.dict([["a", V.string("a")]])],
        ["d2436162630a", V.array([V.string("abc"), V.int(2)])],
        ["d243616263a0", V.array([V.string("abc"), V.string("abc")])],
    ];
    for (const [encoded, value] of cases) {
        const decoded = decodeHDS(Buffer.from(encoded, "hex"));
        assert.ok(valuesEqual(decoded, value), `${encoded}: ${JSON.stringify(toJSONValue(decoded))}`);
    }
    assert.throws(() => decodeHDS(Buffer.from("00", "hex")));
    assert.throws(() => decodeHDS(Buffer.from("43616", "hex")));
    assert.throws(() => decodeHDS(Buffer.from("a0", "hex")));
    assert.throws(() => decodeHDS(Buffer.from("0808", "hex")), /trailing/);
});

test("hdsTags walks nested structures", () => {
    assert.deepEqual(hdsTags(Buffer.from("e1416143616263", "hex")), [0xe1, 0x41, 0x43]);
    assert.deepEqual(hdsTags(Buffer.from("df080903", "hex")), [0xdf, 0x08, 0x09, 0x03]);
});

test("values convert to and from HAP-NodeJS representations", () => {
    const { DataStreamParser, DataStreamReader, DataStreamWriter } = hn().datastream;
    const value = V.dict([
        ["s", V.string("x")], ["i", V.int(1234)], ["f", V.float(2)], ["d", V.data(Buffer.from([9]))],
        ["u", V.uuid("00000022-0000-1000-8000-0026BB765291")], ["t", V.date(12.5)], ["a", V.array([V.bool(true), V.null()])],
    ]);
    const writer = new DataStreamWriter();
    DataStreamParser.encode(toHAPNodeJS(value), writer);
    assert.equal(writer.getData().toString("hex"), hex(value));
    const decoded = DataStreamParser.decode(new DataStreamReader(Buffer.from("e2417343616263416930fe", "hex")));
    assert.ok(valuesEqual(fromHAPNodeJS(decoded, V.dict([["s", V.string("abc")], ["i", V.int(-2)]])),
        V.dict([["s", V.string("abc")], ["i", V.int(-2)]])));
});
