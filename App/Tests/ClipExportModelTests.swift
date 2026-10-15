import BridgeEngine
import Foundation
import Testing

/// Everything a clip export test needs: the model over a fake exporter, a person at the panels, a folder to write in and a clock that moves one
/// second at every reading (so the progress throttle holds nothing back unless a test stops the clock).
@MainActor
private struct Rig {
    /// 2026-10-12 12:00:00 UTC.
    static let start = Date(timeIntervalSince1970: 1_791_806_400)

    let model: ClipExportModel
    let exporter = FakeClipExporter()
    let destinations = FakeClipDestinations()
    let scratch = ScratchDefaults()
    let folder: TemporaryFolder
    let clock: ManualClock
    /// The cameras the model knows by name, in the order of `names`.
    let ids: [UUID]
    /// What the free-space lookup answers (nil: it cannot tell), and the folders it was asked about.
    let free = Guarded<Int64?>(nil)
    let asked = Guarded<[URL]>([])

    init(names: [String] = ["Driveway", "Backyard", "Patio"], step: TimeInterval = 1) throws {
        let ids = names.map { _ in UUID() }
        self.ids = ids
        folder = try TemporaryFolder()
        let clock = ManualClock(step: step)
        self.clock = clock
        let named = Dictionary(uniqueKeysWithValues: zip(ids, names))
        let free = free, asked = asked
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        calendar.locale = Locale(identifier: "en_GB")
        model = ClipExportModel(exporter: exporter, cameraNames: { named }, destinations: destinations,
                                freeSpace: { url in
                                    asked.withLock { $0.append(url) }
                                    return free.value
                                },
                                defaults: scratch.defaults, now: { clock.now() }, calendar: calendar)
    }

    /// The first `count` cameras (all of them by default), `seconds` long from `start`.
    func selection(cameras count: Int? = nil, seconds: TimeInterval = 120) -> ClipSelection {
        ClipSelection(start: Self.start, end: Self.start.addingTimeInterval(seconds), cameras: Array(ids.prefix(count ?? ids.count)))
    }

    /// Every camera has one part of `bytes`.
    func record(_ bytes: Int64 = 4_000, leadIn: TimeInterval = 0) {
        for id in ids { exporter.setFootage(.bytes(bytes, leadIn: leadIn), for: id) }
    }

    /// The name the engine gives the clip of `name` over `selection` (one part).
    func fileName(of name: String, over selection: ClipSelection) -> String {
        ClipFileName.part(cameraName: name, start: selection.range.lowerBound, end: selection.range.upperBound, partIndex: 1, partCount: 1, timeZone: .current)
    }

    /// The folder the model makes for `selection`, inside `parent`.
    func folderName(for selection: ClipSelection) -> String {
        ClipFileName.folder(start: selection.range.lowerBound, timeZone: .current)
    }

    /// The files in a folder the export made, by name.
    func names(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []).sorted()
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct ClipExportModelTests {
    // MARK: Preview

    @Test func theSizeIsTheSumOfTheEnginesExactPlansAndEveryCameraIsAskedOnce() async throws {
        let rig = try Rig()
        rig.exporter.setFootage(.bytes(1_000), for: rig.ids[0])
        rig.exporter.setFootage(.bytes(2_500), for: rig.ids[1])
        rig.exporter.setFootage(.bytes(400), for: rig.ids[2])
        let selection = rig.selection()
        let preview = try #require(await rig.model.preview(selection))
        #expect(preview.byteCount == 3_900)
        #expect(preview.perCamera == [rig.ids[0]: 1_000, rig.ids[1]: 2_500, rig.ids[2]: 400])
        #expect(preview.notes.isEmpty && preview.leadIn == 0 && preview.actualStart == Rig.start)
        #expect(rig.exporter.requests == rig.ids.enumerated().map { offset, id in
            ClipRequest(camera: id, cameraName: ["Driveway", "Backyard", "Patio"][offset], start: Rig.start, end: Rig.start.addingTimeInterval(120), timeZone: .current)
        }, "one plan per camera, in the order of the selection, over the range from the earlier time to the later")
        #expect(rig.model.state == .idle, "a preview is not an export")
    }

    @Test func aRangeChosenBackwardsIsPlannedFromTheEarlierTime() async throws {
        let rig = try Rig()
        rig.record()
        let backwards = ClipSelection(start: Rig.start.addingTimeInterval(120), end: Rig.start, cameras: [rig.ids[0], rig.ids[0]])
        _ = await rig.model.preview(backwards)
        #expect(rig.exporter.requests.count == 1, "a camera that is in the selection twice is planned once")
        #expect(rig.exporter.requests.first?.start == Rig.start && rig.exporter.requests.first?.end == Rig.start.addingTimeInterval(120))
    }

    @Test func thePreviewSaysHowFarBeforeTheChosenStartTheClipsBegin() async throws {
        let rig = try Rig()
        rig.exporter.setFootage(.bytes(1_000, leadIn: 1.35), for: rig.ids[0])
        rig.exporter.setFootage(.bytes(1_000, leadIn: 0.2), for: rig.ids[1])
        let preview = try #require(await rig.model.preview(rig.selection(cameras: 2)))
        #expect(preview.leadIn == 1.35 && preview.actualStart == Rig.start.addingTimeInterval(-1.35), "the earliest first picture, the longest lead-in")
        #expect(preview.notes == ["Starts up to 2 s before your start: clips begin on a key picture."])
    }

    @Test func thePreviewNamesGapsSoundAndTheCamerasWithNothingRecorded() async throws {
        let rig = try Rig()
        let held = ClipGap(from: Rig.start.addingTimeInterval(30), to: Rig.start.addingTimeInterval(32), held: true)
        let skipped = ClipGap(from: Rig.start.addingTimeInterval(300), to: Rig.start.addingTimeInterval(312), held: false)
        rig.exporter.setFootage(FakeClipExporter.Footage(parts: [.init(bytes: 1_000)], gaps: [held], soundOmitted: true), for: rig.ids[0])
        // the second camera has no footage at all
        rig.exporter.setFootage(FakeClipExporter.Footage(parts: [.init(bytes: 2_000)], gaps: [skipped]), for: rig.ids[2])
        let preview = try #require(await rig.model.preview(rig.selection(seconds: 600)))
        #expect(preview.byteCount == 3_000 && Set(preview.perCamera.keys) == [rig.ids[0], rig.ids[2]])
        #expect(preview.notes == [
            "Sound isn't included in clips yet.",
            "The picture freezes for 2 s at 12:00:30: the camera had no recording.",
            "Patio has no recording from 12:05:00 to 12:05:12; the clip skips it.",
            "Backyard had no recording in this time.",
        ])
    }

    @Test func whenNothingWasRecordedTheSentenceIsAloneAndTheSizeIsZero() async throws {
        let rig = try Rig()
        let preview = try #require(await rig.model.preview(rig.selection()))
        #expect(preview.byteCount == 0 && preview.perCamera.isEmpty)
        #expect(preview.notes == ["Nothing was recorded in this time."], "not one line per camera")
        #expect(preview.actualStart == Rig.start && preview.leadIn == 0)
    }

    @Test func underOneSecondAsksForALongerClipWithoutAskingTheEngine() async throws {
        let rig = try Rig()
        rig.record()
        let preview = try #require(await rig.model.preview(rig.selection(seconds: 0.5)))
        #expect(preview.byteCount == 0 && preview.notes == ["Move the end at least 1 second from the start."])
        #expect(rig.exporter.requests.isEmpty, "no plan on every pixel of a drag")
        #expect(await rig.model.preview(ClipSelection(start: Rig.start, end: Rig.start.addingTimeInterval(60), cameras: [])) == nil, "no camera, nothing to plan")
    }

    @Test func anEngineErrorBecomesTheSentenceInsteadOfASize() async throws {
        let rig = try Rig()
        rig.exporter.setPlanError(.tooLong(maxSeconds: 7_200), for: rig.ids[1])
        rig.exporter.setFootage(.bytes(1_000), for: rig.ids[0])
        var preview = try #require(await rig.model.preview(rig.selection(cameras: 2)))
        #expect(preview.byteCount == 0 && preview.notes == ["This clip is too long. The most is 2 hours per camera."])
        rig.exporter.setPlanError(.driveGone, for: rig.ids[1])
        preview = try #require(await rig.model.preview(rig.selection(cameras: 2)))
        #expect(preview.notes == ["The recordings drive went away, so this clip wasn't saved. Check that it is connected, then try again."])
        rig.exporter.setPlanError(.notReady, for: rig.ids[1])
        preview = try #require(await rig.model.preview(rig.selection(cameras: 2)))
        #expect(preview.notes == ["The recordings are still loading. Try again in a moment."])
    }

    @Test func aPreviewThatIsAbandonedAnswersNothing() async throws {
        let rig = try Rig()
        rig.record()
        let stepper = Turnstile()
        rig.exporter.setOnPlan { _ in try await stepper.arrive() }   // the drive is slow
        let selection = rig.selection()
        let asking = Task { await rig.model.preview(selection) }
        await eventually { stepper.reached == 1 }
        asking.cancel()
        #expect(await asking.value == nil, "the next drag asks again; this answer would be stale")
        #expect(rig.model.state == .idle)
    }
}

// MARK: - Where the clips go

extension ClipExportModelTests {
    @Test func oneCameraInOnePartGoesToTheFileTheSavePanelChose() async throws {
        let rig = try Rig()
        rig.record(4_000)
        let selection = rig.selection(cameras: 1)
        rig.destinations.file = rig.folder.file("My driveway clip.mp4")
        await rig.model.export(selection)
        #expect(rig.model.state == .finished(urls: [rig.folder.file("My driveway clip.mp4")], notes: []))
        #expect(rig.destinations.fileRequests.count == 1 && rig.destinations.folderRequests.isEmpty)
        #expect(rig.destinations.fileRequests.first?.suggestedName == rig.fileName(of: "Driveway", over: selection), "the panel is offered the engine's name")
        #expect(rig.folder.names == ["My driveway clip.mp4"], "no part file is left")
        let clip = try #require(rig.folder.bytes(of: "My driveway clip.mp4"))
        #expect(clip.count == 4_000 && clip.first == 1 && clip.last == 4, "the four chunks of the exporter, in order")
        #expect(!rig.model.isBusy)
    }

    @Test func severalCamerasGoIntoANewFolderNamedForTheStartWithOneFileEach() async throws {
        let rig = try Rig()
        rig.record(4_000)
        let selection = rig.selection()
        rig.destinations.folder = rig.folder.url
        await rig.model.export(selection)
        let made = rig.folder.url.appending(path: rig.folderName(for: selection), directoryHint: .isDirectory)
        let expected = ["Driveway", "Backyard", "Patio"].map { made.appending(path: rig.fileName(of: $0, over: selection), directoryHint: .notDirectory) }
        #expect(rig.model.state == .finished(urls: expected, notes: []), "in the order of the selection")
        #expect(rig.folder.names == [rig.folderName(for: selection)], "the chosen folder holds only the new one")
        #expect(rig.names(in: made) == expected.map(\.lastPathComponent).sorted() && rig.destinations.fileRequests.isEmpty)
        #expect(rig.exporter.exportedParts.map(\.camera) == rig.ids, "camera by camera")
    }

    @Test func oneCameraWithTwoPartsAsksForAFolderToo() async throws {
        let rig = try Rig()
        rig.exporter.setFootage(FakeClipExporter.Footage(parts: [.init(bytes: 3_000), .init(bytes: 1_000)]), for: rig.ids[0])
        let selection = rig.selection(cameras: 1)
        rig.destinations.folder = rig.folder.url
        await rig.model.export(selection)
        guard case .finished(let urls, _) = rig.model.state else { Issue.record("expected a result, not \(rig.model.state)"); return }
        #expect(urls.count == 2 && rig.destinations.fileRequests.isEmpty && rig.destinations.folderRequests.count == 1)
        #expect(urls.allSatisfy { $0.deletingLastPathComponent().lastPathComponent == rig.folderName(for: selection) })
        #expect(urls.map { rig.folder.bytes(of: "\(rig.folderName(for: selection))/\($0.lastPathComponent)")?.count } == [3_000, 1_000])
        #expect(urls[0].lastPathComponent.contains("part 1 of 2") && urls[1].lastPathComponent.contains("part 2 of 2"))
        #expect(rig.exporter.exportedParts.map(\.part) == [1, 2])
    }

    @Test func cancelInThePanelDoesNothing() async throws {
        let rig = try Rig()
        rig.record()
        // the Save panel
        rig.destinations.file = nil
        await rig.model.export(rig.selection(cameras: 1))
        #expect(rig.model.state == .idle && rig.destinations.fileRequests.count == 1)
        // the folder panel
        rig.destinations.folder = nil
        await rig.model.export(rig.selection())
        #expect(rig.model.state == .idle && rig.destinations.folderRequests.count == 1)
        #expect(rig.exporter.exports.isEmpty, "nothing was written")
        #expect(rig.folder.names.isEmpty, "not even a folder")
        #expect(rig.scratch.defaults.string(forKey: ClipExportModel.folderKey) == nil, "and the last folder is not changed")
        #expect(rig.asked.value.isEmpty, "the room was not even looked at")
    }

    @Test func theNextPanelOpensInTheLastFolderAndFallsBackWhenItIsGone() async throws {
        let rig = try Rig()
        rig.record()
        let folderPath = rig.folder.url.path(percentEncoded: false)
        rig.destinations.file = rig.folder.file("one.mp4")
        await rig.model.export(rig.selection(cameras: 1))
        #expect(rig.destinations.fileRequests[0].startingIn == nil, "the first time the panel decides: Downloads")
        #expect(rig.scratch.defaults.string(forKey: ClipExportModel.folderKey) == folderPath, "the folder of the file, remembered")

        rig.destinations.file = rig.folder.file("two.mp4")
        await rig.model.export(rig.selection(cameras: 1))
        #expect(rig.destinations.fileRequests[1].startingIn?.path(percentEncoded: false) == folderPath)

        rig.destinations.folder = rig.folder.url
        await rig.model.export(rig.selection())
        #expect(rig.destinations.folderRequests[0]?.path(percentEncoded: false) == folderPath, "the folder panel starts there too")
        #expect(rig.scratch.defaults.string(forKey: ClipExportModel.folderKey) == folderPath, "the chosen folder, not the new one inside it")

        try FileManager.default.removeItem(at: rig.folder.url)
        rig.destinations.file = nil
        await rig.model.export(rig.selection(cameras: 1))
        #expect(rig.destinations.fileRequests[2].startingIn == nil, "a folder that is gone is not offered")
    }

    @Test func aCameraWithNothingRecordedIsSkippedAndNamed() async throws {
        let rig = try Rig()
        rig.exporter.setFootage(.bytes(4_000), for: rig.ids[0])
        rig.exporter.setFootage(.bytes(4_000), for: rig.ids[2])   // Backyard has nothing
        rig.destinations.folder = rig.folder.url
        await rig.model.export(rig.selection())
        guard case .finished(let urls, let notes) = rig.model.state else { Issue.record("expected a result, not \(rig.model.state)"); return }
        #expect(urls.count == 2 && notes == ["Backyard had no recording in this time."])
        #expect(rig.exporter.exportedParts.map(\.camera) == [rig.ids[0], rig.ids[2]])
    }

    @Test func whenEveryCameraIsEmptyNothingIsAskedAndTheSentenceSaysSo() async throws {
        let rig = try Rig()
        await rig.model.export(rig.selection())
        #expect(rig.model.state == .failed("Nothing was recorded in this time."))
        #expect(rig.destinations.fileRequests.isEmpty && rig.destinations.folderRequests.isEmpty && rig.folder.names.isEmpty)
    }

    @Test func anyOtherPlanErrorStopsTheWholeExportBeforeAnythingIsAsked() async throws {
        let rig = try Rig()
        rig.exporter.setFootage(.bytes(4_000), for: rig.ids[0])
        rig.exporter.setPlanError(.tooLong(maxSeconds: 7_200), for: rig.ids[1])
        rig.exporter.setFootage(.bytes(4_000), for: rig.ids[2])
        rig.destinations.folder = rig.folder.url
        await rig.model.export(rig.selection())
        #expect(rig.model.state == .failed("This clip is too long. The most is 2 hours per camera."))
        #expect(rig.destinations.folderRequests.isEmpty && rig.exporter.exports.isEmpty)
    }

    @Test func aClipUnderOneSecondOrWithoutACameraIsRefusedAtOnce() async throws {
        let rig = try Rig()
        rig.record()
        await rig.model.export(rig.selection(seconds: 0.5))
        #expect(rig.model.state == .failed("Move the end at least 1 second from the start."))
        await rig.model.export(ClipSelection(start: Rig.start, end: Rig.start.addingTimeInterval(60), cameras: []))
        #expect(rig.model.state == .failed("Nothing was recorded in this time."))
        #expect(rig.exporter.requests.isEmpty && rig.destinations.fileRequests.isEmpty)
    }

    @Test func aResultStaysUntilItIsDismissedOrReplaced() async throws {
        let rig = try Rig()
        rig.record()
        rig.destinations.file = rig.folder.file("a.mp4")
        await rig.model.export(rig.selection(cameras: 1))
        guard case .finished = rig.model.state else { Issue.record("expected a result, not \(rig.model.state)"); return }
        rig.model.dismissResult()
        #expect(rig.model.state == .idle)
        rig.model.dismissResult()
        #expect(rig.model.state == .idle, "nothing to dismiss")
        await rig.model.export(rig.selection(seconds: 0.5))
        #expect(rig.model.state == .failed("Move the end at least 1 second from the start."))
        rig.destinations.file = rig.folder.file("b.mp4")
        await rig.model.export(rig.selection(cameras: 1))
        guard case .finished = rig.model.state else { Issue.record("a new export replaces the old result, not \(rig.model.state)"); return }
    }
}

// MARK: - Names and room

extension ClipExportModelTests {
    @Test func camerasWithTheSameNameGetNumberedFiles() async throws {
        let rig = try Rig(names: ["Driveway", "Driveway", "Driveway"])
        rig.record(4_000)
        let selection = rig.selection()
        rig.destinations.folder = rig.folder.url
        await rig.model.export(selection)
        guard case .finished(let urls, _) = rig.model.state else { Issue.record("expected a result, not \(rig.model.state)"); return }
        let plain = rig.fileName(of: "Driveway", over: selection), stem = String(plain.dropLast(".mp4".count))
        #expect(urls.map(\.lastPathComponent) == [plain, "\(stem) (2).mp4", "\(stem) (3).mp4"], "none replaces another")
        #expect(Set(urls).count == 3 && urls.allSatisfy { rig.folder.bytes(of: "\(rig.folderName(for: selection))/\($0.lastPathComponent)")?.count == 4_000 })
    }

    @Test func nameLookAlikesThatTheDiskTreatsAsOneAreTold() async throws {
        let rig = try Rig(names: ["Driveway", "DRIVEWAY"])   // the Mac's disks ignore case: these two are one name to them
        rig.record(4_000)
        let selection = rig.selection()
        rig.destinations.folder = rig.folder.url
        await rig.model.export(selection)
        guard case .finished(let urls, _) = rig.model.state else { Issue.record("expected a result, not \(rig.model.state)"); return }
        let made = rig.folder.url.appending(path: rig.folderName(for: selection), directoryHint: .isDirectory)
        #expect(rig.names(in: made).count == 2, "both clips are on the disk: the second one found the first one's name taken")
        #expect(urls.count == 2 && urls[0] != urls[1])
    }

    @Test func illegalCameraNamesNeverMakeAPathOrAnEmptyName() async throws {
        let rig = try Rig(names: ["Front/Door: A", "../Back\\yard", "\u{7}\u{7}"])
        rig.record(4_000)
        let selection = rig.selection()
        rig.destinations.folder = rig.folder.url
        await rig.model.export(selection)
        guard case .finished(let urls, _) = rig.model.state else { Issue.record("expected a result, not \(rig.model.state)"); return }
        let made = rig.folder.url.appending(path: rig.folderName(for: selection), directoryHint: .isDirectory)
        #expect(urls.count == 3 && Set(urls.map(\.lastPathComponent)).count == 3)
        for url in urls {
            let name = url.lastPathComponent
            #expect(url.deletingLastPathComponent().path(percentEncoded: false) == made.path(percentEncoded: false), "\(name) is a file directly in the new folder")
            #expect(!name.contains("/") && !name.contains(":") && !name.hasPrefix(".") && name.hasSuffix(".mp4") && name.count > ".mp4".count, "\(name)")
        }
        #expect(rig.names(in: rig.folder.url) == [rig.folderName(for: selection)], "nothing escaped into the chosen folder")
    }

    @Test func whateverNameTheEngineGivesTheFileStaysInsideTheFolder() async throws {
        let rig = try Rig()
        rig.exporter.setFootage(FakeClipExporter.Footage(parts: [.init(bytes: 4_000)], fileNames: ["../../evil.mp4"]), for: rig.ids[0])
        rig.exporter.setFootage(FakeClipExporter.Footage(parts: [.init(bytes: 4_000)], fileNames: [""]), for: rig.ids[1])
        rig.exporter.setFootage(FakeClipExporter.Footage(parts: [.init(bytes: 4_000)], fileNames: ["a:b/c\\d.mp4"]), for: rig.ids[2])
        let selection = rig.selection()
        rig.destinations.folder = rig.folder.url
        await rig.model.export(selection)
        guard case .finished(let urls, _) = rig.model.state else { Issue.record("expected a result, not \(rig.model.state)"); return }
        #expect(urls.map(\.lastPathComponent) == ["-..-evil.mp4", "Clip.mp4", "a-b-c-d.mp4"])
        let made = rig.folder.url.appending(path: rig.folderName(for: selection), directoryHint: .isDirectory)
        #expect(urls.allSatisfy { $0.deletingLastPathComponent().path(percentEncoded: false) == made.path(percentEncoded: false) })
        #expect(rig.folder.names == [rig.folderName(for: selection)])
        #expect(ClipExportModel.safeName("...") == "Clip.mp4" && ClipExportModel.safeName("  .hidden  ") == "hidden")
    }

    @Test func aFolderOfTheSameNameIsNeverReusedOrTouched() async throws {
        let rig = try Rig()
        rig.record(4_000)
        let selection = rig.selection(cameras: 2)
        let taken = rig.folder.file(rig.folderName(for: selection))
        try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: false)
        try Data("mine".utf8).write(to: taken.appending(path: "keep.txt", directoryHint: .notDirectory))
        rig.destinations.folder = rig.folder.url
        await rig.model.export(selection)
        guard case .finished(let urls, _) = rig.model.state else { Issue.record("expected a result, not \(rig.model.state)"); return }
        #expect(urls.allSatisfy { $0.deletingLastPathComponent().lastPathComponent == "\(rig.folderName(for: selection)) (2)" })
        #expect(rig.names(in: taken) == ["keep.txt"], "the folder that was there is as it was")
        #expect(rig.folder.names == [rig.folderName(for: selection), "\(rig.folderName(for: selection)) (2)"])
        // and a third time, the next number
        await rig.model.export(selection)
        guard case .finished(let more, _) = rig.model.state else { Issue.record("expected a result, not \(rig.model.state)"); return }
        #expect(more.allSatisfy { $0.deletingLastPathComponent().lastPathComponent == "\(rig.folderName(for: selection)) (3)" })
    }

    @Test func aNameThatIsTakenGetsTheNextNumberAndAPartFileCountsAsTaken() throws {
        let folder = try TemporaryFolder()
        #expect(ClipExportModel.availableURL(for: "a.mp4", in: folder.url) == folder.file("a.mp4"))
        try Data().write(to: folder.file("a.mp4"))
        try Data().write(to: folder.file("a (2).mp4.part"))
        #expect(ClipExportModel.availableURL(for: "a.mp4", in: folder.url) == folder.file("a (3).mp4"), "(2) is a part file that another export is writing")
        #expect(ClipExportModel.availableURL(for: "b.mp4", in: folder.url) == folder.file("b.mp4"))
        #expect(ClipExportModel.availableURL(for: "no extension", in: folder.url) == folder.file("no extension"))
        let first = try ClipExportModel.makeFolder(named: "Clips", in: folder.url)
        let second = try ClipExportModel.makeFolder(named: "Clips", in: folder.url)
        #expect(first.lastPathComponent == "Clips" && second.lastPathComponent == "Clips (2)")
        let error = #expect(throws: ClipFileError.self) { try ClipExportModel.makeFolder(named: "x", in: folder.file("missing")) }
        #expect(error?.reason == .cannotWrite)
    }

    // MARK: Room

    @Test func aDestinationThatIsTooSmallIsRefusedBeforeAnythingIsWritten() async throws {
        let rig = try Rig()
        rig.record(4_000)   // three cameras: 12,000 bytes, and one percent more is 12,120
        rig.destinations.folder = rig.folder.url
        rig.free.value = 12_119
        await rig.model.export(rig.selection())
        let needed = RecordingSettings.bytes(12_000), free = RecordingSettings.bytes(12_119)
        #expect(rig.model.state == .failed("There isn't enough room on that drive. The clips need about \(needed) and \(free) is free."))
        #expect(rig.folder.names.isEmpty, "no folder, no part file")
        #expect(rig.exporter.exports.isEmpty && rig.asked.value.map { $0.path(percentEncoded: false) } == [rig.folder.url.path(percentEncoded: false)],
                "the room is asked about the folder that was chosen")
    }

    @Test func exactlyTheSizeAndOnePercentIsRoomEnoughAndNotKnowingIsNotARefusal() async throws {
        let rig = try Rig()
        rig.record(4_000)
        rig.destinations.folder = rig.folder.url
        rig.free.value = 12_120
        await rig.model.export(rig.selection())
        guard case .finished = rig.model.state else { Issue.record("expected a result, not \(rig.model.state)"); return }
        rig.free.value = nil   // the volume does not say
        await rig.model.export(rig.selection())
        guard case .finished = rig.model.state else { Issue.record("expected a result, not \(rig.model.state)"); return }
        rig.free.value = 0
        rig.destinations.file = rig.folder.file("x.mp4")
        await rig.model.export(rig.selection(cameras: 1))
        guard case .failed = rig.model.state else { Issue.record("a full drive is a refusal, not \(rig.model.state)"); return }
    }

    @Test func theRealLookupReadsTheVolumeOfAFolder() throws {
        let folder = try TemporaryFolder()
        let free = try #require(ClipExportModel.availableSpace(at: folder.url))
        #expect(free > 0)
        #expect(ClipExportModel.availableSpace(at: folder.file("nothing-here")) == nil, "a path that is not there has no volume to ask")
    }
}

// MARK: - Progress

extension ClipExportModelTests {
    /// Runs the export with the exporter held after every chunk it writes. Returns what the model showed at each of those moments, once the follower of
    /// the exporter's progress had run; `between(n)` is called after the n-th look and before the exporter goes on. The export has ended when this returns.
    private func watch(_ rig: Rig, _ selection: ClipSelection, between: (Int) -> Void = { _ in }) async -> [ClipExportModel.State] {
        let stepper = Turnstile()
        let finished = Guarded(false)
        rig.exporter.setAfterChunk { _ in try await stepper.arrive() }
        let running = Task {
            await rig.model.export(selection)
            finished.value = true
        }
        var states: [ClipExportModel.State] = []
        while true {
            let seen = states.count
            await eventually { stepper.reached > seen || finished.value }
            guard stepper.reached > seen else { break }
            await settle()
            states.append(rig.model.state)
            between(states.count)
            stepper.release()
        }
        await running.value
        return states
    }

    private func progress(of states: [ClipExportModel.State]) -> [Double] {
        states.map { state in
            guard case .exporting(let value, _) = state else { return -1 }
            return value
        }
    }

    private func labels(of states: [ClipExportModel.State]) -> [String] {
        states.map { state in
            guard case .exporting(_, let label) = state else { return "" }
            return label
        }
    }

    @Test func progressNeverGoesBackAndTheLabelNamesTheFileAndTheCamera() async throws {
        let rig = try Rig()
        rig.record(4_000)   // three files of 4,000 bytes in two chunks each: 12,000 in all
        rig.exporter.setChunks(2)
        // The exporter's second report of the first file is a smaller number than its first one.
        let first = rig.ids[0]
        rig.exporter.setReported { written, _, point in point.camera == first && point.chunk == 2 ? 500 : written }
        rig.destinations.folder = rig.folder.url
        let states = await watch(rig, rig.selection())
        let shown = progress(of: states)
        let expected = [2_000.0 / 12_000, 2_000.0 / 12_000, 6_000.0 / 12_000, 8_000.0 / 12_000, 10_000.0 / 12_000, 1]
        #expect(shown.count == 6 && zip(shown, expected).allSatisfy { abs($0 - $1) < 1e-9 }, "\(shown)")
        #expect(zip(shown, shown.dropFirst()).allSatisfy { $0 <= $1 }, "never backwards: \(shown)")
        #expect(labels(of: states) == ["Saving 1 of 3: Driveway", "Saving 1 of 3: Driveway", "Saving 2 of 3: Backyard", "Saving 2 of 3: Backyard",
                                       "Saving 3 of 3: Patio", "Saving 3 of 3: Patio"])
        guard case .finished(let urls, _) = rig.model.state else { Issue.record("expected a result, not \(rig.model.state)"); return }
        #expect(urls.count == 3)
    }

    @Test func aProgressReportBeyondThePartIsHeldAtTheEndOfThePart() async throws {
        let rig = try Rig()
        rig.record(4_000)
        rig.exporter.setChunks(2)
        rig.exporter.setReported { written, _, _ in written * 10 }   // a writer that counts header bytes the plan did not
        rig.destinations.file = rig.folder.file("a.mp4")
        let states = await watch(rig, rig.selection(cameras: 1))
        #expect(progress(of: states) == [1, 1], "never more than the whole")
    }

    @Test func theBarMovesAtMostEveryTenthOfASecond() async throws {
        let rig = try Rig(step: 0)   // the clock stands still until the test moves it
        rig.record(4_000)
        rig.destinations.file = rig.folder.file("a.mp4")
        let states = await watch(rig, rig.selection(cameras: 1)) { look in if look == 1 { rig.clock.advance(by: 0.2) } }
        // Chunks of 1,000 of 4,000. The first report came at the very moment the label was shown and was held back; the second came 0.2 s later and
        // showed; the third and fourth came at that same moment and were held back.
        #expect(progress(of: states) == [0, 0.5, 0.5, 0.5])
        guard case .finished = rig.model.state else { Issue.record("expected a result, not \(rig.model.state)"); return }
    }
}

// MARK: - Cancel, failure, one at a time

extension ClipExportModelTests {
    /// Starts an export and returns once the exporter has written `chunk` chunks of the file it is on, still holding it there.
    private func start(_ rig: Rig, _ selection: ClipSelection, holdingAfter chunk: Int, at stepper: Turnstile = Turnstile()) async -> (running: Task<Void, Never>, stepper: Turnstile) {
        rig.exporter.setAfterChunk { point in if point.chunk == chunk { try await stepper.arrive() } }
        let running = Task { await rig.model.export(selection) }
        await eventually { stepper.reached == 1 }
        await settle()
        return (running, stepper)
    }

    @Test func cancelRemovesThePartialFileAndLeavesNothing() async throws {
        let rig = try Rig()
        rig.record(4_000)
        rig.destinations.file = rig.folder.file("a.mp4")
        let (running, _) = await start(rig, rig.selection(cameras: 1), holdingAfter: 2)
        #expect(rig.folder.names == ["a.mp4.part"] && rig.folder.bytes(of: "a.mp4.part")?.count == 2_000, "half a clip, under its part name")
        guard case .exporting = rig.model.state else { Issue.record("expected an export, not \(rig.model.state)"); return }
        rig.model.cancel()
        await running.value
        #expect(rig.model.state == .idle, "a cancel is not a failure and shows no alert")
        #expect(rig.folder.names.isEmpty, "no partial file, no clip")
    }

    @Test func cancelAndWaitReturnsOnlyWhenThePartialFileIsGone() async throws {
        let rig = try Rig()
        rig.record(4_000)
        rig.destinations.file = rig.folder.file("a.mp4")
        let (running, _) = await start(rig, rig.selection(cameras: 1), holdingAfter: 2)
        #expect(rig.folder.names == ["a.mp4.part"])
        await rig.model.cancelAndWait()   // what quitting the app does
        #expect(rig.model.state == .idle && rig.folder.names.isEmpty && !rig.model.isBusy)
        await running.value
        await rig.model.cancelAndWait()   // and with nothing running
        rig.model.cancel()
        #expect(rig.model.state == .idle)
    }

    @Test func cancelInTheMiddleOfSeveralCamerasKeepsTheFinishedClipsAndRemovesTheRest() async throws {
        let rig = try Rig()
        rig.record(4_000)
        let selection = rig.selection()
        rig.destinations.folder = rig.folder.url
        let stepper = Turnstile()
        rig.exporter.setAfterChunk { point in if point.camera == rig.ids[1] && point.chunk == 2 { try await stepper.arrive() } }
        let running = Task { await rig.model.export(selection) }
        await eventually { stepper.reached == 1 }
        let made = rig.folder.url.appending(path: rig.folderName(for: selection), directoryHint: .isDirectory)
        #expect(rig.names(in: made).count == 2 && rig.names(in: made).contains { $0.hasSuffix(".part") }, "one whole clip and the second one half written")
        rig.model.cancel()
        await running.value
        #expect(rig.model.state == .idle)
        #expect(rig.names(in: made) == [rig.fileName(of: "Driveway", over: selection)], "the whole clip stays, the partial one is gone, the third never began")
        #expect(rig.exporter.exportedParts.map(\.camera) == [rig.ids[0], rig.ids[1]])
    }

    @Test func cancelBeforeTheFirstChunkAlsoRemovesTheFolderItMade() async throws {
        let rig = try Rig()
        rig.record(4_000)
        rig.destinations.folder = rig.folder.url
        let (running, _) = await start(rig, rig.selection(), holdingAfter: 1)
        #expect(rig.folder.names.count == 1, "the new folder")
        rig.model.cancel()
        await running.value
        #expect(rig.model.state == .idle && rig.folder.names.isEmpty, "an empty folder this export made is removed")
    }

    @Test func cancelWhileThePanelIsOpenWritesNothing() async throws {
        let rig = try Rig()
        rig.record(4_000)
        let panel = Latch()
        rig.destinations.hold = panel
        rig.destinations.file = rig.folder.file("a.mp4")
        let running = Task { await rig.model.export(rig.selection(cameras: 1)) }
        await eventually { !rig.destinations.fileRequests.isEmpty }
        #expect(rig.model.state == .planning && rig.model.isBusy, "the sheet is up")
        rig.model.cancel()
        panel.open()   // the person closes the sheet with a file chosen
        await running.value
        #expect(rig.model.state == .idle && rig.folder.names.isEmpty && rig.exporter.exports.isEmpty)
    }

    @Test func aCancelledPlanEndsTheExportQuietly() async throws {
        let rig = try Rig()
        rig.record(4_000)
        let stepper = Turnstile()
        rig.exporter.setOnPlan { _ in try await stepper.arrive() }
        let running = Task { await rig.model.export(rig.selection()) }
        await eventually { stepper.reached == 1 }
        #expect(rig.model.state == .planning)
        rig.model.cancel()
        await running.value
        #expect(rig.model.state == .idle && rig.destinations.folderRequests.isEmpty)
    }

    @Test func theDriveGoingAwayMidExportRemovesThePartialFileAndSaysSo() async throws {
        let rig = try Rig()
        rig.record(4_000)
        rig.destinations.file = rig.folder.file("a.mp4")
        rig.exporter.setAfterChunk { point in if point.chunk == 3 { throw ClipError.driveGone } }   // after three of four chunks
        await rig.model.export(rig.selection(cameras: 1))
        #expect(rig.model.state == .failed("The recordings drive went away, so this clip wasn't saved. Check that it is connected, then try again."))
        #expect(rig.exporter.exports.count == 3, "it had written most of the clip")
        #expect(rig.folder.names.isEmpty, "and no file, partial or not, looks like a clip")
    }

    @Test func aFailureOnTheSecondCameraKeepsTheFirstClipAndTheModelReadyForAnotherTry() async throws {
        let rig = try Rig()
        rig.record(4_000)
        let selection = rig.selection(cameras: 2)
        rig.destinations.folder = rig.folder.url
        let damaged = Rig.start.addingTimeInterval(61)
        let second = rig.ids[1]
        rig.exporter.setAfterChunk { point in if point.camera == second && point.chunk == 2 { throw ClipError.damaged(at: damaged) } }
        await rig.model.export(selection)
        #expect(rig.model.state == .failed("A recording couldn't be read at 12:01:01, so this clip wasn't saved."))
        let made = rig.folder.url.appending(path: rig.folderName(for: selection), directoryHint: .isDirectory)
        #expect(rig.names(in: made) == [rig.fileName(of: "Driveway", over: selection)], "the whole clip is there, the half one is not")
        rig.model.dismissResult()
        #expect(rig.model.state == .idle)

        // The selection is the caller's value and it is as it was: the same one exports now that the drive is back.
        rig.exporter.setAfterChunk { _ in }
        await rig.model.export(selection)
        guard case .finished(let urls, _) = rig.model.state else { Issue.record("expected a result, not \(rig.model.state)"); return }
        #expect(urls.count == 2 && urls[0].deletingLastPathComponent().lastPathComponent == "\(rig.folderName(for: selection)) (2)", "a new folder, the old one untouched")
    }

    @Test func aFailureOnTheFirstCameraAlsoRemovesTheFolderItMade() async throws {
        let rig = try Rig()
        rig.record(4_000)
        rig.destinations.folder = rig.folder.url
        rig.exporter.setAfterChunk { _ in throw ClipError.driveGone }
        await rig.model.export(rig.selection())
        guard case .failed = rig.model.state else { Issue.record("expected a failure, not \(rig.model.state)"); return }
        #expect(rig.folder.names.isEmpty)
    }

    @Test func theSentenceOfASinkFailureIsShownAsItIs() async throws {
        let rig = try Rig()
        rig.record(4_000)
        rig.destinations.file = rig.folder.file("a.mp4")
        rig.exporter.setAfterChunk { point in if point.chunk == 2 { throw ClipFileError(reason: .noRoom) } }
        await rig.model.export(rig.selection(cameras: 1))
        #expect(rig.model.state == .failed("There isn't enough room on the destination drive."))
        rig.exporter.setAfterChunk { point in if point.chunk == 2 { throw ClipError.sink(String(describing: ClipFileError(reason: .cannotWrite))) } }   // the engine wrapped it
        await rig.model.export(rig.selection(cameras: 1))
        #expect(rig.model.state == .failed("Camera Bridge can't write to that folder."))
        rig.exporter.setAfterChunk { point in if point.chunk == 2 { struct Odd: Error {}; throw Odd() } }
        await rig.model.export(rig.selection(cameras: 1))
        #expect(rig.model.state == .failed(ErrorText.unexpected), "an error nobody mapped does not print its type")
        #expect(rig.folder.names.isEmpty)
    }

    @Test func aFolderThatCannotBeMadeIsReportedBeforeAnythingIsWritten() async throws {
        let rig = try Rig()
        rig.record(4_000)
        rig.destinations.folder = rig.folder.file("not-there")   // the person typed a path that is not a folder
        await rig.model.export(rig.selection())
        #expect(rig.model.state == .failed("Camera Bridge can't write to that folder.") && rig.exporter.exports.isEmpty)
    }

    @Test func aSecondExportWhileOneRunsIsIgnoredAndTheRunningOneIsUntouched() async throws {
        let rig = try Rig()
        rig.record(4_000)
        rig.destinations.file = rig.folder.file("a.mp4")
        let selection = rig.selection(cameras: 1)
        let (running, turnstile) = await start(rig, selection, holdingAfter: 2)
        let before = rig.model.state
        guard case .exporting = before else { Issue.record("expected an export, not \(before)"); return }

        // The second ones come back at once. (Run apart, so that a model that made them wait fails here and does not hang the test.)
        let returned = Guarded(0)
        let others = Task {
            await rig.model.export(rig.selection(cameras: 2))
            returned.withLock { $0 += 1 }
            await rig.model.export(selection)
            returned.withLock { $0 += 1 }
        }
        await eventually { returned.value == 2 }
        #expect(returned.value == 2, "both calls came back without waiting for the running export")
        #expect(rig.model.state == before, "the running export's progress and label")
        #expect(rig.exporter.requests.count == 1 && rig.destinations.fileRequests.count == 1 && rig.destinations.folderRequests.isEmpty,
                "the second ones were not even planned")
        #expect(rig.model.isBusy)

        turnstile.releaseAll()
        await others.value
        await running.value
        #expect(rig.model.state == .finished(urls: [rig.folder.file("a.mp4")], notes: []), "the first export finished as if nothing had happened")
        #expect(rig.folder.names == ["a.mp4"])
    }

    @Test func theStateReadsPlanningWhileTheSheetIsUpAndTheCallerKeepsItsSelection() async throws {
        let rig = try Rig()
        rig.record(4_000)
        let panel = Latch()
        rig.destinations.hold = panel
        rig.destinations.file = rig.folder.file("a.mp4")
        let selection = rig.selection(cameras: 1)
        let before = selection
        let running = Task { await rig.model.export(selection) }
        await eventually { !rig.destinations.fileRequests.isEmpty }
        #expect(rig.model.state == .planning)
        panel.open()
        await running.value
        guard case .finished = rig.model.state else { Issue.record("expected a result, not \(rig.model.state)"); return }
        #expect(selection == before, "the model took the selection by value and gave nothing back")
    }
}

// MARK: - The surface the views build on

extension ClipExportModelTests {
    /// Calls every member of the shared contract between the models and the views in the form it is declared in, so a rename or a changed label is a
    /// compile error here and not in the views that use them.
    @Test func theModelsHaveTheDeclaredSurface() async throws {
        let id = UUID(), later = Rig.start.addingTimeInterval(90)
        var selection = ClipSelection(start: Rig.start, end: later, cameras: [id])
        let range: ClosedRange<Date> = selection.range
        let duration: TimeInterval = selection.duration
        let exportable: Bool = selection.isExportable
        selection = selection.clamped(oldest: Rig.start, newest: later).toggling(UUID())
        let summary: String = selection.summary(calendar: Calendar(identifier: .gregorian))
        #expect(range == Rig.start...later && duration == 90 && exportable && ClipSelection.minimumDuration == 1)
        #expect(selection.cameras.count == 2 && !summary.isEmpty)

        let scratch = ScratchDefaults()
        let destinations: any ClipDestinationPicking = FakeClipDestinations()
        let model = ClipExportModel(exporter: FakeClipExporter(), cameraNames: { [id: "Driveway"] }, destinations: destinations,
                                    freeSpace: { _ in nil }, defaults: scratch.defaults, now: { Date() })
        let states: [ClipExportModel.State] = [.idle, .planning, .exporting(progress: 0.5, label: "Saving 1 of 2: Driveway"), .finished(urls: [], notes: []), .failed("x")]
        let state: ClipExportModel.State = model.state
        #expect(state == states[0] && states.count == 5 && ClipExportModel.folderKey == "clipExportFolder" && !model.isBusy)

        let preview: ClipPreview? = await model.preview(selection)
        let shape = ClipPreview(byteCount: 1, actualStart: Rig.start, leadIn: 0.5, notes: ["a"], perCamera: [id: 1])
        #expect(preview?.byteCount == 0, "the double has no footage")
        #expect(shape.byteCount == 1 && shape.actualStart == Rig.start && shape.leadIn == 0.5 && shape.notes == ["a"] && shape.perCamera == [id: 1])
        await model.export(selection)
        model.cancel()
        await model.cancelAndWait()
        model.dismissResult()
        #expect(model.state == .idle)
        _ = ClipExportModel.availableSpace(at: URL(filePath: "/"))
    }
}
