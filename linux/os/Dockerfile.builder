# Build environment for Camera Bridge OS: Debian 13 with the same systemd and mkosi the image uses.
# Used by build.sh (docker run --privileged) and by the GitHub Actions workflow, so a Mac, a Linux box
# and CI all build the same way.
FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      mkosi mmdebstrap debian-archive-keyring ca-certificates curl gnupg \
      systemd systemd-repart systemd-boot systemd-ukify systemd-sysv udev kmod \
      dosfstools mtools e2fsprogs fdisk gdisk parted util-linux cpio zstd xz-utils tar \
      minisign jq openssl bubblewrap squashfs-tools \
      nftables shellcheck python3 \
      qemu-system-x86 qemu-system-arm qemu-utils ovmf qemu-efi-aarch64 \
      openssh-client iproute2 procps \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
