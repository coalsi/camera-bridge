// Small helpers shared by the golden generators.
import crypto from "node:crypto";

export const hex = buffer => Buffer.from(buffer).toString("hex");

/** SHA-256 of a label: deterministic "random-looking" bytes for fixture inputs. */
export const sha256 = label => crypto.createHash("sha256").update(label, "utf8").digest();

/** `length` deterministic bytes derived from `label` (SHA-256 counter mode). */
export function bytes(label, length) {
    const chunks = [];
    for (let i = 0; chunks.length * 32 < length; i++) chunks.push(sha256(`${label}#${i}`));
    return Buffer.concat(chunks).subarray(0, length);
}

export function generatorNote(section) {
    return `Interop/node/goldens.mjs ${section} (plan task W1-9). Do not edit by hand; regenerate with: cd Interop/node && npm ci && node goldens.mjs ${section}`;
}

export function check(condition, message) {
    if (!condition) throw new Error(`golden self-check failed: ${message}`);
}
