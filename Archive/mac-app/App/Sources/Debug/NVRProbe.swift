#if DEBUG
import AVFoundation
import AppKit
import BridgeEngine
import BridgeSupport
import Foundation
import MediaCore
import Synchronization

/// Debug builds only, and only in a measurement run (`-isolatedEngine`, `AppModel.isolatedRun`). Writes what the soak and the budgets of the Mac
/// spec section 14 need into `<data>/probe/`: `heartbeat.jsonl` (every 10 s: archive readiness, storage numbers, each camera's recording state,
/// newest footage and lag), `events.jsonl` (launch, ready, switch-on, quit), and one `<scenario>.json` per `-nvrProbe` scenario. `Tools/nvr_soak_report.py`
/// reads them. Pictures are timed where they can be seen: `readback` says whether the displayed picture could be read back from the layer
/// (`layer`: `displayedPicture()` worked as it is; `pausedSynchronizer`: it worked after `LiveVideoRenderer.setProbeMode(true)`; `none`: it did not,
/// and times are those of the hand-over to the renderer, "enqueue").
@MainActor
enum NVRProbe {
    /// Held for the whole run: no App Nap for a background app and no idle system sleep, as Keep Mac Awake gives the installed app (the isolated
    /// environment has no power manager of its own).
    private static var activity: (any NSObjectProtocol)?

    static func start(model: AppModel, run: IsolatedEngineOptions) {
        let launch = ProcessInfo.processInfo.systemUptime
        Scenarios.launched = Date()
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Camera Bridge NVR measurement run")
        let files = ProbeFiles(directory: run.directory)
        files.append("events", ["t": Date().timeIntervalSince1970, "event": "launch", "cameras": run.demoCameras, "probe": run.probe ?? NSNull()])

        Task { @MainActor in   // readiness, to 50 ms
            let ready = await Stage.until(timeout: 600, poll: 0.05) { model.engine.archive.isReady }
            files.append("events", ["t": Date().timeIntervalSince1970, "event": ready ? "ready" : "not-ready", "ms": (ProcessInfo.processInfo.systemUptime - launch) * 1_000])
        }
        Task { @MainActor in   // heartbeat
            while !Task.isCancelled {
                heartbeat(model: model, files: files, launch: launch)
                try? await Task.sleep(for: .seconds(run.heartbeat))
            }
        }
        if run.recordAfter > 0 {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(run.recordAfter))
                for camera in IsolatedEngineSeed.seededCameras(model.engine.configurations) { try? await model.engine.setNVR(cameraID: camera.id, enabled: true) }
                files.append("events", ["t": Date().timeIntervalSince1970, "event": "record-on"])
            }
        }
        if let quitAfter = run.quitAfter {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(quitAfter))
                files.append("events", ["t": Date().timeIntervalSince1970, "event": "quit-begin"])
                Quit.now()
            }
        }
        if let text = run.probe, let scenarios = ProbeScenario.parse(text) {
            Task { @MainActor in
                for scenario in scenarios { await Scenarios.run(scenario, model: model, files: files) }
                files.append("events", ["t": Date().timeIntervalSince1970, "event": "probes-done"])
                Quit.now()
            }
        }
    }

    private static func heartbeat(model: AppModel, files: ProbeFiles, launch: TimeInterval) {
        let engine = model.engine, archive = engine.archive, now = Date()
        var storage: [String: Any] = [:]
        if let status = engine.nvrStorage {
            storage = ["used": status.usedBytes, "free": status.freeBytes, "total": status.totalBytes, "floor": status.floorBytes,
                       "pause": status.pause?.code ?? NSNull(), "oldest": status.oldest?.timeIntervalSince1970 ?? NSNull(),
                       "newest": status.newest?.timeIntervalSince1970 ?? NSNull()]
        }
        let cameras = engine.cameras.filter { $0.name.hasPrefix(IsolatedEngineOptions.cameraNamePrefix) }.map { status -> [String: Any] in
            let extent = archive.extent(camera: status.id)
            return ["name": status.name, "state": ProbeFiles.name(of: status.nvr.state), "detail": status.nvr.detail ?? NSNull(),
                    "notes": status.nvr.notes.map(\.id.rawValue), "oldest": extent?.oldest.timeIntervalSince1970 ?? NSNull(),
                    "newest": extent?.newest.timeIntervalSince1970 ?? NSNull(), "lag": extent.map { now.timeIntervalSince($0.newest) } ?? NSNull(),
                    "gop": extent?.typicalGOP ?? NSNull(), "viewers": status.appViewers]
        }
        files.append("heartbeat", ["t": now.timeIntervalSince1970, "issue": model.bridgeIssue?.title ?? NSNull(), "uptime": ProcessInfo.processInfo.systemUptime - launch, "ready": archive.isReady,
                                   "catalogVersion": archive.catalogVersion, "storage": storage, "cameras": cameras])
    }
}

/// Quits the way Cmd-Q does (`applicationShouldTerminate`, `prepareToTerminate`, `engine.stop()`). `NSApp.terminate` waits for the delegate's reply in a
/// nested event loop; called inside a main-actor task it would wait for a reply that task itself has to send, and never return. So the call is
/// handed to the run loop and made after the task has finished.
@MainActor
enum Quit {
    static func now() {
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.05)
    }
}

// MARK: - The sink every probe cell uses

/// The real renderer behind a recorder of what the cell did: when each displayable picture was handed over and which recorded instant it shows.
nonisolated final class ProbingSink: ArchiveVideoSink, @unchecked Sendable {
    struct Shown: Sendable {
        var uptime: TimeInterval
        var wall: Date
        var isKeyframe: Bool
    }

    let renderer: LiveVideoRenderer
    private let log = Mutex<(shown: [Shown], decodeOnly: Int, resets: Int)>(([], 0, 0))

    init(renderer: LiveVideoRenderer) { self.renderer = renderer }

    func show(_ frame: EncodedVideoFrame) { show(frame, decodeOnly: false) }

    func show(_ frame: EncodedVideoFrame, decodeOnly: Bool) {
        let uptime = ProcessInfo.processInfo.systemUptime
        log.withLock { state in
            if decodeOnly { state.decodeOnly += 1 } else { state.shown.append(Shown(uptime: uptime, wall: frame.wallClock, isKeyframe: frame.isKeyframe)) }
        }
        renderer.show(frame, decodeOnly: decodeOnly)
    }

    func play(_ frame: EncodedAudioFrame) { renderer.play(frame) }

    func reset() {
        log.withLock { $0.resets += 1 }
        renderer.reset()
    }

    func silence() { renderer.silence() }
    func clear() { renderer.clear() }
    var queued: Int { renderer.queued }
    var restarts: Int { renderer.restarts }

    var shownCount: Int { log.withLock { $0.shown.count } }
    func shown(from index: Int) -> [Shown] { log.withLock { Array($0.shown.dropFirst(index)) } }
    var resets: Int { log.withLock { $0.resets } }
}

// MARK: - Stage

/// Time between a main-actor sleep's due time and the moment it ran, collected while a scenario drags: a proxy for main-thread hitches.
@MainActor
final class LatenessMeter {
    private var task: Task<Void, Never>?
    private var samples: [Double] = []

    func start() {
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let due = ProcessInfo.processInfo.systemUptime + 0.002
                try? await Task.sleep(for: .milliseconds(2))
                self?.samples.append(max(0, ProcessInfo.processInfo.systemUptime - due) * 1_000)
            }
        }
    }

    func stop() -> [Double] {
        task?.cancel()
        task = nil
        defer { samples = [] }
        return samples
    }
}

/// One to nine cells in a small window that is on screen: a real `NVRSession`, a real `LiveVideoRenderer` per cell, the engine's real archive. The layers must be in
/// a window that is on screen: a layer in no window gives no displayed picture back (`RendererReadbackTests`).
@MainActor
final class Stage {
    enum Readback: String { case layer, pausedSynchronizer, none }

    let session: NVRSession
    let ids: [UUID]
    private(set) var sinks: [UUID: ProbingSink] = [:]
    private(set) var readback = Readback.none
    private let window: NSWindow

    init(model: AppModel, ids: [UUID], columns: Int, tile: CGSize) {
        self.ids = ids
        let sleeper: @Sendable (TimeInterval) async throws -> Void = { until in
            let delay = until - ProcessInfo.processInfo.systemUptime
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        }
        session = NVRSession(archive: model.engine.archive, clock: PlaybackClock(), makeSink: { ProbingSink(renderer: LiveVideoRenderer()) },
                             now: { ProcessInfo.processInfo.systemUptime }, sleep: sleeper)
        let rows = (ids.count + columns - 1) / columns
        window = NSWindow(contentRect: NSRect(x: 40, y: 80, width: tile.width * CGFloat(min(columns, ids.count)), height: tile.height * CGFloat(rows)),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "NVR probe"
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        content.wantsLayer = true
        window.contentView = content
        session.setCameras(ids)
        for (index, id) in ids.enumerated() {
            guard let sink = session.cell(for: id)?.sink as? ProbingSink else { continue }
            sinks[id] = sink
            let column = index % columns, row = index / columns
            sink.renderer.layer.frame = CGRect(x: CGFloat(column) * tile.width, y: content.bounds.height - CGFloat(row + 1) * tile.height, width: tile.width, height: tile.height)
            content.layer?.addSublayer(sink.renderer.layer)
        }
        window.orderFrontRegardless()
    }

    func close() {
        session.setCameras([])
        window.orderOut(nil)
    }

    static func until(timeout: TimeInterval, poll: TimeInterval = 0.002, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .seconds(poll))
        }
        return condition()
    }

    /// The frame counter of the picture the layer shows, nil when it cannot be read.
    func counter(_ id: UUID) -> Int? {
        sinks[id]?.renderer.displayedPicture().flatMap { DemoCounterReader.read(pixelBuffer: $0) }
    }

    /// Tries to read a displayed picture back: as it is, then with the synchronizer stopped. The first that returns a readable counter is kept.
    func chooseReadback(at time: Date) async {
        guard let id = ids.first, let sink = sinks[id] else { return }
        session.beginScrub()
        session.scrub(to: time)
        if await Stage.until(timeout: 3, poll: 0.01, { counter(id) != nil }) {
            readback = .layer
            return
        }
        sink.renderer.setProbeMode(true)
        session.scrub(to: time.addingTimeInterval(7))
        if await Stage.until(timeout: 3, poll: 0.01, { counter(id) != nil }) {
            readback = .pausedSynchronizer
        } else {
            sink.renderer.setProbeMode(false)
            readback = .none
        }
    }
}

// MARK: - Scenarios

@MainActor
enum Scenarios {
    /// How much footage the cameras must have before a scenario starts, and how long to wait for it.
    static let minimumRecorded: TimeInterval = 180
    /// When the app started: the demo camera's frame counter restarts with the app, so footage from before it (an earlier run in the same folder) is not used.
    static var launched = Date()

    static func run(_ scenario: ProbeScenario, model: AppModel, files: ProbeFiles) async {
        // The probe starts with the app, in parallel to the seed that adds the demo cameras (`IsolatedEngineSeed.apply`, before `engine.start()`): the first
        // scenario must wait for them, or it sees no camera and waits for footage that no camera will make.
        let expectedCameras = max(1, model.isolatedRun?.demoCameras ?? 1)
        _ = await Stage.until(timeout: 120, poll: 0.1) { IsolatedEngineSeed.seededCameras(model.engine.configurations).count >= expectedCameras }
        let ids = IsolatedEngineSeed.seededCameras(model.engine.configurations).map(\.id)
        let count = [.grid, .scrubcost, .play].contains(scenario) ? min(9, ids.count) : 1
        let used = Array(ids.prefix(max(1, count)))
        let archive = model.engine.archive
        let minimum: TimeInterval = scenario == .drivehold ? 60 : minimumRecorded   // drivehold starts early: the drive is pulled at minute 2.5
        let ready = await Stage.until(timeout: 900, poll: 0.5) {
            archive.isReady && !used.isEmpty && used.allSatisfy { id in archive.extent(camera: id).map { $0.newest.timeIntervalSince($0.oldest) >= minimum } ?? false }
        }
        var result: [String: Any]
        if !ready || used.isEmpty {
            result = ["error": "fewer than \(Int(minimum)) s recorded on \(used.count) camera(s) after 15 minutes"]
        } else {
            // Footage of this run only, from a few seconds after the start to a few seconds before now.
            let lower = used.compactMap { archive.extent(camera: $0)?.oldest }.max().map { max($0, launched.addingTimeInterval(5)) } ?? launched
            let upper = used.compactMap { archive.extent(camera: $0)?.newest }.min().map { $0.addingTimeInterval(-8) } ?? launched
            let range = lower...max(lower.addingTimeInterval(30), upper)
            switch scenario {
            case .scrubcost: result = await scrubCost(model: model, ids: used, range: range)
            case .keyframe: result = await keyframe(model: model, id: used[0], range: range)
            case .exact: result = await exact(model: model, id: used[0], range: range)
            case .grid: result = await grid(model: model, ids: used, range: range)
            case .play: result = await play(model: model, ids: used, range: range)
            case .drivehold: result = await driveHold(model: model, id: used[0], range: range)
            }
        }
        result["scenario"] = scenario.rawValue
        result["renderer"] = rendererName
        result["cameras"] = used.count
        result["recordedSeconds"] = recordedSeconds(of: used, archive: archive)
        files.write(scenario.rawValue, result)
    }

    static var rendererName: String {
        if #available(macOS 27, *), ProcessInfo.processInfo.environment["CAMERABRIDGE_CLASSIC_RENDERER"] != "1" { return "receiver" }
        return "classic"
    }

    private static func recordedSeconds(of ids: [UUID], archive: any ArchiveReading) -> Double {
        ids.compactMap { archive.extent(camera: $0).map { $0.newest.timeIntervalSince($0.oldest) } }.min() ?? 0
    }

    private static func random(in range: ClosedRange<Date>) -> Date {
        Date(timeIntervalSince1970: .random(in: range.lowerBound.timeIntervalSince1970...range.upperBound.timeIntervalSince1970))
    }

    // MARK: B1: what scrub(to:) costs the main thread

    /// 3,000 `scrub(to:)` calls at about 120 Hz with 1, 4 and 9 cells; each call is timed, and a 2 ms ticker on the main actor measures how late it runs meanwhile.
    static func scrubCost(model: AppModel, ids: [UUID], range: ClosedRange<Date>) async -> [String: Any] {
        var runs: [[String: Any]] = []
        // The ticker's own noise floor: the same 2 ms ticker for 8 s with nothing scrubbing (timer leeway and the load of the recorders are in it).
        let quiet = LatenessMeter()
        quiet.start()
        try? await Task.sleep(for: .seconds(8))
        let baseline = quiet.stop()
        for cells in [1, 4, 9] where cells <= ids.count {
            let stage = Stage(model: model, ids: Array(ids.prefix(cells)), columns: 3, tile: CGSize(width: 320, height: 180))
            let meter = LatenessMeter()
            var costs: [Double] = []
            meter.start()
            stage.session.beginScrub()
            for _ in 0..<3_000 {
                let target = random(in: range)
                let start = ProcessInfo.processInfo.systemUptime
                stage.session.scrub(to: target)
                costs.append((ProcessInfo.processInfo.systemUptime - start) * 1_000_000)
                try? await Task.sleep(for: .milliseconds(8))
            }
            let late = meter.stop()
            stage.session.endScrub()
            stage.session.pause()
            stage.close()
            runs.append(["cells": cells, "calls": costs.count, "callUs": ProbeFiles.json(ProbeStatistics.summary(costs)), "mainLateMs": ProbeFiles.json(ProbeStatistics.summary(late))])
        }
        return ["runs": runs, "baselineMainLateMs": ProbeFiles.json(ProbeStatistics.summary(baseline))]
    }

    // MARK: B2: the first picture of a new GOP

    /// 200 jumps into a GOP that is not the previous one (each a `scrub(to:)`), 0.8 s apart so the exact still of the last jump is over. The time is
    /// from the call to the first keyframe picture handed to the renderer (`enqueue`) and, when the layer can be read back, to the first change of the
    /// displayed counter (`display`). Then a 10 s drag at 120 Hz across the range: distinct pictures per second.
    static func keyframe(model: AppModel, id: UUID, range: ClosedRange<Date>) async -> [String: Any] {
        let stage = Stage(model: model, ids: [id], columns: 1, tile: CGSize(width: 960, height: 540))
        defer { stage.close() }
        await stage.chooseReadback(at: range.lowerBound.addingTimeInterval(range.upperBound.timeIntervalSince(range.lowerBound) / 2))
        guard let sink = stage.sinks[id] else { return ["error": "no cell"] }
        let gop = model.engine.archive.extent(camera: id)?.typicalGOP ?? 2
        var enqueue: [Double] = [], display: [Double] = []
        var failures = 0
        var previous = range.lowerBound
        for _ in 0..<200 {
            var target = random(in: range)
            var guardCount = 0
            while abs(target.timeIntervalSince(previous)) < 3 * gop, guardCount < 20 {
                target = random(in: range)
                guardCount += 1
            }
            previous = target
            try? await Task.sleep(for: .milliseconds(800))
            let mark = sink.shownCount
            let before = stage.counter(id)
            let start = ProcessInfo.processInfo.systemUptime
            stage.session.scrub(to: target)
            var handed: TimeInterval?
            var seen: TimeInterval?
            _ = await Stage.until(timeout: 2, poll: 0.001) {
                if handed == nil, sink.shown(from: mark).contains(where: \.isKeyframe) { handed = ProcessInfo.processInfo.systemUptime }
                if stage.readback != .none, seen == nil, let now = stage.counter(id), now != before { seen = ProcessInfo.processInfo.systemUptime }
                return handed != nil && (stage.readback == .none || seen != nil)
            }
            if let handed { enqueue.append((handed - start) * 1_000) } else { failures += 1 }
            if let seen { display.append((seen - start) * 1_000) }
        }
        // The steady drag: a new GOP at nearly every event.
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        let beginShown = sink.shownCount
        var pictures: [Int] = []
        let begin = ProcessInfo.processInfo.systemUptime
        let meter = LatenessMeter()
        meter.start()
        var position = 0.0, direction = 1.0
        while ProcessInfo.processInfo.systemUptime - begin < 10 {
            position += direction * 4 * gop
            if position > span { position = span; direction = -1 } else if position < 0 { position = 0; direction = 1 }
            stage.session.scrub(to: range.lowerBound.addingTimeInterval(position))
            if stage.readback != .none, let value = stage.counter(id) { pictures.append(value) }
            try? await Task.sleep(for: .milliseconds(8))
        }
        let late = meter.stop()
        let seconds = ProcessInfo.processInfo.systemUptime - begin
        let handedOver = sink.shown(from: beginShown).filter(\.isKeyframe).map { Int($0.wall.timeIntervalSince1970 * 1_000) }
        let rate = stage.readback == .none ? ProbeStatistics.distinctPictureRate(handedOver, seconds: seconds) : ProbeStatistics.distinctPictureRate(pictures, seconds: seconds)
        stage.session.endScrub()
        stage.session.pause()
        return ["readback": stage.readback.rawValue, "measuredAt": stage.readback == .none ? "enqueue" : "display", "gopSeconds": gop, "samples": enqueue.count, "failures": failures,
                "enqueueMs": ProbeFiles.json(ProbeStatistics.summary(enqueue)), "displayMs": ProbeFiles.json(ProbeStatistics.summary(display)),
                "steady": ["seconds": seconds, "picturesPerSecond": rate, "mainLateMs": ProbeFiles.json(ProbeStatistics.summary(late))]]
    }

    // MARK: B3: the exact frame

    /// Learns the offset K between recorded time and the demo counter (frame N is shown at wall time K + N / 30; a settled still shows the last frame at or
    /// before its target, so each target gives K plus up to one frame, and the smallest of 8 is the best estimate), then 200 stills: the time from the
    /// last `scrub(to:)` to the displayed counter being the expected frame (within one), minus the 80 ms the session waits before it asks for the exact frame.
    static func exact(model: AppModel, id: UUID, range: ClosedRange<Date>) async -> [String: Any] {
        let stage = Stage(model: model, ids: [id], columns: 1, tile: CGSize(width: 960, height: 540))
        defer { stage.close() }
        await stage.chooseReadback(at: range.lowerBound.addingTimeInterval(range.upperBound.timeIntervalSince(range.lowerBound) / 2))
        guard let sink = stage.sinks[id] else { return ["error": "no cell"] }
        let fps = 30.0
        var offsets: [Double] = []
        if stage.readback != .none {
            for _ in 0..<8 {
                let target = random(in: range)
                stage.session.scrub(to: target)
                try? await Task.sleep(for: .milliseconds(1_200))
                if let value = stage.counter(id) { offsets.append(target.timeIntervalSince1970 - Double(value) / fps) }
            }
        }
        guard stage.readback != .none, let k = offsets.min() else {
            // Only the hand-over can be timed: the last displayable picture after the final move.
            var settle: [Double] = []
            for _ in 0..<100 {
                try? await Task.sleep(for: .milliseconds(800))
                let mark = sink.shownCount
                let start = ProcessInfo.processInfo.systemUptime
                stage.session.scrub(to: random(in: range))
                try? await Task.sleep(for: .milliseconds(600))
                if let last = sink.shown(from: mark).last { settle.append((last.uptime - start) * 1_000 - 80) }
            }
            return ["readback": "none", "measuredAt": "enqueue", "afterTriggerMs": ProbeFiles.json(ProbeStatistics.summary(settle)), "frameErrors": NSNull()]
        }
        var after: [Double] = []
        var errors = 0
        var worst = 0
        var detail: [[String: Any]] = []
        for round in 0..<200 {
            try? await Task.sleep(for: .milliseconds(600))
            let target = random(in: range)
            let expected = Int(((target.timeIntervalSince1970 - k) * fps).rounded(.down))
            let mark = sink.shownCount
            let start = ProcessInfo.processInfo.systemUptime
            stage.session.scrub(to: target)
            var hit: TimeInterval?
            _ = await Stage.until(timeout: 3, poll: 0.001) {
                if let value = stage.counter(id), abs(value - expected) <= 1 {
                    hit = ProcessInfo.processInfo.systemUptime
                    return true
                }
                return false
            }
            if let hit { after.append((hit - start) * 1_000 - 80) } else {
                errors += 1
                if let value = stage.counter(id) { worst = max(worst, abs(value - expected)) }
            }
            if round < 30 {   // what the player handed over and what the layer showed, for the first stills (classifying a miss)
                let handed = sink.shown(from: mark)
                let last = handed.last
                var entry: [String: Any] = [:]
                entry["targetSecondsIntoSource"] = target.timeIntervalSince1970 - k
                entry["expected"] = expected
                entry["displayed"] = stage.counter(id) ?? NSNull()
                entry["hit"] = hit != nil
                entry["handedOver"] = handed.count
                entry["lastHandedWallMinusTargetMs"] = last.map { $0.wall.timeIntervalSince(target) * 1_000 } ?? NSNull()
                entry["lastHandedFrame"] = last.map { Int(($0.wall.timeIntervalSince1970 - k) * fps + 0.5) } ?? NSNull()
                entry["lastHandedWasKey"] = last?.isKeyframe ?? NSNull()
                detail.append(entry)
            }
        }
        return ["readback": stage.readback.rawValue, "measuredAt": "display", "offsetSeconds": k, "offsetSpread": (offsets.max() ?? 0) - (offsets.min() ?? 0),
                "offsets": offsets.map { $0 - k }, "detail": detail,
                "afterTriggerMs": ProbeFiles.json(ProbeStatistics.summary(after)), "frameErrors": errors, "worstErrorFrames": worst]
    }

    // MARK: B4: the grid

    /// Nine cells, a 10 s drag at 60 Hz across the range, then a release: pictures per tile per second, the longest wait of any tile, how long the
    /// last picture of each tile took after the last move (the exact stills), and the main thread's lateness.
    static func grid(model: AppModel, ids: [UUID], range: ClosedRange<Date>) async -> [String: Any] {
        let stage = Stage(model: model, ids: ids, columns: 3, tile: CGSize(width: 480, height: 270))
        defer { stage.close() }
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        let marks = ids.map { stage.sinks[$0]?.shownCount ?? 0 }
        let meter = LatenessMeter()
        meter.start()
        stage.session.beginScrub()
        let begin = ProcessInfo.processInfo.systemUptime
        var position = 0.0, direction = 1.0
        while ProcessInfo.processInfo.systemUptime - begin < 10 {
            position += direction * span / 300
            if position > span { position = span; direction = -1 } else if position < 0 { position = 0; direction = 1 }
            stage.session.scrub(to: range.lowerBound.addingTimeInterval(position))
            try? await Task.sleep(for: .milliseconds(16))
        }
        let last = ProcessInfo.processInfo.systemUptime
        let late = meter.stop()
        try? await Task.sleep(for: .milliseconds(1_500))
        var perTile: [Double] = [], worstGap = 0.0
        var settle: [Double] = []
        for (index, id) in ids.enumerated() {
            guard let sink = stage.sinks[id] else { continue }
            let shown = sink.shown(from: marks[index])
            let during = shown.filter { $0.uptime <= last }
            perTile.append(Double(during.count) / (last - begin))
            worstGap = max(worstGap, ProbeStatistics.longestGap(during.map { $0.uptime - begin }, from: 0, to: last - begin))
            if let final = shown.filter({ $0.uptime > last }).last { settle.append((final.uptime - last) * 1_000) }
        }
        stage.session.endScrub()
        stage.session.pause()
        return ["measuredAt": "enqueue", "dragSeconds": last - begin, "picturesPerTilePerSecond": perTile, "minPerTile": perTile.min() ?? 0, "worstGapMs": worstGap * 1_000,
                "lastPictureAfterReleaseMs": ProbeFiles.json(ProbeStatistics.summary(settle)), "mainLateMs": ProbeFiles.json(ProbeStatistics.summary(late))]
    }

    // MARK: B5: play

    /// Scrub to a point, release (`endScrub`: the clock plays from there), then 30 s: the time to the first picture, each picture's lateness against the
    /// clock (the instant it was handed over minus the instant the clock says it is due), and the spread of the cells' newest frames (in frames of 1/30 s).
    static func play(model: AppModel, ids: [UUID], range: ClosedRange<Date>) async -> [String: Any] {
        let stage = Stage(model: model, ids: ids, columns: 3, tile: CGSize(width: 480, height: 270))
        defer { stage.close() }
        let start = range.lowerBound.addingTimeInterval(5)
        stage.session.beginScrub()
        stage.session.scrub(to: start)
        try? await Task.sleep(for: .milliseconds(1_500))
        let marks = ids.map { stage.sinks[$0]?.shownCount ?? 0 }
        let release = ProcessInfo.processInfo.systemUptime
        stage.session.endScrub()
        var first: TimeInterval?
        _ = await Stage.until(timeout: 3, poll: 0.001) {
            first = ids.indices.compactMap { stage.sinks[ids[$0]]?.shown(from: marks[$0]).first?.uptime }.min()
            return first != nil
        }
        let clock = stage.session.clock.state
        var skews: [Double] = []
        let begin = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - begin < 30 {
            try? await Task.sleep(for: .milliseconds(100))
            let newest = ids.compactMap { stage.sinks[$0]?.shown(from: 0).last?.wall.timeIntervalSince1970 }
            if newest.count == ids.count, let low = newest.min(), let high = newest.max() { skews.append((high - low) * 30) }
        }
        var lateness: [Double] = []
        for (index, id) in ids.enumerated() {
            for shown in stage.sinks[id]?.shown(from: marks[index]) ?? [] where shown.uptime >= (first ?? release) {
                let due = clock.since + shown.wall.timeIntervalSince(clock.wall)
                lateness.append((shown.uptime - due) * 1_000)
            }
        }
        stage.session.pause()
        return ["measuredAt": "enqueue", "startMs": first.map { ($0 - release) * 1_000 } ?? NSNull(), "latenessMs": ProbeFiles.json(ProbeStatistics.summary(lateness)),
                "skewFramesP95": ProbeFiles.json(ProbeStatistics.summary(skews)), "skewFramesMax": skews.max() ?? 0, "clockMode": "\(clock.mode)"]
    }

    // MARK: the drive pulled while a viewer plays (Mac spec 13, "Drive unplugged": the tile keeps its picture, the clock pauses, playback recovers)

    /// One cell plays recorded footage from near the start of this run while `Tools/nvr-soak.sh yank` force-unmounts the drive's volume and attaches it again
    /// later. Every 250 ms this writes where the playhead stood, what the cell said and whether a picture was on show, for `CB_SOAK_DRIVEHOLD_SECONDS`
    /// (default 240). The yank script's report joins the samples with the times of the pull and of the return that the script logged.
    static func driveHold(model: AppModel, id: UUID, range: ClosedRange<Date>) async -> [String: Any] {
        let stage = Stage(model: model, ids: [id], columns: 1, tile: CGSize(width: 480, height: 270))
        defer { stage.close() }
        // The screens' own panel model: about twice a second it tells the session what the engine says about the recordings folder, as in the app.
        let panel = NVRPanelModel(archive: model.archive, session: stage.session, defaults: model.preferences)
        panel.setCameras([id])
        stage.session.beginScrub()
        stage.session.scrub(to: range.lowerBound.addingTimeInterval(5))
        try? await Task.sleep(for: .milliseconds(1_500))
        stage.session.endScrub()
        let seconds = Double(ProcessInfo.processInfo.environment["CB_SOAK_DRIVEHOLD_SECONDS"] ?? "") ?? 240
        var samples: [[String: Any]] = []
        let begin = ProcessInfo.processInfo.systemUptime
        var tick = 0
        while ProcessInfo.processInfo.systemUptime - begin < seconds {
            try? await Task.sleep(for: .milliseconds(250))
            tick += 1
            if tick % 2 == 0 { panel.refresh(storagePause: model.nvrStorage?.pause) }
            let cell = stage.session.cell(for: id)
            samples.append(["t": Date().timeIntervalSince1970, "position": stage.session.position.timeIntervalSince1970, "coverage": cell.map { "\($0.coverage)" } ?? "none",
                            "shows": cell?.showsPicture ?? false, "shown": stage.sinks[id]?.shownCount ?? 0])
        }
        stage.session.pause()
        return ["measuredAt": "sink", "seconds": seconds, "samples": samples]
    }
}
#endif
