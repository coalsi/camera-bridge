import BridgeSupport
import BridgeWeb
import Foundation
import Synchronization
import Testing
import TestSupport
@testable import BridgeDaemon
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The clock of these tests: every reading is two seconds after the one before, so a status file written for one request can
/// never be taken for the answer to the next (status files carry whole-second timestamps).
final class TestClock: Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

    func tick() -> Date { current.withLock { $0 = $0.addingTimeInterval(2); return $0 } }
    func peek() -> Date { current.withLock { $0 } }
}

/// The root side of Camera Bridge OS in miniature: what `camera-bridge-request.path` and `cb-system process-requests` do, with the
/// same file names, the same checks and the same status files (`linux/os/mkosi.extra/usr/sbin/cb-system`, `lib.sh`'s `cb_status`),
/// so the daemon is tested against the real protocol and not against its own idea of it.
final class FakeRootHelper: @unchecked Sendable {
    typealias Behavior = @Sendable (FakeRootHelper, _ name: String, _ body: Data) async -> Void

    static let allowed: Set<String> = ["ssh-enable", "ssh-disable", "auto-update", "update-check", "update-apply", "reboot", "poweroff", "factory-reset",
                                       "install-list", "install-to-disk"]

    let requests: URL
    let status: URL
    let clock: TestClock
    /// Every request taken, in order: its name and its body.
    let taken = Mutex<[(name: String, body: Data)]>([])
    /// The names refused (not allowed, a symlink, not a JSON object, too large).
    let refused = Mutex<[String]>([])
    private let behavior: Behavior
    private var loop: Task<Void, Never>?
    private let jobs = Mutex<[Task<Void, Never>]>([])

    init(requests: URL, status: URL, clock: TestClock, behavior: @escaping Behavior) {
        self.requests = requests
        self.status = status
        self.clock = clock
        self.behavior = behavior
    }

    func start() {
        loop = Task.detached { [self] in
            while !Task.isCancelled {
                processRequests()
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    func stop() {
        loop?.cancel()
        for job in jobs.withLock({ $0 }) { job.cancel() }
    }

    /// The bodies of the requests called `name`, as dictionaries that compare by value.
    func bodies(_ name: String) -> [NSDictionary] {
        taken.withLock { $0.filter { $0.name == name } }.compactMap { (try? JSONSerialization.jsonObject(with: $0.body)) as? NSDictionary }
    }

    func names() -> [String] { taken.withLock { $0.map(\.name) } }

    // cb-system process_requests
    private func processRequests() {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: requests.path(percentEncoded: false)) else { return }
        for entry in entries.sorted() where entry.hasSuffix(".json") && !entry.hasPrefix(".") {
            let name = String(entry.dropLast(".json".count))
            let url = requests.appending(path: entry)
            let path = url.path(percentEncoded: false)
            let attributes = try? manager.attributesOfItem(atPath: path)
            let isRegular = (attributes?[.type] as? FileAttributeType) == .typeRegular
            if !isRegular || !Self.allowed.contains(name) {
                refused.withLock { $0.append(name) }
                try? manager.removeItem(at: url)
                continue
            }
            let size = (attributes?[.size] as? Int) ?? 0
            let data = (try? Data(contentsOf: url)) ?? Data()
            if size > 65_536 || (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] == nil {
                refused.withLock { $0.append(name) }
                try? manager.removeItem(at: url)
                writeStatus(name, "failed", size > 65_536 ? "request too large" : "request is not a JSON object")
                continue
            }
            try? manager.removeItem(at: url)
            taken.withLock { $0.append((name, data)) }
            writeStatus(name, "queued", "waiting to run")
            let job = Task.detached { [self] in
                writeStatus(name, "running", "started")
                await behavior(self, name, data)
            }
            jobs.withLock { $0.append(job) }
        }
    }

    /// `cb_status NAME STATE MESSAGE [EXTRA]`: atomically `{state, message, updatedAt, ...extra}`.
    func writeStatus(_ name: String, _ state: String, _ message: String, extra: [String: Any] = [:]) {
        var object = extra
        object["state"] = state
        object["message"] = message
        object["updatedAt"] = clock.peek().formatted(Date.ISO8601FormatStyle())
        write(name + ".json", object)
    }

    func write(_ file: String, _ object: [String: Any], modified: Date? = nil) {
        writeData(file, (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), modified: modified)
    }

    func writeData(_ file: String, _ data: Data, modified: Date? = nil) {
        let temporary = status.appending(path: ".\(file).new")
        let target = status.appending(path: file)
        try? data.write(to: temporary)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644, .modificationDate: modified ?? clock.peek()], ofItemAtPath: temporary.path(percentEncoded: false))
        _ = rename(temporary.path(percentEncoded: false), target.path(percentEncoded: false))
    }

    /// `refresh_status` after a job: system.json.
    func refreshSystem(version: String = "0.1", ssh: Bool = false, auto: Bool = false) {
        writeStatus("system", "ok", "system state", extra: ["version": version, "sshEnabled": ssh, "autoUpdate": auto, "bootEntry": "cb-os_\(version)+3.efi"])
    }

    static func object(_ data: Data) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }
}

/// How the real image behaves, as far as the daemon can see it.
extension FakeRootHelper {
    /// `latest`: the version the update source offers; `fixedStatus`: whether update-check.json ends at "ok" (the image's
    /// `run_job` leaves it at "running" for update jobs in the first version; the daemon must work either way).
    static func image(latest: String = "0.2", current: String = "0.1", fixedStatus: Bool = true, ssh: Bool = false, auto: Bool = false,
                      disks: [[String: Any]] = []) -> Behavior {
        let candidates = (try? JSONSerialization.data(withJSONObject: ["disks": disks], options: [.sortedKeys])) ?? Data()
        return { helper, name, body in
            let request = FakeRootHelper.object(body)
            switch name {
            case "update-check":
                helper.writeStatus("update", "checking", "looking for updates")
                try? await Task.sleep(for: .milliseconds(30))
                let available = latest != current
                helper.writeStatus("update", available ? "available" : "current", available ? "version \(latest) is available (you have \(current))" : "you are up to date",
                                   extra: ["current": current, "latest": latest, "updateAvailable": available, "notes": "Faster and calmer.", "checkedAt": helper.clock.peek().formatted(Date.ISO8601FormatStyle())])
                if fixedStatus { helper.writeStatus(name, "ok", "done") }
            case "update-apply":
                helper.writeStatus("update", "downloading", "downloading version \(latest)", extra: ["latest": latest])
                try? await Task.sleep(for: .milliseconds(250))
                helper.writeStatus("update", "installing", "verifying and installing version \(latest)", extra: ["latest": latest])
                try? await Task.sleep(for: .milliseconds(250))
                helper.writeStatus("update", "installed", "version \(latest) is installed; restart to use it.", extra: ["current": current, "latest": latest, "installedVersion": latest, "rebootRequired": true])
                if fixedStatus { helper.writeStatus(name, "ok", "done") }
                helper.refreshSystem(version: current, ssh: ssh, auto: auto)
            case "ssh-enable":
                helper.writeStatus(name, "ok", "done")
                helper.refreshSystem(version: current, ssh: true, auto: auto)
            case "ssh-disable":
                helper.writeStatus(name, "ok", "done")
                helper.refreshSystem(version: current, ssh: false, auto: auto)
            case "auto-update":
                helper.writeStatus(name, "ok", "done")
                helper.refreshSystem(version: current, ssh: ssh, auto: request["enabled"] as? Bool ?? false)
            case "install-list":
                helper.writeData("install-candidates.json", candidates)
                if fixedStatus { helper.writeStatus(name, "ok", "done") }
            case "install-to-disk":
                for step in ["checking", "partitioning", "copying", "done"] {
                    helper.writeStatus(name, step == "done" ? "ok" : "running", "step \(step)", extra: ["step": step, "device": request["device"] ?? ""])
                    try? await Task.sleep(for: .milliseconds(30))
                }
            default:
                helper.writeStatus(name, "ok", "done")
            }
        }
    }

    static func disk(_ name: String, model: String = "Acme NVMe", size: Int64 = 256_000_000_000, problems: [String] = []) -> [String: Any] {
        ["name": name, "path": "/dev/\(name)", "model": model, "serial": "X1", "transport": name.hasPrefix("nvme") ? "nvme" : "usb", "removable": !name.hasPrefix("nvme"),
         "sizeBytes": size, "partitions": [["name": name + "p1", "sizeBytes": 1_000_000, "fstype": "ext4", "label": "data", "partlabel": ""]],
         "eligible": problems.isEmpty, "problems": problems, "phrase": "ERASE ALL DATA ON \(name)"]
    }
}

/// A folder with `requests` and `status` and a helper watching them.
struct Rig {
    let directory: TemporaryDirectory
    let requests: URL
    let status: URL
    let clock = TestClock()
    let helper: FakeRootHelper?
    let system: RequestFileSystemControl

    init(helper behavior: FakeRootHelper.Behavior? = FakeRootHelper.image(), timing: RequestFileSystemControl.Timing? = nil) throws {
        directory = try TemporaryDirectory()
        requests = directory.url.appending(path: "requests", directoryHint: .isDirectory)
        status = directory.url.appending(path: "status", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: status, withIntermediateDirectories: true)
        let requests = self.requests, status = self.status, clock = self.clock
        helper = behavior.map { FakeRootHelper(requests: requests, status: status, clock: clock, behavior: $0) }
        var timing = timing ?? RequestFileSystemControl.Timing()
        if timing.pollInterval == RequestFileSystemControl.Timing().pollInterval { timing.pollInterval = .milliseconds(10) }
        system = RequestFileSystemControl(requestDirectory: requests, statusDirectory: status, product: "Camera Bridge OS", version: "0.1", build: "test",
                                          facts: .init(osName: "Debian GNU/Linux 13 (trixie)", hostname: "camera-bridge", hardware: "N100", architecture: "x86_64"),
                                          timing: timing, now: { clock.tick() })
        helper?.start()
    }

    func finish() {
        helper?.stop()
        directory.remove()
    }

    var leftovers: [String] { (try? FileManager.default.contentsOfDirectory(atPath: requests.path(percentEncoded: false))) ?? [] }
}

@Suite(.timeLimit(.minutes(2))) struct RequestFileSystemControlTests {
    private let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLE me@example"

    // MARK: Without a system

    @Test func withoutTheFoldersTheSystemIsADevelopmentOneAndNothingPrivilegedHappens() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let system = RequestFileSystemControl(requestDirectory: directory.file("requests"), statusDirectory: directory.file("status"), product: "Camera Bridge OS",
                                              version: "0.1", build: "test")
        #expect(!system.isAvailable)
        let info = await system.info()
        #expect(info.mode == "development" && !info.canReboot && !info.canInstall && !info.canUpdate && !info.canManage)
        await #expect(throws: SystemError.self) { try await system.checkForUpdate() }
        await #expect(throws: SystemError.self) { try await system.applyUpdate() }
        await #expect(throws: SystemError.self) { try await system.reboot() }
        await #expect(throws: SystemError.self) { try await system.powerOff() }
        await #expect(throws: SystemError.self) { try await system.factoryReset() }
        await #expect(throws: SystemError.self) { try await system.setSSH(enabled: false, authorizedKeys: []) }
        await #expect(throws: SystemError.self) { try await system.setAutomaticUpdates(true) }
        await #expect(throws: SystemError.self) { _ = try await system.installTargets() }
        await #expect(throws: SystemError.self) { try await system.install(targetID: "sda", phrase: "ERASE ALL DATA ON sda", copyData: true) }
        #expect(directory.contents().isEmpty, "not even a folder was created")
    }

    @Test func aFolderThatIsAFileIsNotASystem() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        try Data().write(to: directory.file("requests"))
        try FileManager.default.createDirectory(at: directory.file("status"), withIntermediateDirectories: true)
        #expect(!RequestFileSystemControl(requestDirectory: directory.file("requests"), statusDirectory: directory.file("status"), product: "p", version: "1", build: "b").isAvailable)
    }

    // MARK: Status

    @Test func theStatusFilesBecomeTheSystemPage() async throws {
        let rig = try Rig(helper: nil)
        defer { try? FileManager.default.removeItem(at: rig.directory.url) }
        let empty = await rig.system.info()
        #expect(empty.mode == "installed" && empty.canReboot && empty.canInstall && empty.canUpdate && empty.canManage)
        #expect(empty.version == "0.1" && empty.update == nil && empty.install == nil && empty.sshEnabled == nil)
        #expect(empty.osName == "Debian GNU/Linux 13 (trixie)" && empty.hostname == "camera-bridge" && empty.hardware == "N100" && empty.architecture == "x86_64")

        let writer = FakeRootHelper(requests: rig.requests, status: rig.status, clock: rig.clock) { _, _, _ in }
        writer.write("system.json", ["version": "0.3", "sshEnabled": true, "autoUpdate": true, "bootEntry": "cb-os_0.3+3.efi", "state": "ok", "message": "system state",
                                     "updatedAt": "2027-01-15T08:00:00Z"])
        writer.write("update.json", ["state": "available", "message": "version 0.4 is available (you have 0.3)", "updatedAt": "2027-01-15T08:00:05Z", "current": "0.3",
                                     "latest": "0.4", "updateAvailable": true, "notes": "Better.", "checkedAt": "2027-01-15T08:00:04Z", "releaseUrl": "https://example.invalid/r"])
        writer.write("install-to-disk.json", ["state": "running", "step": "copying", "device": "/dev/nvme0n1", "message": "copying the system", "updatedAt": "2027-01-15T08:01:00Z"])
        let info = await rig.system.info()
        #expect(info.version == "0.3", "the system's own version")
        #expect(info.sshEnabled == true && info.automaticUpdates == true)
        let update = try #require(info.update)
        #expect(update.state == "idle" && update.available && update.current == "0.3" && update.latest == "0.4" && update.notes == "Better.")
        #expect(update.checked == (try Date("2027-01-15T08:00:04Z", strategy: .iso8601)))
        #expect(info.install == InstallProgress(state: "running", step: "copying", device: "/dev/nvme0n1", message: "copying the system", updatedAt: try Date("2027-01-15T08:01:00Z", strategy: .iso8601)))
    }

    @Test func everyUpdateStateMapsToTheWordsTheInterfaceKnows() async throws {
        let rig = try Rig(helper: nil)
        defer { try? FileManager.default.removeItem(at: rig.directory.url) }
        let writer = FakeRootHelper(requests: rig.requests, status: rig.status, clock: rig.clock) { _, _, _ in }
        let expectations: [(String, String, Bool)] = [("checking", "checking", false), ("available", "idle", false), ("current", "idle", false), ("downloading", "downloading", false),
                                                     ("installing", "downloading", false), ("installed", "ready", true), ("failed", "error", false), ("something-new", "idle", false)]
        for (file, mapped, reboot) in expectations {
            writer.write("update.json", ["state": file, "message": "m", "updatedAt": "2027-01-15T08:00:05Z", "current": "0.1"])
            let update = try #require(await rig.system.info().update)
            #expect(update.state == mapped, "\(file)")
            #expect(update.rebootRequired == reboot, "\(file)")
        }
    }

    @Test func damagedOrHugeStatusFilesAreIgnored() async throws {
        let rig = try Rig(helper: nil)
        defer { try? FileManager.default.removeItem(at: rig.directory.url) }
        try Data("not json".utf8).write(to: rig.status.appending(path: "system.json"))
        try Data(repeating: 0x20, count: 400_000).write(to: rig.status.appending(path: "update.json"))
        try Data("[1,2]".utf8).write(to: rig.status.appending(path: "install-to-disk.json"))
        let info = await rig.system.info()
        #expect(info.mode == "installed" && info.update == nil && info.install == nil && info.version == "0.1")
    }

    // MARK: Updates

    @Test func checkingForUpdatesGoesThroughTheHelper() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        let update = try await rig.system.checkForUpdate()
        #expect(update.available && update.latest == "0.2" && update.current == "0.1" && update.state == "idle" && update.notes == "Faster and calmer.")
        #expect(rig.helper?.names() == ["update-check"])
        #expect(rig.helper?.bodies("update-check") == [[:] as NSDictionary])
        #expect(rig.leftovers.isEmpty, "the request was taken and no temporary file is left")
        let again = try await rig.system.checkForUpdate()
        #expect(again.available)
        #expect(rig.helper?.names() == ["update-check", "update-check"])
    }

    @Test func aHelperThatLeavesTheRequestStatusAtRunningStillAnswers() async throws {
        // The first image version never moved update-check.json past "running"; update.json carries the answer.
        let rig = try Rig(helper: FakeRootHelper.image(latest: "0.1", fixedStatus: false))
        defer { rig.finish() }
        let update = try await rig.system.checkForUpdate()
        #expect(!update.available && update.state == "idle" && update.current == "0.1")
    }

    @Test func aFailedCheckShowsTheHelpersSentence() async throws {
        let rig = try Rig(helper: { helper, name, _ in
            helper.writeStatus("update", "checking", "looking for updates")
            helper.writeStatus("update", "failed", "could not reach the update server (is the box online?)", extra: ["current": "0.1", "updateAvailable": false])
            helper.writeStatus(name, "failed", "failed (exit 1); see the system log")
        })
        defer { rig.finish() }
        await #expect(throws: SystemError("could not reach the update server (is the box online?)")) { try await rig.system.checkForUpdate() }
    }

    @Test func aStaleAnswerIsNotTakenForTheNewOne() async throws {
        // Both files say "done" from an earlier check; the helper takes the request and does nothing. The check must wait, then give up.
        var timing = RequestFileSystemControl.Timing()
        timing.updateCheck = .milliseconds(300)
        let rig = try Rig(helper: { _, _, _ in }, timing: timing)
        defer { rig.finish() }
        rig.helper?.write("update.json", ["state": "current", "updateAvailable": false, "current": "0.1", "updatedAt": "2027-01-15T07:00:00Z"])
        rig.helper?.write("update-check.json", ["state": "ok", "message": "done", "updatedAt": "2027-01-15T07:00:00Z"])
        let started = ContinuousClock.now
        await #expect(throws: SystemError.self) { try await rig.system.checkForUpdate() }
        #expect(ContinuousClock.now - started >= .milliseconds(250), "it waited for the new answer")
        #expect(ContinuousClock.now - started < .seconds(10), "and not forever")
    }

    @Test func aCheckHasAHardLimit() async throws {
        var timing = RequestFileSystemControl.Timing()
        timing.updateCheck = .milliseconds(250)
        let rig = try Rig(helper: { helper, _, _ in helper.writeStatus("update", "checking", "looking for updates") }, timing: timing)
        defer { rig.finish() }
        let started = ContinuousClock.now
        do {
            _ = try await rig.system.checkForUpdate()
            Issue.record("should have given up")
        } catch let error as SystemError {
            #expect(error.message.contains("too long"))
        }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func aRequestNobodyTakesIsWithdrawn() async throws {
        var timing = RequestFileSystemControl.Timing()
        timing.pickup = .milliseconds(200)
        let rig = try Rig(helper: nil, timing: timing)
        defer { try? FileManager.default.removeItem(at: rig.directory.url) }
        for action in [{ try await rig.system.reboot() }, { try await rig.system.powerOff() }, { _ = try await rig.system.checkForUpdate() }] as [@Sendable () async throws -> Void] {
            do {
                try await action()
                Issue.record("nobody answered, so it should have failed")
            } catch let error as SystemError {
                #expect(error.message.contains("isn’t answering"))
            }
        }
        #expect(rig.leftovers.isEmpty, "the withdrawn requests are gone, so a late helper cannot act on them")
    }

    @Test func applyingReturnsAtOnceAndTheStateIsFollowedThroughInfo() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        let started = ContinuousClock.now
        let first = try await rig.system.applyUpdate()
        #expect(first.state == "downloading" && !first.rebootRequired)
        #expect(ContinuousClock.now - started < .milliseconds(450), "it did not wait for the installation")
        #expect(rig.helper?.bodies("update-apply") == [["reboot": false] as NSDictionary])
        // While it runs, a second apply or a check is refused.
        await #expect(throws: SystemError.self) { _ = try await rig.system.applyUpdate() }
        await #expect(throws: SystemError.self) { _ = try await rig.system.checkForUpdate() }
        #expect(await rig.system.info().update?.state == "downloading")
        let finished = await eventually(timeout: .seconds(5)) { await rig.system.info().update?.state == "ready" }
        #expect(finished)
        let done = try #require(await rig.system.info().update)
        #expect(done.rebootRequired && done.latest == "0.2")
    }

    @Test func theMomentBetweenTheRequestAndTheFirstStatusLineStillReadsAsRunning() async throws {
        let rig = try Rig(helper: nil)
        defer { try? FileManager.default.removeItem(at: rig.directory.url) }
        let writer = FakeRootHelper(requests: rig.requests, status: rig.status, clock: rig.clock) { _, _, _ in }
        writer.write("update.json", ["state": "current", "updateAvailable": false, "current": "0.1", "updatedAt": "2027-01-15T07:00:00Z"])
        writer.write("update-apply.json", ["state": "queued", "message": "waiting to run", "updatedAt": "2027-01-15T08:00:00Z"])
        #expect(await rig.system.info().update?.state == "downloading")
        writer.write("update-apply.json", ["state": "ok", "message": "done", "updatedAt": "2027-01-15T08:10:00Z"])
        #expect(await rig.system.info().update?.state == "idle")
    }

    // MARK: Power and reset

    @Test func powerRequestsCarryExactlyTheBodiesTheHelperExpects() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try await rig.system.reboot()
        try await rig.system.powerOff()
        try await rig.system.factoryReset()
        #expect(rig.helper?.names() == ["reboot", "poweroff", "factory-reset"])
        #expect(rig.helper?.bodies("reboot") == [[:] as NSDictionary])
        #expect(rig.helper?.bodies("poweroff") == [[:] as NSDictionary])
        #expect(rig.helper?.bodies("factory-reset") == [["confirm": "RESET"] as NSDictionary])
        #expect(rig.helper?.refused.withLock { $0.isEmpty } == true)
    }

    // MARK: SSH and automatic updates

    @Test func sshIsSwitchedOnWithPlainKeysAndOffAgain() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try await rig.system.setSSH(enabled: true, authorizedKeys: [key, key + "2"])
        #expect(rig.helper?.bodies("ssh-enable").first?["authorizedKeys"] as? String == key + "\n" + key + "2" + "\n")
        #expect(await rig.system.info().sshEnabled == true, "system.json was refreshed before the call returned")
        try await rig.system.setSSH(enabled: false, authorizedKeys: [])
        #expect(rig.helper?.names() == ["ssh-enable", "ssh-disable"])
        #expect(await rig.system.info().sshEnabled == false)
    }

    @Test func keysThatAreNotPlainPublicKeysNeverReachTheHelper() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        for bad in [[], ["command=\"touch /tmp/x\" " + key], ["ssh-ed25519 AAAA\nssh-rsa B$B"], ["not a key"], [String](repeating: key, count: 21)] {
            await #expect(throws: SystemError.self) { try await rig.system.setSSH(enabled: true, authorizedKeys: bad) }
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.helper?.names().isEmpty == true)
        #expect(rig.leftovers.isEmpty)
    }

    @Test func aFailedJobShowsAsASentenceNotARawStatus() async throws {
        let rig = try Rig(helper: { helper, name, _ in helper.writeStatus(name, "failed", "failed (exit 1); see the system log\u{1b}[31m\nsecond line") })
        defer { rig.finish() }
        do {
            try await rig.system.setSSH(enabled: true, authorizedKeys: [key])
            Issue.record("should have failed")
        } catch let error as SystemError {
            #expect(error.message.hasPrefix("The system couldn’t switch SSH on."))
            #expect(error.message.contains("see the system log"))
            #expect(!error.message.contains("\n") && !error.message.contains("\u{1b}"))
        }
    }

    @Test func automaticUpdatesAreSwitchedWithABooleanBody() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try await rig.system.setAutomaticUpdates(true)
        #expect(await rig.system.info().automaticUpdates == true)
        try await rig.system.setAutomaticUpdates(false)
        #expect(rig.helper?.bodies("auto-update") == [["enabled": true] as NSDictionary, ["enabled": false] as NSDictionary])
        #expect(await rig.system.info().automaticUpdates == false)
    }

    // MARK: Installing

    @Test func disksComeFromTheInstallersOwnList() async throws {
        let behavior = FakeRootHelper.image(disks: [FakeRootHelper.disk("nvme0n1"), FakeRootHelper.disk("sda", model: "USB stick", size: 15_000_000_000, problems: ["this is the disk the system is running from"]),
                                                    FakeRootHelper.disk("../etc"), FakeRootHelper.disk("sda1")])
        let rig = try Rig(helper: behavior)
        defer { rig.finish() }
        let targets = try await rig.system.installTargets()
        #expect(targets.map(\.id) == ["nvme0n1", "sda"], "odd names are not offered")
        let nvme = try #require(targets.first)
        #expect(nvme.eligible && nvme.problems.isEmpty && nvme.model == "Acme NVMe" && nvme.sizeBytes == 256_000_000_000)
        #expect(nvme.phrase == "ERASE ALL DATA ON nvme0n1")
        #expect(nvme.note?.contains("NVME") == true)
        let stick = try #require(targets.last)
        #expect(!stick.eligible && stick.problems == ["this is the disk the system is running from"])
        #expect(stick.note?.contains("can’t be used") == true)
        #expect(rig.helper?.names() == ["install-list"])
    }

    @Test func installingNeedsTheExactSentenceAndAUsableDisk() async throws {
        let behavior = FakeRootHelper.image(disks: [FakeRootHelper.disk("nvme0n1"), FakeRootHelper.disk("sda", problems: ["this is the disk the system is running from"])])
        let rig = try Rig(helper: behavior)
        defer { rig.finish() }
        for phrase in ["", "erase all data on nvme0n1", "ERASE ALL DATA ON nvme0n1 ", "ERASE ALL DATA ON sda", " ERASE ALL DATA ON nvme0n1", "ERASE ALL DATA ON nvme0n1\n"] {
            await #expect(throws: SystemError.self, "\(phrase)") { try await rig.system.install(targetID: "nvme0n1", phrase: phrase, copyData: true) }
        }
        for target in ["", "../../dev/sda", "sda1", "nvme0n1; reboot", "/dev/nvme0n1", "nvme9n9"] {
            await #expect(throws: SystemError.self, "\(target)") { try await rig.system.install(targetID: target, phrase: "ERASE ALL DATA ON \(target)", copyData: true) }
        }
        await #expect(throws: SystemError.self) { try await rig.system.install(targetID: "sda", phrase: "ERASE ALL DATA ON sda", copyData: true) }
        #expect(rig.helper?.names().filter { $0 == "install-to-disk" }.isEmpty == true, "nothing destructive was ever requested")
    }

    @Test func aTypedSentenceStartsTheInstallationAndInfoFollowsIt() async throws {
        let rig = try Rig(helper: FakeRootHelper.image(disks: [FakeRootHelper.disk("nvme0n1")]))
        defer { rig.finish() }
        try await rig.system.install(targetID: "nvme0n1", phrase: "ERASE ALL DATA ON nvme0n1", copyData: false)
        let body = try #require(rig.helper?.bodies("install-to-disk").first)
        #expect(body == ["device": "/dev/nvme0n1", "phrase": "ERASE ALL DATA ON nvme0n1", "copyData": false, "poweroff": true, "dryRun": false] as NSDictionary,
                "exactly these five values and nothing else")
        let finished = await eventually(timeout: .seconds(5)) { await rig.system.info().install?.state == "ok" }
        #expect(finished)
        #expect(await rig.system.info().install?.step == "done")
    }

    // MARK: How requests are written

    @Test func requestsAreWholeFilesOnlyWithAllowListedNamesAndPrivateModes() async throws {
        let rig = try Rig(helper: nil, timing: { var t = RequestFileSystemControl.Timing(); t.pickup = .milliseconds(100); return t }())
        defer { try? FileManager.default.removeItem(at: rig.directory.url) }
        // Nobody consumes, so the files stay long enough to look at: write them and read before the withdrawal.
        let watcher = Task.detached { () -> [String: Int] in
            var modes: [String: Int] = [:]
            let deadline = ContinuousClock.now + .milliseconds(90)
            while ContinuousClock.now < deadline {
                for name in (try? FileManager.default.contentsOfDirectory(atPath: rig.requests.path(percentEncoded: false))) ?? [] {
                    let path = rig.requests.appending(path: name).path(percentEncoded: false)
                    if let mode = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int { modes[name] = mode }
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
            return modes
        }
        _ = try? await rig.system.setAutomaticUpdates(true)
        let modes = await watcher.value
        #expect(modes["auto-update.json"] == 0o600)
        #expect(modes.keys.allSatisfy { $0 == "auto-update.json" || ($0.hasPrefix(".auto-update.") && $0.hasSuffix(".tmp")) }, "files seen: \(modes.keys.sorted())")
        #expect(rig.leftovers.isEmpty)
    }

    @Test func aSymlinkWhereTheRequestGoesIsReplacedNotFollowed() async throws {
        var timing = RequestFileSystemControl.Timing()
        timing.pickup = .milliseconds(100)
        let rig = try Rig(helper: nil, timing: timing)
        defer { try? FileManager.default.removeItem(at: rig.directory.url) }
        let victim = rig.directory.file("victim")
        try Data("untouched".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(at: rig.requests.appending(path: "reboot.json"), withDestinationURL: victim)
        _ = try? await rig.system.reboot()
        #expect(try String(contentsOf: victim, encoding: .utf8) == "untouched")
    }

    @Test func manyRequestsAtOnceAllArrive() async throws {
        let rig = try Rig()
        defer { rig.finish() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try await rig.system.checkForUpdate() }
            group.addTask { _ = try await rig.system.checkForUpdate() }
            group.addTask { try await rig.system.setAutomaticUpdates(true) }
            group.addTask { try await rig.system.setSSH(enabled: true, authorizedKeys: [key]) }
            try await group.waitForAll()
        }
        let names = Set(rig.helper?.names() ?? [])
        #expect(names.isSuperset(of: ["update-check", "auto-update", "ssh-enable"]))
        #expect(rig.leftovers.isEmpty)
    }

    @Test func theHostFactsAreReadable() {
        let facts = RequestFileSystemControl.HostFacts.current()
        #expect(facts.hostname?.isEmpty == false)
        #expect(facts.architecture?.isEmpty == false)
    }

    @Test func theMessagesOfTheSystemAreMadeFitForAPage() {
        #expect(RequestFileSystemControl.sentence("a\nb\u{1b}[0mc\u{7f}") == "a b [0mc")
        #expect(RequestFileSystemControl.sentence(String(repeating: "x", count: 1_000)).count == 240)
    }
}
