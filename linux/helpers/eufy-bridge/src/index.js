import { main } from "./main.js";
import { log, errorText } from "./log.js";

// CB_EUFY_SELFTEST=1: load the bundled SDK, build a client offline and make the SDK load protobufjs
// (the one dependency it requires lazily), then exit. No network. Used by the packaging checks.
async function selfTest() {
  const sdk = await import("@mega-yfue/eufy-sdk");
  const client = new sdk.EufyMega({ email: "selftest@example.invalid", password: "", autoRealtime: false });
  const parser = new sdk.McsParser();
  let parsed = false;
  parser.on("message", () => (parsed = true));
  // MCS version byte, then tag 0 with a varint size of 0: enough to make the parser use protobufjs.
  parser.handleData(Buffer.from([41, 0, 0]));
  process.stdout.write(JSON.stringify({ sdk: typeof sdk.EufyMega, client: client instanceof sdk.EufyMega, protobuf: "loaded", parsed }) + "\n");
  process.exit(0);
}

if (process.env.CB_EUFY_SELFTEST === "1") {
  selfTest().catch((e) => {
    process.stderr.write(`selftest failed: ${errorText(e)}\n`);
    process.exit(1);
  });
} else {
  main().catch((e) => {
    log("error", { where: "startup", error: errorText(e) });
    process.exit(1);
  });
}
