import BridgeEngine
import CoreGraphics
import Foundation
import Observation

/// What to ask `ArchiveReading.activity` for so the waveform fills the viewport: one bin per two points, the range aligned to a multiple of the
/// bin length (panning then never shimmers) and one bin longer than the window so its right edge is covered.
nonisolated struct ActivityRequest: Equatable, Sendable {
    var range: Range<Date>
    var binCount: Int
    var binDuration: TimeInterval
    /// `range.lowerBound - viewport.start` in seconds, 0 or negative: where the first bin starts relative to the viewport.
    var offset: TimeInterval

    static let columnWidth: CGFloat = 2

    static func make(viewport: TimelineViewport, width: CGFloat) -> ActivityRequest? {
        guard width >= columnWidth, viewport.duration > 0 else { return nil }
        let visibleBins = max(1, Int((width / columnWidth).rounded(.down)))
        let binDuration = viewport.duration / Double(visibleBins)
        let alignedStart = (viewport.start.timeIntervalSinceReferenceDate / binDuration).rounded(.down) * binDuration
        let lower = Date(timeIntervalSinceReferenceDate: alignedStart)
        let binCount = visibleBins + 1
        return ActivityRequest(range: lower..<lower.addingTimeInterval(Double(binCount) * binDuration), binCount: binCount, binDuration: binDuration,
                               offset: lower.timeIntervalSince(viewport.start))
    }
}

/// The waveform's data for one or more cameras: asks the archive for the viewport's activity (one question in flight, the latest wins), asks again
/// when the viewport changes, and at most every `minimumInterval` seconds when the catalog changed (a new fragment, a deletion) or the answer was incomplete.
@MainActor @Observable final class TimelineActivityModel {
    private(set) var columns = WaveformColumns.empty
    /// The request `columns` answers (nil before the first answer).
    private(set) var answered: ActivityRequest?
    /// Every camera had enough footage (30 minutes) for a typical level: the dashed normal line and the amber bars mean something.
    private(set) var normalIsKnown = false
    private(set) var isComplete = true

    @ObservationIgnored private let archive: any ArchiveReading
    @ObservationIgnored private let uptime: @Sendable () -> TimeInterval
    @ObservationIgnored private let minimumInterval: TimeInterval
    @ObservationIgnored private var cameras: [UUID] = []
    @ObservationIgnored private var wanted: ActivityRequest?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var lastCatalogVersion = -1
    @ObservationIgnored private var lastAnswerUptime: TimeInterval = -.infinity

    init(archive: any ArchiveReading, uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         minimumInterval: TimeInterval = 2) {
        self.archive = archive
        self.uptime = uptime
        self.minimumInterval = minimumInterval
    }

    /// The cameras whose activity is combined (one for the camera page, the page's cameras for the NVR page).
    func setCameras(_ ids: [UUID]) {
        guard ids != cameras else { return }
        cameras = ids
        reload()
    }

    /// The viewport or the width changed.
    func update(viewport: TimelineViewport, width: CGFloat) {
        let request = ActivityRequest.make(viewport: viewport, width: width)
        guard request != wanted else { return }
        wanted = request
        reload()
    }

    /// The page's refresh loop calls this (about twice a second) with what the archive says now: a changed catalog, or an answer that was
    /// incomplete, asks again, but not more often than `minimumInterval`.
    func catalogMayHaveChanged() {
        let version = archive.catalogVersion
        guard version != lastCatalogVersion || !isComplete, uptime() - lastAnswerUptime >= minimumInterval else { return }
        reload()
    }

    func stop() {
        task?.cancel()
        task = nil
        dirty = false
    }

    private func reload() {
        guard wanted != nil, !cameras.isEmpty else {
            if wanted != nil { columns = .empty; answered = wanted }
            return
        }
        guard task == nil else {
            dirty = true   // one question at a time; the answer to this one is already out of date
            return
        }
        task = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        defer { task = nil }
        while !Task.isCancelled {
            dirty = false
            guard let request = wanted else { return }
            let ids = cameras, archive = archive
            let version = archive.catalogVersion
            let activities = await withTaskGroup(of: (Int, ArchiveActivity).self) { group in
                for (index, id) in ids.enumerated() {
                    group.addTask { (index, await archive.activity(camera: id, range: request.range, binCount: request.binCount)) }
                }
                var answers: [(Int, ArchiveActivity)] = []
                for await answer in group { answers.append(answer) }
                return answers.sorted { $0.0 < $1.0 }.map(\.1)
            }
            if Task.isCancelled { return }
            if dirty { continue }   // the viewport or the cameras changed meanwhile: only the newest answer is worth showing
            columns = WaveformColumns.combine(activities)
            answered = request
            normalIsKnown = !activities.isEmpty && activities.allSatisfy { $0.typical != nil }
            isComplete = activities.allSatisfy(\.isComplete)
            lastCatalogVersion = version
            lastAnswerUptime = uptime()
            return
        }
    }
}
