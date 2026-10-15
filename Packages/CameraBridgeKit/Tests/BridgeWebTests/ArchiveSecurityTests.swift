import BridgeEngine
import BridgeSupport
import Foundation
import Synchronization
import Testing
import TestSupport
@testable import BridgeWeb

/// The NVR routes against the box's security model (addendum L9): sessions, anti-forgery checks, no leaks, the content security policy, and
/// admission (docs/superpowers/plans/2026-10-10-nvr/T00-contracts.md C.3 and C.8).
@Suite(.serialized, .timeLimit(.minutes(2))) struct NVRSecurityTests {
    /// Every route the NVR adds. A route added to `archiveRoutes` without a line here fails `everyNVRRouteIsListedHere`.
    private let expected = [
        "GET nvr/storage", "GET nvr/storage/locations", "PATCH nvr/storage", "PATCH cameras/:id/nvr", "GET nvr/cameras", "GET nvr/activity",
        "GET nvr/cameras/:id/fragments", "GET nvr/cameras/:id/fragments/:fid", "GET nvr/cameras/:id/fragments/:fid/init", "GET nvr/cameras/:id/keyframe",
        "GET nvr/cameras/:id/clip-plan", "GET nvr/cameras/:id/clip", "POST cameras/:id/optimize", "POST cameras/:id/optimize/undo",
    ]

    private func name(_ route: Route) -> String { "\(route.method) \(route.pattern.joined(separator: "/"))" }

    /// A concrete request target for `route`, with the query it needs.
    private func target(_ route: Route, rig: NVRRig, fragment: String) -> String {
        let path = "/api/v1/" + route.pattern.map { $0 == ":id" ? rig.cameraID : $0 == ":fid" ? fragment : $0 }.joined(separator: "/")
        switch route.pattern.joined(separator: "/") {
        case "nvr/activity": return path + "?cameras=\(rig.cameraID)&from=\(rig.ms(0))&binMs=60000&bins=4"
        case "nvr/cameras/:id/fragments": return path + "?at=\(rig.ms(500))"
        case "nvr/cameras/:id/keyframe": return path + "?at=\(rig.ms(500))"
        case "nvr/cameras/:id/clip-plan", "nvr/cameras/:id/clip": return path + "?from=\(rig.ms(0))&to=\(rig.ms(1_000))"
        default: return path
        }
    }

    private func body(for route: Route) -> [String: Any]? {
        switch route.pattern.joined(separator: "/") {
        case "nvr/storage": ["keepDays": 7]
        case "cameras/:id/nvr": ["enabled": true]
        case "cameras/:id/optimize": ["confirm": true]
        case "cameras/:id/optimize/undo": [:]
        default: nil
        }
    }

    private func ready() async throws -> (NVRRig, FakeArchiveReading, ArchiveFixtureFile) {
        let archive = FakeArchiveReading()
        let rig = try await NVRRig.make(archive: archive)
        let file = try rig.file(fragments: 3)
        archive.files = [file]
        return (rig, archive, file)
    }

    @Test func everyNVRRouteIsListedHere() {
        #expect(WebApp.archiveRoutes.map(name) == expected)
        #expect(WebApp.archiveRoutes.allSatisfy { $0.access == .session }, "every route needs a session")
        let all = Set(WebApp.routes.map(name))
        #expect(expected.allSatisfy(all.contains), "and every one is in the route table the application serves")
        #expect(WebApp.routes.count == Set(all).count, "no route is listed twice")
    }

    @Test func withoutASessionEveryRouteIsRefused() async throws {
        let (rig, archive, file) = try await ready()
        for route in WebApp.archiveRoutes {
            let url = target(route, rig: rig, fragment: file.fragments[0].id)
            let json = body(for: route)
            let none = await rig.harness.send(route.method, url, json: json)
            #expect(none.status == 401 && none.json["error"] as? String == "unauthorized", "\(name(route)) -> \(none.status)")
            let forged = await rig.harness.send(route.method, url, json: json, cookie: "cb_session=\(Secrets.randomToken())", csrf: rig.session.csrf)
            #expect(forged.status == 401, "\(name(route)) with a cookie nobody issued")
        }
        #expect(archive.reads.isEmpty && archive.activityCalls.isEmpty && rig.backend.read { $0.calls.isEmpty && $0.settings.nvrKeepDays == 7 }, "nothing was done for them")
    }

    @Test func beforeSetupEveryRouteSaysSetupIsRequired() async throws {
        let archive = FakeArchiveReading()
        let backend = FakeBackend()
        backend.write { $0.archive = archive }
        let harness = try Harness(backend: backend)
        let rig = (id: UUID().uuidString, fid: "aaaaaaaaaaaa.0")
        for route in WebApp.archiveRoutes {
            let url = "/api/v1/" + route.pattern.map { $0 == ":id" ? rig.id : $0 == ":fid" ? rig.fid : $0 }.joined(separator: "/")
            let answer = await harness.send(route.method, url)
            #expect(answer.status == 403 && answer.json["error"] as? String == "setup_required", "\(name(route)) -> \(answer.status)")
        }
    }

    @Test func readingNeedsNoAntiForgeryTokenAndChangingNeedsAllThree() async throws {
        let (rig, _, file) = try await ready()
        for route in WebApp.archiveRoutes {
            let url = target(route, rig: rig, fragment: file.fragments[0].id)
            let json = body(for: route)
            if route.method == "GET" {
                let answer = await rig.harness.send("GET", url, cookie: rig.session.cookie)
                #expect(![401, 403, 415].contains(answer.status), "\(name(route)) -> \(answer.status): no token is needed to read")
                continue
            }
            let noToken = await rig.harness.send(route.method, url, json: json, cookie: rig.session.cookie)
            #expect(noToken.status == 403 && noToken.json["error"] as? String == "csrf", "\(name(route)) without the token")
            let wrongToken = await rig.harness.send(route.method, url, json: json, cookie: rig.session.cookie, csrf: String(repeating: "0", count: 64))
            #expect(wrongToken.status == 403 && wrongToken.json["error"] as? String == "csrf", "\(name(route)) with another token")
            let foreign = await rig.harness.send(route.method, url, json: json, cookie: rig.session.cookie, csrf: rig.session.csrf, origin: "http://evil.example")
            #expect(foreign.status == 403 && foreign.json["error"] as? String == "cross_origin", "\(name(route)) from another site")
            var plain = rig.harness.request(route.method, url, cookie: rig.session.cookie, csrf: rig.session.csrf)
            plain.body = Data(#"{"enabled":true,"confirm":true,"keepDays":3}"#.utf8)
            plain.headers["Content-Type"] = "text/plain"
            #expect(await rig.harness.app.handle(plain).status == 415, "\(name(route)) with a body that is not JSON")
        }
        #expect(rig.backend.read { !$0.calls.contains { $0 == "setNVR" || $0 == "optimize" || $0 == "undo" } && !$0.configurations[0].nvrEnabled && $0.settings.nvrKeepDays == 7 },
                "none of those changed anything")
    }

    @Test func noAnswerAndNoLogLineHoldsTheSessionTheTokenAQueryOrAPath() async throws {
        let capture = LogCapture()
        defer { capture.stop() }
        let (rig, archive, file) = try await ready()
        archive.fail(file.fragments[2].id, with: .unreadable("/var/lib/camera-bridge/recordings/\(rig.cameraID)/2026-09-14/13-24-05.mp4 short read"))
        rig.backend.write { $0.configurations[0].nvrEnabled = true }
        var answers: [Answer] = []
        for route in WebApp.archiveRoutes {
            let url = target(route, rig: rig, fragment: file.fragments[0].id)
            answers.append(await rig.session.send(route.method, url, json: body(for: route)))
        }
        answers.append(await rig.get("nvr/cameras/\(rig.cameraID)/fragments/\(file.fragments[2].id)"))
        answers.append(await rig.get("nvr/cameras/\(rig.cameraID)/fragments?at=\(rig.ms(500))&ahead=1&secret=hunter2"))
        let token = rig.session.cookie.replacingOccurrences(of: "cb_session=", with: "")
        let forbidden = [token, rig.session.csrf, rig.harness.directory.url.path, "hunter2", "/var/lib/camera-bridge/recordings/\(rig.cameraID)"]
        for answer in answers {
            let visible = answer.text + answer.headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
            for secret in forbidden { #expect(!visible.contains(secret), "an answer holds \(secret.prefix(14))…: \(answer.text.prefix(120))") }
        }
        let lines = capture.text
        for secret in forbidden { #expect(!lines.contains { $0.contains(secret) }, "a log line holds \(secret.prefix(14))…") }
        #expect(!lines.contains { $0.contains("?") && $0.contains("/api/v1/nvr") }, "a request's query string is never logged")
        #expect(lines.contains { $0.contains("GET /api/v1/nvr/cameras") }, "the debug line names method and path")
    }

    // MARK: Content security policy

    @Test func mediaAnswersCarryTheSamePolicyAndNoValidatorsOrRanges() async throws {
        let (rig, _, file) = try await ready()
        let policy = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; media-src 'self' blob:; connect-src 'self'; font-src 'self'; "
            + "manifest-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
        let base = "nvr/cameras/\(rig.cameraID)"
        let answers = [await rig.get("\(base)/fragments/\(file.fragments[0].id)"), await rig.get("\(base)/fragments/\(file.fragments[0].id)/init"),
                       await rig.get("\(base)/keyframe?at=\(rig.ms(100))"), await rig.get("\(base)/fragments?at=\(rig.ms(100))"), await rig.get("\(base)/fragments/aaaaaaaaaaaa.0")]
        for answer in answers { #expect(answer.headers["Content-Security-Policy"] == policy) }
        let media = answers[0]
        #expect(media.status == 200 && media.headers["Content-Type"] == "video/mp4" && media.headers["X-Content-Type-Options"] == "nosniff" && media.headers["Cache-Control"] == "no-store")
        #expect(media.headers["Cross-Origin-Resource-Policy"] == "same-origin" && media.headers["Permissions-Policy"]?.contains("camera=()") == true)
        #expect(media.headers["Vary"] == nil && media.headers["ETag"] == nil && media.headers["Accept-Ranges"] == nil && media.headers["Content-Range"] == nil, "no ranges, no validators")
        #expect(answers[4].status == 410 && answers[4].headers["Cache-Control"] == "no-store", "even an error is never kept")
    }

    // MARK: Admission

    @Test func fortySimultaneousRequestsFromOneAddressRunSixteenAndRefuseTheRestAtOnce() async throws {
        let gate = AsyncGate()
        let archive = FakeArchiveReading()
        archive.setReadGate(gate)
        let rig = try await NVRRig.make(archive: archive)
        let file = try rig.file(fragments: 4)
        archive.files = [file]
        let target = "/api/v1/nvr/cameras/\(rig.cameraID)/fragments/\(file.fragments[0].id)"
        let refused = Box(0), retryHints = Box<Set<String>>([])
        let tasks = (0..<40).map { _ in
            Task { () -> Int in
                let answer = await rig.harness.send("GET", target, cookie: rig.session.cookie, from: "192.0.2.77")
                if answer.status == 429 {
                    refused.update { $0 += 1 }
                    retryHints.update { _ = $0.insert(answer.headers["Retry-After"] ?? "none") }
                }
                return answer.status
            }
        }
        #expect(await eventually(timeout: .seconds(10)) { archive.readsInFlight == 16 && refused.value == 24 }, "16 reads running, 24 refused without waiting")
        // While sixteen reads sit in the archive, the rest of the bridge answers at its usual speed.
        var elapsed: [Duration] = []
        for _ in 0..<100 {
            let started = ContinuousClock.now
            let health = await rig.harness.send("GET", "/api/v1/health")
            elapsed.append(ContinuousClock.now - started)
            #expect(health.status == 200)
        }
        elapsed.sort()
        #expect(elapsed[98] < .milliseconds(100), "the 99th percentile of /health was \(elapsed[98])")
        gate.open()
        var statuses: [Int] = []
        for task in tasks { statuses.append(await task.value) }
        #expect(statuses.filter { $0 == 200 }.count == 16 && statuses.filter { $0 == 429 }.count == 24)
        #expect(retryHints.value == ["1"])
        #expect(archive.mostReadsInFlight == 16 && rig.harness.app.archiveSlotsInUse == 0)
    }

    @Test func aSlotIsHeldOnlyWhileTheRequestRunsAndEveryFailureReleasesIt() async throws {
        let (rig, archive, file) = try await ready()
        archive.fail(file.fragments[1].id, with: .timedOut)
        for _ in 0..<20 {
            #expect((await rig.get("nvr/cameras/\(rig.cameraID)/fragments/\(file.fragments[1].id)")).status == 504)
            #expect((await rig.get("nvr/cameras/\(rig.cameraID)/fragments/\(file.fragments[0].id)")).status == 200)
            #expect((await rig.get("nvr/cameras/\(rig.cameraID)/fragments?at=\(rig.ms(-500))")).status == 200)
            #expect((await rig.get("nvr/cameras/\(rig.cameraID)/fragments/aaaaaaaaaaaa.7")).status == 410)
        }
        #expect(rig.harness.app.archiveSlotsInUse == 0)
    }

    @Test func aMalformedRequestNeverUsesASlot() async throws {
        let rig = try await NVRRig.make(archive: FakeArchiveReading()) { $0.maximumArchiveReads = 1; $0.maximumArchiveReadsPerAddress = 1 }
        #expect(rig.harness.app.takeArchiveSlot(address: "192.0.2.77"), "the only slot is taken")
        let bad = await rig.get("nvr/cameras/\(rig.cameraID)/fragments/nope")
        #expect(bad.status == 400, "validated first, so not 429")
        let busy = await rig.get("nvr/cameras/\(rig.cameraID)/fragments/aaaaaaaaaaaa.0")
        #expect(busy.status == 429 && busy.json["error"] as? String == "busy" && busy.headers["Retry-After"] == "1")
    }

    @Test func aStoreThatIsNotReadyNeverTakesASlotAndNothingElseWaitsForIt() async throws {
        let (rig, archive, file) = try await ready()
        archive.setReady(false)
        let targets = ["nvr/cameras", "nvr/activity?cameras=\(rig.cameraID)&from=\(rig.ms(0))&binMs=60000&bins=2", "nvr/cameras/\(rig.cameraID)/fragments?at=\(rig.ms(0))",
                       "nvr/cameras/\(rig.cameraID)/fragments/\(file.fragments[0].id)", "nvr/cameras/\(rig.cameraID)/fragments/\(file.fragments[0].id)/init",
                       "nvr/cameras/\(rig.cameraID)/keyframe?at=\(rig.ms(0))"]
        for _ in 0..<10 {
            for target in targets {
                let answer = await rig.get(target)
                #expect(answer.status == 503 && answer.json["error"] as? String == "archive_unavailable" && answer.headers["Retry-After"] == "2", "\(target)")
            }
        }
        #expect(rig.harness.app.archiveSlotsInUse == 0 && archive.reads.isEmpty && archive.activityCalls.isEmpty)
        for fast in ["status", "health", "nvr/storage", "nvr/storage/locations", "cameras", "settings"] {
            let started = ContinuousClock.now
            let answer = await rig.get(fast)
            #expect(answer.status == 200 && ContinuousClock.now - started < .seconds(1), "\(fast)")
        }
        archive.setReady(true)
        #expect((await rig.get("nvr/cameras/\(rig.cameraID)/fragments/\(file.fragments[0].id)")).status == 200, "ready: served")
    }
}
