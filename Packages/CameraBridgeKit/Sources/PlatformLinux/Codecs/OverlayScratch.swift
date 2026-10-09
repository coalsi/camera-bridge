import Foundation
import MediaCore

/// The words of the timestamp overlay as one line of text, the way the Home app lays them out: camera name, then date and time.
/// "Front Door  |  Thu, Oct 2  7:42:15 PM".
func overlayLine(_ text: TimestampOverlayText) -> String {
    var clock = text.time
    if let date = text.date { clock = date + "  " + clock }
    guard let name = text.name else { return clock }
    return name + "  |  " + clock
}

/// A private scratch directory holding the overlay's text file, which ffmpeg's `drawtext` re-reads for every picture
/// (`reload=1`). The file is replaced atomically, so ffmpeg never reads half a line.
final class OverlayScratch: @unchecked Sendable {
    let directory: URL
    let textFile: URL
    private let lock = NSLock()
    private var current: String?

    init(parent: URL?) throws {
        let base = parent ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("camera-bridge-overlay-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        textFile = directory.appendingPathComponent("overlay.txt")
    }

    deinit { remove() }

    /// Writes `line` unless it is what the file already holds. Returns false when the file could not be written.
    @discardableResult
    func update(_ line: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard line != current else { return true }
        let temporary = directory.appendingPathComponent("overlay.tmp")
        do {
            try Data(line.utf8).write(to: temporary)
            // rename(2) replaces the destination atomically.
            guard rename(temporary.path, textFile.path) == 0 else { return false }
            current = line
            return true
        } catch {
            return false
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
