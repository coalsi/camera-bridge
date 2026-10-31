/// Follows a camera's main stream across its offline and online states, for `CameraEventSource.videoResumed(downSince:)`: video that
/// comes back after the stream was down at least `minimum` (a camera that lost power and booted again, a cable or switch that dropped)
/// means the camera's event connection may have died with it. A short reconnect (the stream dropped while the camera stayed up) says
/// nothing about the event connection.
struct VideoOutage {
    /// How long the stream must have been down. A camera that reboots is down for about a minute; a dropped RTSP session to a camera that
    /// stayed up comes back within seconds.
    static let minimum: Duration = .seconds(15)

    private(set) var since: ContinuousClock.Instant?

    /// The stream went offline (the first offline of an outage marks its start).
    mutating func offline(at now: ContinuousClock.Instant = .now) {
        if since == nil { since = now }
    }

    /// The stream delivers again: when it was down at least `minimum`, when it went down.
    mutating func online(at now: ContinuousClock.Instant = .now, minimum: Duration = VideoOutage.minimum) -> ContinuousClock.Instant? {
        defer { since = nil }
        guard let since, now - since >= minimum else { return nil }
        return since
    }
}
