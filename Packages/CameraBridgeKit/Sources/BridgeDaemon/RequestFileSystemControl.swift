import BridgeEngine
import BridgeSupport
import BridgeWeb
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// The operating system, through the request files of Camera Bridge OS (`linux/os/README.md` is the contract).
///
/// The daemon runs as an unprivileged user and never starts anything privileged. To ask the system for something it writes one
/// small JSON file, `<requests>/<name>.json`, where `<name>` is one of a fixed list (`Request`); a root helper (started by a
/// systemd path unit) validates it again, deletes it and does the work, and publishes how it goes as JSON files in `<status>`:
///
///     status/<name>.json            {state: queued | running | ok | failed, message, updatedAt}   for every request
///     status/update.json            {state: checking | available | current | downloading | installing | installed | failed,
///                                    current, latest, updateAvailable, notes, checkedAt, rebootRequired, message, updatedAt}
///     status/install-candidates.json  {disks: [{name, path, model, sizeBytes, partitions, eligible, problems, phrase, ...}]}
///     status/install-to-disk.json   {state, step, device, message, updatedAt}
///     status/system.json            {version, sshEnabled, autoUpdate, bootEntry, updatedAt}
///     status/guard.json             {available, running, timeZone, todayStart, cameras: [{address, level, today, last24h, names: [...]}], updatedAt}
///
/// Nothing here waits without a bound: a check for updates gives up after 60 seconds, a request nobody picks up within 15 seconds
/// is withdrawn and reported. A request file is written whole under a temporary name and moved into place (`rename`), so the
/// helper never sees half a file, the name comes from `Request` and never from input, and every value in a body is validated here
/// (and again by the helper).
///
/// Where the two folders do not exist (a Mac, a plain Linux box) the system reports itself as "development" and refuses
/// everything privileged.
public struct RequestFileSystemControl: SystemControlling {
    /// The requests the helper accepts, and the only file names this code ever writes.
    enum Request: String {
        case updateCheck = "update-check"
        case updateApply = "update-apply"
        case autoUpdate = "auto-update"
        case sshEnable = "ssh-enable"
        case sshDisable = "ssh-disable"
        case reboot
        case poweroff
        case factoryReset = "factory-reset"
        case installList = "install-list"
        case installToDisk = "install-to-disk"
        case driveList = "drive-list"
        case driveUse = "drive-use"
        case driveForget = "drive-forget"
        case wifiScan = "wifi-scan"
        case wifiJoin = "wifi-join"
        case wifiForget = "wifi-forget"
        case guardSet = "guard-set"
    }

    /// The files the system publishes.
    private enum StatusFile {
        case job(Request)
        case update, system, installCandidates, installToDisk, recordingDrive, recordingDriveCandidates, wifi, wifiNetworks, internetGuard

        var name: String {
            switch self {
            case .job(let request): "\(request.rawValue).json"
            case .update: "update.json"
            case .system: "system.json"
            case .installCandidates: "install-candidates.json"
            case .installToDisk: "install-to-disk.json"
            case .recordingDrive: "recording-drive.json"
            case .recordingDriveCandidates: "recording-drive-candidates.json"
            case .wifi: "wifi.json"
            case .wifiNetworks: "wifi-networks.json"
            case .internetGuard: "guard.json"
            }
        }
    }

    /// How long and how often to wait.
    public struct Timing: Sendable {
        public var pollInterval: Duration = .milliseconds(500)
        /// A check for updates (the system asks the network).
        public var updateCheck: Duration = .seconds(60)
        /// Until the helper has taken a request (deleted its file).
        public var pickup: Duration = .seconds(15)
        /// Short jobs whose result the person waits for (SSH, automatic updates, the disk list).
        public var shortJob: Duration = .seconds(30)
        public init() {}
    }

    /// Facts about the machine for the system page; the status files do not carry them.
    public struct HostFacts: Sendable, Equatable {
        public var osName: String?
        public var hostname: String?
        public var hardware: String?
        public var architecture: String?
        /// The system runs from a USB drive (the installer stick), not from the machine's own disk. nil when it can't be told.
        public var runningFromUSB: Bool?

        public init(osName: String? = nil, hostname: String? = nil, hardware: String? = nil, architecture: String? = nil, runningFromUSB: Bool? = nil) {
            self.osName = osName
            self.hostname = hostname
            self.hardware = hardware
            self.architecture = architecture
            self.runningFromUSB = runningFromUSB
        }

        /// Whether the device mounted at `/` (from `/proc/self/mountinfo`) sits on USB: `devicePath` gives a block device's real path in
        /// /sys (`/sys/devices/pci…/usb2/…/block/sdb/sdb2`).
        static func runningFromUSB(mountInfo: String, devicePath: (String) -> String?) -> Bool? {
            for line in mountInfo.split(separator: "\n") {
                let fields = line.split(separator: " ")
                guard fields.count > 4, fields[4] == "/", let dash = fields.firstIndex(of: "-"), fields.index(dash, offsetBy: 2) < fields.endIndex else { continue }
                let source = String(fields[fields.index(dash, offsetBy: 2)])
                guard source.hasPrefix("/dev/") else { return nil }
                guard let path = devicePath(String(source.dropFirst(5))) else { return nil }
                return path.contains("/usb")
            }
            return nil
        }

        public static func current() -> HostFacts {
            var name = [CChar](repeating: 0, count: 256)
            let host = gethostname(&name, name.count - 1) == 0
                ? String(decoding: name.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
            var machine = utsname()
            let architecture = uname(&machine) == 0
                ? withUnsafeBytes(of: &machine.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) } : nil
            let usb = (try? String(contentsOfFile: "/proc/self/mountinfo", encoding: .utf8)).flatMap { info in
                runningFromUSB(mountInfo: info) { name in
                    let link = "/sys/class/block/\(name)"
                    guard FileManager.default.fileExists(atPath: link) else { return nil }
                    return URL(fileURLWithPath: link).resolvingSymlinksInPath().path
                }
            }
            return HostFacts(osName: HostInfo.operatingSystemName(), hostname: host?.isEmpty == false ? host : nil,
                             hardware: HostInfo.hardwareModel(), architecture: architecture, runningFromUSB: usb)
        }
    }

    public let requestDirectory: URL
    public let statusDirectory: URL
    private let product: String
    private let version: String
    private let build: String
    private let facts: HostFacts
    private let timing: Timing
    private let now: @Sendable () -> Date
    private let fallback: UnavailableSystemControl
    private let log = Log(category: "system")

    public init(requestDirectory: URL, statusDirectory: URL, product: String, version: String, build: String,
                facts: HostFacts = .current(), timing: Timing = Timing(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.requestDirectory = requestDirectory
        self.statusDirectory = statusDirectory
        self.product = product
        self.version = version
        self.build = build
        self.facts = facts
        self.timing = timing
        self.now = now
        fallback = UnavailableSystemControl(product: product, version: version, build: build)
    }

    /// The system is there when both folders exist (the image creates them at every boot).
    public var isAvailable: Bool { Self.isDirectory(requestDirectory) && Self.isDirectory(statusDirectory) }

    // MARK: Status

    public func info() async -> SystemInfo {
        guard isAvailable else { return await fallback.info() }
        let system: SystemFile? = read(.system)
        return SystemInfo(product: product, version: system?.version.flatMap { $0.isEmpty ? nil : $0 } ?? version, build: build, mode: "installed",
                          osName: facts.osName, hostname: facts.hostname, hardware: facts.hardware, architecture: facts.architecture,
                          canUpdate: true, canReboot: true, canInstall: true, update: currentUpdate(), canManage: true, runningFromUSB: facts.runningFromUSB,
                          sshEnabled: system?.sshEnabled, automaticUpdates: system?.autoUpdate, install: installProgress())
    }

    private struct SystemFile: Decodable {
        var version: String?
        var sshEnabled: Bool?
        var autoUpdate: Bool?
        var updatedAt: String?
    }

    private struct JobFile: Decodable {
        var state: String?
        var message: String?
        var updatedAt: String?
        var date: Date? { Self.parse(updatedAt) }

        static func parse(_ text: String?) -> Date? {
            guard let text else { return nil }
            return try? Date(text, strategy: .iso8601)
        }
    }

    private struct UpdateFile: Decodable {
        var state: String?
        var message: String?
        var updatedAt: String?
        var current: String?
        var latest: String?
        var updateAvailable: Bool?
        var notes: String?
        var checkedAt: String?
        var rebootRequired: Bool?
    }

    /// `update.json` as the web interface's `UpdateStatus`, with the running `update-apply` job taken into account (the file may
    /// not yet say "downloading" in the moment between the request and the helper's first line).
    private func currentUpdate() -> UpdateStatus? {
        let file: UpdateFile? = read(.update)
        let apply: JobFile? = read(.job(.updateApply))
        let applyRunning = apply.map { ["queued", "running"].contains($0.state ?? "") } ?? false
        guard let file else {
            return applyRunning ? UpdateStatus(state: "downloading", current: version, message: apply?.message) : nil
        }
        var state: String
        switch file.state ?? "" {
        case "checking": state = "checking"
        case "available", "current": state = "idle"
        case "downloading", "installing": state = "downloading"
        case "installed": state = "ready"
        case "failed": state = "error"
        default: state = "idle"
        }
        // The job started after the file was last written: it is running even though the file still says "current".
        if applyRunning, state == "idle" || state == "error" || state == "checking",
           let started = apply?.date, (JobFile.parse(file.updatedAt) ?? .distantPast) <= started {
            state = "downloading"
        }
        let available = file.updateAvailable ?? (file.state == "available")
        let message = (state == "downloading" && applyRunning && file.state != "downloading" && file.state != "installing") ? apply?.message : file.message
        return UpdateStatus(state: state, available: available, current: file.current ?? version, latest: file.latest, notes: file.notes,
                            checked: JobFile.parse(file.checkedAt) ?? JobFile.parse(file.updatedAt), message: message.map(Self.sentence),
                            rebootRequired: file.rebootRequired ?? (file.state == "installed"))
    }

    private struct InstallFile: Decodable {
        var state: String?
        var step: String?
        var device: String?
        var message: String?
        var updatedAt: String?
    }

    private func installProgress() -> InstallProgress? {
        guard let file: InstallFile = read(.installToDisk), let state = file.state else { return nil }
        return InstallProgress(state: state, step: file.step, device: file.device, message: file.message.map(Self.sentence),
                               updatedAt: JobFile.parse(file.updatedAt))
    }

    // MARK: Updates

    public func checkForUpdate() async throws -> UpdateStatus {
        try requireAvailable("Updates are handled by the Camera Bridge OS image. This copy runs as a plain program.")
        if currentUpdate()?.state == "downloading" { throw SystemError("An update is being installed right now.") }
        let since = floorToSecond(now())
        try submit(.updateCheck, Empty())
        try await awaitPickup(.updateCheck)
        // Done when update.json reached an end state after the request (its sentence is the useful one on a failure), or the request's
        // own status says so.
        var answered = false
        for _ in 0...pollCount(timing.updateCheck) {
            if let file: UpdateFile = read(.update), let at = JobFile.parse(file.updatedAt), at >= since,
               ["available", "current", "failed"].contains(file.state ?? "") {
                if file.state == "failed" { throw SystemError(Self.sentence(file.message ?? "The check for updates failed.")) }
                answered = true; break
            }
            if let job: JobFile = read(.job(.updateCheck)), let at = job.date, at >= since {
                if job.state == "failed" { throw SystemError(Self.sentence(job.message ?? "The check for updates failed.")) }
                if job.state == "ok" { answered = true; break }
            }
            try await Task.sleep(for: timing.pollInterval)
            if Task.isCancelled { throw CancellationError() }
        }
        guard answered, let update = currentUpdate(), update.state != "checking" else {
            throw SystemError("Checking for updates took too long. Try again in a few minutes.")
        }
        return update
    }

    public func applyUpdate() async throws -> UpdateStatus {
        try requireAvailable("Updates are handled by the Camera Bridge OS image. This copy runs as a plain program.")
        if currentUpdate()?.state == "downloading" { throw SystemError("An update is already being installed.") }
        struct Body: Encodable { var reboot = false }   // the person restarts when ready
        try submit(.updateApply, Body())
        try await awaitPickup(.updateApply)
        let before = currentUpdate()
        return UpdateStatus(state: "downloading", available: before?.available ?? true, current: before?.current ?? version, latest: before?.latest,
                            notes: before?.notes, checked: before?.checked, message: "Downloading and installing the update.", rebootRequired: false)
    }

    public func setAutomaticUpdates(_ enabled: Bool) async throws {
        try requireAvailable("Updates are handled by the Camera Bridge OS image. This copy runs as a plain program.")
        struct Body: Encodable { var enabled: Bool }
        try await runShortJob(.autoUpdate, Body(enabled: enabled), failure: "The system couldn’t change automatic updates.")
    }

    // MARK: Power

    public func reboot() async throws {
        try requireAvailable("This copy runs as a plain program, so there is no system to restart.")
        try submit(.reboot, Empty())
        try await awaitPickup(.reboot)
    }

    public func powerOff() async throws {
        try requireAvailable("This copy runs as a plain program, so there is no system to switch off.")
        try submit(.poweroff, Empty())
        try await awaitPickup(.poweroff)
    }

    public func factoryReset() async throws {
        try requireAvailable("This copy runs as a plain program, so there is nothing to reset.")
        struct Body: Encodable { var confirm = "RESET" }
        try submit(.factoryReset, Body())
        try await awaitPickup(.factoryReset)
    }

    // MARK: SSH

    public func setSSH(enabled: Bool, authorizedKeys: [String]) async throws {
        try requireAvailable("SSH is managed by the Camera Bridge OS image.")
        if enabled {
            // Checked here as well as by the web layer: only plain public keys ever reach a request.
            let keys = try SSHKeys.parse(authorizedKeys.joined(separator: "\n"))
            struct Body: Encodable { var authorizedKeys: String }
            try await runShortJob(.sshEnable, Body(authorizedKeys: keys.joined(separator: "\n") + "\n"), failure: "The system couldn’t switch SSH on.")
        } else {
            try await runShortJob(.sshDisable, Empty(), failure: "The system couldn’t switch SSH off.")
        }
    }

    // MARK: Installing to a disk

    /// What `cb-install-to-disk --list --json` prints.
    private struct Candidates: Decodable {
        var disks: [Disk]

        struct Disk: Decodable {
            var name: String
            var model: String?
            var transport: String?
            var removable: Bool?
            var sizeBytes: Int64?
            var partitions: [Partition]?
            var eligible: Bool?
            var problems: [String]?
            var phrase: String?
            var isRecordingDrive: Bool?
            var inUse: Bool?
        }

        struct Partition: Decodable {
            var fstype: String?
            var label: String?
        }
    }

    /// Kernel names of whole disks the installer accepts (`DEVICE_RE` in cb-install-to-disk).
    static func isDiskName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard (3...16).contains(bytes.count) else { return false }
        func digits(_ slice: ArraySlice<UInt8>) -> Bool { !slice.isEmpty && slice.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }
        func letters(_ slice: ArraySlice<UInt8>) -> Bool { !slice.isEmpty && slice.allSatisfy { $0 >= 0x61 && $0 <= 0x7A } }
        for prefix in ["sd", "vd"] where name.hasPrefix(prefix) { return letters(bytes[2...]) }
        if name.hasPrefix("mmcblk") { return digits(bytes[6...]) }
        if name.hasPrefix("nvme") {
            let rest = bytes[4...]
            guard let n = rest.firstIndex(of: UInt8(ascii: "n")) else { return false }
            return digits(rest[rest.startIndex..<n]) && digits(rest[(n + 1)...])
        }
        return false
    }

    public func installTargets() async throws -> [InstallTarget] {
        try requireAvailable("Installing to a disk is only possible on Camera Bridge OS.")
        let since = floorToSecond(now())
        try submit(.installList, Empty())
        try await awaitPickup(.installList)
        // The list has no timestamp inside; the file is new when it was written after the request.
        for _ in 0...pollCount(timing.shortJob) {
            if let modified = modificationDate(.installCandidates), modified >= since, let list: Candidates = read(.installCandidates) {
                return list.disks.compactMap(Self.target)
            }
            if let job: JobFile = read(.job(.installList)), job.state == "failed", let at = job.date, at >= since {
                throw SystemError(Self.sentence(job.message ?? "The system couldn’t look at its disks."))
            }
            try await Task.sleep(for: timing.pollInterval)
            if Task.isCancelled { throw CancellationError() }
        }
        throw SystemError("The system took too long to look at its disks.")
    }

    private static func target(_ disk: Candidates.Disk) -> InstallTarget? {
        guard isDiskName(disk.name) else { return nil }
        var notes: [String] = []
        if let transport = disk.transport, !transport.isEmpty { notes.append(transport.uppercased()) }
        if disk.removable == true { notes.append("removable") }
        let contents = (disk.partitions ?? []).compactMap { partition -> String? in
            let parts = [partition.fstype, partition.label].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        if !contents.isEmpty { notes.append("holds " + contents.prefix(4).joined(separator: ", ")) }
        let problems = (disk.problems ?? []).map(sentence)
        let eligible = (disk.eligible ?? false) && problems.isEmpty
        if !eligible, let first = problems.first { notes.append("can’t be used: " + first) }
        let model = disk.model.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }
        return InstallTarget(id: disk.name, name: disk.name, model: model, sizeBytes: disk.sizeBytes ?? 0, note: notes.isEmpty ? nil : notes.joined(separator: " · "),
                             eligible: eligible, problems: problems, phrase: "ERASE ALL DATA ON \(disk.name)",
                             isRecordingDrive: disk.isRecordingDrive, inUse: disk.inUse)
    }

    public func install(targetID: String, phrase: String, copyData: Bool) async throws {
        try requireAvailable("Installing to a disk is only possible on Camera Bridge OS.")
        guard Self.isDiskName(targetID) else { throw SystemError("That isn’t a disk the system knows.") }
        let expected = "ERASE ALL DATA ON \(targetID)"
        guard phrase == expected else { throw SystemError("The sentence doesn’t match. Type it exactly: \(expected)") }
        // The system's own list, fresh: the disk must be on it and usable. (The installer checks everything again before it writes.)
        guard let disk = try await installTargets().first(where: { $0.id == targetID }) else { throw SystemError("That isn’t a disk the system knows.") }
        guard disk.eligible else { throw SystemError("That disk can’t be used: \(disk.problems.first ?? "the system refuses it").") }
        struct Body: Encodable {
            var device: String
            var phrase: String
            var copyData: Bool
            var poweroff: Bool
            var dryRun: Bool
        }
        try submit(.installToDisk, Body(device: "/dev/\(targetID)", phrase: expected, copyData: copyData, poweroff: true, dryRun: false))
        try await awaitPickup(.installToDisk)
    }

    // MARK: Recording drives

    /// What `cb-recording-drive --apply` and the drive jobs write to `status/recording-drive.json`.
    private struct DriveFile: Decodable {
        var state: String?
        var message: String?
    }

    public func recordingDrives() async throws -> RecordingDriveReport {
        try requireAvailable("Choosing a recording drive is only possible on Camera Bridge OS.")
        let since = floorToSecond(now())
        try submit(.driveList, Empty())
        try await awaitPickup(.driveList)
        for _ in 0...pollCount(timing.shortJob) {
            if let modified = modificationDate(.recordingDriveCandidates), modified >= since, let list: Candidates = read(.recordingDriveCandidates) {
                let current: DriveFile? = read(.recordingDrive)
                return RecordingDriveReport(state: current?.state ?? "internal", message: current?.message ?? "Recording to this box's own disk.",
                                            drives: list.disks.compactMap(Self.target))
            }
            if let job: JobFile = read(.job(.driveList)), job.state == "failed", let at = job.date, at >= since {
                throw SystemError(Self.sentence(job.message ?? "The system couldn’t look at its disks."))
            }
            try await Task.sleep(for: timing.pollInterval)
            if Task.isCancelled { throw CancellationError() }
        }
        throw SystemError("The system took too long to look at its disks.")
    }

    public func useRecordingDrive(targetID: String, phrase: String, keepData: Bool) async throws {
        try requireAvailable("Choosing a recording drive is only possible on Camera Bridge OS.")
        guard Self.isDiskName(targetID) else { throw SystemError("That isn’t a disk the system knows.") }
        let expected = "ERASE ALL DATA ON \(targetID)"
        if !keepData, phrase != expected { throw SystemError("The sentence doesn’t match. Type it exactly: \(expected)") }
        // The system's own list, fresh: the disk must be on it and usable. (The helper checks everything again before it writes.)
        guard let disk = try await recordingDrives().drives.first(where: { $0.id == targetID }) else { throw SystemError("That isn’t a disk the system knows.") }
        guard disk.eligible else { throw SystemError("That disk can’t be used: \(disk.problems.first ?? "the system refuses it").") }
        if keepData, disk.isRecordingDrive != true { throw SystemError("That disk isn’t a Camera Bridge recording drive, so it has to be erased first.") }
        struct Body: Encodable {
            var device: String
            var phrase: String
            var keepData: Bool
        }
        try submit(.driveUse, Body(device: "/dev/\(targetID)", phrase: keepData ? "" : expected, keepData: keepData))
        try await awaitPickup(.driveUse)
    }

    public func forgetRecordingDrive() async throws {
        try requireAvailable("Choosing a recording drive is only possible on Camera Bridge OS.")
        try submit(.driveForget, Empty())
        try await awaitPickup(.driveForget)
    }

    // MARK: Wi-Fi

    /// What `cb-wifi` writes to `status/wifi.json`.
    private struct WifiFile: Decodable {
        var state: String?
        var message: String?
        var ssid: String?
        var hotspot: SetupHotspot?
        var lastError: String?
        var saved: [String]?
        var hasWifi: Bool?
        var wired: Bool?
    }

    private struct NetworksFile: Decodable {
        var networks: [WifiNetwork]?
    }

    public func wifi() async -> WifiReport {
        guard isAvailable else { return WifiReport(state: "unavailable", message: "Wi-Fi is managed by Camera Bridge OS.") }
        let file: WifiFile? = read(.wifi)
        let networks: NetworksFile? = read(.wifiNetworks)
        return WifiReport(state: file?.state ?? "searching", message: file?.message ?? "Looking for a network.", ssid: file?.ssid.flatMap { $0.isEmpty ? nil : $0 },
                          hotspot: file?.state == "hotspot" ? file?.hotspot : nil, saved: file?.saved ?? [], lastError: file?.lastError.flatMap { $0.isEmpty ? nil : $0 },
                          hasWifi: file?.hasWifi ?? false, wired: file?.wired ?? false, networks: networks?.networks ?? [])
    }

    public func scanWifi() async throws -> [WifiNetwork] {
        try requireAvailable("Wi-Fi is managed by Camera Bridge OS.")
        try await runShortJob(.wifiScan, Empty(), failure: "The system couldn’t look for Wi-Fi networks.")
        let networks: NetworksFile? = read(.wifiNetworks)
        return networks?.networks ?? []
    }

    /// 1 to 32 bytes, no control characters: what a Wi-Fi network name can be.
    static func isNetworkName(_ name: String) -> Bool {
        (1...32).contains(name.utf8.count) && !name.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// Empty (an open network) or 8 to 63 characters without control characters.
    static func isWifiPassword(_ password: String) -> Bool {
        password.isEmpty || ((8...63).contains(password.count) && !password.unicodeScalars.contains { $0.properties.generalCategory == .control })
    }

    public func joinWifi(ssid: String, password: String, restart: Bool) async throws {
        try requireAvailable("Wi-Fi is managed by Camera Bridge OS.")
        guard Self.isNetworkName(ssid) else { throw SystemError("A network name has 1 to 32 characters.") }
        guard Self.isWifiPassword(password) else { throw SystemError("A Wi-Fi password has 8 to 63 characters (or none, for an open network).") }
        struct Body: Encodable {
            var ssid: String
            var password: String
            var reboot: Bool
        }
        try submit(.wifiJoin, Body(ssid: ssid, password: password, reboot: restart))
        try await awaitPickup(.wifiJoin)
    }

    public func forgetWifi(ssid: String) async throws {
        try requireAvailable("Wi-Fi is managed by Camera Bridge OS.")
        guard Self.isNetworkName(ssid) else { throw SystemError("A network name has 1 to 32 characters.") }
        struct Body: Encodable { var ssid: String }
        try await runShortJob(.wifiForget, Body(ssid: ssid), failure: "The system couldn’t forget that network.")
    }

    public func setupHotspot() -> SetupHotspot? {
        guard isAvailable, let file: WifiFile = read(.wifi), file.state == "hotspot" else { return nil }
        return file.hotspot
    }

    // MARK: The internet guard

    /// At most this many cameras are watched (the helper checks it again).
    static let maximumGuardedCameras = 64

    public func setGuardedCameras(_ cameras: [GuardedCamera]) async throws {
        try requireAvailable("The internet guard is part of Camera Bridge OS.")
        struct Entry: Encodable {
            var address: String
            var level: String
        }
        struct Body: Encodable {
            var cameras: [Entry]
            /// The time zone "today" is counted in: the bridge's own (the engine makes it the process's).
            var timeZone: String
        }
        var entries: [Entry] = []
        for camera in cameras {
            let text = camera.address.trimmingCharacters(in: .whitespaces)
            guard let address = Self.guardedAddress(text) else {
                throw SystemError("“\(Self.sentence(String(text.prefix(45))))” isn’t an address on the local network, so the internet guard can’t watch it.")
            }
            if !entries.contains(where: { $0.address == address }) { entries.append(Entry(address: address, level: camera.level.rawValue)) }
        }
        guard entries.count <= Self.maximumGuardedCameras else { throw SystemError("At most \(Self.maximumGuardedCameras) cameras can be watched.") }
        let failure = "The system couldn’t change the internet guard."
        try await runShortJob(.guardSet, Body(cameras: entries, timeZone: TimeZone.current.identifier), failure: failure)
        // The job's end can be an older list's (one that ran while this one was sent): taken only when the box reports these cameras.
        let reported = read(.internetGuard, maximum: Self.maximumGuardReportBytes).map { (report: GuardReport) in Set(report.cameras.map(\.address)) }
        guard reported == Set(entries.map(\.address)) else {
            log.warning("guard-set ended, but the box reports another list of cameras")
            throw SystemError("\(failure) It still watches another list.")
        }
    }

    public func guardReport() async -> GuardReport {
        guard isAvailable, let report: GuardReport = read(.internetGuard, maximum: Self.maximumGuardReportBytes) else { return .unavailable }
        return report
    }

    /// The address in the form the system logs it (IPv6 per RFC 5952, lowercase), when it is a private IPv4 address (10/8, 172.16/12,
    /// 192.168/16, 169.254/16) or a unique-local or link-local IPv6 address (fc00::/7, fe80::/10, no zone); nil otherwise. The same ranges as
    /// the firewall's `lan4`/`lan6` and the helper's check.
    static func guardedAddress(_ text: String) -> String? {
        guard !text.isEmpty, text.utf8.count <= 45 else { return nil }
        // Spelled out here: inet_pton is laxer on some systems (leading zeros, a zone after "%").
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let plainIPv4 = parts.count == 4 && parts.allSatisfy { part in
            (1...3).contains(part.count) && part.allSatisfy { $0.isASCII && $0.isNumber } && (part.count == 1 || part.first != "0")
        }
        let plainIPv6 = text.contains(":") && text.unicodeScalars.allSatisfy { $0 == ":" || ($0.isASCII && $0.properties.isASCIIHexDigit) }
        var v4 = in_addr()
        if plainIPv4, inet_pton(AF_INET, text, &v4) == 1 {
            let bytes = withUnsafeBytes(of: &v4) { Array($0) }
            let isPrivate = bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 169 && bytes[1] == 254)
            return isPrivate ? bytes.map(String.init).joined(separator: ".") : nil
        }
        var v6 = in6_addr()
        guard plainIPv6, inet_pton(AF_INET6, text, &v6) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        guard bytes[0] & 0xFE == 0xFC || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self).lowercased()
    }

    // MARK: Writing requests

    private struct Empty: Encodable {}

    private func requireAvailable(_ refusal: String) throws {
        guard isAvailable else { throw SystemError(refusal) }
    }

    /// Writes `<requests>/<name>.json` atomically. The name is a `Request`; the body is built by the caller from validated values.
    private func submit<Body: Encodable>(_ request: Request, _ body: Body) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(body)
        guard data.count <= 60_000 else { throw SystemError("That request is too large.") }
        let target = requestDirectory.appending(path: "\(request.rawValue).json", directoryHint: .notDirectory)
        var lastError: Int32 = 0
        // The helper removes files it does not know, which could include the temporary file when it happens to run at that moment.
        for _ in 0..<3 {
            let temporary = requestDirectory.appending(path: ".\(request.rawValue).\(UUID().uuidString).tmp", directoryHint: .notDirectory)
            // POSIX calls, not `FileManager.createFile`: on Linux that writes through a hidden temporary of its own (`.dat.nosync…`) in the
            // same folder, which the helper would remove as an unknown file.
            if let failure = Self.writeNewFile(temporary.path(percentEncoded: false), data) {
                lastError = failure
                continue
            }
            if rename(temporary.path(percentEncoded: false), target.path(percentEncoded: false)) == 0 { return }
            lastError = errno
            unlink(temporary.path(percentEncoded: false))
        }
        log.warning("could not write the \(request.rawValue) request (error \(lastError))")
        throw SystemError("The system couldn’t take the request just now. Try again.")
    }

    /// Creates `path` exclusively with mode 0600 and writes `data` completely; the errno on failure (the file is removed), else nil.
    private static func writeNewFile(_ path: String, _ data: Data) -> Int32? {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return errno }
        var failure: Int32?
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += written
            }
        }
        if failure == nil, fsync(descriptor) != 0 { failure = errno }
        if close(descriptor) != 0, failure == nil { failure = errno }
        if let failure {
            unlink(path)
            return failure
        }
        return nil
    }

    /// Waits until the helper has taken the request (its file is gone). A request nobody takes is withdrawn.
    private func awaitPickup(_ request: Request) async throws {
        let path = requestDirectory.appending(path: "\(request.rawValue).json", directoryHint: .notDirectory).path(percentEncoded: false)
        for _ in 0...pollCount(timing.pickup) {
            var info = stat()
            if lstat(path, &info) != 0 { return }
            try await Task.sleep(for: timing.pollInterval)
            if Task.isCancelled { throw CancellationError() }
        }
        unlink(path)
        log.warning("the system did not pick up the \(request.rawValue) request")
        throw SystemError("The system isn’t answering. Try again in a minute.")
    }

    /// Writes a request and waits (bounded) for the helper to finish it; a failure carries the helper's sentence.
    private func runShortJob<Body: Encodable>(_ request: Request, _ body: Body, failure: String) async throws {
        let since = floorToSecond(now())
        try submit(request, body)
        try await awaitPickup(request)
        for _ in 0...pollCount(timing.shortJob) {
            if let job: JobFile = read(.job(request)), let at = job.date, at >= since {
                if job.state == "ok" {
                    await settle(since)
                    return
                }
                if job.state == "failed" {
                    log.warning("\(request.rawValue) failed: \(Redact.string(job.message ?? ""))")
                    throw SystemError("\(failure) \(Self.sentence(job.message ?? ""))".trimmingCharacters(in: .whitespaces))
                }
            }
            try await Task.sleep(for: timing.pollInterval)
            if Task.isCancelled { throw CancellationError() }
        }
        throw SystemError("\(failure) It took too long.")
    }

    /// The helper refreshes `system.json` right after a job; give it a moment so the next `info()` shows the new state.
    private func settle(_ since: Date) async {
        for _ in 0..<min(pollCount(.seconds(3)), 20) {
            if let system: SystemFile = read(.system), let at = JobFile.parse(system.updatedAt), at >= since { return }
            try? await Task.sleep(for: timing.pollInterval)
        }
    }

    // MARK: Reading status files

    private static let maximumStatusBytes = 256 * 1024
    /// `guard.json` lists up to 64 cameras with 50 names each; the helper keeps it below this.
    static let maximumGuardReportBytes = 1024 * 1024

    private func read<T: Decodable>(_ file: StatusFile, maximum: Int = Self.maximumStatusBytes) -> T? {
        let url = statusDirectory.appending(path: file.name, directoryHint: .notDirectory)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximum + 1), !data.isEmpty, data.count <= maximum else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func modificationDate(_ file: StatusFile) -> Date? {
        let path = statusDirectory.appending(path: file.name, directoryHint: .notDirectory).path(percentEncoded: false)
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // MARK: Helpers

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Status files have whole-second timestamps.
    private func floorToSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    /// How many polls fit in `duration` (the loops are bounded by this, not by the clock).
    private func pollCount(_ duration: Duration) -> Int {
        let step = max(timing.pollInterval.timeInterval, 0.001)
        return Int(min(max(duration.timeInterval / step, 1), 100_000))
    }

    /// A message from the system, for the page: one line, no control characters, bounded.
    static func sentence(_ text: String) -> String {
        let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : $0 }))
        return String(cleaned.trimmingCharacters(in: .whitespaces).prefix(240))
    }
}
