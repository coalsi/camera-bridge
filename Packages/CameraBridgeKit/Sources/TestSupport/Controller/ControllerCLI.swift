import BridgeSupport
import Foundation
import HAP
import HDS

/// `cbctl`: a developer HomeKit controller for CameraBridge accessories, built on `HAPTestController`.
/// It connects by host:port only and never advertises anything. Pairing data lives in `HAPControllerStore`
/// (`~/.cbctl/`, `$CBCTL_HOME` or `--home DIR`). The setup code and keys are never printed.
/// The command logic lives here (not in the executable) so tests can run it against loopback accessories.
public struct ControllerCLI: Sendable {
    /// Where output goes (stdout / stderr in the executable; captured in tests).
    public struct Output: Sendable {
        public var standard: @Sendable (String) -> Void
        public var error: @Sendable (String) -> Void
        public init(standard: @escaping @Sendable (String) -> Void, error: @escaping @Sendable (String) -> Void) {
            self.standard = standard
            self.error = error
        }

        /// Writes lines to the process's stdout / stderr.
        public static let console = Output(standard: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
                                           error: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
    }

    public enum ExitCode {
        public static let success: Int32 = 0
        public static let failure: Int32 = 1
        public static let usage: Int32 = 64
    }

    public static let usage = """
        cbctl — CameraBridge developer HAP controller (dev-only; connects by host:port, never advertises)

        USAGE: cbctl [--home DIR] [--accessory HOST:PORT|ID] <command> [arguments]

        COMMANDS:
          pair <host:port> <setup-code>   Pair with an accessory (keys stored in ~/.cbctl/)
          accessories                     Print the /accessories JSON
          watch-motion [--seconds N]      Subscribe to MotionDetected and print events
          snapshot <out.jpg> [--width W] [--height H]
                                          Request a snapshot via /resource
          live <seconds> <out.h264> [--width W] [--height H] [--fps F]
                                          Start a live stream and write the H.264 elementary stream
          record <out.mp4> [--seconds N] [--fragments N] [--no-audio]
                                          Request an HKSV recording and write init + fragments
          unpair                          Remove the pairing
          --help                          Show this help

        OPTIONS:
          --home DIR          Pairing store directory (default: $CBCTL_HOME or ~/.cbctl)
          --accessory T       Stored accessory to use: host:port or accessory ID (default: most recently paired)
          --aid N             Accessory id on the server (default 1)
          --timeout S         Seconds to wait for connections and answers (default 15)
        """

    public var store: HAPControllerStore
    public var transport: any NetworkTransport
    public var output: Output

    public init(store: HAPControllerStore, transport: any NetworkTransport, output: Output) {
        self.store = store
        self.transport = transport
        self.output = output
    }

    /// Entry point of the `cbctl` executable: default store (or `--home`), the platform transport, console output.
    public static func main(arguments: [String]) async -> Int32 {
        #if os(macOS) || os(Linux)
        let cli = ControllerCLI(store: HAPControllerStore(directory: HAPControllerStore.defaultDirectory()), transport: PlatformNetworkTransport(),
                                output: .console)
        return await cli.run(arguments)
        #else
        Output.console.error("cbctl: no network transport on this platform yet")
        return ExitCode.failure
        #endif
    }

    /// Runs one command line (without the program name). Returns the exit code.
    public func run(_ arguments: [String]) async -> Int32 {
        var args = Arguments(arguments)
        if args.flag("--help") || args.flag("-h") || args.positional.first == "help" || args.positional.isEmpty {
            output.standard(Self.usage)
            return ExitCode.success
        }
        var cli = self
        if let home = args.value("--home") { cli.store = HAPControllerStore(directory: URL(fileURLWithPath: home, isDirectory: true)) }
        let command = args.positional.removeFirst()
        do {
            switch command {
            case "pair": return try await cli.pair(args)
            case "accessories": return try await cli.accessories(args)
            case "watch-motion": return try await cli.watchMotion(args)
            case "snapshot": return try await cli.snapshot(args)
            case "live": return try await cli.live(args)
            case "record": return try await cli.record(args)
            case "unpair": return try await cli.unpair(args)
            default:
                output.error("cbctl: unknown command '\(command)'.\n\n\(Self.usage)")
                return ExitCode.usage
            }
        } catch let error as UsageError {
            output.error("cbctl: \(error.message)\n\n\(Self.usage)")
            return ExitCode.usage
        } catch {
            output.error("cbctl \(command): \(error)")
            return ExitCode.failure
        }
    }

    // MARK: - Commands

    private func pair(_ args: Arguments) async throws -> Int32 {
        let timeout = try args.timeout()
        guard args.positional.count == 2, let endpoint = HostPort(parsing: args.positional[0]) else {
            throw UsageError("pair needs <host:port> <setup-code>")
        }
        let code = args.positional[1]
        try store.prepareDirectory()   // the pairing must be storable before the accessory commits to it
        let identity = try store.loadOrCreateIdentity()
        let controller = try await HAPTestController.connect(host: endpoint.host, port: endpoint.port, transport: transport, identity: identity,
                                                             timeout: timeout)
        return try await Self.using(controller) { controller in
            await controller.setDefaultTimeout(timeout)
            let pairing = try await controller.pairSetup(setupCode: code)
            // From M6 on the accessory counts us as its admin and refuses another pair-setup: store the pairing before
            // anything else can fail, so later commands can verify with it and `unpair` can release the accessory.
            var stored = HAPControllerStore.StoredAccessory(host: endpoint.host, port: endpoint.port, pairing: pairing)
            try store.save(stored)
            let paired = "paired with \(pairing.accessoryPairingID) at \(endpoint) and stored the pairing"
            let recovery = "Retry any command, or run `cbctl unpair --accessory \(endpoint)` to release the accessory."
            do {
                try await controller.pairVerify()
            } catch {
                output.error("cbctl pair: \(paired), but pair-verify failed: \(error). \(recovery)")
                return ExitCode.failure
            }
            do {
                stored.name = try await controller.accessories().accessory(aid: 1)?.information(.name)
            } catch {
                output.error("cbctl pair: \(paired), but GET /accessories failed: \(error). \(recovery)")
                return ExitCode.failure
            }
            try store.save(stored)
            output.standard("Paired with \(stored.name ?? "accessory") (\(pairing.accessoryPairingID)) at \(endpoint).")
            return ExitCode.success
        }
    }

    private func accessories(_ args: Arguments) async throws -> Int32 {
        guard args.positional.isEmpty else { throw UsageError("accessories takes no arguments") }
        return try await withConnection(args) { controller in
            let database = try await controller.accessories()
            output.standard(String(decoding: database.json.serialized(), as: UTF8.self))
            return ExitCode.success
        }
    }

    private func watchMotion(_ args: Arguments) async throws -> Int32 {
        let seconds = try args.double("--seconds")
        guard args.positional.isEmpty else { throw UsageError("watch-motion takes no arguments") }
        return try await withConnection(args) { controller in
            let database = try await controller.accessories()
            let sensors = database.characteristics(.motionDetected)
            guard !sensors.isEmpty else { throw HAPControllerError.notFound("MotionDetected") }
            let names = Dictionary(database.accessories.map { ($0.aid, $0.information(.name) ?? "aid \($0.aid)") }) { first, _ in first }
            try await controller.subscribe(sensors.map(\.id))
            for result in try await controller.read(sensors.map(\.id)) {
                output.standard("\(timestamp()) \(names[result.id.aid] ?? "?") [\(result.id)] MotionDetected = \(describe(result.value))")
            }
            output.standard("Watching \(sensors.count) motion sensor(s)\(seconds.map { " for \($0) s" } ?? "; press Ctrl-C to stop").")
            let deadline = seconds.map { ContinuousClock.now + .milliseconds(Int64($0 * 1000)) }
            while deadline.map({ ContinuousClock.now < $0 }) ?? true {
                let event: HAPCharacteristicEvent
                do {
                    event = try await controller.nextEvent(timeout: .milliseconds(250))
                } catch HAPControllerError.timedOut {
                    continue
                }
                guard sensors.contains(where: { $0.id == event.id }) else { continue }
                output.standard("\(timestamp()) \(names[event.id.aid] ?? "?") [\(event.id)] MotionDetected = \(describe(event.value))")
            }
            try? await controller.unsubscribe(sensors.map(\.id))
            return ExitCode.success
        }
    }

    private func snapshot(_ args: Arguments) async throws -> Int32 {
        let width = try args.int("--width") ?? 1280
        let height = try args.int("--height") ?? 720
        let aid = try args.int("--aid").map { UInt64($0) }
        guard args.positional.count == 1 else { throw UsageError("snapshot needs <out.jpg>") }
        let path = args.positional[0]
        return try await withConnection(args) { controller in
            let jpeg = try await controller.snapshot(width: width, height: height, aid: aid)
            try jpeg.write(to: URL(fileURLWithPath: path))
            output.standard("Wrote \(jpeg.count) bytes to \(path).")
            return ExitCode.success
        }
    }

    private func live(_ args: Arguments) async throws -> Int32 {
        let width = try args.int("--width") ?? 1280
        let height = try args.int("--height") ?? 720
        let fps = try args.int("--fps") ?? 30
        let aid = UInt64(try args.int("--aid") ?? 1)
        guard args.positional.count == 2, let seconds = Double(args.positional[0]), seconds > 0, seconds.isFinite else {
            throw UsageError("live needs <seconds> <out.h264>")
        }
        let path = args.positional[1]
        return try await withConnection(args) { controller in
            let camera = try await controller.cameraIDs(aid: aid)
            guard let stream = camera.streams.first else { throw HAPControllerError.notFound("CameraRTPStreamManagement") }
            let supported = try await controller.supportedStreamingConfiguration(stream)
            guard let codec = supported.video.codecs.first else { throw HAPControllerError.notFound("video codec configuration") }
            let resolution = Self.pickResolution(codec.resolutions, width: width, height: height, fps: fps)
            var options = LiveStreamOptions(resolution: resolution, profile: codec.profiles.contains(1) ? 1 : (codec.profiles.first ?? 1),
                                            level: codec.levels.max() ?? 2)
            if let audioCodec = supported.audio.codecs.first(where: { $0.codec == 3 }) ?? supported.audio.codecs.first {
                options.audio = ControllerTLV.SelectedAudio(codec: audioCodec.codec, channels: audioCodec.channels, bitrateMode: audioCodec.bitrateMode,
                                                            sampleRate: audioCodec.sampleRates.contains(2) ? 2 : (audioCodec.sampleRates.first ?? 2),
                                                            ssrc: UInt32.random(in: 1...UInt32.max))
            } else {
                options.audio = nil
            }
            output.standard("Starting live stream \(resolution) on \(stream.aid).\(stream.serviceIID)…")
            let handle = try await controller.startLiveStream(stream, options: options)
            let receiver = handle.receiver
            let collector = Task { () -> (data: Data, frames: Int) in
                var out = Data()
                var frames = 0
                var started = false
                for await frame in receiver.videoFrames where frame.isComplete {
                    if !started {
                        guard frame.isKeyframe else { continue }
                        started = true
                    }
                    out.append(frame.annexB)
                    frames += 1
                }
                return (out, frames)
            }
            try? await Task.sleep(for: .milliseconds(Int64(seconds * 1000)))
            var stopError: (any Error)?
            do {
                try await handle.stop()
            } catch {
                await receiver.stop()
                stopError = error
            }
            let (data, frames) = await collector.value
            try data.write(to: URL(fileURLWithPath: path))
            let stats = await receiver.statistics
            let rate = await receiver.measuredFrameRate()
            output.standard("Wrote \(frames) access units (\(data.count) bytes) to \(path); keyframes \(stats.keyframes), "
                            + "incomplete \(stats.incompleteVideoFrames), audio packets \(stats.audioFrames), "
                            + "sender reports \(stats.videoSenderReports + stats.audioSenderReports)"
                            + (rate.map { String(format: ", %.1f fps", $0) } ?? "") + ".")
            if let stopError { throw stopError }
            return frames > 0 ? ExitCode.success : ExitCode.failure
        }
    }

    private func record(_ args: Arguments) async throws -> Int32 {
        let seconds = try args.double("--seconds") ?? 30
        let fragments = try args.int("--fragments")
        let audio = !args.flag("--no-audio")
        let aid = UInt64(try args.int("--aid") ?? 1)
        guard args.positional.count == 1 else { throw UsageError("record needs <out.mp4>") }
        let path = args.positional[0]
        return try await withConnection(args) { controller in
            let camera = try await controller.cameraIDs(aid: aid)
            guard let recording = camera.recording else { throw HAPControllerError.notFound("CameraRecordingManagement") }
            guard let setupDataStream = camera.setupDataStreamTransport else { throw HAPControllerError.notFound("SetupDataStreamTransport") }
            let supported = try await controller.supportedRecordingConfiguration(recording)
            let selection = try ControllerTLV.SelectedCameraRecordingConfiguration.preferred(camera: supported.camera, video: supported.video,
                                                                                             audio: supported.audio)
            try await controller.selectRecordingConfiguration(recording, selection)
            try await controller.enableRecording(camera, audio: audio)
            let dataStream = try await controller.openDataStream(setupDataStream)
            let streamID: Int64 = 1
            let capture: RecordingCapture
            do {
                let open = try await dataStream.openRecording(streamID: streamID)
                guard open.isAccepted else {
                    throw HAPControllerError.malformedResponse("dataSend/open refused: HDS status \(open.status)"
                                                               + (open.protocolReason.map { ", reason \($0)" } ?? ""))
                }
                output.standard("Recording \(selection.resolution) (fragments of \(selection.container.fragmentLengthMs) ms) for up to \(seconds) s…")
                capture = try await dataStream.receiveRecording(streamID: streamID, maximumFragments: fragments,
                                                                duration: .milliseconds(Int64(seconds * 1000)))
                if capture.endOfStream {
                    try await dataStream.ackRecording(streamID: streamID)
                    // Let the accessory take the ack before this connection (and the HAP one it rides on) goes away: it reads the
                    // two connections independently, and closing the HAP one ends the HDS session first if it wins that race.
                    try await Task.sleep(for: .milliseconds(100))
                } else if capture.closeReason == nil {
                    try await dataStream.closeRecording(streamID: streamID, reason: .normal)
                }
            } catch {
                await dataStream.close()
                throw error
            }
            await dataStream.close()
            guard capture.initialization != nil else { throw HAPControllerError.malformedResponse("no mediaInitialization packet") }
            try capture.mp4.write(to: URL(fileURLWithPath: path))
            output.standard("Wrote init + \(capture.fragments.count) fragment(s) (\(capture.mp4.count) bytes) to \(path)"
                            + (capture.endOfStream ? "; end of stream" : "") + (capture.closeReason.map { "; closed by the accessory (\($0))" } ?? "") + ".")
            return ExitCode.success
        }
    }

    private func unpair(_ args: Arguments) async throws -> Int32 {
        guard args.positional.isEmpty else { throw UsageError("unpair takes no arguments") }
        let stored = try store.accessory(matching: args.value("--accessory"))
        return try await withConnection(args, stored: stored) { controller in
            try await controller.removePairing()
            try store.remove(accessoryPairingID: stored.pairing.accessoryPairingID)
            output.standard("Unpaired from \(stored.name ?? "accessory") (\(stored.pairing.accessoryPairingID)) at \(stored.endpoint).")
            return ExitCode.success
        }
    }

    // MARK: - Helpers

    /// Connects to the stored accessory (`--accessory` or the most recent), pair-verifies, runs `body`, closes.
    private func withConnection(_ args: Arguments, stored: HAPControllerStore.StoredAccessory? = nil,
                                _ body: (HAPTestController) async throws -> Int32) async throws -> Int32 {
        let timeout = try args.timeout()
        let target = try stored ?? store.accessory(matching: args.value("--accessory"))
        guard let identity = try store.loadIdentity() else { throw HAPControllerStoreError.noPairing }
        let controller = try await HAPTestController.connectVerified(host: target.host, port: target.port, transport: transport, identity: identity,
                                                                     pairing: target.pairing, timeout: timeout)
        await controller.setDefaultTimeout(timeout)
        return try await Self.using(controller, body)
    }

    /// Runs `body` and closes the controller whatever happens.
    private static func using(_ controller: HAPTestController, _ body: (HAPTestController) async throws -> Int32) async throws -> Int32 {
        do {
            let result = try await body(controller)
            await controller.close()
            return result
        } catch {
            await controller.close()
            throw error
        }
    }

    /// The offered resolution equal to the request, else the largest one not above it, else the smallest.
    static func pickResolution(_ offered: [ControllerTLV.Resolution], width: Int, height: Int, fps: Int) -> ControllerTLV.Resolution {
        if let exact = offered.first(where: { $0.width == width && $0.height == height && $0.fps == fps }) { return exact }
        if let exact = offered.first(where: { $0.width == width && $0.height == height }) { return exact }
        let notLarger = offered.filter { $0.width * $0.height <= width * height }
        if let best = notLarger.max(by: { $0.width * $0.height < $1.width * $1.height }) { return best }
        return offered.min(by: { $0.width * $0.height < $1.width * $1.height }) ?? ControllerTLV.Resolution(width, height, fps)
    }

    private func timestamp() -> String { Date().formatted(.iso8601) }

    private func describe(_ value: HAPJSON?) -> String {
        guard let value else { return "?" }
        if let bool = value.hapBool { return bool ? "true" : "false" }
        return String(decoding: value.serialized(), as: UTF8.self)
    }
}

extension HAPTestController {
    public func setDefaultTimeout(_ timeout: Duration) {
        defaultTimeout = timeout
    }
}

struct UsageError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Minimal argument parsing: `--name value` options and `--flag`s anywhere, the rest positional.
struct Arguments {
    private static let valueOptions: Set<String> = ["--home", "--accessory", "--timeout", "--seconds", "--width", "--height", "--fps",
                                                    "--fragments", "--aid"]
    var positional: [String] = []
    private var values: [String: String] = [:]
    private var flags: Set<String> = []
    private var missingValue: String?

    init(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if Self.valueOptions.contains(argument) {
                if index + 1 < arguments.count {
                    values[argument] = arguments[index + 1]
                    index += 2
                } else {
                    missingValue = argument
                    index += 1
                }
                continue
            }
            if argument.hasPrefix("--") || argument == "-h" {
                flags.insert(argument)
            } else {
                positional.append(argument)
            }
            index += 1
        }
    }

    func value(_ name: String) -> String? { values[name] }
    func flag(_ name: String) -> Bool { flags.contains(name) }

    func int(_ name: String) throws -> Int? {
        if missingValue == name { throw UsageError("\(name) needs a value") }
        guard let text = values[name] else { return nil }
        guard let value = Int(text), value > 0 else { throw UsageError("\(name) must be a positive integer") }
        return value
    }

    func double(_ name: String) throws -> Double? {
        if missingValue == name { throw UsageError("\(name) needs a value") }
        guard let text = values[name] else { return nil }
        guard let value = Double(text), value > 0, value.isFinite else { throw UsageError("\(name) must be a positive number") }
        return value
    }

    func timeout() throws -> Duration {
        .milliseconds(Int64((try double("--timeout") ?? 15) * 1000))
    }
}
