#if canImport(Darwin)
import BridgeSupport
import Foundation
import PlatformApple
import TestSupport
import Testing
@testable import BridgeEngine

/// Connections answer from `script` in order, then with `rest` (nil = connected): what macOS does while its Local
/// Network alert waits for the person (`.localNetworkDenied`) and after they answer. Never touches the network.
final class ScriptedConnectTransport: NetworkTransport {
    private let answers: Box<[TransportError?]>
    private let rest: Box<TransportError?>
    let attempts = Box(0)

    init(_ script: [TransportError?], then rest: TransportError?) {
        answers = Box(script)
        self.rest = Box(rest)
    }

    /// From now on, connections that are not scripted answer with `answer`.
    func answerFromNowOn(_ answer: TransportError?) { rest.set(answer) }

    func listen(port: UInt16, loopbackOnly: Bool) async throws -> any TCPListener {
        throw TransportError.failed("not used")
    }

    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TCPConnection {
        attempts.update { $0 += 1 }
        let scripted = answers.update { answers -> TransportError?? in answers.isEmpty ? .none : .some(answers.removeFirst()) }
        if let failure = scripted ?? rest.value { throw failure }
        return FakeConnection(remoteAddress: host)
    }
}

/// The first local network operation shows the system's alert and is blocked until the person answers (TN3179): a
/// deliberate check must not report that as a denial (onboarding, plan W3-3 review).
@MainActor @Suite(.timeLimit(.minutes(1))) struct LocalNetworkCheckTests {
    private func engine(_ transport: any NetworkTransport, directory: TemporaryDirectory) -> BridgeEngine {
        BridgeEngine(environment: BridgeEnvironment(dataDirectory: directory.url,
                                                   platform: PlatformServices(transport: transport, advertiser: NullServiceAdvertiser(),
                                                                              secrets: InMemorySecretStore(),
                                                                              networkChanges: NullNetworkChangeMonitor(), power: NullPowerManager()),
                                                   codecs: AppleMediaCodecs(), loopbackOnly: true, advertise: false),
                     tuning: .testing)
    }

    private static func attempts(_ transport: ScriptedConnectTransport, atLeast count: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while transport.attempts.value < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return transport.attempts.value >= count
    }

    @Test func accessAllowedWhileTheAlertIsUpIsGranted() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let transport = ScriptedConnectTransport([.localNetworkDenied, .localNetworkDenied, .localNetworkDenied], then: .connectionRefused)
        let engine = engine(transport, directory: directory)
        #expect(await engine.checkLocalNetworkAccess(host: "192.0.2.1", answerWait: .seconds(10)) == .granted)
        #expect(engine.localNetworkAccess == .granted)
        #expect(transport.attempts.value == 4)
    }

    @Test func aDenialCountsOnlyAfterTheAnswerWait() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let transport = ScriptedConnectTransport([], then: .localNetworkDenied)
        let engine = engine(transport, directory: directory)
        let start = ContinuousClock.now
        let checking = Task { await engine.checkLocalNetworkAccess(host: "192.0.2.1", answerWait: .milliseconds(400)) }
        let retrying = await Self.attempts(transport, atLeast: 2)
        #expect(retrying)
        #expect(engine.localNetworkAccess == .unknown, "no banner while the person may still be reading the alert")
        #expect(await checking.value == .denied)
        #expect(ContinuousClock.now - start >= .milliseconds(380))
        #expect(engine.localNetworkAccess == .denied)

        // Once the answer is known, Check Again decides with one attempt.
        let before = transport.attempts.value
        #expect(await engine.checkLocalNetworkAccess(host: "192.0.2.1", answerWait: .seconds(30)) == .denied)
        #expect(transport.attempts.value == before + 1)
        transport.answerFromNowOn(nil)
        #expect(await engine.checkLocalNetworkAccess(host: "192.0.2.1") == .granted)
        #expect(engine.localNetworkAccess == .granted && transport.attempts.value == before + 2)
    }

    @Test func otherAnswersAreNotRetried() async {
        let transport = ScriptedConnectTransport([.timedOut], then: nil)
        #expect(await LocalNetworkCheck.check(host: "192.0.2.1", port: 80, transport: transport, answerWait: .seconds(10),
                                              retryInterval: .milliseconds(10)) == .unknown)
        #expect(transport.attempts.value == 1)
        let refused = ScriptedConnectTransport([.connectionRefused], then: .localNetworkDenied)
        #expect(await LocalNetworkCheck.check(host: "192.0.2.1", port: 80, transport: refused, answerWait: .seconds(10),
                                              retryInterval: .milliseconds(10)) == .granted)
        #expect(refused.attempts.value == 1)
    }

    @Test func aCancelledWaitReportsTheLastAnswer() async {
        let transport = ScriptedConnectTransport([], then: .localNetworkDenied)
        let checking = Task {
            await LocalNetworkCheck.check(host: "192.0.2.1", port: 80, transport: transport, answerWait: .seconds(30), retryInterval: .milliseconds(10))
        }
        let retrying = await Self.attempts(transport, atLeast: 2)
        #expect(retrying)
        checking.cancel()
        #expect(await checking.value == .denied)
    }

    @Test func theContractCheckWaitsForTheAlert() {
        #expect(BridgeEngine.localNetworkAnswerWait >= .seconds(15) && BridgeEngine.localNetworkAnswerWait <= .seconds(30))
        #expect(EngineTuning.standard.localNetworkRetryInterval <= .seconds(1))
    }
}
#endif
