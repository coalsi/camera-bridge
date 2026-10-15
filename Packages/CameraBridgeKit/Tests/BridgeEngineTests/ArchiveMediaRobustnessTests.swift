import BridgeSupport
import FMP4
import Foundation
import MediaCore
import Testing
@testable import BridgeEngine

/// SplitMix64: a deterministic generator, so any input a fuzz test builds can be rebuilt from its seed.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Damaged input to `ArchiveMedia`: cut short, bit-flipped and with box sizes and sample counts that claim far more than there is. Whatever the
/// bytes, a call either throws `ArchiveMedia.Failure` or returns a result that is itself consistent; it never traps, never throws another error and
/// never allocates in proportion to a number it read.
@Suite(.timeLimit(.minutes(3))) struct ArchiveMediaRobustnessTests {
    private struct Inputs {
        var initWithSound: Data
        var initVideoOnly: Data
        var fragmentWithSound: Data
        var fragmentVideoOnly: Data
    }

    /// Small enough for every prefix and many mutations: 12 pictures in two fragments, one second of sound in the first.
    private static func makeInputs() throws -> Inputs {
        let frames = ArchiveMediaFixtures.syntheticFrames(ArchiveMediaFixtures.tapoFormat, count: 12, keyEvery: 6)
        let withSound = try ArchiveMediaFixtures.mux(frames, audio: ArchiveMediaFixtures.syntheticAudio(seconds: 1), audioFormat: ArchiveMediaFixtures.aac, cutEvery: 6)
        let videoOnly = try ArchiveMediaFixtures.mux(frames, cutEvery: 6)
        return Inputs(initWithSound: withSound.initSegment, initVideoOnly: videoOnly.initSegment,
                      fragmentWithSound: withSound.fragments[0], fragmentVideoOnly: videoOnly.fragments[0])
    }

    /// Runs `body`; success hands the result to `check`, a `Failure` is the expected outcome and anything else is a failure of the test.
    private func settle<T>(_ label: @autoclosure () -> String, _ body: () throws -> T, check: (T) -> Bool) {
        do {
            let result = try body()
            #expect(check(result), "\(label()): a result that is not consistent")
        } catch is ArchiveMedia.Failure {
        } catch {
            Issue.record("\(label()): threw \(error), not an ArchiveMedia.Failure")
        }
    }

    private func initIsConsistent(_ video: ArchiveMedia.VideoInit) -> Bool {
        guard let boxes = try? MP4BoxReader.parse(video.data), boxes.map(\.type) == ["ftyp", "moov"],
              Set(boxes[1].children.map(\.type)).isSubset(of: ["mvhd", "trak", "mvex"]), boxes[1].children.filter({ $0.type == "trak" }).count == 1
        else { return false }
        return video.mime.hasPrefix("video/mp4; codecs=\"") && video.mime.hasSuffix("\"") && video.width > 0 && video.height > 0
    }

    @Test func everyPrefixOfAnInitSegmentIsMalformed() throws {
        let inputs = try Self.makeInputs()
        for data in [inputs.initWithSound, inputs.initVideoOnly] {
            for length in 0..<data.count {
                #expect(throws: ArchiveMedia.Failure.self, "init cut to \(length)") { _ = try ArchiveMedia.videoInit(data.prefix(length)) }
                #expect(throws: ArchiveMedia.Failure.self, "init cut to \(length)") { _ = try ArchiveMedia.mime(forInit: data.prefix(length)) }
            }
        }
    }

    @Test func everyPrefixOfAFragmentIsMalformed() throws {
        let inputs = try Self.makeInputs()
        for data in [inputs.fragmentWithSound, inputs.fragmentVideoOnly] {
            for length in 0..<data.count {
                #expect(throws: ArchiveMedia.Failure.self, "fragment cut to \(length)") { _ = try ArchiveMedia.videoSegment(data.prefix(length)) }
            }
        }
    }

    @Test func everySuffixOfAFragmentIsMalformed() throws {
        let inputs = try Self.makeInputs()
        for data in [inputs.fragmentWithSound, inputs.fragmentVideoOnly] {
            for start in 1..<data.count where start != 32 {          // dropping exactly the prft is the one cut that is a valid fragment
                #expect(throws: ArchiveMedia.Failure.self, "fragment from \(start)") { _ = try ArchiveMedia.videoSegment(data.suffix(from: start)) }
            }
        }
    }

    @Test func flippedBitsNeverTrapAndNeverGiveAnInconsistentResult() throws {
        let inputs = try Self.makeInputs()
        var random = SeededGenerator(seed: 0x7A5C_0003)
        for round in 0..<4_000 {
            for (kind, source) in [("init", inputs.initWithSound), ("init", inputs.initVideoOnly)] {
                var data = source
                for _ in 0..<Int.random(in: 1...4, using: &random) {
                    data[Int.random(in: 0..<data.count, using: &random)] ^= UInt8(1) << UInt8.random(in: 0..<8, using: &random)
                }
                settle("\(kind) round \(round)", { try ArchiveMedia.videoInit(data) }, check: initIsConsistent)
                settle("\(kind) round \(round)", { try ArchiveMedia.mime(forInit: data) }, check: { $0.hasPrefix("video/mp4; codecs=\"") })
            }
            for source in [inputs.fragmentWithSound, inputs.fragmentVideoOnly] {
                var data = source
                for _ in 0..<Int.random(in: 1...4, using: &random) {
                    data[Int.random(in: 0..<data.count, using: &random)] ^= UInt8(1) << UInt8.random(in: 0..<8, using: &random)
                }
                settle("fragment round \(round)", { try ArchiveMedia.videoSegment(data) }, check: ArchiveMediaBytes.isConsistentSegment)
            }
        }
    }

    /// Every byte of the headers (box sizes, versions, flags, counts, offsets) set to values that sit on the edges.
    @Test func everyHeaderByteSetToAnEdgeValueNeverTraps() throws {
        let inputs = try Self.makeInputs()
        for (name, data, isInit) in [("init", inputs.initWithSound, true), ("fragment", inputs.fragmentWithSound, false)] {
            let headerBytes = try ArchiveMediaBytes.boxes(in: data).filter { !["mdat"].contains($0.box.type) }.flatMap { entry in
                (entry.box.offset..<min(entry.box.offset + min(entry.box.size, 48), data.count)).map { ($0, entry.path) }
            }
            for (offset, path) in headerBytes {
                for value in [UInt8(0x00), 0x01, 0x7F, 0x80, 0xFF] where data[offset] != value {
                    var damaged = data
                    damaged[offset] = value
                    if isInit {
                        settle("\(name) \(path) byte \(offset) = \(value)", { try ArchiveMedia.videoInit(damaged) }, check: initIsConsistent)
                    } else {
                        settle("\(name) \(path) byte \(offset) = \(value)", { try ArchiveMedia.videoSegment(damaged) }, check: ArchiveMediaBytes.isConsistentSegment)
                    }
                }
            }
        }
    }

    /// Box sizes that claim more than the file holds: past the parent, past the end, 2 GiB, 4 GiB - 1, the 64-bit form with 2^63 and 2^64 - 1.
    @Test func oversizedBoxesAreMalformedAndNeverAllocate() throws {
        let inputs = try Self.makeInputs()
        let claims: [UInt32] = [0xFFFF_FFFF, 0x8000_0000, 0x7FFF_FFFF, 0x0100_0000, 0x0001_0000]
        for (data, isInit) in [(inputs.initWithSound, true), (inputs.fragmentWithSound, false)] {
            for entry in try ArchiveMediaBytes.boxes(in: data) {
                for claim in claims where claim > UInt32(entry.box.size) {
                    let damaged = ArchiveMediaBytes.patching(data, at: entry.box.offset, ArchiveMediaBytes.u32(claim))
                    if isInit {
                        #expect(throws: ArchiveMedia.Failure.self, "\(entry.path) claims \(claim)") { _ = try ArchiveMedia.videoInit(damaged) }
                    } else {
                        #expect(throws: ArchiveMedia.Failure.self, "\(entry.path) claims \(claim)") { _ = try ArchiveMedia.videoSegment(damaged) }
                    }
                }
                for large in [UInt64(1) << 63, UInt64.max, UInt64(UInt32.max) + 1] {
                    var header = ArchiveMediaBytes.u32(1) + Array(entry.box.type.utf8)
                    for shift in stride(from: 56, through: 0, by: -8) { header.append(UInt8(truncatingIfNeeded: large >> UInt64(shift))) }
                    let damaged = data.prefix(entry.box.offset) + header + data.suffix(from: min(entry.box.offset + 8, data.count))
                    if isInit {
                        settle("\(entry.path) 64-bit \(large)", { try ArchiveMedia.videoInit(Data(damaged)) }, check: initIsConsistent)
                    } else {
                        settle("\(entry.path) 64-bit \(large)", { try ArchiveMedia.videoSegment(Data(damaged)) }, check: ArchiveMediaBytes.isConsistentSegment)
                    }
                }
            }
        }
    }

    /// A trun that claims 2^32 - 1 samples in a few bytes must be refused before anything is sized by the count.
    @Test func aSampleCountThatTheBoxCannotHoldIsMalformed() throws {
        let inputs = try Self.makeInputs()
        let stored = inputs.fragmentWithSound
        let real = ArchiveMediaBytes.readU32(stored, at: try ArchiveMediaBytes.trun(in: stored, track: 1).payloadOffset + 4)
        for track: UInt32 in [1, 2] {
            for count in [UInt32.max, 0x8000_0000, 0x4000_0000, 0x2000_0000, 0x0100_0000, real &+ 1, real &- 1, 0] {
                let trun = try ArchiveMediaBytes.trun(in: stored, track: track)
                let current = ArchiveMediaBytes.readU32(stored, at: trun.payloadOffset + 4)
                guard count != current else { continue }
                let damaged = try ArchiveMediaBytes.settingTrunField(stored, track: track, at: 4, to: count)
                #expect(throws: ArchiveMedia.Failure.self, "track \(track) claims \(count) samples") { _ = try ArchiveMedia.videoSegment(damaged) }
            }
        }
    }

    /// Sample sizes of 2^32 - 1 each add up to far more than the mdat; the sum must neither wrap nor trap.
    @Test func sampleSizesThatAddUpToMoreThanTheMdatAreMalformed() throws {
        let inputs = try Self.makeInputs()
        let stored = inputs.fragmentWithSound
        let trun = try ArchiveMediaBytes.trun(in: stored, track: 1)
        let count = Int(ArchiveMediaBytes.readU32(stored, at: trun.payloadOffset + 4))
        var damaged = stored
        for index in 0..<count { damaged = ArchiveMediaBytes.patching(damaged, at: trun.payloadOffset + 12 + index * 12 + 4, ArchiveMediaBytes.u32(UInt32.max)) }
        #expect(throws: ArchiveMedia.Failure.self) { _ = try ArchiveMedia.videoSegment(damaged) }
    }

    /// A data offset on the edges of Int32 (the field is signed) is refused, not added to a box position without a check.
    @Test func dataOffsetsOnTheEdgesAreRefused() throws {
        let inputs = try Self.makeInputs()
        let stored = inputs.fragmentWithSound
        for offset: UInt32 in [0, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF, 0xFFFF_FFF8] {
            for track: UInt32 in [1, 2] {
                let damaged = try ArchiveMediaBytes.settingTrunField(stored, track: track, at: 8, to: offset)
                #expect(throws: ArchiveMedia.Failure.self, "track \(track) data offset \(offset)") { _ = try ArchiveMedia.videoSegment(damaged) }
            }
        }
    }

    /// The `Failure` text is for a log: printable ASCII, short, and free of the bytes that were read.
    @Test func failureMessagesArePrintableAndShort() throws {
        let inputs = try Self.makeInputs()
        var random = SeededGenerator(seed: 0x7A5C_0004)
        var seen = Set<String>()
        for _ in 0..<3_000 {
            var data = inputs.fragmentWithSound
            for _ in 0..<Int.random(in: 1...6, using: &random) { data[Int.random(in: 0..<data.count, using: &random)] = UInt8.random(in: 0...255, using: &random) }
            do { _ = try ArchiveMedia.videoSegment(data) } catch let ArchiveMedia.Failure.malformed(message), let ArchiveMedia.Failure.unsupported(message) {
                seen.insert(message)
            } catch {}
        }
        #expect(seen.count > 5)
        for message in seen {
            #expect(message.count <= 160 && message.unicodeScalars.allSatisfy { (0x20..<0x7F).contains($0.value) }, "\(message)")
        }
    }
}
