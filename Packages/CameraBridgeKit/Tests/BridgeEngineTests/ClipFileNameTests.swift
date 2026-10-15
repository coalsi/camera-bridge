import Foundation
import Testing
@testable import BridgeEngine

/// The names of exported clips (export-clip design, section 4; the plan's review focus 3): the shape, the clock of the request's time zone and
/// midnight, the camera name's sanitising and length, non-ASCII names, duplicates, and the folder and ZIP names.
@Suite struct ClipFileNameTests {
    private let utc = TimeZone.gmt
    /// What `named()` makes of "Driveway" without arguments: 2026-10-12 14:02:10 UTC to 14:05:42 UTC.
    private let tail = " 2026-10-12 14.02.10 to 14.05.42.mp4"

    /// A zone by its identifier; a machine without the zone data fails the test, it does not crash the run.
    private func zone(_ identifier: String) throws -> TimeZone {
        try #require(TimeZone(identifier: identifier), "this machine has no time zone \(identifier)")
    }

    private func named(_ camera: String = "Driveway", start: TimeInterval = 1_791_813_730, end: TimeInterval = 1_791_813_942, part: Int = 1, of count: Int = 1,
                       in zone: TimeZone? = nil) -> String {
        ClipFileName.part(cameraName: camera, start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end), partIndex: part, partCount: count,
                          timeZone: zone ?? utc)
    }

    @Test func aClipIsNamedAfterItsCameraAndTheClockOfTheRequestsZone() throws {
        let phoenix = try zone("America/Phoenix"), berlin = try zone("Europe/Berlin")
        #expect(named() == "Driveway" + tail)
        #expect(named(in: phoenix) == "Driveway 2026-10-12 07.02.10 to 07.05.42.mp4")
        #expect(named(in: berlin) == "Driveway 2026-10-12 16.02.10 to 16.05.42.mp4")
        #expect(named(in: TimeZone(secondsFromGMT: -420 * 60)!) == named(in: phoenix), "tz=-420, as the box's web routes pass it, is Phoenix")
        // A second is never rounded up: the name says when the first picture was, not a moment later.
        #expect(named(start: 1_791_813_730.9, end: 1_791_813_942.999) == "Driveway" + tail)
        // Only ASCII digits, whatever the machine's language or calendar.
        #expect(named().unicodeScalars.allSatisfy { $0.isASCII })
    }

    @Test func theEndCarriesItsDateWhenTheClipCrossesMidnightInTheRequestsZone() throws {
        let phoenix = try zone("America/Phoenix")
        // 23:58:30 UTC to 00:01:05 UTC the next day.
        #expect(named("Garage", start: 1_791_849_510, end: 1_791_849_665) == "Garage 2026-10-12 23.58.30 to 2026-10-13 00.01.05.mp4")
        // The same two instants do not cross midnight in Phoenix.
        #expect(named("Garage", start: 1_791_849_510, end: 1_791_849_665, in: phoenix) == "Garage 2026-10-12 16.58.30 to 17.01.05.mp4")
        // And two instants that do not cross it in UTC do in a zone seven hours east of it.
        #expect(named("Garage", start: 1_791_824_310, end: 1_791_824_465) == "Garage 2026-10-12 16.58.30 to 17.01.05.mp4")
        #expect(named("Garage", start: 1_791_824_310, end: 1_791_824_465, in: TimeZone(secondsFromGMT: 7 * 3_600)!) == "Garage 2026-10-12 23.58.30 to 2026-10-13 00.01.05.mp4")
        // A clip that ends exactly at midnight ends on the next day; at the turn of a year the year shows.
        #expect(named("Garage", start: 1_791_849_540, end: 1_791_849_600) == "Garage 2026-10-12 23.59.00 to 2026-10-13 00.00.00.mp4")
        #expect(named("Garage", start: 1_798_761_590, end: 1_798_761_620) == "Garage 2026-12-31 23.59.50 to 2027-01-01 00.00.20.mp4")
    }

    @Test func aDaylightSavingDayReadsTheClockOfTheDay() throws {
        let berlin = try zone("Europe/Berlin"), phoenix = try zone("America/Phoenix"), losAngeles = try zone("America/Los_Angeles")
        // Europe/Berlin, 2026-10-25: at 03:00 the clocks go back to 02:00, so 02:30 happens twice and an hour of video reads 02:30 to 02:30.
        #expect(named("Hof", start: 1_792_888_200, end: 1_792_891_800, in: berlin) == "Hof 2026-10-25 02.30.00 to 02.30.00.mp4")
        // 2026-03-29: at 02:00 they go forward to 03:00, so an hour of video reads 01:30 to 03:30.
        #expect(named("Hof", start: 1_774_744_200, end: 1_774_747_800, in: berlin) == "Hof 2026-03-29 01.30.00 to 03.30.00.mp4")
        // The hour before midnight of the night of the change.
        #expect(named("Hof", start: 1_792_877_400, end: 1_792_881_000, in: berlin) == "Hof 2026-10-24 23.30.00 to 2026-10-25 00.30.00.mp4")
        // America/Phoenix keeps no daylight saving time: on the days America/Los_Angeles skips 02:00 to 03:00 (2026-03-08) and repeats 01:00 (2026-11-01)
        // its clock just runs on.
        #expect(named("Porch", start: 1_772_962_200, end: 1_772_965_800, in: phoenix) == "Porch 2026-03-08 02.30.00 to 03.30.00.mp4")
        #expect(named("Porch", start: 1_772_962_200, end: 1_772_965_800, in: losAngeles) == "Porch 2026-03-08 01.30.00 to 03.30.00.mp4")
        #expect(named("Porch", start: 1_793_521_800, end: 1_793_525_400, in: phoenix) == "Porch 2026-11-01 01.30.00 to 02.30.00.mp4")
        #expect(named("Porch", start: 1_793_521_800, end: 1_793_525_400, in: losAngeles) == "Porch 2026-11-01 01.30.00 to 01.30.00.mp4")
    }

    @Test func aBoxWithoutAZoneNamesFilesInUTC() throws {
        // The box's own zone is UTC unless someone set one, and `tz=0` is the same: every way of saying UTC makes the same name.
        let zones = [try zone("UTC"), TimeZone.gmt, TimeZone(secondsFromGMT: 0)!]
        #expect(Set(zones.map { named(in: $0) }) == ["Driveway" + tail])
        let start = Date(timeIntervalSince1970: 1_791_813_730)
        #expect(Set(zones.map { ClipFileName.folder(start: start, timeZone: $0) }) == ["Clips 2026-10-12 14.02.10"])
        #expect(Set(zones.map { ClipFileName.archive(start: start, timeZone: $0) }) == ["Camera Bridge clips 2026-10-12 14.02.10.zip"])
    }

    @Test func aClipOfSeveralPartsSaysWhichPartItIs() {
        #expect(named(part: 2, of: 3) == "Driveway 2026-10-12 14.02.10 to 14.05.42 (part 2 of 3).mp4")
        #expect(named(part: 1, of: 2) == "Driveway 2026-10-12 14.02.10 to 14.05.42 (part 1 of 2).mp4")
        #expect(named(part: 1, of: 1) == "Driveway" + tail, "one part: no suffix")
        #expect(named("Garage", start: 1_791_849_510, end: 1_791_849_665, part: 2, of: 2) == "Garage 2026-10-12 23.58.30 to 2026-10-13 00.01.05 (part 2 of 2).mp4")
    }

    @Test func illegalCharactersBecomeDashesAndTheNameIsNeverEmpty() {
        let cases: [(String, String)] = [
            ("Front/Door: A", "Front-Door- A"), ("a\\b", "a-b"), ("a:b", "a-b"), ("a\nb", "a-b"), ("a\u{0}b", "a-b"), ("a\u{7F}b", "a-b"), ("a/../b", "a-..-b"),
            ("..hidden", "hidden"), ("name. ", "name"), ("  padded  ", "padded"), ("/", "-"), ("Front Door (2)", "Front Door (2)"),
            ("", "Camera"), ("   ", "Camera"), (".", "Camera"), ("...", "Camera"),
        ]
        for (input, expected) in cases { #expect(named(input) == expected + tail, "\(input.debugDescription)") }
        let nasty = ["", " ", "..", "/", "\\", ":", "a/b\\c:d", "\u{1}\u{2}", "\n", "../../etc/passwd", "C:\\Windows", "\u{7F}", String(repeating: "/", count: 100)]
        for camera in nasty {
            let file = named(camera)
            #expect(!file.contains("/") && !file.contains("\\") && !file.contains(":"), "\(camera.debugDescription): no path separator")
            #expect(file.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }, "\(camera.debugDescription): no control character")
            #expect(!file.hasPrefix(".") && !file.hasPrefix(" ") && file.hasSuffix(tail), "\(camera.debugDescription): a name, then the times")
        }
    }

    @Test func aLongNameIsCutToSixtyScalarsAndToWhatAFileSystemAllows() {
        let sixty = String(repeating: "é", count: 60)
        #expect(named(sixty) == sixty + tail)
        #expect(named(String(repeating: "é", count: 61)) == sixty + tail)
        #expect(named(String(repeating: "日", count: 100)) == String(repeating: "日", count: 60) + tail, "180 bytes and the times still fit")
        // Sixty scalars of four bytes are 240 bytes: with the times that is more than a file name may have (255, and " (2)" must still fit).
        // The name loses scalars; the times never.
        let clef = String(repeating: "\u{1D11E}", count: 60)
        let cut = named(clef)
        #expect(cut == String(repeating: "\u{1D11E}", count: 51) + tail && cut.utf8.count == ClipFileName.maximumBytes)
        let cutWithPart = named(clef, part: 2, of: 3)
        #expect(cutWithPart == String(repeating: "\u{1D11E}", count: 47) + " 2026-10-12 14.02.10 to 14.05.42 (part 2 of 3).mp4")
        #expect(cutWithPart.utf8.count <= ClipFileName.maximumBytes)
        // A cut that leaves a space at the end of the name is trimmed again: one space before the times, not two.
        let spaced = String(repeating: "\u{1D11E}", count: 50) + " " + String(repeating: "\u{1D11E}", count: 9)
        #expect(named(spaced) == String(repeating: "\u{1D11E}", count: 50) + tail)
    }

    @Test func nonASCIINamesSurviveAsTheyAre() {
        for camera in ["Garten Süd", "カメラ１", "Cámara del garaje", "Кухня", "Garage 🚗", "Côté jardin"] {
            let file = named(camera)
            #expect(file == camera + tail, "\(camera)")
            #expect(String(decoding: Data(file.utf8), as: UTF8.self) == file, "UTF-8 and back")
        }
        // A letter and its accent kept apart stay apart: the bytes are the camera's own.
        let decomposed = "Cafe\u{301}"
        #expect(named(decomposed).unicodeScalars.starts(with: decomposed.unicodeScalars))
    }

    @Test func aDuplicateGetsANumberBeforeTheExtension() {
        #expect(ClipFileName.unique([]) == [])
        #expect(ClipFileName.unique(["A.mp4", "B.mp4"]) == ["A.mp4", "B.mp4"])
        #expect(ClipFileName.unique(["A.mp4", "A.mp4", "B.mp4", "A.mp4"]) == ["A.mp4", "A (2).mp4", "B.mp4", "A (3).mp4"])
        #expect(ClipFileName.unique(["A.mp4", "a.MP4"]) == ["A.mp4", "a (2).MP4"], "the Mac's and Windows' file systems keep one of two names that differ in case")
        // A number is never handed out twice.
        #expect(ClipFileName.unique(["A.mp4", "A (2).mp4", "A.mp4"]) == ["A.mp4", "A (2).mp4", "A (3).mp4"])
        #expect(ClipFileName.unique(["A.mp4", "A.mp4", "A (2).mp4"]) == ["A.mp4", "A (2).mp4", "A (2) (2).mp4"])
        #expect(ClipFileName.unique(["Clips", "Clips"]) == ["Clips", "Clips (2)"], "no extension: the number goes last")
        #expect(ClipFileName.unique([".hidden", ".hidden"]) == [".hidden", ".hidden (2)"], "a leading dot is not an extension")
        // Two cameras both called Garage with the same range, and many of the same name: all different, in order.
        let same = named("Garage")
        #expect(ClipFileName.unique([same, same]) == [same, "Garage 2026-10-12 14.02.10 to 14.05.42 (2).mp4"])
        let many = ClipFileName.unique(Array(repeating: same, count: 25))
        #expect(many.count == 25 && Set(many.map { $0.lowercased() }).count == 25 && many.first == same && many.last == "Garage 2026-10-12 14.02.10 to 14.05.42 (25).mp4")
    }

    @Test func theFolderAndTheArchiveAreNamedAfterTheStart() throws {
        let start = Date(timeIntervalSince1970: 1_791_813_730)
        let phoenix = try zone("America/Phoenix"), berlin = try zone("Europe/Berlin")
        #expect(ClipFileName.folder(start: start, timeZone: utc) == "Clips 2026-10-12 14.02.10")
        #expect(ClipFileName.archive(start: start, timeZone: utc) == "Camera Bridge clips 2026-10-12 14.02.10.zip")
        #expect(ClipFileName.folder(start: start, timeZone: phoenix) == "Clips 2026-10-12 07.02.10")
        #expect(ClipFileName.archive(start: start, timeZone: berlin) == "Camera Bridge clips 2026-10-12 16.02.10.zip")
        for name in [ClipFileName.folder(start: start, timeZone: berlin), ClipFileName.archive(start: start, timeZone: berlin)] {
            #expect(!name.contains("/") && !name.contains(":") && !name.contains("\\"))
        }
    }
}
