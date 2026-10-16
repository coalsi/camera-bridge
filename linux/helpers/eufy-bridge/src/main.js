// eufy-bridge: Camera Bridge OS helper for one Eufy account.
// Exit codes: 0 stopped (SIGTERM/SIGINT), 2 bad configuration, 5 can't listen.

import { existsSync } from "node:fs";
import { readConfig, ConfigError } from "./config.js";
import { StateDir } from "./statedir.js";
import { Bridge } from "./bridge.js";
import { createServer } from "./server.js";
import { FakeBackend } from "./backend-fake.js";
import { addSecret, log, errorText } from "./log.js";
import { VERSION } from "./version.js";

export async function main(env = process.env) {
  let cfg;
  try {
    cfg = readConfig(env);
  } catch (e) {
    if (e instanceof ConfigError) {
      log("error", { where: "config", error: e.message });
      process.exit(2);
    }
    throw e;
  }
  addSecret(cfg.token);

  let state;
  try {
    state = new StateDir(cfg.stateDir);
  } catch (e) {
    log("error", { where: "config", error: `CB_EUFY_STATE_DIR is not usable: ${errorText(e)}` });
    process.exit(2);
  }

  let ffmpeg = cfg.ffmpeg;
  if (!ffmpeg && existsSync("/usr/bin/ffmpeg")) ffmpeg = "/usr/bin/ffmpeg";
  if (cfg.fake && !ffmpeg) {
    log("error", { where: "config", error: "fake mode needs ffmpeg: set CB_EUFY_FFMPEG" });
    process.exit(2);
  }

  log("start", { version: VERSION.app, sdk: VERSION.sdk, node: process.versions.node, fake: cfg.fake ? 1 : 0, ffmpeg: ffmpeg ? "yes" : "no" });

  let backend;
  if (cfg.fake) backend = new FakeBackend({ state, ffmpeg });
  else {
    const { RealBackend } = await import("./backend-real.js");
    backend = new RealBackend({ state, ffmpeg });
  }
  const bridge = new Bridge({ backend, state, ffmpeg });
  const server = createServer({ bridge, token: cfg.token, fake: cfg.fake ? backend : undefined });

  const sockets = new Set();
  server.on("connection", (s) => {
    sockets.add(s);
    s.on("close", () => sockets.delete(s));
  });

  await new Promise((resolve) => {
    server.once("error", (e) => {
      log("error", { where: "listen", port: cfg.port, error: e.code === "EADDRINUSE" ? "port already in use" : errorText(e) });
      process.exit(5);
    });
    server.listen({ host: cfg.host, port: cfg.port, exclusive: true }, resolve);
  });
  server.on("error", (e) => log("error", { where: "http", error: errorText(e) }));
  log("listening", { port: cfg.port });

  await bridge.init();

  let stopping = false;
  const stop = async (signal) => {
    if (stopping) return;
    stopping = true;
    const hard = setTimeout(() => process.exit(0), 4_000);
    hard.unref();
    server.close();
    try {
      await bridge.close();
    } catch {
      /* exiting */
    }
    for (const s of sockets) s.destroy();
    log("stopped", { signal });
    process.exit(0);
  };
  process.on("SIGTERM", () => stop("SIGTERM"));
  process.on("SIGINT", () => stop("SIGINT"));
  process.on("SIGPIPE", () => {});
  process.on("uncaughtException", (e) => {
    log("error", { where: "uncaught", error: errorText(e) });
    process.exit(1);
  });
  process.on("unhandledRejection", (e) => {
    // Cloud/P2P promises the SDK leaves dangling must not take the helper down.
    log("error", { where: "unhandled", error: errorText(e) });
  });
}
