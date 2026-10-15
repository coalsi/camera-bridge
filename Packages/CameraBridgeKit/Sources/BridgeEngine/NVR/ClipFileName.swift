import Foundation

/// The names of what an export saves (export-clip design, section 4): a clip's file, the folder of a multi-camera export on the Mac and the ZIP
/// the browser gets for several cameras. Pure functions of their arguments. A time is read from a fixed Gregorian calendar in the request's time
/// zone and written with `String(format:)` and no locale, so nothing set on the machine (language, 12-hour clock, other digits) can change a
/// name, and the Mac and Linux agree. The camera's name goes through the recorder's folder-name sanitiser (`ArchiveCameraDirectory.sanitize`).
public enum ClipFileName {
    /// The longest name `part` makes, in UTF-8 bytes: file systems stop at 255, and `unique` needs room for " (2)".
    static let maximumBytes = 240

    /// "<camera> yyyy-MM-dd HH.mm.ss to HH.mm.ss.mp4": the clock of `timeZone`, a second never rounded up. The end carries its date when the clip
    /// crosses midnight in `timeZone`. A camera's clip of several parts gets " (part 2 of 3)" before ".mp4". The camera's name is sanitised
    /// ("Camera" when nothing is left) and loses its last characters, never the times, when the whole name would be longer than `maximumBytes`.
    public static func part(cameraName: String, start: Date, end: Date, partIndex: Int, partCount: Int, timeZone: TimeZone) -> String {
        let first = components(start, timeZone), last = components(end, timeZone)
        let endText = day(first) == day(last) ? clock(last) : "\(day(last)) \(clock(last))"
        let tail = " \(day(first)) \(clock(first)) to \(endText)" + (partCount > 1 ? " (part \(partIndex) of \(partCount))" : "") + ".mp4"
        var name = ArchiveCameraDirectory.sanitize(cameraName)
        while name.utf8.count + tail.utf8.count > maximumBytes, name.unicodeScalars.count > 1 {
            var shorter = String.UnicodeScalarView()
            shorter.append(contentsOf: name.unicodeScalars.dropLast())
            name = ArchiveCameraDirectory.sanitize(String(shorter))
        }
        return name + tail
    }

    /// "Clips yyyy-MM-dd HH.mm.ss": the folder a multi-camera export makes on the Mac.
    public static func folder(start: Date, timeZone: TimeZone) -> String {
        "Clips " + stamp(start, timeZone)
    }

    /// "Camera Bridge clips yyyy-MM-dd HH.mm.ss.zip": the ZIP the browser downloads for several cameras.
    public static func archive(start: Date, timeZone: TimeZone) -> String {
        "Camera Bridge clips " + stamp(start, timeZone) + ".zip"
    }

    /// `names` (file names with an extension) with every later duplicate numbered before the extension: "A.mp4", "A (2).mp4", "A (3).mp4". Names that
    /// differ only in case are duplicates (the Mac's and Windows' file systems keep one of them). A number is never given twice: an "A (2).mp4" that
    /// comes after an "A.mp4" which already took the 2 becomes "A (2) (2).mp4". The order and the count are kept.
    public static func unique(_ names: [String]) -> [String] {
        var taken = Set<String>()
        return names.map { name in
            var candidate = name
            var number = 2
            while !taken.insert(candidate.lowercased()).inserted {
                candidate = numbered(name, number)
                number += 1
            }
            return candidate
        }
    }

    private static func numbered(_ name: String, _ number: Int) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "\(name) (\(number))" }
        return "\(name[..<dot]) (\(number))\(name[dot...])"
    }

    private static func stamp(_ date: Date, _ timeZone: TimeZone) -> String {
        let parts = components(date, timeZone)
        return day(parts) + " " + clock(parts)
    }

    private static func components(_ date: Date, _ timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    /// "2026-10-12".
    private static func day(_ parts: DateComponents) -> String {
        String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// "14.02.10": dots, because a colon is not a character a file name can have on every system.
    private static func clock(_ parts: DateComponents) -> String {
        String(format: "%02d.%02d.%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }
}
