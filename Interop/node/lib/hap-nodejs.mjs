// Loaders for the pinned oracle packages (CommonJS) from ES modules.
// HAP-NodeJS internals are reached through their dist paths; the package has no "exports" map, and the
// versions are pinned in package.json / package-lock.json, so these paths are stable.
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);

let cached;

/** HAP-NodeJS 2.2.3 (Apache-2.0) modules used by the oracles. */
export function hn() {
    if (cached) return cached;
    const dist = "@homebridge/hap-nodejs/dist/lib/";
    cached = {
        version: require("@homebridge/hap-nodejs/package.json").version,
        hap: require("@homebridge/hap-nodejs"),
        tlv: require(dist + "util/tlv.js"),
        hapCrypto: require(dist + "util/hapCrypto.js"),
        datastream: require(dist + "datastream/DataStreamParser.js"),
        Advertiser: require(dist + "Advertiser.js"),
        RTPStreamManagement: require(dist + "camera/RTPStreamManagement.js").RTPStreamManagement,
        RecordingManagement: require(dist + "camera/RecordingManagement.js").RecordingManagement,
    };
    return cached;
}

/** fast-srp-hap 2.0.4 (MIT), the SRP implementation HAP-NodeJS uses. */
export function fastSRP() {
    const srp = require("fast-srp-hap");
    return { ...srp, version: require("fast-srp-hap/package.json").version };
}

/**
 * hap-controller 0.10.2 (MPL-2.0) IP transport only. The package index also loads the BLE transport
 * (noble), which would touch Bluetooth; the IP client is required directly instead.
 */
export function hapController() {
    const lib = "hap-controller/lib/";
    return {
        version: require("hap-controller/package.json").version,
        HttpClient: require(lib + "transport/ip/http-client.js").default,
        HttpConnection: require(lib + "transport/ip/http-connection.js").default,
        PairMethods: require(lib + "protocol/pairing-protocol.js").PairMethods,
        HomekitControllerError: require(lib + "model/error.js").default,
    };
}
