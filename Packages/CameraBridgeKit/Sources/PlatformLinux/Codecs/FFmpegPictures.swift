import BridgeSupport
import Foundation
import MediaCore
import Synchronization

/// Runs ffmpeg once: input in, wait (bounded) for the end, output back. For work that is one picture or a second of audio.
enum FFmpegOneShot {
    static func run(runtime: FFmpegRuntime, label: String, arguments: [String], input: Data?, timeout: Duration) throws -> Data {
        let executable = try runtime.requireExecutable()
        let session = try FFmpegSession(launcher: runtime.launcher, spec: FFmpegProcessSpec(executable: executable, arguments: arguments, label: label))
        defer { session.terminate() }
        if let input {
            do {
                try session.send(input)
            } catch {
                throw session.exit != nil ? session.failure : error
            }
        }
        session.closeInput()
        guard let exit = session.waitForExit(timeout: timeout) else {
            throw MediaCodecError.unsupported("ffmpeg (\(label)) did not finish within \(timeout / .seconds(1)) s")
        }
        let output = session.drain()
        guard exit.status == 0, !exit.signaled else { throw session.failure }
        return output
    }
}

/// JPEG snapshots and resizing with ffmpeg's mjpeg encoder. Sizes keep the aspect ratio within the bounds and never upscale
/// (the rule of `PlatformApple.JPEGSnapshot`).
enum FFmpegPictures {
    static let timeout = Duration.seconds(15)

    /// The largest size within the bounds with the source aspect ratio (rounded, at least 1); nil or non-positive bounds are ignored.
    static func fittedSize(width: Int, height: Int, maxWidth: Int?, maxHeight: Int?) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (width, height) }
        var scale = 1.0
        if let maxWidth, maxWidth > 0 { scale = min(scale, Double(maxWidth) / Double(width)) }
        if let maxHeight, maxHeight > 0 { scale = min(scale, Double(maxHeight) / Double(height)) }
        guard scale < 1 else { return (width, height) }
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    static func jpeg(from picture: RawVideoFrame, maxWidth: Int?, maxHeight: Int?, quality: Double, runtime: FFmpegRuntime) throws -> Data {
        guard picture.isComplete else {
            throw MediaCodecError.unsupported("picture \(picture.width)×\(picture.height) holds \(picture.pixels.count) bytes")
        }
        let target = fittedSize(width: picture.width, height: picture.height, maxWidth: maxWidth, maxHeight: maxHeight)
        let arguments = FFmpegArguments.jpeg(inputWidth: picture.width, inputHeight: picture.height, width: max(1, target.width), height: max(1, target.height),
                                             quality: quality)
        let data = try FFmpegOneShot.run(runtime: runtime, label: "snapshot", arguments: arguments, input: picture.pixels, timeout: timeout)
        guard data.count > 4, data.prefix(2) == Data([0xFF, 0xD8]) else { throw MediaCodecError.noFrame }
        return data
    }

    /// Downscales a JPEG (or PNG) to fit the bounds as JPEG; returns the input unchanged when it already fits.
    static func resize(_ data: Data, maxWidth: Int?, maxHeight: Int?, runtime: FFmpegRuntime) throws -> Data {
        guard let size = imageSize(data), size.width > 0, size.height > 0 else { throw MediaCodecError.unsupported("not an image") }
        let target = fittedSize(width: size.width, height: size.height, maxWidth: maxWidth, maxHeight: maxHeight)
        if target.width == size.width && target.height == size.height { return data }
        let output = try FFmpegOneShot.run(runtime: runtime, label: "snapshot resize", arguments: FFmpegArguments.resizeImage(width: max(1, target.width),
                                                                                                                              height: max(1, target.height)),
                                           input: data, timeout: timeout)
        guard output.count > 4, output.prefix(2) == Data([0xFF, 0xD8]) else { throw MediaCodecError.noFrame }
        return output
    }

    /// Width and height from a JPEG's start-of-frame marker or a PNG's IHDR; nil for anything else.
    static func imageSize(_ data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data.prefix(1 << 20))
        if bytes.count >= 24, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
            let width = Int(bytes[16]) << 24 | Int(bytes[17]) << 16 | Int(bytes[18]) << 8 | Int(bytes[19])
            let height = Int(bytes[20]) << 24 | Int(bytes[21]) << 16 | Int(bytes[22]) << 8 | Int(bytes[23])
            return (width, height)
        }
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var index = 2
        while index + 4 <= bytes.count {
            guard bytes[index] == 0xFF else { index += 1; continue }
            let marker = bytes[index + 1]
            if marker == 0xFF { index += 1; continue }
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) || marker == 0x00 { index += 2; continue }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            // SOF0…SOF15 except DHT (C4), JPG (C8) and DAC (CC).
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                guard index + 9 <= bytes.count else { return nil }
                return (width: Int(bytes[index + 7]) << 8 | Int(bytes[index + 8]), height: Int(bytes[index + 5]) << 8 | Int(bytes[index + 6]))
            }
            if marker == 0xD9 || marker == 0xDA { return nil }
            index += 2 + length
        }
        return nil
    }
}

/// Silent AAC-LC access units (recording audio for cameras without a microphone): encodes digital silence once per
/// (rate, channels) with ffmpeg and repeats a steady-state access unit; every copy decodes on its own to silence.
enum FFmpegSilentAudio {
    private struct Key: Hashable {
        var sampleRate: Int
        var channels: Int
    }

    private static let cache = Mutex<[Key: Data]>([:])

    static func aacLCFrames(runtime: FFmpegRuntime, duration: Duration, sampleRate: Int, channels: Int, startPTS: MediaTime, wallClock: Date) throws -> [EncodedAudioFrame] {
        guard sampleRate > 0, (1...8).contains(channels) else {
            throw MediaCodecError.unsupported("silent AAC at \(sampleRate) Hz × \(channels)")
        }
        let seconds = max(0, duration / .seconds(1))
        let count = Int((seconds * Double(sampleRate) / 1024).rounded(.up))
        guard count > 0 else { return [] }
        let accessUnit = try silentAccessUnit(Key(sampleRate: sampleRate, channels: channels), runtime: runtime)
        let format = AudioFormat.aacLC(sampleRate: sampleRate, channels: channels)
        let start = startPTS.converted(to: Int32(sampleRate)).value
        return (0..<count).map { index in
            EncodedAudioFrame(format: format, data: accessUnit, pts: MediaTime(value: start + Int64(index) * 1024, timescale: Int32(sampleRate)),
                              sampleCount: 1024, wallClock: wallClock.addingTimeInterval(Double(index) * 1024 / Double(sampleRate)))
        }
    }

    private static func silentAccessUnit(_ key: Key, runtime: FFmpegRuntime) throws -> Data {
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let layout = ["mono", "stereo", "3.0", "4.0", "5.0", "5.1", "6.1", "7.1"][key.channels - 1]
        let output = try FFmpegOneShot.run(runtime: runtime, label: "silent audio", arguments: FFmpegArguments.silentAAC(sampleRate: key.sampleRate, channelLayout: layout, seconds: 0.5),
                                           input: nil, timeout: .seconds(15))
        var reader = FLVReader()
        let units = reader.push(output).compactMap { tag -> Data? in
            guard case .frame(let unit)? = FLVAACPacket.parse(tag) else { return nil }
            return unit
        }
        // Past the encoder's priming the output for silence is steady.
        guard units.count >= 4 else { throw MediaCodecError.noFrame }
        let accessUnit = units[units.count / 2]
        cache.withLock { $0[key] = accessUnit }
        return accessUnit
    }
}
