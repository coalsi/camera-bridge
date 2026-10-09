// Registry of golden sections written by goldens.mjs. Each section maps to one JSON fixture under
// Packages/CameraBridgeKit/Tests/<Module>Tests/Fixtures/, read by Swift tests relative to #filePath.
import path from "node:path";
import { fileURLToPath } from "node:url";

import { generateSRP } from "./srp.mjs";
import { generateTLV8 } from "./tlv8.mjs";
import { generateSetupPayload } from "./setup-payload.mjs";
import { generateHDSCodec } from "./hds-codec.mjs";
import { generateHDSFrames } from "./hds-frames.mjs";
import { generateCamera } from "./camera.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));

/** Packages/CameraBridgeKit/Tests of this checkout. */
export const defaultTestsDirectory = path.resolve(here, "..", "..", "..", "..", "Packages", "CameraBridgeKit", "Tests");

export const sections = {
    "srp": { file: "HAPCoreTests/Fixtures/srp.json", generate: generateSRP },
    "tlv8": { file: "HAPCoreTests/Fixtures/tlv8.json", generate: generateTLV8 },
    "setup-payload": { file: "HAPCoreTests/Fixtures/setup-payload.json", generate: generateSetupPayload },
    "hds-codec": { file: "HDSTests/Fixtures/hds-codec.json", generate: generateHDSCodec },
    "hds-frames": { file: "HDSTests/Fixtures/hds-frames.json", generate: generateHDSFrames },
    "camera": { file: "HAPCameraTests/Fixtures/camera-tlv.json", generate: generateCamera },
};

/** Stable text form: one-space indentation (as srp.json has always used) and a trailing newline. */
export function render(value) {
    return JSON.stringify(value, null, 1) + "\n";
}
