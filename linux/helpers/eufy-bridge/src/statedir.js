// The state directory: 0700, every file 0600, written atomically (temp file + rename) so a crash or
// power cut mid-write never leaves a half-written session behind.

import { chmodSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync, openSync, fsyncSync, closeSync } from "node:fs";
import { join } from "node:path";
import { randomBytes } from "node:crypto";

export class StateDir {
  constructor(dir) {
    this.dir = dir;
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    chmodSync(dir, 0o700);
  }

  path(name) {
    if (!/^[A-Za-z0-9._-]+$/.test(name) || name.startsWith(".")) throw new Error("bad state file name");
    return join(this.dir, name);
  }

  readBuffer(name) {
    try {
      return readFileSync(this.path(name));
    } catch {
      return null;
    }
  }

  readJSON(name) {
    const b = this.readBuffer(name);
    if (!b) return null;
    try {
      return JSON.parse(b.toString("utf8"));
    } catch {
      return null;
    }
  }

  write(name, data) {
    const final = this.path(name);
    const tmp = join(this.dir, `.${name}.${randomBytes(4).toString("hex")}.tmp`);
    writeFileSync(tmp, data, { mode: 0o600 });
    try {
      const fd = openSync(tmp, "r");
      try {
        fsyncSync(fd);
      } finally {
        closeSync(fd);
      }
    } catch {
      /* best effort */
    }
    chmodSync(tmp, 0o600);
    renameSync(tmp, final);
  }

  writeJSON(name, value) {
    this.write(name, JSON.stringify(value));
  }

  remove(name) {
    try {
      rmSync(this.path(name), { force: true });
    } catch {
      /* gone */
    }
  }

  /** File names in the directory (no temp files). */
  list() {
    try {
      return readdirSync(this.dir).filter((n) => !n.startsWith("."));
    } catch {
      return [];
    }
  }

  /** A SessionStore / FcmStore shaped adapter over one JSON file, for the SDK. */
  jsonStore(name) {
    return {
      load: () => this.readJSON(name),
      save: (v) => this.writeJSON(name, v),
      clear: () => this.remove(name),
    };
  }
}
