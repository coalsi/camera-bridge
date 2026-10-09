// Shared helpers for the oracle tests (not a test file: npm test runs test/*.test.mjs only).
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
export const accessoryScript = path.join(here, "..", "reference-accessory.mjs");
export const oracleScript = path.join(here, "..", "pair-oracle.mjs");
export const SETUP_CODE = "482-73-619";

/**
 * Returns a stream `data` handler that calls `onObject` once per complete JSON line. A line split across chunks is
 * held until its newline arrives; lines that are not JSON objects are skipped (never thrown from the listener).
 */
export function jsonLineSplitter(onObject) {
    let carry = "";
    return chunk => {
        carry += chunk;
        const lines = carry.split("\n");
        carry = lines.pop();
        for (const line of lines) {
            if (!line.startsWith("{")) continue;
            let value;
            try { value = JSON.parse(line); } catch { continue; }
            onObject(value);
        }
    };
}

/**
 * Starts reference-accessory.mjs on 127.0.0.1 (port 0) with throwaway storage and waits for its `ready` line.
 * @returns {Promise<{child, ready, events: object[], stdout: () => string, stop: () => void}>}
 */
export function startReferenceAccessory(extraArgs = [], { setupCode = SETUP_CODE, readyTimeoutMs = 20_000 } = {}) {
    const storage = fs.mkdtempSync(path.join(os.tmpdir(), "cb-reference-accessory-"));
    const child = spawn(process.execPath, [accessoryScript, "--port", "0", "--setup-code", setupCode, "--storage", storage,
        "--lifetime-s", "120", ...extraArgs], { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    const events = [];
    const stop = () => {
        child.kill("SIGTERM");
        fs.rmSync(storage, { recursive: true, force: true });
    };
    child.stderr.on("data", () => {});
    return new Promise((resolve, reject) => {
        const fail = error => { clearTimeout(timer); stop(); reject(error); };
        const timer = setTimeout(() => fail(new Error(`reference accessory did not become ready: ${stdout}`)), readyTimeoutMs);
        const split = jsonLineSplitter(event => {
            events.push(event);
            if (event.event === "ready") {
                clearTimeout(timer);
                resolve({ child, ready: event, events, stdout: () => stdout, stop });
            }
        });
        child.stdout.setEncoding("utf8");
        child.stdout.on("data", chunk => { stdout += chunk; split(chunk); });
        child.on("exit", code => fail(new Error(`reference accessory exited early (${code}): ${stdout}`)));
    });
}

/** Runs pair-oracle.mjs; resolves with its exit status, raw output and parsed JSON summary. */
export function runOracle(args, timeoutMs = 60_000) {
    return new Promise(resolve => {
        const child = spawn(process.execPath, [oracleScript, ...args], { stdio: ["ignore", "pipe", "pipe"] });
        let stdout = "", stderr = "";
        child.stdout.on("data", c => { stdout += c; });
        child.stderr.on("data", c => { stderr += c; });
        const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
        child.on("exit", status => {
            clearTimeout(timer);
            let summary;
            try { summary = JSON.parse(stdout); } catch { summary = undefined; }
            resolve({ status, stdout, stderr, summary });
        });
    });
}

/** Resolves when `predicate(events)` holds, or rejects after `timeoutMs`. */
export async function waitForEvent(accessory, predicate, timeoutMs = 5000) {
    const deadline = Date.now() + timeoutMs;
    while (!predicate(accessory.events)) {
        if (Date.now() > deadline) throw new Error(`accessory event not seen: ${accessory.stdout()}`);
        await new Promise(r => setTimeout(r, 25));
    }
}
