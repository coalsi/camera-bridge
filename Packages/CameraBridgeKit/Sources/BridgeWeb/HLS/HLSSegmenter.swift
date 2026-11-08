import BridgeEngine
import Foundation

/// One finished HLS segment: the `moof` + `mdat` fragments of a run of frames that starts on a key frame.
struct HLSSegment: Sendable, Equatable {
    let number: Int
    /// The init segment this segment plays with.
    let initNumber: Int
    /// Seconds, summed from the frames' own durations.
    let duration: Double
    let data: Data
    /// The first segment after a new init segment: the decoder restarts and the timeline begins again.
    let startsDiscontinuity: Bool
}

/// Cuts the box's live parts (`LiveMP4Remuxer.Part`) into HLS segments at key frames. Pure: no clock, no networking, no transcoding.
///
/// Time is only ever the sum of the parts' durations (a replayed first GOP arrives as a burst, so the wall clock says nothing). A segment ends
/// at the first key frame at least `minimumSegment` ticks after its start; a camera with long key intervals therefore gives long segments, and
/// a segment never ends anywhere else. The first key interval sets the target duration once, as `max(6, ceil(1.5 x interval))`.
struct HLSSegmenter: Sendable {
    private let minimumSegment: Int64
    private let window: Int
    private let maximumBytes: Int

    private(set) var published: [HLSSegment] = []
    private(set) var mediaSequence = 0
    private(set) var discontinuitySequence = 0
    private(set) var targetDuration: Int?
    private(set) var codecs: String?
    private(set) var resolution: (Int, Int)?
    private(set) var bandwidth: Int?

    /// Init segments still wanted, by number.
    private var inits: [Int: Data] = [:]
    private var currentInit: Int?
    private var nextInitNumber = 0
    private var nextSegmentNumber = 0
    private var hasPublished = false
    /// A new init arrived after publishing: the next segment starts a discontinuity.
    private var discontinuityPending = false

    private var open = Data()
    private var openTicks: Int64 = 0
    private var isOpen = false
    /// Ticks since the last key frame, nil before the first one after an init.
    private var sinceKey: Int64?

    init(minimumSegment: Int64 = 180_000, window: Int = 6, maximumBytes: Int = 64 << 20) {
        self.minimumSegment = minimumSegment
        self.window = max(1, window)
        self.maximumBytes = maximumBytes
    }

    mutating func add(_ part: LiveMP4Remuxer.Part) {
        switch part {
        case let .initialization(data, mime, width, height):
            addInit(data, mime: mime, width: width, height: height)
        case let .media(data, keyframe, duration):
            addMedia(data, keyframe: keyframe, duration: duration)
        }
    }

    /// Three segments have been published, enough for a player to start on. AVPlayer starts on the first segment it is given and reloads half a
    /// target after a change, or a whole one once segments are longer than half a target, so a new segment can take up to two and a half segments'
    /// length to reach it: on two it froze (`hls-check`: 2, 4 and 10 s key intervals). It stays true however few the window keeps afterwards: the byte
    /// cap can leave one, and the players polling the playlist by then must not lose it.
    var hasFirstSegments: Bool { mediaSequence + published.count >= 3 }

    func initSegment(_ number: Int) -> Data? { inits[number] }

    func segment(_ number: Int) -> Data? { published.first { $0.number == number }?.data }

    // MARK: - Init segments

    private mutating func addInit(_ data: Data, mime: String, width: Int, height: Int) {
        let number: Int
        if hasPublished {
            number = nextInitNumber
            nextInitNumber += 1
            discontinuityPending = true
        } else {
            // Nothing is out yet: the new init replaces the old one and what was buffered for it goes.
            number = currentInit ?? 0
            nextInitNumber = number + 1
        }
        currentInit = number
        inits[number] = data
        open = Data()
        openTicks = 0
        isOpen = false
        sinceKey = nil
        codecs = Self.codecs(in: mime)
        resolution = (width, height)
        pruneInits()
    }

    private static func codecs(in mime: String) -> String? {
        guard let start = mime.range(of: "codecs=\"") else { return nil }
        let rest = mime[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private mutating func pruneInits() {
        let wanted = Set(published.map(\.initNumber) + [currentInit].compactMap { $0 })
        inits = inits.filter { wanted.contains($0.key) }
    }

    // MARK: - Media

    private mutating func addMedia(_ data: Data, keyframe: Bool, duration: Int64) {
        guard let currentInit else { return }
        if keyframe {
            if let sinceKey, targetDuration == nil {
                let seconds = Double(sinceKey) / 90_000
                targetDuration = max(6, Int((1.5 * seconds).rounded(.up)))
            }
            if isOpen, openTicks >= minimumSegment { finishOpen(initNumber: currentInit) }
            sinceKey = 0
        }
        // Nothing starts but on a key frame.
        guard isOpen || keyframe else { return }
        isOpen = true
        open.append(data)
        openTicks += duration
        if sinceKey != nil { sinceKey! += duration }
        if open.count > maximumBytes {
            // One segment alone is past the cap: drop it and resync at the next key frame, as a discontinuity.
            open = Data()
            openTicks = 0
            isOpen = false
            if hasPublished { discontinuityPending = true }
        } else {
            slide()
        }
    }

    private mutating func finishOpen(initNumber: Int) {
        let seconds = Double(openTicks) / 90_000
        let segment = HLSSegment(
            number: nextSegmentNumber, initNumber: initNumber, duration: seconds, data: open,
            startsDiscontinuity: discontinuityPending)
        nextSegmentNumber += 1
        discontinuityPending = false
        hasPublished = true
        if seconds > 0 {
            let rate = Int((Double(open.count) * 8 / seconds).rounded())
            bandwidth = max(bandwidth ?? 0, rate)
        }
        published.append(segment)
        open = Data()
        openTicks = 0
        isOpen = false
        slide()
    }

    private mutating func slide() {
        func total() -> Int { published.reduce(open.count) { $0 + $1.data.count } }
        while published.count > 1, published.count > window || total() > maximumBytes {
            let gone = published.removeFirst()
            if gone.startsDiscontinuity { discontinuitySequence += 1 }
        }
        mediaSequence = published.first?.number ?? mediaSequence
        pruneInits()
    }
}
