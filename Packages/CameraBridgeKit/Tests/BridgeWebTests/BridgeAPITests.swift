import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

@Suite(.timeLimit(.minutes(1))) struct StatusAPITests {
    @Test func publicStatusIsMinimal() async throws {
        let harness = try Harness()
        _ = try await harness.signIn(name: "Hallway")
        let json = await harness.send("GET", "/api/v1/status").json
        #expect(Set(json.keys) == ["product", "version", "name", "setupRequired", "authenticated"])
        #expect(json["authenticated"] as? Bool == false)
    }

    @Test func signedInStatusTellsTheBridgesStory() async throws {
        let backend = FakeBackend()
        backend.write {
            $0.notices = [NetworkNotice(kind: .controllerOnVPN, cameraName: "Front Door", advertisedAddress: "10.5.0.2", peerAddress: "192.0.2.50", usedFallback: true,
                                        delivery: .failed)]
        }
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        _ = await session.send("POST", "/api/v1/cameras", json: ["type": "automatic", "host": "192.0.2.20", "username": "u", "name": "Front Door"])
        let json = await session.get("/api/v1/status").json
        #expect(json["state"] as? String == "running")
        #expect(json["stateText"] as? String == "Running")
        #expect(json["version"] as? String == "0.1")
        #expect(json["build"] as? String == "test")
        #expect((json["uptimeSeconds"] as? Int ?? -1) >= 0)
        let cameras = try #require(json["cameras"] as? [String: Int])
        #expect(cameras == ["total": 1, "online": 1, "paired": 0])
        let system = try #require(json["system"] as? [String: Any])
        #expect(system["mode"] as? String == "installed")
        let notices = try #require(json["notices"] as? [[String: Any]])
        #expect(notices.count == 1)
        #expect(notices.first?["title"] as? String == "Live View to a Device on a VPN Failed")
        #expect(notices.first?["severity"] as? String == "warning")
        #expect(json["streamingHelperInstalled"] as? Bool == true)
    }

    @Test func healthFollowsTheBridgeState() async throws {
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        #expect(await harness.send("GET", "/api/v1/health").status == 200)
        backend.write { $0.state = .paused }
        #expect(await harness.send("GET", "/api/v1/health").status == 200)
        backend.write { $0.state = .failed("no disk") }
        let failed = await harness.send("GET", "/api/v1/health")
        #expect(failed.status == 503)
        #expect(failed.json["ok"] as? Bool == false)
        backend.write { $0.state = .stopped }
        #expect(await harness.send("GET", "/api/v1/health").status == 503)
    }

    @Test func noticesWithNothingToSayAreLeftOut() {
        let notices = [
            NetworkNotice(kind: .macOnVPN), NetworkNotice(kind: .localNetworkDenied),
            NetworkNotice(kind: .liveViewNotReceived, cameraName: "Porch", delivery: .reached),
            NetworkNotice(kind: .controllerOnVPN, cameraName: "Porch", advertisedAddress: "10.5.0.2", delivery: .reached),
            NetworkNotice(kind: .dualHomedSubnet, interfaceName: "eth0, wlan0", detail: "192.0.2.0/24"),
        ]
        let shown = NoticeResource.resources(for: notices)
        #expect(shown.map(\.kind) == ["dualHomedSubnet"])
        #expect(shown.first?.detail.contains("eth0, wlan0") == true)
    }
}

@Suite(.timeLimit(.minutes(1))) struct SettingsAPITests {
    @Test func settingsAreReadAndChanged() async throws {
        let harness = try Harness()
        let session = try await harness.signIn(name: "Hallway")
        let before = await session.get("/api/v1/settings")
        #expect(before.status == 200)
        #expect(before.json["bridgeName"] as? String == "Hallway")
        #expect(before.json["basePort"] as? Int == 21_100)
        #expect(before.json["sensorsBridgePort"] as? Int == 21_099)
        #expect(before.json["webhookEnabled"] as? Bool == false)
        #expect(before.json["logLevel"] as? String == "info")
        #expect((before.json["webhookToken"] as? String)?.count == 32)
        let after = await session.send("PATCH", "/api/v1/settings", json: ["bridgeName": "Garage", "basePort": 22_000, "sensorsBridgePort": 22_099, "motionShadowTest": true,
                                                                          "logLevel": "debug"])
        #expect(after.status == 200)
        #expect(after.json["bridgeName"] as? String == "Garage")
        #expect(after.json["basePort"] as? Int == 22_000)
        #expect(after.json["motionShadowTest"] as? Bool == true)
        #expect(after.json["logLevel"] as? String == "debug")
        #expect(await session.get("/api/v1/status").json["name"] as? String == "Garage")
    }

    @Test func theWebhookCanBeTurnedOnAndItsTokenRenewed() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let token = try #require(await session.get("/api/v1/settings").json["webhookToken"] as? String)
        let on = await session.send("PATCH", "/api/v1/settings", json: ["webhookEnabled": true, "webhookPort": 21_090])
        #expect(on.json["webhookEnabled"] as? Bool == true)
        #expect(on.json["webhookToken"] as? String == token)
        let renewed = await session.send("PATCH", "/api/v1/settings", json: ["regenerateWebhookToken": true])
        let newToken = try #require(renewed.json["webhookToken"] as? String)
        #expect(newToken != token)
        #expect(newToken.count == 32)
        #expect(newToken.allSatisfy { $0.isHexDigit })
    }

    @Test func wrongSettingsAreExplained() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let low = await session.send("PATCH", "/api/v1/settings", json: ["basePort": 80])
        #expect(low.status == 400)
        #expect(low.json["field"] as? String == "basePort")
        #expect(await session.send("PATCH", "/api/v1/settings", json: ["webhookPort": 70_000]).status == 400)
        #expect(await session.send("PATCH", "/api/v1/settings", json: ["logLevel": "shouty"]).json["field"] as? String == "logLevel")
        #expect(await session.send("PATCH", "/api/v1/settings", json: ["bridgeName": "  "]).status == 400)
        #expect(await session.send("PATCH", "/api/v1/settings", json: ["basePort": "high"]).status == 400)
        #expect(await session.get("/api/v1/settings").json["basePort"] as? Int == 21_100, "nothing changed")
    }

    @Test func theEnginesRefusalIsShown() async throws {
        let backend = FakeBackend()
        backend.write { $0.settings.webhookToken = "short" }
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let answer = await session.send("PATCH", "/api/v1/settings", json: ["webhookEnabled": true])
        #expect(answer.status == 422)
        #expect((answer.json["message"] as? String)?.contains("webhook token") == true)
    }

    @Test func pausingAndResumingTheBridge() async throws {
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        #expect(await session.send("POST", "/api/v1/bridge/pause").status == 204)
        #expect(await session.get("/api/v1/status").json["state"] as? String == "paused")
        #expect(await session.send("POST", "/api/v1/bridge/resume").status == 204)
        #expect(await session.get("/api/v1/status").json["state"] as? String == "running")
    }

    @Test func theSensorsBridgeExplainsWhyItIsNotThereYet() async throws {
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let none = await session.get("/api/v1/sensors-bridge")
        #expect(none.json["available"] as? Bool == false)
        #expect((none.json["message"] as? String)?.hasPrefix("It starts when you add a camera") == true)
        _ = await session.send("POST", "/api/v1/cameras", json: ["type": "automatic", "host": "192.0.2.20", "username": "u", "name": "Front"])
        backend.write { $0.state = .paused }
        #expect((await session.get("/api/v1/sensors-bridge").json["message"] as? String) == "The bridge is paused. Resume it to use the sensors bridge.")
        backend.write { $0.state = .running }
        #expect((await session.get("/api/v1/sensors-bridge").json["message"] as? String) == "It isn’t running. The log shows why.")
        backend.write { $0.sensorsBridge = SensorsBridgeStatus(isPaired: false, setupCode: "87654321", setupURI: "X-HM://00GW95DQA7OSX", accessoryCount: 2) }
        let ready = await session.get("/api/v1/sensors-bridge")
        #expect(ready.json["available"] as? Bool == true)
        #expect(ready.json["setupCode"] as? String == "876-54-321")
        #expect((ready.json["qrSVG"] as? String)?.hasPrefix("<svg") == true)
        backend.write { $0.sensorsBridge = SensorsBridgeStatus(isPaired: true, setupCode: "87654321", setupURI: "X-HM://00GW95DQA7OSX", accessoryCount: 2) }
        let paired = await session.get("/api/v1/sensors-bridge")
        #expect(paired.json["paired"] as? Bool == true)
        #expect(paired.json["setupCode"] == nil)
        #expect(await session.send("POST", "/api/v1/sensors-bridge/reset-pairing").status == 204)
    }
}

@Suite(.timeLimit(.minutes(1))) struct LogAndDiagnosticsAPITests {
    private func write(_ feed: LogFeed, _ level: LogLevel, _ message: String, at date: Date = Date()) {
        feed.record(LogEntry(date: date, level: level, category: "Test", message: message))
    }

    @Test func recentLinesAreListedOldestFirst() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        write(harness.logs, .info, "first")
        write(harness.logs, .warning, "second")
        write(harness.logs, .debug, "hidden by default")
        let json = await session.get("/api/v1/logs").json
        let lines = try #require(json["lines"] as? [[String: Any]])
        #expect(lines.compactMap { $0["message"] as? String } == ["first", "second"])
        #expect(lines.last?["level"] as? String == "warning")
        #expect(lines.first?["category"] as? String == "Test")
    }

    @Test func linesCanBeFilteredByLevelLimitAndTime() async throws {
        let harness = try Harness(modify: { _ in })
        let session = try await harness.signIn()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<10 { write(harness.logs, index.isMultiple(of: 2) ? .info : .error, "line \(index)", at: base.addingTimeInterval(Double(index))) }
        let errors = try #require(await session.get("/api/v1/logs?level=error").json["lines"] as? [[String: Any]])
        #expect(errors.count == 5)
        let limited = try #require(await session.get("/api/v1/logs?limit=3").json["lines"] as? [[String: Any]])
        #expect(limited.compactMap { $0["message"] as? String } == ["line 7", "line 8", "line 9"])
        let since = try #require(await session.get("/api/v1/logs?since=2027-01-15T08:00:07Z").json["lines"] as? [[String: Any]])
        #expect(since.compactMap { $0["message"] as? String } == ["line 8", "line 9"])
        let tooMany = try #require(await session.get("/api/v1/logs?limit=999999").json["lines"] as? [[String: Any]])
        #expect(tooMany.count == 10)
        let nonsense = await session.get("/api/v1/logs?limit=abc&level=zzz&since=yesterday")
        #expect(nonsense.status == 200, "bad query values fall back to the defaults")
    }

    @Test func secretsInLogLinesAreRedacted() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        write(harness.logs, .error, "could not open rtsp://admin:hunter2@192.0.2.20/stream and password=hunter2")
        let text = await session.get("/api/v1/logs").text
        #expect(!text.contains("hunter2"))
    }

    @Test func logsStreamLiveAsServerSentEvents() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        write(harness.logs, .info, "backlog line")
        let stream = await session.stream("/api/v1/logs?limit=10", headers: [("Accept", "text/event-stream")])
        defer { stream.stop() }
        #expect(stream.response.headers["Content-Type"] == "text/event-stream; charset=utf-8")
        #expect(stream.response.headers["Cache-Control"] == "no-store")
        #expect(await stream.wait { $0.contains("backlog line") })
        write(harness.logs, .warning, "live line")
        #expect(await stream.wait { $0.contains("live line") })
        let events = stream.events("log")
        #expect(events.compactMap { $0["message"] as? String } == ["backlog line", "live line"])
        #expect(stream.text.hasPrefix("retry: 3000\n\n"))
    }

    @Test func theFeedKeepsOnlyWhatItWasToldToKeep() {
        let feed = LogFeed(capacity: 20, minimumLevel: .notice)
        feed.record(LogEntry(level: .info, category: "x", message: "too quiet"))
        for index in 0..<100 { feed.record(LogEntry(level: .error, category: "x", message: "e\(index)")) }
        #expect(feed.count <= 20 + 32)
        #expect(feed.recent(limit: 1, level: .debug).first?.message == "e99")
        #expect(!feed.recent(limit: 500, level: .debug).contains { $0.message == "too quiet" })
        feed.record(LogEntry(level: .error, category: "x", message: String(repeating: "m", count: 10_000)))
        #expect((feed.recent(limit: 1).first?.message.count ?? 0) <= LogFeed.maximumMessageLength)
    }

    @Test func diagnosticsAreADownloadableTextFile() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let answer = await session.get("/api/v1/diagnostics")
        #expect(answer.status == 200)
        #expect(answer.headers["Content-Type"] == "text/plain; charset=utf-8")
        let disposition = try #require(answer.headers["Content-Disposition"])
        #expect(disposition.hasPrefix("attachment; filename=\"CameraBridge-Diagnostics-"))
        #expect(disposition.hasSuffix(".txt\""))
        #expect(answer.text.contains("Camera Bridge diagnostics"))
        #expect(answer.text.contains("Camera Bridge OS 0.1"), "the report names this product and version")
    }
}

@Suite(.timeLimit(.minutes(1))) struct EventStreamAPITests {
    private func addCamera(_ session: Harness.Session) async throws -> UUID {
        let answer = await session.send("POST", "/api/v1/cameras", json: ["type": "automatic", "host": "192.0.2.20", "username": "u", "name": "Front Door"])
        return try #require(UUID(uuidString: answer.json["id"] as? String ?? ""))
    }

    @Test func aNewListenerGetsTheStateAsItIs() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let id = try await addCamera(session)
        harness.app.startEvents()
        defer { harness.app.stopEvents() }
        let stream = await session.stream("/api/v1/events")
        defer { stream.stop() }
        #expect(stream.response.headers["Content-Type"] == "text/event-stream; charset=utf-8")
        #expect(await stream.wait { $0.contains("event: notices") })
        #expect(stream.events("bridge").first?["state"] as? String == "running")
        let camera = try #require(stream.events("camera").first)
        #expect(camera["id"] as? String == id.uuidString)
        #expect((camera["status"] as? [String: Any])?["connection"] as? String == "online")
    }

    @Test func changesAreAnnouncedAsTheyHappen() async throws {
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let id = try await addCamera(session)
        harness.app.startEvents()
        defer { harness.app.stopEvents() }
        let stream = await session.stream("/api/v1/events")
        defer { stream.stop() }
        #expect(await stream.wait { $0.contains("event: notices") })
        // Let the hub take its baseline, then change things.
        try await Task.sleep(for: .milliseconds(100))
        backend.write {
            $0.statusOverrides[id] = CameraStatus(id: id, name: "Front Door", kind: .camera, vendor: .onvif, connection: .online, isPaired: true, motionActive: true,
                                                  lastEvent: "Motion", lastEventDate: Date())
        }
        #expect(await stream.wait { $0.contains("event: motion") })
        let motion = try #require(stream.events("motion").first)
        #expect(motion["active"] as? Bool == true)
        #expect(motion["name"] as? String == "Front Door")
        #expect(stream.events("camera").contains { ($0["status"] as? [String: Any])?["motion"] as? Bool == true })
        backend.write {
            $0.statusOverrides[id] = CameraStatus(id: id, name: "Front Door", kind: .camera, vendor: .onvif, connection: .online, isPaired: true,
                                                  lastEvent: "Doorbell ring", lastEventDate: Date().addingTimeInterval(5))
        }
        #expect(await stream.wait { $0.contains("event: doorbell") })
        backend.write { $0.state = .paused }
        #expect(await stream.wait { $0.contains("\"state\":\"paused\"") })
        backend.write { $0.configurations.removeAll() }
        #expect(await stream.wait { $0.contains("event: removed") })
        #expect(stream.events("removed").first?["id"] as? String == id.uuidString)
    }

    @Test func noticesAreAnnouncedWhenTheyChange() async throws {
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        harness.app.startEvents()
        defer { harness.app.stopEvents() }
        let stream = await session.stream("/api/v1/events")
        defer { stream.stop() }
        #expect(await stream.wait { $0.contains("event: notices") })
        try await Task.sleep(for: .milliseconds(100))
        backend.write { $0.notices = [NetworkNotice(kind: .dualHomedSubnet, interfaceName: "eth0, wlan0")] }
        #expect(await stream.wait { $0.contains("This Bridge Is on Your Network Twice") })
    }

    @Test func theNumberOfListenersIsLimited() async throws {
        let harness = try Harness { $0.maximumEventStreams = 1 }
        let session = try await harness.signIn()
        harness.app.startEvents()
        defer { harness.app.stopEvents() }
        let first = await session.stream("/api/v1/events")
        let refused = await session.send("GET", "/api/v1/events")
        #expect(refused.status == 429)
        first.stop()
        #expect(await eventually { first.finished.value })
        let again = await session.stream("/api/v1/events")
        #expect(again.response.status == 200)
        again.stop()
    }

    @Test func eventsNeedASession() async throws {
        let harness = try Harness()
        _ = try await harness.signIn()
        #expect(await harness.send("GET", "/api/v1/events").status == 401)
        #expect(await harness.send("GET", "/api/v1/logs", headers: [("Accept", "text/event-stream")]).status == 401)
    }

    @Test func serverEventsAreFormattedForEventSource() {
        #expect(ServerEvent(name: "camera", data: "{\"a\":1}").text == "event: camera\ndata: {\"a\":1}\n\n")
        #expect(ServerEvent.ping.text == ": ping\n\n")
    }
}

@Suite(.timeLimit(.minutes(1))) struct SystemAPITests {
    @Test func theSystemDescribesItself() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let json = await session.get("/api/v1/system").json
        #expect(json["product"] as? String == "Camera Bridge OS")
        #expect(json["mode"] as? String == "installed")
        #expect(json["canInstall"] as? Bool == true)
        #expect(json["canReboot"] as? Bool == true)
        #expect(json["canManage"] as? Bool == true)
        #expect(json["sshEnabled"] as? Bool == false)
        #expect(json["automaticUpdates"] as? Bool == true)
    }

    @Test func updatesAreCheckedAndApplied() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let check = await session.send("POST", "/api/v1/system/update", json: ["action": "check"])
        #expect(check.status == 200)
        #expect(check.json["available"] as? Bool == true)
        #expect(check.json["latest"] as? String == "0.2")
        let apply = await session.send("POST", "/api/v1/system/update", json: ["action": "apply"])
        #expect(apply.json["rebootRequired"] as? Bool == true)
        #expect(harness.system.calls.value == ["check", "apply"])
        #expect(await session.send("POST", "/api/v1/system/update", json: ["action": "explode"]).status == 400)
        #expect(await session.send("POST", "/api/v1/system/update", json: [String: String]()).status == 400)
    }

    @Test func restartingNeedsAConfirmation() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        #expect(await session.send("POST", "/api/v1/system/reboot", json: [String: String]()).status == 400)
        #expect(await session.send("POST", "/api/v1/system/reboot", json: ["confirm": false]).status == 400)
        #expect(harness.system.calls.value.isEmpty)
        #expect(await session.send("POST", "/api/v1/system/reboot", json: ["confirm": true]).status == 202)
        #expect(harness.system.calls.value == ["reboot"])
    }

    @Test func installingNeedsADiskAndTheTypedSentence() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let disks = await session.get("/api/v1/system/disks")
        let first = (disks.json["disks"] as? [[String: Any]])?.first
        #expect(first?["id"] as? String == "nvme0n1")
        #expect(first?["phrase"] as? String == "ERASE ALL DATA ON nvme0n1")
        #expect(first?["eligible"] as? Bool == true)
        #expect(await session.send("POST", "/api/v1/system/install", json: ["phrase": "ERASE ALL DATA ON nvme0n1"]).status == 400)
        #expect(await session.send("POST", "/api/v1/system/install", json: ["targetID": "nvme0n1"]).status == 400)
        #expect(await session.send("POST", "/api/v1/system/install", json: ["targetID": "nvme0n1", "confirm": true]).status == 400, "a tick box is not the sentence")
        #expect(await session.send("POST", "/api/v1/system/install", json: ["targetID": "nvme0n1", "phrase": ""]).status == 400)
        #expect(harness.system.calls.value.isEmpty)
        let started = await session.send("POST", "/api/v1/system/install", json: ["targetID": "nvme0n1", "phrase": "ERASE ALL DATA ON nvme0n1", "copyData": false])
        #expect(started.status == 202)
        #expect(harness.system.calls.value == ["install:nvme0n1:ERASE ALL DATA ON nvme0n1:false"])
        let refused = await session.send("POST", "/api/v1/system/install", json: ["targetID": "bad", "phrase": "x"])
        #expect(refused.status == 409)
        #expect(refused.json["message"] as? String == "That disk can’t be used.")
    }

    @Test func poweringOffAndResettingNeedConfirmations() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        #expect(await session.send("POST", "/api/v1/system/poweroff", json: [String: String]()).status == 400)
        #expect(await session.send("POST", "/api/v1/system/factory-reset", json: [String: String]()).status == 400)
        #expect(await session.send("POST", "/api/v1/system/factory-reset", json: ["confirm": true]).status == 400, "the word, not a tick")
        #expect(await session.send("POST", "/api/v1/system/factory-reset", json: ["confirm": "reset"]).status == 400)
        #expect(harness.system.calls.value.isEmpty)
        #expect(await session.send("POST", "/api/v1/system/poweroff", json: ["confirm": true]).status == 202)
        #expect(await session.send("POST", "/api/v1/system/factory-reset", json: ["confirm": "RESET"]).status == 202)
        #expect(harness.system.calls.value == ["poweroff", "factory-reset"])
    }

    @Test func sshAndAutomaticUpdatesAreSwitchedFromTheInterface() async throws {
        let harness = try Harness()
        let session = try await harness.signIn()
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLE me@example"
        #expect(await session.send("POST", "/api/v1/system/ssh", json: [String: String]()).status == 400)
        let none = await session.send("POST", "/api/v1/system/ssh", json: ["enabled": true])
        #expect(none.status == 400 && none.json["field"] as? String == "authorizedKeys")
        let withOptions = await session.send("POST", "/api/v1/system/ssh", json: ["enabled": true, "authorizedKeys": "command=\"rm -rf /\" " + key])
        #expect(withOptions.status == 400, "only plain public keys")
        #expect(harness.system.calls.value.isEmpty)
        let on = await session.send("POST", "/api/v1/system/ssh", json: ["enabled": true, "authorizedKeys": "# mine\n" + key + "\n\n"])
        #expect(on.status == 200)
        #expect(await session.send("POST", "/api/v1/system/ssh", json: ["enabled": false]).status == 200)
        #expect(await session.send("POST", "/api/v1/system/auto-update", json: [String: String]()).status == 400)
        #expect(await session.send("POST", "/api/v1/system/auto-update", json: ["enabled": true]).status == 200)
        #expect(harness.system.calls.value == ["ssh:true:1", "ssh:false:0", "auto-update:true"])
    }

    @Test func sshKeysAreCheckedStrictly() throws {
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLE"
        #expect(try SSHKeys.parse(key) == [key])
        #expect(try SSHKeys.parse(key + " laptop\r\n\r\n# a comment\n" + key + "  \n").count == 2)
        for bad in ["", "   \n", "ssh-dss AAAA", "ssh-ed25519", "ssh-ed25519 AAAA$AAA", "ssh-ed25519 =AAAA", "ssh-ed25519 AA=AA", "command=\"x\" " + key,
                    key + " bad\u{7}comment", key + " " + String(repeating: "c", count: 101), String(repeating: key + "\n", count: 21),
                    "ssh-ed25519 " + String(repeating: "A", count: 9_000), "from=\"1.2.3.4\",ssh-ed25519 AAAA"] {
            #expect(throws: SystemError.self, "\(bad.prefix(30))") { try SSHKeys.parse(bad) }
        }
    }

    @Test func withoutAnOperatingSystemUnderneathTheseAreRefusedPlainly() async throws {
        let backend = FakeBackend()
        let harness = try Harness(backend: backend)
        let session = try await harness.signIn()
        let plain = WebApp(configuration: WebConfiguration(dataDirectory: harness.directory.url, port: 0, passwordIterations: 1_000), backend: backend,
                           system: UnavailableSystemControl(), logs: harness.logs)
        let info = await plain.handle(harness.request("GET", "/api/v1/system", cookie: session.cookie))
        #expect(info.status == 200)
        let reboot = await plain.handle(harness.request("POST", "/api/v1/system/reboot", json: ["confirm": true], cookie: session.cookie, csrf: session.csrf))
        #expect(reboot.status == 409)
        let disks = await plain.handle(harness.request("GET", "/api/v1/system/disks", cookie: session.cookie))
        #expect(disks.status == 409)
        let poweroff = await plain.handle(harness.request("POST", "/api/v1/system/poweroff", json: ["confirm": true], cookie: session.cookie, csrf: session.csrf))
        #expect(poweroff.status == 409)
        let reset = await plain.handle(harness.request("POST", "/api/v1/system/factory-reset", json: ["confirm": "RESET"], cookie: session.cookie, csrf: session.csrf))
        #expect(reset.status == 409)
        let auto = await plain.handle(harness.request("POST", "/api/v1/system/auto-update", json: ["enabled": true], cookie: session.cookie, csrf: session.csrf))
        #expect(auto.status == 409)
    }
}
