import BridgeSupport
import CameraAdapters
import FMP4
import Foundation
import MediaCore
import Synchronization
import TestSupport
import Testing
@testable import BridgeEngine

/// Everything one recorder test needs: a recordings folder that exists, a store decision, a hub, a clock, and the recorder.
struct RecorderRig {
    let root: TemporaryDirectory
    let target: FakeWriteTarget
    let hub = MediaHub()
    let clock: Box<Date>
    /// Seconds that do not jump (`RecorderTuning.uptime`); tests move it to age a write or an idle camera.
    let uptime = Box<TimeInterval>(1_000)
    let camera: CameraConfiguration
    let signal = ChangeSignal()
    var fileSystem: any RecorderFileSystem = DiskFileSystem()
    var naming: ArchivePlatformPolicy.DirectoryNaming = .cameraID
    var fileMaximumBytes = ArchiveConstants.fileMaximumBytes
    /// The host clock follows the frames (a tenth of a second behind their wall clock) while `feed` runs, as it would in real time.
    var clockFollowsFrames = true
    var stallPendingBytes = ArchiveConstants.stallPendingBytes

    init(camera: CameraConfiguration = RecorderFixtures.camera(), now: Date = RecorderFixtures.base.addingTimeInterval(1)) throws {
        root = try TemporaryDirectory()
        target = FakeWriteTarget(folder: root.url)
        clock = Box(now)
        self.camera = camera
    }

    func tuning(tick: Duration = .seconds(60), closeDeadline: Duration = .seconds(3)) -> RecorderTuning {
        var tuning = RecorderTuning()
        tuning.unrecordableRetry = 0.5
        tuning.fileMaximumBytes = fileMaximumBytes
        tuning.stallPendingBytes = stallPendingBytes
        let clock = clock, uptime = uptime
        tuning.now = { clock.value }
        tuning.uptime = { uptime.value }
        tuning.timeZone = TimeZone(identifier: "UTC")!
        tuning.fileSystem = fileSystem
        tuning.waitingTick = tick
        tuning.recordingTick = tick
        tuning.retryDelays = [0.2, 0.4, 0.8]
        tuning.closeDeadline = closeDeadline
        return tuning
    }

    /// `tick`: how often the recorder looks at the store, the clock and the drive (a minute: only the first look, at `start()`, happens unless a
    /// test needs the others).
    func recorder(tick: Duration = .seconds(60), closeDeadline: Duration = .seconds(3), codecs: any MediaCodecs = BridgeEnvironment.inert(directory: URL(filePath: "/tmp/x")).codecs) -> CameraArchiveRecorder {
        CameraArchiveRecorder(camera: camera, hub: hub, target: target, codecs: codecs, naming: naming, signal: signal, tuning: tuning(tick: tick, closeDeadline: closeDeadline))
    }

    /// Ingests `samples` into the hub. With a `recorder`, 25 at a time and waiting after each batch until the recorder has taken them in (so the
    /// host clock, which follows the frames, is never far ahead of the recorder, a stalled disk cannot be mistaken for a slow test machine, and
    /// the hub's queue of 900 samples never overflows); `expecting` is the number of samples the recorder is meant to take in (default: all).
    /// Without a recorder the samples go in with a short pause every 50.
    func feed(_ samples: [MediaSample], to recorder: CameraArchiveRecorder? = nil, expecting: Int? = nil) async {
        let before = await recorder?.samplesHandled ?? 0
        let expected = expecting ?? samples.count
        for (number, sample) in samples.enumerated() {
            if clockFollowsFrames, case .video(let frame) = sample, frame.wallClock.addingTimeInterval(0.1) > clock.value {
                clock.set(frame.wallClock.addingTimeInterval(0.1))
            }
            await hub.ingest(sample)
            if let recorder {
                if number % 25 == 24 || number == samples.count - 1 {
                    let goal = before + min(expected, number + 1)
                    _ = await eventually(timeout: .seconds(20), every: .milliseconds(1)) { await recorder.samplesHandled >= goal }
                }
            } else if number % 50 == 49 {
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    func feed(_ frames: [EncodedVideoFrame], to recorder: CameraArchiveRecorder? = nil, expecting: Int? = nil) async {
        await feed(frames.map { MediaSample.video($0) }, to: recorder, expecting: expecting)
    }

    /// The mp4 and sidecar of a segment ("<camera>/<date>/<time>").
    func files(_ segment: String) -> (mp4: URL, index: URL) {
        (root.url.appending(path: "\(segment).mp4"), root.url.appending(path: "\(segment).cbidx"))
    }
}

extension RecordedFile {
    init(_ rig: RecorderRig, segment: String) throws {
        try self.init(root: rig.root.url, segment: segment)
    }
}
