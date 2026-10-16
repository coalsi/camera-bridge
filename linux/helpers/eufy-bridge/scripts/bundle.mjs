// Bundle src/index.js and every dependency into one CommonJS file, out/eufy-bridge/eufy-bridge.js,
// and write out/meta.json (the inputs esbuild used, for the licence collection).
//
// One SDK patch, applied at bundle time: @mega-yfue/eufy-sdk loads protobufjs lazily through
// `createRequire(import.meta.url)("protobufjs")`, which a bundler cannot follow and which would look
// for node_modules next to the bundle at run time. It is rewritten to a plain `require("protobufjs")`,
// which esbuild bundles and still evaluates lazily on first use. The build fails if the pattern is
// not found exactly once, so an SDK update cannot silently ship without protobufjs.

import { build } from "esbuild";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const outDir = process.argv[2] ?? join(root, "out", "eufy-bridge");
const version = JSON.parse(process.env.CB_EUFY_VERSION_JSON ?? '{"app":"dev","sdk":"@mega-yfue/eufy-sdk@0.4.0"}');

const sdkPatch = {
  name: "eufy-sdk-protobuf-require",
  setup(b) {
    b.onLoad({ filter: /[\\/]@mega-yfue[\\/]eufy-sdk[\\/]dist[\\/]index\.js$/ }, (args) => {
      let src = readFileSync(args.path, "utf8");
      const decl = "var requireFrom = createRequire(import.meta.url);";
      const call = 'requireFrom("protobufjs")';
      const count = (s, x) => s.split(x).length - 1;
      if (count(src, decl) !== 1 || count(src, call) !== 1) {
        throw new Error("eufy-sdk protobuf loader not found as expected; review scripts/bundle.mjs for this SDK version");
      }
      src = src.replace(decl, "var requireFrom = null;").replace(call, 'require("protobufjs")');
      return { contents: src, loader: "js" };
    });
  },
};

mkdirSync(outDir, { recursive: true });
const result = await build({
  entryPoints: [join(root, "src", "index.js")],
  bundle: true,
  platform: "node",
  target: "node24",
  format: "cjs",
  outfile: join(outDir, "eufy-bridge.js"),
  metafile: true,
  legalComments: "none", // licence texts ship in LICENSES/ instead
  sourcemap: false,
  minify: false,
  logLevel: "warning",
  define: { __CB_EUFY_VERSION__: JSON.stringify(version) },
  // Licence texts ship in LICENSES/ (legalComments: none); the banner names the one modified third-party file (Apache-2.0, 4(b)).
  banner: {
    js:
      "#!/usr/bin/env node\n" +
      "// eufy-bridge (Camera Bridge). Bundles @mega-yfue/eufy-sdk (Apache-2.0, Copyright 2026 mega-yfue) and other npm packages;\n" +
      "// their licences are in LICENSES/ next to this file. Modified: the SDK's dist/index.js, whose lazy protobufjs loader\n" +
      "// (createRequire(import.meta.url)(\"protobufjs\")) is replaced by require(\"protobufjs\") at bundle time. Nothing else is changed.\n" +
      "'use strict';",
  },
  plugins: [sdkPatch],
});

const warnings = result.warnings.map((w) => w.text);
if (warnings.some((t) => /import\.meta/.test(t))) {
  throw new Error("bundle uses import.meta, which is empty in CommonJS output:\n" + warnings.join("\n"));
}
writeFileSync(join(root, "out", "meta.json"), JSON.stringify(result.metafile));
// Pin the module type next to the bundle: without it, node would treat eufy-bridge.js as an ES module
// whenever some parent directory has a package.json saying "type": "module".
writeFileSync(join(outDir, "package.json"), JSON.stringify({ type: "commonjs", private: true }) + "\n");
console.log(`bundled ${Object.keys(result.metafile.inputs).length} inputs; warnings: ${warnings.length}`);
for (const w of warnings) console.log("  warning:", w);
