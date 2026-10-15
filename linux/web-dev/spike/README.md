# Spike S1: MSE playback of recorded fragments over plain HTTP

Task T06 of the NVR build. A browser test bench, not part of the product (the image copies `linux/web` only; this folder is outside it).
It answers, per browser, whether the player design in addendum L7 works: init + key fragment and seek, lead-in decode, chain extension, far jumps,
two files with the same or another mime, huge and negative buffer times, overlaps and gaps, video-only output of a file with sound, codec support,
iPhone `ManagedMediaSource`, the hold-back margin, and several 8 MP surfaces at once. It is served over plain HTTP with the daemon's exact
Content-Security-Policy (T00 C.8), so it proves what the box's page can do.

```
sh make-fixtures.sh                       build the fixtures into out/ (needs ffmpeg, ffprobe, node)
node server.mjs --sample-cpu              serve the page, the fixtures and a results drop box on 127.0.0.1 (port 8099)
CB_SPIKE_LAN_YES="owner said yes in chat" node server.mjs --lan --sample-cpu   the same on the LAN for at most 60 minutes, only after the owner's yes
open  http://spike.test:8099/?label=chrome-mac&auto=1    Chrome with --host-resolver-rules="MAP spike.test 127.0.0.1"; tab in front, screen awake
node summarize.mjs --write                RESULTS.md (the tables) and DECISION.json (what the player tasks read)
node --test test/*.test.mjs               the tests of the tools themselves
```

Labels: `chrome-mac`, `safari-mac`, `firefox-mac`, `ipad-safari`, `iphone-safari`; add `-sim` for an iOS simulator and any `-run2` style suffix.
`?only=c01,c04` runs some cases, `?managed=1` forces ManagedMediaSource, `?max-tiles=4` limits case 12, `?csp=old` runs the control with the daemon's current policy.
The server writes `results/<label>.json` while the page runs. The full procedure, the decision rules and the Sunday go/no-go are in
`docs/superpowers/plans/2026-10-10-nvr/T06-browser-spike-mse.md`.
