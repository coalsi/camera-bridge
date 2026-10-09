#!/usr/bin/env node
// HAP-NodeJS reference accessory used to prove pair-oracle.mjs works (dev-only; plan task W1-9).
// A camera (or video doorbell) with CameraBridge's v1 streaming + HKSV options and a MotionSensor whose
// MotionDetected toggles periodically, so event subscriptions have something to deliver.
//
//   node reference-accessory.mjs [--port N] [--setup-code XXX-XX-XXX] [--storage DIR] [--kind camera|doorbell]
//                                [--motion-interval-ms N] [--device-id AA:BB:CC:DD:EE:FF] [--lifetime-s N]
//                                [--fault subscribe[=STATUS] | unsubscribe[=STATUS] | close-on-unpair]...
//
// --fault makes the accessory misbehave so the oracle tests can prove the oracle notices (test use only):
//   subscribe[=STATUS]    ev:true on MotionDetected answers STATUS (HAP status -70401…-70412, default -70406
//                         NOTIFICATION_NOT_SUPPORTED) in a 207 and does not subscribe;
//   unsubscribe[=STATUS]  the same for ev:false (the subscription stays active);
//   close-on-unpair       once the last admin pairing is removed, stop accepting HAP connections (open ones stay),
//                         like an accessory that drops its listener instead of refusing pair-verify.
//
// LOOPBACK ONLY: lib/loopback-guard.mjs forces every listener onto 127.0.0.1, disables UDP and replaces the mDNS
// advertiser before HAP-NodeJS starts, so nothing is announced or reachable on the LAN. Storage defaults to a
// fresh temporary directory that is deleted on exit. stdout carries JSON lines: {"event":"ready",…},
// {"event":"paired"}, {"event":"unpaired"}; the process exits after --lifetime-s (default 900) or on SIGINT/SIGTERM.
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import { LOOPBACK, LoopbackNullAdvertiser, installLoopbackGuard } from "./lib/loopback-guard.mjs";
import { hn } from "./lib/hap-nodejs.mjs";
import { V1_OPTIONS, hapNodeJSRecordingOptions, hapNodeJSStreamingOptions } from "./lib/goldens/camera.mjs";
import { normalizeSetupCode } from "./lib/pair-oracle.mjs";

installLoopbackGuard();

const USAGE = "usage: node reference-accessory.mjs [--port N] [--setup-code XXX-XX-XXX] [--storage DIR] [--kind camera|doorbell] "
    + "[--motion-interval-ms N] [--device-id AA:BB:CC:DD:EE:FF] [--lifetime-s N] "
    + "[--fault subscribe[=STATUS]|unsubscribe[=STATUS]|close-on-unpair]...";

const HAP_STATUS_NOTIFICATION_NOT_SUPPORTED = -70406;

function usage(message) {
    process.stderr.write(`reference-accessory.mjs: ${message}\n${USAGE}\n`);
    process.exit(2);
}

function randomSetupCode() {
    for (;;) {
        const digits = String(crypto.randomInt(0, 100_000_000)).padStart(8, "0");
        const steps = [...digits].slice(1).map((d, i) => Number(d) - Number(digits[i]));
        const trivial = steps.every(s => s === 0) || steps.every(s => s === 1) || steps.every(s => s === -1);
        if (!trivial) return normalizeSetupCode(digits);
    }
}

/** "subscribe", "subscribe=-70402", "unsubscribe=…", "close-on-unpair" → { name, status? } (exit 2 otherwise). */
function parseFault(text) {
    const match = /^(subscribe|unsubscribe)(?:=(-\d+))?$/.exec(text ?? "");
    if (match) {
        const status = match[2] === undefined ? HAP_STATUS_NOTIFICATION_NOT_SUPPORTED : Number(match[2]);
        if (!Number.isInteger(status) || status < -70412 || status > -70401) usage(`--fault ${text}: STATUS must be a HAP status -70412…-70401`);
        return { name: match[1], status };
    }
    if (text === "close-on-unpair") return { name: text };
    return usage(`bad --fault: ${text}`);
}

function parseArguments(argv) {
    const o = { port: 0, setupCode: undefined, storage: undefined, kind: "camera", motionIntervalMs: 2000, deviceId: undefined, lifetimeS: 900,
        faults: {} };
    const int = (text, name) => {
        const value = Number(text);
        if (text === undefined || !Number.isInteger(value) || value < 0) usage(`bad ${name}: ${text}`);
        return value;
    };
    for (let i = 0; i < argv.length; i++) {
        const arg = argv[i];
        switch (arg) {
        case "--port": o.port = int(argv[++i], "--port"); if (o.port > 65535) usage("bad --port"); break;
        case "--setup-code": o.setupCode = normalizeSetupCode(argv[++i] ?? "") ?? usage("setup code must be XXX-XX-XXX or 8 digits"); break;
        case "--storage": o.storage = argv[++i] ?? usage("--storage needs a directory"); break;
        case "--kind": o.kind = argv[++i]; if (!["camera", "doorbell"].includes(o.kind)) usage("--kind must be camera or doorbell"); break;
        case "--motion-interval-ms": o.motionIntervalMs = int(argv[++i], "--motion-interval-ms"); break;
        case "--device-id": o.deviceId = (argv[++i] ?? "").toUpperCase(); if (!/^([0-9A-F]{2}:){5}[0-9A-F]{2}$/.test(o.deviceId)) usage("bad --device-id"); break;
        case "--lifetime-s": o.lifetimeS = int(argv[++i], "--lifetime-s"); break;
        case "--fault": { const fault = parseFault(argv[++i]); o.faults[fault.name] = fault; break; }
        default: usage(`unknown argument ${arg}`);
        }
    }
    o.setupCode ??= randomSetupCode();
    o.deviceId ??= [...crypto.randomBytes(6)].map((b, i) => (i === 0 ? (b | 0x02) & 0xfe : b).toString(16).padStart(2, "0")).join(":").toUpperCase();
    return o;
}

const emit = event => process.stdout.write(JSON.stringify(event) + "\n");
const log = line => process.stderr.write(`[reference-accessory] ${line}\n`);

const options = parseArguments(process.argv.slice(2));
const ownsStorage = options.storage === undefined;
const storage = ownsStorage ? fs.mkdtempSync(path.join(os.tmpdir(), "cb-reference-accessory-")) : path.resolve(options.storage);
fs.mkdirSync(storage, { recursive: true, mode: 0o700 });

const { hap, version } = hn();
hap.HAPStorage.setCustomStoragePath(storage);

const accessory = new hap.Accessory("CameraBridge Reference", hap.uuid.generate(`camerabridge.interop.reference.${options.deviceId}`));
accessory.getService(hap.Service.AccessoryInformation)
    .setCharacteristic(hap.Characteristic.Manufacturer, "CameraBridge Interop")
    .setCharacteristic(hap.Characteristic.Model, "HAP-NodeJS reference")
    .setCharacteristic(hap.Characteristic.SerialNumber, options.deviceId.replace(/:/g, ""))
    .setCharacteristic(hap.Characteristic.FirmwareRevision, version);

const refuse = what => (_request, callback) => callback(new Error(`reference accessory: ${what} not supported`));
const Controller = options.kind === "doorbell" ? hap.DoorbellController : hap.CameraController;
const controller = new Controller({
    cameraStreamCount: 2,
    delegate: { handleSnapshotRequest: refuse("snapshots"), prepareStream: refuse("streaming"), handleStreamRequest: refuse("streaming") },
    streamingOptions: hapNodeJSStreamingOptions(V1_OPTIONS.streaming),
    recording: {
        options: hapNodeJSRecordingOptions(V1_OPTIONS.recording),
        delegate: {
            updateRecordingActive() {},
            updateRecordingConfiguration() {},
            // eslint-disable-next-line require-yield
            async *handleRecordingStreamRequest() { throw new Error("reference accessory: recording not supported"); },
            acknowledgeStream() {},
            closeRecordingStream() {},
        },
    },
    sensors: { motion: true },
});
accessory.configureController(controller);

const faults = Object.values(options.faults).map(f => (f.status === undefined ? f.name : `${f.name}=${f.status}`));
if (options.faults.subscribe || options.faults.unsubscribe) {
    // HAP-NodeJS answers every entry of a /characteristics write through handleCharacteristicWrite; a non-zero
    // status there makes HAPServer answer 207 Multi-Status with that status for the entry.
    const handleCharacteristicWrite = accessory.handleCharacteristicWrite.bind(accessory);
    const motionUUID = hap.Characteristic.MotionDetected.UUID;
    accessory.handleCharacteristicWrite = async (connection, data, writeState) => {
        const fault = data.ev == null ? undefined : options.faults[data.ev ? "subscribe" : "unsubscribe"];
        if (fault && accessory.findCharacteristic(data.aid, data.iid)?.UUID === motionUUID) {
            log(`fault ${fault.name}: answering ev:${data.ev} on ${data.aid}.${data.iid} with ${fault.status}`);
            return { status: fault.status };
        }
        return handleCharacteristicWrite(connection, data, writeState);
    };
}

let motionTimer;
let lifetimeTimer;
let shuttingDown = false;

async function shutdown(code) {
    if (shuttingDown) return;
    shuttingDown = true;
    clearInterval(motionTimer);
    clearTimeout(lifetimeTimer);
    try { await accessory.unpublish(); } catch (error) { log(`unpublish: ${error.message}`); }
    if (ownsStorage) fs.rmSync(storage, { recursive: true, force: true });
    process.exit(code);
}

process.on("SIGINT", () => shutdown(0));
process.on("SIGTERM", () => shutdown(0));

accessory.on("paired", () => emit({ event: "paired" }));
accessory.on("unpaired", () => {
    emit({ event: "unpaired" });
    if (options.faults["close-on-unpair"]) {
        // HAP-NodeJS emits "unpaired" right after answering remove-pairing, so that answer is already on its way.
        accessory._server.httpServer.tcpServer.close();
        log("fault close-on-unpair: no longer accepting HAP connections");
    }
});
accessory.on("listening", (port, hostname) => {
    if (hostname !== LOOPBACK) {
        log(`refusing to run: HAP server bound ${hostname}, not ${LOOPBACK}`);
        shutdown(1);
        return;
    }
    if (!(accessory._advertiser instanceof LoopbackNullAdvertiser)) {
        log("refusing to run: the mDNS advertiser was not replaced");
        shutdown(1);
        return;
    }
    if (options.faults["close-on-unpair"] && typeof accessory._server?.httpServer?.tcpServer?.close !== "function") {
        log("refusing to run: --fault close-on-unpair cannot reach HAP-NodeJS's TCP server");
        shutdown(1);
        return;
    }
    emit({
        event: "ready", host: hostname, port, setupCode: options.setupCode, setupURI: accessory.setupURI(),
        deviceId: options.deviceId, category: options.kind === "doorbell" ? 18 : 17, kind: options.kind,
        storage, hapNodeJS: version, faults,
    });
    if (options.motionIntervalMs > 0) {
        const motion = controller.motionService.getCharacteristic(hap.Characteristic.MotionDetected);
        motionTimer = setInterval(() => motion.updateValue(!motion.value), options.motionIntervalMs);
    }
});

if (options.lifetimeS > 0) lifetimeTimer = setTimeout(() => { log("lifetime reached"); shutdown(0); }, options.lifetimeS * 1000);

try {
    await accessory.publish({
        username: options.deviceId,
        pincode: options.setupCode,
        category: options.kind === "doorbell" ? hap.Categories.VIDEO_DOORBELL : hap.Categories.IP_CAMERA,
        port: options.port,
        bind: [LOOPBACK],
        setupID: "CBRF",
        addIdentifyingMaterial: false,
    });
} catch (error) {
    log(`publish failed: ${error.stack ?? error}`);
    await shutdown(1);
}
