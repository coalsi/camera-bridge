import BridgeEngine
import BridgeSupport
import Foundation
import Observation

/// What the clip bar shows before Export, from the engine's plan of every chosen camera: the exact size, where the clip really starts and the
/// sentences under the bar. When nothing can be saved (under a second, nothing recorded, too long, the drive gone) `byteCount` is 0 and `notes`
/// holds the one sentence that says why.
nonisolated struct ClipPreview: Equatable, Sendable {
    var byteCount: Int64
    /// The first picture of the earliest clip: clips begin on the key picture at or before the chosen start.
    var actualStart: Date
    /// The most any camera's clip starts before the chosen start.
    var leadIn: TimeInterval
    var notes: [String]
    /// The exact size of each camera's clip (cameras with nothing recorded are not in it).
    var perCamera: [UUID: Int64]
}

/// Plans and saves the clip a person chose: asks the engine for the exact size, asks where to put the file or files, checks the room, writes camera
/// by camera through `FileClipSink`, and tells the clip bar how far it has got. One export at a time; it belongs to `AppModel` so it outlives the
/// views, and it is cancelled (and its partial file removed) when the app quits.
@MainActor @Observable
final class ClipExportModel {
    enum State: Equatable {
        case idle
        /// Asking the engine for the plans and the person for the destination.
        case planning
        /// `progress` is 0...1 over all the files of the export and never goes back; `label` is "Saving 2 of 5: Driveway".
        case exporting(progress: Double, label: String)
        /// The files saved, in order, and the cameras that had nothing recorded (named, with their sentence).
        case finished(urls: [URL], notes: [String])
        /// One sentence. The selection is the caller's and is untouched: the person can try again.
        case failed(String)
    }

    /// The `UserDefaults` key of the folder the last clip went to (a path).
    static let folderKey = "clipExportFolder"
    /// Progress reaches the screen at most this often, in seconds.
    static let progressInterval: TimeInterval = 0.1

    private(set) var state: State = .idle

    /// A clip is being planned, asked for or written.
    var isBusy: Bool {
        switch state {
        case .planning, .exporting: true
        case .idle, .finished, .failed: false
        }
    }

    @ObservationIgnored private let exporter: any ClipExporting
    @ObservationIgnored private let cameraNames: @MainActor @Sendable () -> [UUID: String]
    @ObservationIgnored private let destinations: any ClipDestinationPicking
    @ObservationIgnored private let freeSpace: @Sendable (URL) -> Int64?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let log = Log(category: "Clips")
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var lastProgressShown = Date.distantPast

    /// `cameraNames` answers the names people know the cameras by, each time it is asked (on the main actor, where the engine's camera list is);
    /// `freeSpace` the bytes free on the volume of a folder (nil: unknown); `now` is the clock the progress throttle reads; `calendar` writes the times in
    /// the notes.
    init(exporter: any ClipExporting, cameraNames: @escaping @MainActor @Sendable () -> [UUID: String], destinations: any ClipDestinationPicking,
         freeSpace: @escaping @Sendable (URL) -> Int64?, defaults: UserDefaults, now: @escaping @Sendable () -> Date, calendar: Calendar = .current) {
        self.exporter = exporter
        self.cameraNames = cameraNames
        self.destinations = destinations
        self.freeSpace = freeSpace
        self.defaults = defaults
        self.now = now
        self.calendar = calendar
    }

    // MARK: Preview

    /// The engine's plan of every camera in `selection`, for the clip bar. Reads fragment headers only, so it is cheap enough for every pause of a
    /// drag. nil when the plan was abandoned (the caller's task was cancelled) or the selection has no camera.
    func preview(_ selection: ClipSelection) async -> ClipPreview? {
        let cameras = Self.unique(selection.cameras)
        guard !cameras.isEmpty else { return nil }
        let range = selection.range
        func problem(_ sentence: String) -> ClipPreview {
            ClipPreview(byteCount: 0, actualStart: range.lowerBound, leadIn: 0, notes: [sentence], perCamera: [:])
        }
        guard selection.duration >= ClipSelection.minimumDuration else { return problem(ClipSentences.underOneSecond) }
        do {
            let planning = try await plan(cameras, over: range)
            guard !planning.planned.isEmpty else { return problem(ClipSentences.nothingRecorded) }
            let firstParts = planning.planned.compactMap { $0.plan.parts.first }
            let leadIn = firstParts.map(\.leadIn).max() ?? 0
            return ClipPreview(byteCount: planning.planned.reduce(0) { $0 + $1.plan.byteCount },
                               actualStart: firstParts.map(\.start).min() ?? range.lowerBound, leadIn: leadIn,
                               notes: ClipSentences.notes(planned: planning.planned, empty: planning.empty, leadIn: leadIn, calendar: calendar),
                               perCamera: Dictionary(uniqueKeysWithValues: planning.planned.map { ($0.camera, $0.plan.byteCount) }))
        } catch {
            if ClipSentences.isCancellation(error) || Task.isCancelled { return nil }
            return problem(ClipSentences.sentence(for: error, calendar: calendar))
        }
    }

    private struct Planning {
        var planned: [PlannedClip] = []
        /// The names of the cameras with nothing recorded in the range.
        var empty: [String] = []
    }

    /// Plans the cameras one after another (one drive, shared with the recorder). A camera with nothing recorded is set aside; any other error ends it.
    private func plan(_ cameras: [UUID], over range: ClosedRange<Date>) async throws -> Planning {
        let names = cameraNames()
        var planning = Planning()
        for camera in cameras {
            try Task.checkCancellation()
            let name = names[camera] ?? String(localized: "Camera")
            let request = ClipRequest(camera: camera, cameraName: name, start: range.lowerBound, end: range.upperBound, timeZone: .current)
            do {
                planning.planned.append(PlannedClip(camera: camera, name: name, plan: try await exporter.plan(request)))
            } catch ClipError.nothingRecorded {
                planning.empty.append(name)
            }
        }
        return planning
    }

    // MARK: Export

    /// Saves `selection`: plans it, asks where, checks the room and writes the files. Returns when the export has ended; `state` says how. A second
    /// call while one runs does nothing.
    func export(_ selection: ClipSelection) async {
        guard runner == nil else { return }
        state = .planning
        let task = Task { await run(selection) }
        runner = task
        await task.value
    }

    /// Stops the export that is running: the file being written is removed, and the clips already finished stay. `state` returns to `idle` when it has
    /// stopped. While the person is still choosing the destination, the panel stays up until they dismiss it and nothing is written.
    func cancel() {
        runner?.cancel()
    }

    /// `cancel()`, and returns when the export has stopped and its partial file is gone (the app is quitting).
    func cancelAndWait() async {
        guard let task = runner else { return }
        task.cancel()
        await task.value
    }

    /// Clears a finished or failed result from the bar.
    func dismissResult() {
        switch state {
        case .finished, .failed: state = .idle
        case .idle, .planning, .exporting: break
        }
    }

    private struct Job {
        var camera: String
        var plan: ClipPlan
        /// 1-based, as `ClipExporting.export` counts.
        var part: Int
        var fileName: String
        var bytes: Int64
    }

    private func run(_ selection: ClipSelection) async {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Saving a clip")
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            runner = nil
        }
        let range = selection.range
        guard selection.isExportable else {
            state = .failed(selection.cameras.isEmpty ? ClipSentences.nothingRecorded : ClipSentences.underOneSecond)
            return
        }

        // The engine's plan of every camera: the exact bytes, the parts and their names.
        let planning: Planning
        do {
            planning = try await plan(Self.unique(selection.cameras), over: range)
        } catch {
            conclude(error)
            return
        }
        guard !planning.planned.isEmpty else {
            state = .failed(ClipSentences.nothingRecorded)
            return
        }

        // Where: a Save panel for one file, a folder for several.
        let isOneFile = planning.planned.count == 1 && planning.planned[0].plan.parts.count == 1
        let startFolder = rememberedFolder()
        let chosenFile: URL?
        let parent: URL
        if isOneFile {
            guard let file = await destinations.pickFile(suggestedName: planning.planned[0].plan.parts[0].fileName, startingIn: startFolder) else {
                state = .idle
                return
            }
            chosenFile = file
            parent = file.deletingLastPathComponent()
        } else {
            guard let folder = await destinations.pickFolder(startingIn: startFolder) else {
                state = .idle
                return
            }
            chosenFile = nil
            parent = folder
        }
        defaults.set(parent.path(percentEncoded: false), forKey: Self.folderKey)
        if Task.isCancelled {
            state = .idle
            return
        }

        // Room: the plan's size is exact, so the check is too, with a margin of one percent.
        let total = planning.planned.reduce(Int64(0)) { $0 + $1.plan.byteCount }
        if let free = freeSpace(parent), free < total + total / 100 {
            state = .failed(ClipSentences.notEnoughRoom(needed: total, free: free))
            return
        }

        // Several files go into a new folder named for the start of the clip.
        var createdFolder: URL?
        let directory: URL
        if chosenFile == nil {
            do {
                directory = try Self.makeFolder(named: ClipFileName.folder(start: range.lowerBound, timeZone: .current), in: parent)
            } catch {
                conclude(error)
                return
            }
            createdFolder = directory
        } else {
            directory = parent
        }
        func stop(with error: any Error) {
            Self.removeIfEmpty(createdFolder)
            conclude(error)
        }

        // The files, camera by camera and part by part.
        let jobs = Self.jobs(for: planning.planned)
        let names = ClipFileName.unique(jobs.map(\.fileName))
        var urls: [URL] = []
        var done: Int64 = 0
        for (offset, job) in jobs.enumerated() {
            if Task.isCancelled {
                stop(with: CancellationError())
                return
            }
            show(progress: total > 0 ? Double(done) / Double(total) : 0, label: ClipSentences.saving(offset + 1, of: jobs.count, camera: job.camera))
            let destination = chosenFile ?? Self.availableURL(for: names[offset], in: directory)
            let sink: FileClipSink
            do {
                sink = try FileClipSink(destination: destination)
            } catch {
                stop(with: error)
                return
            }
            do {
                try await write(job, to: sink, bytesBefore: done, of: total)
                urls.append(try sink.finish())
            } catch {
                sink.discard()
                stop(with: error)
                return
            }
            done += job.bytes
        }
        state = .finished(urls: urls, notes: planning.empty.map(ClipSentences.emptyCamera))
    }

    /// Writes one part through `sink` and follows its progress. The engine reports from its own task; the updates travel through a stream that keeps
    /// only the newest, so the main actor sees them in order and never has a backlog.
    private func write(_ job: Job, to sink: FileClipSink, bytesBefore: Int64, of total: Int64) async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: Int64.self, bufferingPolicy: .bufferingNewest(1))
        let follower = Task { [weak self] in
            for await bytes in stream { self?.advance(to: bytesBefore + min(bytes, job.bytes), of: total) }
        }
        do {
            try await exporter.export(job.plan, part: job.part, to: sink, progress: { continuation.yield($0) })
        } catch {
            continuation.finish()
            await follower.value
            throw error
        }
        continuation.finish()
        await follower.value
    }

    /// Shows the label of the file that is starting, with the fraction the finished files make: never less than what `advance` has shown, because it
    /// stops at the end of each file's bytes.
    private func show(progress: Double, label: String) {
        state = .exporting(progress: min(1, max(0, progress)), label: label)
        lastProgressShown = now()
    }

    /// Moves the bar to `bytes` of `total`: forward only, and at most `progressInterval` apart.
    private func advance(to bytes: Int64, of total: Int64) {
        guard total > 0, case .exporting(let shown, let label) = state else { return }
        let fraction = min(1, Double(bytes) / Double(total))
        guard fraction > shown else { return }
        let moment = now()
        let elapsed = moment.timeIntervalSince(lastProgressShown)
        guard elapsed >= Self.progressInterval || elapsed < 0 else { return }
        lastProgressShown = moment
        state = .exporting(progress: fraction, label: label)
    }

    /// Ends the export on `error`: a cancellation is not a failure and returns to `idle`; anything else is one sentence.
    private func conclude(_ error: any Error) {
        if Task.isCancelled || ClipSentences.isCancellation(error) {
            state = .idle
            return
        }
        log.warning("The clip could not be saved: \(ErrorText.logDescription(error))")
        state = .failed(ClipSentences.sentence(for: error, calendar: calendar))
    }

    // MARK: Destination

    /// The folder of the last clip when it is still there; nil the first time (the panel then opens in Downloads, never in the recordings folder).
    private func rememberedFolder() -> URL? {
        guard let path = defaults.string(forKey: Self.folderKey) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func unique(_ cameras: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return cameras.filter { seen.insert($0).inserted }
    }

    private static func jobs(for planned: [PlannedClip]) -> [Job] {
        planned.flatMap { clip in
            clip.plan.parts.enumerated().map { offset, part in
                Job(camera: clip.name, plan: clip.plan, part: offset + 1, fileName: safeName(part.fileName), bytes: part.byteCount)
            }
        }
    }

    /// The engine's file name as one path component whatever it holds: `/`, `\`, `:` and control characters become `-`, leading dots and the edges'
    /// white space go, and nothing left is "Clip.mp4".
    static func safeName(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F || scalar == "/" || scalar == "\\" || scalar == ":" {
                scalars.append("-")
            } else {
                scalars.append(scalar)
            }
        }
        var result = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix(".") { result.removeFirst() }
        return result.isEmpty ? "Clip.mp4" : result
    }

    /// Creates the folder `name` inside `parent`, or "name (2)", "name (3)" … when that is taken, and returns it. Throws `ClipFileError`.
    static func makeFolder(named name: String, in parent: URL) throws -> URL {
        let manager = FileManager.default
        for number in 1...999 {
            let candidate = parent.appending(path: number == 1 ? name : "\(name) (\(number))", directoryHint: .isDirectory)
            if manager.fileExists(atPath: candidate.path(percentEncoded: false)) { continue }
            do {
                try manager.createDirectory(at: candidate, withIntermediateDirectories: false)
                return candidate
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue   // taken between the check and the create
            } catch {
                throw ClipFileError(reason: .cannotWrite)
            }
        }
        throw ClipFileError(reason: .cannotWrite)
    }

    /// `name` in `directory`, or "stem (2).ext", "stem (3).ext" … when a file of that name (or its part file) is already there.
    static func availableURL(for name: String, in directory: URL) -> URL {
        let manager = FileManager.default
        let ext = URL(fileURLWithPath: name).pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        for number in 1...9_999 {
            let candidate = number == 1 ? name : (ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)")
            let url = directory.appending(path: candidate, directoryHint: .notDirectory)
            let path = url.path(percentEncoded: false)
            if !manager.fileExists(atPath: path), !manager.fileExists(atPath: path + ".part") { return url }
        }
        return directory.appending(path: "\(UUID().uuidString).\(ext.isEmpty ? "mp4" : ext)", directoryHint: .notDirectory)
    }

    /// Removes a folder this export made when nothing was saved in it.
    private static func removeIfEmpty(_ folder: URL?) {
        guard let folder, let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)), contents.isEmpty else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// The bytes free on the volume of `url`, counting space the system gives back when it is needed (what Finder shows); nil when the volume does not say.
    nonisolated static func availableSpace(at url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let important = values.volumeAvailableCapacityForImportantUsage
        let plain = values.volumeAvailableCapacity.map { Int64($0) }
        guard important != nil || plain != nil else { return nil }
        return max(important ?? 0, plain ?? 0)
    }
}
