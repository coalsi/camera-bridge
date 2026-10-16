// Configuration comes only from the environment. A bad value is exit code 2.

import { existsSync, statSync } from "node:fs";
import { isAbsolute } from "node:path";

export class ConfigError extends Error {}

/**
 * @param {Record<string, string|undefined>} env
 * @returns {{host: string, port: number, token: string, stateDir: string, ffmpeg?: string, fake: boolean}}
 */
export function readConfig(env) {
  const listen = env.CB_EUFY_LISTEN ?? "";
  const m = /^127\.0\.0\.1:(\d{1,5})$/.exec(listen);
  if (!m) throw new ConfigError("CB_EUFY_LISTEN must be 127.0.0.1:<port> (loopback only)");
  const port = Number(m[1]);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new ConfigError("CB_EUFY_LISTEN port is out of range");

  const token = env.CB_EUFY_TOKEN ?? "";
  if (token.length < 16) throw new ConfigError("CB_EUFY_TOKEN must be at least 16 characters");
  if (!/^[A-Za-z0-9._~-]+$/.test(token)) throw new ConfigError("CB_EUFY_TOKEN must be URL-safe (A-Z a-z 0-9 . _ ~ -)");

  const stateDir = env.CB_EUFY_STATE_DIR ?? "";
  if (!stateDir || !isAbsolute(stateDir)) throw new ConfigError("CB_EUFY_STATE_DIR must be an absolute path");

  let ffmpeg = env.CB_EUFY_FFMPEG || undefined;
  if (ffmpeg) {
    if (!isAbsolute(ffmpeg)) throw new ConfigError("CB_EUFY_FFMPEG must be an absolute path");
    if (!existsSync(ffmpeg) || !statSync(ffmpeg).isFile()) throw new ConfigError("CB_EUFY_FFMPEG does not exist");
  }

  const fakeRaw = env.CB_EUFY_FAKE ?? "";
  if (fakeRaw !== "" && fakeRaw !== "0" && fakeRaw !== "1") throw new ConfigError("CB_EUFY_FAKE must be 0 or 1");

  return { host: "127.0.0.1", port, token, stateDir, ffmpeg, fake: fakeRaw === "1" };
}
