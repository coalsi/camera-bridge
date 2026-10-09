// TLV8 goldens: encodings produced by HAP-NodeJS util/tlv.js `encode`, decodes cross-checked against its
// `decodeWithLists` (fragments merge only after a 255-byte item; `00 00` delimits lists), invalid inputs that
// HAP-NodeJS rejects, and list splitting at `FF 00` (pairings) / `00 00` (camera configurations).
import { hn } from "../hap-nodejs.mjs";
import { bytes, check, generatorNote, hex } from "./util.mjs";

const item = (type, value) => ({ type, value: Buffer.from(value) });
const json = items => items.map(i => ({ type: i.type, value: hex(i.value) }));

/** HAP-NodeJS encode of an ordered item list: tlv.encode(t1, v1, t2, v2, …). */
function hnEncode(items) {
    const { tlv } = hn();
    const args = items.flatMap(i => [i.type, i.value]);
    return tlv.encode(...args);
}

/** Item-level decode with the CameraBridge rule (research brief §3.2; same merge rule as decodeWithLists). */
function decodeItems(buffer) {
    const items = [];
    let index = 0;
    let lastWasFull = false;
    while (index < buffer.length) {
        if (buffer.length - index < 2) throw new Error("truncated");
        const type = buffer[index];
        const length = buffer[index + 1];
        if (buffer.length - index - 2 < length) throw new Error("invalidLength");
        const value = buffer.subarray(index + 2, index + 2 + length);
        if (lastWasFull && items.length && items[items.length - 1].type === type) {
            items[items.length - 1].value = Buffer.concat([items[items.length - 1].value, value]);
        } else {
            items.push(item(type, value));
        }
        lastWasFull = length === 255;
        index += 2 + length;
    }
    return items;
}

/** The shape HAP-NodeJS decodeWithLists returns for `items` (type → Buffer | Buffer[]), or null if it would throw. */
function itemsAsDecodeWithLists(items) {
    const result = {};
    let lastType = -1;
    let lastWasDelimiter = false;
    for (const { type, value } of items) {
        if (type === 0 && value.length === 0) { lastWasDelimiter = true; continue; }
        if (result[type] !== undefined) {
            if (!(lastWasDelimiter && lastType === type)) return null;
            result[type] = [result[type]].flat().concat([value]);
        } else {
            result[type] = value;
        }
        lastType = type;
        lastWasDelimiter = false;
    }
    return result;
}

function sameDecodeWithLists(buffer, items) {
    const { tlv } = hn();
    const expected = itemsAsDecodeWithLists(items);
    if (expected === null) return "not-applicable";
    const actual = tlv.decodeWithLists(buffer);
    const norm = o => JSON.stringify(Object.fromEntries(Object.entries(o).map(([k, v]) => [k, [v].flat().map(hex)])));
    return norm(actual) === norm(expected);
}

function splitList(items, separator) {
    const groups = [];
    let current = [];
    for (const i of items) {
        if (i.type === separator && i.value.length === 0) {
            if (current.length) groups.push(current);
            current = [];
        } else {
            current.push(i);
        }
    }
    if (current.length) groups.push(current);
    return groups;
}

const ENCODE_CASES = [
    ["empty value", [item(1, [])]],
    ["one-byte value (kTLVType_State M1)", [item(6, [1])]],
    ["pair-setup M1: state 1, method 0", [item(6, [1]), item(0, [0])]],
    ["255-byte value fits one item", [item(3, bytes("tlv8 255", 255))]],
    ["256-byte value splits 255 + 1", [item(3, bytes("tlv8 256", 256))]],
    ["300-byte value splits 255 + 45 (brief §3.2: 05 FF … 05 2D …)", [item(5, bytes("tlv8 300", 300))]],
    ["510-byte value splits into two full fragments", [item(3, bytes("tlv8 510", 510))]],
    ["1000-byte value splits 255 + 255 + 255 + 235", [item(10, bytes("tlv8 1000", 1000))]],
    ["pair-setup M2: state, 16-byte salt, 384-byte public key", [item(6, [2]), item(2, bytes("tlv8 salt", 16)), item(3, bytes("tlv8 srp B", 384))]],
    ["fragmented value followed by another type", [item(9, bytes("tlv8 ciphertext", 400)), item(10, bytes("tlv8 signature", 64))]],
    ["UTF-8 identifier then permissions", [item(1, Buffer.from("CameraBridge-Controller-7A3F", "utf8")), item(11, [1])]],
    ["items around an FF separator", [item(1, Buffer.from("A")), item(0xff, []), item(1, Buffer.from("B"))]],
];

export function generateTLV8() {
    const { tlv, version } = hn();
    check(version === "2.2.3", "HAP-NodeJS 2.2.3 is installed (npm ci)");

    const encode = ENCODE_CASES.map(([name, items]) => ({ name, items: json(items), encoded: hex(hnEncode(items)) }));

    const decodeOnlyInputs = [
        ["255-byte item followed by an empty same-type item merges to 255 bytes",
            Buffer.concat([Buffer.from([1, 255]), bytes("tlv8 full", 255), Buffer.from([1, 0])])],
        ["00 00 delimiter between same-type items keeps three items",
            Buffer.from("0101aa00000101bb", "hex")],
        ["255-byte item, delimiter, same-type item: not merged",
            Buffer.concat([Buffer.from([1, 255]), bytes("tlv8 full 2", 255), Buffer.from("00000101bb", "hex")])],
    ];
    const decode = [
        ...encode.map(c => ({ name: c.name, encoded: c.encoded })),
        ...decodeOnlyInputs.map(([name, buffer]) => ({ name, encoded: hex(buffer) })),
    ].map(({ name, encoded }) => {
        const buffer = Buffer.from(encoded, "hex");
        const items = decodeItems(buffer);
        const agrees = sameDecodeWithLists(buffer, items);
        check(agrees !== false, `decodeWithLists agrees for ${name}`);
        return { name, encoded, items: json(items), hapNodeJSDecodeWithLists: agrees === true ? "agrees" : "not applicable (repeated type without 00 00 delimiter)" };
    });
    // every encode case decodes back to its input items
    for (const c of encode) {
        const d = decode.find(x => x.encoded === c.encoded);
        check(JSON.stringify(d.items) === JSON.stringify(c.items), `round trip ${c.name}`);
    }

    const invalidInputs = [
        ["lone type byte", "01", "truncated", undefined],
        ["type and length without value", "0102aa", "invalidLength", 1],
        ["second item declares more bytes than remain", "0601010105aabb", "invalidLength", 1],
        ["valid item followed by a lone type byte", "06010109", "truncated", undefined],
    ];
    const invalid = invalidInputs.map(([name, encoded, error, type]) => {
        let rejected = false;
        try { tlv.decode(Buffer.from(encoded, "hex")); } catch { rejected = true; }
        check(rejected, `HAP-NodeJS tlv.decode rejects ${name}`);
        return type === undefined ? { name, encoded, error } : { name, encoded, error, type };
    });

    const pairingList = tlv.encode(6, 2,
        1, Buffer.from("A1B2C3D4-0000-4000-8000-000000000001"), 3, bytes("tlv8 ltpk 1", 32), 11, 1,
        0xff, Buffer.alloc(0),
        1, Buffer.from("A1B2C3D4-0000-4000-8000-000000000002"), 3, bytes("tlv8 ltpk 2", 32), 11, 0);
    const attributeList = tlv.encode(3, [
        tlv.encode(1, Buffer.from([0x80, 0x07]), 2, Buffer.from([0x38, 0x04]), 3, 30),
        tlv.encode(1, Buffer.from([0x00, 0x05]), 2, Buffer.from([0xd0, 0x02]), 3, 30),
        tlv.encode(1, Buffer.from([0x40, 0x01]), 2, Buffer.from([0xf0, 0x00]), 3, 15),
    ]);
    const lists = [
        ["list-pairings M2: two pairings separated by FF 00 (HAP-NodeJS HAPServer layout)", pairingList, 0xff],
        ["camera attribute list: three resolutions separated by 00 00", attributeList, 0x00],
    ].map(([name, buffer, separator]) => {
        const items = decodeItems(buffer);
        const groups = splitList(items, separator);
        if (separator === 0) {
            const hnList = [tlv.decodeWithLists(buffer)[3]].flat().map(hex);
            check(JSON.stringify(hnList) === JSON.stringify(groups.map(g => hex(g[0].value))), "00-list groups match decodeWithLists");
        }
        return { name, encoded: hex(buffer), separator, groups: groups.map(json) };
    });

    return {
        generator: generatorNote("tlv8"),
        source: `HAP-NodeJS ${version} (Apache-2.0) lib/util/tlv.ts: encode, decode, decodeWithLists`,
        notes: [
            "Values are hex. `encode`: TLV8.encode(items) must produce `encoded` exactly (values > 255 bytes split into 255-byte fragments of the same type; an empty value is `<type> 00`).",
            "`decode`: TLV8.decode(encoded) must return `items` in order. A 255-byte item followed by an item of the same type is a fragment and is merged; separator items (`00 00`, `FF 00`) are returned as ordinary empty items.",
            "`invalid`: TLV8.decode must throw TLV8Error.<error>(type) (type present only for invalidLength); HAP-NodeJS rejects every one of these inputs.",
            "`lists`: TLV8.splitList(decode(encoded), separator:) must return `groups` (empty groups dropped). Camera configuration TLVs delimit list elements with `00 00`, pairing lists with `FF 00`.",
        ],
        encode,
        decode,
        invalid,
        lists,
    };
}
