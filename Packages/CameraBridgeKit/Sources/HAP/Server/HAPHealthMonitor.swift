import BridgeSupport
import Foundation

/// Watches one accessory the way a controller experiences it and repairs what it finds, one log line per incident and per
/// repair (hardening plan WS-C 9, audit 3 part D). Every `interval` it checks three things:
///
/// 1. **The listener answers.** An unauthenticated request over loopback must be refused as HAP refuses it within
///    `probeTimeout`. A listener that accepts but never answers (a wedged accept loop) is restarted; the controllers see such a
///    camera only as "No Response".
/// 2. **Bonjour shows the advertisement.** Browsing `_hap._tcp` the way a controller does must find the accessory with the `id`,
///    `c#` and `sf` it registered. After `bonjourMissesBeforeRestart` checks in a row that do not, it registers again (a
///    registration mDNSResponder lost, a stale TXT record). A browse that cannot run (no Local Network access) counts for nothing.
/// 3. **A controller is connected.** A paired accessory with no verified connection for `controllerSilence` is advertised again
///    once, and `controllerSilenceNote` says so ("Home hasn't contacted this camera for 12 min"): the person sees it before
///    they open Home and find the camera not responding.
///
/// `runOnce()` is one pass (tests drive it with their own clock, `now`); `start()` runs it every `interval` until `stop()`.
/// Portable: it reaches the network only through the server's transport and the injected `ServiceBrowsing`.
public actor HAPHealthMonitor {
    public struct Timing: Sendable, Equatable {
        public var interval: Duration
        public var probeTimeout: Duration
        public var browseTimeout: Duration
        public var bonjourMissesBeforeRestart: Int
        public var controllerSilence: Duration

        /// 30 s between passes, a 1 s loopback answer, a 3 s browse, 2 misses, 10 minutes without a controller.
        public init(interval: Duration = .seconds(30), probeTimeout: Duration = .seconds(1), browseTimeout: Duration = .seconds(3),
                    bonjourMissesBeforeRestart: Int = 2, controllerSilence: Duration = .seconds(600)) {
            self.interval = interval
            self.probeTimeout = probeTimeout
            self.browseTimeout = browseTimeout
            self.bonjourMissesBeforeRestart = bonjourMissesBeforeRestart
            self.controllerSilence = controllerSilence
        }
    }

    private let server: AccessoryServer
    private let browser: any ServiceBrowsing
    private let timing: Timing
    private let now: @Sendable () -> ContinuousClock.Instant
    private let log: Log
    private let name: String

    private var loop: Task<Void, Never>?
    private var bonjourMisses = 0
    private var bonjourUnavailableLogged = false
    private var lastControllerSeen: ContinuousClock.Instant
    private var reAdvertisedForSilence = false

    /// Set while a paired accessory has had no controller connected for `controllerSilence`; nil otherwise.
    public private(set) var controllerSilenceNote: String?
    /// Repairs made so far (tests).
    public private(set) var listenerRestarts = 0
    public private(set) var advertisingRestarts = 0

    /// `log`: the camera's HAP logger. `now`: replaced by tests.
    public init(server: AccessoryServer, name: String, browser: any ServiceBrowsing, timing: Timing = Timing(), log: Log,
                now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.server = server
        self.name = name
        self.browser = browser
        self.timing = timing
        self.log = log
        self.now = now
        lastControllerSeen = now()
    }

    deinit {
        loop?.cancel()
    }

    /// Runs a pass every `interval` until `stop()`. Holds the monitor only weakly between passes.
    public func start() {
        guard loop == nil else { return }
        let interval = timing.interval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self else { return }
                await self.runOnce()
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// The Mac woke: the time it slept says nothing about the controllers, so the silence is counted from now (they reconnect
    /// on their own once the network is back; `AccessoryServer.dropStaleConnections` has closed what they no longer hold).
    public func systemDidWake() {
        lastControllerSeen = now()
        reAdvertisedForSilence = false
        controllerSilenceNote = nil
        bonjourMisses = 0
    }

    /// One pass of the three checks.
    public func runOnce() async {
        await checkListener()
        guard !Task.isCancelled else { return }
        await checkBonjour()
        guard !Task.isCancelled else { return }
        await checkController()
    }

    // MARK: - Checks

    private func checkListener() async {
        switch await server.probeListener(timeout: timing.probeTimeout) {
        case .answered, .notListening:
            break   // not listening: the server is stopped or listening again by itself (`relistenNow`), nothing to add
        case .failed(let reason):
            listenerRestarts += 1
            log.error("The HAP listener of \(name) did not answer a check over loopback (\(reason)); restarting it")
            await server.restartListener(because: "it did not answer a loopback check")
        }
    }

    private func checkBonjour() async {
        guard let expected = await server.advertisedTXT else { return }   // not advertised (yet, or switched off): nothing to compare
        let serviceName = await server.advertisedName
        let seen = await browser.lookup(type: "_hap._tcp", name: serviceName, timeout: timing.browseTimeout)
        let problem: String
        switch seen {
        case .unavailable(let reason):
            if !bonjourUnavailableLogged {
                bonjourUnavailableLogged = true
                log.info("The Bonjour check of \(name) cannot run (\(reason))")
            }
            return
        case .found(let txt):
            bonjourUnavailableLogged = false
            let differing = ["id", "c#", "sf"].filter { txt[$0] != expected[$0] }
            if differing.isEmpty {
                if bonjourMisses > 0 { log.info("Bonjour shows \(name) as advertised again") }
                bonjourMisses = 0
                return
            }
            problem = "Bonjour shows " + differing.map { "\($0)=\(txt[$0] ?? "none") (expected \(expected[$0] ?? "none"))" }.joined(separator: ", ")
        case .notFound:
            bonjourUnavailableLogged = false
            problem = "Bonjour does not show it"
        }
        bonjourMisses += 1
        guard bonjourMisses >= timing.bonjourMissesBeforeRestart else {
            log.debug("\(name): \(problem) (check \(bonjourMisses) of \(timing.bonjourMissesBeforeRestart))")
            return
        }
        bonjourMisses = 0
        advertisingRestarts += 1
        log.warning("\(name): \(problem) in \(timing.bonjourMissesBeforeRestart) checks in a row; registering it again")
        await server.restartAdvertising()
    }

    private func checkController() async {
        let current = now()
        let (paired, sessions) = (await server.isPaired, await server.sessionCount)
        if sessions > 0 || !paired {
            if controllerSilenceNote != nil, sessions > 0 { log.info("Home is connected to \(name) again") }
            lastControllerSeen = current
            reAdvertisedForSilence = false
            controllerSilenceNote = nil
            return
        }
        let silent = current - lastControllerSeen
        guard silent >= timing.controllerSilence else { return }
        let minutes = Int(silent.components.seconds / 60)
        controllerSilenceNote = "Home hasn't contacted this camera for \(minutes) min"
        guard !reAdvertisedForSilence else { return }
        reAdvertisedForSilence = true
        advertisingRestarts += 1
        log.warning("No controller has been connected to \(name) for \(minutes) min although it is paired; registering it again")
        await server.restartAdvertising()
    }
}
