// SRP-6a goldens (3072-bit group, g = 5, SHA-512 — the HAP parameters) computed with fast-srp-hap, the SRP
// implementation HAP-NodeJS uses. Output format is fixed by Tests/HAPCoreTests/SRPTests.swift (`SRPVector`).
import { fastSRP } from "../hap-nodejs.mjs";
import { check, hex, sha256 } from "./util.mjs";

const fromHex = s => Buffer.from(s.replace(/\s+/g, ""), "hex");

// RFC 5054 Appendix B test inputs (salt, a, b); the RFC's own vector uses a 1024-bit group and SHA-1,
// so only the inputs are reused here.
const RFC5054_SALT = fromHex("BEB25379 D1A8581E B5A72767 3A2441EE");
const RFC5054_A = fromHex("60975527 035CF2AD 1989806F 0407210B C81EDC04 E2762A56 AFD529DD DA2D4393");
const RFC5054_B = fromHex("E487CB59 D31AC550 471E81F0 0F6928E0 1DDA08E9 74A004F4 9E61F5D1 05284D20");

const SOURCE = "fast-srp-hap 2.0.4 (MIT), params SRP.params.hap (RFC 5054 3072-bit group, g=5, SHA-512). Inputs chosen by CameraBridge: "
    + "vector 1 uses I=CameraBridge, P=482-73-619, salt = SHA-256(\"CameraBridge SRP golden salt\")[0..<16], "
    + "a = SHA-256(\"CameraBridge SRP golden client private value a\"), b = SHA-256(\"CameraBridge SRP golden server private value b\"); "
    + "vector 2 uses I=Pair-Setup, P=031-45-154 with the RFC 5054 Appendix B salt/a/b. Regenerate with Interop/node/goldens.mjs (W1-9).";

function vector({ username, password, salt, a, b }) {
    const { SRP, SrpClient, SrpServer } = fastSRP();
    const params = SRP.params.hap;
    const I = Buffer.from(username, "utf8");
    const P = Buffer.from(password, "utf8");
    const server = new SrpServer(params, salt, I, P, b);
    const client = new SrpClient(params, salt, I, P, a);
    const A = client.computeA();
    const B = server.computeB();
    client.setB(B);
    server.setA(A);
    const M1 = client.computeM1();
    server.checkM1(M1);                      // throws on mismatch
    const M2 = server.computeM2();
    client.checkM2(M2);                      // throws on mismatch
    const K = server.computeK();
    check(K.equals(client.computeK()), "client and server K agree");
    const v = SRP.computeVerifier(params, salt, I, P);
    return {
        username, password, salt: hex(salt), a: hex(a), b: hex(b), v: hex(v),
        A: hex(A), B: hex(B), K: hex(K), M1: hex(M1), M2: hex(M2),
    };
}

export function generateSRP() {
    check(fastSRP().version === "2.0.4", "fast-srp-hap 2.0.4 is installed (npm ci)");
    return {
        source: SOURCE,
        vectors: [
            vector({
                username: "CameraBridge", password: "482-73-619",
                salt: sha256("CameraBridge SRP golden salt").subarray(0, 16),
                a: sha256("CameraBridge SRP golden client private value a"),
                b: sha256("CameraBridge SRP golden server private value b"),
            }),
            vector({ username: "Pair-Setup", password: "031-45-154", salt: RFC5054_SALT, a: RFC5054_A, b: RFC5054_B }),
        ],
    };
}
