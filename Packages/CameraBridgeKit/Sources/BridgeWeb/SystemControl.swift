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

    public init(product: String, version: String, build: String, mode: String, osName: String? = nil, hostname: String? = nil,
                hardware: String? = nil, architecture: String? = nil, canUpdate: Bool = false, canReboot: Bool = false,
                canInstall: Bool = false, update: UpdateStatus? = nil, canManage: Bool = false, sshEnabled: Bool? = nil,
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

    public init(id: String, name: String, model: String? = nil, sizeBytes: Int64, note: String? = nil, eligible: Bool = true,
                problems: [String] = [], phrase: String? = nil) {
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
