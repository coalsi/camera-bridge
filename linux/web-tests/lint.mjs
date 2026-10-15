#!/usr/bin/env node
// The lint is linux/web-dev/lint.mjs (a dev tool with a command line); this path forwards to it, for the plans and people that look in
// linux/web-tests: `node linux/web-tests/lint.mjs [directory]` does the same.

import { pathToFileURL } from 'node:url';
import { main } from '../web-dev/lint.mjs';

export * from '../web-dev/lint.mjs';

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) main();
