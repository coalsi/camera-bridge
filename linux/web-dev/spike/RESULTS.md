# Spike S1 results: MSE playback of recorded fragments over plain HTTP

Generated 2026-10-11T05:03:19.820Z by summarize.mjs from 1 run(s): chrome-mac-run2.

## Decision

**KEY STEPS: GO for chrome-mac.** The floor (settle-based scrubbing) applies to: safari-mac, firefox-mac, ipad-safari, iphone-safari, and to any browser not in this list.

| Decision | Value | Why |
| --- | --- | --- |
| key step, chrome-mac | on | device evidence; key pictures right, best drag step p95 34.6 ms |
| key step, safari-mac | off | none evidence; no run for this browser class |
| key step, firefox-mac | off | none evidence; no run for this browser class |
| key step, ipad-safari | off | none evidence; no run for this browser class |
| key step, iphone-safari | off | none evidence; no run for this browser class |
| key step, other browsers | off | unknown browsers get the floor |
| iPhone | cannot-play | no run |
| tile cap, chrome-mac | 1 | 8 MP tiles that held 16 fps: 1 |
| tile cap, safari-mac | 4 | no run: the addendum default |
| tile cap, firefox-mac | 4 | no run: the addendum default |
| tile cap, ipad-safari | 4 | no run: the addendum default |
| tile cap, iphone-safari | 2 | no run: the addendum default |
| hold canvas, chrome-mac | false | the element keeps its picture after its range is removed |
| hold canvas, safari-mac | true | not measured: keep the canvas |
| hold canvas, firefox-mac | true | not measured: keep the canvas |
| hold canvas, ipad-safari | true | not measured: keep the canvas |
| hold canvas, iphone-safari | true | not measured: keep the canvas |
| MIME change | recreate | recreate the MediaSource unless changeType is faster and works in every tested class (Chrome and Safari on devices) |
| jump protocol | abort+offset+init | how a chain starts far from held data: the simplest of offset, abort+offset, offset+init, abort+offset+init that passes in every tested class |
| seek margin | 700 ms | data that must lie after the target before a seek into held data is allowed |

## This browser

|  | chrome-mac | safari-mac | firefox-mac | ipad-safari | iphone-safari |
| --- | --- | --- | --- | --- | --- |
| run | chrome-mac-run2 | - | - | - | - |
| evidence | device | - | - | - | - |
| origin kind | name | - | - | - | - |
| isSecureContext | false | - | - | - | - |
| typeof VideoDecoder | undefined | - | - | - | - |
| MSE used | MediaSource | - | - | - | - |
| requestVideoFrameCallback | true | - | - | - | - |
| changeType | true | - | - | - | - |
| link to the server (Mbit/s) | 6452.8 | - | - | - | - |
| tab hidden during the run (ms) | 0 | - | - | - | - |

## The twelve cases

| case | chrome-mac | safari-mac | firefox-mac | ipad-safari | iphone-safari |
| --- | --- | --- | --- | --- | --- |
| c01 | pass | - | - | - | - |
| c02 | FAIL | - | - | - | - |
| c03 | pass | - | - | - | - |
| c04 | pass | - | - | - | - |
| c05 | pass | - | - | - | - |
| c06 | pass | - | - | - | - |
| c07 | pass | - | - | - | - |
| c08 | pass | - | - | - | - |
| c09 | pass | - | - | - | - |
| c10 | skip | - | - | - | - |
| c11 | FAIL | - | - | - | - |
| c12 | pass | - | - | - | - |

## Numbers

|  | chrome-mac | safari-mac | firefox-mac | ipad-safari | iphone-safari |
| --- | --- | --- | --- | --- | --- |
| c01 key picture, median (ms) | 9.9 | - | - | - | - |
| c01 drag, key steps per second (best variant) | 34.2 | - | - | - | - |
| c01 drag, one step p95 (ms) | 34.6 | - | - | - | - |
| c01 stored form with prft accepted | true | - | - | - | - |
| c02 exact frame, median (ms) | 13.5 | - | - | - | - |
| c02 within one frame (%) | 90.3 | - | - | - | - |
| c04 jump protocols that work | offset, abort+offset, offset+init, abort+offset+init | - | - | - | - |
| c05 changeType works | true | - | - | - | - |
| c05 advice | recreate | - | - | - | - |
| c03 picture kept when its range is removed | true | - | - | - | - |
| c03 appended before a quota error (MB) | 70+ | - | - | - | - |
| c06 a keyframe before time 0 loses its GOP | true | - | - | - | - |
| c07 smallest gap that stalls (ms) | 100 | - | - | - | - |
| c08 muxed sound on a video-only buffer | init rejected | - | - | - | - |
| c08 sound dropout stalls a muxed buffer | true | - | - | - | - |
| c10 startstreaming / endstreaming / bufferedchange seen | n/a | - | - | - | - |
| c11 least data after the target that always worked (ms) | 250 | - | - | - | - |
| c12 8 MP tiles at 16 fps (4256x1888) | 1 | - | - | - | - |
| c12 8 MP, 4 MP tiles: lowest fps (big 1/4/9, cap 4/9) | 20 / 14.6 / - / 14.6 / - | - | - | - | - |
| c12 browser CPU % while playing, big 1 / 4 / 9 tiles (Mac only) | 36 / 16 / - | - | - | - | - |

## Failed checks

- chrome-mac-run2 c02: the exact frame is on screen within 1.5 s (at least 95%) (28 of 31)
- chrome-mac-run2 c02: the shown frame is within one frame of the target (at least 95%) (28 of 31)
- chrome-mac-run2 c02: a lead-in under 100 frames is presented in 1.5 s every time (26 of 29)
- chrome-mac-run2 c11: with the target frame as the last buffered frame the picture is still shown (no hold-back) (8 of 10)

## Control: the CSP the daemon sends today

- chrome-mac-cspold: x0 pass (opened=false violations=1; hidden for 0 ms); violations [{"directive":"media-src","blocked":"blob"}]

## Runs not used for the decision

- chrome-mac-wifi (not all twelve cases (a single case, ?only=, the CSP control, or stopped early)): cases c01; link 99.7 Mbit/s; best drag step p50 86.7 ms, p95 94.4 ms

