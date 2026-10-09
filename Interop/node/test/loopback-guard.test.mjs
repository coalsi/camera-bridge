// The guard reference-accessory.mjs installs before loading HAP-NodeJS: every TCP listener binds 127.0.0.1,
// UDP sockets (mDNS, RTP) cannot be created, and HAP-NodeJS's mDNS advertiser is replaced by a no-op.
// node --test runs each file in its own process, so patching globals here is contained.
import { test } from "node:test";
import assert from "node:assert/strict";
import dgram from "node:dgram";
import http from "node:http";
import net from "node:net";
import { createSocket } from "node:dgram";

import { installLoopbackGuard, LOOPBACK } from "../lib/loopback-guard.mjs";

installLoopbackGuard();

async function boundAddress(server, ...args) {
    await new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(...args, resolve);
    });
    const address = server.address();
    await new Promise(r => server.close(r));
    return address;
}

test("every listen form binds 127.0.0.1", async () => {
    assert.equal(LOOPBACK, "127.0.0.1");
    assert.equal((await boundAddress(net.createServer(), 0)).address, "127.0.0.1");
    assert.equal((await boundAddress(net.createServer(), 0, "0.0.0.0")).address, "127.0.0.1");
    assert.equal((await boundAddress(net.createServer(), 0, "::")).address, "127.0.0.1");
    assert.equal((await boundAddress(net.createServer(), { port: 0, host: "::", ipv6Only: true })).address, "127.0.0.1");
    assert.equal((await boundAddress(net.createServer(), { port: 0 })).address, "127.0.0.1");
    assert.equal((await boundAddress(net.createServer(), 0, 16)).address, "127.0.0.1");
    assert.equal((await boundAddress(http.createServer(), 0)).address, "127.0.0.1");
    // callback-only form
    const server = net.createServer();
    await new Promise(r => server.listen(r));
    assert.equal(server.address().address, "127.0.0.1");
    await new Promise(r => server.close(r));
});

test("UDP sockets cannot be created", () => {
    assert.throws(() => dgram.createSocket("udp4"), /loopback guard/);
    assert.throws(() => dgram.createSocket({ type: "udp6", reuseAddr: true }), /loopback guard/);
    assert.throws(() => createSocket("udp4"), /loopback guard/);
});

test("HAP-NodeJS's mDNS advertiser is a no-op after the guard", async () => {
    const { hn } = await import("../lib/hap-nodejs.mjs");
    const { Advertiser } = hn();
    assert.equal(Advertiser.CiaoAdvertiser.name, "LoopbackNullAdvertiser");
    assert.equal(Advertiser.BonjourHAPAdvertiser.name, "LoopbackNullAdvertiser");
    const advertiser = new Advertiser.CiaoAdvertiser({}, {}, {});
    advertiser.initPort(1234);
    await advertiser.startAdvertising();
    advertiser.updateAdvertisement();
    await advertiser.destroy();
    assert.equal(Advertiser.CiaoAdvertiser.protocolVersionService, "1.1.0");
});
