# FMP4

Fragmented MP4 for HKSV recordings: init segment, keyframe-aligned `moof`+`mdat` fragments, GOP fragmenter, box reader.
Depends on MediaCore only (contract graph): no `BridgeSupport` import, so no logging — failures throw `FMP4Error`.

## Entry points

- `FMP4Muxer(configuration:)` → `initializationSegment()` once, then `fragment(_:)` per `FragmentGroup` (or the
  contract's `fragment(video:audio:)`, which cannot know where the next fragment starts; see Invariants).
- `GOPFragmenter(targetDuration:)` → `pushGroups(_:)` returns closed `FragmentGroup`s (video, audio, `nextDecodeTime`);
  `flushGroup()` returns the tail and resets; `flushGroups()` does too, splitting the tail in two when it would run
  past target + allowance (end a recording with it). The contract's `push(_:)` / `flush()` return the same groups as
  tuples.
- Recording pipeline: `for group in fragmenter.pushGroups(sample) { send(try muxer.fragment(group)) }`, then report
  `muxer.lastFragmentStatistics` (dropped/out-of-range audio, removed NAL units) to the log — FMP4 itself cannot log.
- `MP4BoxReader.parse(_:)` → `[MP4Box]` (recursive for containers, full-box containers and sample entries).

## Layout (matches ffmpeg `-movflags frag_keyframe+empty_moov+default_base_moof`)

- `ftyp` isom/0x200/[isom iso5 iso6 mp41]; `moov` = `mvhd` (timescale 1000, duration 0) + video `trak` (id 1, `tkhd`,
  `mdhd` = `videoTimescale`, `hdlr vide`, `vmhd`, `dinf/dref/url `, `stbl` with `stsd` → `avc1`+`avcC`+`pasp` or
  `hvc1`+`hvcC`+`pasp`, empty `stts/stsc/stsz/stco`; `pasp` = the SPS VUI sample aspect ratio (1:1 when absent) and the
  `tkhd` width = coded width × SAR, as ffmpeg writes them) + audio `trak` (id 2, `mdhd` = sample rate, `hdlr soun`, `smhd`,
  `mp4a` + `esds` from an ES_Descriptor wrapping the AudioSpecificConfig) + `mvex` with one `trex` per track.
- Fragment: [`prft` v1 flags 0 (NTP of the first sample's `wallClock`, media_time = video tfdt)] `moof`(`mfhd` seq from 1,
  per track `traf`(`tfhd` flags 0x020000 + track id, `tfdt` v1, ONE `trun` flags 0x701 [+0x800 cts] with data offset))
  + `mdat` (length-prefixed NALs, then audio AUs). Sample flags: key 0x02000000, delta 0x01010000, audio 0x02000000.

## Invariants

- tfdt of both tracks is rebased together: the first video frame of the muxer decodes at 0 (audio keeps its offset).
  Audio and video pts must share one origin. Video decode times (`dts ?? pts`) must increase strictly, also across
  fragments; audio before the recording start or not advancing is dropped. A fragment without audio has no audio traf.
- Durations: distance to the next sample. The last video sample ends at the group's `nextDecodeTime` (the closing
  keyframe's decode time), so tfdt(N+1) = tfdt(N) + Σ durations(N) (ISO/IEC 14496-12 §8.8.12, as ffmpeg's `frag_keyframe`
  lines the flushed track up with the next sample); without one (flushed tail, contract API, a value not after the last
  sample) it repeats the previous duration. The last audio sample lasts `sampleCount`.
- Samples: in-band parameter sets identical to the sample entry's, AUDs, end of sequence/stream, filler, H.264 SPS
  extension and empty NAL units are removed (`hvc1` keeps parameter sets in the sample entry only); a differing in-band parameter set
  throws `.videoFormatChanged`; frames left without NAL units are skipped.
- Audio: AAC-LC only — the AudioSpecificConfig must parse (an explicit frequency within 1…1 000 000 Hz, as for RTSP),
  have object type 2 and the format's sample rate (HE-AAC, AAC-ELD…
  throw `.unsupportedAudio`); a frame whose config differs throws `.audioFormatChanged`. Audio more than
  `FMP4Muxer.audioHorizon` (2 s) past the end of the fragment's video is dropped without moving the audio timeline.
- A frame whose codec or parameter sets (ignoring trailing zero bytes, order and duplicates) differ from the configuration
  throws `.videoFormatChanged`: start a new muxer. Failed calls leave the muxer (and `lastFragmentStatistics`) unchanged.
  `accepts(video:)` / `accepts(audio:)` answer the same checks beforehand (W4 review: a recording producer ends its
  stream cleanly, or converts the audio, instead of failing it).
- avcC/hvcC classify parameter sets by NAL type; avcC adds the High-profile tail (chroma/bit depth) for profiles
  100/110/122/144; hvcC takes profile/tier/level, chroma, bit depths, sub-layers and temporal-id nesting from the SPS
  (SPS fields, the sample aspect ratio and the AudioSpecificConfig come from MediaCore's package-visible parsers;
  FMP4 has no bitstream parser of its own),
  array_completeness 1 (required by `hvc1`). Both are byte-identical to ffmpeg 8.1 goldens.
- GOPFragmenter (see type doc): closes at a keyframe when the fragment is full (≥ target − 5 %) or when another GOP of
  the last length would overflow the target by more than a 50 ms jitter allowance, so fragments stay within HKSV's
  `fragmentLength` (2.1 s GOPs / 4 s target → 2.1 s fragments). A GOP merged on that guess stays pending until it is
  known to fit: when the GOP length varies (night-mode frame-rate drop, a GOP cut short by a reconnect, irregular IDRs)
  and a frame of it starts, or the next keyframe comes, past target + allowance (decode time, as muxed), the fragment
  before it is returned (ending at its keyframe) and it goes on alone; `flushGroups()` splits the tail the same way when,
  muxed (last frame repeating the previous duration), it would end past that. So a fragment of several GOPs never
  exceeds target + allowance (W4 review; `flush()` / `flushGroup()` keep the tail whole, up to one frame longer).
  Audio goes to the fragment covering its pts (early audio
  moves on, late audio joins the open fragment; misaligned clocks fall back to arrival order). Fragments cannot be split
  without a keyframe: GOP > target gives one GOP per fragment. An open fragment is bounded (video span
  max(4 × target, 30 s), 4 096 video or audio frames, 64 MiB): past a bound it is returned as is and delta frames are
  dropped until the next keyframe.
- MP4BoxReader never traps: size/truncation errors throw `.malformedBox`; nesting is capped at 32 levels.

## Additions beyond the contract

`FMP4Error`; `FMP4Muxer.configuration`; `FragmentGroup`, `GOPFragmenter.pushGroups(_:)` / `flushGroup()` / `flushGroups()`,
`FMP4Muxer.fragment(_:)` / `fragment(video:audio:nextDecodeTime:)`, `FMP4Muxer.FragmentStatistics`,
`FMP4Muxer.lastFragmentStatistics`, `FMP4Muxer.audioHorizon`, `FMP4Muxer.accepts(video:)` / `accepts(audio:)` (W4 review);
`MP4Box.headerSize` (+ defaulted `init` parameter), `payloadOffset`, `payloadSize`, `child(_:)`, `children(ofType:)`,
`descendant(atPath:)`; `MP4BoxReader.box(atPath:in:)`, `MP4BoxReader.maximumDepth`.

## Tests

Structural tests with ffmpeg goldens; real media from VideoToolbox (software encoder, deterministic IDRs) and
AVAudioConverter; playback via `AVAssetReader` (all frames decode, duration ≈ expected); `ffprobe -show_packets` and
`ffmpeg -xerror` decode when `/opt/homebrew/bin` has them (each tool run is killed after 30 s). avcC/hvcC are also
checked against VideoToolbox's own. Fragment length is checked on constant and variable GOPs (frame-rate drop, reconnect,
alternating and irregular IDR spacing). Decode-time continuity is checked on jittered, bursty, variable-frame-rate timelines;
SAR parsing on x264/x265/VideoToolbox SPSs and two synthetic SPSs that ffmpeg's `trace_headers` parses to the end.
Fuzz and property tests use a seeded `SeededGenerator`, so any failing input can be regenerated.

## References

Research brief §3.9 (normative), ISO/IEC 14496-12 (boxes), 14496-15 §5.3.3 / §8.3.3 (avcC/hvcC), 14496-1 §7.2.6.5
and 14496-14 §3.1.2 (ES_Descriptor), the HKSV research notes (not published) (prft, hvc1, tfdt rebasing).
