#!/usr/bin/env node
// Dev-only HAP controller oracle (plan task W1-9): pairs with an accessory using hap-controller's IP client,
// verifies, lists pairings, reads /accessories and every readable characteristic, subscribes to MotionDetected
// (every per-characteristic status must be 0) and prints events for N seconds, unsubscribes, then removes the
// pairing and checks that pair-verify is refused (kTLVError_Authentication) afterwards. A run that fails after
// pair-setup removes its own pairing on the way out (summary.cleanup).
//
//   node pair-oracle.mjs <host> <port> <setupCode> [--seconds N] [--min-events N] [--timeout-ms N]
//                        [--strict] [--expect-status TYPE=STATUS]... [--method 0|1] [--device-id LABEL] [--quiet]
//
// stdout: one JSON summary. stderr: progress. Exit 0 = every step passed, 1 = a step failed, 2 = bad usage.
import { DEFAULT_EXPECTED_STATUSES, normalizeSetupCode, runPairOracle } from "./lib/pair-oracle.mjs";

const USAGE = "usage: node pair-oracle.mjs <host> <port> <setupCode> [--seconds N] [--min-events N] [--timeout-ms N] "
    + "[--strict] [--expect-status TYPE=STATUS]... [--method 0|1] [--device-id LABEL] [--quiet]";

function usage(message) {
    process.stderr.write(`pair-oracle.mjs: ${message}\n${USAGE}\n`);
    process.exit(2);
}

function number(text, name, { min = 0, integer = false } = {}) {
    const value = Number(text);
    if (text === undefined || !Number.isFinite(value) || value < min || (integer && !Number.isInteger(value))) usage(`bad ${name}: ${text}`);
    return value;
}

function parseArguments(argv) {
    const positional = [];
    const o = { seconds: 5, minEvents: 0, timeoutMs: 15000, method: 0, deviceId: "CameraBridge-oracle-target", quiet: false,
        expectedStatuses: structuredClone(DEFAULT_EXPECTED_STATUSES) };
    for (let i = 0; i < argv.length; i++) {
        const arg = argv[i];
        switch (arg) {
        case "--seconds": o.seconds = number(argv[++i], "--seconds"); break;
        case "--min-events": o.minEvents = number(argv[++i], "--min-events", { integer: true }); break;
        case "--timeout-ms": o.timeoutMs = number(argv[++i], "--timeout-ms", { min: 100, integer: true }); break;
        case "--method": o.method = number(argv[++i], "--method", { integer: true }); if (o.method > 1) usage("--method must be 0 or 1"); break;
        case "--device-id": o.deviceId = argv[++i] ?? usage("--device-id needs a value"); break;
        case "--strict": o.expectedStatuses = {}; break;
        case "--quiet": o.quiet = true; break;
        case "--expect-status": {
            const match = /^([0-9A-Fa-f-]+)=(-?\d+)$/.exec(argv[++i] ?? "");
            if (!match) usage("--expect-status needs TYPE=STATUS, e.g. 209=-70402");
            const type = match[1].toUpperCase();
            o.expectedStatuses[type] ??= { statuses: [], reason: "--expect-status" };
            o.expectedStatuses[type].statuses.push(Number(match[2]));
            break;
        }
        case "-h": case "--help": usage("help");
        // eslint-disable-next-line no-fallthrough
        default:
            if (arg.startsWith("--")) usage(`unknown option ${arg}`);
            positional.push(arg);
        }
    }
    if (positional.length !== 3) usage("expected <host> <port> <setupCode>");
    const [host, portText, codeText] = positional;
    if (!host) usage("empty host");
    o.host = host;
    o.port = number(portText, "port", { min: 1, integer: true });
    if (o.port > 65535) usage(`bad port: ${portText}`);
    o.setupCode = normalizeSetupCode(codeText);
    if (!o.setupCode) usage("setup code must be XXX-XX-XXX or 8 digits");
    return o;
}

const options = parseArguments(process.argv.slice(2));
const log = options.quiet ? () => {} : line => process.stderr.write(`[pair-oracle] ${line}\n`);
const summary = await runPairOracle(options, log);
process.stdout.write(JSON.stringify(summary, null, 2) + "\n");
// hap-controller may leave sockets half-closed; the verdict is final.
process.exit(summary.ok ? 0 : 1);
