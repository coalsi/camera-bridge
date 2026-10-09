// Independent HAP controller oracle (hap-controller 0.10.2, IP transport). Runs the pairing lifecycle against an
// accessory and returns a JSON-serialisable summary. Never prints key material or the setup code.
import { hapController } from "./hap-nodejs.mjs";

const APPLE_UUID_SUFFIX = "-0000-1000-8000-0026BB765291";
const MOTION_DETECTED = "22";
const PROGRAMMABLE_SWITCH_EVENT = "73";
const TLV_ERROR_AUTHENTICATION = 2;
const CLEANUP_TIMEOUT_MS = 5000;

/** Statuses that are correct behaviour, not failures (override with --strict / --expect-status). */
export const DEFAULT_EXPECTED_STATUSES = {
    "209": { statuses: [-70402], reason: "SelectedCameraRecordingConfiguration has no value until a hub selects one (brief §3.7)" },
};

export function shortType(type) {
    const upper = String(type).toUpperCase();
    if (upper.endsWith(APPLE_UUID_SUFFIX)) return upper.slice(0, 8).replace(/^0+(?=.)/, "");
    return upper;
}

/** "03145154" or "031-45-154" → "031-45-154"; undefined when malformed. */
export function normalizeSetupCode(text) {
    const digits = /^\d{3}-\d{2}-\d{3}$/.test(text) ? text.replace(/-/g, "") : text;
    if (!/^\d{8}$/.test(digits)) return undefined;
    return `${digits.slice(0, 3)}-${digits.slice(3, 5)}-${digits.slice(5)}`;
}

const isBase64 = s => typeof s === "string" && /^[A-Za-z0-9+/]*={0,2}$/.test(s) && s.length % 4 === 0;
const isInteger = v => (typeof v === "number" && Number.isInteger(v)) || (v !== null && typeof v === "object" && typeof v.isInteger === "function" && v.isInteger());

/** Does a read value match the characteristic's declared format? */
export function valueMatchesFormat(value, format) {
    switch (format) {
    case "bool": return typeof value === "boolean" || value === 0 || value === 1;
    case "uint8": case "uint16": case "uint32": case "uint64": case "int": return isInteger(value);
    case "float": return typeof value === "number" || isInteger(value);
    case "string": return typeof value === "string";
    case "tlv8": case "data": return isBase64(value);
    default: return value !== undefined;
    }
}

function displayValue(value) {
    if (value !== null && typeof value === "object" && typeof value.toFixed === "function") return value.toFixed();
    if (typeof value === "string" && value.length > 80) return `${value.slice(0, 64)}… (${value.length} chars)`;
    return value;
}

function withTimeout(promise, ms, what) {
    let timer;
    const timeout = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`${what} timed out after ${ms} ms`)), ms); });
    return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

/**
 * What is wrong with a `PUT /characteristics` response to a write of `ids` (["aid.iid", …]); empty = all accepted.
 * HAP answers 204 when every write succeeded, otherwise 207 Multi-Status whose entries each carry a status
 * (0 = success). hap-controller only checks for 204/207, so a 207 full of per-characteristic errors would pass.
 */
export function characteristicWriteProblems(response, ids) {
    const httpStatus = response?.statusCode;
    if (httpStatus === 204) return [];
    if (httpStatus !== 207) return [`HTTP ${httpStatus}, expected 204 or 207`];
    let body;
    try { body = JSON.parse(Buffer.from(response.body ?? "").toString("utf8")); } catch { return ["207 body is not JSON"]; }
    if (!Array.isArray(body?.characteristics)) return ["207 body has no characteristics array"];
    const problems = [];
    const answered = new Set();
    for (const entry of body.characteristics) {
        const id = `${String(entry?.aid)}.${String(entry?.iid)}`;
        answered.add(id);
        if (!ids.includes(id)) { problems.push(`${id}: not in the request`); continue; }
        if (entry.status === undefined || !Number.isInteger(Number(entry.status))) problems.push(`${id}: no status`);
        else if (Number(entry.status) !== 0) problems.push(`${id}: status ${Number(entry.status)}`);
    }
    for (const id of ids) if (!answered.has(id)) problems.push(`${id}: missing from the 207 response`);
    return problems;
}

/**
 * True only when pair-verify was refused the way HAP refuses an unknown controller: kTLVError_Authentication (2)
 * in M2 or M4 (hap-controller: HomekitControllerError "M4: Error: 2" with statusCode 2). A refused connection, a
 * reset or a parse error is not proof that a pairing is gone.
 */
export function isPairVerifyRefusal(error) {
    return error?.statusCode === TLV_ERROR_AUTHENTICATION && /^M[24]: Error: 2$/.test(String(error.message));
}

/** `{"characteristics":[{aid,iid,ev}]}` for every "aid.iid". */
function eventWrite(ids, ev) {
    return Buffer.from(JSON.stringify({ characteristics: ids.map(id => { const [aid, iid] = id.split(".").map(Number); return { aid, iid, ev }; }) }));
}

/**
 * Best effort after a failed run: remove the admin pairing the run created, so the accessory is not left paired to
 * a controller whose keys were never printed. Uses a fresh client (the run's connections may be broken).
 */
async function removeLeftoverPairing(o, pairing, HttpClient, log) {
    const t0 = Date.now();
    const result = { needed: true };
    const cleaner = new HttpClient(o.deviceId, o.host, o.port, pairing, { usePersistentConnections: false });
    try {
        await withTimeout(cleaner.removePairing(pairing.iOSDevicePairingID), Math.min(o.timeoutMs, CLEANUP_TIMEOUT_MS), "cleanup removePairing");
        result.removed = true;
        log("cleanup: removed the pairing this run created");
    } catch (error) {
        if (isPairVerifyRefusal(error)) {
            result.removed = true;
            result.note = "pair-verify refused: the pairing was already gone";
        } else {
            result.removed = false;
            result.error = String(error?.message ?? error);
            log(`cleanup: could not remove the pairing this run created (${result.error}); reset the accessory before the next run`);
        }
    } finally {
        try { await cleaner.close(); } catch { /* ignore */ }
    }
    result.ms = Date.now() - t0;
    return result;
}

/**
 * @param {object} o host, port, setupCode (normalised), seconds, minEvents, timeoutMs, expectedStatuses, method, deviceId
 * @param {(line: string) => void} log progress sink (stderr in the CLI)
 */
export async function runPairOracle(o, log = () => {}) {
    const { HttpClient, HttpConnection, PairMethods, version } = hapController();
    const summary = {
        ok: false,
        oracle: { tool: "hap-controller", version, pairMethod: o.method === 1 ? "PairSetupWithAuth (1)" : "PairSetup (0)" },
        target: { host: o.host, port: o.port },
        accessory: {},
        controller: {},
        steps: [],
    };
    const client = new HttpClient(o.deviceId, o.host, o.port, undefined, { usePersistentConnections: true });
    const started = Date.now();
    let pairing;
    let removed = false;
    let subscription;       // HttpConnection that carries the MotionDetected events
    const closeSubscription = () => {
        if (!subscription) return;
        subscription.removeAllListeners("event");
        try { subscription.close(); } catch { /* ignore */ }
        subscription = undefined;
    };

    const step = async (name, body) => {
        const t0 = Date.now();
        try {
            const detail = await withTimeout(Promise.resolve().then(body), o.timeoutMs + (name === "events" ? o.seconds * 1000 : 0), name);
            summary.steps.push({ name, ok: true, ms: Date.now() - t0, ...(detail ?? {}) });
            log(`${name}: ok (${Date.now() - t0} ms)`);
        } catch (error) {
            const message = String(error?.message ?? error);
            summary.steps.push({ name, ok: false, ms: Date.now() - t0, error: message });
            summary.failedStep = name;
            summary.error = message;
            log(`${name}: FAILED — ${message}`);
            throw error;
        }
    };

    try {
        await step("pairSetup", async () => {
            await client.pairSetup(o.setupCode, o.method === 1 ? PairMethods.PairSetupWithAuth : PairMethods.PairSetup);
            pairing = client.getLongTermData();
            if (!pairing) throw new Error("pair-setup finished without long-term pairing data");
            summary.accessory.deviceId = Buffer.from(pairing.AccessoryPairingID, "hex").toString("utf8");
            summary.controller.pairingId = Buffer.from(pairing.iOSDevicePairingID, "hex").toString("utf8");
        });

        await step("pairVerify", async () => {
            // Explicit pair-verify M1–M4 on the persistent connection every later request uses.
            await client.getDefaultVerifiedConnection();
        });

        await step("listPairings", async () => {
            const tlv = await client.listPairings();
            const ids = [tlv.get(1) ?? []].flat().map(b => Buffer.from(b).toString("utf8"));
            const permissions = [tlv.get(11) ?? []].flat().map(b => Buffer.from(b)[0]);
            summary.pairings = {
                count: ids.length,
                admins: permissions.filter(p => p === 1).length,
                includesOracle: ids.includes(summary.controller.pairingId),
            };
            if (!summary.pairings.includesOracle) throw new Error("list-pairings does not contain this controller");
            if (summary.pairings.admins < 1) throw new Error("list-pairings reports no admin");
        });

        let database;
        await step("getAccessories", async () => {
            database = await client.getAccessories();
            if (!Array.isArray(database?.accessories) || database.accessories.length === 0) throw new Error("no accessories");
            let services = 0, characteristics = 0;
            for (const accessory of database.accessories) {
                if (!Array.isArray(accessory.services) || accessory.services.length === 0) throw new Error(`accessory ${accessory.aid} has no services`);
                for (const service of accessory.services) {
                    services += 1;
                    if (service.iid === undefined || !service.type || !Array.isArray(service.characteristics)) throw new Error("malformed service");
                    for (const c of service.characteristics) {
                        characteristics += 1;
                        if (c.iid === undefined || !c.type || !Array.isArray(c.perms) || !c.format) throw new Error(`malformed characteristic ${accessory.aid}.${c.iid}`);
                    }
                }
            }
            summary.accessories = {
                count: database.accessories.length,
                services,
                characteristics,
                serviceTypes: [...new Set(database.accessories.flatMap(a => a.services.map(s => shortType(s.type))))],
            };
        });

        const all = database.accessories.flatMap(a => a.services.flatMap(s => s.characteristics.map(c => ({
            id: `${String(a.aid)}.${String(c.iid)}`, type: shortType(c.type), perms: c.perms, format: c.format,
        }))));

        await step("readCharacteristics", async () => {
            const readable = all.filter(c => c.perms.includes("pr"));
            const byId = new Map(readable.map(c => [c.id, c]));
            const results = [];
            for (let i = 0; i < readable.length; i += 40) {
                const ids = readable.slice(i, i + 40).map(c => c.id);
                const response = await client.getCharacteristics(ids, { meta: true, perms: true, type: true, ev: true });
                results.push(...(response?.characteristics ?? []));
            }
            const reads = { readable: readable.length, ok: 0, failed: 0, expectedErrors: [], failures: [], characteristics: [] };
            const seen = new Set();
            for (const r of results) {
                const id = `${String(r.aid)}.${String(r.iid)}`;
                const declared = byId.get(id);
                seen.add(id);
                const status = r.status === undefined ? 0 : Number(r.status);
                const entry = { id, type: declared?.type ?? shortType(r.type ?? "?"), format: declared?.format, status, value: displayValue(r.value) };
                reads.characteristics.push(entry);
                if (!declared) { reads.failed += 1; reads.failures.push({ ...entry, reason: "not requested" }); continue; }
                if (status !== 0) {
                    const expected = o.expectedStatuses[declared.type];
                    if (expected?.statuses.includes(status)) reads.expectedErrors.push({ id, type: declared.type, status, reason: expected.reason });
                    else { reads.failed += 1; reads.failures.push({ ...entry, reason: `status ${status}` }); }
                    continue;
                }
                const nullAllowed = declared.type === PROGRAMMABLE_SWITCH_EVENT;
                if ((r.value === null && !nullAllowed) || (r.value !== null && !valueMatchesFormat(r.value, declared.format))) {
                    reads.failed += 1;
                    reads.failures.push({ ...entry, reason: `value does not match format ${declared.format}` });
                    continue;
                }
                reads.ok += 1;
            }
            for (const c of readable) {
                if (!seen.has(c.id)) { reads.failed += 1; reads.failures.push({ id: c.id, type: c.type, reason: "missing from response" }); }
            }
            summary.reads = reads;
            if (reads.failed > 0) throw new Error(`${reads.failed} characteristic read(s) failed: ${JSON.stringify(reads.failures.slice(0, 5))}`);
        });

        const motionIds = all.filter(c => c.type === MOTION_DETECTED && c.perms.includes("ev")).map(c => c.id);
        summary.motion = { characteristics: motionIds };
        summary.events = [];
        let malformedEvents = 0;
        const onEvent = raw => {
            let payload;
            try { payload = JSON.parse(Buffer.from(raw).toString("utf8")); } catch { malformedEvents += 1; log("event: body is not JSON"); return; }
            for (const c of payload?.characteristics ?? []) {
                const id = `${String(c.aid)}.${String(c.iid)}`;
                if (!motionIds.includes(id)) continue;
                const event = { atMs: Date.now() - started, id, value: displayValue(c.value) };
                summary.events.push(event);
                log(`event ${id} MotionDetected = ${JSON.stringify(event.value)}`);
            }
        };

        // The ev writes go over a pair-verified connection of the oracle's own (the connection hap-controller's
        // subscribeCharacteristics() would open): that method returns neither the HTTP status nor, reliably, the
        // per-characteristic statuses, and an accessory answering 207 with -70406/-70402 must fail the run.
        await step("subscribeMotion", async () => {
            if (motionIds.length === 0) throw new Error("the accessory has no MotionDetected characteristic with events");
            subscription = new HttpConnection(o.host, o.port);
            subscription.setSessionKeys(await client._pairVerify(subscription));
            subscription.on("event", onEvent);
            const response = await subscription.put("/characteristics", eventWrite(motionIds, true), "application/hap+json", true);
            const problems = characteristicWriteProblems(response, motionIds);
            if (problems.length > 0) throw new Error(`ev:true on MotionDetected was not accepted: ${problems.join("; ")}`);
            return { status: response.statusCode };
        });

        await step("events", async () => {
            await sleep(o.seconds * 1000);
            const count = summary.events.length;
            if (malformedEvents > 0) throw new Error(`${malformedEvents} EVENT message(s) with a body that is not JSON`);
            if (count < o.minEvents) throw new Error(`received ${count} MotionDetected event(s) in ${o.seconds} s, expected at least ${o.minEvents}`);
            return { received: count };
        });

        await step("unsubscribeMotion", async () => {
            // (hap-controller 0.10.2's unsubscribeCharacteristics() would skip every subscribed id: inverted check.)
            if (!subscription) throw new Error("subscription connection is gone");
            const response = await subscription.put("/characteristics", eventWrite(motionIds, false), "application/hap+json", false);
            const problems = characteristicWriteProblems(response, motionIds);
            if (problems.length > 0) throw new Error(`ev:false on MotionDetected was not accepted: ${problems.join("; ")}`);
            closeSubscription();
            return { status: response.statusCode };
        });

        await step("removePairing", async () => {
            await client.removePairing(pairing.iOSDevicePairingID);
            removed = true;
        });

        await step("verifyRemoved", async () => {
            const stale = new HttpClient(o.deviceId, o.host, o.port, pairing, { usePersistentConnections: false });
            const connection = new HttpConnection(o.host, o.port);
            let refusal;
            try {
                await stale._pairVerify(connection);
            } catch (error) {
                const message = String(error?.message ?? error);
                if (!isPairVerifyRefusal(error)) {
                    throw new Error(`pair-verify with the removed pairing failed, but not with kTLVError_Authentication (2): ${message}`);
                }
                refusal = message;
            } finally {
                connection.close();
                await stale.close();
            }
            if (refusal === undefined) throw new Error("pair-verify with the removed pairing still succeeds");
            return { rejected: refusal };
        });

        summary.ok = true;
    } catch {
        summary.ok = false;
    } finally {
        closeSubscription();
        try { await client.close(); } catch { /* ignore */ }
        // A failed run must not leave the accessory paired to this throwaway controller (its keys are never printed).
        summary.cleanup = pairing && !removed ? await removeLeftoverPairing(o, pairing, HttpClient, log) : { needed: false };
        summary.durationMs = Date.now() - started;
    }
    return summary;
}
