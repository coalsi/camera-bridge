# go2rtc

Camera Bridge bundles the **go2rtc** program as a helper (`Contents/Helpers/go2rtc`) to reach cloud cameras and consoles (Ring, Google Nest, Wyze, Tuya, UniFi's RTSPS and others). It is run as a separate program; none of its source is part of Camera Bridge.

- **Project:** go2rtc, <https://github.com/AlexxIT/go2rtc>
- **Version:** 1.9.14 (release v1.9.14, 2026-01-19)
- **Files used:** `go2rtc_mac_arm64.zip` (SHA-256 `919b78adc759d6b3883d1e1b2ac915ac0985bb903ff1897b4d228527bd64690c`) and `go2rtc_mac_amd64.zip` (SHA-256 `9b0b9a27a4dc3a5b8b93376e7e8fc2787c6af624a512842622be84aec0171c7a`), joined into one universal binary by `Tools/fetch-go2rtc.sh`, which downloads only from the official release and refuses a file that does not match these checksums.
- **Licence:** MIT, below. go2rtc itself is built from Go modules with their own (permissive) licences, listed in the project's `go.mod`; they are part of the unmodified release binary. Camera Bridge does not modify go2rtc.
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

(Text of the `LICENSE` file at tag v1.9.14.)
