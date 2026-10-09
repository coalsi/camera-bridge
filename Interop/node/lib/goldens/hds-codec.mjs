// HDS value codec goldens. For each value: the canonical CameraBridge encoding (plan W1-6 item 1), what
// HAP-NodeJS's DataStreamWriter writes for it, and whether HAP-NodeJS's DataStreamParser reads the canonical
// bytes back. Differences are the HAP-NodeJS bugs / choices listed in research brief §3.8 and are documented
// per case. Decode-only cases are non-canonical encodings a decoder must accept (many written by HAP-NodeJS).
import { hn } from "../hap-nodejs.mjs";
import { V, decodeHDS, encodeCanonical, hapNodeJSReads, hapNodeJSWrite, toJSONValue, valuesEqual } from "./hds-values.mjs";
import { bytes, check, generatorNote, hex } from "./util.mjs";

const HN_READER_2F = "HAP-NodeJS's reader accepts integer tags only up to 0x2E (brief §3.8 HN bug); CameraBridge must decode 0x2F as 39.";
const HN_INT64 = "HAP-NodeJS writes int64 as a 32-bit value (writeUInt32LE) and throws outside 0…2^32−1 (brief §3.8 HN bug); CameraBridge writes a full two's-complement int64.";
const HN_NOT_REPRESENTABLE = "HAP-NodeJS holds integers as JS numbers and cannot express this int64 exactly; CameraBridge writes the full two's-complement int64.";
const HN_SHORT_DATA = "HAP-NodeJS's reader drops data of 0–32 bytes (tags 0x70–0x90 return undefined; brief §3.8 HN bug); CameraBridge must decode it.";
const HN_ARRAY_12 = "HAP-NodeJS writes arrays of more than 12 items in terminated form (0xDF … 0x03); CameraBridge uses the count form up to 14 items (0xD0+n).";
const HN_BACKREF = "HAP-NodeJS's writer replaces a repeated string/int/float/data with a back-reference (0xA0+index); CameraBridge never emits back-references.";

const ints = n => Array.from({ length: n }, (_, i) => V.int(i));
const keys = n => Array.from({ length: n }, (_, i) => [`key${String(i).padStart(2, "0")}`, V.int(i)]);

/** [name, value, note?] — a note is required whenever HAP-NodeJS writes or reads the value differently. */
const VALUE_CASES = [
    ["null", V.null()],
    ["true", V.bool(true)],
    ["false", V.bool(false)],
    ["int -1", V.int(-1)],
    ["int 0", V.int(0)],
    ["int 1", V.int(1)],
    ["int 38", V.int(38)],
    ["int 39 (tag 0x2F)", V.int(39), HN_READER_2F],
    ["int 40 (first int8)", V.int(40)],
    ["int 127", V.int(127)],
    ["int -2", V.int(-2)],
    ["int -128", V.int(-128)],
    ["int 128 (first int16)", V.int(128)],
    ["int -129", V.int(-129)],
    ["int 255", V.int(255)],
    ["int 32767", V.int(32767)],
    ["int -32768", V.int(-32768)],
    ["int 32768 (first int32)", V.int(32768)],
    ["int -32769", V.int(-32769)],
    ["int 65535", V.int(65535)],
    ["int 2147483647", V.int(2147483647)],
    ["int -2147483648", V.int(-2147483648)],
    ["int 2147483648 (first int64)", V.int(2147483648)],
    ["int 4294967295", V.int(4294967295)],
    ["int 4294967296", V.int(4294967296n), HN_INT64],
    ["int -2147483649", V.int(-2147483649n), HN_INT64],
    ["int 2^53 − 1", V.int(9007199254740991n), HN_INT64],
    ["int64 max", V.int(9223372036854775807n), HN_NOT_REPRESENTABLE],
    ["int64 min", V.int(-9223372036854775808n), HN_NOT_REPRESENTABLE],
    ["float 1.5", V.float(1.5)],
    ["float -0.25", V.float(-0.25)],
    ["float 2.0 (integral float stays float64)", V.float(2)],
    ["float 0.1", V.float(0.1)],
    ["float pi", V.float(Math.PI)],
    ["float 1e300", V.float(1e300)],
    ["date 0 (2001-01-01T00:00:00Z)", V.date(0)],
    ["date 781000000.5", V.date(781000000.5)],
    ["uuid MotionDetected", V.uuid("00000022-0000-1000-8000-0026BB765291")],
    ["uuid random-looking", V.uuid("E7A5E2C1-4F7B-4E5D-9A3B-0C6F1D2E3A4B")],
    ["string empty", V.string("")],
    ["string a", V.string("a")],
    ["string dataSend", V.string("dataSend")],
    ["string 32 bytes (last short form)", V.string("ipcamera.recording.stream.012345")],
    ["string 33 bytes (first length8)", V.string("ipcamera.recording.stream.0123456")],
    ["string 255 bytes", V.string("s".repeat(255))],
    ["string 256 bytes (first length16)", V.string("t".repeat(256))],
    ["string UTF-8 multibyte", V.string("Grüße ✓ 📷")],
    ["data empty", V.data(Buffer.alloc(0)), HN_SHORT_DATA],
    ["data 1 byte", V.data(Buffer.from([0x7f])), HN_SHORT_DATA],
    ["data 32 bytes (last short form)", V.data(bytes("hds data 32", 32)), HN_SHORT_DATA],
    ["data 33 bytes (first length8)", V.data(bytes("hds data 33", 33))],
    ["data 255 bytes", V.data(bytes("hds data 255", 255))],
    ["data 256 bytes (first length16)", V.data(bytes("hds data 256", 256))],
    ["array empty", V.array([])],
    ["array [1]", V.array([V.int(1)])],
    ["array mixed", V.array([V.string("a"), V.int(1000), V.bool(true), V.null(), V.float(0.5)])],
    ["array 12 items", V.array(ints(12))],
    ["array 13 items", V.array(ints(13)), HN_ARRAY_12],
    ["array 14 items (last count form)", V.array(ints(14)), HN_ARRAY_12],
    ["array 15 items (terminated)", V.array(ints(15))],
    ["array nested", V.array([V.array([V.int(1), V.int(2)]), V.array([V.int(3), V.array([V.int(4)])])])],
    ["dictionary empty", V.dict([])],
    ["dictionary brief §3.8 event header", V.dict([["protocol", V.string("dataSend")], ["event", V.string("data")]])],
    ["dictionary 14 entries (last count form)", V.dict(keys(14))],
    ["dictionary 15 entries (terminated)", V.dict(keys(15))],
    ["dictionary dataSend open request body", V.dict([["target", V.string("controller")], ["type", V.string("ipcamera.recording")], ["streamId", V.int(1)]])],
    ["dictionary nested with data", V.dict([
        ["streamId", V.int(3)],
        ["packets", V.array([V.dict([
            ["data", V.data(bytes("hds nested data", 40))],
            ["metadata", V.dict([["dataType", V.string("mediaFragment")], ["dataSequenceNumber", V.int(2)], ["isLastDataChunk", V.bool(true)]])],
        ])])],
    ])],
    ["array with a repeated string", V.array([V.string("abc"), V.string("abc")]), HN_BACKREF],
    ["dictionary with a repeated value", V.dict([["a", V.string("x")], ["b", V.string("x")]]), HN_BACKREF],
];

/** [name, encoded, value, note]: accepted by a decoder, never produced by the canonical encoder. */
function decodeOnlyCases() {
    const hnWritten = value => {
        const written = hapNodeJSWrite(value).encoded;
        check(written, "HAP-NodeJS writes the decode-only source value");
        return written;
    };
    const { DataStreamParser, DataStreamWriter } = hn().datastream;
    const sameBuffer = bytes("hds repeated data", 40);
    const repeatedData = new DataStreamWriter();
    DataStreamParser.encode([sameBuffer, sameBuffer], repeatedData);
    return [
        ["int 5 as int8 (0x30)", Buffer.from("3005", "hex"), V.int(5), "Non-minimal integer form."],
        ["int -1 as int16 (0x31)", Buffer.from("31ffff", "hex"), V.int(-1), "Non-minimal integer form."],
        ["int 5 as int64 (0x33)", Buffer.from("330500000000000000", "hex"), V.int(5), "Non-minimal integer form (HDS headers carry id/status this way)."],
        ["float32 1.5 (0x35)", Buffer.from("350000c03f", "hex"), V.float(1.5), "float32 widens to Double."],
        ["string length8 form for 3 bytes (0x61)", Buffer.from("6103616263", "hex"), V.string("abc"), "Non-minimal length form."],
        ["string length16 form (0x62)", Buffer.from("620300616263", "hex"), V.string("abc"), "Non-minimal length form."],
        ["string length32 form (0x63)", Buffer.from("6303000000616263", "hex"), V.string("abc"), "Non-minimal length form."],
        ["string length64 form (0x64)", Buffer.from("640300000000000000616263", "hex"), V.string("abc"), "Non-minimal length form."],
        ["string NUL-terminated (0x6F)", Buffer.from("6f61626300", "hex"), V.string("abc"), "Terminated by 0x00."],
        ["data length8 form for 2 bytes (0x91)", Buffer.from("91020102", "hex"), V.data(Buffer.from([1, 2])), "Non-minimal length form."],
        ["data length32 form (0x93)", Buffer.from("93020000000102", "hex"), V.data(Buffer.from([1, 2])), "Non-minimal length form."],
        ["data length64 form (0x94)", Buffer.from("9402000000000000000102", "hex"), V.data(Buffer.from([1, 2])), "Non-minimal length form."],
        ["data terminated (0x9F)", Buffer.from("9f010203", "hex"), V.data(Buffer.from([1, 2])), "Terminated by 0x03 (so 0x03 cannot occur inside)."],
        ["array of 13 as HAP-NodeJS writes it (terminated 0xDF)", hnWritten(V.array(ints(13))), V.array(ints(13)), HN_ARRAY_12],
        ["array of 2 in terminated form (0xDF)", Buffer.from("df080903", "hex"), V.array(ints(2)), "Terminated form for a short array."],
        ["dictionary of 2 in terminated form (0xEF)", Buffer.from("ef416108416209" + "03", "hex"), V.dict([["a", V.int(0)], ["b", V.int(1)]]), "Terminated form for a short dictionary."],
        ["back-reference (compression) to a repeated string, as HAP-NodeJS writes it", hnWritten(V.array([V.string("abc"), V.string("abc")])),
            V.array([V.string("abc"), V.string("abc")]), HN_BACKREF],
        ["back-reference (compression) to a repeated dictionary value", hnWritten(V.dict([["a", V.string("x")], ["b", V.string("x")]])),
            V.dict([["a", V.string("x")], ["b", V.string("x")]]), HN_BACKREF],
        ["back-reference (compression) to a repeated int8", hnWritten(V.array([V.int(100), V.int(100)])),
            V.array([V.int(100), V.int(100)]), HN_BACKREF],
        ["back-reference (compression) to a repeated data value", Buffer.from(repeatedData.getData()),
            V.array([V.data(sameBuffer), V.data(sameBuffer)]), HN_BACKREF + " HAP-NodeJS compresses data only when the same Buffer object repeats."],
        ["back-reference (compression) to a dictionary key", hnWritten(V.dict([["key", V.string("value")], ["nested", V.dict([["key", V.string("other")]])]])),
            V.dict([["key", V.string("value")], ["nested", V.dict([["key", V.string("other")]])]]), HN_BACKREF + " Keys are strings and count as written values."],
    ];
}

const INVALID_CASES = [
    ["tag 0x00 (invalid)", "00"],
    ["unassigned tag 0x34", "34"],
    ["unassigned tag 0x65", "65"],
    ["unassigned tag 0x95", "95"],
    ["string shorter than its tag says", "43 6162"],
    ["int32 truncated", "32 0100"],
    ["back-reference with nothing written before it", "a0"],
    ["dictionary missing its value", "e1 4161"],
    ["array missing an element", "d2 08"],
    ["NUL-terminated string without NUL", "6f 6162"],
    ["terminated array without terminator", "df 08 09"],
];

export function generateHDSCodec() {
    const { version } = hn();
    const values = VALUE_CASES.map(([name, value, note]) => {
        const encoded = encodeCanonical(value);
        check(valuesEqual(decodeHDS(encoded), value), `canonical ${name} decodes to its value`);
        const written = hapNodeJSWrite(value);
        const readerRoundTrip = hapNodeJSReads(encoded, value);
        const writer = written.encoded ? hex(written.encoded) : null;
        const differs = writer !== hex(encoded) || !readerRoundTrip;
        check(!differs || note, `${name}: HAP-NodeJS differs (writer ${writer}, reads canonical ${readerRoundTrip}) — document it`);
        check(differs || !note, `${name}: documented difference no longer occurs`);
        const out = { name, value: toJSONValue(value), encoded: hex(encoded), hapNodeJS: { writer, readerRoundTrip } };
        if (note) out.note = note;
        return out;
    });

    const decodeOnly = decodeOnlyCases().map(([name, buffer, value, note]) => {
        check(valuesEqual(decodeHDS(buffer), value), `decode-only ${name} decodes to its value`);
        check(!buffer.equals(encodeCanonical(value)), `decode-only ${name} is not canonical`);
        const hapNodeJSReadsIt = hapNodeJSReads(buffer, value);
        check(hapNodeJSReadsIt, `HAP-NodeJS reads decode-only ${name}`);
        return { name, encoded: hex(buffer), value: toJSONValue(value), note };
    });

    const invalid = INVALID_CASES.map(([name, spaced]) => {
        const encoded = spaced.replace(/\s+/g, "");
        const buffer = Buffer.from(encoded, "hex");
        let rejected = false;
        try { decodeHDS(buffer); } catch { rejected = true; }
        check(rejected, `independent decoder rejects ${name}`);
        const { DataStreamParser, DataStreamReader } = hn().datastream;
        let hnRejected = false;
        try { DataStreamParser.decode(new DataStreamReader(buffer)); } catch { hnRejected = true; }
        const out = { name, encoded };
        if (!hnRejected) out.note = "HAP-NodeJS's reader does not reject this input (it returns a partial value).";
        return out;
    });

    return {
        generator: generatorNote("hds-codec"),
        source: `HAP-NodeJS ${version} (Apache-2.0) lib/datastream/DataStreamParser.ts (DataStreamWriter / DataStreamReader), research brief §3.8, plan W1-6 item 1`,
        notes: [
            "Value JSON: {type: null|bool|int|float|string|data|uuid|date|array|dictionary, value}. int values are decimal strings (full int64); float values are float64 JSON numbers; data values are hex; uuid values are uppercase; date values are seconds since 2001-01-01T00:00:00Z (Date(timeIntervalSinceReferenceDate:)); dictionary values are ordered [{key, value}] pairs.",
            "`values`: HDSCodec.encode(value) must equal `encoded` byte for byte, and HDSCodec.decode(encoded) must equal `value`. `hapNodeJS.writer` is what HAP-NodeJS writes (null when it cannot); `hapNodeJS.readerRoundTrip` says whether HAP-NodeJS reads `encoded` back. Every difference has a `note`.",
            "Canonical rules: -1 → 0x07; 0…39 → 0x08+n; then int8 0x30 / int16LE 0x31 / int32LE 0x32 / int64LE 0x33 by range; float → float64 0x36; date → 0x06 + float64; strings and data ≤ 32 bytes → 0x40+n / 0x70+n, else length8/16/32/64 (0x61–0x64 / 0x91–0x94); uuid → 0x05 + 16 bytes big-endian; arrays/dictionaries ≤ 14 items → 0xD0+n / 0xE0+n, else 0xDF / 0xEF … 0x03; never back-references (0xA0–0xCF).",
            "`decodeOnly`: HDSCodec.decode(encoded) must equal `value`; the canonical encoder never produces these bytes. HAP-NodeJS reads all of them.",
            "Back-references (0xA0+i) refer to the i-th value decoded so far in the same encoded message (header and body are separate messages). HAP-NodeJS's reader counts every bool, int, float, date, string, data and uuid it reads (dictionary keys included; not null and not containers), while its writer only counts strings, ints outside -1…39, floats, dates, data and uuids — the two disagree when a bool or small int precedes a back-reference, so the decodeOnly cases avoid that situation.",
            "`invalid`: HDSCodec.decode(encoded) must throw.",
        ],
        values,
        decodeOnly,
        invalid,
    };
}
