#if DEBUG
import BridgeEngine
import CameraAdapters
import CoreVideo
import Foundation
import MediaCore
import PlatformApple
import Testing

/// `-isolatedEngine`: the measurement build’s throwaway engine. The point of every test here is that the person’s installed app, its data
/// and its ports can never be reached by a mistyped argument.
@Suite struct IsolatedEngineTests {
    private let measurementBundle = "com.coreysilvia.CameraBridge.nvrtest"

    /// A fake home with the app’s two data folders in it, and a throwaway directory beside them.
    private func makeHome() throws -> (home: URL, support: URL, container: URL, scratch: URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "T18-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        let support = home.appending(path: "Library/Application Support/CameraBridge", directoryHint: .isDirectory)
        let container = home.appending(path: "Library/Containers/com.coreysilvia.CameraBridge", directoryHint: .isDirectory)
        let scratch = home.appending(path: "scratch/run-1", directoryHint: .isDirectory)
        for url in [support, container] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return (home, support, container, scratch)
    }

    private func options(_ directory: URL, mutate: (inout IsolatedEngineOptions) -> Void = { _ in }) -> IsolatedEngineOptions {
        var options = IsolatedEngineOptions(directory: directory)
        options.demoCameras = 8
        options.nvrFolder = directory.deletingLastPathComponent().appending(path: "recordings", directoryHint: .isDirectory)
        mutate(&options)
        return options
    }

    @Test func absentArgumentsMeanTheLiveEngine() {
        let scratch = ScratchDefaults()
        #expect(IsolatedEngineOptions(defaults: scratch.defaults) == nil)
        #expect(IsolatedLaunchDecision.decide(defaults: scratch.defaults, bundleIdentifier: "com.coreysilvia.CameraBridge") == .live)
        scratch.defaults.set("", forKey: "isolatedEngine")
        #expect(IsolatedEngineOptions(defaults: scratch.defaults) == nil, "an empty path is no request")
    }

    @Test func readsTheLaunchArguments() throws {
        let scratch = ScratchDefaults()
        scratch.defaults.set("/tmp/t18/data", forKey: "isolatedEngine")
        scratch.defaults.set(8, forKey: "isolatedDemoCameras")
        scratch.defaults.set("/tmp/t18/mnt/Recordings", forKey: "isolatedNVRFolder")
        scratch.defaults.set(38_200, forKey: "isolatedBasePort")
        scratch.defaults.set(2, forKey: "isolatedKeepDays")
        scratch.defaults.set(25, forKey: "isolatedMaxGB")
        scratch.defaults.set(180, forKey: "isolatedRecordAfterSeconds")
        scratch.defaults.set(1.5, forKey: "isolatedQuitAfterMinutes")
        scratch.defaults.set(2, forKey: "isolatedHeartbeatSeconds")
        scratch.defaults.set(12, forKey: "isolatedDemoKeyframeSeconds")
        scratch.defaults.set("keyframe", forKey: "nvrProbe")
        let parsed = try #require(IsolatedEngineOptions(defaults: scratch.defaults))
        #expect(parsed.directory.path == "/tmp/t18/data" && parsed.demoCameras == 8 && parsed.nvrFolder?.path == "/tmp/t18/mnt/Recordings")
        #expect(parsed.basePort == 38_200 && parsed.keepDays == 2 && parsed.maxSizeGB == 25 && parsed.recordAfter == 180 && parsed.quitAfter == 90 && parsed.heartbeat == 2)
        #expect(parsed.probe == "keyframe" && parsed.demoKeyframeSeconds == 12)
        let bare = ScratchDefaults()
        bare.defaults.set("/tmp/t18/data", forKey: "isolatedEngine")
        let defaulted = try #require(IsolatedEngineOptions(defaults: bare.defaults))
        #expect(defaulted.demoCameras == 0 && defaulted.nvrFolder == nil && defaulted.basePort == 38_100 && defaulted.keepDays == 1 && defaulted.maxSizeGB == 10)
        #expect(defaulted.recordAfter == 0 && defaulted.quitAfter == nil && defaulted.probe == nil && defaulted.heartbeat == 10 && defaulted.demoKeyframeSeconds == nil)
    }

    @Test func onlyAMeasurementBuildMayRun() throws {
        let fake = try makeHome()
        let run = options(fake.scratch)
        for refused in [nil, "com.coreysilvia.CameraBridge", "com.coreysilvia.CameraBridgeTests", "com.example.nvrtest.app"] {
            #expect(run.validated(bundleIdentifier: refused, home: fake.home) == .failure(.notAMeasurementBuild), "\(refused ?? "nil")")
        }
        #expect(run.validated(bundleIdentifier: measurementBundle, home: fake.home) == .success(run))
    }

    @Test func theAppsOwnDataIsNeverUsed() throws {
        let fake = try makeHome()
        let link = fake.home.appending(path: "shortcut", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fake.support)
        for directory in [fake.support, fake.support.appending(path: "Diagnostics"), fake.container, fake.container.appending(path: "Data/x/y"),
                          link, link.appending(path: "child"), fake.support.appending(path: "a/../b")] {
            #expect(options(directory).validated(bundleIdentifier: measurementBundle, home: fake.home) == .failure(.ownerData)
                    || options(directory).validated(bundleIdentifier: measurementBundle, home: fake.home) == .failure(.directoryNotUsable),
                    "\(directory.path)")
        }
        // The recordings folder is held to the same rule, and a sibling that only shares the name’s start is fine.
        #expect(options(fake.scratch) { $0.nvrFolder = fake.container.appending(path: "Data/Recordings") }
            .validated(bundleIdentifier: measurementBundle, home: fake.home) == .failure(.ownerData))
        let sibling = fake.support.deletingLastPathComponent().appending(path: "CameraBridge2", directoryHint: .isDirectory)
        #expect(options(sibling).validated(bundleIdentifier: measurementBundle, home: fake.home) == .success(options(sibling)))
    }

    @Test func pathsMustBeFullAndPlain() throws {
        let fake = try makeHome()
        for path in ["relative/dir", "~/dir", "/tmp/../etc", "/tmp/with\nnewline"] {
            let run = IsolatedEngineOptions(directoryPath: path)
            #expect(run.validated(bundleIdentifier: measurementBundle, home: fake.home) == .failure(.directoryNotUsable), "\(path)")
        }
        #expect(options(fake.scratch) { $0.folderPath = "relative" }
            .validated(bundleIdentifier: measurementBundle, home: fake.home) == .failure(.folderNotUsable))
    }

    @Test func numbersStayInTheirRanges() throws {
        let fake = try makeHome()
        func check(_ expected: IsolatedEngineOptions.Refusal?, _ mutate: (inout IsolatedEngineOptions) -> Void, line: Int = #line) {
            let result = options(fake.scratch, mutate: mutate).validated(bundleIdentifier: measurementBundle, home: fake.home)
            if let expected { #expect(result == .failure(expected), "line \(line)") } else { #expect((try? result.get()) != nil, "line \(line)") }
        }
        check(.tooManyCameras) { $0.demoCameras = 10 }
        check(.tooManyCameras) { $0.demoCameras = -1 }
        check(nil) { $0.demoCameras = 9 }
        check(.portOutOfRange) { $0.basePort = 21_100 }
        check(.portOutOfRange) { $0.basePort = 51_826 }
        check(nil) { $0.basePort = 22_000 }
        check(.limitOutOfRange) { $0.keepDays = 0 }
        check(.limitOutOfRange) { $0.maxSizeGB = 5 }
        check(nil) { ($0.keepDays, $0.maxSizeGB) = (365, 100_000) }
        check(.timingOutOfRange) { $0.recordAfter = -1 }
        check(.timingOutOfRange) { $0.quitAfter = 10 }
        check(nil) { $0.quitAfter = 30 }
        check(.unknownProbe("bogus")) { $0.probe = "bogus" }
        check(nil) { $0.probe = "grid" }
        check(nil) { $0.probe = "keyframe,exact,play" }
        check(nil) { $0.probe = "all" }
        check(.unknownProbe("keyframe,,exact")) { $0.probe = "keyframe,,exact" }
        check(.unknownProbe("")) { $0.probe = "" }
        check(.timingOutOfRange) { $0.heartbeat = 0.1 }
        check(nil) { $0.heartbeat = 1 }
        check(.timingOutOfRange) { $0.demoKeyframeSeconds = 0.5 }
        check(.timingOutOfRange) { $0.demoKeyframeSeconds = 121 }
        check(nil) { $0.demoKeyframeSeconds = 12 }
        check(nil) { $0.probe = "drivehold" }
        #expect(ProbeScenario.allCases.map(\.rawValue) == ["scrubcost", "keyframe", "exact", "grid", "play", "drivehold"])
        #expect(ProbeScenario.parse("all") == ProbeScenario.budgets && !ProbeScenario.budgets.contains(.drivehold) && ProbeScenario.parse("play,keyframe") == [.play, .keyframe])
        #expect(ProbeScenario.parse("Play") == nil && ProbeScenario.parse("play,") == nil)
    }

    @Test func aRequestThatIsPresentButWrongIsRefusedNeverRunLive() throws {
        let fake = try makeHome()
        let scratch = ScratchDefaults()
        scratch.defaults.set(fake.support.path, forKey: "isolatedEngine")
        #expect(IsolatedLaunchDecision.decide(defaults: scratch.defaults, bundleIdentifier: measurementBundle, home: fake.home) == .refused(.ownerData))
        scratch.defaults.set(fake.scratch.path, forKey: "isolatedEngine")
        #expect(IsolatedLaunchDecision.decide(defaults: scratch.defaults, bundleIdentifier: "com.coreysilvia.CameraBridge", home: fake.home) == .refused(.notAMeasurementBuild))
        if case .isolated(let run) = IsolatedLaunchDecision.decide(defaults: scratch.defaults, bundleIdentifier: measurementBundle, home: fake.home) {
            #expect(run.directory.path == fake.scratch.path)
        } else {
            Issue.record("a valid request should run isolated")
        }
    }

    // MARK: The seed

    @Test func theSeedMovesPortsAndFolderAndNothingElse() {
        var run = IsolatedEngineOptions(directory: URL(fileURLWithPath: "/tmp/t18/data"))
        run.nvrFolder = URL(fileURLWithPath: "/tmp/t18/mnt/Recordings")
        run.basePort = 38_300
        run.keepDays = 3
        run.maxSizeGB = 40
        var base = BridgeSettings()
        base.webhookEnabled = true
        base.webhookPort = 21_090
        base.keepMacAwake = true
        let seeded = IsolatedEngineSeed.settings(run, applying: base)
        #expect(seeded.basePort == 38_300 && seeded.sensorsBridgePort == 0 && seeded.webhookPort == 0 && !seeded.webhookEnabled)
        #expect(seeded.nvrFolder == "/tmp/t18/mnt/Recordings" && seeded.nvrKeepDays == 3 && seeded.nvrMaxSizeGB == 40)
        #expect(seeded.keepMacAwake, "the seed leaves the other settings alone")
        #expect(seeded.webhookToken == base.webhookToken && seeded.logLevel == base.logLevel)
    }

    @Test func theSeedAddsOnlyTheMissingDemoCameras() {
        var run = IsolatedEngineOptions(directory: URL(fileURLWithPath: "/tmp/t18/data"))
        run.demoCameras = 3
        let first = IsolatedEngineSeed.missingCameras(run, existing: [])
        #expect(first.map(\.name) == ["Soak 1", "Soak 2", "Soak 3"])
        #expect(first.allSatisfy { $0.vendor == .demo && $0.kind == .camera && !$0.nvrEnabled && $0.isEnabled })
        let relaunch = IsolatedEngineSeed.missingCameras(run, existing: Array(first.prefix(2)))
        #expect(relaunch.map(\.name) == ["Soak 3"])
        #expect(IsolatedEngineSeed.missingCameras(run, existing: first).isEmpty)
        run.demoCameras = 0
        #expect(IsolatedEngineSeed.missingCameras(run, existing: []).isEmpty, "zero cameras means none")
        let mixed = [CameraConfiguration(name: "Soak 10", kind: .camera, vendor: .demo, endpoint: CameraEndpoint(host: "localhost"), username: ""),
                     CameraConfiguration(name: "Soak 2", kind: .camera, vendor: .demo, endpoint: CameraEndpoint(host: "localhost"), username: ""),
                     CameraConfiguration(name: "Porch", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.41"), username: "")]
        #expect(IsolatedEngineSeed.seededCameras(mixed).map(\.name) == ["Soak 2", "Soak 10"], "numeric order, other cameras left out")
    }
}

/// The measurement numbers and the counter reader.
@Suite struct ProbeSupportTests {
    @Test func percentilesAreNearestRankSamples() throws {
        let values = (1...100).map(Double.init).shuffled()
        let summary = try #require(ProbeStatistics.summary(values))
        #expect(summary.count == 100 && summary.min == 1 && summary.max == 100 && summary.p50 == 50 && summary.p95 == 95 && summary.p99 == 99 && summary.mean == 50.5)
        let few = try #require(ProbeStatistics.summary([7, 3]))
        #expect(few.p50 == 3 && few.p95 == 7 && few.p99 == 7, "rank ceil(p x n), a value that was measured")
        let one = try #require(ProbeStatistics.summary([4]))
        #expect(one.p50 == 4 && one.p99 == 4 && one.max == 4)
        #expect(ProbeStatistics.summary([]) == nil)
        #expect(ProbeStatistics.summary([.nan, .infinity])?.count == nil, "values that are not numbers are dropped")
        #expect(ProbeStatistics.summary([1, .nan, 3])?.count == 2)
    }

    @Test func millisecondsAndRates() {
        #expect(ProbeStatistics.milliseconds(from: 1_000_000, to: 2_500_000) == 1.5)
        #expect(ProbeStatistics.distinctPictureRate([5, 5, 5, 6, 6, 9, 5], seconds: 2) == 2, "5, 6, 9, 5 are four pictures in two seconds")
        #expect(ProbeStatistics.distinctPictureRate([], seconds: 1) == 0 && ProbeStatistics.distinctPictureRate([1], seconds: 0) == 0)
        #expect(ProbeStatistics.longestGap([0.1, 0.15, 0.9], from: 0, to: 1) == 0.75)
        #expect(ProbeStatistics.longestGap([], from: 2, to: 5) == 3, "no picture at all is one long gap")
        #expect(ProbeStatistics.longestGap([0.5], from: 0, to: 2) == 1.5, "and the wait after the last one counts")
    }

    @Test func probeFilesAreOneJSONObjectPerLineAndNeverNaN() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "T18-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ProbeFiles(directory: directory)
        files.append("heartbeat", ["n": 1, "lag": Double.nan, "state": ProbeFiles.name(of: .paused(.folderMissing))])
        files.append("heartbeat", ["n": 2, "cameras": [["state": ProbeFiles.name(of: .recording)], ["state": ProbeFiles.name(of: .waiting("waiting for the camera"))]]])
        let lines = try String(contentsOf: files.directory.appending(path: "heartbeat.jsonl"), encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        let first = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(first["n"] as? Int == 1 && first["lag"] is NSNull && first["state"] as? String == "paused:folderMissing")
        #expect(lines[1].contains("recording") && lines[1].contains("waiting"))
        files.write("keyframe", ["samples": 3, "enqueueMs": ProbeFiles.json(ProbeStatistics.summary([1, 2, 3]))])
        let result = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: files.directory.appending(path: "keyframe.json"))) as? [String: Any])
        #expect((result["enqueueMs"] as? [String: Any])?["p95"] as? Double == 3)
        #expect(ProbeFiles.json(nil) is NSNull)
        #expect(ProbeFiles.name(of: .off) == "off" && ProbeFiles.name(of: .paused(.diskFull)) == "paused:diskFull" && ProbeFiles.name(of: .paused(.notWritable("The drive isn’t answering."))) == "paused:notWritable")
    }

    /// Draws the counter the way `TestPattern.render` does (a black label, white glyph pixels, scale height / 120) into a luma plane.
    private func render(_ counter: Int, width: Int, height: Int, noise: Int = 0) -> [UInt8] {
        var plane = [UInt8](repeating: 100, count: width * height)
        let label = DemoCounterReader.geometry(width: width, height: height)
        for y in label.y..<min(height, label.y + 9 * label.scale) {
            for x in label.x..<min(width, label.x + (6 * 6 + 1) * label.scale) { plane[y * width + x] = 16 }
        }
        let text = String(repeating: "0", count: 6 - String(counter % 1_000_000).count) + String(counter % 1_000_000)
        for (position, character) in text.enumerated() {
            let digit = character.wholeNumberValue ?? 0
            for (row, bits) in DemoCounterReader.glyphs[digit].enumerated() {
                for column in 0..<5 where bits & (0x10 >> column) != 0 {
                    let px = label.x + (1 + position * 6 + column) * label.scale, py = label.y + (1 + row) * label.scale
                    for dy in 0..<label.scale { for dx in 0..<label.scale { plane[(py + dy) * width + px + dx] = 235 } }
                }
            }
        }
        if noise > 0 {
            var generator = SystemRandomNumberGenerator()
            for index in plane.indices { plane[index] = UInt8(clamping: Int(plane[index]) + Int.random(in: -noise...noise, using: &generator)) }
        }
        return plane
    }

    @Test func theCounterIsReadBackAtEveryDemoSize() {
        for (width, height) in [(1_920, 1_080), (640, 360), (2_688, 1_520), (320, 180)] {
            for counter in [0, 7, 12_345, 999_999, 100_000, 54_321] {
                let plane = render(counter, width: width, height: height)
                #expect(DemoCounterReader.read(width: width, height: height) { plane[$1 * width + $0] } == counter, "\(width)x\(height) \(counter)")
            }
        }
    }

    /// The reader against what the engine's demo camera really produces: encoded to H.264 by VideoToolbox, decoded again, and the counter of each picture
    /// read back. It starts at 0 and only goes up.
    @Test func theCounterIsReadFromARealEncodedAndDecodedDemoPicture() async throws {
        let codecs = AppleMediaCodecs()
        let source = codecs.makeSyntheticSource(displayName: "Counter", width: 1_920, height: 1_080, fps: 30, keyframeInterval: .seconds(1), audio: nil, audioSampleRate: 0)
        let stream = try await source.samples()
        var decoder: (any VideoDecoding)?
        defer { decoder?.invalidate() }
        var counters: [Int] = []
        var decoded = 0
        for try await sample in stream {
            guard case .video(let frame) = sample else { continue }
            let active = try decoder ?? codecs.makeVideoDecoder(format: frame.format)
            decoder = active
            if let picture = try await active.decode(frame) as? PixelBufferFrame {
                decoded += 1
                let value = DemoCounterReader.read(pixelBuffer: picture.pixelBuffer)
                #expect(value == DemoCounterReader.read(pixelBuffer: picture.pixelBuffer, viaCoreImage: true), "CoreImage reads what the direct path reads")
                if let value { counters.append(value) }
            }
            if decoded >= 45 { break }
        }
        await source.stop()
        #expect(decoded >= 40 && counters.count == decoded, "every decoded picture has a readable counter: \(counters.count) of \(decoded)")
        #expect(counters.first == 0 && zip(counters, counters.dropFirst()).allSatisfy { $0 < $1 }, "\(counters)")
    }

    @Test func compressionNoiseDoesNotChangeTheDigits() {
        let (width, height) = (1_920, 1_080)
        for counter in [31_415, 271_828, 600_000] {
            let plane = render(counter, width: width, height: height, noise: 30)
            #expect(DemoCounterReader.read(width: width, height: height) { plane[$1 * width + $0] } == counter)
        }
    }

    @Test func aPictureWithoutTheLabelReadsAsNothing() {
        let (width, height) = (1_920, 1_080)
        let blank = [UInt8](repeating: 0, count: width * height)
        #expect(DemoCounterReader.read(width: width, height: height) { blank[$1 * width + $0] } == nil, "a blank layer")
        let gray = [UInt8](repeating: 128, count: width * height)
        #expect(DemoCounterReader.read(width: width, height: height) { gray[$1 * width + $0] } == nil, "all lit is no digit")
        #expect(DemoCounterReader.read(width: 40, height: 20) { _, _ in 0 } == nil, "a picture too small for the label")
    }
}
#endif
