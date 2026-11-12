import BridgeSupport
import Foundation

/// Announces the bridge on the home network as `_camera-bridge._tcp`, the service the Apple TV app looks for. The instance name is the
/// bridge's name (cut to DNS-SD's 63 bytes), the port is the web port, and the TXT record is `id` (the box's identity for life: `GET viewer`'s
/// `bridge.id`), `name` (the bridge's name; cut to 250 bytes, on a character boundary, when `name=` and the name together would pass the 255
/// bytes of a TXT entry), `v` (the version) and `api` (`1`). The `_http._tcp` announcement for browsers is avahi's own service file and stays
/// as it is.
///
/// - `start` and `rename` say what is wanted and return at once: a task registers it through the platform's `ServiceAdvertiser`, one
///   registration at a time, so announcing never delays the web interface and a slow answer from avahi never delays a saved name. What
///   changes while a call to the advertiser is out is looked at when it returns: a stop withdraws the registration that has just come back, a
///   rename registers again.
/// - A rename withdraws the old registration first and then registers the new one, so the two never share an instance name (a name that is
///   cut can stay the same while the name in the TXT record changes).
/// - A registration that fails, when it is made or later (avahi restarted and dropped it), is withdrawn and tried again after `retryDelay`,
///   doubling up to `maximumRetryDelay`, as HAP's is. A failure is logged unless it is the one logged last.
/// - `stop` withdraws the registration and ends every retry.
actor ViewerAnnouncer {
    /// What is announced: the bridge's identity, name and version, and the port its web interface listens on.
    struct Announcement: Sendable, Equatable {
        var id: String
        var name: String
        var version: String
        var port: UInt16
    }

    static let serviceType = "_camera-bridge._tcp"
    /// The version of the HTTP interface the app speaks (TXT `api`).
    static let apiVersion = "1"
    /// A DNS-SD instance name is one label: at most 63 bytes of UTF-8.
    static let maximumInstanceNameBytes = 63
    /// A TXT entry is `key=value` in at most 255 bytes, and a registration with a longer one is refused whole; `name=` leaves 250.
    static let maximumNameBytesInTXT = 250

    private let advertiser: any ServiceAdvertiser
    private let retryDelay: Duration
    private let maximumRetryDelay: Duration
    private let log = Log(category: "bonjour")

    /// What the bridge wants announced; nil before `start` and after `stop`.
    private var wanted: Announcement?
    /// What is registered now; nil while nothing is, or a registration is under way.
    private(set) var announced: Announcement?
    private var service: (any AdvertisedService)?
    /// Listens for the registered service to fail.
    private var failureTask: Task<Void, Never>?
    /// The task registering `wanted`, nil when none is. At most one at a time.
    private var registration: Task<Void, Never>?
    /// Waiting to register again after a failure.
    private var retryTask: Task<Void, Never>?
    /// How long the next retry waits.
    private var nextDelay: Duration
    /// The failure logged last, so the same one is not logged at every retry.
    private var lastFailure: String?

    init(advertiser: any ServiceAdvertiser, retryDelay: Duration = .seconds(1), maximumRetryDelay: Duration = .seconds(60)) {
        self.advertiser = advertiser
        self.retryDelay = retryDelay
        self.maximumRetryDelay = maximumRetryDelay
        nextDelay = retryDelay
    }

    /// Safety net for an announcer released without `stop()`.
    deinit {
        failureTask?.cancel()
        retryTask?.cancel()
        service?.cancel()
    }

    // MARK: Asking

    /// Announces `announcement`, and keeps it announced until `stop()`.
    func start(_ announcement: Announcement) {
        wanted = announcement
        beginRegistering()
    }

    /// Announces the bridge under a new name. Nothing before `start` and after `stop`, nor for the name already announced.
    func rename(to name: String) {
        guard var renamed = wanted, renamed.name != name else { return }
        renamed.name = name
        wanted = renamed
        beginRegistering()
    }

    /// Withdraws the announcement and ends every retry. A registration whose answer is still out is withdrawn when it comes back.
    func stop() {
        wanted = nil
        retryTask?.cancel()
        retryTask = nil
        nextDelay = retryDelay
        lastFailure = nil
        withdraw()
    }

    // MARK: Registering

    /// Registers what is wanted now, unless a registration is under way (it looks again when its call returns). A retry that is waiting is
    /// replaced: something changed, so it is tried at once.
    private func beginRegistering() {
        retryTask?.cancel()
        retryTask = nil
        guard registration == nil else { return }
        registration = Task { [weak self] in await self?.register() }
    }

    /// Registers `wanted` until it is what is registered. Every `await` is a point where `start`, `rename`, `stop` and a failure of the service
    /// may run, so what the call was made for is compared with what is wanted when it returns.
    private func register() async {
        while let target = wanted, announced != target {
            withdraw()   // a registration of an older announcement: the new one takes its place
            let created: any AdvertisedService
            do {
                created = try await advertiser.advertise(Self.advertisement(for: target))
            } catch {
                guard let current = wanted else { break }   // stopped meanwhile: nothing to say, nothing to try again
                if current != target { continue }           // renamed meanwhile: the failure was the old name's, so the new one is tried now
                registrationFailed(error)
                break
            }
            guard wanted == target else {   // stopped or renamed meanwhile
                created.cancel()
                continue
            }
            service = created
            announced = target
            nextDelay = retryDelay
            lastFailure = nil
            watch(created)
            log.notice("Apple TVs and iPhones can find this bridge: “\(target.name)” (\(Self.serviceType)) on port \(target.port)")
        }
        registration = nil
    }

    private func watch(_ created: any AdvertisedService) {
        let failures = created.failures
        failureTask = Task { [weak self] in
            for await failure in failures {
                await self?.serviceFailed(failure, source: created)
            }
        }
    }

    /// The registered service reported a failure. News of a registration already withdrawn is ignored.
    private func serviceFailed(_ error: TransportError, source: any AdvertisedService) {
        guard let current = service, current === source else { return }
        withdraw()
        registrationFailed(error)
    }

    /// Withdraws the registration, if there is one.
    private func withdraw() {
        failureTask?.cancel()
        failureTask = nil
        service?.cancel()
        service = nil
        announced = nil
    }

    // MARK: Trying again

    /// A registration failed. It is said in the log unless it is what was said last, and tried again after the delay.
    private func registrationFailed(_ error: any Error) {
        let message = ErrorText.logDescription(error)
        if message != lastFailure {
            lastFailure = message
            log.warning("Apple TVs and iPhones cannot find this bridge yet: \(message); trying again")
        }
        scheduleRetry()
    }

    /// Registers again after `nextDelay`, which doubles for the next failure up to `maximumRetryDelay`. Holds the announcer only weakly while
    /// it waits.
    private func scheduleRetry() {
        let wait = nextDelay
        nextDelay = min(wait * 2, maximumRetryDelay)
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: wait)
            } catch {
                return
            }
            await self?.retryDue()
        }
    }

    private func retryDue() {
        guard !Task.isCancelled else { return }   // replaced or stopped while this was on its way to the announcer
        retryTask = nil
        beginRegistering()
    }

    // MARK: What is announced

    static func advertisement(for announcement: Announcement) -> ServiceAdvertisement {
        ServiceAdvertisement(name: instanceName(for: announcement.name), type: serviceType, port: announcement.port, txt: txt(for: announcement))
    }

    /// The TXT record the app reads: `id` is `GET viewer`'s `bridge.id`, `name` the bridge's name (all of it, cut to 250 bytes only when `name=`
    /// and the name together would pass a TXT entry's 255), `v` its version and `api` the version of the HTTP interface.
    static func txt(for announcement: Announcement) -> [String: String] {
        ["id": announcement.id, "name": prefix(of: announcement.name, bytes: maximumNameBytesInTXT), "v": announcement.version, "api": apiVersion]
    }

    /// The bridge's name as a DNS-SD instance name: cut to 63 bytes on a character boundary (60 accented letters or emoji are more), without
    /// blanks at either end, and "Camera Bridge" when nothing is left.
    static func instanceName(for bridgeName: String) -> String {
        let name = prefix(of: bridgeName.trimmingCharacters(in: .whitespacesAndNewlines), bytes: maximumInstanceNameBytes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? AuthStore.defaultBridgeName : name
    }

    /// The longest start of `text` that is at most `limit` bytes of UTF-8, in whole characters (a family emoji is one character of 25 bytes).
    private static func prefix(of text: String, bytes limit: Int) -> String {
        var bytes = 0
        for index in text.indices {
            bytes += text[index..<text.index(after: index)].utf8.count
            if bytes > limit { return String(text[..<index]) }
        }
        return text
    }
}
