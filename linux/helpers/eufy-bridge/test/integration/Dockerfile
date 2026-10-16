# Test image for the integration scripts: Debian bookworm (like the box) with ffmpeg, curl and a go2rtc
# built from the pinned commit. The helper under test is mounted from out/eufy-bridge at run time.
FROM golang@sha256:3b4a11519ad929d1e1d261a12cff056f0c85b735253d7d861346b9c6f8b36437 AS go2rtc
ARG GO2RTC_COMMIT=c245815e75e2a5fd60b4290f12bfc04e55a984d3
RUN git clone https://github.com/AlexxIT/go2rtc.git /go2rtc \
 && cd /go2rtc && git checkout "$GO2RTC_COMMIT" \
 && CGO_ENABLED=0 go build -trimpath -o /usr/local/bin/go2rtc . \
 && /usr/local/bin/go2rtc -version

FROM debian@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends ffmpeg curl ca-certificates procps >/dev/null \
 && rm -rf /var/lib/apt/lists/*
COPY --from=go2rtc /usr/local/bin/go2rtc /usr/local/bin/go2rtc
