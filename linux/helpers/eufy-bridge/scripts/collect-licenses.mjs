// Copy the licence text of every package esbuild actually bundled (from out/meta.json) into
// <out>/LICENSES/<package>/, plus Node.js's LICENSE, and write LICENSES/README.txt listing them.
// Fails if a bundled package ships no licence file and none can be named from package.json.

import { readFileSync, readdirSync, mkdirSync, copyFileSync, writeFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const outDir = process.argv[2] ?? join(root, "out", "eufy-bridge");
const nodeLicense = process.argv[3]; // path to Node's LICENSE from the pinned tarball
const meta = JSON.parse(readFileSync(join(root, "out", "meta.json"), "utf8"));

const pkgDirs = new Map();
for (const input of Object.keys(meta.inputs)) {
  const m = /^(.*node_modules\/((?:@[^/]+\/)?[^/]+))\//.exec(input);
  if (m) pkgDirs.set(m[1], m[2]);
}

const licDir = join(outDir, "LICENSES");
mkdirSync(licDir, { recursive: true });
const rows = [];
const LIC_RE = /^(licen[cs]e|copying|notice|authors|patents)(\..*)?$/i;

for (const [dir, name] of [...pkgDirs].sort((a, b) => a[1].localeCompare(b[1]))) {
  const pkg = JSON.parse(readFileSync(join(root, dir, "package.json"), "utf8"));
  const files = readdirSync(join(root, dir)).filter((f) => LIC_RE.test(f));
  const dest = join(licDir, name.replace("/", "__"));
  mkdirSync(dest, { recursive: true });
  for (const f of files) copyFileSync(join(root, dir, f), join(dest, f));
  const license = typeof pkg.license === "string" ? pkg.license : pkg.license?.type ?? "UNKNOWN";
  if (files.length === 0) {
    if (license === "UNKNOWN") throw new Error(`${name} has no licence file and no licence field`);
    // Some packages publish only the SPDX id; record it with the copyright holder from package.json.
    const who = typeof pkg.author === "string" ? pkg.author : pkg.author?.name ?? "the package authors";
    writeFileSync(join(dest, "LICENSE-from-package.json.txt"), `${name}@${pkg.version}\nLicense: ${license}\nCopyright: ${who}\n(No licence file is shipped in the npm package; see ${pkg.repository?.url ?? pkg.homepage ?? "the package"}.)\n`);
  }
  rows.push(`${name}@${pkg.version}  ${license}  ${files.length ? files.join(", ") : "(licence id only)"}`);
}

if (nodeLicense) {
  if (!existsSync(nodeLicense)) throw new Error("Node LICENSE not found");
  mkdirSync(join(licDir, "node"), { recursive: true });
  copyFileSync(nodeLicense, join(licDir, "node", "LICENSE"));
  rows.unshift(`node (the bundled runtime)  MIT and others (see node/LICENSE)`);
}

writeFileSync(
  join(licDir, "README.txt"),
  "Third-party software in this directory's parent (node, eufy-bridge.js):\n\n" + rows.join("\n") + "\n",
);
console.log(rows.join("\n"));
