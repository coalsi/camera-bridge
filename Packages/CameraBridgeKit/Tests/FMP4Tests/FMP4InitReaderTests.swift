import Foundation
import MediaCore
import Testing
@testable import FMP4

/// `FMP4InitReader`: the codec configuration and track ids that `FMP4Muxer.initializationSegment()` wrote, read back.
@Suite struct FMP4InitReaderTests {
    @Test func h264RoundTripsTheFormatInLiveOrder() throws {
        let format = try Golden.h264Format
        let initialization = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil)).initializationSegment()
        let info = try FMP4InitReader.parse(initialization)
        #expect(info.video == format, "[SPS, PPS], size, profile, compatibility and level as the hub's format")
        #expect(info.video.parameterSets == [Golden.h264SPS, Golden.h264PPS])
        #expect(info.videoTimescale == 90_000 && info.nalLengthSize == 4 && info.videoTrackID == 1)
        #expect(info.audio == nil && info.audioTrackID == nil)
        #expect(info.byteCount == initialization.count)
    }

    @Test func hevcRoundTripsTheFormatInLiveOrder() throws {
        let format = try Golden.hevcFormat
        let initialization = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil)).initializationSegment()
        let info = try FMP4InitReader.parse(initialization)
        #expect(info.video == format, "[VPS, SPS, PPS]")
        #expect(info.video.codec == .hevc && info.nalLengthSize == 4 && info.videoTimescale == 90_000)
    }

    @Test func aacRoundTripsWithItsTrackAndRate() throws {
        let format = try Golden.h264Format
        for (rate, channels) in [(32_000, 1), (48_000, 2), (8_000, 1), (16_000, 1)] {
            let aac = AudioFormat.aacLC(sampleRate: rate, channels: channels)
            let initialization = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: aac)).initializationSegment()
            let info = try FMP4InitReader.parse(initialization)
            #expect(info.audio == aac, "\(rate) Hz / \(channels) ch")
            #expect(info.audioTrackID == 2 && info.videoTrackID == 1)
        }
    }

    @Test func aWholeFileOrAPrefixOfOneGivesTheSameInfo() throws {
        let format = try Golden.h264Format
        let fixture = try ReaderFixture.make(format: format, frames: ReaderFixture.frames(format, count: 30, gop: 10), cutEvery: 10)
        let info = try FMP4InitReader.parse(fixture.initialization)
        #expect(try FMP4InitReader.parse(fixture.file) == info)
        #expect(try FMP4InitReader.parse(fixture.file.prefix(fixture.initialization.count + 5)) == info, "torn right after the init segment")
        #expect(info.byteCount == fixture.initialization.count)
    }

    @Test func aCustomVideoTimescaleIsReported() throws {
        let format = try Golden.h264Format
        let initialization = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: nil, videoTimescale: 30_000)).initializationSegment()
        #expect(try FMP4InitReader.parse(initialization).videoTimescale == 30_000)
    }

    @Test func aTornInitializationSegmentThrowsAtEveryLength() throws {
        let format = try Golden.h264Format
        let aac = AudioFormat.aacLC(sampleRate: 32_000, channels: 1)
        let initialization = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: aac)).initializationSegment()
        for length in 0..<initialization.count {
            #expect(throws: FMP4Error.self) { _ = try FMP4InitReader.parse(initialization.prefix(length)) }
        }
        #expect(throws: FMP4Error.self) { _ = try FMP4InitReader.parse(Data()) }
    }

    @Test func flippedBitsNeverTrap() throws {
        let format = try Golden.hevcFormat
        let aac = AudioFormat.aacLC(sampleRate: 44_100, channels: 2)
        let initialization = try FMP4Muxer(configuration: FMP4Configuration(video: format, audio: aac)).initializationSegment()
        var generator = SeededGenerator(seed: 0xBEEF)
        var parsed = 0
        for _ in 0..<20_000 {
            var damaged = initialization
            for _ in 0..<Int.random(in: 1...4, using: &generator) {
                damaged[Int.random(in: 0..<damaged.count, using: &generator)] ^= UInt8(1) << UInt8.random(in: 0..<8, using: &generator)
            }
            do {
                _ = try FMP4InitReader.parse(damaged)
                parsed += 1
            } catch is FMP4Error {
                continue
            }
        }
        #expect(parsed > 0)
    }
}
