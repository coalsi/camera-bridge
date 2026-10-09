import BridgeSupport
import Foundation
import Synchronization

/// PullPoint timing (defaults from the `onvif` 0.8 library Scrypted uses; research brief §3.5).
struct ONVIFEventTiming: Sendable {
    var initialTerminationTime = "PT2M"
    var pullTimeout = "PT1M"
    var messageLimit = 10
    /// HTTP reply timeout for PullMessages (longer than `pullTimeout`).
    var replyTimeout: Duration = .seconds(80)
    var renewInterval: Duration = .seconds(60)
    var renewTerminationTime = "PT2M"
    /// Hold for pulse topics without a reliable stop (CellMotion, ObjectDetection).
    var pulseHold: Duration = .seconds(20)
    /// An empty PullMessages answer faster than this is followed by a pause (cameras that ignore `Timeout`).
    var minimumPullInterval: Duration = .seconds(1)
    var ringDedupe: Duration = .seconds(3)
    /// A session counts as healthy after 30 s (Tapo drops its PullPoint request after 10 s: counting that as healthy
    /// reconnected at once, every 11 s, forever); shorter ones back off from 5 s up to 5 min.
    var policy = ReconnectPolicy(healthyAfter: .seconds(30), shortSessionBackoff: Backoff(initial: .seconds(5), maximum: .seconds(300)))
    /// Short sessions in a row after which the source reports `.eventChannelUnreliable` (the app then falls back to
    /// built-in motion detection for the camera).
    var unreliableAfterShortSessions = 5
}

/// ONVIF PullPoint event channel: CreatePullPointSubscription → PullMessages loop (Renew every `renewInterval`, and
/// early enough that no PullMessages can outlive the subscription) → Unsubscribe (only for a subscription that was
/// actually created; errors ignored).
enum ONVIFPullPoint {
    /// A Renew is sent when the next PullMessages could otherwise end less than this before the subscription expires.
    static let renewMargin: Duration = .seconds(10)
    /// Consecutive unclassified Renew faults after which the loop relies on PullMessages alone.
    static let maximumRenewFaults = 3
    /// Shortest PullMessages timeout the loop falls back to (seconds).
    static let minimumPullSeconds = 2.0

    /// Pull timeouts learned from cameras that close a PullMessages request early, by device host (seconds). Tapo's HTTP
    /// server closes a request that takes 10 s, whatever `Timeout` says; the next subscription starts with the shorter one.
    private static let learnedPull = Mutex<[String: Double]>([:])

    static func learnedPullSeconds(host: String) -> Double? { learnedPull.withLock { $0[host] } }

    static func forgetLearnedPullSeconds() { learnedPull.withLock { $0.removeAll() } }

    /// The PullMessages timeout (seconds) to use after the camera dropped the connection of a request `elapsed` seconds in,
    /// while `current` was asked for: a bit under what the camera tolerated (70 %, so its own timer never beats ours).
    /// nil when the camera dropped it too early to learn anything (under `minimumPullSeconds` / 0.7) or this is not shorter.
    static func shorterPullSeconds(droppedAfter elapsed: Double, current: Double) -> Double? {
        guard elapsed.isFinite, elapsed >= minimumPullSeconds / 0.7 else { return nil }
        let shorter = (elapsed * 0.7).rounded(.down)
        return shorter >= minimumPullSeconds && shorter < current ? shorter : nil
    }

    /// How the camera answered a Renew fault.
    enum RenewFault: Equatable {
        /// The device does not implement Renew (some extend the subscription on every PullMessages): keep pulling.
        case unsupported
        /// The subscription is gone (expired, unknown, "create pull-point subscription first"): subscribe again.
        case subscriptionGone
        case other

        init(_ summary: String) {
            let text = summary.lowercased()
            if ["notsupported", "not supported", "unsupported", "notimplemented", "not implemented"].contains(where: text.contains) {
                self = .unsupported
            } else if text.contains("resourceunknown") || text.contains("subscription") {
                self = .subscriptionGone
            } else {
                self = .other
            }
        }
    }

    /// An `xs:duration` of days, hours, minutes and seconds (`PT2M`, `PT1M30S`, `P1DT2H`, `PT0.5S`); nil for anything
    /// else (years and months are not fixed lengths).
    static func duration(xsDuration text: String) -> Duration? {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        guard rest.hasPrefix("P") else { return nil }
        rest = rest.dropFirst()
        var seconds = 0.0
        var inTime = false
        var number = ""
        var parts = 0
        var seen = Set<Character>()
        for character in rest {
            if character == "T" {
                guard !inTime, number.isEmpty else { return nil }
                inTime = true
            } else if character.isNumber || character == "." {
                number.append(character)
            } else {
                let unit: Double
                switch (character, inTime) {
                case ("D", false): unit = 86_400
                case ("H", true): unit = 3600
                case ("M", true): unit = 60
                case ("S", true): unit = 1
                default: return nil
                }
                guard let value = Double(number), value.isFinite, seen.insert(character).inserted else { return nil }
                seconds += value * unit
                number = ""
                parts += 1
            }
        }
        guard number.isEmpty, parts > 0, seconds.isFinite, seconds <= 31_536_000 else { return nil }
        return .milliseconds(Int64((seconds * 1000).rounded()))
    }

    /// Renew now: the regular interval passed, or a PullMessages started now could end (at the reply timeout) within
    /// `renewMargin` of the subscription's termination.
    static func renewDue(sinceRenew elapsed: Duration, lifetime: Duration, timing: ONVIFEventTiming) -> Bool {
        elapsed >= timing.renewInterval || elapsed + timing.replyTimeout >= lifetime - renewMargin
    }

    /// `cameraID`: the camera the source serves (the source, its ONVIF client and the PullPoint loop log with it).
    static func makeSource(deviceServiceURL: URL, credentials: HTTPCredentials?, timing: ONVIFEventTiming = ONVIFEventTiming(),
                           label: String = "ONVIF", cameraID: UUID? = nil) -> SupervisedEventSource {
        let log = Log(category: "onvif-events", cameraID: cameraID)
        return SupervisedEventSource(label: label, cameraID: cameraID, policy: timing.policy, ringDedupe: timing.ringDedupe,
                                     unreliableAfterShortSessions: timing.unreliableAfterShortSessions) { context in
            let client = ONVIFClient(deviceServiceURL: deviceServiceURL, credentials: credentials, longPollTimeout: timing.replyTimeout,
                                     cameraID: cameraID)
            try await run(client: client, timing: timing, log: log) { signals in await context.apply(signals) } onConnected: { context.connected() }
        }
    }

    /// One subscription's lifetime. `deliver` receives the mapped signals of each notification (in order).
    static func run(client: ONVIFClient, timing: ONVIFEventTiming, log: Log = Log(category: "onvif-events"),
                    filter: (@Sendable (ONVIFNotification) -> Bool)? = nil,
                    deliver: @Sendable ([EventSignal]) async -> Void, onConnected: @Sendable () -> Void) async throws {
        _ = try? await client.systemDateAndTime()
        let subscription = try await client.createPullPointSubscription(initialTerminationTime: timing.initialTerminationTime)
        onConnected()
        do {
            try await pullLoop(client: client, subscription: subscription, timing: timing, log: log, filter: filter, deliver: deliver)
        } catch {
            await unsubscribe(client: client, subscription: subscription, log: log)
            throw error
        }
        await unsubscribe(client: client, subscription: subscription, log: log)
    }

    private static func pullLoop(client: ONVIFClient, subscription: ONVIFSubscription, timing: ONVIFEventTiming, log: Log,
                                 filter: (@Sendable (ONVIFNotification) -> Bool)?, deliver: @Sendable ([EventSignal]) async -> Void) async throws {
        let host = client.deviceServiceURL.host(percentEncoded: false) ?? ""
        let configuredSeconds = duration(xsDuration: timing.pullTimeout)?.timeInterval ?? 60
        var pullSeconds = configuredSeconds
        if let learned = learnedPullSeconds(host: host), learned < pullSeconds { pullSeconds = learned }
        var pullTimeout = pullSeconds == configuredSeconds ? timing.pullTimeout : "PT\(Int(pullSeconds))S"
        let fallbackLifetime = Duration.seconds(60)
        var lifetime = duration(xsDuration: timing.initialTerminationTime) ?? fallbackLifetime
        var lastRenew = ContinuousClock.now
        var renewSupported = true
        var renewFaults = 0
        /// This subscription's property instances (a stop whose Source items differ from its start's still ends it).
        var mapping = ONVIFEventMapping()
        while !Task.isCancelled {
            if renewSupported, renewDue(sinceRenew: ContinuousClock.now - lastRenew, lifetime: lifetime, timing: timing) {
                do {
                    try await client.renew(subscription, terminationTime: timing.renewTerminationTime)
                    lastRenew = .now
                    lifetime = duration(xsDuration: timing.renewTerminationTime) ?? fallbackLifetime
                    renewFaults = 0
                } catch CameraAdapterError.soapFault(let reason) {
                    switch RenewFault(reason) {
                    case .unsupported:
                        renewSupported = false
                        log.info("Renew not supported (\(reason)); relying on PullMessages")
                    case .subscriptionGone:
                        log.info("subscription gone on Renew (\(reason)); subscribing again")
                        throw CameraAdapterError.soapFault(reason)
                    case .other:
                        renewFaults += 1   // retried before the next pull
                        if renewFaults >= maximumRenewFaults {
                            renewSupported = false
                            log.info("Renew keeps failing (\(reason)); relying on PullMessages")
                        }
                    }
                }
            }
            let started = ContinuousClock.now
            let notifications: [ONVIFNotification]
            do {
                notifications = try await client.pullMessages(subscription, timeout: pullTimeout, messageLimit: timing.messageLimit)
            } catch let error as TransportError where error == .closed {
                // The camera dropped the connection while it held the request: some close one after a fixed idle time
                // (Tapo: 10 s) however long `Timeout` is. The subscription lives on: pull again, for less.
                let elapsed = (ContinuousClock.now - started).timeInterval
                guard let shorter = shorterPullSeconds(droppedAfter: elapsed, current: pullSeconds) else { throw error }
                pullSeconds = shorter
                pullTimeout = "PT\(Int(shorter))S"
                learnedPull.withLock { $0[host] = shorter }
                log.info("the camera dropped a PullMessages request after \(String(format: "%.1f", elapsed)) s; pulling for \(Int(shorter)) s from now on")
                continue
            }
            for notification in notifications where filter?(notification) ?? true {
                await deliver(mapping.signals(for: notification, pulseHold: timing.pulseHold))
            }
            let elapsed = ContinuousClock.now - started
            if notifications.isEmpty, elapsed < timing.minimumPullInterval {
                try await Task.sleep(for: timing.minimumPullInterval - elapsed)
            }
        }
    }

    /// Best effort, outside the (possibly cancelled) session task so the request is actually sent.
    private static func unsubscribe(client: ONVIFClient, subscription: ONVIFSubscription, log: Log) async {
        await Task {
            do { try await client.unsubscribe(subscription) } catch {
                log.debug("Unsubscribe failed: \(Redact.string(String(describing: error)))")
            }
        }.value
    }
}
