#!/usr/bin/env python3
"""Reads what a Camera Bridge NVR measurement run left behind and prints it as Markdown with a verdict per budget.

    python3 -I Tools/nvr_soak_report.py soak    ROOT                  # ROOT = the run directory of Tools/nvr-soak.sh (samples.csv, events.log, data/probe/)
    python3 -I Tools/nvr_soak_report.py verify  RECORDINGS [--kill-ts UNIX_SECONDS] [--decode N]   # sidecars against mp4s, then ffmpeg decodes
    python3 -I Tools/nvr_soak_report.py killloss RECORDINGS UNIX_SECONDS                              # the footage lost at kill -9, taken soon after the relaunch (retention deletes those files later)
    python3 -I Tools/nvr_soak_report.py budgets PROBE_DIR [PROBE_DIR ...]                           # the budgets of the Mac spec section 14
    python3 -I Tools/nvr_soak_report.py selftest

Nothing here writes anywhere but standard output. The budgets are the numbers of docs/superpowers/specs/2026-10-10-nvr-design.md section 14;
`measuredAt` says where a picture time was taken (display: read back from the layer; enqueue: the hand-over to the renderer).
"""
import csv
import json
import os
import statistics
import struct
import subprocess
import sys

# --------------------------------------------------------------------------------------------------------------------------- budgets

# id, scenario, label, extractor(result) -> number or None, operator, limit
def _run(result, cells):
    return next((r for r in result.get("runs", []) if r.get("cells") == cells), None)


def _nested(result, *path):
    value = result
    for key in path:
        if not isinstance(value, dict) or key not in value:
            return None
        value = value[key]
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def _picture_ms(result):
    return _nested(result, "displayMs", "p95") if result.get("readback") not in (None, "none") else _nested(result, "enqueueMs", "p95")


BUDGETS = [
    ("B1a", "scrubcost", "NVRSession.scrub(to:) on the main thread, p99, 9 cells (microseconds)", lambda r: _nested(_run(r, 9) or {}, "callUs", "p99"), "<=", 50),
    ("B1b", "scrubcost", "main-thread lateness during a 120 Hz drag, p99, 9 cells (ms; stands in for 0.3 ms per event)", lambda r: _nested(_run(r, 9) or {}, "mainLateMs", "p99"), "<=", 3.0),
    ("B2a", "keyframe", "picture of a new GOP after a scrub, p95 (ms)", _picture_ms, "<=", 80),
    ("B2b", "keyframe", "distinct pictures per second in a steady single-camera drag", lambda r: _nested(r, "steady", "picturesPerSecond"), ">=", 25),
    ("B3a", "exact", "exact frame after the 80 ms trigger, p95 (ms)", lambda r: _nested(r, "afterTriggerMs", "p95"), "<=", 250),
    ("B3b", "exact", "stills that show a frame more than one away from the target", lambda r: _nested(r, "frameErrors"), "==", 0),
    ("B4a", "grid", "pictures per tile per second during a 9-tile drag (the slowest tile)", lambda r: _nested(r, "minPerTile"), ">=", 10),
    ("B4b", "grid", "longest time any tile went without a picture during the drag (ms)", lambda r: _nested(r, "worstGapMs"), "<=", 250),
    ("B4c", "grid", "last picture of every tile after the drag ends, p95 (ms)", lambda r: _nested(r, "lastPictureAfterReleaseMs", "p95"), "<=", 400),
    ("B4d", "grid", "main-thread lateness during the 9-tile drag, p99 (ms)", lambda r: _nested(r, "mainLateMs", "p99"), "<=", 3.0),
    ("B5a", "play", "first picture after release (ms)", lambda r: _nested(r, "startMs"), "<=", 300),
    ("B5b", "play", "lateness of a picture against the clock, p95 (ms)", lambda r: _nested(r, "latenessMs", "p95"), "<=", 40),
    ("B5c", "play", "spread of the nine tiles' newest frames, max (frames; budget 1, plus half a frame of sampling error)", lambda r: _nested(r, "skewFramesMax"), "<=", 1.5),
]

OPERATORS = {"<=": lambda a, b: a <= b, ">=": lambda a, b: a >= b, "==": lambda a, b: a == b}


def verdicts(results):
    """results: {scenario: parsed json}. One row per budget: (id, label, value, limit text, verdict, note)."""
    rows = []
    for budget_id, scenario, label, extract, op, limit in BUDGETS:
        result = results.get(scenario)
        if result is None:
            rows.append((budget_id, label, None, f"{op} {limit}", "NOT RUN", "no probe/%s.json" % scenario))
            continue
        if "error" in result:
            rows.append((budget_id, label, None, f"{op} {limit}", "NOT RUN", str(result["error"])))
            continue
        value = extract(result)
        note = "%s, %s renderer" % (result.get("measuredAt", "enqueue"), result.get("renderer", "?"))
        if budget_id == "B1b" and _nested(result, "baselineMainLateMs", "p99") is not None:
            note += "; the same ticker with no scrubbing: p99 %.3g ms" % _nested(result, "baselineMainLateMs", "p99")
        if value is None:
            rows.append((budget_id, label, None, f"{op} {limit}", "UNMEASURED", note))
        else:
            rows.append((budget_id, label, value, f"{op} {limit}", "PASS" if OPERATORS[op](value, limit) else "FAIL", note))
    return rows


def render_budgets(rows):
    out = ["| id | budget | measured | limit | verdict | where |", "|---|---|---|---|---|---|"]
    for budget_id, label, value, limit, verdict, note in rows:
        shown = "-" if value is None else ("%.3g" % value)
        out.append(f"| {budget_id} | {label} | {shown} | {limit} | {verdict} | {note} |")
    return "\n".join(out)


def load_probe_dir(path):
    results = {}
    for name in ("scrubcost", "keyframe", "exact", "grid", "play"):
        file = os.path.join(path, name + ".json")
        if os.path.exists(file):
            with open(file) as handle:
                results[name] = json.load(handle)
    return results


# ------------------------------------------------------------------------------------------------------------------------ the sidecar

HEADER = 64


def read_sidecar(data):
    """The fields of a .cbidx header that a check needs (the index format): None when it is not a version 1 index of the right size."""
    if len(data) < HEADER or data[:4] != b"CBNX":
        return None
    version, flags = struct.unpack(">HH", data[4:8])
    start_ms, end_ms, mp4_size = struct.unpack(">qqQ", data[24:48])
    init_length, count, rollups = struct.unpack(">IIH", data[48:58])
    if version != 1 or len(data) != HEADER + rollups * 12 + count * 40:
        return None
    return {"flags": flags, "startMs": start_ms, "endMs": end_ms, "mp4Size": mp4_size, "initLength": init_length, "count": count, "rollups": rollups}


def make_sidecar(start_ms, end_ms, mp4_size, count=2, rollups=1):
    """A well-formed header for the selftest (records are zeros)."""
    head = b"CBNX" + struct.pack(">HH", 1, 0) + bytes(16) + struct.pack(">qqQ", start_ms, end_ms, mp4_size) + struct.pack(">IIH", 32, count, rollups) + bytes(6)
    return head + bytes(rollups * 12 + count * 40)


def scan_recordings(root):
    """Every mp4 under ROOT/<camera>/<date>/: its size, its sidecar's header (None if missing or bad)."""
    files = []
    for camera in sorted(os.listdir(root)):
        camera_dir = os.path.join(root, camera)
        if not os.path.isdir(camera_dir):
            continue
        for date in sorted(os.listdir(camera_dir)):
            date_dir = os.path.join(camera_dir, date)
            if not os.path.isdir(date_dir):
                continue
            for name in sorted(os.listdir(date_dir)):
                if not name.endswith(".mp4"):
                    continue
                path = os.path.join(date_dir, name)
                sidecar = path[:-4] + ".cbidx"
                header = None
                if os.path.exists(sidecar):
                    with open(sidecar, "rb") as handle:
                        header = read_sidecar(handle.read())
                files.append({"camera": camera, "path": path, "size": os.path.getsize(path), "index": header, "hasSidecar": os.path.exists(sidecar)})
    return files


def kill_loss(root, kill_ts):
    """The line about the footage lost at kill -9 (None when no file ended before it): the end of each camera's last file that ended at or before the kill."""
    tails = {}
    for f in scan_recordings(root):
        if f["index"]:
            end = f["index"]["endMs"] / 1000.0
            if end <= kill_ts + 2:
                tails[f["camera"]] = max(tails.get(f["camera"], 0), end)
    if not tails:
        return None
    losses = sorted(kill_ts - end for end in tails.values())
    return ("- footage lost at kill -9 (kill time minus the end of each camera's last file that ended before it): min %.1f s, median %.1f s, max %.1f s over %d cameras\n"
            "  budget: at most 2.5 s plus one frame interval plus the write (about 2.8 s); a file still open when the process died is repaired to its last whole fragment"
            % (losses[0], statistics.median(losses), losses[-1], len(losses)))


def verify(root, kill_ts=None, decode=6):
    files = scan_recordings(root)
    problems = [] if files else ["no mp4 files under " + root]
    unclosed = [f for f in files if not f["hasSidecar"]]
    bad = [f for f in files if f["hasSidecar"] and f["index"] is None]
    stale = [f for f in files if f["index"] and f["index"]["mp4Size"] != f["size"]]
    lines = [f"- mp4 files: {len(files)}; without a sidecar (open or torn): {len(unclosed)}; sidecars that are not valid: {len(bad)}; sidecars for another size: {len(stale)}"]
    problems += [f"no sidecar: {f['path']}" for f in unclosed] if kill_ts is None else []
    problems += [f"bad sidecar: {f['path']}" for f in bad] + [f"stale sidecar: {f['path']}" for f in stale]
    if kill_ts is not None:
        tails = {}
        for f in files:
            if f["index"]:
                end = f["index"]["endMs"] / 1000.0
                if end <= kill_ts + 2:
                    tails[f["camera"]] = max(tails.get(f["camera"], 0), end)
        if tails:
            losses = sorted(kill_ts - end for end in tails.values())
            lines.append("- footage lost at kill -9 (kill time minus the end of each camera's last file that ended before it): min %.1f s, median %.1f s, max %.1f s over %d cameras"
                         % (losses[0], statistics.median(losses), losses[-1], len(losses)))
            lines.append("  budget: at most 2.5 s plus one frame interval plus the write (about 2.8 s); a file still open when the process died is repaired to its last whole fragment")
    closed = [f for f in files if f["index"]]
    picks = []
    if closed:
        closed.sort(key=lambda f: f["index"]["startMs"])
        picks = closed[:2] + closed[-2:]
        if kill_ts is not None:
            near = sorted(closed, key=lambda f: abs(f["index"]["endMs"] / 1000.0 - kill_ts))[:2]
            picks = near + picks
    seen, chosen = set(), []
    for f in picks:
        if f["path"] not in seen:
            seen.add(f["path"])
            chosen.append(f)
    chosen = chosen[:decode]
    for f in chosen:
        result = subprocess.run(["ffmpeg", "-v", "error", "-xerror", "-i", f["path"], "-map", "0:v:0", "-f", "null", "-"], capture_output=True, text=True, timeout=900)
        ok = result.returncode == 0 and not result.stderr.strip()
        lines.append("- ffmpeg decode of %s: %s" % (os.path.relpath(f["path"], root), "clean" if ok else "FAILED " + result.stderr.strip()[:200]))
        if not ok:
            problems.append("decode failed: " + f["path"])
    lines.append("- verdict: " + ("PASS" if not problems else "FAIL (" + "; ".join(problems[:5]) + ")"))
    return "\n".join(lines), not problems


# -------------------------------------------------------------------------------------------------------------------------- the soak

def read_jsonl(path):
    rows = []
    if os.path.exists(path):
        with open(path) as handle:
            for line in handle:
                line = line.strip()
                if line:
                    try:
                        rows.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass
    return rows


def slope_per_hour(points):
    """Least-squares slope of (seconds, value) points, per hour; 0 for fewer than 3 points."""
    if len(points) < 3:
        return 0.0
    mean_x = statistics.fmean(p[0] for p in points)
    mean_y = statistics.fmean(p[1] for p in points)
    denominator = sum((p[0] - mean_x) ** 2 for p in points)
    return 0.0 if denominator == 0 else 3600 * sum((p[0] - mean_x) * (p[1] - mean_y) for p in points) / denominator


def read_events_log(path):
    """events.log of nvr-soak.sh: '<unix seconds> <name>' per line -> {name: [seconds, ...]}."""
    marks = {}
    if os.path.exists(path):
        with open(path) as handle:
            for line in handle:
                parts = line.split()
                if len(parts) >= 2:
                    marks.setdefault(parts[1], []).append(float(parts[0]))
    return marks


def soak(root):
    out = []
    samples = []
    path = os.path.join(root, "samples.csv")
    if os.path.exists(path):
        with open(path) as handle:
            for row in csv.DictReader(handle):
                samples.append({k: float(v) for k, v in row.items()})
    out.append("### Process and disk (samples.csv, %d samples)" % len(samples))
    segments = []
    for sample in samples:
        if not segments or segments[-1][-1]["pid"] != sample["pid"]:
            segments.append([])
        segments[-1].append(sample)
    out.append("| launch | samples | RSS start (MB) | RSS end (MB) | RSS max (MB) | growth after 10 min (MB/hour) | CPU mean (% of one core) | mp4 files max |")
    out.append("|---|---|---|---|---|---|---|---|")
    for index, segment in enumerate(segments, 1):
        t0 = segment[0]["ts"]
        settled = [(s["ts"] - t0, s["rss_kb"] / 1024) for s in segment if s["ts"] - t0 >= 600]
        out.append("| %d | %d | %.0f | %.0f | %.0f | %.1f | %.1f | %d |" % (index, len(segment), segment[0]["rss_kb"] / 1024, segment[-1]["rss_kb"] / 1024,
                   max(s["rss_kb"] for s in segment) / 1024, slope_per_hour(settled), statistics.fmean(s["cpu"] for s in segment), max(s["mp4"] for s in segment)))
    out.append("")
    heartbeat = read_jsonl(os.path.join(root, "data", "probe", "heartbeat.jsonl"))
    events = read_jsonl(os.path.join(root, "data", "probe", "events.jsonl"))
    marks = read_events_log(os.path.join(root, "events.log"))
    cameras = max((len(b.get("cameras", [])) for b in heartbeat), default=0)
    if segments and marks.get("launch-1"):
        t0 = marks["launch-1"][0]
        baseline = [s for s in segments[0] if 90 <= s["ts"] - t0 < 175]
        recording = [s for s in segments[0] if 240 <= s["ts"] - t0 < 600]
        if baseline and recording and cameras:
            rss = statistics.median(s["rss_kb"] for s in recording) / 1024 - statistics.median(s["rss_kb"] for s in baseline) / 1024
            cpu = statistics.fmean(s["cpu"] for s in recording) - statistics.fmean(s["cpu"] for s in baseline)
            out.append("### What Record costs (Record off for the first 180 s, on after: median RSS and mean CPU of minutes 4 to 10 against minutes 1.5 to 3)")
            out.append("- memory: %+.0f MB for %d cameras = %.0f MB per camera; budget about 22 MB per camera (20 MB plus 2.5 s of a 6.2 Mbps stream)" % (rss, cameras, rss / cameras))
            out.append("- CPU: %+.1f points of one core = %.2f per camera; budget 1 point per 4 Mbps camera, so about 1.55 for the demo camera's 6.2 Mbps" % (cpu, cpu / cameras))
            out.append("")
    out.append("### Archive and cameras (heartbeat.jsonl, %d beats)" % len(heartbeat))
    readies = [e for e in events if e.get("event") == "ready"]
    out.append("- archive ready after launch: " + (", ".join("%.0f ms" % e["ms"] for e in readies) + "  (the last is the relaunch after kill -9, when there is one)" if readies else "NEVER (no ready event)"))
    stopped = [e for e in events if e.get("event") == "engine-stopped"]
    begun = [e for e in events if e.get("event") == "quit-begin"]
    if stopped and begun:
        out.append("- quit: the engine had stopped %.1f s after Cmd-Q (within its 5 s limit: %s); recorders close within 3 s" % (stopped[-1]["t"] - begun[-1]["t"], stopped[-1].get("withinLimit")))
    not_recording, lags, used = 0, [], []
    record_on = min((e["t"] for e in events if e.get("event") == "record-on"), default=None)   # before it Record is off on purpose (the baseline minutes)
    states = {}
    for beat in heartbeat:
        if not beat.get("ready"):
            continue
        for camera in beat.get("cameras", []):
            if camera["state"] != "recording" and (record_on is None or beat.get("t", 0) >= record_on):
                not_recording += 1
                states[camera["state"]] = states.get(camera["state"], 0) + 1
            if camera.get("lag") is not None and camera["state"] == "recording":
                lags.append(camera["lag"])
        if beat.get("storage", {}).get("used") is not None:
            used.append(beat["storage"]["used"])
    out.append("- camera beats not in the recording state after the archive was ready and Record was on: %d%s" % (not_recording, "  (" + ", ".join("%s %d" % item for item in sorted(states.items())) + ")" if states else ""))
    if lags:
        lags.sort()
        out.append("- edge lag (now minus the newest footage), p50 %.2f s, p95 %.2f s, max %.2f s; budget: at most 2.5 s plus a frame plus the write (about 2.8 s)"
                   % (lags[len(lags) // 2], lags[min(len(lags) - 1, int(0.95 * len(lags)))], lags[-1]))
    if used:
        out.append("- bytes used by recordings: max %.2f GB (the limit and the open files together should keep it near the maximum size)" % (max(used) / 1e9))
    free_beats = [b["storage"]["free"] for b in heartbeat if b.get("ready") and b.get("storage", {}).get("free")]
    if free_beats and samples and samples[-1].get("free_vol_kb"):
        out.append("- free space of the recordings volume: the engine says %.2f GB, df says %.2f GB (the engine rounds to 10 MB and refreshes every 5 s)" % (free_beats[-1] / 1e9, samples[-1]["free_vol_kb"] * 1024 / 1e9))
    return "\n".join(out)


# ---------------------------------------------------------------------------------------------------------------------------- selftest

def selftest():
    # percentile/slope/sidecar/verdict logic on made-up numbers
    assert abs(slope_per_hour([(0, 100), (1800, 150), (3600, 200)]) - 100) < 1e-6
    assert slope_per_hour([(0, 1)]) == 0.0
    data = make_sidecar(1_000, 5_000, 4_096, count=2, rollups=1)
    parsed = read_sidecar(data)
    assert parsed and parsed["mp4Size"] == 4_096 and parsed["count"] == 2 and parsed["endMs"] == 5_000
    assert read_sidecar(data[:-1]) is None and read_sidecar(b"XXXX" + data[4:]) is None
    results = {
        "scrubcost": {"runs": [{"cells": 9, "callUs": {"p99": 12.0}, "mainLateMs": {"p99": 1.1}}]},
        "keyframe": {"readback": "layer", "displayMs": {"p95": 61.0}, "enqueueMs": {"p95": 30.0}, "steady": {"picturesPerSecond": 31.0}, "measuredAt": "display", "renderer": "receiver"},
        "exact": {"afterTriggerMs": {"p95": 300.0}, "frameErrors": 0},
        "grid": {"error": "fewer than 180 s recorded"},
    }
    rows = {row[0]: row for row in verdicts(results)}
    assert rows["B1a"][4] == "PASS" and rows["B1b"][4] == "PASS"
    assert rows["B2a"][2] == 61.0 and rows["B2a"][4] == "PASS" and rows["B2b"][4] == "PASS"
    assert rows["B3a"][4] == "FAIL" and rows["B3b"][4] == "PASS"
    assert rows["B4a"][4] == "NOT RUN" and rows["B5a"][4] == "NOT RUN"
    no_readback = {"keyframe": {"readback": "none", "enqueueMs": {"p95": 90.0}, "steady": {"picturesPerSecond": 10}}}
    rows = {row[0]: row for row in verdicts(no_readback)}
    assert rows["B2a"][2] == 90.0 and rows["B2a"][4] == "FAIL" and rows["B2b"][4] == "FAIL"
    assert "UNMEASURED" in {row[4] for row in verdicts({"exact": {"measuredAt": "enqueue"}})}
    # a whole run directory, made up: two launches (a kill between them), Record on after 180 s
    import tempfile
    with tempfile.TemporaryDirectory() as root:
        os.makedirs(os.path.join(root, "data", "probe"))
        with open(os.path.join(root, "samples.csv"), "w") as handle:
            handle.write("ts,pid,rss_kb,cpu,used_kb,mp4,cbidx,free_data_kb,free_vol_kb\n")
            for i in range(0, 900, 30):
                recording = i >= 200
                handle.write("%d,100,%d,%.1f,0,%d,0,50000000,20000000\n" % (1_000_000 + i, (300_000 + (200_000 if recording else 0)), 20.0 + (12.0 if recording else 0.0), i // 100))
            for i in range(900, 1200, 30):
                handle.write("%d,200,%d,%.1f,0,3,0,50000000,20000000\n" % (1_000_000 + i, 450_000, 30.0))
        with open(os.path.join(root, "events.log"), "w") as handle:
            handle.write("1000000 launch-1\n1000900 kill-9\n1000902 launch-2\n")
        with open(os.path.join(root, "data", "probe", "events.jsonl"), "w") as handle:
            for event in [{"event": "ready", "ms": 900.0, "t": 1}, {"event": "ready", "ms": 4100.0, "t": 2}, {"event": "quit-begin", "t": 100.0}, {"event": "engine-stopped", "t": 101.5, "withinLimit": True}]:
                handle.write(json.dumps(event) + "\n")
        with open(os.path.join(root, "data", "probe", "heartbeat.jsonl"), "w") as handle:
            for i in range(10):
                handle.write(json.dumps({"t": 1.0 + i, "ready": True, "storage": {"used": 9_000_000_000, "free": 20_000_000_000}, "cameras": [
                    {"name": "Soak 1", "state": "recording" if i != 4 else "waiting", "lag": 1.2}, {"name": "Soak 2", "state": "recording", "lag": 2.0}]}) + "\n")
        report = soak(root)
        assert "launch | samples" in report and "| 1 |" in report and "| 2 |" in report, report
        assert "memory: +195 MB for 2 cameras" in report or "memory: +196 MB for 2 cameras" in report, report
        assert "CPU: +12.0 points" in report, report
        assert "900 ms, 4100 ms" in report and "not in the recording state after the archive was ready and Record was on: 1  (waiting 1)" in report, report
        assert "quit: the engine had stopped 1.5 s after Cmd-Q" in report, report
        assert "the engine says 20.00 GB, df says 20.48 GB" in report, report
        assert scan_recordings(root) == []
        assert verify(root)[1] is False, "an empty recordings folder is a failed run"
        # the footage lost at the kill: each camera's last file that ended at or before it (one file ended 3 s before, one 0.4 s before, one after the kill)
        for camera, end_ms in [("Soak 1", 996_000), ("Soak 2", 999_600), ("Soak 2", 1_005_000)]:
            directory = os.path.join(root, camera, "2026-10-11")
            os.makedirs(directory, exist_ok=True)
            name = os.path.join(directory, "%d" % end_ms)
            with open(name + ".mp4", "wb") as handle:
                handle.write(b"\0" * 4096)
            with open(name + ".cbidx", "wb") as handle:
                handle.write(make_sidecar(end_ms - 60_000, end_ms, 4096))
        line = kill_loss(root, 1_000.0)
        assert line and "min 0.4 s" in line and "max 4.0 s" in line and "over 2 cameras" in line, line
        assert kill_loss(root, 100.0) is None
    print("selftest ok")


def main(argv):
    if len(argv) >= 2 and argv[1] == "selftest":
        selftest()
        return 0
    if len(argv) >= 3 and argv[1] == "soak":
        print(soak(argv[2]))
        return 0
    if len(argv) >= 3 and argv[1] == "verify":
        kill = float(argv[argv.index("--kill-ts") + 1]) if "--kill-ts" in argv else None
        decode = int(argv[argv.index("--decode") + 1]) if "--decode" in argv else 6
        text, ok = verify(argv[2], kill, decode)
        print(text)
        return 0 if ok else 1
    if len(argv) >= 4 and argv[1] == "killloss":
        line = kill_loss(argv[2], float(argv[3]))
        print(line or "- footage lost at kill -9: UNMEASURED (no file had ended before the kill)")
        return 0
    if len(argv) >= 3 and argv[1] == "budgets":
        merged = {}
        for directory in argv[2:]:
            for name, result in load_probe_dir(directory).items():
                merged.setdefault(name, result)
        print(render_budgets(verdicts(merged)))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
