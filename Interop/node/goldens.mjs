#!/usr/bin/env node
// Writes the JSON goldens CameraBridge's Swift tests compare against (dev-only; plan task W1-9).
//
//   node goldens.mjs [section ...] [--check] [--out <Tests directory>]
//
// Sections: srp tlv8 setup-payload hds-codec hds-frames camera (default: all). Files land in
// Packages/CameraBridgeKit/Tests/<Module>Tests/Fixtures/<name>.json (or under --out). --check writes nothing
// and exits 1 if any fixture is missing or differs from what the pinned oracles produce now.
import fs from "node:fs";
import path from "node:path";

import { defaultTestsDirectory, render, sections } from "./lib/goldens/index.mjs";

function usage(message) {
    if (message) process.stderr.write(`goldens.mjs: ${message}\n`);
    process.stderr.write(`usage: node goldens.mjs [${Object.keys(sections).join("|")} ...] [--check] [--out <Tests directory>]\n`);
    process.exit(2);
}

function parseArguments(argv) {
    const options = { check: false, out: defaultTestsDirectory, names: [] };
    for (let i = 0; i < argv.length; i++) {
        const arg = argv[i];
        if (arg === "--check") options.check = true;
        else if (arg === "--out") {
            const value = argv[++i];
            if (!value) usage("--out needs a directory");
            options.out = path.resolve(value);
        } else if (arg === "--help" || arg === "-h") usage();
        else if (arg === "all") options.names.push(...Object.keys(sections));
        else if (Object.hasOwn(sections, arg)) options.names.push(arg);
        else usage(`unknown section or option: ${arg}`);
    }
    if (options.names.length === 0) options.names = Object.keys(sections);
    options.names = [...new Set(options.names)];
    return options;
}

function main() {
    const options = parseArguments(process.argv.slice(2));
    let drift = 0;
    for (const name of options.names) {
        const section = sections[name];
        const target = path.join(options.out, section.file);
        const text = render(section.generate());
        const current = fs.existsSync(target) ? fs.readFileSync(target, "utf8") : undefined;
        const relative = path.relative(process.cwd(), target) || target;
        if (options.check) {
            if (current === text) {
                process.stdout.write(`ok       ${relative}\n`);
            } else {
                drift += 1;
                process.stdout.write(`${current === undefined ? "missing " : "differs "} ${relative} (run: node goldens.mjs ${name})\n`);
            }
            continue;
        }
        if (current === text) {
            process.stdout.write(`unchanged ${relative}\n`);
        } else {
            fs.mkdirSync(path.dirname(target), { recursive: true });
            fs.writeFileSync(target, text);
            process.stdout.write(`wrote     ${relative}\n`);
        }
    }
    return drift === 0 ? 0 : 1;
}

try {
    process.exitCode = main();
} catch (error) {
    process.stderr.write(`goldens.mjs: ${error.stack ?? error}\n`);
    process.exitCode = 1;
}
// HAP-NodeJS objects created for the camera goldens may hold timers; the work is done.
process.exit(process.exitCode);
