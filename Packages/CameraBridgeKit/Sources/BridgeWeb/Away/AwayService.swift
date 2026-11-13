import BridgeEngine
import BridgeSupport
import Foundation

/// Away from home, from the daemon's side (docs/superpowers/specs/2026-11-12-away-from-home-design.md). It keeps the devices and the tunnel's
/// subnet in `away.json` (`AwayState`), has the system's `cb-away` hold the WireGuard interface to match (`SystemControlling.setAway`, always the
/// whole list), keeps the box's stable global IPv6 address published for its away name through the secure address's signed client, notices the
/// devices that reach the box from away, and answers the page's card and the phones' tunnel document.
///
/// The state is the owner's record, and the system follows it. Every change runs inside one lock and sends the whole list, so two changes close
/// together can't leave the system with the older list. A change the system did not take is tried again at the next look, and the first look of
/// each instance makes the system match the state. Only a system with Away from home (`awayStatus() != nil`) and a network to read takes part.
actor AwayService {
    /// How often the service looks without being told the network changed. The change signal does not fire when an address is deprecated, when
    /// its preferred lifetime runs down or when the IPv6 default route moves, so every look chooses the address again.
    static let interval: Duration = .seconds(30)
    /// The website hears from the box at most once a minute. The same address is sent again twice a day, which the website counts as the day's
    /// refresh, not as a change: it deletes a record nobody refreshed for a week.
    static let minimumPublishGap: TimeInterval = 60
    static let refreshAfter: TimeInterval = 12 * 3600
    /// The address changes `away.json` keeps, to learn how often the home's prefix changes.
    static let keptChanges = 50
    /// The card's problem for a tunnel the system reports as failed without saying why.
    static let tunnelFailed = "The system reports that Away from home’s VPN isn’t working."
    /// Added to the card's problem while the system still holds a key the owner removed.
    static let removalPending = "A removed device can still connect until the box’s retry goes through."

    /// A website call that a look decided on. It is made outside the lock, so it never holds up a device change.
    private struct WebsiteCall {
        enum Kind { case publish(String), withdraw }
        var kind: Kind
        /// `generation` when the call was decided: an answer that arrives after Away from home was turned off or on again is about a state
        /// that is gone, and that turn made its own call.
        var generation: Int
    }

    private enum WebsiteAnswer {
        case published(name: String)
        case withdrawn
        case failed(BoxClientError)
    }

    private let system: any SystemControlling
    private let secureAddress: SecureAddressService
    private let auth: AuthStore
    private let network: (any AwayNetwork)?
    private let directory: URL
    private let cameraAddresses: @Sendable () async -> [String]
    private let now: @Sendable () -> Date
    private let log = Log(category: "away")
    /// Every change of the state runs inside it, in the order the callers came.
    private let serial = AsyncSerialLock()
    private var state: AwayState
    /// The stable global IPv6 address the last look chose; nil while the box has none.
    private var currentAddress: String?
    /// Whether a look has run since the service started or Away from home was turned on: the card says `checking` until then. Not kept.
    private var checked = false
    /// Whether this instance has looked yet. Its first look makes the system match the state, whoever calls it.
    private var looked = false
    /// A look's website call is under way; another look leaves the website alone meanwhile.
    private var websiteBusy = false
    /// Counts the turns on and off (see `WebsiteCall.generation`).
    private var generation = 0
    /// The website's refusal of the last address sent, for the card. Not kept: the next try says it again.
    private var websiteProblem: String?
    /// The last warning written: a failure that repeats at every look is written once, until something works again.
    private var lastWarning: String?
    private var saveFailed = false
    private var loops: [Task<Void, Never>] = []

    /// What a take-out gives the route that answers it, to end that one removal's hold once its answer is out (`settleRemoval`).
    struct Hold: Equatable, Sendable { fileprivate let number: Int }
    private struct Held {
        var hold: Hold
        var device: AwayDevice
        /// The fallback: after this the hold is over even if its answer never went out.
        var until: ContinuousClock.Instant
    }
    /// The devices taken out whose answers have not gone out yet (`takeOut`), each with its own hold, so the answer to one removal never
    /// releases another's key early. Not kept: after a restart the owed change applies at the first look.
    private var held: [Held] = []
    private var holdsMade = 0

    /// `cameraAddresses`: the cameras' hosts, which the tunnel's subnet avoids. `directory`: the data directory, which holds `away.json`.
    init(system: any SystemControlling, secureAddress: SecureAddressService, auth: AuthStore, network: (any AwayNetwork)?, directory: URL,
         cameraAddresses: @escaping @Sendable () async -> [String] = { [] }, now: @escaping @Sendable () -> Date = { Date() }) {
        self.system = system
        self.secureAddress = secureAddress
        self.auth = auth
        self.network = network
        self.directory = directory
        self.cameraAddresses = cameraAddresses
        self.now = now
        let loaded = AwayState.load(from: directory)
        state = loaded
        // Until the first look, the card and the documents show the address the box had before the restart.
        currentAddress = loaded.on ? loaded.lastAddress : nil
    }

    var isOn: Bool { state.on }

    // MARK: Running

    /// Looks at once, then every 30 s and whenever the network says the addresses may have changed. Without a network there is nothing to do.
    func start() {
        guard loops.isEmpty, let network else { return }
        // Subscribed before this returns, so a change right after the start is not lost.
        let changed = network.changes
        loops = [
            Task { [weak self] in
                while !Task.isCancelled {
                    await self?.tick()
                    try? await Task.sleep(for: AwayService.interval)
                }
            },
            Task { [weak self] in
                for await _ in changed { await self?.tick() }
            },
        ]
    }

    func stop() {
        for loop in loops { loop.cancel() }
        loops = []
    }

    /// One look. While on: the system's status and the box's addresses, the devices' handshakes from away, the stable address and its changes,
    /// and the publish that is due. While off: only a change or a delete the website is still owed. The lock is held while the state is read and
    /// written, never across the website call.
    func tick() async {
        guard let network else { return }
        guard let call = await serial.withLock({ await look(network) }) else { return }
        let answer = await perform(call.kind)
        await serial.withLock {
            websiteBusy = false
            record(answer, of: call)
        }
    }

    private func look(_ network: any AwayNetwork) async -> WebsiteCall? {
        guard var status = await system.awayStatus() else { return nil }
        let before = state
        let first = !looked
        looked = true
        var mustApply = state.applyPending && !isHolding
        if await removeUnpairedPhones() { mustApply = true }
        if state.on, state.subnet == nil {
            // A state written by hand or by an older version can be on without a subnet, and the request needs one.
            state.subnet = await chosenSubnet(network)
            mustApply = true
        }
        // The state is the owner's record. The first look makes the system match it: after a restart between a change and its job, or a tunnel
        // the system reports as failed.
        if first, Self.differs(status, from: state) { mustApply = true }
        if mustApply {
            await apply()
            status = await system.awayStatus() ?? status
        }
        guard state.on else {
            guard state.withdrawPending, !websiteBusy, websiteFree else { return nil }
            websiteBusy = true
            return WebsiteCall(kind: .withdraw, generation: generation)
        }
        noteHandshakes(status, ownPrefixes: await network.ownPrefixes())
        noteAddress(among: await network.globalIPv6())
        checked = true
        if state != before { save() }
        guard let address = currentAddress, !websiteBusy, publishIsDue(address) else { return nil }
        websiteBusy = true
        return WebsiteCall(kind: .publish(address), generation: generation)
    }

    /// Takes out the phones whose pairing is gone: removed behind this service's back, or lapsed (a year unused, or a key nobody collected).
    /// True when one was.
    private func removeUnpairedPhones() async -> Bool {
        guard state.devices.contains(where: { $0.kind == .app }) else { return false }
        let paired = Set(await auth.viewers().map(\.id))
        let gone = state.devices.filter { $0.kind == .app && !paired.contains($0.id) }
        guard !gone.isEmpty else { return false }
        state.devices.removeAll { $0.kind == .app && !paired.contains($0.id) }
        for device in gone { log.notice("a phone that is no longer paired lost its Away from home key (\(device.name))") }
        return true
    }

    /// Whether the system's tunnel is other than the state: on or off, another list of keys, or failed.
    private static func differs(_ status: AwayStatus, from state: AwayState) -> Bool {
        (status.state != "off") != state.on || status.state == "failed" || Set(status.peers.map(\.publicKey)) != Set(state.devices.map(\.publicKey))
    }

    /// A device's newer handshake counts as a trip from away when its endpoint is on none of the box's prefixes and is no private address.
    private func noteHandshakes(_ status: AwayStatus, ownPrefixes: [String]) {
        for index in state.devices.indices {
            guard let peer = status.peers.first(where: { $0.publicKey == state.devices[index].publicKey }), peer.latestHandshake > 0,
                  AwayRules.isFromAway(peer.endpoint, ownPrefixes: ownPrefixes) else { continue }
            let at = Date(timeIntervalSince1970: TimeInterval(peer.latestHandshake))
            if state.devices[index].lastAwayAt.map({ at > $0 }) ?? true { state.devices[index].lastAwayAt = at }
        }
    }

    /// Chooses the address to publish: the one before while it still qualifies (`AwayRules.stableAddress`). Another one than before is a change:
    /// its time is kept for the card and in `changes`, and the log says so without the address, which stays in the box's own file. While the box
    /// has no address the last one is kept, so the next is compared with it.
    private func noteAddress(among addresses: [AwayAddress]) {
        let chosen = AwayRules.stableAddress(among: addresses, previous: state.lastAddress).map { StreamAddress.canonical($0.address) }
        currentAddress = chosen
        guard let chosen else { return }
        if let last = state.lastAddress, StreamAddress.canonical(last) != chosen {
            let at = now()
            state.addressChangedAt = at
            state.changes = Array((state.changes + [AwayState.AddressChange(at: at, address: chosen)]).suffix(Self.keptChanges))
            log.notice("the box’s global IPv6 address changed; Away from home sends the new one to the website")
        }
        state.lastAddress = chosen
    }

    /// A changed address, or the same one after 12 hours; never within a minute of the last send, and never while the website is waited for. A
    /// last send in the future means the clock was set back since, and is not waited for.
    private func publishIsDue(_ address: String) -> Bool {
        let since = state.publishedAt.map { now().timeIntervalSince($0) }
        let changed = state.publishedAddress.map { StreamAddress.canonical($0) != address } ?? true
        let stale = since.map { $0 >= Self.refreshAfter || $0 < 0 } ?? true
        let spaced = since.map { $0 >= Self.minimumPublishGap || $0 < 0 } ?? true
        return (changed || stale) && spaced && websiteFree
    }

    /// Whether the website may be asked: not while a wait after a failure lasts.
    private var websiteFree: Bool { state.websiteWaitUntil.map { $0 <= now() } ?? true }

    // MARK: The website

    private func perform(_ kind: WebsiteCall.Kind) async -> WebsiteAnswer {
        do {
            switch kind {
            case .publish(let address):
                return .published(name: try await secureAddress.publishAway(ip: address))
            case .withdraw:
                try await secureAddress.withdrawAway()
                return .withdrawn
            }
        } catch let error as BoxClientError {
            return .failed(error)
        } catch {
            // Only the box's own side fails this way (its identity could not be read or used), and it is waited for like a website out of reach.
            log.warning("Away from home could not sign its call to the website: \(ErrorText.logDescription(error))")
            return .failed(BoxClientError(kind: .unreachable, message: "The box couldn’t sign its call to the Camera Bridge website. It will try again."))
        }
    }

    /// Keeps what the website answered, unless Away from home was turned off or on since the call was decided.
    private func record(_ answer: WebsiteAnswer, of call: WebsiteCall) {
        guard call.generation == generation else { return }
        switch answer {
        case .published(let name):
            guard case .publish(let address) = call.kind else { return }
            state.name = name
            state.publishedAddress = address
            state.publishedAt = now()
            websiteProblem = nil
            websiteAnswered()
            log.notice("told the website the box’s address for Away from home")
        case .withdrawn:
            state.withdrawPending = false
            websiteAnswered()
            log.notice("the website deleted the box’s away record")
        case .failed(let error):
            // A refusal is the card's problem, since waiting won't change the website's mind. Any other failure goes by itself and is only
            // waited for: out of reach, not ready, too many requests, or a server error (the website's 500 when its database or its DNS
            // provider fails), which would otherwise hold the card on a problem for the whole wait.
            if case .publish = call.kind { websiteProblem = [.refused, .unauthorized].contains(error.kind) ? error.message : nil }
            websiteFailed(error)
        }
        save()
    }

    private func websiteAnswered() {
        state.websiteFailures = 0
        state.websiteWaitUntil = nil
        lastWarning = nil
    }

    /// The website is left alone after a failure the way the secure address leaves it (10 minutes, growing to 6 hours; too many requests waits
    /// for the website's next day), so a broken website is never asked once a minute. `.notRegistered` sent nothing (the secure address has no
    /// TLS front or no name yet), so it only waits for the next look.
    private func websiteFailed(_ error: BoxClientError) {
        warn("Away from home: \(error.message)")
        guard error.kind != .notRegistered else { return }
        state.websiteFailures += 1
        state.websiteWaitUntil = SecureAddressRules.websiteWait(after: error.kind, failures: state.websiteFailures, now: now())
    }

    // MARK: On and off

    /// Turns Away from home on or off and answers the card. On also turns the secure address on, picks the tunnel's subnet once, and looks at
    /// once. Off empties the devices, has the system remove the tunnel and asks the website to delete the record; the subnet, the away name and
    /// the address changes stay. A change the system did not take is no error here: the owner's choice is kept, the card says what failed, and
    /// the next look tries again (the page's Try again sends the same choice).
    func setOn(_ on: Bool) async throws -> AwayCard {
        guard let network, await system.awayStatus() != nil else { throw AwayFailure.unavailable }
        if on, !(await secureAddress.report().enabled) {
            // The phone talks HTTPS to the secure name through the tunnel, so Away from home needs the secure address.
            await secureAddress.setEnabled(true)
        }
        let applied = await serial.withLock {
            if on { await turnOn(network) } else { await turnOff() }
        }
        if on, applied { await tick() }
        return try await card()
    }

    /// True when the system took it. Turning on is also the card's Try again, so it forgets the website's last refusal and the wait after a
    /// failure, as the secure address's own Try again does: the look that follows asks the website at once. The minute between two sends
    /// still holds (`publishIsDue`).
    private func turnOn(_ network: any AwayNetwork) async -> Bool {
        generation += 1
        if state.subnet == nil { state.subnet = await chosenSubnet(network) }
        state.on = true
        // The next publish sets the record again, so a delete still owed from turning off is not needed any more.
        state.withdrawPending = false
        state.websiteWaitUntil = nil
        websiteProblem = nil
        checked = false
        save()
        return await apply() == nil
    }

    /// True when the system took it. The website is asked to delete the record now, whatever the waits say: turning off is the owner's choice,
    /// and a delete is no address change on the website. When it fails, the delete stays owed and a later look sends it after the wait.
    private func turnOff() async -> Bool {
        generation += 1
        state.on = false
        state.devices = []
        held = []   // turning off removes every key at once
        state.lastAddress = nil
        state.publishedAddress = nil
        state.addressChangedAt = nil
        // Kept before the website is asked, so a restart in the middle still deletes the record.
        state.withdrawPending = true
        currentAddress = nil
        checked = false
        websiteProblem = nil
        save()
        let applied = await apply() == nil
        record(await perform(.withdraw), of: WebsiteCall(kind: .withdraw, generation: generation))
        return applied
    }

    /// A new random subnet that avoids the networks the box and its cameras are on (`AwayRules.chooseSubnet`).
    private func chosenSubnet(_ network: any AwayNetwork) async -> String {
        let avoided = await network.ownPrefixes() + cameraAddresses()
        var generator = SystemRandomNumberGenerator()
        return AwayRules.chooseSubnet(avoiding: avoided, using: &generator)
    }

    /// Sends the whole state to the system: on or off, the subnet, and every device's key and address. Nil when the system took it; otherwise
    /// the sentence that says why not, which stays the card's problem (`applyError`) until a later try works.
    @discardableResult
    private func apply() async -> String? {
        // A key whose removal still waits for its answer stays in the list, so another change can't drop it early.
        let kept = heldDevices()
        let peers = (state.devices + kept).map { AwayRequest.Peer(publicKey: $0.publicKey, address: $0.address) }
        do {
            try await system.setAway(AwayRequest(on: state.on, subnet: state.subnet, peers: peers))
            state.applyPending = !kept.isEmpty
            state.applyError = nil
            lastWarning = nil
            save()
            return nil
        } catch {
            let sentence = (error as? SystemError)?.message ?? ErrorText.describe(error)
            if !(error is SystemError) { log.warning("Away from home: \(ErrorText.logDescription(error))") }
            state.applyPending = true
            state.applyError = sentence
            save()
            warn("Away from home: the system did not take the change: \(sentence)")
            return sentence
        }
    }

    // MARK: Devices

    /// Adds a device that uses the WireGuard app and answers its configuration. Its key pair is made here, in memory: the private half goes into
    /// the configuration only (the page shows it once as a QR code) and is never kept, logged or sent to the system.
    func addWireGuardDevice(name: String?) async throws -> (device: AwayCard.Device, config: String) {
        try await requireAvailable()
        return try await serial.withLock {
            guard state.on else { throw AwayFailure.off }
            guard let name = AwayRules.cleanedName(name) else { throw AwayFailure.badName }
            guard let subnet = state.subnet else { throw AwayFailure.notReady }
            guard state.devices.filter({ $0.kind == .wireguard }).count < AwayRules.maximumWireGuardDevices,
                  let address = AwayRules.nextDeviceAddress(subnet: subnet, taken: takenAddresses()) else { throw AwayFailure.tooManyDevices }
            // The away name holds a TXT record that a WireGuard app can't read, so the device is given the box's address itself.
            guard let endpoint = AwayRules.endpoint(address: currentAddress) else { throw AwayFailure.noAddress }
            guard let boxKey = await system.awayStatus()?.publicKey else { throw AwayFailure.notReady }
            let keys = AwayKeyPair()
            let device = AwayDevice(id: Secrets.hex(Secrets.randomBytes(16)), kind: .wireguard, name: name, publicKey: keys.publicKey, address: address,
                                    created: now())
            state.devices.append(device)
            save()
            if let failure = await apply() {
                // Taken out again: a configuration the system doesn't hold would never connect.
                state.devices.removeAll { $0.id == device.id }
                save()
                throw AwayFailure.system(failure)
            }
            log.notice("a device with the WireGuard app was added to Away from home (\(name))")
            let config = AwayRules.wireGuardConfig(privateKey: keys.privateKey, address: address, boxPublicKey: boxKey, endpoint: endpoint,
                                                   allowedIPs: await routes(subnet: subnet))
            return (AwayCard.Device(id: device.id, kind: device.kind.rawValue, name: name, lastHandshake: nil, lastAwayAt: nil), config)
        }
    }

    /// Removes a device of either kind; a phone stays paired but loses away access. A removal is never undone, since a key put back would work
    /// again after the next try: when the system does not take it, the device stays removed and every look tries again. The call still throws
    /// `.system`, so the page doesn't take the device for gone, and the card says it can connect until a try goes through.
    func removeDevice(id: String) async throws {
        try await requireAvailable()
        try await serial.withLock {
            guard let device = state.devices.first(where: { $0.id == id }) else { throw AwayFailure.noSuchDevice }
            remove(device)
            if let failure = await apply() { throw AwayFailure.system(failure) }
        }
    }

    /// The hook for a phone removed in Settings › Security: its key leaves the system at once, as `removeDevice` takes it out. Unlike
    /// `removeDevice` it doesn't throw: the pairing is gone already, and a failure shows on the card.
    func removeAppDevice(viewerID: String) async {
        await serial.withLock {
            guard let device = state.devices.first(where: { $0.kind == .app && $0.id == viewerID }) else { return }
            remove(device)
            await apply()
        }
    }

    /// How long the last packet of an answer gets after `afterSend` before the system is asked to drop a key.
    static let lastPacketDelay: Duration = .milliseconds(100)
    /// How long a removal is held back at most. A connection whose answer never finishes would otherwise keep the key for good; after this the
    /// next look applies it.
    static let holdFallback: Duration = .seconds(5)

    /// True when `address` is a tunnel address of this box: a request from there came through the tunnel, so dropping a peer's key may cut the
    /// very connection that asked.
    func isTunnelAddress(_ address: String) -> Bool {
        guard state.on, let subnet = state.subnet else { return false }
        return address.hasPrefix(String(subnet.dropLast("0/24".count)))
    }

    /// The first half of a removal for a route that answers before the system is asked: the device is out of the record and saved, and the change
    /// is marked as owed, so a look applies it after a restart even if `settleRemoval` never runs. Until this answer has gone out (or the fallback
    /// has passed) the key stays in what the system is sent, whoever asks. Throws `.noSuchDevice`.
    @discardableResult
    func takeOutDevice(id: String) async throws -> Hold {
        try await requireAvailable()
        return try await serial.withLock {
            guard let device = state.devices.first(where: { $0.id == id }) else { throw AwayFailure.noSuchDevice }
            return takeOut(device)
        }
    }

    /// `takeOutDevice` for the phone `viewerID` names, which is not an error when it has no device (nil: nothing to hold): a phone turning Away
    /// from home off asks whether it is on or not, and a box without Away from home has nothing to take out.
    @discardableResult
    func takeOutAppDevice(viewerID: String) async -> Hold? {
        guard network != nil, await system.awayStatus() != nil else { return nil }
        return await serial.withLock {
            guard let device = state.devices.first(where: { $0.kind == .app && $0.id == viewerID }) else { return nil }
            return takeOut(device)
        }
    }

    /// The second half, once `hold`'s answer is out: ends that hold, and that hold only (another removal's key stays until its own answer is
    /// out), and sends the system what is owed. A failure stays on the card (`applyError`, with the removal-pending sentence) and every look
    /// tries again.
    func settleRemoval(_ hold: Hold) async {
        await serial.withLock {
            held.removeAll { $0.hold == hold }
            if state.applyPending { await apply() }
        }
    }

    private func takeOut(_ device: AwayDevice) -> Hold {
        remove(device)
        holdsMade += 1
        let hold = Hold(number: holdsMade)
        let now = ContinuousClock.now
        held.removeAll { $0.until <= now }   // over by their fallback
        held.append(Held(hold: hold, device: device, until: now + Self.holdFallback))
        state.applyPending = true
        save()
        return hold
    }

    /// Whether a removal is being held back for its answer.
    private var isHolding: Bool {
        let now = ContinuousClock.now
        return held.contains { $0.until > now }
    }

    /// The devices whose removal waits for its answer, each key once and none the record has again (the system refuses a key twice).
    private func heldDevices() -> [AwayDevice] {
        let now = ContinuousClock.now
        var keys = Set(state.devices.map(\.publicKey))
        return held.filter { $0.until > now }.map(\.device).filter { keys.insert($0.publicKey).inserted }
    }

    /// The tunnel addresses in use, including a held device's: its address is still in what the system holds, and it can't be given twice.
    private func takenAddresses() -> [String] {
        (state.devices + heldDevices()).map(\.address)
    }

    private func remove(_ device: AwayDevice) {
        state.devices.removeAll { $0.id == device.id }
        save()
        log.notice("a device was removed from Away from home (\(device.name))")
    }

    /// Sets a paired phone's one device key, replacing an earlier one at the same tunnel address, and answers the tunnel document. The same key
    /// again changes nothing and runs no job.
    func setAppDevice(viewer: AuthStore.ViewerInfo, publicKey: String) async throws -> TunnelDocument {
        try await requireAvailable()
        return try await serial.withLock {
            guard state.on else { throw AwayFailure.off }
            let secure = try await routedSecureAddress()
            guard AwayRequest.isPublicKey(publicKey) else { throw AwayFailure.badKey }
            // The phone's key was checked a moment ago, but the owner may have removed the phone since; its device must not come back.
            guard await auth.isViewerListed(viewer.id) else { throw AwayFailure.notSetUp }
            guard let subnet = state.subnet, let boxKey = await system.awayStatus()?.publicKey else { throw AwayFailure.notReady }
            // The box's own key, or another device's, would make the system refuse the whole list.
            let others = state.devices.filter { !($0.kind == .app && $0.id == viewer.id) }
            guard publicKey != boxKey, !others.contains(where: { $0.publicKey == publicKey }) else { throw AwayFailure.badKey }
            let previous = state.devices.first { $0.kind == .app && $0.id == viewer.id }
            if let previous, previous.publicKey == publicKey { return document(for: previous, subnet: subnet, boxKey: boxKey, secure: secure) }
            guard let address = previous?.address ?? AwayRules.nextDeviceAddress(subnet: subnet, taken: takenAddresses()) else {
                throw AwayFailure.tooManyDevices
            }
            let device = AwayDevice(id: viewer.id, kind: .app, name: viewer.name, publicKey: publicKey, address: address, created: previous?.created ?? now(),
                                    lastAwayAt: previous?.lastAwayAt)
            setPhone(device, in: viewer.id)
            if let failure = await apply() {
                // As it was: the phone keeps the key that works and can try again.
                setPhone(previous, in: viewer.id)
                throw AwayFailure.system(failure)
            }
            log.notice(previous == nil ? "a phone was added to Away from home (\(viewer.name))" : "a phone gave Away from home a new key (\(viewer.name))")
            return document(for: device, subnet: subnet, boxKey: boxKey, secure: secure)
        }
    }

    /// Puts `device` in the place of the phone `viewerID` names (nil takes it out), and saves.
    private func setPhone(_ device: AwayDevice?, in viewerID: String) {
        if let index = state.devices.firstIndex(where: { $0.kind == .app && $0.id == viewerID }) {
            if let device { state.devices[index] = device } else { state.devices.remove(at: index) }
        } else if let device {
            state.devices.append(device)
        }
        save()
    }

    /// The tunnel document of the phone that `viewerID` names, with the current endpoint and routes.
    func tunnelDocument(viewerID: String) async throws -> TunnelDocument {
        try await requireAvailable()
        guard state.on else { throw AwayFailure.off }
        guard let device = state.devices.first(where: { $0.kind == .app && $0.id == viewerID }) else { throw AwayFailure.notSetUp }
        let secure = try await routedSecureAddress()
        guard let subnet = state.subnet, let boxKey = await system.awayStatus()?.publicKey else { throw AwayFailure.notReady }
        return document(for: device, subnet: subnet, boxKey: boxKey, secure: secure)
    }

    /// The secure address's link and the home address its name points at. A phone reaches the box by its secure name through the tunnel, so
    /// without a name, or before the secure address knows the home address, a phone would have nothing to route (`.secureAddressOff`).
    private func routedSecureAddress() async throws -> (url: String, home: String) {
        let report = await secureAddress.report()
        guard let url = report.url, let home = report.address else { throw AwayFailure.secureAddressOff }
        return (url, home)
    }

    private func document(for device: AwayDevice, subnet: String, boxKey: String, secure: (url: String, home: String)) -> TunnelDocument {
        TunnelDocument(boxPublicKey: boxKey, endpoint: .init(host: state.name, port: AwayRules.port, addresses: currentAddress.map { [$0] } ?? []),
                       address: "\(device.address)/32", routes: ["\(AwayRules.boxAddress(subnet: subnet))/32", "\(secure.home)/32"],
                       secureURL: secure.url, mtu: AwayRules.mtu)
    }

    /// What a WireGuard-app device sends through the tunnel: the box's tunnel address, and the home address once the secure address knows it
    /// (the secure name points there, so the box's own page opens by its name through the tunnel).
    private func routes(subnet: String) async -> [String] {
        let home = await secureAddress.report().address
        return ["\(AwayRules.boxAddress(subnet: subnet))/32"] + (home.map { ["\($0)/32"] } ?? [])
    }

    private func requireAvailable() async throws {
        guard network != nil, await system.awayStatus() != nil else { throw AwayFailure.unavailable }
    }

    // MARK: The card

    /// The card. `.unavailable` on a system without Away from home.
    func card() async throws -> AwayCard {
        guard network != nil, let status = await system.awayStatus() else { throw AwayFailure.unavailable }
        guard state.on else {
            // Only a change the system did not take shows while off: the tunnel may still be up.
            let problem = applyProblem(status)
            return AwayCard(on: false, state: AwayRules.cardState(on: false, checked: checked, problem: problem, address: nil, lastAway: nil, addressChangedAt: nil),
                            problem: problem, port: AwayRules.port, address: nil, name: nil, router: nil, addressChangedAt: nil, devices: [])
        }
        let failed = status.state == "failed" ? status.message ?? Self.tunnelFailed : nil
        let problem = applyProblem(status) ?? failed ?? websiteProblem
        let handshakes = Dictionary(status.peers.map { ($0.publicKey, $0.latestHandshake) }, uniquingKeysWith: max)
        let devices = Self.ordered(state.devices).map { device in
            AwayCard.Device(id: device.id, kind: device.kind.rawValue, name: device.name,
                            lastHandshake: handshakes[device.publicKey].flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
                            lastAwayAt: device.lastAwayAt)
        }
        let shown = AwayRules.cardState(on: true, checked: checked, problem: problem, address: currentAddress, lastAway: state.devices.compactMap(\.lastAwayAt).max(),
                                        addressChangedAt: state.addressChangedAt)
        return AwayCard(on: true, state: shown, problem: problem, port: AwayRules.port, address: currentAddress, name: state.name, router: status.router,
                        addressChangedAt: state.addressChangedAt, devices: devices)
    }

    /// The problem of a change the system did not take (`applyError`). While the system still lists a key the state no longer holds (a device
    /// removed, or every device when Away from home was turned off), that device can still connect, and the card says so until a try goes
    /// through.
    private func applyProblem(_ status: AwayStatus) -> String? {
        guard let error = state.applyError else { return nil }
        let kept = Set(state.devices.map(\.publicKey))
        guard status.peers.contains(where: { !kept.contains($0.publicKey) }) else { return error }
        return "\(error) \(Self.removalPending)"
    }

    /// The card's order, which the page keeps: the devices that reached the box from away, the newest first, then the others as they were added.
    private static func ordered(_ devices: [AwayDevice]) -> [AwayDevice] {
        devices.sorted { lhs, rhs in
            switch (lhs.lastAwayAt, rhs.lastAwayAt) {
            case let (left?, right?) where left != right: left > right
            case (.some, nil): true
            case (nil, .some): false
            default: (lhs.created, lhs.id) < (rhs.created, rhs.id)
            }
        }
    }

    // MARK: Keeping

    private func save() {
        let saved = state.save(to: directory)
        if !saved, !saveFailed { log.error("Away from home could not save its state; the change holds until the box restarts") }
        saveFailed = !saved
    }

    private func warn(_ message: String) {
        guard message != lastWarning else { return }
        lastWarning = message
        log.warning(message)
    }
}
