// hls-check: opens an HLS address in a real AVPlayer, with no screen, and prints what the player says.
//
// Standalone macOS tool, not part of any package:
//   swiftc -O Tools/hls-check/main.swift -o /tmp/hls-check
//   /tmp/hls-check <url> <seconds> [--seek <seconds>] [--seek-at <seconds>] [--until-end] [--pause-at <seconds> --resume-at <seconds>]
//
// Every second it prints the item's status, the time-control status, the current time, `isPlaybackLikelyToKeepUp`, the buffered seconds and how
// many pictures were really decoded (an AVPlayerItemVideoOutput pulls them, because a player with no layer has no other proof that its pictures
// decode). Every error log event and every player notification is printed as it happens, then a summary with the asset's properties, including
// `isCompatibleWithAirPlayVideo`, and the access log.
//
// The player is muted: the demo camera's sound is a test tone. Exit status: 0 when the item was ready, time advanced and no error ended it.

import AVFoundation
import CoreMedia
import Foundation
import QuartzCore

struct Options {
    var url: URL
    var seconds: Double
    /// Seek here before playing.
    var seek: Double?
    /// Seek to `seek` this many seconds into playback, rather than before it.
    var seekAt: Double?
    /// Stop when the item plays to its end instead of waiting out `seconds`.
    var untilEnd = false
    /// Pause at this time and play again at the other, for what a pause does to a live stream.
    var pauseAt: Double?
    var resumeAt: Double?

    static func parse(_ arguments: [String]) -> Options? {
        guard arguments.count >= 2, let url = URL(string: arguments[0]), let seconds = Double(arguments[1]), seconds > 0 else { return nil }
        var options = Options(url: url, seconds: seconds)
        var rest = arguments.dropFirst(2).makeIterator()
        while let flag = rest.next() {
            switch flag {
            case "--seek":
                guard let value = rest.next().flatMap(Double.init) else { return nil }
                options.seek = value
            case "--seek-at":
                guard let value = rest.next().flatMap(Double.init) else { return nil }
                options.seekAt = value
            case "--until-end":
                options.untilEnd = true
            case "--pause-at":
                guard let value = rest.next().flatMap(Double.init) else { return nil }
                options.pauseAt = value
            case "--resume-at":
                guard let value = rest.next().flatMap(Double.init) else { return nil }
                options.resumeAt = value
            default:
                return nil
            }
        }
        return options
    }
}

/// Seconds since the tool started, so that lines from the loop and from notifications line up.
let started = CACurrentMediaTime()
func stamp() -> String { String(format: "%6.2fs", CACurrentMediaTime() - started) }
func say(_ text: String) {
    print("\(stamp())  \(text)")
    fflush(stdout)
}

func name(_ status: AVPlayerItem.Status) -> String {
    switch status {
    case .unknown: "unknown"
    case .readyToPlay: "readyToPlay"
    case .failed: "failed"
    @unknown default: "other"
    }
}

func name(_ status: AVPlayer.TimeControlStatus) -> String {
    switch status {
    case .paused: "paused"
    case .waitingToPlayAtSpecifiedRate: "waiting"
    case .playing: "playing"
    @unknown default: "other"
    }
}

/// The error, then every underlying error, one line each.
func describe(_ error: Error) -> [String] {
    var lines: [String] = []
    var current: NSError? = error as NSError
    while let found = current {
        var line = "\(found.domain) \(found.code): \(found.localizedDescription)"
        if let reason = found.localizedFailureReason { line += " | reason: \(reason)" }
        if let hint = found.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String { line += " | suggestion: \(hint)" }
        lines.append(line)
        current = found.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return lines
}

func seconds(_ time: CMTime) -> String {
    time.isNumeric ? String(format: "%.3f", time.seconds) : "\(time.flags)"
}

func text(_ range: CMTimeRange) -> String {
    "\(seconds(range.start))+\(seconds(range.duration))"
}

func ranges(_ values: [NSValue]) -> String {
    values.map { text($0.timeRangeValue) }.joined(separator: " ")
}

/// Prints each error log event once.
final class ErrorLogReader {
    private var seen = 0
    private(set) var total = 0

    func read(_ item: AVPlayerItem) async {
        guard let events = await item.errorLog?.events, events.count > seen else { return }
        for event in events[seen...] {
            let date = event.date.map { String(format: "%.3f", $0.timeIntervalSince1970) } ?? "-"
            // The file's name alone: the rest of the address holds the ticket.
            let file = event.uri.flatMap { URL(string: $0)?.lastPathComponent } ?? "-"
            say("ERROR-LOG domain=\(event.errorDomain) code=\(event.errorStatusCode) comment=\(event.errorComment ?? "-") file=\(file) date=\(date)")
        }
        seen = events.count
        total = events.count
    }
}

@MainActor
func run(_ options: Options) async -> Int32 {
    let asset = AVURLAsset(url: options.url)
    let item = AVPlayerItem(asset: asset)
    let output = AVPlayerItemVideoOutput(outputSettings: nil)
    item.add(output)
    let player = AVPlayer(playerItem: item)
    player.isMuted = true

    let errors = ErrorLogReader()
    var observers: [NSObjectProtocol] = []
    var ended = false
    var failedToEnd = false
    var stalls = 0
    let center = NotificationCenter.default
    func watch(_ name: Notification.Name, _ body: @escaping @Sendable (Notification) -> Void) {
        observers.append(center.addObserver(forName: name, object: item, queue: .main, using: body))
    }
    let endedFlag = Flag(), failedFlag = Flag(), stallCount = Counter()
    watch(AVPlayerItem.didPlayToEndTimeNotification) { _ in
        say("NOTE didPlayToEnd")
        endedFlag.set()
    }
    watch(AVPlayerItem.failedToPlayToEndTimeNotification) { note in
        say("NOTE failedToPlayToEnd")
        if let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
            for line in describe(error) { say("     \(line)") }
        }
        failedFlag.set()
    }
    watch(AVPlayerItem.playbackStalledNotification) { _ in
        say("NOTE playbackStalled")
        stallCount.add()
    }
    watch(AVPlayerItem.timeJumpedNotification) { _ in say("NOTE timeJumped") }
    let newErrorEvent = Flag()
    watch(AVPlayerItem.newErrorLogEntryNotification) { _ in newErrorEvent.set() }

    say("open \(options.url.host() ?? "?"):\(options.url.port ?? 0) (the path holds the ticket, so it is left out)")
    if let seek = options.seek, options.seekAt == nil {
        let done = await player.seek(to: CMTime(seconds: seek, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        say("seek \(seek) before playing finished: \(done)")
    }
    player.play()

    var lastPrint = -1.0, lastStatus = AVPlayerItem.Status.unknown, lastControl = AVPlayer.TimeControlStatus.paused
    var firstReady: Double?, firstFrame: Double?, firstAdvance: Double?
    var frames = 0, firstTime = Double.nan, lastTime = Double.nan, lastFramePTS = Double.nan
    var decodedPTSJumps: [String] = []
    var seeked = false, paused = false, resumed = false
    var failedAt: Double?
    var reported = false

    while CACurrentMediaTime() - started < options.seconds {
        ended = endedFlag.value
        failedToEnd = failedFlag.value
        stalls = stallCount.value
        let now = CACurrentMediaTime() - started
        if newErrorEvent.take() { await errors.read(item) }

        if item.status != lastStatus {
            lastStatus = item.status
            say("STATUS \(name(item.status))")
            if item.status == .readyToPlay, firstReady == nil { firstReady = now }
            if item.status == .failed {
                if let error = item.error { for line in describe(error) { say("     item.error \(line)") } }
                if !failedToEnd { break }
            }
        }
        if player.timeControlStatus != lastControl {
            lastControl = player.timeControlStatus
            say("CONTROL \(name(lastControl)) reason=\(player.reasonForWaitingToPlay?.rawValue ?? "-")")
        }
        if player.status == .failed {
            say("PLAYER failed")
            if let error = player.error { for line in describe(error) { say("     player.error \(line)") } }
            break
        }

        let hostTime = CACurrentMediaTime()
        let itemTime = output.itemTime(forHostTime: hostTime)
        if output.hasNewPixelBuffer(forItemTime: itemTime) {
            let (buffer, display) = output.pixelBufferAndDisplayTime(forItemTime: itemTime)
            if buffer != nil {
                frames += 1
                if firstFrame == nil {
                    firstFrame = now
                    say("FIRST PICTURE decoded at item time \(seconds(display)), presentation size \(item.presentationSize)")
                }
                if display.isNumeric {
                    let pts = display.seconds
                    if !lastFramePTS.isNaN, pts < lastFramePTS - 0.001 || pts > lastFramePTS + 1 {
                        decodedPTSJumps.append(String(format: "%.3f->%.3f", lastFramePTS, pts))
                    }
                    lastFramePTS = pts
                }
            }
        }

        let current = player.currentTime().seconds
        if current.isFinite {
            if firstTime.isNaN { firstTime = current }
            if !lastTime.isNaN, current > firstTime + 0.1, firstAdvance == nil { firstAdvance = now }
            lastTime = current
        }

        if let at = options.seekAt, let target = options.seek, !seeked, now >= at {
            seeked = true
            let done = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            say("seek \(target) finished: \(done), current \(seconds(player.currentTime()))")
        }

        if let at = options.pauseAt, !paused, now >= at {
            paused = true
            player.pause()
            say("pause")
        }
        if let at = options.resumeAt, !resumed, now >= at {
            resumed = true
            player.play()
            say("play again")
        }

        if now - lastPrint >= 1 {
            lastPrint = now
            await errors.read(item)
            let buffered = item.loadedTimeRanges.last.map { CMTimeRangeGetEnd($0.timeRangeValue).seconds - max(current, 0) } ?? 0
            say(String(format: "status=%@ control=%@ time=%.3f keepUp=%@ buffered=%.1f pictures=%d", name(item.status), name(player.timeControlStatus), current,
                       item.isPlaybackLikelyToKeepUp ? "yes" : "no", buffered, frames))
        }

        if options.untilEnd, ended { break }
        // A little longer than the failure itself: what the item's status does next is part of what is being looked at.
        if failedToEnd {
            let at = failedAt ?? now
            failedAt = at
            if now - at >= 3 { break }
        }
        if !reported, item.status == .readyToPlay {
            reported = true
            say("seekable=\(ranges(item.seekableTimeRanges)) duration=\(seconds(item.duration)) presentationSize=\(item.presentationSize)")
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    await errors.read(item)

    print("--- summary")
    print("item.status          \(name(item.status))")
    if let error = item.error { for line in describe(error) { print("item.error           \(line)") } }
    print("timeControlStatus    \(name(player.timeControlStatus)) reason=\(player.reasonForWaitingToPlay?.rawValue ?? "-")")
    print("readyToPlay after    \(firstReady.map { String(format: "%.2f s", $0) } ?? "never")")
    print("first picture after  \(firstFrame.map { String(format: "%.2f s", $0) } ?? "never")")
    print("time advanced after  \(firstAdvance.map { String(format: "%.2f s", $0) } ?? "never")")
    print(String(format: "time                 from %.3f to %.3f", firstTime, lastTime))
    print("pictures decoded     \(frames)")
    print("decoded pts jumps    \(decodedPTSJumps.isEmpty ? "none" : decodedPTSJumps.joined(separator: " "))")
    print("likelyToKeepUp       \(item.isPlaybackLikelyToKeepUp)")
    print("stall notifications  \(stalls)")
    print("played to end        \(ended)")
    print("failed to end        \(failedToEnd)")
    print("seekable             \(ranges(item.seekableTimeRanges))")
    print("loaded               \(ranges(item.loadedTimeRanges))")
    print("duration             \(seconds(item.duration))")
    print("presentationSize     \(item.presentationSize)")

    do {
        let (playable, airPlay, duration) = try await asset.load(.isPlayable, .isCompatibleWithAirPlayVideo, .duration)
        print("asset.isPlayable     \(playable)")
        print("isCompatibleWithAirPlayVideo \(airPlay)")
        print("asset.duration       \(seconds(duration))")
    } catch {
        for line in describe(error) { print("asset.load failed    \(line)") }
    }
    for track in item.tracks {
        print("track                \(track.assetTrack?.mediaType.rawValue ?? "?") enabled=\(track.isEnabled) fps=\(track.currentVideoFrameRate)")
    }

    print("error log events     \(errors.total)")
    for event in await item.accessLog?.events ?? [] {
        print(String(format: "access log           type=%@ requests=%d played=%.1f stalls=%d dropped=%d indicated=%.0f observed=%.0f bytes=%lld startup=%.2f",
                     event.playbackType ?? "-", event.numberOfMediaRequests, event.durationWatched, event.numberOfStalls, event.numberOfDroppedVideoFrames,
                     event.indicatedBitrate, event.observedBitrate, event.numberOfBytesTransferred, event.startupTime))
    }
    player.pause()
    for observer in observers { center.removeObserver(observer) }

    let good = item.status == .readyToPlay && item.error == nil && !failedToEnd && !lastTime.isNaN && lastTime > firstTime + 0.1 && frames > 0
    print("verdict              \(good ? "PLAYS" : "DOES NOT PLAY")")
    return good ? 0 : 1
}

/// Written on the main queue by the notification blocks, read by the loop.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set() { lock.withLock { stored = true } }
    /// The value, which goes back to false.
    func take() -> Bool {
        lock.withLock {
            defer { stored = false }
            return stored
        }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    func add() { lock.withLock { stored += 1 } }
}

guard let options = Options.parse(Array(CommandLine.arguments.dropFirst())) else {
    print("usage: hls-check <url> <seconds> [--seek <seconds>] [--seek-at <seconds>] [--until-end] [--pause-at <seconds> --resume-at <seconds>]")
    exit(2)
}
exit(await run(options))
