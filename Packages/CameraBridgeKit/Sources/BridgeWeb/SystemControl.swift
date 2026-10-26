import BridgeEngine
import Foundation

/// The operating system under the bridge: what version runs, whether an update waits, restarting, SSH, and installing to the
/// machine's own disk. Camera Bridge OS supplies the real one (the daemon asks the image's root helper through request files, see
/// `RequestFileSystemControl` in BridgeDaemon); on a Mac the web interface is a development aid and `UnavailableSystemControl`
/// answers.
///
/// Most actions are asynchronous on the system's side: the call returns once the system has taken the request (or, for short
/// ones, finished it), and `info()` tells how a long one (an update, an installation) goes.
public protocol SystemControlling: Sendable {
    func info() async -> SystemInfo
    /// Asks the update source whether a newer system exists (nothing is downloaded). Returns when the answer is in.
    func checkForUpdate() async throws -> UpdateStatus
    /// Starts downloading and installing the newer system into the idle slot and returns at once with the running state; it runs
    /// after the next restart. `info().update` follows the progress.
    func applyUpdate() async throws -> UpdateStatus
    func reboot() async throws
    /// The disks the system could be installed to, with the reasons for the ones it cannot (the disk it runs from, mounted
    /// disks, …).
    func installTargets() async throws -> [InstallTarget]
    /// Copies this system to the disk `targetID` names; every file on that disk is erased. `phrase` is the sentence the person
    /// typed ("ERASE ALL DATA ON <disk name>"); the system refuses anything else. Returns once the installation has started;
    /// `info().install` follows it.
    func install(targetID: String, phrase: String, copyData: Bool) async throws
    func powerOff() async throws
    /// Turns SSH on (key login only, with these public keys) or off.
    func setSSH(enabled: Bool, authorizedKeys: [String]) async throws
    func setAutomaticUpdates(_ enabled: Bool) async throws
    /// Erases the bridge's settings and HomeKit pairings, then restarts.
    func factoryReset() async throws
    /// Where recordings go now (the box's own disk or an attached drive) and the disks that could take them.
    func recordingDrives() async throws -> RecordingDriveReport
    /// Records to the disk `targetID` names from now on. Without `keepData` every file on it is erased and a new file system made (`phrase` is the
    /// sentence the person typed, "ERASE ALL DATA ON <disk name>"); with it a disk that already is a Camera Bridge recording drive is used as it is.
    func useRecordingDrive(targetID: String, phrase: String, keepData: Bool) async throws
    /// Goes back to recording on the box's own disk. The drive and what is on it are left alone.
    func forgetRecordingDrive() async throws
    /// The archive drive (where older recordings move when the recordings drive fills, instead of being deleted) and the disks that could be it: the
    /// recording drive's list, in the archive's view.
    func archiveDrives() async throws -> ArchiveDriveReport
    /// Makes the disk `targetID` names the archive drive. Without `keepData` every file on it is erased and a new file system made (`phrase` is the
    /// sentence the person typed, "ERASE ALL DATA ON <disk name>"); with it a disk that already is a Camera Bridge archive drive is used as it is.
    func useArchiveDrive(targetID: String, phrase: String, keepData: Bool) async throws
    /// Stops using the archive drive. The drive and what is on it are left alone.
    func forgetArchiveDrive() async throws
    /// How the box is on the network (wired, a Wi-Fi network, the setup hotspot), the networks it knows and the last ones it saw.
    func wifi() async -> WifiReport
    /// Looks for Wi-Fi networks in range (the radio is busy for a few seconds). Strongest first.
    func scanWifi() async throws -> [WifiNetwork]
    /// Saves the network `ssid` (with `password`, empty for an open network) and, with `restart`, restarts the box to join it.
    func joinWifi(ssid: String, password: String, restart: Bool) async throws
    func forgetWifi(ssid: String) async throws
    /// The setup hotspot while it is open (the box has no other network), nil otherwise. Cheap: it is asked for requests to unknown host names.
    func setupHotspot() -> SetupHotspot?
    /// Replaces the list of cameras the internet guard watches (an empty list turns it off). Only cameras on the local network.
    func setGuardedCameras(_ cameras: [GuardedCamera]) async throws
    /// What the internet guard saw; `GuardReport.unavailable` where there is none (or it has not reported yet).
    func guardReport() async -> GuardReport
    /// The certificate of the secure address (`status/tls.json`); nil where this system has no TLS front (a plain program, an older image).
    func certificateStatus() async -> CertificateStatus?
    /// Asks the system to get (or renew) the certificate for `host` with the box key `privateKeyPEM`; returns once the system took the request.
    /// `certificateStatus()` follows it.
    func obtainCertificate(name: String, host: String, privateKeyPEM: String) async throws
}

extension SystemControlling {
    public func powerOff() async throws {
        throw SystemError("This copy runs as a plain program, so there is no system to switch off.")
    }

    public func setSSH(enabled: Bool, authorizedKeys: [String]) async throws {
        throw SystemError("SSH is managed by the Camera Bridge OS image.")
    }

    public func setAutomaticUpdates(_ enabled: Bool) async throws {
        throw SystemError("Updates are handled by the Camera Bridge OS image. This copy runs as a plain program.")
    }

    public func factoryReset() async throws {
        throw SystemError("This copy runs as a plain program, so there is nothing to reset.")
    }

    public func recordingDrives() async throws -> RecordingDriveReport {
        throw SystemError("Choosing a recording drive is only possible on Camera Bridge OS.")
    }

    public func useRecordingDrive(targetID: String, phrase: String, keepData: Bool) async throws {
        throw SystemError("Choosing a recording drive is only possible on Camera Bridge OS.")
    }

    public func forgetRecordingDrive() async throws {
        throw SystemError("Choosing a recording drive is only possible on Camera Bridge OS.")
    }

    public func archiveDrives() async throws -> ArchiveDriveReport {
        throw SystemError("An archive drive is only possible on Camera Bridge OS.")
    }

    public func useArchiveDrive(targetID: String, phrase: String, keepData: Bool) async throws {
        throw SystemError("An archive drive is only possible on Camera Bridge OS.")
    }

    public func forgetArchiveDrive() async throws {
        throw SystemError("An archive drive is only possible on Camera Bridge OS.")
    }

    public func wifi() async -> WifiReport { WifiReport(state: "unavailable", message: "Wi-Fi is managed by Camera Bridge OS.") }

    public func scanWifi() async throws -> [WifiNetwork] { throw SystemError("Wi-Fi is managed by Camera Bridge OS.") }

    public func joinWifi(ssid: String, password: String, restart: Bool) async throws { throw SystemError("Wi-Fi is managed by Camera Bridge OS.") }

    public func forgetWifi(ssid: String) async throws { throw SystemError("Wi-Fi is managed by Camera Bridge OS.") }

    public func setupHotspot() -> SetupHotspot? { nil }

    public func setGuardedCameras(_ cameras: [GuardedCamera]) async throws { throw SystemError("The internet guard is part of Camera Bridge OS.") }

    public func guardReport() async -> GuardReport { .unavailable }

    public func certificateStatus() async -> CertificateStatus? { nil }

    public func obtainCertificate(name: String, host: String, privateKeyPEM: String) async throws {
        throw SystemError("The secure address is part of Camera Bridge OS.")
    }
}

/// The certificate the TLS front serves, as the system reports it.
public struct CertificateStatus: Codable, Sendable, Equatable {
    /// `none` (no certificate yet), `working` (being obtained), `ready`, `failed` (the last try failed; an earlier certificate may remain).
    public var state: String
    public var message: String?
    /// The host name the certificate is for, and when it expires; nil without a certificate.
    public var host: String?
    public var notAfter: Date?

    public init(state: String, message: String? = nil, host: String? = nil, notAfter: Date? = nil) {
        self.state = state
        self.message = message
        self.host = host
        self.notAfter = notAfter
    }
}

/// A Wi-Fi network in range.
public struct WifiNetwork: Codable, Sendable, Equatable {
    public var ssid: String
    /// 0 to 100.
    public var signal: Int
    /// "" for an open network, else what the system says ("WPA2", "WPA1 WPA2", "WPA3", …).
    public var security: String

    public init(ssid: String, signal: Int, security: String) {
        self.ssid = ssid
        self.signal = signal
        self.security = security
    }
}

/// The setup hotspot the box opens when it has no network.
public struct SetupHotspot: Codable, Sendable, Equatable {
    public var ssid: String
    /// The box's address on it (the setup page is there).
    public var address: String

    public init(ssid: String, address: String) {
        self.ssid = ssid
        self.address = address
    }
}

/// How the box is on the network.
public struct WifiReport: Codable, Sendable, Equatable {
    /// "online", "hotspot", "searching", "no-wifi", "no-hotspot" or "unavailable" (no Camera Bridge OS underneath).
    public var state: String
    public var message: String
    /// The Wi-Fi network the box is on, if any.
    public var ssid: String?
    public var hotspot: SetupHotspot?
    /// The networks the box knows (it joins them by itself).
    public var saved: [String]
    /// Why the last network could not be joined, in a sentence.
    public var lastError: String?
    public var hasWifi: Bool
    public var wired: Bool
    /// The networks seen at the last look, strongest first.
    public var networks: [WifiNetwork]
    /// The radio the box is joined on: "2.4 GHz", "5 GHz" or "6 GHz"; nil when it is not joined or the system does not say.
    public var band: String?

    public init(state: String, message: String, ssid: String? = nil, hotspot: SetupHotspot? = nil, saved: [String] = [], lastError: String? = nil,
                hasWifi: Bool = false, wired: Bool = false, networks: [WifiNetwork] = [], band: String? = nil) {
        self.state = state
        self.message = message
        self.ssid = ssid
        self.hotspot = hotspot
        self.saved = saved
        self.lastError = lastError
        self.hasWifi = hasWifi
        self.wired = wired
        self.networks = networks
        self.band = band
    }
}

/// Where recordings go, as the system reports it.
public struct RecordingDriveReport: Codable, Sendable, Equatable {
    /// "internal" (the box's own disk), "mounted" (the chosen drive is in place), "missing" (chosen, not attached), "working" (being set up) or
    /// "failed" (the last attempt did not work; `message` says why).
    public var state: String
    public var message: String
    /// The disks that could take recordings (the system's own list, with the reasons for the ones that cannot).
    public var drives: [InstallTarget]

    public init(state: String, message: String, drives: [InstallTarget]) {
        self.state = state
        self.message = message
        self.drives = drives
    }
}

/// The archive drive, as the system reports it.
public struct ArchiveDriveReport: Codable, Sendable, Equatable {
    /// "none" (no archive drive is chosen), "mounted" (the chosen drive is in place), "missing" (chosen, not attached), "working" (being set up) or
    /// "failed" (the last attempt did not work; `message` says why).
    public var state: String
    public var message: String
    /// The disks that could be the archive drive (the system's list, with the reasons for the ones that cannot: the recording drive is one).
    public var drives: [InstallTarget]

    public init(state: String, message: String, drives: [InstallTarget]) {
        self.state = state
        self.message = message
        self.drives = drives
    }
}

/// A refusal or failure with a sentence the person can read.
public struct SystemError: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

public struct SystemInfo: Codable, Sendable, Equatable {
    public var product: String
    public var version: String
    public var build: String
    /// "installed" (running on Camera Bridge OS) or "development" (no system underneath: the daemon runs as a program).
    public var mode: String
    public var osName: String?
    public var hostname: String?
    public var hardware: String?
    public var architecture: String?
    public var canUpdate: Bool
    public var canReboot: Bool
    public var canInstall: Bool
    public var update: UpdateStatus?
    /// SSH, automatic updates, switching off and the factory reset are available.
    public var canManage: Bool
    /// nil when the system does not say.
    public var sshEnabled: Bool?
    public var automaticUpdates: Bool?
    /// How the installation to a disk is going (nil: none was started since the system started).
    public var install: InstallProgress?
    /// The system runs from a USB drive (the installer stick); nil when it can't be told. The page offers installing to a disk then.
    public var runningFromUSB: Bool?

    public init(product: String, version: String, build: String, mode: String, osName: String? = nil, hostname: String? = nil,
                hardware: String? = nil, architecture: String? = nil, canUpdate: Bool = false, canReboot: Bool = false,
                canInstall: Bool = false, update: UpdateStatus? = nil, canManage: Bool = false, runningFromUSB: Bool? = nil, sshEnabled: Bool? = nil,
                automaticUpdates: Bool? = nil, install: InstallProgress? = nil) {
        self.product = product
        self.version = version
        self.build = build
        self.mode = mode
        self.osName = osName
        self.hostname = hostname
        self.hardware = hardware
        self.architecture = architecture
        self.canUpdate = canUpdate
        self.canReboot = canReboot
        self.canInstall = canInstall
        self.update = update
        self.canManage = canManage
        self.sshEnabled = sshEnabled
        self.automaticUpdates = automaticUpdates
        self.install = install
        self.runningFromUSB = runningFromUSB
    }
}

/// The installation to a disk, as the system reports it.
public struct InstallProgress: Codable, Sendable, Equatable {
    /// "queued", "running", "ok" or "failed".
    public var state: String
    /// "checking", "stopping", "partitioning", "copying", "boot-entry", "done", "refused" or "failed".
    public var step: String?
    public var device: String?
    public var message: String?
    public var updatedAt: Date?

    public init(state: String, step: String? = nil, device: String? = nil, message: String? = nil, updatedAt: Date? = nil) {
        self.state = state
        self.step = step
        self.device = device
        self.message = message
        self.updatedAt = updatedAt
    }
}

public struct UpdateStatus: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey { case state, available, current, latest, notes, checked, message, rebootRequired }

    /// The system's helper may leave out what it does not know: every field has a default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? "idle"
        available = try container.decodeIfPresent(Bool.self, forKey: .available) ?? false
        current = try container.decodeIfPresent(String.self, forKey: .current) ?? ""
        latest = try container.decodeIfPresent(String.self, forKey: .latest)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        checked = try container.decodeIfPresent(Date.self, forKey: .checked)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        rebootRequired = try container.decodeIfPresent(Bool.self, forKey: .rebootRequired) ?? false
    }

    /// "idle", "checking", "downloading" (downloading, verifying or installing), "ready" (installed, waiting for a restart) or
    /// "error".
    public var state: String
    public var available: Bool
    public var current: String
    public var latest: String?
    public var notes: String?
    public var checked: Date?
    public var message: String?
    public var rebootRequired: Bool

    public init(state: String = "idle", available: Bool = false, current: String, latest: String? = nil, notes: String? = nil,
                checked: Date? = nil, message: String? = nil, rebootRequired: Bool = false) {
        self.state = state
        self.available = available
        self.current = current
        self.latest = latest
        self.notes = notes
        self.checked = checked
        self.message = message
        self.rebootRequired = rebootRequired
    }
}

public struct InstallTarget: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var model: String?
    public var sizeBytes: Int64
    public var note: String?
    /// Whether the system would install to this disk. When not, `problems` says why (in the system's words).
    public var eligible: Bool
    public var problems: [String]
    /// The sentence the person must type to erase this disk ("ERASE ALL DATA ON nvme0n1").
    public var phrase: String?
    /// The disk already is a Camera Bridge recording drive: it can be used without erasing it (recording drives only).
    public var isRecordingDrive: Bool?
    /// The disk is the recording drive in use now (recording drives only); in an archive drive list, the archive drive in use now.
    public var inUse: Bool?
    /// The disk already is a Camera Bridge archive drive: it can be used as one without erasing it (archive drive lists only).
    public var isArchiveDrive: Bool?

    public init(id: String, name: String, model: String? = nil, sizeBytes: Int64, note: String? = nil, eligible: Bool = true,
                problems: [String] = [], phrase: String? = nil, isRecordingDrive: Bool? = nil, inUse: Bool? = nil, isArchiveDrive: Bool? = nil) {
        self.isRecordingDrive = isRecordingDrive
        self.inUse = inUse
        self.isArchiveDrive = isArchiveDrive
        self.id = id
        self.name = name
        self.model = model
        self.sizeBytes = sizeBytes
        self.note = note
        self.eligible = eligible
        self.problems = problems
        self.phrase = phrase
    }
}

/// Public SSH keys for the system's SSH: plain keys only (no options such as `command=`), at most 20. The system checks them again.
public enum SSHKeys {
    public static let maximumKeys = 20
    static let types: Set<String> = ["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
                                     "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com"]

    /// The key lines in `text` (blank lines and `#` comments dropped). Throws a sentence the person can read.
    public static func parse(_ text: String) throws -> [String] {
        guard text.utf8.count <= 32 * 1024 else { throw SystemError("That is too much text for SSH keys.") }
        var keys: [String] = []
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            var line = String(rawLine)
            while line.last == "\r" || line.last == " " || line.last == "\t" { line.removeLast() }
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard isPlainKey(line) else {
                throw SystemError("“\(String(line.prefix(24)))…” isn’t a plain SSH public key. Paste the line from your .pub file.")
            }
            keys.append(line)
        }
        guard !keys.isEmpty else { throw SystemError("Paste at least one SSH public key.") }
        guard keys.count <= maximumKeys else { throw SystemError("At most \(maximumKeys) keys are allowed.") }
        return keys
    }

    /// `<type> <base64>[ <comment>]` with a known type, plain base64 and a short comment without control characters.
    static func isPlainKey(_ line: String) -> Bool {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, types.contains(String(parts[0])) else { return false }
        let blob = parts[1]
        guard !blob.isEmpty, blob.utf8.count <= 8_192 else { return false }
        var padding = 0
        for byte in blob.utf8 {
            switch byte {
            case UInt8(ascii: "="):
                padding += 1
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "+"), UInt8(ascii: "/"):
                if padding > 0 { return false }
            default:
                return false
            }
        }
        guard padding <= 3, blob.first != "=" else { return false }
        if parts.count == 3 {
            let comment = parts[2]
            guard comment.count <= 100, !comment.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return false }
        }
        return true
    }
}

/// No operating system under the daemon (development on a Mac): reports itself and refuses the rest.
public struct UnavailableSystemControl: SystemControlling {
    private let product: String
    private let version: String
    private let build: String

    public init(product: String = "Camera Bridge OS", version: String = "0.1", build: String = "development") {
        self.product = product
        self.version = version
        self.build = build
    }

    public func info() async -> SystemInfo {
        SystemInfo(product: product, version: version, build: build, mode: "development", osName: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    public func checkForUpdate() async throws -> UpdateStatus {
        throw SystemError("Updates are handled by the Camera Bridge OS image. This copy runs as a plain program.")
    }

    public func applyUpdate() async throws -> UpdateStatus {
        throw SystemError("Updates are handled by the Camera Bridge OS image. This copy runs as a plain program.")
    }

    public func reboot() async throws {
        throw SystemError("This copy runs as a plain program, so there is no system to restart.")
    }

    public func installTargets() async throws -> [InstallTarget] {
        throw SystemError("Installing to a disk is only possible on Camera Bridge OS.")
    }

    public func install(targetID: String, phrase: String, copyData: Bool) async throws {
        throw SystemError("Installing to a disk is only possible on Camera Bridge OS.")
    }
}
