# PlatformLinux / Codecs

`FFmpegMediaCodecs: MediaCodecs`: the Linux counterpart of `PlatformApple.AppleMediaCodecs`, built on `ffmpeg` child processes.
Plain Swift (Foundation, Dispatch, Synchronization); it also builds on macOS, where the unit tests run against a real ffmpeg if
one is installed (`brew install ffmpeg` is enough, nothing is required of the Mac app).

```swift
let codecs = FFmpegMediaCodecs()                 // ffmpeg from CAMERABRIDGE_FFMPEG, PATH, /usr/bin, ...
try codecs.prepare()                             // optional: probe encoders and VA-API now, not on the first stream
print(try codecs.capabilitySummary())
```

## Requirements on the box

- `ffmpeg` (tested: 7.1.5 from Debian 13, 8.0.1 on Ubuntu 26.04 aarch64, 8.1.1 from Homebrew; Enhanced-FLV HEVC input needs 6.1 or
  newer) with `libx264`, `libopus`, the native `aac` encoder, `mjpeg`, and for the timestamp
  overlay `drawtext` (libfreetype) and a TrueType font (`fonts-dejavu-core`). Without the font or filter the overlay is left out and
  logged once; the stream still runs. Straighten the picture uses `remap`, `extractplanes` and `mergeplanes` (built into libavfilter, no
  extra library); without them it is unavailable (`supportsPictureCorrection` false, logged once).
- VA-API: `h264_vaapi`, a render node (`/dev/dri/renderD128`) and the driver (`intel-media-va-driver`, `mesa-va-drivers`). At first
  use a 0.6 s probe encode decides: the default encoder first, then `-low_power 1` (recent Intel GPUs, Alder Lake-N and newer, offer
  H.264 encoding only through the fixed-function entrypoint); if one works VA-API is used, otherwise libx264
  (`-preset veryfast -tune zerolatency`). `FFmpegCodecsConfiguration.videoEncoder` (`.automatic`, `.software`, `.vaapi`) forces a
  choice. A VA-API child that dies before producing a picture switches new pipelines to software. The chosen encoder is logged
  (`H.264 encoding with ...`) and shows in `TranscoderDiagnostics.encoderIsHardware`. **VA-API was not exercised on real hardware**
  (no GPU is reachable from the Mac or its containers): the arguments, the probe order, the low-power retry and the fall back are
  unit-tested with a fake ffmpeg, and the option names were checked against `ffmpeg -h encoder=h264_vaapi` of ffmpeg 7.1.
- Call `FFmpegMediaCodecs.prepare()` at start-up: the first use otherwise runs the capability probe (about a tenth of a second, up to
  ten seconds if the GPU stalls) inside the first stream's creation deadline.

## How it talks to ffmpeg

One child process per decoder, encoder, transcoder and audio transcoder, with three threads each (stdin writer, stdout reader,
stderr reader) and one waiting for its end. Everything above them uses `FFmpegProcess` / `FFmpegProcessLaunching`, so the logic is
tested with a fake process as well as with the real one.

- **Framing**: compressed video goes in as FLV (every tag carries its size and a timestamp, so a frame is complete when its bytes
  arrive; H.264 as AVC, HEVC as Enhanced FLV, ffmpeg 6.1+) and comes out as FLV; AAC likewise; Opus as Ogg (one packet per page); G.711
  and PCM as bare samples; raw pictures as `yuv420p` in, Y4M out (ffmpeg's `rawvideo` muxer holds each picture back until the next).
- **Timestamps**: ffmpeg works in milliseconds, the engine in 90 kHz ticks with a wall clock. Each picture put in is remembered under
  the millisecond it was sent with and gets its exact PTS and wall clock back when the encoded picture arrives (`VideoFLVStream`).
  `-copyts` keeps ffmpeg from rebasing the clock.
- **No waiting**: `transcode` writes the frame and returns whatever the child produced so far (pipeline latency is a few ms when warm,
  the first picture follows the first frames by ~50 ms). Decoders and the encoder wait (bounded) for the picture they just fed.
- **Back-pressure and bounds**: stdin is a queue of at most 32 MiB (a stalled child throws "not keeping up"), stdout is buffered up
  to 64 MiB and then the reader stops, so ffmpeg itself blocks. stderr keeps the last 20 lines (400 characters each) for errors.
- **Death**: a child that exits or is killed surfaces as a thrown `MediaCodecError.unsupported("ffmpeg (<label>) exited with status N: <stderr tail>")`.
  The video transcoder then waits for the next keyframe and starts a new child; the audio transcoder starts a new one after 1 s.
  `invalidate()` and `deinit` send SIGTERM and, 0.7 s later, SIGKILL; the waiting thread reaps the child, so none is left as a zombie.
  A parent that dies closes the children's stdin, which ends them.

## Controls ffmpeg does not have, and what replaces them

| Control | Replacement |
|---|---|
| `requestKeyframe()` | The next picture is written with an **odd** millisecond timestamp (all others are even); `-force_key_frames expr:mod(round(t*1000),2)` turns that into an IDR. Instant, no restart. |
| `updateBitrate(kbps:)` | Restart: a change of 10 % or more (at least 2 s after the child started) starts a new child fed with the GOP since the last source keyframe; a `select` filter skips every picture but the newest, so the output continues with an IDR of "now". Bit rate updates are rare, a restart costs a few hundred milliseconds. |
| `catchUp(_:)` | The same restart on the frames handed over. |
| frame-rate limit | `select` with the rule of `FrameRateLimiter` (a state variable in the expression holds the next due time). |
| timestamp overlay | `drawtext` re-reading a text file for every picture (`reload=1`); the words are rewritten atomically when they change. A change of position, size or on/off restarts the child like a bit rate change. |
| Straighten the picture (`makeVideoTranscoder(output:overlay:correction:)`) | `remap` on each plane of the 4:2:0 picture as grey (`extractplanes`, three `remap`s, `mergeplanes`: `remap` takes no subsampled format, and on the box's N150 this costs about 18 ms per 1920×852 picture, half of a 4:4:4 warp, at the same quality), with four 16-bit PGM maps from `PictureCorrection.remapMaps` (`RemapScratch`: a private directory; each map replaced atomically; the x maps written when the size changes, the y maps when the correction or the size changes, and any map that has gone missing written again), given as four more `-i` inputs (luma x, luma y, chroma x, chroma y) that ffmpeg reads once and keeps for the whole stream. The filters become a graph (`-filter_complex`, output pad `cbv`): the frame-rate `select` first, then scale to the picture's fitted size at twice its height, the warp, `scale=…:flags=area` back down (remap only picks the nearest pixel), then the bars, the label and the encoder's pixel format. A letterboxed picture is straightened before its bars, and the label is drawn upright after the warp. A change of the correction restarts the child like a bit rate change; maps that cannot be written leave the picture uncorrected (one warning, no restarts). Without a correction the arguments are what they were. Snapshots (`correctJPEG`): one child per JPEG with the same warp at the picture's size (an odd width warped one pixel wider and scaled back), its four maps kept in a private temporary directory for each picture size and correction (`SnapshotMapCache`, six sets at most, the least recently used removed at once, all removed with the codecs; a `/live` preview asks for a picture every 700 ms, so they are made once, not for every snapshot), then full range again (`scale=out_range=pc,format=yuvj420p`) and `mjpeg` `-q:v 5`, as `resizeJPEG` writes; at most 6 s (`straightenTimeout` = `PictureCorrection.snapshotTimeout`; the engine runs the call on a thread of its own, `CorrectedSnapshots.offloaded`). |
| level | The lowest level at or above the request that fits the picture and rate (`H264LevelLimits`), passed as `-level`. |

## Decoding on the GPU, and the sky detector's decoder

`FFmpegVideoDecoder` (snapshots, the live self-check, motion detection, the sky detector) decodes in software, except that the decoders for motion detection and
the sky ask for the GPU (`hardwareWhenHeavy`) when the stream is heavy on the CPU (HEVC, or more than 1080p) **and the GPU's decoder takes its size**
(`FFmpegVideoDecoder.fitsHardware`: H.264 up to 4096 wide and tall, HEVC up to 8192, Intel's limits), and VA-API is usable. A 4256×1888 H.264 camera is
therefore decoded in software, and the same size in HEVC on the GPU. If a GPU session ends before its first picture (the driver refuses the stream, the
device cannot be opened) that stream (codec, size, profile) is decoded in software for the next 10 minutes (`FFmpegRuntime.hardwareDecodeRetryAfter`), by every decoder,
and the log says, as a warning, "the GPU could not decode H.264 3840×2160; decoding in software" with the last line ffmpeg said (once for the failure, not for each
decoder it touches); the next keyframe starts the software child, and the first keyframe after the 10 minutes tries the GPU again (a passing hiccup of the GPU does not
send a 4K or HEVC camera to the CPU for the rest of the run; a GPU that is still dead fails again, and is held and said again 10 minutes on).
`VideoDecoding.decodingPlace` says `gpu` or `software`. **VA-API decoding was not exercised on real hardware** here: the arguments, the size limits and the
fall back are unit-tested with a fake ffmpeg.

`makeSkyDecoder(format:maxOutputWidth:keepEvery:)` (`FFmpegArguments.decoder(…, keepEvery:, highQualityScaling:)`):
- **Pictures**: at most `maxOutputWidth` wide (the shape kept, even sizes), `yuv420p`, of frames 0, N, 2N, … only. On the GPU the chain is
  `scale_vaapi=w=…:h=…:format=nv12:mode=hq,select='not(mod(n\,N))',hwdownload,format=nv12,format=yuv420p`: scaled by the GPU's high-quality scaler, dropped there,
  and only the kept pictures (about five a second) copied back. On the CPU `select` comes before `scale=…:flags=area` (an area average), so a dropped picture is
  never scaled either. The loop filter stays on (`-skip_loop_filter` would show block edges as faint false lights in a dark sky). How single-pixel sensor
  speckle looks depends on the scaling, hence the filters.
- **Times**: `decode` returns nil at once for a frame that is not kept (no 0.4 s wait for a picture that never comes), and a kept picture takes the time of its
  own frame: the N − 1 times before it go with it (the pending times stay sorted). A stream with reordering (a frame with a decode time before its presentation
  time) is not waited for at all: its pictures come out frames late, and the call that brings one hands it over.
- **Priority**: the child runs under `nice -n 10` (`FFmpegProcessSpec.niceness`, `FFmpegVideoDecoder.skyNiceness`; the real launcher starts `/usr/bin/nice -n 10
  ffmpeg …`, so every thread has it; no `nice` program: as it is), as the clip conversions do, so live video and recordings keep the box's cores.
- `RawVideoFrame.grayThumbnail(maxWidth:)` at the picture's own size (what the sky decoder makes) copies the luma plane instead of averaging blocks of one pixel.

## Audio and HomeKit

What ffmpeg can produce is read from `ffmpeg -encoders` (see `capabilitySummary()`):

- **Opus** (`libopus`, 8/12/16/24/48 kHz): yes. This is what the live view uses (`AudioEncoderSettings(codec: .opus, ...)`).
- **AAC-LC** (ffmpeg's own `aac` encoder): yes. HKSV recording audio and the silent track.
- **AAC-ELD**: **no**, in either direction. ffmpeg encodes AAC-ELD only through `libfdk_aac` (non-free, not in Debian, Ubuntu or
  Homebrew builds), and its own AAC decoder rejects Apple's AAC-ELD access units with `AVERROR_BUG` ("Internal bug, should not have
  happened"; checked with ffmpeg 7.1.5 and 8.x against AudioToolbox's encoder). `makeAudioTranscoder` with `.aacELD` as input or
  output throws `MediaCodecError.unsupported` naming `libfdk_aac` at creation; an ffmpeg that has `libfdk_aac` is used for it
  automatically (not verified). Nothing in the engine needs it: `StreamingConfiguration` offers Opus only (16 and 24 kHz) for the
  live view and talkback, and recording audio is AAC-LC.
- G.711 (A-law, µ-law) and 16-bit PCM in and out: yes, in 20 ms chunks.

AAC's first access unit is encoder priming and is dropped so the timeline matches the input; Opus has no such offset here.

## Tests

`Tests/PlatformLinuxCodecsTests` (Swift Testing): unit tests of the framing, argument building, clock and process layer with a fake
or ordinary Unix programs; tests against a real ffmpeg are skipped when there is none (`.enabled(if: FFmpegTesting.available)`).
`swift test --filter PlatformLinuxCodecsTests` on a Mac with Homebrew ffmpeg, or the same in a Swift Linux container with
`apt-get install ffmpeg fonts-dejavu-core`.
