#!/bin/sh
# Runs inside the pinned Node container (see build.sh). /src is the source (read-only), /out the output.
set -eu

: "${NODE_VERSION:?}" "${NODE_SHA256:?}" "${NODE_BIN_SHA256:?}" "${SDK_VERSION:?}" "${SDK_COMMIT:?}"

rm -rf /work && mkdir -p /work
cd /src
# Copy the sources only (no node_modules / out from the host).
tar --exclude=./node_modules --exclude=./out --exclude=./.git --exclude='./dl-*' -cf - . | tar -C /work -xf -
cd /work

npm ci --ignore-scripts --no-audit --no-fund --loglevel=error

# The lockfile must pin exactly the SDK version we claim.
node -e '
const lock = require("./package-lock.json");
const v = lock.packages["node_modules/@mega-yfue/eufy-sdk"].version;
if (v !== process.env.SDK_VERSION) { console.error("SDK in lockfile is " + v); process.exit(1); }
'

if [ "${SKIP_TESTS:-0}" != "1" ]; then
  npm test
fi

if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then BUILD_DATE="$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)"; else BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; fi
APP_VERSION="$(node -p 'require("./package.json").version')"
CB_EUFY_VERSION_JSON="$(printf '{"app":"%s","sdk":"@mega-yfue/eufy-sdk@%s+%s","built":"%s"}' \
  "$APP_VERSION" "$SDK_VERSION" "$(echo "$SDK_COMMIT" | cut -c1-12)" "$BUILD_DATE")"
export CB_EUFY_VERSION_JSON

OUT=/work/out/eufy-bridge
rm -rf /work/out && mkdir -p "$OUT"
node scripts/bundle.mjs "$OUT"

# The pinned Node.js binary, verified against the pinned SHA-256 and the release's SHASUMS256.txt.
mkdir -p /work/dl && cd /work/dl
TARBALL="node-v${NODE_VERSION}-linux-x64.tar.gz"
node -e '
const [url, file] = process.argv.slice(1);
(async () => {
  const r = await fetch(url);
  if (!r.ok) throw new Error(url + " " + r.status);
  require("fs").writeFileSync(file, Buffer.from(await r.arrayBuffer()));
})().catch((e) => { console.error(e.message); process.exit(1); });
' "https://nodejs.org/dist/v${NODE_VERSION}/${TARBALL}" "$TARBALL"
node -e '
const [url, file] = process.argv.slice(1);
fetch(url).then(r => r.text()).then(t => require("fs").writeFileSync(file, t));
' "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" SHASUMS256.txt
echo "${NODE_SHA256}  ${TARBALL}" | sha256sum -c -
grep " ${TARBALL}\$" SHASUMS256.txt | sha256sum -c -
tar -xzf "$TARBALL"
NODE_DIR="node-v${NODE_VERSION}-linux-x64"
cp "$NODE_DIR/bin/node" "$OUT/node"
echo "${NODE_BIN_SHA256}  $OUT/node" | sha256sum -c -
chmod 0755 "$OUT/node"
"$OUT/node" --version | grep -qx "v${NODE_VERSION}"
cd /work

node scripts/collect-licenses.mjs "$OUT" "/work/dl/$NODE_DIR/LICENSE" > /dev/null

cat > "$OUT/eufy-bridge" <<'EOF'
#!/bin/sh
exec "$(dirname "$0")/node" "$(dirname "$0")/eufy-bridge.js"
EOF
chmod 0755 "$OUT/eufy-bridge"
chmod 0644 "$OUT/eufy-bridge.js"

cat > "$OUT/VERSION" <<EOF
eufy-bridge $(node -p 'require("./package.json").version')
node ${NODE_VERSION} linux-x64 (official binary from node-v${NODE_VERSION}-linux-x64.tar.gz, sha256 ${NODE_SHA256}, checked against SHASUMS256.txt)
@mega-yfue/eufy-sdk ${SDK_VERSION} commit ${SDK_COMMIT} $(node -p 'require("./package-lock.json").packages["node_modules/@mega-yfue/eufy-sdk"].integrity')
built ${BUILD_DATE}
EOF

# Hand the result back, owned by the caller.
rm -rf /out/eufy-bridge
cp -R "$OUT" /out/eufy-bridge
cp /work/out/meta.json /out/meta.json
if [ -n "${HOST_UID:-}" ]; then chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" /out; fi
du -sh /out/eufy-bridge
