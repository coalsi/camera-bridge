// Keeps a HAP-NodeJS process off the LAN (dev-only). Once installed, in this process:
//  - every TCP listener binds 127.0.0.1, whatever host HAP-NodeJS asks for (with `bind: ["127.0.0.1"]` it would
//    still listen on 0.0.0.0 — "so config-ui always has a connection via loopback" — and its DataStreamServer
//    always listens on all interfaces);
//  - UDP sockets cannot be created, so no mDNS packet (ciao / bonjour-hap) and no RTP can leave the process;
//  - HAP-NodeJS's mDNS advertisers are replaced by a no-op, so publish() never announces `_hap._tcp`.
// A real iPhone must never see a test accessory (task rules), so this fails closed.
import dgram from "node:dgram";
import { EventEmitter } from "node:events";
import { syncBuiltinESMExports } from "node:module";
import net from "node:net";

import { hn } from "./hap-nodejs.mjs";

export const LOOPBACK = "127.0.0.1";

let installed = false;

/** Rewrites any net.Server#listen argument form to an options object bound to 127.0.0.1. */
export function loopbackListenArguments(args) {
    const callback = typeof args[args.length - 1] === "function" ? args[args.length - 1] : undefined;
    const rest = callback ? args.slice(0, -1) : args.slice();
    const first = rest[0];
    let options;
    if (first !== null && typeof first === "object") {
        if (first.path !== undefined) return args;                      // IPC (Unix socket): never on the network
        if (first._handle !== undefined || first.fd !== undefined || typeof first.listen === "function") {
            throw new Error("loopback guard: listening on an existing handle / fd is not allowed");
        }
        options = { ...first };
    } else if (typeof first === "string" && !/^\d+$/.test(first)) {
        return args;                                                    // IPC path
    } else {
        options = { port: first === undefined || first === null ? 0 : Number(first) };
        for (const extra of rest.slice(1)) {
            if (typeof extra === "number") options.backlog = extra;      // listen(port[, host][, backlog])
        }
    }
    options.host = LOOPBACK;
    delete options.ipv6Only;
    return callback ? [options, callback] : [options];
}

/** Stands in for CiaoAdvertiser / BonjourHAPAdvertiser / AvahiAdvertiser / ResolvedAdvertiser. */
class LoopbackNullAdvertiser extends EventEmitter {
    static protocolVersion = "1.1";
    static protocolVersionService = "1.1.0";
    static original;
    static async isAvailable() { return false; }
    static computeSetupHash(accessoryInfo) { return LoopbackNullAdvertiser.original.computeSetupHash(accessoryInfo); }
    static createTxt(accessoryInfo, setupHash) { return LoopbackNullAdvertiser.original.createTxt(accessoryInfo, setupHash); }
    constructor(accessoryInfo) {
        super();
        this.accessoryInfo = accessoryInfo;
        this.port = undefined;
    }
    initPort(port) { this.port = port; }
    async startAdvertising() {}
    updateAdvertisement() {}
    async destroy() { this.removeAllListeners(); }
}

export function installLoopbackGuard() {
    if (installed) return;
    installed = true;

    const originalListen = net.Server.prototype.listen;
    net.Server.prototype.listen = function loopbackListen(...args) {
        return originalListen.apply(this, loopbackListenArguments(args));
    };

    dgram.createSocket = function refuseUDP() {
        throw new Error("loopback guard: UDP sockets are disabled in this process (no mDNS advertising, no RTP)");
    };
    syncBuiltinESMExports();

    const { Advertiser } = hn();
    LoopbackNullAdvertiser.original = Advertiser.CiaoAdvertiser;
    for (const name of ["CiaoAdvertiser", "BonjourHAPAdvertiser", "AvahiAdvertiser", "ResolvedAdvertiser"]) {
        Advertiser[name] = LoopbackNullAdvertiser;
        if (Advertiser[name] !== LoopbackNullAdvertiser) throw new Error(`loopback guard: could not replace HAP-NodeJS ${name}`);
    }
}

export { LoopbackNullAdvertiser };
