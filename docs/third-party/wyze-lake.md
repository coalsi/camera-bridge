# wyze-lake

Camera Bridge OS includes **wyze-lake**, Camera Bridge's own helper program for the Wyze cameras that stream only through Wyze's cloud (the Cam Pan v4; Wyze's web viewer on Agora). The daemon starts it on demand; it runs as a separate program.

- **Source:** [`linux/helpers/wyze-lake/`](../../linux/helpers/wyze-lake/) in this repository. Our own code, under the **MIT License** ([`LICENSE`](../../linux/helpers/wyze-lake/LICENSE)), not the PolyForm licence of the rest of Camera Bridge. [`NOTICE`](../../linux/helpers/wyze-lake/NOTICE) names the projects whose documentation and code were read to learn the protocol (no code was copied from them).
- **In the image:** `/usr/lib/camera-bridge/helpers/wyze-lake`, `0755 root:root`, a static Linux binary (`CGO_ENABLED=0`). Licence, notice and the licence texts of its Go modules: `/usr/share/doc/wyze-lake/` (`copyright`, `LICENSES/`).
- **Build:** `linux/os/build-helpers.sh` (run by `linux/os/build.sh`) runs `linux/helpers/wyze-lake/build.sh` in the official Go image pinned by digest (`golang:1.24-bookworm@sha256:1a6d4452…`, go1.24.13; see `pins.env`): `go mod verify` against `go.sum`, `go vet`, the tests, then `go build -trimpath -buildvcs=false -ldflags "-s -w -buildid= -X main.version=0.1.0"`. The build is reproducible (the same bytes on an Apple Silicon Mac and on x86-64: Go cross-compiles).
- ffmpeg is run as a separate program (the system's own package); it is not linked.

## Go modules linked into the binary

| Module | Version | Licence |
|---|---|---|
| Go standard library | go1.24.13 | BSD-3-Clause |
| github.com/pion/webrtc/v4 | v4.2.3 | MIT |
| github.com/pion/datachannel | v1.6.0 | MIT |
| github.com/pion/dtls/v3 | v3.0.10 | MIT |
| github.com/pion/ice/v4 | v4.2.0 | MIT |
| github.com/pion/interceptor | v0.1.43 | MIT |
| github.com/pion/logging | v0.2.4 | MIT |
| github.com/pion/mdns/v2 | v2.1.0 | MIT |
| github.com/pion/randutil | v0.1.0 | MIT |
| github.com/pion/rtcp | v1.2.16 | MIT |
| github.com/pion/rtp | v1.10.0 | MIT |
| github.com/pion/sctp | v1.9.2 | MIT |
| github.com/pion/sdp/v3 | v3.0.17 | MIT |
| github.com/pion/srtp/v3 | v3.0.10 | MIT |
| github.com/pion/stun/v3 | v3.1.1 | MIT |
| github.com/pion/transport/v4 | v4.0.1 | MIT |
| github.com/pion/turn/v4 | v4.1.4 | MIT |
| github.com/gorilla/websocket | v1.5.3 | BSD-2-Clause |
| github.com/google/uuid | v1.6.0 | BSD-3-Clause |
| github.com/wlynxg/anet | v0.0.5 | BSD-3-Clause |
| golang.org/x/crypto | v0.33.0 | BSD-3-Clause |
| golang.org/x/net | v0.35.0 | BSD-3-Clause |
| golang.org/x/sys | v0.30.0 | BSD-3-Clause |
| golang.org/x/time | v0.10.0 | BSD-3-Clause |

The full texts are in [`linux/helpers/wyze-lake/LICENSES/`](../../linux/helpers/wyze-lake/LICENSES/) (and in the image at `/usr/share/doc/wyze-lake/LICENSES/`). The versions are those of `go.mod` / `go.sum`; when they change, update `LICENSES/`, `NOTICE` there, this page, `THIRD_PARTY_LICENSES.md` and `docs/linux/LICENSES.md`.
