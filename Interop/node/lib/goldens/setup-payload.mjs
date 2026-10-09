// Setup payload goldens: X-HM:// setup URIs from HAP-NodeJS Accessory.setupURI() and TXT `sh` setup hashes
// from HAP-NodeJS CiaoAdvertiser.computeSetupHash(), each cross-checked with the brief §3.3 formula.
import crypto from "node:crypto";

import { hn } from "../hap-nodejs.mjs";
import { check, generatorNote } from "./util.mjs";

const CODES = ["031-45-154", "482-73-619", "101-48-005", "990-01-287", "274-60-139"];
const CATEGORIES = [1, 2, 10, 17, 18];
const SETUP_IDS = ["7OSX", "CB01", "ZZ9Z"];
const DEVICE_IDS = ["CC:22:3D:E3:CE:F3", "0E:5A:21:B7:9C:44", "A0:00:00:00:00:01", "FF:FF:FF:FF:FF:FE"];

function hapNodeJSSetupURI(code, setupID, category) {
    const { hap } = hn();
    const accessory = new hap.Accessory("Setup URI golden", hap.uuid.generate(`camerabridge.golden.setupuri.${code}.${setupID}.${category}`));
    // setupURI() only reads the pincode/category of the (normally published) AccessoryInfo and the setup ID.
    accessory._accessoryInfo = { pincode: code, category };
    accessory._setupID = setupID;
    return accessory.setupURI();
}

/** Research brief §3.3: low32 = code | 1<<28 | (category & 1)<<31, high32 = category >> 1, base-36, 9 chars. */
function briefSetupURI(code, setupID, category) {
    const low = BigInt(parseInt(code.replace(/-/g, ""), 10)) | (1n << 28n) | (BigInt(category & 1) << 31n);
    const high = BigInt(category >> 1);
    const payload = ((high << 32n) | low).toString(36).toUpperCase().padStart(9, "0");
    return `X-HM://${payload}${setupID}`;
}

export function generateSetupPayload() {
    const { Advertiser, version } = hn();
    const uris = [];
    for (const setupID of SETUP_IDS) {
        for (const code of CODES) {
            if (setupID !== "7OSX" && code !== CODES[0] && code !== CODES[1]) continue;
            for (const category of CATEGORIES) {
                const uri = hapNodeJSSetupURI(code, setupID, category);
                check(uri === briefSetupURI(code, setupID, category), `setup URI formula for ${code}/${setupID}/${category}`);
                uris.push({ code, setupID, category, uri });
            }
        }
    }
    const setupHashes = [];
    for (const setupID of SETUP_IDS) {
        for (const deviceID of DEVICE_IDS) {
            const hash = Advertiser.CiaoAdvertiser.computeSetupHash({ setupID, username: deviceID });
            const expected = crypto.createHash("sha512").update(setupID + deviceID.toUpperCase()).digest().subarray(0, 4).toString("base64");
            check(hash === expected, `setup hash formula for ${setupID}/${deviceID}`);
            setupHashes.push({ setupID, deviceID, hash });
        }
    }
    return {
        generator: generatorNote("setup-payload"),
        source: `HAP-NodeJS ${version} (Apache-2.0): Accessory.setupURI(), CiaoAdvertiser.computeSetupHash(); cross-checked with research brief §3.3`,
        notes: [
            "`uris`: SetupPayload.uri(code: SetupCode(code), setupID:, category: AccessoryCategory(rawValue: category)) must equal `uri`.",
            "`setupHashes`: SetupPayload.setupHash(setupID:, deviceID: DeviceID(deviceID)) must equal `hash` (base64 of SHA-512(setupID + uppercase device ID)[0..<4]).",
        ],
        uris,
        setupHashes,
    };
}
