// Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0. Modified for CameraBridge.
//
// HDS message / frame goldens: payloads `[header length u8][header][message]` and headers exactly as
// HAP-NodeJS's DataStreamConnection builds them (sendEvent / sendRequest / sendResponse: `id` and `status` are
// Int64-wrapped), session keys from DataStreamServer.prepareSession (HKDF-SHA512, salt = controllerKeySalt ‖
// accessoryKeySalt), and encrypted frames as sendHDSFrame seals them (ChaCha20-Poly1305, AAD = 4-byte frame
// header, nonce = 4 zero bytes ‖ LE64(counter)).
import crypto from "node:crypto";

import { hn } from "../hap-nodejs.mjs";
import { V, encodeCanonical, decodeHDS, toHAPNodeJS, toJSONValue, valuesEqual } from "./hds-values.mjs";
import { bytes, check, generatorNote, hex, sha256 } from "./util.mjs";

const dataEvent = ({ streamId, data, dataType, dataSequenceNumber, dataChunkSequenceNumber, isLastDataChunk, dataTotalSize, endOfStream }) => {
    const metadata = [
        ["dataType", V.string(dataType)],
        ["dataSequenceNumber", V.int(dataSequenceNumber)],
        ["dataChunkSequenceNumber", V.int(dataChunkSequenceNumber)],
        ["isLastDataChunk", V.bool(isLastDataChunk)],
    ];
    if (dataTotalSize !== undefined) metadata.push(["dataTotalSize", V.int(dataTotalSize)]);
    const body = [
        ["streamId", V.int(streamId)],
        ["packets", V.array([V.dict([["data", V.data(data)], ["metadata", V.dict(metadata)]])])],
    ];
    if (endOfStream !== undefined) body.push(["endOfStream", V.bool(endOfStream)]);
    return V.dict(body);
};

const MESSAGES = [
    { name: "control hello request", direction: "controllerToAccessory", kind: "request", protocol: "control", topic: "hello", id: 1, body: V.dict([]) },
    { name: "control hello response", direction: "accessoryToController", kind: "response", protocol: "control", topic: "hello", id: 1234, status: 0, body: V.dict([]) },
    {
        name: "dataSend open request", direction: "controllerToAccessory", kind: "request", protocol: "dataSend", topic: "open", id: 7,
        body: V.dict([["target", V.string("controller")], ["type", V.string("ipcamera.recording")], ["streamId", V.int(1)]]),
    },
    { name: "dataSend open response (accepted)", direction: "accessoryToController", kind: "response", protocol: "dataSend", topic: "open", id: 7, status: 0, body: V.dict([["status", V.int(0)]]) },
    { name: "dataSend open response (busy)", direction: "accessoryToController", kind: "response", protocol: "dataSend", topic: "open", id: 7, status: 6, body: V.dict([["status", V.int(2)]]) },
    {
        name: "dataSend data event (initialization chunk)", direction: "accessoryToController", kind: "event", protocol: "dataSend", topic: "data",
        body: dataEvent({ streamId: 1, data: bytes("hds init segment", 48), dataType: "mediaInitialization", dataSequenceNumber: 1, dataChunkSequenceNumber: 1, isLastDataChunk: true, dataTotalSize: 48, endOfStream: false }),
    },
    {
        name: "dataSend data event (first chunk of a split fragment)", direction: "accessoryToController", kind: "event", protocol: "dataSend", topic: "data",
        body: dataEvent({ streamId: 1, data: bytes("hds fragment chunk 1", 300), dataType: "mediaFragment", dataSequenceNumber: 2, dataChunkSequenceNumber: 1, isLastDataChunk: false, dataTotalSize: 600 }),
    },
    {
        name: "dataSend data event (last chunk, end of stream)", direction: "accessoryToController", kind: "event", protocol: "dataSend", topic: "data",
        body: dataEvent({ streamId: 1, data: bytes("hds fragment chunk 2", 300), dataType: "mediaFragment", dataSequenceNumber: 2, dataChunkSequenceNumber: 2, isLastDataChunk: true, endOfStream: true }),
    },
    { name: "dataSend ack event", direction: "controllerToAccessory", kind: "event", protocol: "dataSend", topic: "ack", body: V.dict([["streamId", V.int(1)], ["endOfStream", V.bool(true)]]) },
    { name: "dataSend close event", direction: "accessoryToController", kind: "event", protocol: "dataSend", topic: "close", body: V.dict([["streamId", V.int(1)], ["reason", V.int(0)]]) },
];

function typedHeader(m) {
    const pairs = [["protocol", V.string(m.protocol)]];
    if (m.kind === "event") pairs.push(["event", V.string(m.topic)]);
    if (m.kind === "request") pairs.push(["request", V.string(m.topic)], ["id", V.int64(m.id)]);
    if (m.kind === "response") pairs.push(["response", V.string(m.topic)], ["id", V.int64(m.id)], ["status", V.int64(m.status)]);
    return V.dict(pairs);
}

/** HAP-NodeJS DataStreamConnection header object (sendEvent / sendRequest / sendResponse). */
function hapNodeJSHeader(m) {
    const { Int64 } = hn().datastream;
    const header = {};
    header.protocol = m.protocol;
    if (m.kind === "event") header.event = m.topic;
    if (m.kind === "request") { header.request = m.topic; header.id = new Int64(m.id); }
    if (m.kind === "response") { header.response = m.topic; header.id = new Int64(m.id); header.status = new Int64(m.status); }
    return header;
}

/** As DataStreamConnection.sendHDSFrame assembles the plaintext payload. */
function hapNodeJSPayload(m) {
    const { DataStreamParser, DataStreamWriter } = hn().datastream;
    const headerWriter = new DataStreamWriter();
    const messageWriter = new DataStreamWriter();
    DataStreamParser.encode(hapNodeJSHeader(m), headerWriter);
    DataStreamParser.encode(toHAPNodeJS(m.body), messageWriter);
    const length = Buffer.alloc(1);
    length.writeUInt8(headerWriter.length(), 0);
    return { header: Buffer.from(headerWriter.getData()), payload: Buffer.concat([length, headerWriter.getData(), messageWriter.getData()]) };
}

/** As DataStreamConnection.sendHDSFrame seals a payload. */
function hapNodeJSFrame(payload, key, counter) {
    const { hapCrypto } = hn();
    const frameHeader = Buffer.alloc(4);
    frameHeader.writeUInt32BE(payload.length, 0);
    frameHeader[0] = 1;
    const nonce = Buffer.alloc(8);
    hapCrypto.writeUInt64LE(counter, nonce);
    const sealed = hapCrypto.chacha20_poly1305_encryptAndSeal(key, nonce, frameHeader, payload);
    return Buffer.concat([frameHeader, sealed.ciphertext, sealed.authTag]);
}

/** Independent open with node:crypto (12-byte nonce = 4 zero bytes ‖ LE64(counter)). */
function openFrame(frame, key, counter) {
    const nonce = Buffer.alloc(12);
    nonce.writeBigUInt64LE(BigInt(counter), 4);
    const header = frame.subarray(0, 4);
    const length = frame.readUIntBE(1, 3);
    const decipher = crypto.createDecipheriv("chacha20-poly1305", key, nonce, { authTagLength: 16 });
    decipher.setAAD(header, { plaintextLength: length });
    decipher.setAuthTag(frame.subarray(4 + length, 4 + length + 16));
    return Buffer.concat([decipher.update(frame.subarray(4, 4 + length)), decipher.final()]);
}

function deriveKeys(name, sharedSecret, controllerKeySalt, accessoryKeySalt) {
    const { hapCrypto } = hn();
    const salt = Buffer.concat([controllerKeySalt, accessoryKeySalt]);
    const accessoryToController = hapCrypto.HKDF("sha512", salt, sharedSecret, Buffer.from("HDS-Read-Encryption-Key"), 32);
    const controllerToAccessory = hapCrypto.HKDF("sha512", salt, sharedSecret, Buffer.from("HDS-Write-Encryption-Key"), 32);
    const independent = info => Buffer.from(crypto.hkdfSync("sha512", sharedSecret, salt, Buffer.from(info), 32));
    check(accessoryToController.equals(independent("HDS-Read-Encryption-Key")), "HKDF read key (node:crypto)");
    check(controllerToAccessory.equals(independent("HDS-Write-Encryption-Key")), "HKDF write key (node:crypto)");
    return { name, sharedSecret, controllerKeySalt, accessoryKeySalt, accessoryToController, controllerToAccessory };
}

export function generateHDSFrames() {
    const { version } = hn();
    const messages = MESSAGES.map(m => {
        const { header, payload } = hapNodeJSPayload(m);
        const canonical = Buffer.concat([Buffer.from([encodeCanonical(typedHeader(m)).length]), encodeCanonical(typedHeader(m)), encodeCanonical(m.body)]);
        check(canonical.equals(payload), `${m.name}: HAP-NodeJS payload equals the canonical encoding`);
        check(valuesEqual(decodeHDS(header), typedHeader(m)), `${m.name}: header decodes`);
        const message = { kind: m.kind, protocol: m.protocol, topic: m.topic };
        if (m.id !== undefined) message.id = m.id;
        if (m.status !== undefined) message.status = m.status;
        message.body = toJSONValue(m.body);
        return { name: m.name, direction: m.direction, message, header: hex(header), payload: hex(payload) };
    });

    const keySets = [
        deriveKeys("session 1", sha256("CameraBridge HDS golden shared secret 1"), sha256("CameraBridge HDS golden controller salt 1"), sha256("CameraBridge HDS golden accessory salt 1")),
        deriveKeys("session 2", sha256("CameraBridge HDS golden shared secret 2"), sha256("CameraBridge HDS golden controller salt 2"), sha256("CameraBridge HDS golden accessory salt 2")),
    ];
    const keys = keySets.map(k => ({
        name: k.name,
        sharedSecret: hex(k.sharedSecret),
        controllerKeySalt: hex(k.controllerKeySalt),
        accessoryKeySalt: hex(k.accessoryKeySalt),
        accessoryToControllerKey: hex(k.accessoryToController),
        controllerToAccessoryKey: hex(k.controllerToAccessory),
    }));

    const payloadOf = name => Buffer.from(messages.find(m => m.name === name).payload, "hex");
    const frameCases = [
        ["control hello request", 0],
        ["control hello response", 0],
        ["dataSend open request", 1],
        ["dataSend open response (accepted)", 1],
        ["dataSend data event (initialization chunk)", 2],
        ["dataSend close event", 4294967303],
    ];
    const frames = frameCases.map(([messageName, counter]) => {
        const direction = messages.find(m => m.name === messageName).direction;
        const key = direction === "accessoryToController" ? keySets[0].accessoryToController : keySets[0].controllerToAccessory;
        const payload = payloadOf(messageName);
        const frame = hapNodeJSFrame(payload, key, counter);
        check(openFrame(frame, key, counter).equals(payload), `${messageName}: frame opens with node:crypto`);
        return { name: `${messageName} #${counter}`, message: messageName, direction, keySet: "session 1", key: hex(key), counter, payload: hex(payload), frame: hex(frame) };
    });

    return {
        generator: generatorNote("hds-frames"),
        source: `HAP-NodeJS ${version} (Apache-2.0) lib/datastream/DataStreamServer.ts (prepareSession, sendEvent/sendRequest/sendResponse, sendHDSFrame), research brief §3.8`,
        notes: [
            "`messages`: HDSFrameCodec.encodePayload(HDSMessage(kind, protocolName: protocol, topic, body)) must equal `payload`, and decodePayload(payload) must return that message. `header` is the encoded header dictionary (payload = [header length u8][header][body]).",
            "Header dictionaries: event {protocol, event}; request {protocol, request, id}; response {protocol, response, id, status}, in that order. `id` and `status` are always written as int64 (tag 0x33), as HAP-NodeJS does (brief §3.8 hello-response golden); body values use the canonical forms of hds-codec.json.",
            "Body value JSON is the hds-codec.json value form. `direction` says who sends the message; the dataSend data events mirror HAP-NodeJS RecordingManagement (dataTotalSize only on chunk 1, endOfStream false on the last chunk of a non-final fragment, omitted on other chunks).",
            "`keys`: HDSFrameCodec.deriveKeys(sharedSecret:controllerKeySalt:accessoryKeySalt:) must return (accessoryToController: accessoryToControllerKey [info HDS-Read-Encryption-Key], controllerToAccessory: controllerToAccessoryKey [info HDS-Write-Encryption-Key]); HKDF-SHA512, salt = controllerKeySalt ‖ accessoryKeySalt, 32-byte keys.",
            "`frames`: HDSFrameCodec.sealFrame(payload, key:, counter:) must equal `frame` ([0x01][payload length u24 BE][ciphertext][16-byte tag]; AAD = the 4-byte header; nonce = 4 zero bytes ‖ LE64(counter)), and openFrame(header: frame[0..<4], body: frame[4...], key:, counter:) must return `payload`.",
        ],
        messages,
        keys,
        frames,
    };
}
