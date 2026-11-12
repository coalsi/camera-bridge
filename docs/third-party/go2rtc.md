# go2rtc

Camera Bridge OS includes the **go2rtc** program as a helper to reach cloud cameras and consoles (Ring, Google Nest, Wyze, Tuya, UniFi's RTSPS and others). The daemon starts it as a separate program when a camera needs it; none of its source is part of Camera Bridge.

- **Project:** go2rtc, <https://github.com/AlexxIT/go2rtc>
- **Version:** 1.9.14+dev.c245815, built from commit `c245815e75e2a5fd60b4290f12bfc04e55a984d3` (master, 2026-07-13) rather than the v1.9.14 release (2026-01-19), because the native Wyze source (`pkg/tutk`, `pkg/wyze`) was fixed after the release (commit `75bd1f1`, "Improve packet loss on old TUTK proto"). go2rtc's own tests of `pkg/tutk` pass at that commit (`fetch-go2rtc.sh --test`).
- **On the box:** `/usr/lib/camera-bridge/helpers/go2rtc` (`0755 root:root`), a static Linux binary. Its licence text, with the version line of the build, is at `/usr/share/doc/go2rtc/copyright`. It is not a Debian package, so it is not in the image's `packages.txt`.
- **How it is built:** `linux/os/fetch-go2rtc.sh`, which `linux/os/build.sh` runs for each image, fetches that commit by its hash, checks the Go modules against `go.sum` (`go mod verify`) and builds with the official Go toolchain image, pinned by digest (`golang:1.27.4-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea`, go1.27.4; `CGO_ENABLED=0`, `-trimpath`, `-ldflags "-s -w -buildid="`). Go cross-compiles, so no emulation is involved.
- **Checksums:** the script installs only these results: linux/amd64 SHA-256 `ae6091ca45a607ba0cdcac96e336b8ff535111c27380b291f868086c0d68ec10`, linux/arm64 SHA-256 `16370666fdbdea3c1532f03385e13b3ae3b2677c6c8e06cff0ae55ad46e61a03`, `LICENSE` SHA-256 `b0dcf4855af5a72b4dfbd9117c207b330f4cc35658576a0b5351d6e2becac546` (the same bytes on every build on an Apple Silicon Mac; the x86-64 checksum was made there too and is checked again by the first image build in CI). A build with other bytes installs nothing.
- **Licence:** MIT, below. go2rtc is built from Go modules with their own (permissive) licences, listed in the project's `go.mod`; they are compiled into the binary unmodified. Camera Bridge does not modify go2rtc.
- **The archived Mac app** bundled the v1.9.14 release itself (`Contents/Helpers/go2rtc`): `go2rtc_mac_arm64.zip` (SHA-256 `919b78adc759d6b3883d1e1b2ac915ac0985bb903ff1897b4d228527bd64690c`) and `go2rtc_mac_amd64.zip` (SHA-256 `9b0b9a27a4dc3a5b8b93376e7e8fc2787c6af624a512842622be84aec0171c7a`), joined into one universal binary by `Tools/fetch-go2rtc.sh`, which downloads only from the official release and refuses a file that does not match these checksums. The engine's tests of the real program still use that script on a Mac.
- **How Camera Bridge uses it:** [../integrations/go2rtc-helper.md](../integrations/go2rtc-helper.md). Its source-type formats (`ring:`, `nest:`, `tuya:`, `wyze:`, `rtspx:`) are taken from go2rtc's README and per-source documentation.

## Licence text

```
MIT License

Copyright (c) 2022 Alexey Khit

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

(Text of the `LICENSE` file at commit `c245815`, the same as at tag v1.9.14.)
