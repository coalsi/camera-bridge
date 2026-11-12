# Test image for the integration scripts: Debian 12 (bookworm-slim) with ffmpeg, curl and a go2rtc built from the
# pinned commit with the Go image linux/os/fetch-go2rtc.sh pins (go1.27.4). The helper under test is mounted from
# out/eufy-bridge at run time.
FROM golang:1.27.4-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea AS go2rtc
ARG GO2RTC_COMMIT=c245815e75e2a5fd60b4290f12bfc04e55a984d3
RUN git clone https://github.com/AlexxIT/go2rtc.git /go2rtc \
 && cd /go2rtc && git checkout "$GO2RTC_COMMIT" \
 && CGO_ENABLED=0 go build -trimpath -o /usr/local/bin/go2rtc . \
 && /usr/local/bin/go2rtc -version

FROM debian@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends ffmpeg curl ca-certificates procps >/dev/null \
 && rm -rf /var/lib/apt/lists/*
COPY --from=go2rtc /usr/local/bin/go2rtc /usr/local/bin/go2rtc
