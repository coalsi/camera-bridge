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
    /// A paired device's `AuthStore.ViewerInfo.id`, or `HLSTickets.sessionViewer(_:)` for a signed-in browser.
    var viewer: String
    var camera: UUID
    var kind: HLSTicketKind
    /// The `HLSLivePackager.id` a live ticket was minted against, and the only one it plays; nil for a recorded ticket.
    var packager: UUID?
    /// What a recorded ticket plays, planned once when it was minted and dropped with it; nil for a live ticket.
    var recording: HLSRecordedPlan?
    /// On a clock nobody sets (`WebConfiguration.uptime`), so setting the time of day neither ends a ticket nor makes one last longer.
    var created: ContinuousClock.Instant
    var lastUsed: ContinuousClock.Instant
}

/// The tickets a player fetches HLS files with (`GET hls/:ticket/:file`), so that the viewer's key never goes in a URL. They live in memory
/// only: a ticket is 32 random bytes as hex, lasts until 5 minutes after its last use and at most 6 hours, and a viewer holds at most 8 (the
/// oldest is dropped for a ninth). The caller passes the time, from a clock nobody sets, so tests move it and a clock set by hand changes nothing.
actor HLSTickets {
    static let idleLifetime = Duration.seconds(300)
    static let hardLifetime = Duration.seconds(21_600)
    static let perViewer = 8

    private var held: [HLSTicket] = []

    /// The viewer name a signed-in browser's tickets are kept under. It is not a paired device's id: the session list is asked about it, not the devices.
    static func sessionViewer(_ sessionID: String) -> String { "session:" + sessionID }
    /// The session id inside a `sessionViewer` name; nil for a paired device's id.
    static func sessionID(of viewer: String) -> String? { viewer.hasPrefix("session:") ? String(viewer.dropFirst(8)) : nil }

    /// A new ticket for `viewer`; the viewer's oldest goes first when it already holds 8. `released` is the live packager the dropped ticket was
    /// minted against when no ticket of the viewer refers to it any more: the caller lets the viewer go from it (`HLSLivePackagers.release`), so a
    /// packager nobody can fetch from stops at once instead of holding a live slot until it is idle.
    func mint(viewer: String, camera: UUID, kind: HLSTicketKind, packager: UUID? = nil, recording: HLSRecordedPlan? = nil,
              now: ContinuousClock.Instant) -> (ticket: String, released: UUID?) {
        removeEnded(now: now)
        var dropped: HLSTicket?
        let mine = held.indices.filter { held[$0].viewer == viewer }
        if mine.count >= Self.perViewer, let oldest = mine.min(by: { held[$0].created < held[$1].created }) {
            dropped = held.remove(at: oldest)
        }
        let ticket = Secrets.hex(Secrets.randomBytes(32))
        held.append(HLSTicket(ticket: ticket, viewer: viewer, camera: camera, kind: kind, packager: packager, recording: recording, created: now, lastUsed: now))
        let released = dropped?.packager.flatMap { id in held.contains { $0.viewer == viewer && $0.packager == id } ? nil : id }
        return (ticket, released)
    }

    /// The ticket, now used, or nil when there is none by that name or it has ended (an ended one is forgotten). Compared with every held
    /// ticket in constant time, so the time taken says nothing about how much of a guess was right.
    func touch(_ ticket: String, now: ContinuousClock.Instant) -> HLSTicket? {
        guard ticket.utf8.count == 64 else { return nil }   // an oversized guess is neither copied nor scanned
        removeEnded(now: now)
        var found: Int?
        for index in held.indices where Secrets.constantTimeEqual(held[index].ticket, ticket) { found = index }
        guard let found else { return nil }
        held[found].lastUsed = now
        return held[found]
    }

    /// Ends every ticket of `viewer` (a device that was removed, a browser signed out).
    func drop(viewer: String) {
        held.removeAll { $0.viewer == viewer }
    }

    func count(viewer: String) -> Int {
        held.count { $0.viewer == viewer }
    }

    /// Forgets the tickets that ended. Their packagers are left to stop by themselves: one whose ticket idled out was idle long before, and the
    /// player of one that reached 6 hours asks for a new ticket, which finds it still running.
    private func removeEnded(now: ContinuousClock.Instant) {
        held.removeAll { now - $0.lastUsed > Self.idleLifetime || now - $0.created > Self.hardLifetime }
    }
}
