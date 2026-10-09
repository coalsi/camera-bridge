import BridgeSupport
import Foundation

/// One poll of Reolink event state (`GetEvents`, or `GetMdState` + `GetAiState` on older firmware).
struct ReolinkEventState: Sendable, Equatable {
    var motion: Bool?
    /// Supported AI classes only.
    var objects: [DetectedObjectKind: Bool]
    /// Doorbell visitor (press) flag; nil when not reported.
    var visitor: Bool?
    var supported: Set<CameraEventKind>

    static let aiKeys: [(key: String, kind: DetectedObjectKind)] = [
        ("people", .person), ("vehicle", .vehicle), ("dog_cat", .animal), ("package", .package), ("face", .face),
    ]

    init(motion: Bool?, objects: [DetectedObjectKind: Bool], visitor: Bool?, supported: Set<CameraEventKind>) {
        self.motion = motion
        self.objects = objects
        self.visitor = visitor
        self.supported = supported
    }

    /// From a `GetEvents` value: `{ai:{people:{alarm_state,support},…}, md:{alarm_state,support}, visitor:{…}}`.
    init(events value: JSONValue) {
        self.init(motion: value["md"]?["alarm_state"]?.flag ?? value["md"]?["state"]?.flag, ai: value["ai"],
                  visitor: value["visitor"]?["support"]?.flag == true ? value["visitor"]?["alarm_state"]?.flag : nil)
    }

    /// From `GetMdState` (`{state}`) and `GetAiState` (`{people:{alarm_state,support},…}`) values.
    init(motionState: JSONValue?, aiState: JSONValue?) {
        self.init(motion: motionState?["state"]?.flag, ai: aiState, visitor: nil)
    }

    private init(motion: Bool?, ai: JSONValue?, visitor: Bool?) {
        var objects: [DetectedObjectKind: Bool] = [:]
        var supported: Set<CameraEventKind> = [.motion]
        for (key, kind) in Self.aiKeys {
            guard let entry = ai?[key], entry["support"]?.flag == true else { continue }
            objects[kind] = entry["alarm_state"]?.flag ?? false
            supported.insert(CameraEventKind(kind))
        }
        if visitor != nil { supported.insert(.doorbell) }
        self.init(motion: motion, objects: objects, visitor: visitor, supported: supported)
    }
}

extension CameraEventKind {
    init(_ kind: DetectedObjectKind) {
        switch kind {
        case .person: self = .person
        case .vehicle: self = .vehicle
        case .animal: self = .animal
        case .package: self = .package
        case .face: self = .face
        }
    }
}

/// Poll state → signals. Motion is on while `md` or any AI class is active (Reolink AI does not always raise `md`);
/// a visitor rising edge is a ring (the first poll only sets the baseline).
struct ReolinkEventMapper: Sendable {
    private var previousVisitor: Bool?

    mutating func signals(for state: ReolinkEventState) -> [EventSignal] {
        var signals: [EventSignal] = []
        if let motion = state.motion {
            signals.append(motion ? .activate(.motion, source: "md", hold: nil) : .deactivate(.motion, source: "md"))
        }
        for kind in DetectedObjectKind.allCases {
            guard let active = state.objects[kind] else { continue }
            signals.append(active ? .activate(.object(kind), source: "poll", hold: nil) : .deactivate(.object(kind), source: "poll"))
        }
        if !state.objects.isEmpty {
            let any = state.objects.values.contains(true)
            signals.append(any ? .activate(.motion, source: "ai", hold: nil) : .deactivate(.motion, source: "ai"))
        }
        if let visitor = state.visitor {
            if visitor, previousVisitor == false { signals.append(.ring) }
            previousVisitor = visitor
        }
        return signals
    }
}

struct ReolinkEventTiming: Sendable {
    var pollInterval: Duration = .seconds(1)
    var ringDedupe: Duration = .seconds(3)
    /// Consecutive failed polls before the session reconnects (fresh login).
    var maximumPollFailures = 3
    /// Also subscribe to ONVIF PullPoint (Visitor, AI topics) for doorbells / AI models with ONVIF enabled.
    var useONVIFEvents = true
    var onvif = ONVIFEventTiming()
    var policy = ReconnectPolicy(shortSessionBackoff: Backoff(initial: .seconds(5), maximum: .seconds(300)))
}

/// Reolink event channel: 1 Hz polling of `GetEvents` (or `GetMdState` + `GetAiState`), plus an ONVIF PullPoint
/// side channel for low-latency `Visitor` rings on doorbells; rings from both are deduplicated within 3 s.
/// Polling uses the driver's `ReolinkAPI` (one token for probe, snapshots and every reconnect); stopping the source
/// logs that session out.
///
/// Each session decides once how to poll and whether to run the side channel, so it decides only on answers the
/// camera actually gave: legacy polling only after `GetEvents` was refused as unsupported (`unsupportedCodes`), and
/// any transport or transient failure while deciding fails the session (a camera that is down — Wi-Fi drop, reboot,
/// firmware update — is retried with backoff instead of latching legacy polling, which never reports the visitor
/// button, or dropping the doorbell's ONVIF `Visitor` channel). The channel reports connected after the first
/// successful poll. Everything the source logs carries the camera ID of its `ReolinkAPI` (the driver's camera).
enum ReolinkEvents {
    /// `GetEvents` answers that mean the firmware cannot run it (older firmware polls `GetMdState` + `GetAiState`):
    /// answers about the request itself, which no retry changes — -1 "not exist", -4 "param error", -9 "not support",
    /// -23 "missing param", -24 "error command", -26 "ability error" (Reolink HTTP API v8 error table). Every other
    /// failure (transport, HTTP status, timeout, transient codes such as -8, -12, -17, -25, -31, -99) is retried.
    static let unsupportedCodes: Set<Int> = [-1, -4, -9, -23, -24, -26]

    private enum PollMode: Sendable { case events, legacy }

    static func makeSource(api: ReolinkAPI, credentials: HTTPCredentials?, timing: ReolinkEventTiming = ReolinkEventTiming())
        -> SupervisedEventSource {
        let endpoint = api.endpoint
        let channel = api.channel
        let cameraID = api.cameraID
        let log = Log(category: "reolink-events", cameraID: cameraID)
        let onvifOffReported = LockedValue(false)
        return SupervisedEventSource(label: "Reolink \(endpoint.host)", cameraID: cameraID, policy: timing.policy, ringDedupe: timing.ringDedupe,
                                     onStop: { await api.logout() }, reachability: api.reachability) { context in
            _ = try await api.validToken()   // reuses a live token: a reconnect costs no new camera session
            let channelParam = JSONValue.object(["channel": .number(Double(channel))])
            let mode = try await pollMode(api: api, channelParam: channelParam)
            let onvifURL = timing.useONVIFEvents
                ? try await onvifDeviceURL(api: api, endpoint: endpoint, credentials: credentials, onvifOffReported: onvifOffReported, log: log)
                : nil
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await poll(api: api, mode: mode, channelParam: channelParam, timing: timing, context: context)
                }
                if let onvifURL {
                    group.addTask {
                        await onvifSideChannel(url: onvifURL, credentials: credentials, timing: timing, context: context, cameraID: cameraID, log: log,
                                               reachability: api.reachability)
                    }
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        }
    }

    /// `.events` when `GetEvents` works, `.legacy` when the camera refuses it as unsupported; throws on anything else
    /// (unreachable camera, HTTP error, timeout, transient API error).
    private static func pollMode(api: ReolinkAPI, channelParam: JSONValue) async throws -> PollMode {
        do {
            _ = try await api.command("GetEvents", param: channelParam)
            return .events
        } catch CameraAdapterError.apiError(_, let code) where unsupportedCodes.contains(code) {
            return .legacy
        }
    }

    /// ONVIF device service URL when the camera is a doorbell or an ONVIF-detection model and ONVIF is switched on.
    /// Whether it is on comes from `GetNetPort.onvifEnable` (`supportOnvifEnable` only says the camera has the
    /// switch; newer firmware ships with it off, and a side channel to a closed port would retry for the whole
    /// session). The port is the configured one, else the one `GetNetPort` reports, else 8000. When `GetNetPort` is
    /// not answered (older firmware, a user without the right), the ability — or a configured ONVIF port — decides as
    /// before. Throws when the camera cannot be asked (a doorbell must not lose its `Visitor` channel to an outage);
    /// a `GetAbility` / `GetNetPort` the camera refuses counts as not reported. `onvifOffReported` limits the hint to
    /// turn ONVIF on to once per event source.
    private static func onvifDeviceURL(api: ReolinkAPI, endpoint: CameraEndpoint, credentials: HTTPCredentials?,
                                       onvifOffReported: LockedValue<Bool>, log: Log) async throws -> URL? {
        let info = try await api.command("GetDevInfo")
        let devInfo = info["DevInfo"]
        let isDoorbell = ReolinkDriver.isDoorbell(devInfo: devInfo, visitorSupported: false)
        let model = devInfo?["model"]?.string ?? ""
        let onvifDetections = ReolinkDriver.onvifDetectionModels.contains(model)
        guard isDoorbell || onvifDetections else { return nil }
        let ability = try await commandUnlessRefused(api, "GetAbility", param: ReolinkDriver.abilityParam(credentials))
        let hasONVIFSwitch = ReolinkDriver.onvifEnabled(ability: ability)
        guard hasONVIFSwitch != false else { return nil }
        let netPort = ReolinkDriver.onvifNetPort(try await commandUnlessRefused(api, "GetNetPort"))
        switch netPort.enabled {
        case false?:
            if !onvifOffReported.withLock({ reported in
                let before = reported
                reported = true
                return before
            }) {
                log.notice("ONVIF is switched off on Reolink \(model.isEmpty ? "camera" : model): \(isDoorbell ? "rings" : "AI detections") arrive through 1 s polling. Turn ONVIF on in the camera's network port settings for instant events.")
            }
            return nil
        case true?:
            break
        case nil:
            guard hasONVIFSwitch ?? (endpoint.onvifPort != nil) else { return nil }
        }
        var onvifEndpoint = endpoint
        onvifEndpoint.onvifPort = endpoint.onvifPort ?? netPort.port ?? ReolinkDriver.defaultONVIFPort
        return ONVIFClient.deviceServiceURL(for: onvifEndpoint)
    }

    /// `command`'s value; nil when the camera refuses it (an API error code, or a per-user refusal: the session's own
    /// commands just worked, so it is not bad credentials). Transport failures still throw.
    private static func commandUnlessRefused(_ api: ReolinkAPI, _ command: String, param: JSONValue? = nil) async throws -> JSONValue? {
        do {
            return try await api.command(command, param: param)
        } catch CameraAdapterError.apiError {
            return nil
        } catch CameraAdapterError.unauthorized {
            return nil
        }
    }

    /// Polls until `maximumPollFailures` consecutive failures; the channel is connected from the first successful poll.
    private static func poll(api: ReolinkAPI, mode: PollMode, channelParam: JSONValue, timing: ReolinkEventTiming,
                             context: EventSessionContext) async throws {
        var mapper = ReolinkEventMapper()
        var failures = 0
        while !Task.isCancelled {
            // A camera known to be unreachable is not polled (every poll is a connection it can ill afford, and none would
            // be answered): the poll resumes, at its usual pace, when the probe finds the camera again.
            if let reachability = api.reachability, reachability.isOffline {
                await reachability.waitUntilReachable()
                failures = 0
                if Task.isCancelled { break }
            }
            do {
                let state: ReolinkEventState
                switch mode {
                case .events:
                    state = ReolinkEventState(events: try await api.command("GetEvents", param: channelParam))
                case .legacy:
                    let md = try await api.command("GetMdState", param: channelParam)
                    let ai = try? await api.command("GetAiState", param: channelParam)
                    state = ReolinkEventState(motionState: md, aiState: ai)
                }
                failures = 0
                context.connected()
                await context.apply(mapper.signals(for: state))
            } catch CameraAdapterError.unauthorized {
                throw CameraAdapterError.unauthorized
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures += 1
                if failures >= timing.maximumPollFailures { throw error }
            }
            try await Task.sleep(for: timing.pollInterval)
        }
    }

    /// Runs PullPoint subscriptions until cancelled, with its own backoff; never fails the polling session. Level
    /// states a subscription turned on (`MyRuleDetector`, `MotionAlarm`) end with it — nothing would report their end,
    /// and polling keeps the session alive — as `EventSessionContext.disconnected()` does for a whole session; the
    /// next subscription re-asserts whatever is still on.
    private static func onvifSideChannel(url: URL, credentials: HTTPCredentials?, timing: ReolinkEventTiming,
                                         context: EventSessionContext, cameraID: UUID?, log: Log,
                                         reachability: CameraReachability? = nil) async {
        var backoff = timing.onvif.policy.backoff
        let pullPointLog = Log(category: "onvif-events", cameraID: cameraID)
        while !Task.isCancelled {
            if let reachability, reachability.isOffline {
                await reachability.waitUntilReachable()
                backoff.reset()
                if Task.isCancelled { return }
            }
            let connected = LockedValue(false)
            let levels = LockedValue(ActiveLevels())
            let client = ONVIFClient(deviceServiceURL: url, credentials: credentials, longPollTimeout: timing.onvif.replyTimeout, cameraID: cameraID)
            var failure: (any Error)?
            do {
                try await ONVIFPullPoint.run(client: client, timing: timing.onvif, log: pullPointLog) { signals in
                    levels.withLock { $0.track(signals) }
                    await context.apply(signals)
                } onConnected: {
                    connected.set(true)
                }
            } catch {
                if Task.isCancelled { return }
                failure = error
                reachability?.report(adapterError: error)
                log.info("ONVIF events unavailable: \(Redact.string(String(describing: error)))")
            }
            if Task.isCancelled { return }   // the session ends: its context releases every level state
            await context.apply(levels.withLock { $0.releaseAll() })
            if connected.value { backoff.reset() }
            var delay = backoff.next()
            if case CameraAdapterError.unauthorized? = failure {
                delay = max(delay, timing.onvif.policy.delayAfterUnauthorized)   // do not trip the camera's login lockout
            }
            do { try await Task.sleep(for: delay) } catch { return }
        }
    }
}
