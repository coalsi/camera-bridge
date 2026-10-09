import BridgeSupport
import Foundation
import MediaCore
import Synchronization

/// How the Linux codecs are set up. Everything has a default that works on the Camera Bridge OS image.
public struct FFmpegCodecsConfiguration: Sendable, Equatable {
    public enum VideoEncoderPreference: String, Sendable, Equatable {
        /// VA-API when a render node exists and a probe encode works, libx264 otherwise.
        case automatic
        case software
        case vaapi
    }

    /// The ffmpeg program. nil: `CAMERABRIDGE_FFMPEG`, then `ffmpeg` on the usual paths.
    public var executable: URL?
    public var videoEncoder: VideoEncoderPreference
    /// The VA-API render node.
    public var vaapiDevice: String
    /// libx264 preset: `veryfast` keeps a mini PC's CPU low at a small cost in picture quality per bit.
    public var x264Preset: String
    /// A TrueType font for the timestamp overlay (drawtext). nil: the first of the usual system fonts.
    public var fontFile: String?
    /// Where per-transcoder scratch files (the overlay text) go. nil: the system temporary directory.
    public var scratchDirectory: URL?

    public init(executable: URL? = nil, videoEncoder: VideoEncoderPreference = .automatic, vaapiDevice: String = "/dev/dri/renderD128",
                x264Preset: String = "veryfast", fontFile: String? = nil, scratchDirectory: URL? = nil) {
        self.executable = executable
        self.videoEncoder = videoEncoder
        self.vaapiDevice = vaapiDevice
        self.x264Preset = x264Preset
        self.fontFile = fontFile
        self.scratchDirectory = scratchDirectory
    }

    static let searchPaths = ["/usr/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg", "/snap/bin/ffmpeg"]
    static let fontPaths = ["/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
                            "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf", "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
                            "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
                            "/System/Library/Fonts/Supplemental/Arial Bold.ttf", "/System/Library/Fonts/Supplemental/Arial.ttf"]

    /// The ffmpeg program to run, nil when there is none.
    func resolveExecutable(environment: [String: String] = ProcessInfo.processInfo.environment,
                           fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        if let executable { return fileExists(executable.path) ? executable : nil }
        if let override = environment["CAMERABRIDGE_FFMPEG"], !override.isEmpty { return fileExists(override) ? URL(fileURLWithPath: override) : nil }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let path = "\(directory)/ffmpeg"
            if fileExists(path) { return URL(fileURLWithPath: path) }
        }
        return Self.searchPaths.first(where: fileExists).map { URL(fileURLWithPath: $0) }
    }

    func resolveFont(fileExists: (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) }) -> String? {
        if let fontFile { return fileExists(fontFile) ? fontFile : nil }
        return Self.fontPaths.first(where: fileExists)
    }
}

/// What the installed ffmpeg can do, learned once by asking it (`-version`, `-encoders`, `-filters`, and a probe encode for
/// VA-API).
struct FFmpegCapabilities: Sendable, Equatable {
    var version = ""
    var encoders: Set<String> = []
    var decoders: Set<String> = []
    var filters: Set<String> = []
    /// h264_vaapi works on `vaapiDevice` (a probe encode succeeded), with the GPU's low-power encoder when `vaapiLowPower`.
    var vaapiUsable = false
    var vaapiLowPower = false

    var hasLibx264: Bool { encoders.contains("libx264") }
    var hasDrawText: Bool { filters.contains("drawtext") }
    var hasOpus: Bool { encoders.contains("libopus") }
    var hasAACEncoder: Bool { encoders.contains("aac") || encoders.contains("libfdk_aac") }
    var hasAACELDEncoder: Bool { encoders.contains("libfdk_aac") }
    /// `-encoders` of an ffmpeg that has all the pieces the codecs need.
    var hasMJPEG: Bool { encoders.contains("mjpeg") }

    /// Names in the second column of `ffmpeg -encoders` / `-decoders` / `-filters` (the first is the flag column: letters and dots,
    /// like `V....D` or `T.C`). The legend lines before the list (`V..... = Video`) and headings are skipped.
    static func names(inListing listing: String) -> Set<String> {
        var names: Set<String> = []
        for line in listing.split(separator: "\n", omittingEmptySubsequences: true) {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 3, columns[1] != "=", columns[0].count <= 8,
                  columns[0].allSatisfy({ $0.isLetter || $0 == "." || $0 == "|" }) else { continue }
            names.insert(String(columns[1]))
        }
        return names
    }

    /// "7.1.1" from "ffmpeg version 7.1.1-1 Copyright …".
    static func versionName(inBanner banner: String) -> String {
        let first = banner.split(separator: "\n").first.map(String.init) ?? ""
        let parts = first.split(separator: " ")
        guard let index = parts.firstIndex(of: "version"), index + 1 < parts.count else { return first }
        return String(parts[index + 1])
    }

    /// Asks ffmpeg. Synchronous (about a tenth of a second, plus the VA-API probe when there is a render node).
    static func probe(launcher: any FFmpegProcessLaunching, executable: URL, configuration: FFmpegCodecsConfiguration,
                      deviceExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }, log: Log) -> FFmpegCapabilities {
        var capabilities = FFmpegCapabilities()
        func run(_ arguments: [String], label: String, timeout: Duration = .seconds(10)) -> (output: String, status: Int32?) {
            guard let session = try? FFmpegSession(launcher: launcher, spec: FFmpegProcessSpec(executable: executable, arguments: arguments, label: label)) else {
                return ("", nil)
            }
            session.closeInput()
            let exit = session.waitForExit(timeout: timeout)
            if exit == nil { session.terminate() }
            return (String(decoding: session.drain(), as: UTF8.self), exit?.status)
        }
        capabilities.version = versionName(inBanner: run(["-hide_banner", "-version"], label: "version").output)
        // `-version` without -hide_banner prints the banner; with it, only the first line, which is all we need.
        if capabilities.version.isEmpty { capabilities.version = versionName(inBanner: run(["-version"], label: "version").output) }
        capabilities.encoders = names(inListing: run(["-hide_banner", "-encoders"], label: "encoders").output)
        capabilities.decoders = names(inListing: run(["-hide_banner", "-decoders"], label: "decoders").output)
        capabilities.filters = names(inListing: run(["-hide_banner", "-filters"], label: "filters").output)
        if configuration.videoEncoder != .software, capabilities.encoders.contains("h264_vaapi"), deviceExists(configuration.vaapiDevice) {
            func probe(lowPower: Bool) -> (output: String, status: Int32?) {
                run(["-hide_banner", "-loglevel", "error", "-vaapi_device", configuration.vaapiDevice, "-f", "lavfi", "-i", "color=c=black:s=320x240:r=5",
                     "-t", "0.6", "-vf", "format=nv12,hwupload", "-c:v", "h264_vaapi"] + (lowPower ? ["-low_power", "1"] : []) + ["-f", "null", "-"],
                    label: "VA-API probe", timeout: .seconds(10))
            }
            // The shader-based encoder first; recent Intel GPUs (Alder Lake-N and newer) only offer the fixed-function one.
            var result = probe(lowPower: false)
            if result.status == 0 {
                capabilities.vaapiUsable = true
            } else {
                let second = probe(lowPower: true)
                if second.status == 0 {
                    capabilities.vaapiUsable = true
                    capabilities.vaapiLowPower = true
                } else {
                    result = second
                }
            }
            if !capabilities.vaapiUsable {
                log.info("VA-API probe encode on \(configuration.vaapiDevice) failed (\(result.output.split(separator: "\n").last.map(String.init) ?? "no output")); encoding in software")
            }
        }
        return capabilities
    }
}

/// The ffmpeg this process uses: where it is, what it can do, and what the codecs decided from that. Shared by every object
/// `FFmpegMediaCodecs` makes.
final class FFmpegRuntime: Sendable {
    let launcher: any FFmpegProcessLaunching
    let executable: URL?
    let configuration: FFmpegCodecsConfiguration
    let log = Log(category: "FFmpegCodecs")

    private struct State {
        var capabilities: FFmpegCapabilities?
        var vaapiDisabled = false
        var loggedBackend: String?
        var loggedFontProblem = false
        var fontResolved = false
        var font: String?
    }

    private let state = Mutex(State())

    /// Whether a device node exists (replaced in tests).
    let deviceExists: @Sendable (String) -> Bool

    init(launcher: any FFmpegProcessLaunching, configuration: FFmpegCodecsConfiguration, executable: URL?,
         deviceExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.deviceExists = deviceExists
        self.launcher = launcher
        self.configuration = configuration
        self.executable = executable
    }

    /// The program, or the error every `make…` throws when ffmpeg is not installed.
    func requireExecutable() throws -> URL {
        guard let executable else {
            throw MediaCodecError.unsupported("ffmpeg is not installed (looked for CAMERABRIDGE_FFMPEG, PATH and \(FFmpegCodecsConfiguration.searchPaths.joined(separator: ", ")))")
        }
        return executable
    }

    /// Probed on first use.
    func capabilities() throws -> FFmpegCapabilities {
        let executable = try requireExecutable()
        if let known = state.withLock({ $0.capabilities }) { return known }
        let probed = FFmpegCapabilities.probe(launcher: launcher, executable: executable, configuration: configuration, deviceExists: deviceExists, log: log)
        let stored = state.withLock { state -> FFmpegCapabilities in
            if let known = state.capabilities { return known }
            state.capabilities = probed
            return probed
        }
        log.info("ffmpeg \(stored.version): libx264 \(stored.hasLibx264 ? "yes" : "no"), VA-API \(stored.vaapiUsable ? (stored.vaapiLowPower ? "usable (low power)" : "usable") : "not available"), "
                 + "Opus \(stored.hasOpus ? "yes" : "no"), AAC \(stored.hasAACEncoder ? "yes" : "no"), AAC-ELD \(stored.hasAACELDEncoder ? "yes" : "no"), "
                 + "drawtext \(stored.hasDrawText ? "yes" : "no")")
        return stored
    }

    /// The H.264 encoder for a new pipeline (logged when it changes).
    func videoBackend() throws -> FFmpegVideoBackend {
        let capabilities = try capabilities()
        let disabled = state.withLock { $0.vaapiDisabled }
        let backend: FFmpegVideoBackend
        switch configuration.videoEncoder {
        case .software:
            backend = .software(preset: configuration.x264Preset)
        case .vaapi, .automatic:
            backend = capabilities.vaapiUsable && !disabled ? .vaapi(device: configuration.vaapiDevice, lowPower: capabilities.vaapiLowPower)
                : .software(preset: configuration.x264Preset)
        }
        if case .software = backend, !capabilities.hasLibx264 {
            throw MediaCodecError.unsupported("this ffmpeg has no libx264 encoder and no usable VA-API encoder")
        }
        let description = backend.description
        let changed = state.withLock { state -> Bool in
            defer { state.loggedBackend = description }
            return state.loggedBackend != description
        }
        if changed { log.info("H.264 encoding with \(description)") }
        return backend
    }

    /// A VA-API pipeline died at start: use software from now on.
    func disableVAAPI(reason: String) {
        let first = state.withLock { state -> Bool in
            defer { state.vaapiDisabled = true }
            return !state.vaapiDisabled
        }
        if first { log.warning("VA-API encoding failed (\(reason)); switching to libx264 for new pipelines") }
    }

    /// The overlay's font, nil (logged once) when overlay drawing is not possible. Resolved once.
    func overlayFont() -> String? {
        let known = state.withLock { ($0.fontResolved, $0.font) }
        if known.0 { return known.1 }
        guard let capabilities = try? capabilities() else { return nil }
        let font = configuration.resolveFont().flatMap { FFmpegArguments.isUsablePath($0) ? $0 : nil }
        let usable = capabilities.hasDrawText ? font : nil
        let first = state.withLock { state -> Bool in
            state.fontResolved = true
            state.font = usable
            defer { state.loggedFontProblem = true }
            return !state.loggedFontProblem
        }
        if usable == nil, first {
            log.warning("the timestamp overlay cannot be drawn: " + (capabilities.hasDrawText ? "no usable TrueType font found (install fonts-dejavu-core)"
                                                                      : "this ffmpeg has no drawtext filter (needs libfreetype)"))
        }
        return usable
    }
}
