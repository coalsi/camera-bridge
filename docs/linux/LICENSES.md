# Camera Bridge OS: licenses and source code

This page says what Camera Bridge OS contains, under which licenses, and how to get the source code. It is an overview, not
legal advice. The authoritative texts are in the image itself (`/usr/share/doc/`).

## What is in the image

| Part | License | Notes |
|---|---|---|
| Camera Bridge (`camerabridged`, the web interface, the system scripts) | [PolyForm Noncommercial 1.0.0](../../LICENSE) | Free for personal and noncommercial use. Commercial use needs a license: <legal@camera-bridge.app>. Source: <https://github.com/coalsi/camera-bridge>. |
| Third-party code inside Camera Bridge | Apache-2.0, MIT | See [`NOTICE`](../../NOTICE) and [`THIRD_PARTY_LICENSES.md`](../../THIRD_PARTY_LICENSES.md). Also installed at `/usr/share/doc/camera-bridge/`. |
| Linux kernel | GPL-2.0 | Debian's kernel, unmodified. |
| ffmpeg | LGPL-2.1+ / GPL-2+ (Debian's build) | Camera Bridge runs it as a separate program; it does not link it. |
| systemd, Avahi, glibc and the other libraries | LGPL-2.1+ and similar | Camera Bridge links Avahi's `dns_sd` compatibility library and glibc dynamically. |
| Everything else from Debian 13 | Each package has its own license | Listed in `/usr/share/doc/<package>/copyright`. |
| Intel graphics and Realtek network firmware | Redistributable firmware licenses | From Debian's `non-free-firmware` section (`firmware-intel-graphics`, `firmware-realtek`). Their license texts are in `/usr/share/doc/`. |

The Camera Bridge programs and the GPL parts are separate programs that run side by side. The noncommercial terms of
Camera Bridge's license apply to Camera Bridge only, and never restrict what the GPL and LGPL parts allow you to do.

## Getting the source code

* Every release lists the exact packages: `camera-bridge-os-<version>-packages.txt` (binary package, version, source package,
  source version), also inside the system at `/usr/share/camera-bridge/packages.txt`.
* Debian publishes the source of every package: <https://snapshot.debian.org/> (any exact version) and
  <https://sources.debian.org/>.
* Or ask us: write to <legal@camera-bridge.app> naming the version. The written offer is in
  [`linux/os/SOURCE-OFFER.txt.in`](../../linux/os/SOURCE-OFFER.txt.in) and in the image at
  `/usr/share/doc/camera-bridge/SOURCE-OFFER.txt`.

## Video and audio codecs

Camera Bridge OS uses Debian's ffmpeg to convert audio (and video where a camera needs it). H.264, H.265 and AAC are covered
by patent pools in some countries, and Debian, like every open-source distribution, ships ffmpeg without paying those
licenses. For personal use this is the normal situation of Linux and most media players. If you use Camera Bridge OS in a
business, check whether you need codec licenses; that is between you and the patent holders, not something this project can
grant.
