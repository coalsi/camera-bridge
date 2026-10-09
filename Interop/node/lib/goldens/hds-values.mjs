// Typed HDS values (mirroring the contract's `HDSValue`), the canonical encoder CameraBridge must match
// byte for byte (plan W1-6 item 1, research brief §3.8), an independent decoder, and conversions to and
// from HAP-NodeJS's DataStreamParser representation (plain JS values plus ValueWrapper classes).
//
// JSON form used in the fixtures (see goldens README / docs/interop.md):
//   {"type":"null"} | {"type":"bool","value":true} | {"type":"int","value":"-1"} (decimal string, int64)
//   {"type":"float","value":1.5} (float64) | {"type":"string","value":"…"} | {"type":"data","value":"<hex>"}
//   {"type":"uuid","value":"XXXXXXXX-…"} | {"type":"date","value":<seconds since 2001-01-01T00:00:00Z>}
//   {"type":"array","value":[…]} | {"type":"dictionary","value":[{"key":"…","value":{…}}, …]} (ordered)
import { hn } from "../hap-nodejs.mjs";

const INT64_MIN = -(2n ** 63n);
const INT64_MAX = 2n ** 63n - 1n;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const V = {
    null: () => ({ type: "null" }),
    bool: value => ({ type: "bool", value: Boolean(value) }),
    int: value => {
        const big = BigInt(value);
        if (big < INT64_MIN || big > INT64_MAX) throw new RangeError(`int64 out of range: ${big}`);
        return { type: "int", value: big };
    },
    /** An int that must be written as int64 (tag 0x33) whatever its magnitude: HDS header `id` / `status`. */
    int64: value => ({ ...V.int(value), width: 64 }),
    float: value => ({ type: "float", value: Number(value) }),
    string: value => ({ type: "string", value: String(value) }),
    data: value => ({ type: "data", value: Buffer.from(value) }),
    uuid: value => {
        if (!UUID_PATTERN.test(value)) throw new Error(`invalid uuid ${value}`);
        return { type: "uuid", value: value.toUpperCase() };
    },
    date: seconds => ({ type: "date", value: Number(seconds) }),
    array: items => ({ type: "array", value: items }),
    dict: pairs => ({ type: "dictionary", value: pairs.map(([k, v]) => [String(k), v]) }),
};

// MARK: canonical encoder

function intBytes(value, width) {
    const out = Buffer.alloc(width / 8);
    if (width === 8) out.writeInt8(Number(value));
    else if (width === 16) out.writeInt16LE(Number(value));
    else if (width === 32) out.writeInt32LE(Number(value));
    else out.writeBigInt64LE(value);
    return out;
}

function lengthPrefixed(shortBase, longTags, bytes) {
    const n = bytes.length;
    if (n <= 32) return Buffer.concat([Buffer.from([shortBase + n]), bytes]);
    if (n <= 0xff) return Buffer.concat([Buffer.from([longTags[0], n]), bytes]);
    if (n <= 0xffff) { const l = Buffer.alloc(2); l.writeUInt16LE(n); return Buffer.concat([Buffer.from([longTags[1]]), l, bytes]); }
    if (n <= 0xffffffff) { const l = Buffer.alloc(4); l.writeUInt32LE(n); return Buffer.concat([Buffer.from([longTags[2]]), l, bytes]); }
    const l = Buffer.alloc(8); l.writeBigUInt64LE(BigInt(n)); return Buffer.concat([Buffer.from([longTags[3]]), l, bytes]);
}

function float64(tag, value) {
    const out = Buffer.alloc(9);
    out[0] = tag;
    out.writeDoubleLE(value, 1);
    return out;
}

/** Canonical CameraBridge encoding: smallest integer form, count forms up to 14 items, never back-references. */
export function encodeCanonical(v) {
    switch (v.type) {
    case "null": return Buffer.from([0x04]);
    case "bool": return Buffer.from([v.value ? 0x01 : 0x02]);
    case "int": {
        const n = v.value;
        if (v.width === 64) return Buffer.concat([Buffer.from([0x33]), intBytes(n, 64)]);
        if (n === -1n) return Buffer.from([0x07]);
        if (n >= 0n && n <= 39n) return Buffer.from([0x08 + Number(n)]);
        if (n >= -128n && n <= 127n) return Buffer.concat([Buffer.from([0x30]), intBytes(n, 8)]);
        if (n >= -32768n && n <= 32767n) return Buffer.concat([Buffer.from([0x31]), intBytes(n, 16)]);
        if (n >= -2147483648n && n <= 2147483647n) return Buffer.concat([Buffer.from([0x32]), intBytes(n, 32)]);
        return Buffer.concat([Buffer.from([0x33]), intBytes(n, 64)]);
    }
    case "float": return float64(0x36, v.value);
    case "date": return float64(0x06, v.value);
    case "string": return lengthPrefixed(0x40, [0x61, 0x62, 0x63, 0x64], Buffer.from(v.value, "utf8"));
    case "data": return lengthPrefixed(0x70, [0x91, 0x92, 0x93, 0x94], v.value);
    case "uuid": return Buffer.concat([Buffer.from([0x05]), Buffer.from(v.value.replace(/-/g, ""), "hex")]);
    case "array": {
        const body = v.value.map(encodeCanonical);
        return v.value.length <= 14
            ? Buffer.concat([Buffer.from([0xd0 + v.value.length]), ...body])
            : Buffer.concat([Buffer.from([0xdf]), ...body, Buffer.from([0x03])]);
    }
    case "dictionary": {
        const body = v.value.flatMap(([k, value]) => [encodeCanonical(V.string(k)), encodeCanonical(value)]);
        return v.value.length <= 14
            ? Buffer.concat([Buffer.from([0xe0 + v.value.length]), ...body])
            : Buffer.concat([Buffer.from([0xef]), ...body, Buffer.from([0x03])]);
    }
    default: throw new Error(`unknown HDS value type ${v.type}`);
    }
}

// MARK: independent decoder

const TERMINATOR = Symbol("terminator");

/**
 * Decodes one HDS value (every tag of brief §3.8). Back-references (0xA0–0xCF) index the list of scalar values
 * decoded so far in this buffer, counted the way HAP-NodeJS's DataStreamReader counts them (every bool, int,
 * float, date, string, data and uuid; not null, not containers).
 */
export function decodeHDS(buffer, { onTag } = {}) {
    let index = 0;
    const tracked = [];
    const need = n => { if (index + n > buffer.length) throw new Error(`truncated at ${index}`); };
    const track = v => { tracked.push(v); return v; };
    const readLength = width => {
        need(width);
        let n;
        if (width === 1) n = buffer.readUInt8(index);
        else if (width === 2) n = buffer.readUInt16LE(index);
        else if (width === 4) n = buffer.readUInt32LE(index);
        else { const big = buffer.readBigUInt64LE(index); if (big > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error("length too large"); n = Number(big); }
        index += width;
        return n;
    };
    const readBytes = n => { need(n); const b = buffer.subarray(index, index + n); index += n; return Buffer.from(b); };
    const readUntil = stop => {
        const end = buffer.indexOf(stop, index);
        if (end < 0) throw new Error("unterminated value");
        const b = Buffer.from(buffer.subarray(index, end));
        index = end + 1;
        return b;
    };
    const decodeOne = () => {
        need(1);
        const tag = buffer[index++];
        onTag?.(tag);
        if (tag === 0x01) return track(V.bool(true));
        if (tag === 0x02) return track(V.bool(false));
        if (tag === 0x03) return TERMINATOR;
        if (tag === 0x04) return V.null();
        if (tag === 0x05) { const b = readBytes(16).toString("hex"); return track(V.uuid(`${b.slice(0, 8)}-${b.slice(8, 12)}-${b.slice(12, 16)}-${b.slice(16, 20)}-${b.slice(20)}`)); }
        if (tag === 0x06) { need(8); const s = buffer.readDoubleLE(index); index += 8; return track(V.date(s)); }
        if (tag === 0x07) return track(V.int(-1));
        if (tag >= 0x08 && tag <= 0x2f) return track(V.int(tag - 0x08));
        if (tag === 0x30) { need(1); const n = buffer.readInt8(index); index += 1; return track(V.int(n)); }
        if (tag === 0x31) { need(2); const n = buffer.readInt16LE(index); index += 2; return track(V.int(n)); }
        if (tag === 0x32) { need(4); const n = buffer.readInt32LE(index); index += 4; return track(V.int(n)); }
        if (tag === 0x33) { need(8); const n = buffer.readBigInt64LE(index); index += 8; return track(V.int(n)); }
        if (tag === 0x35) { need(4); const f = buffer.readFloatLE(index); index += 4; return track(V.float(f)); }
        if (tag === 0x36) { need(8); const f = buffer.readDoubleLE(index); index += 8; return track(V.float(f)); }
        if (tag >= 0x40 && tag <= 0x60) return track(V.string(readBytes(tag - 0x40).toString("utf8")));
        if (tag >= 0x61 && tag <= 0x64) return track(V.string(readBytes(readLength([1, 2, 4, 8][tag - 0x61])).toString("utf8")));
        if (tag === 0x6f) return track(V.string(readUntil(0x00).toString("utf8")));
        if (tag >= 0x70 && tag <= 0x90) return track(V.data(readBytes(tag - 0x70)));
        if (tag >= 0x91 && tag <= 0x94) return track(V.data(readBytes(readLength([1, 2, 4, 8][tag - 0x91]))));
        if (tag === 0x9f) return track(V.data(readUntil(0x03)));
        if (tag >= 0xa0 && tag <= 0xcf) {
            const ref = tracked[tag - 0xa0];
            if (ref === undefined) throw new Error(`back-reference 0x${tag.toString(16)} out of range`);
            return ref;
        }
        if (tag >= 0xd0 && tag <= 0xde) {
            const items = [];
            for (let i = 0; i < tag - 0xd0; i++) items.push(decodeValue());
            return V.array(items);
        }
        if (tag === 0xdf) {
            const items = [];
            for (let item = decodeOne(); item !== TERMINATOR; item = decodeOne()) items.push(item);
            return V.array(items);
        }
        if (tag >= 0xe0 && tag <= 0xee) {
            const pairs = [];
            for (let i = 0; i < tag - 0xe0; i++) pairs.push([decodeKey(), decodeValue()]);
            return V.dict(pairs);
        }
        if (tag === 0xef) {
            const pairs = [];
            for (let key = decodeOne(); key !== TERMINATOR; key = decodeOne()) {
                if (key.type !== "string") throw new Error("dictionary key is not a string");
                pairs.push([key.value, decodeValue()]);
            }
            return V.dict(pairs);
        }
        throw new Error(`invalid tag 0x${tag.toString(16)} at ${index - 1}`);
    };
    const decodeValue = () => {
        const v = decodeOne();
        if (v === TERMINATOR) throw new Error("unexpected terminator");
        return v;
    };
    const decodeKey = () => {
        const k = decodeValue();
        if (k.type !== "string") throw new Error("dictionary key is not a string");
        return k.value;
    };
    const value = decodeValue();
    if (index !== buffer.length) throw new Error(`trailing bytes after value (${buffer.length - index})`);
    return value;
}

/** Tags in walk order (nested values included; payload bytes skipped). */
export function hdsTags(buffer) {
    const tags = [];
    decodeHDS(buffer, { onTag: t => tags.push(t) });
    return tags;
}

// MARK: comparison

export function valuesEqual(a, b) {
    if (!a || !b || a.type !== b.type) return false;
    switch (a.type) {
    case "null": return true;
    case "int": return a.value === b.value;
    case "float": case "date": return Object.is(a.value, b.value) || a.value === b.value;
    case "data": return a.value.equals(b.value);
    case "uuid": return a.value.toUpperCase() === b.value.toUpperCase();
    case "array": return a.value.length === b.value.length && a.value.every((x, i) => valuesEqual(x, b.value[i]));
    case "dictionary": return a.value.length === b.value.length
        && a.value.every(([k, x], i) => k === b.value[i][0] && valuesEqual(x, b.value[i][1]));
    default: return a.value === b.value;
    }
}

// MARK: JSON form

export function toJSONValue(v) {
    switch (v.type) {
    case "null": return { type: "null" };
    case "int": return { type: "int", value: v.value.toString() };
    case "data": return { type: "data", value: v.value.toString("hex") };
    case "array": return { type: "array", value: v.value.map(toJSONValue) };
    case "dictionary": return { type: "dictionary", value: v.value.map(([key, value]) => ({ key, value: toJSONValue(value) })) };
    default: return { type: v.type, value: v.value };
    }
}

export function fromJSONValue(j) {
    switch (j.type) {
    case "null": return V.null();
    case "bool": return V.bool(j.value);
    case "int": return V.int(BigInt(j.value));
    case "float": return V.float(j.value);
    case "string": return V.string(j.value);
    case "data": return V.data(Buffer.from(j.value, "hex"));
    case "uuid": return V.uuid(j.value);
    case "date": return V.date(j.value);
    case "array": return V.array(j.value.map(fromJSONValue));
    case "dictionary": return V.dict(j.value.map(({ key, value }) => [key, fromJSONValue(value)]));
    default: throw new Error(`unknown JSON value type ${j.type}`);
    }
}

// MARK: HAP-NodeJS bridging

/** Converts to the value HAP-NodeJS's DataStreamParser.encode expects. Throws if HAP-NodeJS cannot express it. */
export function toHAPNodeJS(v) {
    const { Int64, Float64, UUID, SecondsSince2001 } = hn().datastream;
    switch (v.type) {
    case "null": return null;
    case "bool": return v.value;
    case "int": {
        if (v.value < BigInt(Number.MIN_SAFE_INTEGER) || v.value > BigInt(Number.MAX_SAFE_INTEGER)) {
            throw new RangeError("HAP-NodeJS represents integers as JS numbers; this value is not exactly representable");
        }
        return v.width === 64 ? new Int64(Number(v.value)) : Number(v.value);
    }
    case "float": return new Float64(v.value);
    case "date": return new SecondsSince2001(v.value);
    case "string": return v.value;
    case "data": return Buffer.from(v.value);
    case "uuid": return new UUID(v.value.toLowerCase());
    case "array": return v.value.map(toHAPNodeJS);
    case "dictionary": {
        const object = {};
        for (const [key, value] of v.value) {
            if (/^(0|[1-9]\d*)$/.test(key)) throw new Error(`integer-like key ${key} would be reordered by JS objects`);
            if (Object.hasOwn(object, key)) throw new Error(`duplicate key ${key}`);
            object[key] = toHAPNodeJS(value);
        }
        return object;
    }
    default: throw new Error(`unknown HDS value type ${v.type}`);
    }
}

const mismatch = value => ({ type: "mismatch", value });

/** Converts a HAP-NodeJS decoded value to a typed value, using `schema` (the expected value) for type hints. */
export function fromHAPNodeJS(hv, schema) {
    switch (schema.type) {
    case "null": return hv === null ? V.null() : mismatch(hv);
    case "bool": return typeof hv === "boolean" ? V.bool(hv) : mismatch(hv);
    case "int": return Number.isInteger(hv) ? V.int(BigInt(hv)) : mismatch(hv);
    case "float": return typeof hv === "number" ? V.float(hv) : mismatch(hv);
    case "date": return typeof hv === "number" ? V.date(hv) : mismatch(hv);
    case "string": return typeof hv === "string" ? V.string(hv) : mismatch(hv);
    case "data": return Buffer.isBuffer(hv) ? V.data(hv) : mismatch(hv);
    case "uuid": return typeof hv === "string" && UUID_PATTERN.test(hv) ? V.uuid(hv) : mismatch(hv);
    case "array":
        if (!Array.isArray(hv) || hv.length !== schema.value.length) return mismatch(hv);
        return V.array(hv.map((x, i) => fromHAPNodeJS(x, schema.value[i])));
    case "dictionary": {
        if (hv === null || typeof hv !== "object" || Array.isArray(hv) || Buffer.isBuffer(hv)) return mismatch(hv);
        const entries = Object.entries(hv);
        if (entries.length !== schema.value.length) return mismatch(hv);
        return V.dict(entries.map(([k, x], i) => {
            const hint = schema.value.find(([key]) => key === k)?.[1] ?? schema.value[i][1];
            return [k, fromHAPNodeJS(x, hint)];
        }));
    }
    default: return mismatch(hv);
    }
}

/** HAP-NodeJS's writer output for `v`, or null when it throws / cannot express the value. */
export function hapNodeJSWrite(v) {
    const { DataStreamParser, DataStreamWriter } = hn().datastream;
    try {
        const writer = new DataStreamWriter();
        DataStreamParser.encode(toHAPNodeJS(v), writer);
        return { encoded: Buffer.from(writer.getData()) };
    } catch (error) {
        return { encoded: null, error: String(error.message ?? error) };
    }
}

/** Whether HAP-NodeJS's reader decodes `buffer` completely to `expected`. */
export function hapNodeJSReads(buffer, expected) {
    const { DataStreamParser, DataStreamReader } = hn().datastream;
    try {
        const reader = new DataStreamReader(buffer);
        const decoded = DataStreamParser.decode(reader);
        return reader.readerIndex === buffer.length && valuesEqual(fromHAPNodeJS(decoded, expected), expected);
    } catch {
        return false;
    }
}
