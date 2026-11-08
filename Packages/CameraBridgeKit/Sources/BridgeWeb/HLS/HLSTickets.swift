import BridgeEngine
import Foundation

/// What a ticket plays.
enum HLSTicketKind: Sendable, Equatable {
    /// A camera's live video: which stream, and whether it carries sound.
    case live(stream: LiveVideoStream, audio: Bool)
    /// A range of recordings, in milliseconds since 1970.
    case recorded(from: Int64, to: Int64)
}

/// One ticket: it names one camera, one kind of video and the viewer that asked, and nothing else.
struct HLSTicket: Sendable, Equatable {
    var ticket: String
    /// An Apple TV's `AuthStore.ViewerInfo.id`, or `HLSTickets.sessionViewer(_:)` for a signed-in browser.
    var viewer: String
    var camera: UUID
    var kind: HLSTicketKind
    /// The `HLSLivePackager.id` a live ticket was minted against, and the only one it plays; nil for a recorded ticket.
    var packager: UUID?
    /// What a recorded ticket plays, planned once when it was minted and dropped with it; nil for a live ticket.
    var recording: HLSRecordedPlan?
    var created: Date
    var lastUsed: Date
}

/// The tickets a player fetches HLS files with (`GET hls/:ticket/:file`), so that the viewer's key never goes in a URL. They live in memory
/// only: a ticket is 32 random bytes as hex, lasts until 5 minutes after its last use and at most 6 hours, and a viewer holds at most 8 (the
/// oldest is dropped for a ninth). The caller passes the time, so tests move it.
actor HLSTickets {
    static let idleLifetime: TimeInterval = 300
    static let hardLifetime: TimeInterval = 21_600
    static let perViewer = 8

    private var held: [HLSTicket] = []

    /// The viewer name a signed-in browser's tickets are kept under. It is not an Apple TV's id: the session list is asked about it, not the TVs.
    static func sessionViewer(_ sessionID: String) -> String { "session:" + sessionID }
    /// The session id inside a `sessionViewer` name; nil for an Apple TV's id.
    static func sessionID(of viewer: String) -> String? { viewer.hasPrefix("session:") ? String(viewer.dropFirst(8)) : nil }

    /// A new ticket for `viewer`; the viewer's oldest goes first when it already holds 8.
    func mint(viewer: String, camera: UUID, kind: HLSTicketKind, packager: UUID? = nil, recording: HLSRecordedPlan? = nil, now: Date) -> String {
        removeEnded(now: now)
        let mine = held.indices.filter { held[$0].viewer == viewer }
        if mine.count >= Self.perViewer, let oldest = mine.min(by: { held[$0].created < held[$1].created }) {
            held.remove(at: oldest)
        }
        let ticket = Secrets.hex(Secrets.randomBytes(32))
        held.append(HLSTicket(ticket: ticket, viewer: viewer, camera: camera, kind: kind, packager: packager, recording: recording, created: now, lastUsed: now))
        return ticket
    }

    /// The ticket, now used, or nil when there is none by that name or it has ended (an ended one is forgotten). Compared with every held
    /// ticket in constant time, so the time taken says nothing about how much of a guess was right.
    func touch(_ ticket: String, now: Date) -> HLSTicket? {
        guard ticket.utf8.count == 64 else { return nil }   // an oversized guess is neither copied nor scanned
        removeEnded(now: now)
        var found: Int?
        for index in held.indices where Secrets.constantTimeEqual(held[index].ticket, ticket) { found = index }
        guard let found else { return nil }
        held[found].lastUsed = now
        return held[found]
    }

    /// Ends every ticket of `viewer` (a TV that was removed).
    func drop(viewer: String) {
        held.removeAll { $0.viewer == viewer }
    }

    func count(viewer: String) -> Int {
        held.count { $0.viewer == viewer }
    }

    private func removeEnded(now: Date) {
        held.removeAll {
            now.timeIntervalSince($0.lastUsed) > Self.idleLifetime || now.timeIntervalSince($0.created) > Self.hardLifetime
        }
    }
}
