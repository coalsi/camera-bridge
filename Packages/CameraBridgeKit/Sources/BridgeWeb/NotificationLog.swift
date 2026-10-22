import BridgeSupport
import Foundation
import Synchronization

// The notification log: everything that was a notice, kept on the box (`notifications.json` in the data directory) so the phone and the
// Mac agree on what is new, what was read and what has been shown as a toast. The notices themselves are a list of what is true now
// (`NoticeResource`); the log is what happened: an entry when a notice first appears or changes, bounded to the last 500 or 90 days.

/// One thing that happened, as the Notifications page lists it. Every key is always encoded (null when empty).
struct NotificationEntry: Codable, Equatable, Sendable {
    var id: String
    /// What the notice said it was (`NoticeResource.key`); another key is another happening.
    var key: String
    var noticeID: String
    var kind: String
    var category: String
    var severity: String
    var title: String
    var detail: String
    var cameraID: UUID?
    var cameraName: String?
    var action: String?
    var date: Date
    var read: Bool
    /// The page showed it as a toast already (claimed by one browser; no other shows it).
    var toasted: Bool

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(key, forKey: .key)
        try container.encode(noticeID, forKey: .noticeID)
        try container.encode(kind, forKey: .kind)
        try container.encode(category, forKey: .category)
        try container.encode(severity, forKey: .severity)
        try container.encode(title, forKey: .title)
        try container.encode(detail, forKey: .detail)
        try container.encode(cameraID, forKey: .cameraID)
        try container.encode(cameraName, forKey: .cameraName)
        try container.encode(action, forKey: .action)
        try container.encode(date, forKey: .date)
        try container.encode(read, forKey: .read)
        try container.encode(toasted, forKey: .toasted)
    }
}

final class NotificationLog: Sendable {
    /// Notices of these kinds are events: once logged they are never logged again, though they leave the list and come back. Any other
    /// notice is a state: when it goes away and comes back, it happened again.
    private static let eventKinds: Set<String> = ["internetGuard"]

    private struct Stored: Codable {
        var entries: [NotificationEntry] = []
        /// The key each state notice had when last recorded (the ones in the list then).
        var active: [String: String] = [:]
        /// The keys of events logged (newest last, at most `maximumEvents`).
        var events: [String] = []
    }

    private static let maximumEvents = 1000

    private let url: URL
    private let maximumEntries: Int
    private let maximumAge: TimeInterval
    private let state: Mutex<Stored>

    init(directory: URL, maximumEntries: Int = 500, maximumAge: TimeInterval = 90 * 86_400) {
        url = directory.appending(path: "notifications.json", directoryHint: .notDirectory)
        self.maximumEntries = maximumEntries
        self.maximumAge = maximumAge
        let stored = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.iso.decode(Stored.self, from: $0) } ?? Stored()
        state = Mutex(stored)
    }

    /// Newest first.
    func entries() -> [NotificationEntry] { state.withLock { $0.entries } }

    var unread: Int { state.withLock { $0.entries.filter { !$0.read }.count } }

    /// Adds an entry for every notice of `notices` that is new or changed since the last call, and forgets the state notices that went away.
    func record(_ notices: [NoticeResource], now: Date = Date()) {
        state.withLock { stored in
            var changed = false
            for notice in notices {
                let isEvent = Self.eventKinds.contains(notice.kind)
                if isEvent ? stored.events.contains(notice.key) : stored.active[notice.id] == notice.key { continue }
                if isEvent { stored.events.append(notice.key) } else { stored.active[notice.id] = notice.key }
                stored.entries.insert(NotificationEntry(
                    id: UUID().uuidString, key: notice.key, noticeID: notice.id, kind: notice.kind, category: notice.category, severity: notice.severity,
                    title: notice.title, detail: notice.detail, cameraID: notice.cameraID, cameraName: notice.cameraName, action: notice.action,
                    date: now, read: false, toasted: false), at: 0)
                changed = true
            }
            let current = Set(notices.map(\.id))
            for id in stored.active.keys where !current.contains(id) {
                stored.active[id] = nil
                changed = true
            }
            let before = (stored.entries.count, stored.events.count)
            stored.entries = Array(stored.entries.filter { now.timeIntervalSince($0.date) <= maximumAge }.prefix(maximumEntries))
            stored.events = Array(stored.events.suffix(Self.maximumEvents))
            if changed || before != (stored.entries.count, stored.events.count) { save(stored) }
        }
    }

    /// The entries of `notices` not shown as a toast yet, marked shown: one browser gets each, once. Newest first.
    func claim(_ notices: [NoticeResource]) -> [NotificationEntry] {
        state.withLock { stored in
            let keys = Set(notices.map(\.key))
            var claimed: [NotificationEntry] = []
            for index in stored.entries.indices where !stored.entries[index].toasted && keys.contains(stored.entries[index].key) {
                stored.entries[index].toasted = true
                claimed.append(stored.entries[index])
            }
            if !claimed.isEmpty { save(stored) }
            return claimed
        }
    }

    /// Marks the entries `ids` read, or every entry when `ids` is nil.
    func markRead(ids: [String]?) {
        state.withLock { stored in
            let wanted = ids.map(Set.init)
            var changed = false
            for index in stored.entries.indices where !stored.entries[index].read && wanted?.contains(stored.entries[index].id) ?? true {
                stored.entries[index].read = true
                changed = true
            }
            if changed { save(stored) }
        }
    }

    private func save(_ stored: Stored) {
        guard let data = try? JSONEncoder.iso.encode(stored) else { return }
        try? PrivateFiles.write(data, to: url)
    }
}
