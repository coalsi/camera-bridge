#!/usr/bin/env python3
"""Host side of the NVR tests in linux/os/test-vm.sh (tests nvr, nvr-archive, nvr-faults).

test-vm.sh boots a Camera Bridge OS image in QEMU and forwards the box's port 80 to the host. This program is the web client of
that test: it signs in, drives the NVR routes of docs/superpowers/plans/2026-10-10-nvr/T00-contracts.md (part C), checks every
answer against the contract and builds the files that test-vm.sh puts on the box (a seeded archive and a torn recording).
It prints one line per result:  "ok  <text>"  or  "FAIL <text>"  (any other line is information). The exit status is 0 only when
no line was FAIL. Python 3, standard library only.

    python3 -I linux/os/test-nvr.py selftest                      offline, a few seconds, no VM
    python3 -I linux/os/test-nvr.py PHASE --base URL --dir DIR    one phase against a running box (see PHASES)

The password comes from the environment variable CB_TEST_PASSWORD (never from the command line). Session cookie and CSRF token
are kept in DIR/state.json (mode 0600) between phases. Every wait has a deadline; CB_NVR_TIMEOUT_SCALE (default 1) stretches them
for slow emulation. Nothing here prints a password, a cookie or a token.
"""
import argparse
import contextlib
import datetime
import http.client
import http.server
import io
import json
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from urllib.parse import urlsplit

GIB = 1 << 30
# T00 C.8: the Content-Security-Policy of every answer after the NVR (exactly one directive more than before: media-src).
CSP = ("default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; media-src 'self' blob:; connect-src 'self'; "
       "font-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'")
# BridgeWeb/WebApp.swift addSecurityHeaders: the other six headers of every answer (the page, the API and the media alike); the CSP above is the seventh.
SECURITY_HEADERS = (("X-Content-Type-Options", "nosniff"), ("X-Frame-Options", "DENY"), ("Referrer-Policy", "no-referrer"),
                    ("Cross-Origin-Opener-Policy", "same-origin"), ("Cross-Origin-Resource-Policy", "same-origin"),
                    ("Permissions-Policy", "camera=(), microphone=(), geolocation=(self), payment=(), usb=()"))
# The FakeBox below implements what the phases need, not the whole contract, and says so on every answer; test-vm.sh does not run
# conformance.mjs (which checks the whole contract) against a server that sends this header. The daemon never sends it.
STAND_IN_HEADER = ("X-CB-Stand-In", "linux/os/test-nvr.py FakeBox")
# WebApp.swift sessionCookie: the attributes of cb_session (Max-Age is AuthStore.absoluteLifetime, 30 days). Plain HTTP, so no Secure.
SESSION_COOKIE = "cb_session=%s; Path=/; HttpOnly; SameSite=Strict; Max-Age=2592000"
ID_RE = re.compile(r"^[0-9a-f]{12}\.(0|[1-9][0-9]{0,6})$")
MIME_RE = re.compile(r'^video/mp4; codecs="avc1\.[0-9a-f]{6}"$')
SEGMENT_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}/[0-9]{2}-[0-9]{2}-[0-9]{2}$")
UUID_RE = re.compile(r"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$")
TIMEOUT_SCALE = max(0.1, float(os.environ.get("CB_NVR_TIMEOUT_SCALE", "1") or "1"))


# ---------------------------------------------------------------------------------------------------------------------------
# Results

class Report:
    def __init__(self):
        self.failed = 0
        self.passed = 0


REPORT = Report()


def clean(text, limit=300):
    """One printable line: server text is data, never trusted with control characters or length."""
    text = "".join(ch if ch.isprintable() else "?" for ch in str(text))
    return text if len(text) <= limit else text[:limit] + "..."


def say(line):
    print(line, flush=True)


def ok(text):
    REPORT.passed += 1
    say("ok  " + clean(text))


def bad(text):
    REPORT.failed += 1
    say("FAIL " + clean(text))


def note(text):
    say(clean(text))


def check(condition, good, wrong):
    (ok if condition else bad)(good if condition else wrong)
    return bool(condition)


class Abort(Exception):
    """A precondition failed; the rest of the phase makes no sense."""


def wait_until(probe, seconds, what, every=2.0):
    """Calls probe() (truthy result = done) until it succeeds or `seconds` (scaled) pass. Returns (result, elapsed seconds) or (None, elapsed)."""
    started = time.monotonic()
    deadline = started + seconds * TIMEOUT_SCALE
    while True:
        try:
            result = probe()
        except (OSError, http.client.HTTPException, ValueError, KeyError, TypeError):
            result = None
        if result:
            return result, time.monotonic() - started
        if time.monotonic() >= deadline:
            return None, time.monotonic() - started
        time.sleep(every)


# ---------------------------------------------------------------------------------------------------------------------------
# The .cbidx v1 sidecar (T00 B.8) and MP4 boxes, parsed independently of the Swift code

def parse_cbidx(data, mp4_size=None):
    """The checks of CBIndexFile.decode. Returns a dict; raises ValueError('<CBIndexError case>') for anything it would refuse."""
    if len(data) < 64:
        raise ValueError("truncated")
    if data[:4] != b"CBNX":
        raise ValueError("badMagic")
    version, flags = struct.unpack_from(">HH", data, 4)
    if version != 1:
        raise ValueError("unsupportedVersion")
    camera = uuid.UUID(bytes=bytes(data[8:24]))
    start, end, size = struct.unpack_from(">qqQ", data, 24)
    init_length, count, rollup_count = struct.unpack_from(">IIH", data, 48)
    if count > 100_000 or rollup_count > 1_000 or len(data) != 64 + rollup_count * 12 + count * 40:
        raise ValueError("sizeMismatch")
    if mp4_size is not None and size != mp4_size:
        raise ValueError("mp4SizeMismatch")
    rollups = [struct.unpack_from(">IIHH", data, 64 + 12 * i)[:3] for i in range(rollup_count)]
    records, next_free, position = [], init_length, 64 + 12 * rollup_count
    for index in range(count):
        offset, length, wall, media, duration, header, key, non_key, samples, back = struct.unpack_from(">QIIIIIIIHH", data, position)
        position += 40
        if not (offset >= next_free and offset + length <= size and length > 0 and header <= length and key <= length
                and back <= index and (key == 0 or back == 0)):
            raise ValueError("inconsistentRecord(%d)" % index)
        next_free = offset + length
        records.append({"offset": offset, "length": length, "wall": wall, "media": media, "duration": duration, "header": header,
                        "key": key, "nonKey": non_key, "samples": samples, "back": back})
    return {"flags": flags, "camera": camera, "start": start, "end": end, "mp4Size": size, "initLength": init_length,
            "rollups": rollups, "records": records}


def build_cbidx(camera, start, end, mp4_size, init_length, records, flags=0, rollups=()):
    out = bytearray(b"CBNX")
    out += struct.pack(">HH", 1, flags) + camera.bytes + struct.pack(">qqQ", start, end, mp4_size)
    out += struct.pack(">IIH", init_length, len(records), len(rollups)) + bytes(6)
    for non_key, peak, covered in rollups:
        out += struct.pack(">IIHH", non_key, peak, covered, 0)
    for r in records:
        out += struct.pack(">QIIIIIIIHH", r["offset"], r["length"], r["wall"], r["media"], r["duration"], r["header"], r["key"],
                           r["nonKey"], r["samples"], r["back"])
    return bytes(out)


def boxes(data, start=0, end=None):
    """(type, offset, size) of the boxes in data[start:end]; ValueError when a size does not fit."""
    end = len(data) if end is None else end
    position, found = start, []
    while position < end:
        if end - position < 8:
            raise ValueError("box header cut short")
        size, kind = struct.unpack_from(">I4s", data, position)
        header = 8
        if size == 1:
            size, header = struct.unpack_from(">Q", data, position + 8)[0], 16
        elif size == 0:
            size = end - position
        if size < header or position + size > end:
            raise ValueError("box %r has size %d at %d" % (kind, size, position))
        found.append((kind, position, size))
        position += size
    return found


def children(data, box):
    kind, offset, size = box
    return boxes(data, offset + 8, offset + size)


def fnv1a64(data):
    value = 0xCBF29CE484222325
    for byte in data:
        value = ((value ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return value


def file_key(segment):
    """ArchiveIdentity.fileKey(forSegment:): the first 12 of the 16 lowercase hex digits of the FNV-1a-64 hash of the UTF-8 path."""
    return format(fnv1a64(segment.encode("utf-8")), "016x")[:12]


def segment_of(camera_dir, start_ms):
    """'<CAMERA UUID>/<yyyy-MM-dd>/<HH-mm-ss>' in UTC, the box's time zone."""
    when = datetime.datetime.fromtimestamp(start_ms / 1000, datetime.timezone.utc)
    return "%s/%s/%s" % (camera_dir, when.strftime("%Y-%m-%d"), when.strftime("%H-%M-%S"))


# ---------------------------------------------------------------------------------------------------------------------------
# The web client

class Reply:
    def __init__(self, status, headers, body):
        self.status = status
        self.headers = headers
        self.body = body

    def json(self):
        return json.loads(self.body.decode("utf-8"))

    def header(self, name):
        return self.headers.get(name.lower())

    def code(self):
        try:
            return self.json().get("error")
        except (ValueError, AttributeError):
            return None


class Client:
    def __init__(self, base, directory):
        parts = urlsplit(base)
        self.host, self.port = parts.hostname, parts.port or 80
        self.origin = "http://%s:%d" % (self.host, self.port)
        self.directory = directory
        os.makedirs(directory, exist_ok=True)
        self.state_path = os.path.join(directory, "state.json")
        self.state = {}
        if os.path.exists(self.state_path):
            with open(self.state_path) as handle:
                self.state = json.load(handle)

    def save(self):
        descriptor = os.open(self.state_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            json.dump(self.state, handle)

    def raw(self, method, path, body=None, headers=None, cookie=True, csrf=True, origin=None, timeout=30):
        """One request on its own connection. `body` is a dict (sent as JSON) or bytes. Never follows redirects."""
        sent = {}
        data = None
        if body is not None:
            data = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
            sent["Content-Type"] = "application/json"
        if cookie and self.state.get("cookie"):
            sent["Cookie"] = "cb_session=" + self.state["cookie"]
        if method not in ("GET", "HEAD"):
            sent["Origin"] = origin or self.origin
            if csrf and self.state.get("csrf"):
                sent["X-CSRF-Token"] = self.state["csrf"]
        sent.update(headers or {})
        connection = http.client.HTTPConnection(self.host, self.port, timeout=timeout * max(1.0, TIMEOUT_SCALE))
        try:
            connection.request(method, path, body=data, headers=sent)
            response = connection.getresponse()
            payload = response.read()
            received = {name.lower(): value for name, value in response.getheaders()}
            return Reply(response.status, received, payload)
        finally:
            connection.close()

    def login(self):
        """Signs in with CB_TEST_PASSWORD; sets the password first when the box has none. Returns 'login' or 'setup'."""
        password = os.environ.get("CB_TEST_PASSWORD", "")
        if len(password) < 8:
            raise Abort("CB_TEST_PASSWORD is not set (at least 8 characters)")
        info = self.raw("GET", "/api/v1/session", cookie=False).json()
        if info.get("setupTokenRequired"):
            raise Abort("the box asks for a setup code; the image is not expected to")
        how = "setup" if info.get("setupRequired") else "login"
        reply = self.raw("POST", "/api/v1/auth/setup" if how == "setup" else "/api/v1/auth/login", {"password": password}, cookie=False,
                         csrf=False)
        if reply.status not in (200, 201):
            raise Abort("%s answered %d %s" % (how, reply.status, reply.code()))
        found = re.search(r"cb_session=([^;,\s]+)", reply.header("set-cookie") or "")
        if not found:
            raise Abort("no session cookie after %s" % how)
        self.state["cookie"], self.state["csrf"] = found.group(1), reply.json()["csrfToken"]
        self.save()
        return how

    def api(self, method, path, body=None, **options):
        """raw() with one automatic sign-in when the session has ended (a daemon restart or a reboot)."""
        reply = self.raw(method, path, body, **options)
        if reply.status == 401 and options.get("cookie", True):
            self.login()
            reply = self.raw(method, path, body, **options)
        return reply

    @property
    def camera(self):
        if not self.state.get("camera"):
            raise Abort("no camera yet (phase add-camera)")
        return self.state["camera"]

    def camera_json(self):
        reply = self.api("GET", "/api/v1/cameras/" + self.camera)
        return reply.json() if reply.status == 200 else None

    def nvr_state(self):
        camera = self.camera_json()
        return (camera or {}).get("status", {}).get("nvr", {}).get("state")

    def extent(self):
        """(reply, this camera's entry of GET nvr/cameras or None)."""
        reply = self.api("GET", "/api/v1/nvr/cameras")
        if reply.status != 200:
            return reply, None
        for entry in reply.json().get("cameras", []):
            if entry.get("id", "").lower() == self.camera:
                return reply, entry
        return reply, None

    def plan(self, at, ahead=1):
        return self.api("GET", "/api/v1/nvr/cameras/%s/fragments?at=%d&ahead=%d" % (self.camera, at, ahead))


# ---------------------------------------------------------------------------------------------------------------------------
# Checks shared by several phases

def validate_plan(plan, at):
    """Problems in a 200 'found' answer of GET fragments?at= (T00 C.5 R7); an empty list means it is as the contract says."""
    problems = []
    for key in ("serverTime", "found", "at", "exact", "targetIndex", "parts", "files"):
        if key not in plan:
            problems.append("missing " + key)
    if problems:
        return problems
    parts, files = plan["parts"], plan["files"]
    if not parts:
        return ["no parts"]
    index = plan["targetIndex"]
    if not isinstance(index, int) or not 0 <= index < len(parts):
        problems.append("targetIndex out of range")
    elif not parts[index]["start"] <= at < parts[index]["end"]:
        problems.append("the target part does not contain the time asked for")
    if not parts[0].get("key"):
        problems.append("the first part is not a key fragment")
    previous = None
    for part in parts:
        if not ID_RE.match(part.get("id", "")) or part["id"].split(".")[0] != part.get("file"):
            problems.append("bad id %r" % part.get("id"))
        if not (isinstance(part.get("start"), int) and isinstance(part.get("end"), int) and part["end"] > part["start"]):
            problems.append("bad times in %s" % part.get("id"))
        if not (isinstance(part.get("bytes"), int) and part["bytes"] > 0):
            problems.append("bad size in %s" % part.get("id"))
        if previous and previous["file"] == part["file"]:
            if int(part["id"].split(".")[1]) != int(previous["id"].split(".")[1]) + 1:
                problems.append("indexes of %s do not follow %s" % (part["id"], previous["id"]))
            if abs(part["start"] - previous["end"]) > 2:
                problems.append("%s does not abut the part before it" % part["id"])
        previous = part
    if set(files) != {part["file"] for part in parts}:
        problems.append("files do not match the parts")
    for name, info in files.items():
        if not MIME_RE.match(info.get("mime", "")):
            problems.append("mime of %s is %r" % (name, info.get("mime")))
        if not (isinstance(info.get("width"), int) and info["width"] > 0 and isinstance(info.get("height"), int) and info["height"] > 0):
            problems.append("size of %s" % name)
        if not isinstance(info.get("anchor"), (int, float)) or not isinstance(info.get("sound"), bool):
            problems.append("anchor or sound of %s" % name)
        if info.get("initId") not in [part["id"] for part in parts if part["file"] == name]:
            problems.append("initId of %s is not one of its parts" % name)
    return problems


def media_problems(reply, label):
    """Headers every media answer must have (T00 C.3, C.8)."""
    problems = []
    if reply.header("content-type") != "video/mp4":
        problems.append("%s: content type %r" % (label, reply.header("content-type")))
    if reply.header("cache-control") != "no-store":
        problems.append("%s: cache-control %r" % (label, reply.header("cache-control")))
    if reply.header("content-security-policy") != CSP:
        problems.append("%s: the content security policy is not the pinned one" % label)
    if reply.header("content-length") != str(len(reply.body)):
        problems.append("%s: content length %r for %d bytes" % (label, reply.header("content-length"), len(reply.body)))
    if len(reply.body) > 16 * 1_048_576:
        problems.append("%s: %d bytes is over 16 MiB" % (label, len(reply.body)))
    return problems


def segment_problems(body, label, video_only=True):
    """A served segment is moof + mdat and nothing else (no prft); with sound in the file the moof still holds one track fragment."""
    try:
        top = boxes(body)
    except ValueError as error:
        return ["%s: %s" % (label, error)]
    problems = []
    if [kind for kind, _, _ in top] != [b"moof", b"mdat"]:
        problems.append("%s: boxes are %s, expected moof and mdat" % (label, [kind.decode("latin-1") for kind, _, _ in top]))
        return problems
    inside = [kind for kind, _, _ in children(body, top[0])]
    if video_only and inside.count(b"traf") != 1:
        problems.append("%s: %d track fragments in the moof, expected 1" % (label, inside.count(b"traf")))
    return problems


def init_problems(body, label):
    try:
        top = boxes(body)
    except ValueError as error:
        return ["%s: %s" % (label, error)]
    kinds = [kind for kind, _, _ in top]
    if kinds[:2] != [b"ftyp", b"moov"]:
        return ["%s: boxes are %s, expected ftyp and moov first" % (label, [kind.decode("latin-1") for kind in kinds])]
    inside = [kind for kind, _, _ in children(body, top[1])]
    if inside.count(b"trak") != 1:
        return ["%s: %d tracks in the init segment, expected the video track only" % (label, inside.count(b"trak"))]
    return []


def fetch_chain(client, plan, label):
    """Fetches the init segment and every part of a plan. Returns (init bytes, [part bytes], problems)."""
    problems = []
    first = plan["parts"][0]
    init_id = plan["files"][first["file"]]["initId"]
    path = "/api/v1/nvr/cameras/%s/fragments/%s" % (client.camera, init_id)
    reply = client.api("GET", path + "/init")
    if reply.status != 200:
        return b"", [], ["%s: init answered %d %s" % (label, reply.status, reply.code())]
    problems += media_problems(reply, label + " init") + init_problems(reply.body, label + " init")
    segments = []
    for part in plan["parts"]:
        got = client.api("GET", "/api/v1/nvr/cameras/%s/fragments/%s" % (client.camera, part["id"]))
        if got.status != 200:
            problems.append("%s: part %s answered %d %s" % (label, part["id"], got.status, got.code()))
            continue
        sound = plan["files"][part["file"]]["sound"]
        problems += media_problems(got, "%s %s" % (label, part["id"])) + segment_problems(got.body, "%s %s" % (label, part["id"]))
        if not sound and len(got.body) != part["bytes"]:
            problems.append("%s: %s has %d bytes, the plan said %d" % (label, part["id"], len(got.body), part["bytes"]))
        segments.append(got.body)
    return reply.body, segments, problems


# ---------------------------------------------------------------------------------------------------------------------------
# Phases against a running box

def storage(client):
    return client.api("GET", "/api/v1/nvr/storage").json()


def phase_session(client, args):
    how = client.login()
    ok("signed in" if how == "login" else "the first-run setup set the password and signed in")
    status = client.api("GET", "/api/v1/status").json()
    check(status.get("authenticated") is True, "the status answer knows the session", "the status answer does not know the session")


def phase_add_camera(client, args):
    reply = client.api("POST", "/api/v1/cameras", {"type": "demo", "name": args.camera_name, "audioEnabled": False}, timeout=90)
    if not check(reply.status == 201, "the demo camera was added", "adding the demo camera answered %d %s" % (reply.status, reply.code())):
        raise Abort("no camera")
    camera = reply.json()
    client.state["camera"] = camera["id"].lower()
    client.save()
    nvr = camera.get("status", {}).get("nvr", {})
    check(camera.get("nvrEnabled") is False and camera.get("nvrRecordSound") is False, "Record and Record sound are off by default",
          "the camera starts with nvrEnabled=%r nvrRecordSound=%r" % (camera.get("nvrEnabled"), camera.get("nvrRecordSound")))
    check(nvr.get("state") == "off" and nvr.get("notes") == [] and nvr.get("pause") is None, "status.nvr of a new camera is off, no notes, no pause",
          "status.nvr of a new camera is %r" % (nvr,))


def phase_folder_required(client, args):
    before = storage(client)
    if before.get("location") is not None:
        note("a folder is already chosen; the folder_required case is not tested")
        return
    check(before.get("state") == "noFolder" and before.get("recordingCameras") == 0, "storage before the first choice: state noFolder, no recording camera",
          "storage before the first choice is %r" % ({k: before.get(k) for k in ("state", "recordingCameras", "location")},))
    reply = client.api("PATCH", "/api/v1/cameras/%s/nvr" % client.camera, {"enabled": True})
    check(reply.status == 409 and reply.code() == "folder_required", "Record on without a folder: 409 folder_required",
          "Record on without a folder answered %d %s" % (reply.status, reply.code()))
    camera = client.camera_json()
    check(camera and camera.get("nvrEnabled") is False, "nothing changed after folder_required", "the camera changed after folder_required")


def phase_choose_folder(client, args):
    reply = client.api("GET", "/api/v1/nvr/storage/locations")
    listed = reply.json().get("locations", []) if reply.status == 200 else []
    entry = listed[0] if len(listed) == 1 else {}
    check(len(listed) == 1 and entry.get("id") == "builtin" and re.match(r"^This box.s storage$", entry.get("label", "")) is not None
          and entry.get("path") == args.recordings_path and entry.get("writable") is True and entry.get("problem") is None,
          "one location: the box's own storage at %s, writable" % args.recordings_path, "locations are %r" % (listed,))
    reply = client.api("PATCH", "/api/v1/nvr/storage", {"location": "builtin"})
    if not check(reply.status == 200, "choosing the location answered 200", "choosing the location answered %d %s" % (reply.status, reply.code())):
        raise Abort("no folder")
    body = reply.json()
    required = {"location", "label", "state", "message", "recordingCameras", "keepDays", "maxSizeGB", "limits", "usedBytes", "freeBytes",
                "totalBytes", "floorBytes", "roomBytes", "effectiveMaxBytes", "oldest", "newest"}
    check(required <= set(body), "the storage answer has every key of the contract", "storage lacks %s" % sorted(required - set(body)))
    check(body.get("location") == "builtin" and body.get("state") == "ok" and body.get("message") is None,
          "storage is ok at the built-in location", "storage says %r" % ({k: body.get(k) for k in ("location", "state", "message")},))
    check(body.get("keepDays") == 7 and body.get("maxSizeGB") == 500 and body.get("limits") == {"keepDays": [1, 365], "maxSizeGB": [10, 100000]},
          "defaults: keep 7 days, 500 GB, limits 1...365 and 10...100000", "defaults are %r" % ({k: body.get(k) for k in ("keepDays", "maxSizeGB", "limits")},))
    total, free, floor = body.get("totalBytes", 0), body.get("freeBytes", 0), body.get("floorBytes", 0)
    check(floor == max(8 * GIB, total // 20), "the floor is max(8 GiB, 5%%) of the data partition (%d MiB)" % (floor >> 20),
          "the floor is %d bytes for a partition of %d" % (floor, total))
    check(body.get("roomBytes") == body.get("usedBytes", 0) + max(0, free - floor), "roomBytes = used + (free - floor)", "roomBytes does not follow the formula")
    expected = min(500 * 10**9, max(0, total - 2 * floor))
    check(body.get("effectiveMaxBytes") == expected, "effectiveMaxBytes = min(500 GB, total - 2 x floor) = %d MB" % (expected >> 20),
          "effectiveMaxBytes is %r, the formula gives %d" % (body.get("effectiveMaxBytes"), expected))
    if expected < 6 * 10**9:
        bad("the data partition (%d MiB) leaves room for only %d MB of recordings; the nvr tests need a disk of 32G (--disk-size 32G)" % (total >> 20, expected >> 20))
        raise Abort("disk too small")


def phase_record_on(client, args):
    reply = client.api("PATCH", "/api/v1/cameras/%s/nvr" % client.camera, {"enabled": True})
    if not check(reply.status == 200 and reply.json().get("nvrEnabled") is True, "Record switched on", "Record on answered %d %s" % (reply.status, reply.code())):
        raise Abort("record on failed")
    found, seconds = wait_until(lambda: client.nvr_state() == "recording", 120, "recording")
    if not found:
        bad("the camera is not recording after %.0f s (state %s)" % (seconds, last_state(client)))
        raise Abort("not recording")
    ok("the camera is recording after %.0f s" % seconds)
    wait_for_span(client, args.seconds)


def last_state(client):
    try:
        return repr(client.nvr_state())
    except (OSError, http.client.HTTPException, ValueError, KeyError):
        return "unknown (the box does not answer)"


def newest_reaches_back(client, seconds):
    """Looks at the end of the newest recording and at the time `seconds` before it. Returns (extent entry, that earlier time or None, what was seen).

    The extent of a camera runs from its oldest recording to its newest, so "newest - oldest" says nothing about the file that is being written
    now: after a power cut or a restart the archive can span hours or days, then a gap, then a new file of a few seconds. So this asks the plan
    route: the earlier time is returned when it lies in the same recording file as the end, which means that the newest file is at least
    `seconds` long and that a time `seconds` before its end is inside it, not in the gap before it."""
    entry = client.extent()[1]
    if not entry:
        return None, None, "the box lists no recording of the camera"
    at = entry["newest"] - max(1, int(seconds * 1000))
    end, early = client.plan(entry["newest"] - 1, 0), client.plan(at, 0)
    ends, starts = (end.json() if end.status == 200 else {}), (early.json() if early.status == 200 else {})
    if not ends.get("found"):
        return entry, None, "the end of the newest recording is not found (%d %s)" % (end.status, ends.get("reason") or end.code())
    if not starts.get("found"):
        return entry, None, "the time %.0f s before its end %s" % (seconds, "lies in a gap (nothing is recorded there)" if starts.get("reason") == "gap" else "is not found: %s (%d)" % (starts.get("reason"), early.status))
    last, first = ends["parts"][ends["targetIndex"]]["file"], starts["parts"][starts["targetIndex"]]["file"]
    if first != last:
        return entry, None, "the time %.0f s before its end lies in the file before it" % seconds
    return entry, at, "the time %.0f s before its end lies in the same file" % seconds


def wait_newest_reaches_back(client, seconds, limit):
    """newest_reaches_back() until it succeeds or `limit` (scaled) seconds pass. Returns (entry, at or None, seconds waited, what was seen last)."""
    seen = {"entry": None, "why": "the box did not answer"}

    def probe():
        seen["entry"], at, seen["why"] = newest_reaches_back(client, seconds)
        return at

    got, took = wait_until(probe, limit, "the newest recording")
    return seen["entry"], got, took, seen["why"]


def inside_newest(client, seconds, limit=60):
    """(entry, at): a time `seconds` before the end of the newest recording that lies inside it. Waits for the file to be that long; when it
    never is, says so (a FAIL line) and stops the phase, instead of asking the box for a time in a gap."""
    entry, at, took, why = wait_newest_reaches_back(client, seconds, limit)
    if at is None:
        bad("the newest recording is not %d s long after %.0f s: %s" % (seconds, took, why))
        raise Abort("the newest recording is too short")
    if took >= 1:
        note("waited %.0f s for the newest recording to be %d s long" % (took, seconds))
    return entry, at


def wait_for_span(client, seconds):
    """The newest recording is `seconds` long. (Not the extent: that spans every recording of the camera, the seeded archive of nvr-archive included.)"""
    entry, at, took, why = wait_newest_reaches_back(client, seconds, 120)
    check(at is not None, "%d s of the newest recording are listed after %.0f s" % (seconds, took),
          "the newest recording is not %d s long after %.0f s: %s" % (seconds, took, why))
    if at is None:
        raise Abort("no extent")


def phase_wait_recording(client, args):
    found, seconds = wait_until(lambda: client.nvr_state() == "recording", 120, "recording")
    if found:
        ok("recording again after %.0f s" % seconds)
    else:
        bad("not recording after %.0f s (state %s)" % (seconds, last_state(client)))
    if found and args.seconds:
        wait_for_span(client, args.seconds)


def phase_fetch(client, args):
    reply, entry = client.extent()
    if not check(entry is not None, "GET nvr/cameras lists the camera", "GET nvr/cameras answered %d %s without the camera" % (reply.status, reply.code())):
        raise Abort("no extent")
    body = reply.json()
    check(isinstance(body.get("serverTime"), int) and isinstance(body.get("catalogVersion"), int) and isinstance(entry.get("oldest"), int)
          and isinstance(entry.get("newest"), int), "extent: serverTime, catalogVersion, and oldest and newest in milliseconds",
          "extent answer is %r" % (body,))
    gop = entry.get("typicalGOP")
    note("recorded %.1f s, typical keyframe interval %s" % ((entry["newest"] - entry["oldest"]) / 1000, "%.1f s" % gop if gop else "not known yet"))
    entry, at = inside_newest(client, 3)   # newest - 3 s lies in a gap while the newest file is shorter than that (a recorder that has just restarted)
    reply = client.plan(at, 1)
    plan = reply.json() if reply.status == 200 else {}
    if not check(reply.status == 200 and plan.get("found") is True, "fragments?at= finds the recording", "fragments?at= answered %d %r" % (reply.status, plan)):
        raise Abort("no plan")
    problems = validate_plan(plan, at)
    check(not problems, "the plan follows the contract (%d parts, target %d)" % (len(plan["parts"]), plan["targetIndex"]), "the plan: " + "; ".join(problems[:4]))
    init, segments, problems = fetch_chain(client, plan, "chain")
    check(not problems, "init and %d fragments come back as video-only fMP4, headers as pinned" % len(segments), "; ".join(problems[:4]))
    with open(os.path.join(client.directory, "served.mp4"), "wb") as handle:
        handle.write(init + b"".join(segments))
    # the keyframe route is the whole key fragment, the same bytes as the fragment route
    first = plan["parts"][0]
    reply = client.api("GET", "/api/v1/nvr/cameras/%s/keyframe?at=%d" % (client.camera, at))
    header = {}
    try:
        header = json.loads(reply.header("x-cb-part") or "{}")
    except ValueError:
        pass
    check(reply.status == 200 and reply.body == segments[0] and header.get("id") == first["id"] and header.get("file") == first["file"],
          "keyframe?at= is the key fragment %s with X-CB-Part" % first["id"], "keyframe?at= answered %d, header %r" % (reply.status, header))
    wanted = {"id", "file", "start", "end", "mime", "width", "height", "anchor", "initId"}
    check(wanted <= set(header), "X-CB-Part has every key", "X-CB-Part lacks %s" % sorted(wanted - set(header)))
    # the clock the page uses
    serial = client.api("GET", "/api/v1/nvr/cameras").json()
    check(abs(serial["serverTime"] - int(time.time() * 1000)) < 5 * 60 * 1000, "the box clock is within 5 minutes of this computer's",
          "the box clock is %d s from this computer's" % ((serial["serverTime"] - int(time.time() * 1000)) // 1000))
    # a time with nothing recorded, and one after everything
    early = client.plan(1_000_000_000_000, 0).json()
    check(early.get("found") is False and early.get("reason") == "beforeStart", "a time before the first recording: found false, beforeStart",
          "a time before the first recording: %r" % (early,))
    late = client.plan(entry["newest"] + 600_000, 0).json()
    check(late.get("found") is False and late.get("reason") == "afterEnd", "a time after the last recording: found false, afterEnd", "a time after: %r" % (late,))
    stranger = client.api("GET", "/api/v1/nvr/cameras/%s/fragments?at=%d" % (str(uuid.uuid4()).upper(), at)).json()
    check(stranger.get("found") is False and stranger.get("reason") == "empty", "an unknown camera looks like one without recordings",
          "an unknown camera: %r" % (stranger,))
    activity = client.api("GET", "/api/v1/nvr/activity?cameras=%s&from=%d&binMs=2000&bins=10" % (client.camera, entry["newest"] - 20_000))
    shape = activity.json() if activity.status == 200 else {}
    per = shape.get("byCamera", {}).get(client.camera.upper()) or shape.get("byCamera", {}).get(client.camera) or {}
    check(activity.status == 200 and len(per.get("coverage", [])) == 10 and len(per.get("level", [])) == 10 and shape.get("from", 1) % 2000 == 0,
          "activity: 10 bins of coverage and level, from snapped to the bin", "activity answered %d %r" % (activity.status, shape if activity.status != 200 else per))


def phase_security(client, args):
    cid = client.camera
    extent, at = inside_newest(client, 3)
    fid = client.plan(at, 0).json()["parts"][0]["id"]
    media = "/api/v1/nvr/cameras/%s/fragments/%s" % (cid, fid)
    for path in ("/api/v1/nvr/storage", "/api/v1/nvr/storage/locations", "/api/v1/nvr/cameras", media, media + "/init",
                 "/api/v1/nvr/cameras/%s/keyframe?at=1760000000000" % cid, "/api/v1/nvr/activity?cameras=%s&from=0&binMs=1000&bins=1" % cid):
        reply = client.raw("GET", path, cookie=False)
        if reply.status != 401 or reply.code() != "unauthorized":
            bad("without a session %s answered %d %s" % (path.split("?")[0].replace(cid, ":id").replace(fid, ":fid"), reply.status, reply.code()))
            break
    else:
        ok("every NVR route answers 401 without a session")
    write = "/api/v1/cameras/%s/nvr" % cid
    reply = client.raw("PATCH", write, {"recordSound": False}, csrf=False)
    check(reply.status == 403 and reply.code() == "csrf", "a write without the CSRF token: 403 csrf", "a write without the token answered %d %s" % (reply.status, reply.code()))
    reply = client.raw("PATCH", write, {"recordSound": False}, origin="http://other.example")
    check(reply.status == 403 and reply.code() == "cross_origin", "a write from another origin: 403 cross_origin", "another origin answered %d %s" % (reply.status, reply.code()))
    reply = client.raw("PATCH", write, b'{"recordSound": false}', headers={"Content-Type": "text/plain"})
    check(reply.status == 415, "a write that is not JSON: 415", "a write with text/plain answered %d" % reply.status)
    reply = client.raw("HEAD", media)
    check(reply.status == 405 and (reply.header("allow") or "").upper() == "GET" and reply.body == b"", "HEAD on a media route: 405, Allow GET",
          "HEAD on a media route answered %d allow=%r" % (reply.status, reply.header("allow")))
    # bad input never reaches the archive
    cases = [("at=abc", 400, "invalid"), ("at=1", 400, "invalid"), ("", 400, "invalid"), ("at=%d&after=%s" % (extent["newest"], fid), 400, "invalid")]
    wrong = []
    for query, status, code in cases:
        got = client.api("GET", "/api/v1/nvr/cameras/%s/fragments?%s" % (cid, query))
        if (got.status, got.code()) != (status, code):
            wrong.append("%r gave %d %s" % (query, got.status, got.code()))
    check(not wrong, "fragments with a bad, missing or doubled time: 400 invalid", "; ".join(wrong))
    wrong = []
    for path, status, code in [("/api/v1/nvr/cameras/%s/fragments/not-an-id" % cid, 400, "invalid"),
                               ("/api/v1/nvr/cameras/%s/fragments/000000000000.1" % cid, 410, "gone"),
                               ("/api/v1/nvr/cameras/%s/fragments/000000000000.1/init" % cid, 410, "gone"),
                               ("/api/v1/nvr/cameras/not-a-uuid/fragments?at=1760000000000", 404, "not_found")]:
        got = client.api("GET", path)
        if (got.status, got.code()) != (status, code):
            wrong.append("%s gave %d %s" % (path.replace(cid, ":id"), got.status, got.code()))
    check(not wrong, "a malformed id is 400, an unknown fragment 410 gone, a malformed camera 404", "; ".join(wrong))
    before = storage(client)
    wrong = []
    for body, status, code in [({}, 400, "invalid"), ({"path": "/etc"}, 400, "invalid"), ({"keepDays": 0}, 400, "invalid"), ({"maxSizeGB": 5}, 400, "invalid"),
                               ({"location": "../../etc"}, 422, "folder_rejected")]:
        got = client.api("PATCH", "/api/v1/nvr/storage", body)
        if (got.status, got.code()) != (status, code):
            wrong.append("%r gave %d %s" % (body, got.status, got.code()))
    for body, status, code in [({}, 400, "invalid"), ({"enabled": "yes"}, 400, "invalid")]:
        got = client.api("PATCH", write, body)
        if (got.status, got.code()) != (status, code):
            wrong.append("camera %r gave %d %s" % (body, got.status, got.code()))
    got = client.api("PATCH", "/api/v1/cameras/%s/nvr" % str(uuid.uuid4()).upper(), {"enabled": False})
    if (got.status, got.code()) != (404, "not_found"):
        wrong.append("unknown camera gave %d %s" % (got.status, got.code()))
    check(not wrong, "bad storage and camera changes are refused with the contract's codes", "; ".join(wrong))
    after = storage(client)
    check(all(before.get(k) == after.get(k) for k in ("location", "keepDays", "maxSizeGB")), "refused changes left the settings alone", "settings changed: %r -> %r" % (before, after))
    # one header set on the page, the API and the media: exactly the pinned policy
    page = client.raw("GET", "/", cookie=False)
    api = client.api("GET", "/api/v1/nvr/storage")
    served = client.api("GET", media)
    policies = {"page": page.header("content-security-policy"), "api": api.header("content-security-policy"), "media": served.header("content-security-policy")}
    check(all(value == CSP for value in policies.values()), "the Content-Security-Policy is the pinned one everywhere (media-src 'self' blob: and nothing else new)",
          "policies differ: %r" % ({k: v for k, v in policies.items() if v != CSP},))
    check("unsafe-inline" not in CSP and "unsafe-eval" not in CSP and page.status == 200, "no unsafe-inline, no unsafe-eval; the page is served",
          "the page answered %d" % page.status)
    check(api.header("cache-control") == "no-store" and served.header("cross-origin-resource-policy") == "same-origin" and served.header("x-content-type-options") == "nosniff",
          "media answers: no-store, same-origin, nosniff", "media headers: %r" % ({k: served.header(k) for k in ("cache-control", "cross-origin-resource-policy", "x-content-type-options")},))


def phase_sound_on(client, args):
    cid = client.camera
    reply = client.api("PATCH", "/api/v1/cameras/%s" % cid, {"audioEnabled": True})
    check(reply.status == 200 and reply.json().get("nvrEnabled") is True, "camera audio on; editing the camera kept Record on",
          "camera audio on answered %d, nvrEnabled=%r" % (reply.status, (reply.json() if reply.status == 200 else {}).get("nvrEnabled")))
    found, seconds = wait_until(lambda: (client.camera_json() or {}).get("status", {}).get("connection") == "online" and client.nvr_state() == "recording", 120, "back")
    if not check(found, "the camera is online and recording again after %.0f s" % seconds, "not recording again after %.0f s" % seconds):
        raise Abort("camera did not come back")
    reply = client.api("PATCH", "/api/v1/cameras/%s/nvr" % cid, {"recordSound": True})
    check(reply.status == 200 and reply.json().get("nvrRecordSound") is True, "Record sound switched on", "Record sound answered %d %s" % (reply.status, reply.code()))
    online = True
    for _ in range(5):
        time.sleep(1)
        online = online and (client.camera_json() or {}).get("status", {}).get("connection") == "online"
    check(online, "the camera stayed online while the recorder was replaced", "the camera went offline when Record sound was switched")

    def newest_has_sound():
        entry = client.extent()[1]
        if not entry:
            return None
        plan = client.plan(entry["newest"] - 2000, 1).json()
        if not plan.get("found"):
            return None
        info = plan["files"][plan["parts"][plan["targetIndex"]]["file"]]
        return plan if info["sound"] else None

    plan, seconds = wait_until(newest_has_sound, 120, "a file with sound")
    if not check(plan, "a file with sound is listed after %.0f s (files[].sound true)" % seconds, "no file with sound after %.0f s" % seconds):
        raise Abort("no sound file")
    init, segments, problems = fetch_chain(client, plan, "sound chain")
    check(not problems, "init and %d fragments of a file with sound are served video-only" % len(segments), "; ".join(problems[:4]))
    with open(os.path.join(client.directory, "served-sound.mp4"), "wb") as handle:
        handle.write(init + b"".join(segments))
    notes = (client.camera_json() or {}).get("status", {}).get("nvr", {}).get("notes")
    check(notes == [], "no 'sound could not be recorded' note: the AAC track was recorded", "status.nvr.notes is %r" % (notes,))


def phase_record_off(client, args):
    reply = client.api("PATCH", "/api/v1/cameras/%s/nvr" % client.camera, {"enabled": False})
    check(reply.status == 200 and reply.json().get("nvrEnabled") is False, "Record switched off", "Record off answered %d %s" % (reply.status, reply.code()))
    found, seconds = wait_until(lambda: client.nvr_state() == "off", 30, "off")
    check(found, "status.nvr is off after %.0f s" % seconds, "status.nvr is %r after %.0f s" % (client.nvr_state(), seconds))


# --- the seeded archive and the torn recording ----------------------------------------------------------------------------

def prft_size(mp4, offset):
    size, kind = struct.unpack_from(">I4s", mp4, offset)
    if kind != b"prft":
        raise ValueError("no prft at %d" % offset)
    return size


def plan_seed(closed_directory, out_directory, now_ms, wanted, camera_dir, byte_budget=4 * 10**9):
    """Chooses the template recording, writes the sidecars of the seeded archive and the numbers test-vm.sh needs.

    closed_directory holds the sidecars of the closed recordings, pulled from the box as <CAMERA>/<yyyy-MM-dd>/<HH-mm-ss>.cbidx.
    The template is the largest one without sound (at least 6 fragments). Seeds are copies of its first fragment (a hard link to
    one file of BASE_SIZE bytes, each with a sidecar of its own, 104 bytes) spread over the 5 days before the first recording of the run, as
    many as fit `byte_budget` counted per name (the size cap must not eat them); three more are 9 days
    old and one 10 days old, to be removed by retention. Returns the plan (also written to plan.json and plan.env)."""
    template, earliest = None, None
    for root, _, names in os.walk(closed_directory):
        for name in sorted(names):
            if not name.endswith(".cbidx"):
                continue
            path = os.path.join(root, name)
            with open(path, "rb") as handle:
                data = handle.read()
            parsed = parse_cbidx(data)
            relative = os.path.relpath(path, closed_directory)[:-len(".cbidx")].replace(os.sep, "/")
            earliest = parsed["start"] if earliest is None else min(earliest, parsed["start"])
            if parsed["flags"] & 1 == 0 and len(parsed["records"]) >= 6 and (template is None or len(parsed["records"]) > len(template["records"])):
                template = dict(parsed, relative=relative)
    if template is None:
        raise Abort("no closed recording without sound and with at least 6 fragments; is the encoder keeping up? (the VM's load average is in DIR/diag)")
    parts = template["relative"].split("/")
    if len(parts) != 3 or parts[0] != camera_dir or not SEGMENT_RE.match("/".join(parts[1:])):
        raise Abort("the template is at %r, not <camera>/<date>/<time>" % template["relative"])
    records = template["records"]
    first = records[0]
    base_size = first["offset"] + first["length"]
    seed_ms = max(1000, round(first["duration"] / 90))
    span = 5 * 86_400_000
    count = max(1, min(wanted, span // 2000, byte_budget // max(1, base_size + 104)))
    step = span // count
    last_end = (earliest - 300_000) // 1000 * 1000
    seeds = [(last_end - (count - 1 - i) * step) // 1000 * 1000 for i in range(count)]
    midnight = now_ms // 86_400_000 * 86_400_000
    old = [midnight - 9 * 86_400_000 + (36_000 + 300 * i) * 1000 for i in range(3)] + [midnight - 10 * 86_400_000 + 10_800_000]
    everything = seeds + old
    sidecars = os.path.join(out_directory, "sidecars")
    manifest, old_names = [], []
    for start in everything:
        relative = segment_of(camera_dir, start).split("/", 1)[1]
        if relative in manifest:
            raise Abort("two seeds share the name %s" % relative)
        manifest.append(relative)
        record = dict(first, wall=0, media=0)
        data = build_cbidx(uuid.UUID(camera_dir), start, start + seed_ms, base_size, template["initLength"], [record], flags=0)
        parse_cbidx(data, mp4_size=base_size)
        target = os.path.join(sidecars, relative + ".cbidx")
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as handle:
            handle.write(data)
    old_names = manifest[len(seeds):]
    tear = len(records) // 2
    plan = {
        "camera": camera_dir, "count": count, "baseSize": base_size, "seedMs": seed_ms, "step": step, "initLength": template["initLength"],
        "seedStarts": seeds, "seedRelatives": manifest[:len(seeds)], "oldRelatives": old_names,
        "firstRecord": first, "template": {"relative": template["relative"], "start": template["start"], "records": len(records)},
        "tear": {"index": tear, "truncateTo": records[tear]["offset"] + records[tear]["length"] // 2,
                 "keep": records[tear - 1]["offset"] + records[tear - 1]["length"], "relative": template["relative"],
                 "lastWall": records[tear - 1]["wall"], "lastDuration": records[tear - 1]["duration"]},
    }
    with open(os.path.join(out_directory, "manifest.txt"), "w") as handle:
        handle.write("".join(name + "\n" for name in manifest))
    with open(os.path.join(out_directory, "plan.json"), "w") as handle:
        json.dump(plan, handle)
    env = ["CAM_DIR=%s" % camera_dir, "SEED_N=%d" % count, "BASE_SIZE=%d" % base_size, "TEAR_REL=%s" % template["relative"].split("/", 1)[1],
           "TEAR_TRUNCATE=%d" % plan["tear"]["truncateTo"], "TEAR_KEEP=%d" % plan["tear"]["keep"], "TEAR_FRAGMENTS=%d" % tear,
           "OLD_FOREIGN_DAY=%s" % old_names[0].split("/")[0], "OLD_EMPTY_DAY=%s" % old_names[3].split("/")[0], "OLD_N=%d" % len(old_names)]
    for line in env:
        if not re.match(r"^[A-Z_]+=([0-9A-F-]+|[0-9]+|[0-9]{4}-[0-9]{2}-[0-9]{2}(/[0-9]{2}-[0-9]{2}-[0-9]{2}(-[0-9]+)?)?)$", line):
            raise Abort("refusing to write %r into plan.env" % line)
    with open(os.path.join(out_directory, "plan.env"), "w") as handle:
        handle.write("\n".join(env) + "\n")
    return plan


def phase_plan_seed(client, args):
    server = client.api("GET", "/api/v1/nvr/cameras").json()["serverTime"]
    budget = min(4 * 10**9, storage(client).get("effectiveMaxBytes", 0) * 4 // 10)
    out = os.path.join(client.directory, "seed")
    os.makedirs(out, exist_ok=True)
    plan = plan_seed(os.path.join(client.directory, "closed"), out, server, args.seed_files, client.camera.upper(), budget)
    ok("template %s (%d fragments); %d seeds of %d bytes (asked for %d), %d old ones for retention; fragment %d is cut for the torn file" % (
        plan["template"]["relative"], plan["template"]["records"], plan["count"], plan["baseSize"], args.seed_files, len(plan["oldRelatives"]), plan["tear"]["index"]))


def phase_wait_ready(client, args):
    saw = {}

    def ready():
        reply = client.api("GET", "/api/v1/nvr/cameras")
        if reply.status == 503:
            saw["loading"] = (reply.code(), reply.header("retry-after"))
            return None
        return reply.status == 200

    found, seconds = wait_until(ready, 120, "archive ready", every=1.0)
    check(found, "the archive is ready %.0f s after the daemon started answering" % seconds, "the archive is not ready after %.0f s" % seconds)
    if saw:
        check(saw["loading"] == ("archive_unavailable", "2"), "while loading the routes answer 503 archive_unavailable, Retry-After 2",
              "while loading the routes answered %r" % (saw["loading"],))
    else:
        note("the archive was ready at the first look")


def phase_wait_oldest(client, args):
    plan = load_plan(client)
    wanted = plan["seedStarts"][0]
    got, seconds = wait_until(lambda: (client.extent()[1] or {}).get("oldest") is not None and abs(client.extent()[1]["oldest"] - wanted) <= 1500, 150, "retention")
    entry = client.extent()[1] or {}
    check(got, "after %.0f s the oldest recording is the oldest seed: retention removed the 9 and 10 day old ones" % seconds,
          "the oldest recording is %s s from the oldest seed after %.0f s" % ("?" if not entry else (entry["oldest"] - wanted) // 1000, seconds))


def load_plan(client):
    with open(os.path.join(client.directory, "seed", "plan.json")) as handle:
        return json.load(handle)


def phase_verify_seed(client, args):
    plan = load_plan(client)
    with open(os.path.join(client.directory, "torn-head.mp4"), "rb") as handle:
        head = handle.read()
    base, first, cam = head[:plan["baseSize"]], plan["firstRecord"], plan["camera"]
    prft = prft_size(base, first["offset"])
    wanted = base[first["offset"] + prft:first["offset"] + first["length"]]
    count = plan["count"]
    picks = sorted({0, count - 1, count // 2} | set(range(0, count, max(1, count // 20))))
    wrong = []
    for i in picks:
        start = plan["seedStarts"][i]
        key = file_key(cam + "/" + plan["seedRelatives"][i])
        got = client.plan(start + 500, 0)
        body = got.json() if got.status == 200 else {}
        if not body.get("found"):
            wrong.append("seed %d: fragments answered %d %r" % (i, got.status, body.get("reason")))
            continue
        part = body["parts"][body["targetIndex"]]
        info = body["files"].get(part["file"], {})
        if (part["file"], part["id"], part["start"], part["key"], part["bytes"]) != (key, key + ".0", start, True, len(wanted)):
            wrong.append("seed %d: part %r, expected id %s.0 start %d bytes %d" % (i, part, key, start, len(wanted)))
        if info.get("sound") is not False or abs(info.get("anchor", 0) - start) > 1:
            wrong.append("seed %d: file info %r" % (i, info))
        segment = client.api("GET", "/api/v1/nvr/cameras/%s/fragments/%s" % (client.camera, part["id"]))
        if segment.status != 200 or segment.body != wanted:
            wrong.append("seed %d: the fragment is not byte for byte the recorded one (%d, %d bytes)" % (i, segment.status, len(segment.body)))
        init = client.api("GET", "/api/v1/nvr/cameras/%s/fragments/%s/init" % (client.camera, part["id"]))
        if init.status != 200 or init.body != base[:plan["initLength"]]:
            wrong.append("seed %d: the init segment differs (%d)" % (i, init.status))
    check(not wrong, "%d of %d seeded recordings: id, start, size and bytes are exactly what was written (ids = FNV-1a of the path)" % (len(picks), count),
          "; ".join(wrong[:3]))
    middle = count // 2
    gap_at = plan["seedStarts"][middle] + 60_000
    gap = client.plan(gap_at, 0).json()
    check(gap.get("found") is False and gap.get("reason") == "gap" and gap.get("next") == plan["seedStarts"][middle + 1],
          "between two seeds: found false, gap, next = the following seed", "between two seeds: %r" % (gap,))
    reply = client.api("GET", "/api/v1/nvr/cameras/%s/keyframe?at=%d" % (client.camera, gap_at))
    check(reply.status == 404 and reply.code() == "gap" and reply.header("x-cb-next") == str(plan["seedStarts"][middle + 1]),
          "keyframe?at= in a gap: 404 gap with X-CB-Next", "keyframe in a gap answered %d %s next=%r" % (reply.status, reply.code(), reply.header("x-cb-next")))
    before = client.plan(plan["seedStarts"][0] - 3_600_000, 0).json()
    check(before.get("found") is False and before.get("reason") == "beforeStart", "before the oldest seed: beforeStart", "before the oldest seed: %r" % (before,))
    verify_torn(client, plan, head)


def verify_torn(client, plan, head):
    tear, template = plan["tear"], plan["template"]
    with open(os.path.join(client.directory, "repaired.cbidx"), "rb") as handle:
        repaired = handle.read()
    try:
        index = parse_cbidx(repaired, mp4_size=tear["keep"])
    except ValueError as error:
        bad("the torn recording has no valid sidecar after the repair: %s" % error)
        return
    check(len(index["records"]) == tear["index"] and index["initLength"] == plan["initLength"] and abs(index["start"] - template["start"]) <= 1000
          and str(index["camera"]).upper() == plan["camera"], "the torn recording was repaired: %d whole fragments, new sidecar (104 + 40 x n bytes), the same start" % tear["index"],
          "the repaired sidecar has %d fragments (expected %d), start %+d ms" % (len(index["records"]), tear["index"], index["start"] - template["start"]))
    key = file_key(tear["relative"])
    last = index["records"][-1]
    at = index["start"] + last["wall"] + 200
    got = client.plan(at, 0)
    body = got.json() if got.status == 200 else {}
    if not body.get("found"):
        bad("the last whole fragment of the torn recording is not listed (%d %r)" % (got.status, body.get("reason")))
        return
    part = body["parts"][body["targetIndex"]]
    check(part["file"] == key and part["id"] == "%s.%d" % (key, tear["index"] - 1), "the last whole fragment of the torn recording is listed as %s.%d" % (key, tear["index"] - 1),
          "the fragment at that time is %r, expected %s.%d" % (part["id"], key, tear["index"] - 1))
    offset = last["offset"]
    expected = head[offset + prft_size(head, offset):offset + last["length"]]
    served = client.api("GET", "/api/v1/nvr/cameras/%s/fragments/%s" % (client.camera, part["id"]))
    check(served.status == 200 and served.body == expected, "that fragment is byte for byte what was recorded", "that fragment differs (%d, %d bytes, expected %d)" % (served.status, len(served.body), len(expected)))
    cut = client.api("GET", "/api/v1/nvr/cameras/%s/fragments/%s.%d" % (client.camera, key, tear["index"]))
    check(cut.status == 410 and cut.code() == "gone", "the fragment that was cut off is gone (410)", "the cut fragment answered %d %s" % (cut.status, cut.code()))


def phase_burst(client, args):
    """40 clients at once from one address, and the health route answering meanwhile (T00 C.3 admission: 8 in all, 6 per address).

    Where this runs matters. QEMU's user-mode port forwarding (how test-vm.sh reaches the box from the host) resets connections that arrive
    together, on a macOS host even two; so test-vm.sh runs this phase inside the box (--inside-box: the same file, the box's own python3, the
    box's loopback) unless the host is known to carry it (--burst-from host, the default off macOS)."""
    entry, at = inside_newest(client, 3)
    path = "/api/v1/nvr/cameras/%s/keyframe?at=%d" % (client.camera, at)
    results, health, stop = [], [], threading.Event()
    if args.inside_box:
        note("the burst runs inside the box, from its own loopback address")

    def one():
        try:
            reply = client.raw("GET", path)
            results.append((reply.status, reply.code() if reply.status != 200 else None, reply.header("retry-after")))
        except (OSError, http.client.HTTPException) as error:
            results.append((0, str(error), None))

    def watch():
        while not stop.is_set():
            started = time.monotonic()
            try:
                reply = client.raw("GET", "/api/v1/health", cookie=False, timeout=5)
                health.append((reply.status, time.monotonic() - started))
            except (OSError, http.client.HTTPException):
                health.append((0, time.monotonic() - started))
            time.sleep(0.1)

    watcher = threading.Thread(target=watch)
    watcher.start()
    threads = [threading.Thread(target=one) for _ in range(40)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(60)
    stop.set()
    watcher.join(10)
    statuses = sorted(r[0] for r in results)
    silent, silent_health = statuses.count(0), sum(1 for h in health if h[0] == 0)
    if silent or silent_health:
        # not an answer of the daemon (it answers 200 or 429): the connection was reset or refused on the way
        bad("%d of 40 burst requests and %d of %d health requests got no answer at all (reset or refused: %s). QEMU's user-mode port forwarding does that "
            "to connections that arrive together: run the burst from inside the box (test-vm.sh --burst-from guest)" % (
                silent, silent_health, len(health), clean(next((r[1] for r in results if r[0] == 0), ""), 40)))
        return
    busy = [r for r in results if r[0] == 429]
    check(len(results) == 40 and set(statuses) <= {200, 429}, "40 simultaneous keyframe requests: %d answered 200, %d answered 429" % (statuses.count(200), len(busy)),
          "40 simultaneous requests gave %r" % (statuses,))
    check(all(r[1] == "busy" and r[2] == "1" for r in busy), "every refusal is 429 busy with Retry-After 1", "refusals: %r" % (busy[:3],))
    slowest = max((h[1] for h in health), default=99)
    check(health and all(h[0] == 200 for h in health) and slowest < 2.0, "/api/v1/health answered %d times during the burst, the slowest in %.0f ms" % (len(health), slowest * 1000),
          "/api/v1/health during the burst: %r" % ([h for h in health if h[0] != 200 or h[1] >= 2.0][:3],))
    for _ in range(60):
        reply = client.api("GET", "/api/v1/nvr/cameras/%s/fragments?at=%d&ahead=0" % (client.camera, at))
        if reply.status != 200:
            bad("a request after the burst answered %d" % reply.status)
            return
    ok("60 more requests after the burst all answered")


def phase_notices(client, args):
    """--expect none | low | full: the banner and the camera's state as the contract says (T00 C.6, C.7)."""
    def look():
        status = client.api("GET", "/api/v1/status").json()
        found = [n for n in status.get("notices", []) if n.get("id") == "nvr-storage"]
        camera = (client.camera_json() or {}).get("status", {}).get("nvr", {})
        return {"notice": found[0] if found else None, "camera": camera, "storage": storage(client)}

    def matches(seen):
        notice = seen["notice"]
        if args.expect == "none":
            return notice is None and seen["camera"].get("state") in ("recording", "waiting")
        if args.expect == "low":
            return (notice is not None and re.match(r"^Recording Storage Almost Full$", notice.get("title", "")) is not None
                    and re.match(r"^About [0-9]+ GB are left before recording pauses\.$", notice.get("detail", "")) is not None and notice.get("action") == "open-settings")
        return (notice is not None and re.match(r"^Recording Can.t Continue$", notice.get("title", "")) is not None and notice.get("action") == "open-settings"
                and seen["camera"].get("state") == "paused" and seen["camera"].get("pause") == "diskFull" and seen["storage"].get("state") == "diskFull")

    box = {}

    def probe():
        box["seen"] = look()
        return matches(box["seen"])

    found, seconds = wait_until(probe, 60, "notice", every=2.0)
    seen = box.get("seen", {})
    describe = {"none": "no storage notice and the camera records", "low": "the low-space notice 'Recording Storage Almost Full' with open-settings",
                "full": "'Recording Can't Continue', open-settings, the camera paused for diskFull, storage state diskFull"}[args.expect]
    check(found, "%s (after %.0f s)" % (describe, seconds), "expected %s, saw notice %r camera %r storage state %r" % (
        args.expect, (seen.get("notice") or {}).get("title"), (seen.get("camera") or {}).get("state"), (seen.get("storage") or {}).get("state")))


def phase_persisted(client, args):
    """After a reboot: the choices survived and the catalog (once it has loaded) still starts where the seeded archive starts."""
    body = storage(client)
    check(body.get("location") == "builtin" and body.get("keepDays") == 7 and body.get("maxSizeGB") == 500, "the folder and the limits survived the reboot",
          "storage after the reboot: %r" % ({k: body.get(k) for k in ("location", "keepDays", "maxSizeGB")},))
    camera = client.camera_json() or {}
    check(camera.get("nvrEnabled") is True, "Record is still on after the reboot", "nvrEnabled is %r after the reboot" % camera.get("nvrEnabled"))
    path = os.path.join(client.directory, "seed", "plan.json")
    if os.path.exists(path):
        wanted = load_plan(client)["seedStarts"][0]
        got, seconds = wait_until(lambda: abs((client.extent()[1] or {}).get("oldest", 0) - wanted) <= 1500, 120, "catalog", every=1.0)
        check(got, "the catalog is back after %.0f s and starts at the oldest seed" % seconds, "the catalog does not start at the oldest seed after %.0f s" % seconds)


def phase_check_sidecar(client, args):
    """No network: the sidecar in --file is valid for an mp4 of --size bytes (what a repair must leave behind)."""
    with open(args.file, "rb") as handle:
        data = handle.read()
    try:
        index = parse_cbidx(data, mp4_size=args.size)
    except ValueError as error:
        bad("the sidecar does not fit its file: %s" % error)
        return
    check(len(index["records"]) >= 1, "the sidecar holds %d fragments and fits its file (%d bytes)" % (len(index["records"]), args.size), "the sidecar holds no fragment")


def phase_leakscan(client, args):
    with open(args.journal, errors="replace") as handle:
        text = handle.read()
    secrets = {"the password": os.environ.get("CB_TEST_PASSWORD", ""), "the session cookie": client.state.get("cookie", ""), "the CSRF token": client.state.get("csrf", "")}
    for name, value in secrets.items():
        if len(value) >= 8:
            check(value not in text, "%s is nowhere in the daemon's log" % name, "%s is in the daemon's log" % name)
    noise = [line for line in text.splitlines() if "/api/v1/nvr" in line]
    check(not noise, "no log line names an NVR request path", "%d log lines name an NVR request path, e.g. %s" % (len(noise), clean(noise[0], 120) if noise else ""))
    lines = len(text.splitlines())
    note("the daemon's log has %d lines since boot" % lines)


# The two shell scripts that run ON the box (as the camerabridge user, so every file is owned by the daemon and private). They are
# sent over ssh as "plan.env, then the script" to `bash -s`: bash on purpose (the box has python3 only as a dependency of systemd-ukify). NVR_ROOT and NVR_STAGE exist so the self-test
# can run them on this computer.
VM_SCRIPTS = {
    "seed": r"""
set -eu
umask 077
root=${NVR_ROOT:-/var/lib/camera-bridge/recordings}
stage=${NVR_STAGE:-/var/lib/camera-bridge/nvr-seed}
case $CAM_DIR in ''|*[!0-9A-F-]*) echo "bad CAM_DIR" >&2; exit 2 ;; esac
dst=$root/$CAM_DIR
[ -d "$dst" ] || { echo "no camera folder $dst" >&2; exit 2; }
[ "$(wc -c <"$stage/base.mp4" | tr -d ' ')" = "$BASE_SIZE" ] || { echo "base.mp4 is not $BASE_SIZE bytes" >&2; exit 2; }
n=0
while IFS= read -r rel; do
    case $rel in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/[0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
        *) echo "bad name $rel" >&2; exit 2 ;;
    esac
    mkdir -p "$dst/${rel%/*}"
    ln "$stage/base.mp4" "$dst/$rel.mp4"
    mv "$stage/sidecars/$rel.cbidx" "$dst/$rel.cbidx"
    n=$((n + 1))
done <"$stage/manifest.txt"
# Things retention must leave alone, in the day that also holds three expired recordings: a foreign file and a link named like a recording.
printf 'not a recording\n' >"$dst/$OLD_FOREIGN_DAY/keep-me.txt"
ln -s /etc/hostname "$dst/$OLD_FOREIGN_DAY/00-00-01.mp4"
rm -rf "$stage"
echo "seeded $n recordings"
""",
    "tear": r"""
set -eu
umask 077
root=${NVR_ROOT:-/var/lib/camera-bridge/recordings}
stage=${NVR_STAGE:-/var/lib/camera-bridge/nvr-seed}
mp4=$root/$CAM_DIR/$TEAR_REL.mp4
side=$root/$CAM_DIR/$TEAR_REL.cbidx
if [ ! -f "$mp4" ] || [ ! -f "$side" ] || [ ! -d "$stage" ]; then echo "no closed recording at $TEAR_REL, or no $stage" >&2; exit 2; fi
sha() { sha256sum "$@" 2>/dev/null || shasum -a 256 "$@"; }
head -c "$BASE_SIZE" "$mp4" >"$stage/base.mp4"
head -c "$TEAR_KEEP" "$mp4" >"$stage/torn-head.mp4"
sha "$stage/torn-head.mp4" | cut -d' ' -f1 >"$stage/torn.sha"
# What a power cut leaves behind: the file cut in the middle of fragment $TEAR_FRAGMENTS, no sidecar, not written for ten minutes.
dd if=/dev/null of="$mp4" bs=1 seek="$TEAR_TRUNCATE" 2>/dev/null
if [ "$(wc -c <"$mp4" | tr -d ' ')" != "$TEAR_TRUNCATE" ]; then echo "the file was not cut to $TEAR_TRUNCATE bytes" >&2; exit 3; fi
rm -f "$side"
touch -d '10 minutes ago' "$mp4" 2>/dev/null || touch -t "$(date -v-10M +%Y%m%d%H%M.%S)" "$mp4"
echo "cut $TEAR_REL to $TEAR_TRUNCATE bytes"
""",
}


PHASES = {
    "session": phase_session, "add-camera": phase_add_camera, "folder-required": phase_folder_required, "choose-folder": phase_choose_folder,
    "record-on": phase_record_on, "wait-recording": phase_wait_recording, "fetch": phase_fetch, "security": phase_security,
    "sound-on": phase_sound_on, "record-off": phase_record_off, "plan-seed": phase_plan_seed, "wait-ready": phase_wait_ready,
    "wait-oldest": phase_wait_oldest, "verify-seed": phase_verify_seed, "burst": phase_burst, "notices": phase_notices, "leakscan": phase_leakscan,
    "persisted": phase_persisted, "check-sidecar": phase_check_sidecar,
}
OFFLINE = {"check-sidecar"}   # phases that never talk to the box


# ---------------------------------------------------------------------------------------------------------------------------
# Self-test (python3 -I linux/os/test-nvr.py selftest): no VM, no network beyond loopback, a few seconds.
# It pins the codec to the golden bytes of CBIndexFormatTests, runs the box-side shell scripts on a local folder, and runs every
# phase against a small fake box that follows T00 part C - then breaks the fake in six ways and expects the phases to notice.

def box(kind, payload):
    return struct.pack(">I4s", 8 + len(payload), kind) + payload


def synthetic_recording(camera, start_ms, fragments=8, sound=False):
    """A file shaped like the recorder's (ftyp + moov, then prft + moof + mdat per fragment) and its index. Not decodable video."""
    traks = box(b"trak", box(b"tkhd", bytes(84))) * (2 if sound else 1)
    init = box(b"ftyp", b"isom" + bytes(4) + b"isomiso2avc1mp41") + box(b"moov", box(b"mvhd", bytes(100)) + traks + box(b"mvex", box(b"trex", bytes(24))))
    data, records = bytearray(init), []
    for i in range(fragments):
        prft = box(b"prft", bytes(24))
        trafs = box(b"traf", box(b"tfhd", bytes(8)) + box(b"trun", bytes(20))) * (2 if sound else 1)
        moof = box(b"moof", box(b"mfhd", bytes(8)) + trafs)
        fragment = prft + moof + box(b"mdat", bytes((i * 7 + j) % 251 for j in range(3000 + 100 * i)))
        key = i % 2 == 0
        records.append({"offset": len(data), "length": len(fragment), "wall": i * 2000, "media": i * 180_000, "duration": 180_000,
                        "header": len(prft) + len(moof) + 8, "key": 2000 if key else 0, "nonKey": 1000 + i, "samples": 60, "back": 0 if key else 1})
        data += fragment
    return bytes(data), build_cbidx(uuid.UUID(camera), start_ms, start_ms + fragments * 2000, len(data), len(init), records, flags=1 if sound else 0)


def video_only(piece):
    """What the box serves: no prft, one track (init) or one track fragment (moof). Works on an init segment or on a fragment."""
    out = b""
    for kind, offset, size in boxes(piece):
        if kind == b"prft":
            continue
        if kind in (b"moov", b"moof"):
            wanted = b"trak" if kind == b"moov" else b"traf"
            kept, seen = b"", 0
            for inner, at, length in children(piece, (kind, offset, size)):
                if inner == wanted:
                    seen += 1
                    if seen > 1:
                        continue
                kept += piece[at:at + length]
            out += box(kind, kept)
        else:
            out += piece[offset:offset + size]
    return out


class FakeBox:
    """Just enough of the box for the phases: sign-in, one camera, storage, and an archive served from a local folder (T00 part C)."""

    def __init__(self, recordings, camera, host="127.0.0.1", port=0):
        self.recordings, self.camera_id = recordings, camera.upper()
        self.password, self.sessions, self.camera = None, {}, None
        self.folder, self.enabled, self.sound, self.audio = None, False, False, False
        self.notice, self.flaws, self.sound_listed, self.ready = None, set(), False, True
        self.recorder = None   # called when the camera list is read: the recorder of a box that writes while it is being polled (GrowingRecording)
        self.busy, self.lock = 0, threading.Lock()
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def do_GET(self):
                owner.handle(self, "GET")

            def do_HEAD(self):
                owner.handle(self, "HEAD")

            def do_POST(self):
                owner.handle(self, "POST")

            def do_PATCH(self):
                owner.handle(self, "PATCH")

        http.server.ThreadingHTTPServer.request_queue_size = 128
        self.server = http.server.ThreadingHTTPServer((host, port), Handler)
        self.base = "http://127.0.0.1:%d" % self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    # --- the archive
    def files(self):
        found, root = [], os.path.join(self.recordings, self.camera_id)
        for date in sorted(os.listdir(root)) if os.path.isdir(root) else []:
            if not os.path.isdir(os.path.join(root, date)):
                continue   # camera.json
            for name in sorted(os.listdir(os.path.join(root, date))):
                path = os.path.join(root, date, name[:-6])
                if not name.endswith(".cbidx") or not os.path.isfile(path + ".mp4") or os.path.islink(path + ".mp4"):
                    continue
                try:
                    with open(os.path.join(root, date, name), "rb") as handle:
                        index = parse_cbidx(handle.read(), os.path.getsize(path + ".mp4"))
                except ValueError:
                    continue
                if index["flags"] & 1 and not self.sound_listed:
                    continue
                found.append({"segment": "%s/%s/%s" % (self.camera_id, date, name[:-6]), "mp4": path + ".mp4", "index": index})
        return found

    def fragments(self):
        out = []
        for f in self.files():
            for i, r in enumerate(f["index"]["records"]):
                start = f["index"]["start"] + r["wall"]
                out.append(dict(f, i=i, r=r, start=start, end=start + round(r["duration"] / 90), key=file_key(f["segment"])))
        return out

    def containing(self, at):
        hits = [f for f in self.fragments() if f["start"] <= at < f["end"]]
        return max(hits, key=lambda f: f["index"]["start"]) if hits else None

    @staticmethod
    def part(f):
        return {"id": "%s.%d" % (f["key"], f["i"]), "file": f["key"], "start": f["start"], "end": f["end"], "bytes": f["r"]["length"] - 32, "key": f["r"]["key"] > 0}

    def info(self, f):
        return {"mime": 'video/mp4; codecs="avc1.4d0032"', "width": 1920, "height": 1080, "anchor": f["index"]["start"] - f["index"]["records"][0]["media"] / 90,
                "initId": "%s.%d" % (f["key"], f["i"]), "sound": bool(f["index"]["flags"] & 1)}

    def plan(self, at, ahead):
        everything = self.fragments()
        hit = self.containing(at)
        if hit is None:
            if not everything:
                return {"serverTime": now_ms(), "found": False, "at": at, "reason": "empty", "next": None, "newest": None}
            oldest, newest = min(f["start"] for f in everything), max(f["end"] for f in everything)
            later = sorted((f for f in everything if f["start"] > at), key=lambda f: f["start"])
            reason = "beforeStart" if at < oldest else "afterEnd" if at >= newest else "gap"
            return {"serverTime": now_ms(), "found": False, "at": at, "reason": reason, "next": later[0]["start"] if later else None, "newest": newest}
        same = [f for f in everything if f["segment"] == hit["segment"]]
        chain = [f for f in same if hit["i"] - hit["r"]["back"] <= f["i"] <= hit["i"]]
        target = len(chain) - 1
        last = chain[-1]
        for _ in range(ahead):
            later = sorted((f for f in everything if f["start"] > last["start"]), key=lambda f: f["start"])
            if not later:
                break
            last = later[0]
            chain.append(last)
        files = {}
        for f in chain:
            files.setdefault(f["key"], self.info(f))
        for key in files:
            files[key]["initId"] = next(p["id"] for p in map(self.part, chain) if p["file"] == key)
        return {"serverTime": now_ms(), "found": True, "at": at, "exact": True, "targetIndex": target, "parts": [self.part(f) for f in chain], "files": files}

    def media(self, f):
        with open(f["mp4"], "rb") as handle:
            raw = handle.read()
        r = f["r"]
        piece = raw[r["offset"]:r["offset"] + r["length"]]
        if "prft" in self.flaws:
            return piece
        return video_only(piece) if f["index"]["flags"] & 1 else piece[boxes(piece)[0][2]:]

    def init(self, f):
        with open(f["mp4"], "rb") as handle:
            raw = handle.read(f["index"]["initLength"])
        return video_only(raw) if f["index"]["flags"] & 1 else raw

    # --- HTTP
    def send(self, handler, method, status, body=None, kind="application/json", extra=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        body = body or b""
        handler.send_response(status)
        handler.send_header("Content-Type", kind)
        handler.send_header("Content-Length", str(len(body)))
        if "csp" not in self.flaws:
            handler.send_header("Content-Security-Policy", CSP)
        for name, value in SECURITY_HEADERS + (STAND_IN_HEADER,):   # the daemon puts the security headers on every answer (WebApp.addSecurityHeaders)
            handler.send_header(name, value)
        if "nostore" not in self.flaws:
            handler.send_header("Cache-Control", "no-store")
        for name, value in (extra or {}).items():
            handler.send_header(name, value)
        handler.end_headers()
        if method != "HEAD":
            handler.wfile.write(body)

    def error(self, handler, method, status, code, **extra):
        self.send(handler, method, status, {"error": code, "message": code}, extra=extra)

    def handle(self, handler, method):
        path, _, query = handler.path.partition("?")
        params = dict(p.split("=", 1) for p in query.split("&") if "=" in p)
        length = int(handler.headers.get("Content-Length") or 0)
        raw = handler.rfile.read(length) if length else b""
        cookie = re.search(r"cb_session=([^;\s]+)", handler.headers.get("Cookie", ""))
        token = cookie.group(1) if cookie else None
        csrf = self.sessions.get(token)
        send = lambda status, body=None, **kw: self.send(handler, method, status, body, **kw)
        fail = lambda status, code, **extra: self.error(handler, method, status, code, **extra)
        if not path.startswith("/api/"):
            return send(200, b"<title>Camera Bridge</title>", kind="text/html")
        if method in ("POST", "PATCH"):
            origin = handler.headers.get("Origin")
            if origin and origin != self.base:
                return fail(403, "cross_origin")
            if raw and not handler.headers.get("Content-Type", "").startswith("application/json"):
                return fail(415, "unsupported_media_type")
        body = json.loads(raw) if raw else {}
        if path == "/api/v1/health":
            return send(200, {"ok": True})
        if path == "/api/v1/status":   # open to everyone, as on the box; the notices only to a signed-in person
            return send(200, {"authenticated": csrf is not None, "setupRequired": self.password is None, "notices": self.notices() if csrf is not None else []})
        if path == "/api/v1/session":
            return send(200, {"authenticated": csrf is not None, "setupRequired": self.password is None, "setupTokenRequired": False, "csrfToken": csrf})
        if path in ("/api/v1/auth/setup", "/api/v1/auth/login") and method == "POST":
            setup = path.endswith("setup")
            if setup and self.password is not None:
                return fail(409, "already_configured")
            if setup:
                self.password = body["password"]
            if body.get("password") != self.password:
                return fail(401, "wrong_password")
            token, csrf = uuid.uuid4().hex, uuid.uuid4().hex
            self.sessions[token] = csrf
            return send(201 if setup else 200, {"csrfToken": csrf, "bridgeName": "x"}, extra={"Set-Cookie": SESSION_COOKIE % token})
        if csrf is None:
            return fail(401, "unauthorized")
        if method in ("POST", "PATCH") and handler.headers.get("X-CSRF-Token") != csrf:
            return fail(403, "csrf")
        parts = path.split("/")[3:]
        if parts == ["cameras"] and method == "POST":
            self.camera = {"id": self.camera_id, "name": body.get("name"), "audioEnabled": body.get("audioEnabled", False)}
            return send(201, self.camera_json())
        if len(parts) >= 2 and parts[0] == "cameras":
            if parts[1].upper() != self.camera_id:
                return fail(404, "not_found")
            if len(parts) == 2 and method == "GET":
                return send(200, self.camera_json())
            if len(parts) == 2 and method == "PATCH":
                self.audio = self.camera["audioEnabled"] = body.get("audioEnabled", self.audio)
                return send(200, self.camera_json())
            if parts[2:] == ["nvr"] and method == "PATCH":
                if not body or any(not isinstance(body.get(k, False), bool) for k in ("enabled", "recordSound")):
                    return fail(400, "invalid")
                if body.get("enabled") and not self.enabled and self.folder is None:
                    return fail(409, "folder_required")
                self.enabled = body.get("enabled", self.enabled)
                self.sound = body.get("recordSound", self.sound)
                self.sound_listed = self.enabled and self.sound
                return send(200, self.camera_json())
        if parts[:2] == ["nvr", "storage"] and len(parts) == 2 and method == "GET":
            return send(200, self.storage())
        if parts[:2] == ["nvr", "storage"] and len(parts) == 2 and method == "PATCH":
            if not any(k in body for k in ("location", "keepDays", "maxSizeGB")):
                return fail(400, "invalid")
            if "keepDays" in body and body["keepDays"] not in range(1, 366) or "maxSizeGB" in body and body["maxSizeGB"] not in range(10, 100_001):
                return fail(400, "invalid")
            if "location" in body and body["location"] != "builtin":
                return fail(422, "folder_rejected")
            self.folder = "builtin" if "location" in body else self.folder
            return send(200, self.storage())
        if parts == ["nvr", "storage", "locations"]:
            return send(200, {"locations": [{"id": "builtin", "label": "This box’s storage", "path": "/var/lib/camera-bridge/recordings", "current": self.folder == "builtin",
                                             "writable": True, "freeBytes": 20 * 10**9, "totalBytes": 28 * 10**9, "roomBytes": None, "problem": None, "warning": None}]})
        if parts[:2] == ["nvr", "cameras"] or parts[:2] == ["nvr", "activity"]:
            return self.archive(handler, method, parts, params, send, fail)
        return fail(404, "not_found")

    def archive(self, handler, method, parts, params, send, fail):
        if not self.ready:
            return fail(503, "archive_unavailable", **{"Retry-After": "2"})
        if parts == ["nvr", "cameras"]:
            if self.recorder:
                self.recorder()
            everything = self.fragments()
            cameras = [{"id": self.camera_id, "oldest": min(f["start"] for f in everything), "newest": max(f["end"] for f in everything), "typicalGOP": 4.0}] if everything else []
            return send(200, {"serverTime": now_ms(), "catalogVersion": len(everything), "cameras": cameras})
        if parts == ["nvr", "activity"]:
            bins, bin_ms = int(params["bins"]), int(params["binMs"])
            return send(200, {"from": int(params["from"]) // bin_ms * bin_ms, "binMs": bin_ms, "bins": bins, "serverTime": now_ms(), "catalogVersion": 1,
                              "byCamera": {self.camera_id: {"typical": None, "complete": True, "coverage": [100] * bins, "level": [1000.0] * bins}}})
        if len(parts) < 4 or parts[2].upper() != self.camera_id and not re.match(r"^[0-9A-Fa-f-]{36}$", parts[2]):
            return fail(404, "not_found")
        known = parts[2].upper() == self.camera_id
        with self.lock:
            if "reset" in self.flaws and self.busy >= 1:   # a port forward that cannot take two connections at once: the second one is reset
                handler.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                handler.connection.close()
                handler.close_connection = True
                return None
            if self.busy >= 6:
                return fail(429, "busy", **{"Retry-After": "1"})
            self.busy += 1
        try:
            if parts[3] == "fragments" and len(parts) == 4:
                if ("at" in params) == ("after" in params) or not re.match(r"^[0-9]{1,15}$", params.get("at", params.get("after", "x")) if "at" in params else "1"):
                    return fail(400, "invalid")
                at = int(params["at"])
                if not 978307200000 <= at <= 4102444800000:
                    return fail(400, "invalid")
                return send(200, self.plan(at, int(params.get("ahead", 2))) if known else {"serverTime": now_ms(), "found": False, "at": at, "reason": "empty", "next": None, "newest": None})
            if parts[3] == "keyframe":
                time.sleep(0.05)
                at = int(params["at"])
                hit = self.containing(at) if known else None
                if hit is None:
                    later = sorted((f for f in self.fragments() if f["start"] > at), key=lambda f: f["start"])
                    return self.error(handler, method, 404, "gap", **({"X-CB-Next": str(later[0]["start"])} if later else {}))
                first = next(f for f in self.fragments() if f["segment"] == hit["segment"] and f["i"] == hit["i"] - hit["r"]["back"])
                header = dict(self.part(first), mime=self.info(first)["mime"], width=1920, height=1080, anchor=self.info(first)["anchor"], initId=self.part(first)["id"])
                return send(200, self.media(first), kind="video/mp4", extra={"X-CB-Part": json.dumps(header)})
            if parts[3] == "fragments" and len(parts) in (5, 6):
                if method == "HEAD" and "head" not in self.flaws:
                    return self.error(handler, method, 405, "method_not_allowed", Allow="GET")
                match = ID_RE.match(parts[4])
                if not match:
                    return fail(400, "invalid")
                chosen = [f for f in self.fragments() if "%s.%d" % (f["key"], f["i"]) == parts[4]] if known else []
                if not chosen:
                    return fail(410, "gone")
                return send(200, self.init(chosen[0]) if len(parts) == 6 else self.media(chosen[0]), kind="video/mp4")
            return fail(404, "not_found")
        finally:
            with self.lock:
                self.busy -= 1

    # --- resources
    def state(self):
        if not self.enabled:
            return {"state": "off", "detail": None, "pause": None, "notes": []}
        if self.notice == "full":
            return {"state": "paused", "detail": "There isn’t enough free space on the recordings drive.", "pause": "diskFull", "notes": []}
        return {"state": "recording", "detail": None, "pause": None, "notes": []}

    def camera_json(self):
        return dict(self.camera, nvrEnabled=self.enabled, nvrRecordSound=self.sound, status={"connection": "online", "nvr": self.state()})

    def storage(self):
        total, used = 28_453_000_000, 10_000_000
        floor = max(8 * GIB, total // 20)
        free = floor + (3 * GIB if self.notice == "low" else 12 * GIB) if self.notice != "full" else floor - GIB // 2
        return {"location": self.folder, "label": "This box’s storage" if self.folder else None, "state": "diskFull" if self.notice == "full" else "ok" if self.folder else "noFolder",
                "message": None, "recordingCameras": 1 if self.enabled else 0, "keepDays": 7, "maxSizeGB": 500, "limits": {"keepDays": [1, 365], "maxSizeGB": [10, 100000]},
                "usedBytes": used, "freeBytes": free, "totalBytes": total, "floorBytes": floor, "roomBytes": used + max(0, free - floor),
                "effectiveMaxBytes": min(500 * 10**9, max(0, total - 2 * floor)), "oldest": None, "newest": None}

    def notices(self):
        if not self.enabled or self.notice is None:
            return []
        if self.notice == "low":
            return [{"id": "nvr-storage", "title": "Recording Storage Almost Full", "detail": "About 3 GB are left before recording pauses.", "action": "open-settings"}]
        return [{"id": "nvr-storage", "title": "Recording Can’t Continue", "detail": "There isn’t enough free space on the recordings drive.", "action": "open-settings"}]


def now_ms():
    return int(time.time() * 1000)


class GrowingRecording:
    """The file the recorder is writing, for the FakeBox: it has `fragments` fragments (of 2 s) and gets one more each time it is called, from the
    `begin`-th call on and up to `limit`. FakeBox calls it when the camera list is read, which is what the phases poll. The mp4 is replaced
    before its sidecar, and only one request is served at a time in the self-test, so the box never sees the two out of step."""

    def __init__(self, recordings, camera, start_ms, fragments=1, limit=8, begin=1):
        self.stem = os.path.join(recordings, segment_of(camera, start_ms))
        self.camera, self.start, self.limit = camera, start_ms, limit
        self.reset(fragments, begin)

    def reset(self, fragments=1, begin=1):
        self.fragments, self.begin, self.calls = fragments, begin, 0
        self.write()

    def write(self):
        data, index = synthetic_recording(self.camera, self.start, self.fragments)
        os.makedirs(os.path.dirname(self.stem), exist_ok=True)
        for extension, content in ((".mp4", data), (".cbidx", index)):
            with open(self.stem + extension + ".tmp", "wb") as handle:
                handle.write(content)
            os.replace(self.stem + extension + ".tmp", self.stem + extension)

    def __call__(self):
        self.calls += 1
        if self.calls >= self.begin and self.fragments < self.limit:
            self.fragments += 1
            self.write()


def run_phase(name, client, **options):
    """Runs one phase in this process; returns (lines it printed, number of FAIL lines)."""
    global REPORT
    REPORT = Report()
    args = argparse.Namespace(camera_name="Smoke camera", recordings_path="/var/lib/camera-bridge/recordings", seconds=6, seed_files=40, expect="none", journal="",
                              file="", size=0, inside_box=False)
    for key, value in options.items():
        setattr(args, key, value)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        try:
            PHASES[name](client, args)
        except Abort as error:
            bad("%s stopped: %s" % (name, error))
    return out.getvalue().splitlines(), REPORT.failed


def selftest():
    global TIMEOUT_SCALE
    TIMEOUT_SCALE = 0.02   # the fake answers at once; a wait that cannot succeed should give up quickly
    outcomes = []

    def case(function):
        try:
            function()
            outcomes.append((function.__name__, None))
        except Exception as error:  # a failed assertion or any other exception is a failed case
            outcomes.append((function.__name__, "%s: %s" % (type(error).__name__, error)))
        return function

    @case
    def cbidx_matches_the_golden_bytes_of_t00():
        # CBIndexFormatTests.swift (T00 step 4): header, one rollup, two records, written independently of the encoder.
        golden = bytes.fromhex("43424e58" "0001" "0001" "00112233445566778899aabbccddeeff" "00000199ce135ec0" "00000199ce137248" "00000000000003e8" "00000064" "00000002" "0001"
                               "000000000000" "00000bb8" "000004b0" "1388" "0000"
                               "0000000000000064" "00000190" "00000000" "00000000" "00036ee8" "00000096" "000000c8" "00000064" "0032" "0000"
                               "00000000000001f4" "000001f4" "000009c4" "00036ee8" "00036ee8" "00000096" "00000000" "0000012c" "0032" "0001")
        assert len(golden) == 156
        parsed = parse_cbidx(golden, mp4_size=1000)
        assert parsed["flags"] == 1 and parsed["start"] == 1_760_099_000_000 and parsed["end"] == parsed["start"] + 5000 and parsed["initLength"] == 100
        assert len(parsed["records"]) == 2 and parsed["records"][1]["back"] == 1 and parsed["rollups"] == [(3000, 1200, 5000)]
        assert build_cbidx(uuid.UUID("00112233-4455-6677-8899-AABBCCDDEEFF"), parsed["start"], parsed["end"], 1000, 100, parsed["records"], flags=1,
                           rollups=parsed["rollups"]) == golden

    @case
    def cbidx_refuses_what_the_swift_decoder_refuses():
        data, index = synthetic_recording("6F9619FF-8B86-D011-B42D-00C04FC964FF", 1_760_099_000_000, 4)
        size = len(data)
        assert parse_cbidx(index, size)["records"][3]["back"] == 1

        def refused(blob, expected, mp4=size):
            try:
                parse_cbidx(blob, mp4)
            except ValueError as error:
                assert str(error).startswith(expected), (expected, str(error))
                return
            raise AssertionError("accepted: " + expected)
        refused(b"X" + index[1:], "badMagic")
        refused(index[:63], "truncated")
        refused(index[:-1], "sizeMismatch")
        refused(index + b"\0", "sizeMismatch")
        refused(index, "mp4SizeMismatch", mp4=size + 1)
        refused(index[:5] + b"\x02" + index[6:], "unsupportedVersion")
        for count in range(len(index)):
            try:
                parse_cbidx(index[:count], size)
            except ValueError:
                continue
            raise AssertionError("a prefix of %d bytes was accepted" % count)
        records = parse_cbidx(index, size)["records"]
        for change, expected in [({"offset": 10}, "inconsistentRecord(0)"), ({"length": 0}, "inconsistentRecord(0)"), ({"back": 1}, "inconsistentRecord(0)")]:
            broken = [dict(records[0], **change)] + records[1:]
            refused(build_cbidx(uuid.UUID("6F9619FF-8B86-D011-B42D-00C04FC964FF"), 0, 0, size, parse_cbidx(index)["initLength"], broken), expected)

    @case
    def file_keys_match_the_swift_vectors():
        assert fnv1a64(b"") == 0xCBF29CE484222325 and fnv1a64(b"a") == 0xAF63DC4C8601EC8C and fnv1a64(b"foobar") == 0x85944171F73967E8
        assert file_key("") == "cbf29ce48422" and file_key("a") == "af63dc4c8601"
        short = next("short-%d" % i for i in range(10_000) if fnv1a64(("short-%d" % i).encode()) < 1 << 60)   # prints with fewer than 16 hex digits
        assert file_key(short) == format(fnv1a64(short.encode()), "016x")[:12] and file_key(short).startswith("0"), "leading zeros are kept"
        assert segment_of("CAM", 1_760_099_000_000) == "CAM/2025-10-10/12-23-20", segment_of("CAM", 1_760_099_000_000)

    @case
    def phases_seed_tear_and_verify_against_a_fake_box():
        camera = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
        with tempfile.TemporaryDirectory() as tmp:
            recordings, work, stage = os.path.join(tmp, "recordings"), os.path.join(tmp, "work"), os.path.join(tmp, "stage")
            started = now_ms() // 1000 * 1000
            for start, fragments, sound in ((started - 90_000, 12, False), (started - 40_000, 5, True)):
                data, index = synthetic_recording(camera, start, fragments, sound)
                stem = os.path.join(recordings, segment_of(camera, start))
                os.makedirs(os.path.dirname(stem), exist_ok=True)
                with open(stem + ".mp4", "wb") as handle:
                    handle.write(data)
                with open(stem + ".cbidx", "wb") as handle:
                    handle.write(index)
            fake = FakeBox(recordings, camera)
            os.environ["CB_TEST_PASSWORD"] = "correct horse battery"
            try:
                client = Client(fake.base, work)
                for name, options in (("session", {}), ("add-camera", {}), ("folder-required", {}), ("choose-folder", {}), ("record-on", {}), ("fetch", {}),
                                      ("security", {}), ("sound-on", {}), ("record-off", {})):
                    lines, failed = run_phase(name, client, **options)
                    assert failed == 0, "%s: %s" % (name, [line for line in lines if line.startswith("FAIL")])
                assert os.stat(client.state_path).st_mode & 0o777 == 0o600
                assert os.path.getsize(os.path.join(work, "served.mp4")) > 0 and os.path.getsize(os.path.join(work, "served-sound.mp4")) > 0
                # the box-side scripts run on this computer; the sidecars of the closed recordings are "pulled" as test-vm.sh does
                closed = os.path.join(work, "closed")
                for root, _, names in os.walk(recordings):
                    for name in names:
                        if name.endswith(".cbidx"):
                            target = os.path.join(closed, os.path.relpath(os.path.join(root, name), recordings))
                            os.makedirs(os.path.dirname(target), exist_ok=True)
                            shutil.copy(os.path.join(root, name), target)
                lines, failed = run_phase("plan-seed", client, seed_files=40)
                assert failed == 0, lines
                seed = os.path.join(work, "seed")
                plan = load_plan(client)
                assert plan["count"] == 40 and len(plan["oldRelatives"]) == 4 and plan["template"]["records"] == 12
                capped = plan_seed(closed, os.path.join(tmp, "capped"), started, 40, camera, byte_budget=10 * (plan["baseSize"] + 104))
                assert capped["count"] == 10, "the size budget caps the number of seeds"
                assert max(plan["seedStarts"]) + plan["seedMs"] <= started - 90_000 - 300_000 + 2000
                assert fake.files() and len(os.listdir(os.path.join(seed, "sidecars"))) >= 2
                for relative in plan["seedRelatives"] + plan["oldRelatives"]:
                    parse_cbidx(open(os.path.join(seed, "sidecars", relative + ".cbidx"), "rb").read(), mp4_size=plan["baseSize"])
                shutil.copytree(seed, stage)
                env = open(os.path.join(seed, "plan.env")).read()
                env += "NVR_ROOT=%s\nexport NVR_ROOT\nNVR_STAGE=%s\nexport NVR_STAGE\n" % (recordings, stage)
                for script in ("tear", "seed"):
                    if script == "seed":   # test-vm.sh pulls torn-head.mp4 between the two
                        shutil.copy(os.path.join(stage, "torn-head.mp4"), os.path.join(work, "torn-head.mp4"))
                    done = subprocess.run(["bash", "-s"], input=(env + VM_SCRIPTS[script]).encode(), capture_output=True, timeout=60)
                    assert done.returncode == 0, done.stderr.decode()
                assert not os.path.exists(stage), "the seed script removes its stage"
                folder = os.path.join(recordings, camera)
                assert len([n for _, _, names in os.walk(folder) for n in names if n.endswith(".mp4")]) == 40 + 4 + 1 + 1 + 1   # seeds, old seeds, link, torn, sound file
                assert os.path.islink(os.path.join(folder, plan["oldRelatives"][0].split("/")[0], "00-00-01.mp4"))
                torn = os.path.join(recordings, plan["tear"]["relative"])
                assert os.path.getsize(torn + ".mp4") == plan["tear"]["truncateTo"] and not os.path.exists(torn + ".cbidx")
                # what the store's repair does (T02), so that verify-seed has something to check
                tear = plan["tear"]
                with open(torn + ".mp4", "r+b") as handle:
                    handle.truncate(tear["keep"])
                original = parse_cbidx(open(os.path.join(closed, tear["relative"] + ".cbidx"), "rb").read())
                kept = original["records"][:tear["index"]]
                repaired = build_cbidx(original["camera"], original["start"], original["start"] + kept[-1]["wall"] + 2000, tear["keep"], original["initLength"], kept)
                with open(torn + ".cbidx", "wb") as handle:
                    handle.write(repaired)
                shutil.copy(torn + ".cbidx", os.path.join(work, "repaired.cbidx"))
                # what retention does (T02): the expired recordings and their empty day
                for relative in plan["oldRelatives"]:
                    for extension in (".mp4", ".cbidx"):
                        os.remove(os.path.join(folder, relative + extension))
                os.rmdir(os.path.join(folder, plan["oldRelatives"][3].split("/")[0]))
                fake.ready = False
                lines, failed = run_phase("wait-ready", client)
                assert failed == 1 and any("503 archive_unavailable" in line for line in lines), lines
                fake.ready = True
                for name in ("wait-ready", "wait-oldest", "verify-seed"):
                    lines, failed = run_phase(name, client)
                    assert failed == 0, "%s: %s" % (name, [line for line in lines if line.startswith("FAIL")])
                # a seed that serves other bytes than were written is noticed
                victim = os.path.join(folder, plan["seedRelatives"][0] + ".mp4")
                os.remove(victim)
                with open(victim, "wb") as handle:
                    handle.write(open(os.path.join(work, "torn-head.mp4"), "rb").read()[:plan["baseSize"]][:-1] + b"\x00")
                lines, failed = run_phase("verify-seed", client)
                assert failed >= 1, "a changed seed was not noticed"
            finally:
                fake.close()
                os.environ.pop("CB_TEST_PASSWORD", None)

    @case
    def the_phases_notice_a_box_that_breaks_the_contract():
        camera = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
        with tempfile.TemporaryDirectory() as tmp:
            recordings, started = os.path.join(tmp, "recordings"), now_ms() // 1000 * 1000
            data, index = synthetic_recording(camera, started - 60_000, 12)
            stem = os.path.join(recordings, segment_of(camera, started - 60_000))
            os.makedirs(os.path.dirname(stem), exist_ok=True)
            open(stem + ".mp4", "wb").write(data)
            open(stem + ".cbidx", "wb").write(index)
            fake = FakeBox(recordings, camera)
            os.environ["CB_TEST_PASSWORD"] = "correct horse battery"
            try:
                client = Client(fake.base, os.path.join(tmp, "work"))
                for name in ("session", "add-camera", "choose-folder", "record-on"):
                    assert run_phase(name, client)[1] == 0
                for phase in ("fetch", "security"):
                    assert run_phase(phase, client)[1] == 0, phase
                for flaw, phase in (("head", "security"), ("csp", "security"), ("nostore", "fetch"), ("prft", "fetch")):
                    fake.flaws = {flaw}
                    assert run_phase(phase, client)[1] >= 1, "%s was not noticed by %s" % (flaw, phase)
                fake.flaws = set()
                # a path that resets connections which arrive together (QEMU's user-mode port forwarding on a macOS host): the burst has to say that
                # nothing answered, not list statuses, and say where to run it instead
                fake.flaws = {"reset"}
                lines, failed = run_phase("burst", client)
                shown = [line for line in lines if line.startswith("FAIL")]
                assert failed >= 1, "resets during the burst were not noticed"
                assert any("no answer at all" in line and "from inside the box" in line for line in shown), "the burst does not explain the resets: %r" % (shown,)
                fake.flaws = set()
                for expect, notice in (("low", "low"), ("full", "full"), ("none", None)):
                    fake.notice = notice
                    lines, failed = run_phase("notices", client, expect=expect)
                    assert failed == 0, (expect, lines)
                fake.notice = "low"
                assert run_phase("notices", client, expect="full")[1] == 1
                fake.notice = None
                lines, failed = run_phase("burst", client)
                assert failed == 0, lines
                journal = os.path.join(tmp, "journal.txt")
                open(journal, "w").write("started\nweb interface listening on port 80\n")
                assert run_phase("leakscan", client, journal=journal)[1] == 0
                open(journal, "a").write("cookie " + client.state["cookie"] + "\nGET /api/v1/nvr/cameras\n")
                assert run_phase("leakscan", client, journal=journal)[1] == 2
            finally:
                fake.close()
                os.environ.pop("CB_TEST_PASSWORD", None)

    @case
    def the_newest_recording_is_waited_for_after_a_power_cut():
        # nvr-faults after the power cut (the smoke run of 2026-10-11): the archive holds hours of recordings, then a gap, then the file the recorder
        # opened when the box came back, which is one fragment (2 s) long. The extent runs from the oldest recording to the newest, so "span >= 6 s"
        # was true at once, and fetch asked for newest - 3 s, which lies in the gap: found false, reason gap. The phases have to look at the newest
        # file's own span, wait for it (bounded) and, when it does not get there, say that instead of a gap.
        camera = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
        with tempfile.TemporaryDirectory() as tmp:
            recordings, started = os.path.join(tmp, "recordings"), now_ms() // 1000 * 1000
            old = started - 3 * 3_600_000
            data, index = synthetic_recording(camera, old, 12)
            stem = os.path.join(recordings, segment_of(camera, old))
            os.makedirs(os.path.dirname(stem), exist_ok=True)
            open(stem + ".mp4", "wb").write(data)
            open(stem + ".cbidx", "wb").write(index)
            fresh = GrowingRecording(recordings, camera, started - 20_000, fragments=1, limit=8)
            fake = FakeBox(recordings, camera)
            os.environ["CB_TEST_PASSWORD"] = "correct horse battery"
            try:
                client = Client(fake.base, os.path.join(tmp, "work"))
                for name, options in (("session", {}), ("add-camera", {}), ("choose-folder", {}), ("record-on", {"seconds": 1})):
                    lines, failed = run_phase(name, client, **options)
                    assert failed == 0, "%s: %s" % (name, lines)
                entry = client.extent()[1]
                assert entry["newest"] - entry["oldest"] > 3_600_000 and fresh.fragments == 1, "the set-up is not a short new file after a long archive"
                # 1. wait-recording --seconds 6 may not be satisfied by the days before the gap: it waits until the new file has 6 s
                fake.recorder = fresh
                lines, failed = run_phase("wait-recording", client, seconds=6)
                assert failed == 0, lines
                assert fresh.fragments >= 3, "wait-recording passed with a newest file of %d fragments (%d s), the archive before it counted" % (fresh.fragments, 2 * fresh.fragments)
                # 2. fetch on a file that never gets to 3 s says so (and is not reported as a gap in the plan)
                fake.recorder = None
                fresh.reset(1)
                lines, failed = run_phase("fetch", client)
                shown = [line for line in lines if line.startswith("FAIL")]
                assert failed >= 1 and any("newest recording" in line for line in shown), "a newest file of 2 s was not reported as such: %r" % (shown,)
                assert not any(line.startswith("FAIL fragments?at=") for line in shown), "the failure is the plan's answer for a time in the gap, not the length of the newest recording: %r" % (shown,)
                # 3. fetch on a file that gets there while it waits passes (the recorder writes its next fragment when the box is polled for the third time)
                fresh.reset(1, begin=3)
                fake.recorder = fresh
                lines, failed = run_phase("fetch", client)
                assert failed == 0, lines
                assert fresh.fragments >= 2, "the recorder never wrote the fragment fetch waited for"
            finally:
                fake.close()
                os.environ.pop("CB_TEST_PASSWORD", None)

    @case
    def the_fake_box_has_the_security_headers_and_the_cookie_of_the_daemon():
        # The dry run puts the FakeBox in front of the shell code of test-vm.sh, and that code runs T07's conformance.mjs against the box when
        # the file and Node 22 exist. A stand-in that differs from the daemon in what that tool reads (all seven security headers on every
        # answer, the attributes of the session cookie) fails the dry run for a reason that is not in test-vm.sh. So: pin the FakeBox to the
        # daemon, and to the two files that state the daemon's side, and let the independent checker look at it where Node 22 is at hand.
        camera, password = "6F9619FF-8B86-D011-B42D-00C04FC964FF", "correct horse battery"
        here = os.path.dirname(os.path.abspath(__file__))
        # the headers written out once more, so that the case does not compare the FakeBox with the table it is built from
        golden = {"Content-Security-Policy": CSP, "X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY", "Referrer-Policy": "no-referrer",
                  "Cross-Origin-Opener-Policy": "same-origin", "Cross-Origin-Resource-Policy": "same-origin",
                  "Permissions-Policy": "camera=(), microphone=(), geolocation=(self), payment=(), usb=()"}
        assert dict(SECURITY_HEADERS) == {name: value for name, value in golden.items() if name != "Content-Security-Policy"}, "the table is not the golden headers"
        assert STAND_IN_HEADER[0] == "X-CB-Stand-In", "test-vm.sh looks for the header x-cb-stand-in"
        vm_script = os.path.join(here, "test-vm.sh")
        if os.path.exists(vm_script):
            assert "grep -qi '^x-cb-stand-in:'" in open(vm_script, encoding="utf-8").read(), "test-vm.sh does not look for the stand-in header"
        with tempfile.TemporaryDirectory() as tmp:
            fake = FakeBox(os.path.join(tmp, "recordings"), camera)
            os.environ["CB_TEST_PASSWORD"] = password
            try:
                client = Client(fake.base, os.path.join(tmp, "work"))
                post = lambda path, body: client.raw("POST", path, body, cookie=False, csrf=False)
                setup, wrong, login = post("/api/v1/auth/setup", {"password": password}), post("/api/v1/auth/login", {"password": password + "x"}), \
                    post("/api/v1/auth/login", {"password": password})
                assert (setup.status, wrong.status, login.status) == (201, 401, 200), (setup.status, wrong.status, login.status)
                answers = {"the page": client.raw("GET", "/", cookie=False), "health": client.raw("GET", "/api/v1/health", cookie=False),
                           "session": client.raw("GET", "/api/v1/session", cookie=False), "setup": setup, "a refused sign-in": wrong, "login": login,
                           "an NVR route without a session": client.raw("GET", "/api/v1/nvr/storage", cookie=False)}
                for label, reply in answers.items():
                    for name, value in list(golden.items()) + [STAND_IN_HEADER]:
                        assert reply.header(name) == value, "%s: the header %s is %r, expected %r" % (label, name, reply.header(name), value)
                for label, reply in (("setup", setup), ("login", login)):
                    cookie = reply.header("set-cookie") or ""
                    token = re.match(r"^cb_session=([0-9a-f]{32})(;|$)", cookie)
                    shown = re.sub(r"=[0-9a-f]{32}", "=...", cookie)
                    assert token and cookie == SESSION_COOKIE % token.group(1), "%s: the cookie is %r, the daemon sends %r" % (label, shown, SESSION_COOKIE % "...")
                    assert all(re.search(r";\s*" + attribute + r"(;|$)", cookie, re.I) for attribute in ("HttpOnly", "SameSite=Strict", "Path=/")), \
                        "%s: the cookie %r lacks HttpOnly, SameSite=Strict or Path=/" % (label, shown)   # the words conformance.mjs looks for
                # the two files that state the daemon's side; absent in an export that leaves them out, and then the table above stands alone
                security = os.path.join(here, "..", "web-dev", "lib", "security.mjs")
                if os.path.exists(security):
                    block = re.search(r"export const SECURITY_HEADERS = \{(.*?)\};", open(security, encoding="utf-8").read(), re.S)
                    assert block and dict(re.findall(r"'([A-Za-z-]+)': '([^']*)'", block.group(1))) == dict(SECURITY_HEADERS), "security.mjs states other headers than this file"
                else:
                    note("(security.mjs not found: the header table was not compared with it)")
                swift = os.path.join(here, "..", "..", "Packages", "CameraBridgeKit", "Sources", "BridgeWeb", "WebApp.swift")
                if os.path.exists(swift):
                    source = open(swift, encoding="utf-8").read()
                    function = re.search(r"static func addSecurityHeaders\(.*?\n    \}\n", source, re.S)
                    sent = dict(re.findall(r'response\.headers\["([A-Za-z-]+)"\] = "([^"]*)"', function.group(0) if function else ""))
                    for dropped in ("Content-Security-Policy", "Cache-Control"):   # the CSP is two string literals, Cache-Control is for the API only
                        sent.pop(dropped, None)
                    assert sent == dict(SECURITY_HEADERS), "WebApp.swift sends other headers than this file: %r" % sent
                    assert "; Path=/; HttpOnly; SameSite=Strict; Max-Age=" in source, "WebApp.swift sets the session cookie with other attributes"
                else:
                    note("(WebApp.swift not found: the header table was not compared with it)")
                # the independent checker, where it can run: the two groups of checks that read exactly this
                checker = os.path.join(here, "..", "web-dev", "conformance.mjs")
                node = shutil.which("node")
                major = int(subprocess.run([node, "-p", "process.versions.node.split('.')[0]"], capture_output=True, text=True).stdout or 0) if node else 0
                if os.path.exists(checker) and major >= 22:
                    for only in ("headers", "sign-in"):
                        done = subprocess.run([node, checker, fake.base, "--only", only], env=dict(os.environ, CB_PASSWORD=password), capture_output=True, text=True,
                                              timeout=60)
                        lines = [line for line in done.stdout.splitlines() if line.startswith((" ok ", "FAIL"))]
                        assert lines and all(line.startswith(" ok ") for line in lines), "conformance.mjs --only %s: %s" % (only, done.stdout.strip()[:400])
                else:
                    note("(conformance.mjs was not run: it needs the file and Node 22 or newer)")
            finally:
                fake.close()
                os.environ.pop("CB_TEST_PASSWORD", None)

    failures = [(name, problem) for name, problem in outcomes if problem]
    for name, problem in outcomes:
        ok(name.replace("_", " ")) if not problem else bad("%s: %s" % (name.replace("_", " "), problem))
    say("selftest: %d cases, %d failed" % (len(outcomes), len(failures)))
    return 1 if failures else 0


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("phase", choices=sorted(PHASES) + ["selftest", "vm-script", "state"])
    parser.add_argument("--base", default="http://127.0.0.1:18080")
    parser.add_argument("--dir", default=".")
    parser.add_argument("--camera-name", default="Smoke camera")
    parser.add_argument("--recordings-path", default="/var/lib/camera-bridge/recordings")
    parser.add_argument("--seconds", type=int, default=12, help="recorded seconds to wait for (record-on, wait-recording)")
    parser.add_argument("--seed-files", type=int, default=2000)
    parser.add_argument("--expect", choices=["none", "low", "full"], default="none")
    parser.add_argument("--journal", default="")
    parser.add_argument("--file", default="", help="check-sidecar: the sidecar")
    parser.add_argument("--size", type=int, default=0, help="check-sidecar: the size of its mp4")
    parser.add_argument("--inside-box", action="store_true", help="burst: this program runs inside the box (test-vm.sh --burst-from guest); only changes what it says")
    parser.add_argument("--key", default="camera", help="state: the value to print")
    parser.add_argument("--name", choices=sorted(VM_SCRIPTS), default="seed", help="vm-script: which script to print")
    args = parser.parse_args(argv)
    if args.phase == "selftest":
        return selftest()
    if args.phase == "vm-script":
        sys.stdout.write(VM_SCRIPTS[args.name])
        return 0
    client = Client(args.base, args.dir)
    if args.phase == "state":
        print(client.state.get(args.key, ""))
        return 0
    try:
        if args.phase != "session" and args.phase not in OFFLINE and not client.state.get("cookie"):
            client.login()
        PHASES[args.phase](client, args)
    except Abort as error:
        bad("%s stopped: %s" % (args.phase, error))
    except (OSError, http.client.HTTPException, ValueError, KeyError, TypeError, IndexError) as error:
        bad("%s raised %s: %s" % (args.phase, type(error).__name__, error))
    return 1 if REPORT.failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
