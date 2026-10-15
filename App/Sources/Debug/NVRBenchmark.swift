#if DEBUG
import AppKit
import AVFoundation
import BridgeEngine
import BridgeSupport
import CoreImage
import CoreVideo
import Foundation
import MediaCore
import PlatformApple

/// Debug builds only: the measurements the NVR's display path and storage assumptions rest on (Mac spec 8.1, 8.4, 10.3, 14), run inside the app because
/// they need real layers and decoders (the logic-test bundle has no window server). `-nvrBenchmark b1,b2,b3,b5,b6 [-nvrBenchmarkSize 2688x1520]
/// [-nvrBenchmarkFps 20] -nvrBenchmarkQuit YES` writes `$TMPDIR/CameraBridgeNVRBenchmark/report.txt`; `b4` also needs
/// `-nvrBenchmarkFolder <a COPY of a folder of recordings>`: it starts a throwaway engine on the folder, and the archive store repairs what it finds there
/// (torn tails, missing sidecars), so never point it at the folder a running Camera Bridge records into.
///
/// - B1: do decode-only lead-ins decode without ever showing (no flash), how fast, and does the displayable frame after them appear (spec spike S1/S6).
/// - B2: how long after the last displayable frame a flush may come without losing the picture (sets `CellPlayback.previewDwell`, spike S2).
/// - B3: nine concurrent main-stream decoders: throughput and memory (sets `NVRSession.maximumCells`, spike S3).
/// - B4: reads from a copy of a real recordings folder: listing, keyframe reads, activity (spike S4; needs the archive store, task T02).
/// - B5: 1x pacing against the clock: lateness and the spread of intervals (spike S5).
/// - B6: the whole recorded path over the sample recordings (`-previewEngine YES -demoScenario nvr`): archive bytes, FMP4 readers, `CellPlayback`,
///   a real renderer; pictures arrive on a scrub and change while it plays.
@MainActor
enum NVRBenchmark {
    static let argumentKey = "nvrBenchmark"
    private static let log = Log(category: "NVRBenchmark")

    static var requested: String? { UserDefaults.standard.string(forKey: argumentKey) }

    static func run(_ names: String, model: AppModel) async {
        var report = "NVR benchmark \(Date()) on \(ProcessInfo.processInfo.operatingSystemVersionString), \(ProcessInfo.processInfo.processorCount) cores\n"
        report += "display: \(NSScreen.main?.maximumFramesPerSecond ?? 0) Hz; picture \(size.width)x\(size.height) at \(fps) fps, a keyframe every \(gop) s\n\n"
        do {
            let clip = try await Clip.make(width: size.width, height: size.height, fps: fps, gop: gop, seconds: 10)
            report += "clip: \(clip.frames.count) frames, \(clip.frames.filter(\.isKeyframe).count) keyframes, \(clip.frames.map { $0.lengthPrefixedData.count }.reduce(0, +) / 1_000) kB\n\n"
            for name in names.split(separator: ",").map({ String($0).lowercased() }) {
                switch name {
                case "b1": report += await b1(clip)
                case "b2": report += await b2(clip)
                case "b3": report += await b3(clip)
                case "b4": report += await b4(model)
                case "b5": report += await b5(clip)
                case "b6": report += await b6(model)
                default: report += "unknown benchmark \(name)\n"
                }
                report += "\n"
            }
        } catch {
            report += "failed: \(error)\n"
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "CameraBridgeNVRBenchmark", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? report.write(to: directory.appending(path: "report.txt"), atomically: true, encoding: .utf8)
        log.notice("Benchmark report written to \(directory.path)")
        print(report)
        if UserDefaults.standard.bool(forKey: "nvrBenchmarkQuit") { NSApp.terminate(nil) }
    }

    // MARK: Settings

    private static var size: (width: Int, height: Int) {
        let parts = (UserDefaults.standard.string(forKey: "nvrBenchmarkSize") ?? "1920x1080").split(separator: "x").compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : (1_920, 1_080)
    }

    private static var fps: Int { UserDefaults.standard.integer(forKey: "nvrBenchmarkFps").nonZero ?? 20 }
    private static var gop: Int { UserDefaults.standard.integer(forKey: "nvrBenchmarkGop").nonZero ?? 2 }

    // MARK: B1

    private static func b1(_ clip: Clip) async -> String {
        var out = "B1 decode-only lead-ins\n"
        let bench = Bench()
        bench.show(clip.frames[0], decodeOnly: false)
        await bench.settle(0.4)
        let key = bench.picture()
        out += "  displayedPicture after the keyframe: \(key == nil ? "NIL (the layer cannot be read at rate 1: measure by screen capture)" : "ok")\n"
        guard let keyHash = key else { return out }
        for lead in [12, 25, 60, min(150, clip.frames.count - 2)] where lead > 0 && lead < clip.frames.count - 1 {
            bench.show(clip.frames[0], decodeOnly: false)   // a known picture first
            await bench.settle(0.3)
            let before = bench.picture() ?? keyHash
            let start = now()
            for index in 1..<lead { bench.show(clip.frames[index], decodeOnly: true) }
            var seen = Set<UInt64>()
            var shownAt: Double?
            bench.show(clip.frames[lead], decodeOnly: false)
            for _ in 0..<2_000 {
                if let picture = bench.picture() {
                    seen.insert(picture)
                    if picture != before, shownAt == nil { shownAt = now() - start }
                }
                if shownAt != nil, bench.renderer.queued == 0 { break }
                try? await Task.sleep(for: .milliseconds(1))
            }
            let intermediate = seen.subtracting([before]).count
            out += "  lead-in \(lead): the displayable frame appeared after \(shownAt.map { ms($0) } ?? "NEVER"); distinct pictures seen: \(seen.count) (\(intermediate <= 1 ? "no flash" : "FLASH: \(intermediate - 1) intermediate"))"
            out += shownAt.map { "; about \(Int(Double(lead) / max(0.001, $0))) frames/s" } ?? ""
            out += "\n"
        }
        bench.close()
        return out
    }

    // MARK: B2

    private static func b2(_ clip: Clip) async -> String {
        var out = "B2 flush after a displayable frame (the dwell)\n"
        let second = clip.frames.firstIndex(where: { $0.isKeyframe && $0.pts != clip.frames[0].pts }) ?? clip.frames.count - 1
        let bench = Bench()
        bench.show(clip.frames[second], decodeOnly: false)
        await bench.settle(0.4)
        guard let other = bench.picture() else { bench.close(); return out + "  displayedPicture is nil: cannot measure\n" }
        for dwell in [0, 5, 10, 15, 30, 60] {
            var latencies: [Double] = []
            var lost = 0
            var beforeShown = 0
            for _ in 0..<30 {
                bench.show(clip.frames[0], decodeOnly: false)   // picture A
                try? await Task.sleep(for: .milliseconds(dwell))
                let a = bench.picture()
                if let a, a != other { beforeShown += 1 }   // A was on screen when the flush came
                bench.renderer.reset()
                let start = now()
                bench.show(clip.frames[second], decodeOnly: false)   // picture B (after the flush)
                var landed = false
                for _ in 0..<400 {
                    if let picture = bench.picture(), picture == other { landed = true; break }
                    try? await Task.sleep(for: .milliseconds(1))
                }
                if landed { latencies.append((now() - start) * 1_000) } else { lost += 1 }
                await bench.settle(0.05)
            }
            latencies.sort()
            out += "  dwell \(dwell) ms: the picture before the flush was on screen \(beforeShown) of 30 times; the next keyframe landed p50 \(Int(latencies.percentile(0.5))) ms, p95 \(Int(latencies.percentile(0.95))) ms, lost \(lost)\n"
        }
        out += "  previewDwell is the smallest dwell at which the picture before the flush is on screen 30 of 30 times (now \(Int(CellPlayback.previewDwell * 1_000)) ms)\n"
        bench.close()
        return out
    }

    // MARK: B3

    private static func b3(_ clip: Clip) async -> String {
        var out = "B3 concurrent decoders\n"
        let count = min(120, clip.frames.count - 2)
        for sessions in [1, 2, 4, 6, 9] {
            let before = footprint()
            let benches = (0..<sessions).map { _ in Bench() }
            for bench in benches { bench.show(clip.frames[0], decodeOnly: false) }
            await Bench.settleAll(benches, 0.5)
            let shownKey = benches.compactMap { $0.picture() }
            let resident = footprint()
            // Every session primes the decoder with `count` frames and shows the next one; the time is until the last of them has shown it.
            let heldBack = shownKey
            let start = now()
            for bench in benches {
                for index in 1..<count { bench.show(clip.frames[index], decodeOnly: true) }
                bench.show(clip.frames[count], decodeOnly: false)
            }
            var finished = Set<Int>()
            for _ in 0..<5_000 where finished.count < sessions {
                for (index, bench) in benches.enumerated() where !finished.contains(index) {
                    if let picture = bench.picture(), index < heldBack.count, picture != heldBack[index] { finished.insert(index) }
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
            let elapsed = now() - start
            out += "  \(sessions) session(s): \(count) frames each shown by \(finished.count) of \(sessions) after \(Int(elapsed * 1_000)) ms = \(Int(Double(count * sessions) / elapsed)) frames/s in all (\(Int(Double(count) / elapsed)) per session, a camera sends \(fps)); the app's own footprint \(String(format: "%+d", (Int64(resident) - Int64(before)) / 1_048_576)) MB (decoder memory is held outside the app: not counted)\n"
            for bench in benches { bench.close() }
            try? await Task.sleep(for: .milliseconds(400))
        }
        out += "  NVRSession.maximumCells is \(NVRSession.maximumCells); lower it where nine sessions cannot keep up with \(fps) fps each (per session figure above)\n"
        return out
    }

    // MARK: B4

    private static func b4(_ model: AppModel) async -> String {
        var out = "B4 storage reads\n"
        guard let path = UserDefaults.standard.string(forKey: "nvrBenchmarkFolder") else { return out + "  give -nvrBenchmarkFolder <a folder of recordings>\n" }
        let directory = FileManager.default.temporaryDirectory.appending(path: "CameraBridgeNVRBenchmarkEngine-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = BridgeEngine(environment: .testing(directory: directory))
        do {
            try await engine.updateSettings { $0.nvrFolder = path }
        } catch {
            return out + "  the folder was refused: \(error)\n"
        }
        let started = now()
        await engine.start()
        for _ in 0..<600 where !engine.archive.isReady { try? await Task.sleep(for: .milliseconds(100)) }
        out += "  catalog ready after \(ms(now() - started))\n"
        let archive = engine.archive
        // The cameras of the folder are the ones its `camera.json` files name (the throwaway engine has no cameras of its own).
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let cameras = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).compactMap { directory -> UUID? in
            guard let data = try? Data(contentsOf: directory.appending(path: "camera.json")),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = object["id"] as? String else { return nil }
            return UUID(uuidString: id)
        }
        out += "  \(cameras.count) camera folder(s) with a camera.json; extents: \(cameras.compactMap { archive.extent(camera: $0) }.count)\n"
        var keyframeReads: [Double] = []
        var lookups: [Double] = []
        for camera in cameras {
            guard let extent = archive.extent(camera: camera) else { continue }
            for _ in 0..<100 {
                let time = extent.oldest.addingTimeInterval(Double.random(in: 0..<max(1, extent.newest.timeIntervalSince(extent.oldest))))
                let t0 = now()
                guard let fragment = await archive.fragment(camera: camera, containing: time) else { continue }
                lookups.append((now() - t0) * 1_000)
                let t1 = now()
                if fragment.hasKeyframe, (try? await archive.read(fragment, .keyframe)) != nil { keyframeReads.append((now() - t1) * 1_000) }
            }
            let t2 = now()
            _ = await archive.activity(camera: camera, range: extent.newest.addingTimeInterval(-86_400)..<extent.newest, binCount: 400)
            out += "  activity over 24 h, 400 bins: \(ms(now() - t2))\n"
        }
        lookups.sort()
        keyframeReads.sort()
        out += "  fragment lookup p50 \(lookups.percentile(0.5)) ms, p95 \(lookups.percentile(0.95)) ms\n"
        out += "  keyframe read p50 \(keyframeReads.percentile(0.5)) ms, p95 \(keyframeReads.percentile(0.95)) ms (\(keyframeReads.count) reads)\n"
        await engine.stop()
        return out
    }

    // MARK: B5

    private static func b5(_ clip: Clip) async -> String {
        var out = "B5 1x pacing\n"
        let bench = Bench()
        bench.show(clip.frames[0], decodeOnly: false)
        await bench.settle(0.4)
        let start = ProcessInfo.processInfo.systemUptime + 0.2
        let origin = Double(clip.frames[0].pts.value) / Double(clip.frames[0].pts.timescale)
        var lateness: [Double] = []
        var shownAt: [Double] = []
        for frame in clip.frames.dropFirst() {
            let due = start + Double(frame.pts.value) / Double(frame.pts.timescale) - origin
            let wait = due - ProcessInfo.processInfo.systemUptime
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            let now = ProcessInfo.processInfo.systemUptime
            bench.show(frame, decodeOnly: false)
            lateness.append((now - due) * 1_000)
            shownAt.append(now)
        }
        await bench.settle(0.3)
        lateness.sort()
        let intervals = zip(shownAt, shownAt.dropFirst()).map { ($1 - $0) * 1_000 }
        let mean = intervals.reduce(0, +) / Double(max(1, intervals.count))
        let deviation = (intervals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(1, intervals.count))).squareRoot()
        out += "  \(clip.frames.count) frames: lateness p50 \(lateness.percentile(0.5)) ms, p95 \(lateness.percentile(0.95)) ms, max \(Int((lateness.last ?? 0).rounded())) ms\n"
        out += "  interval between frames: mean \(Int(mean)) ms, deviation \(String(format: "%.1f", deviation)) ms (display \(NSScreen.main?.maximumFramesPerSecond ?? 0) Hz)\n"
        out += "  judder is visible when the deviation is above about a third of a refresh interval; then play uses timed samples (Mac spec 8.1, fallback 1)\n"
        bench.close()
        return out
    }

    // MARK: B6

    private static func b6(_ model: AppModel) async -> String {
        var out = "B6 recorded playback end to end (the sample recordings)\n"
        guard let camera = model.engine.cameras.first, let extent = model.archive.extent(camera: camera.id) else {
            return out + "  the archive has no recordings: start with -previewEngine YES -demoScenario nvr\n"
        }
        let bench = Bench()
        let clock = PlaybackClock()
        let cell = CellPlayback(sink: bench.renderer, archive: model.archive, camera: camera.id, clock: clock)
        let base = extent.newest.addingTimeInterval(-3_600)
        var seen = Set<UInt64>()
        for (index, offset) in [1.0, 7.5, 40.0].enumerated() {
            let started = now()
            cell.request(PlaybackDesire(target: base.addingTimeInterval(offset), precision: .exact, playing: false, epoch: index + 1))
            var shownAfter: Double?
            for _ in 0..<5_000 where shownAfter == nil {
                if cell.isIdle, let picture = bench.picture() {
                    shownAfter = now() - started
                    out += "  scrub to +\(offset) s: a picture after \(ms(shownAfter ?? 0)); \(seen.contains(picture) ? "the same as an earlier one" : "new")\n"
                    seen.insert(picture)
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
            if shownAfter == nil { out += "  scrub to +\(offset) s: NO PICTURE within 10 s (coverage \(cell.coverage))\n" }
        }
        // Play for two seconds: a 15 fps recording changes its picture about 30 times.
        let from = base.addingTimeInterval(60)
        clock.play(from: from)
        cell.request(PlaybackDesire(target: from, precision: .exact, playing: true, epoch: 10))
        var pictures = Set<UInt64>()
        let end = now() + 2.5
        while now() < end {
            if let picture = bench.picture() { pictures.insert(picture) }
            try? await Task.sleep(for: .milliseconds(20))
        }
        out += "  playing 2.5 s at 1x: \(pictures.count) different pictures seen (a 15 fps recording gives up to about 37; coverage \(cell.coverage))\n"
        await cell.stop()
        bench.close()
        return out
    }

    // MARK: Helpers

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }
    private static func ms(_ seconds: Double) -> String { "\(Int(seconds * 1_000)) ms" }

    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    /// A renderer in its own small window, and a way to see its picture (a hash of the pixels `displayedPicture()` returns).
    private final class Bench {
        let renderer = LiveVideoRenderer()
        private let window: NSWindow

        init() {
            window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false   // ARC owns it: a window released by `close()` as well is released twice
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
            host.wantsLayer = true
            renderer.layer.frame = host.bounds
            host.layer?.addSublayer(renderer.layer)
            window.contentView = host
            window.orderFrontRegardless()
        }

        func show(_ frame: EncodedVideoFrame, decodeOnly: Bool) { renderer.show(frame, decodeOnly: decodeOnly) }
        func close() { window.close() }

        func settle(_ seconds: Double) async {
            for _ in 0..<2_000 where renderer.queued > 0 { try? await Task.sleep(for: .milliseconds(2)) }
            try? await Task.sleep(for: .seconds(seconds))
        }

        static func settleAll(_ benches: [Bench], _ seconds: Double) async {
            for bench in benches { await bench.settle(0) }
            try? await Task.sleep(for: .seconds(seconds))
        }

        private static let context = CIContext()

        /// A hash of the displayed picture scaled down to 64x36 (any pixel format: the layer's buffer may be a compressed one the CPU cannot read
        /// directly); nil when the layer gives none.
        func picture() -> UInt64? {
            guard let buffer = renderer.displayedPicture() else { return nil }
            let width = CGFloat(CVPixelBufferGetWidth(buffer)), height = CGFloat(CVPixelBufferGetHeight(buffer))
            guard width > 0, height > 0 else { return nil }
            let scaled = CIImage(cvPixelBuffer: buffer).transformed(by: CGAffineTransform(scaleX: 64 / width, y: 36 / height))
            var bitmap = [UInt8](repeating: 0, count: 64 * 36 * 4)
            Self.context.render(scaled, toBitmap: &bitmap, rowBytes: 64 * 4, bounds: CGRect(x: 0, y: 0, width: 64, height: 36), format: .RGBA8,
                                colorSpace: CGColorSpaceCreateDeviceRGB())
            var hash: UInt64 = 1_469_598_103_934_665_603
            for byte in bitmap { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
            return hash
        }
    }

    /// Encoded frames of a moving test pattern, made by the codecs' synthetic source (real-time: about `seconds` of waiting).
    private struct Clip {
        var frames: [EncodedVideoFrame]

        static func make(width: Int, height: Int, fps: Int, gop: Int, seconds: Int) async throws -> Clip {
            let source = AppleMediaCodecs().makeSyntheticSource(displayName: "Benchmark", width: width, height: height, fps: fps, keyframeInterval: .seconds(gop),
                                                                audio: nil, audioSampleRate: 0)
            var frames: [EncodedVideoFrame] = []
            let deadline = ProcessInfo.processInfo.systemUptime + Double(seconds + 5)
            for try await sample in try await source.samples() {
                if case .video(let frame) = sample, frame.isKeyframe || !frames.isEmpty { frames.append(frame) }
                if frames.count >= fps * seconds || ProcessInfo.processInfo.systemUptime > deadline { break }
            }
            await source.stop()
            guard frames.count > fps else { throw MediaCodecError.unsupported("The synthetic source gave \(frames.count) frames.") }
            return Clip(frames: frames)
        }
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

private extension Array where Element == Double {
    func percentile(_ fraction: Double) -> Double {
        guard !isEmpty else { return 0 }
        return self[Swift.min(count - 1, Int((fraction * Double(count)).rounded(.up)) - 1)].rounded()
    }
}
#endif
