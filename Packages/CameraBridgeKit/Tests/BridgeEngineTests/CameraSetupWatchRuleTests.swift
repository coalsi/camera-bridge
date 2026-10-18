import BridgeSupport
import CameraAdapters
import Foundation
import Testing
@testable import BridgeEngine

/// "Set up for Camera Bridge"'s rule for "Watch its internet" (the camera's DNS, the last step), the pure pieces: it still runs after an
/// earlier step the camera refused, unless that refusal says the camera stopped answering or refused the login the DNS step uses; and the
/// watch its result leaves (`CameraSetupState.watchedServer`), which a record saved by an older build does not have.
@Suite struct CameraSetupWatchRuleTests {
    /// Streams that "didn't stick" or a value out of range are the camera's answers; a timeout is no answer; a refused login is the API's
    /// it came through.
    @Test func whatAStepsFailureSaysAboutTheCamera() {
        #expect(BridgeEngine.setupFailure(CameraAdapterError.unauthorized, login: .onvif) == .loginRefused(.onvif))
        #expect(BridgeEngine.setupFailure(CameraAdapterError.lockedOut(until: Date()), login: nil) == .loginRefused(nil))
        let silent: [any Error] = [TransportError.timedOut, TransportError.connectionRefused, TransportError.closed, DeadlineExceeded(limit: .seconds(10))]
        for error in silent { #expect(BridgeEngine.setupFailure(error, login: .isapi) == .silent, "\(error)") }
        let answers: [any Error] = [CameraAdapterError.httpStatus(403), CameraAdapterError.soapFault("ter:InvalidArgVal"), CameraAdapterError.unsupported("no")]
        for error in answers { #expect(BridgeEngine.setupFailure(error, login: .onvif) == .answered, "\(error)") }

        let stuck = [CameraConfigAttempt(method: .onvifMinimal, failure: .didNotStick), CameraConfigAttempt(method: .onvifFull, failure: .didNotStick),
                     CameraConfigAttempt(method: .onvifMinimal, failure: .rejected("the value is outside the range the camera reports"))]
        #expect(BridgeEngine.encoderFailure(stuck) == .answered)
        #expect(BridgeEngine.encoderFailure([CameraConfigAttempt(method: .reolinkAPI, failure: .unauthorized)]) == .loginRefused(.reolink))
        #expect(BridgeEngine.encoderFailure([CameraConfigAttempt(method: .hikvisionISAPI, failure: .rejected("HTTP 403")),
                                             CameraConfigAttempt(method: .onvifMinimal, failure: .lockedOut(until: Date()))]) == .loginRefused(.onvif))
        #expect(BridgeEngine.encoderFailure([CameraConfigAttempt(method: .onvifMinimal, failure: .network("the camera did not answer")),
                                             CameraConfigAttempt(method: .onvifFull, failure: .network("the camera did not answer"))]) == .silent)
        #expect(BridgeEngine.encoderFailure([CameraConfigAttempt(method: .hikvisionISAPI, failure: .network("the camera did not answer")),
                                             CameraConfigAttempt(method: .onvifMinimal, failure: .unsupported("camera has no ONVIF service"))]) == .answered)
        #expect(BridgeEngine.encoderFailure([]) == .answered)
    }

    /// Watch runs after the camera's own answer and after another API's refused login; not after no answer, nor after a refused login of
    /// its API (a Reolink without `LocalLink` reads its DNS through ONVIF, as an older build's time source went) or of one the engine can't
    /// tell.
    @Test func watchRunsUnlessTheCameraIsSilentOrRefusedItsLogin() {
        #expect(BridgeEngine.watchHeld(by: .answered, at: .streams, watch: .onvif) == nil)
        #expect(BridgeEngine.watchHeld(by: .loginRefused(.reolink), at: .timeZone, watch: .onvif) == nil, "Reolink's own API is another login")
        #expect(BridgeEngine.watchHeld(by: .loginRefused(.onvif), at: .upnp, watch: .isapi) == nil)
        #expect(BridgeEngine.watchHeld(by: .silent, at: .upnp, watch: .isapi) == "the camera stopped answering at “UPnP off”, so Camera Bridge did not try it")
        let refused = "the camera refused the login at “Time from the bridge”, so Camera Bridge did not try it: another refused login can lock the camera’s logins"
        #expect(BridgeEngine.watchHeld(by: .loginRefused(.onvif), at: .timeSource, watch: .onvif) == refused, "the same API")
        #expect(BridgeEngine.watchHeld(by: .loginRefused(nil), at: .timeSource, watch: .onvif) == refused)
        #expect(BridgeEngine.watchHeld(by: .loginRefused(.isapi), at: .timeSource, watch: nil) == refused)
    }

    /// A change the account may not make (`.notPermitted`: the camera signs the account in and reads with it, but refuses it the change, as the
    /// Reolink doorbell's ONVIF refuses `SetNTP`) is the camera's answer, not a refused login: it holds no Watch, and the step says to use an
    /// administrator account.
    @Test func aChangeTheAccountMayNotMakeIsTheCamerasAnswer() {
        let refused = CameraAdapterError.notPermitted("SetNTP")
        #expect(BridgeEngine.setupFailure(refused, login: .onvif) == .answered)
        #expect(BridgeEngine.watchHeld(by: BridgeEngine.setupFailure(refused, login: .onvif), at: .timeSource, watch: .onvif) == nil)
        #expect(BridgeEngine.encoderFailure([CameraConfigAttempt(method: .onvifMinimal, failure: .notPermitted),
                                             CameraConfigAttempt(method: .onvifFull, failure: .notPermitted)]) == .answered)
        let words = "the account Camera Bridge uses may not change this; use an administrator account in the camera’s settings"
        #expect(BridgeEngine.setupReason(refused) == words)
        #expect(BridgeEngine.readableReason(refused) == words)
        #expect(BridgeEngine.setupReason(CameraAdapterError.unauthorized) == "the camera refused the login")

        // The streams: every method refused the account the change, said in those words; otherwise each method's own.
        let all = [CameraEncoderEditResult(isSub: false, succeeded: false, method: nil,
                                           failures: [.init(method: .onvifMinimal, failure: .notPermitted), .init(method: .onvifFull, failure: .notPermitted)])]
        #expect(BridgeEngine.streamsRefusal(all) == words)
        let mixed = [CameraEncoderEditResult(isSub: false, succeeded: false, method: nil,
                                             failures: [.init(method: .reolinkAPI, failure: .rejected("SetEnc error -13")),
                                                        .init(method: .onvifMinimal, failure: .notPermitted)])]
        #expect(BridgeEngine.streamsRefusal(mixed) == "Reolink API: SetEnc error -13; ONVIF minimal: this account may not change it")
        #expect(BridgeEngine.streamsRefusal([CameraEncoderEditResult(isSub: true, succeeded: false, method: nil, failures: [])]).isEmpty)

        // Typed, so the run goes on after it: every method refused so, or the step threw it.
        #expect(BridgeEngine.encoderNotPermitted(all) && !BridgeEngine.encoderNotPermitted(mixed))
        #expect(!BridgeEngine.encoderNotPermitted([CameraEncoderEditResult(isSub: true, succeeded: false, method: nil, failures: [])]))
        #expect(BridgeEngine.refusal(refused) == CameraSetupOutcome(succeeded: false, detail: words, notPermitted: true))
        #expect(BridgeEngine.refusal(CameraAdapterError.unauthorized) == CameraSetupOutcome(succeeded: false, detail: "the camera refused the login"))
    }

    @Test func aStepsLoginIsTheOneItsReadWentThrough() {
        var read = CameraSetupRead()
        read.fresh.timeZone = CameraTimeZoneBackup(method: .reolinkAPI, value: "1")
        read.fresh.timeSource = CameraTimeSourceBackup(method: .onvifMinimal, mode: "NTP")
        read.fresh.internetWatch = CameraDNSBackup(method: .hikvisionISAPI, fromDHCP: false, servers: ["8.8.8.8"])
        read.fresh.upnp = CameraFeatureBackup(path: "/ISAPI/System/Network/UPnP", enabled: true)
        read.fresh.cloud = CameraFeatureBackup(path: "mobile", enabled: true)
        #expect(BridgeEngine.setupLogin(.timeZone, read: read) == .reolink)
        #expect(BridgeEngine.setupLogin(.timeSource, read: read) == .onvif)
        #expect(BridgeEngine.setupLogin(.internetWatch, read: read) == .isapi)
        #expect(BridgeEngine.setupLogin(.upnp, read: read) == .isapi)
        #expect(BridgeEngine.setupLogin(.cloud, read: read) == .onvif, "a web API's cloud: one account with ONVIF")
        #expect(BridgeEngine.setupLogin(.videoPassword, read: read) == .onvif && BridgeEngine.setupLogin(.extraServices, read: read) == .onvif)
        #expect(BridgeEngine.setupLogin(.streams, read: read) == nil && BridgeEngine.setupLogin(.cleanPicture, read: read) == nil, "they try several ways")
        #expect(BridgeEngine.setupLogin(.timeZone, read: CameraSetupRead()) == nil)
        #expect(CameraSetupLogin(.onvifFull) == .onvif && CameraSetupLogin(.ipcWebAPI) == .onvif)
    }

    /// A Reolink's UPnP off and Cloud off go through its own API (backup paths "reolink:Upnp", "reolink:P2p"): a login refused there is
    /// Reolink's, so it holds back "Watch its internet" when that goes through Reolink's `LocalLink` too (ReolinkAPI keeps no block after a
    /// refused login: Watch would log in again with the refused password), and not when the DNS goes through ONVIF.
    @Test func aReolinksUPnPAndCloudGoThroughItsOwnLogin() {
        var read = CameraSetupRead()
        read.fresh.upnp = CameraFeatureBackup(path: "reolink:Upnp", enabled: true)
        read.fresh.cloud = CameraFeatureBackup(path: "reolink:P2p", enabled: true)
        read.fresh.internetWatch = CameraDNSBackup(method: .reolinkAPI, fromDHCP: true, servers: ["192.168.77.1", "192.168.77.1"])
        #expect(BridgeEngine.setupLogin(.upnp, read: read) == .reolink && BridgeEngine.setupLogin(.cloud, read: read) == .reolink)
        #expect(BridgeEngine.setupLogin(.internetWatch, read: read) == .reolink)
        let watch = BridgeEngine.setupLogin(.internetWatch, read: read)
        let refused = CameraAdapterError.unauthorized
        for step in [CameraSetupStepID.upnp, .cloud] {
            let failure = BridgeEngine.setupFailure(refused, login: BridgeEngine.setupLogin(step, read: read))
            #expect(failure == .loginRefused(.reolink))
            #expect(BridgeEngine.watchHeld(by: failure, at: step, watch: watch)?.hasPrefix("the camera refused the login at") == true, "\(step)")
        }
        read.fresh.internetWatch = CameraDNSBackup(method: .onvifMinimal, fromDHCP: true, servers: [])   // a Reolink without LocalLink
        #expect(BridgeEngine.watchHeld(by: .loginRefused(.reolink), at: .cloud, watch: BridgeEngine.setupLogin(.internetWatch, read: read)) == nil)
        #expect(BridgeEngine.featureLogin("/ISAPI/System/Network/UPnP") == .isapi && BridgeEngine.featureLogin("mobile") == .onvif)
    }

    /// The step's result sets the watch; a step that could not be read leaves it as it was.
    @Test func theWatchFollowsTheStepsResult() {
        for status in [CameraSetupStepStatus.done, .alreadyRight] {
            #expect(BridgeEngine.watchedServer(after: status, was: nil, server: "192.168.77.2") == "192.168.77.2", "\(status)")
        }
        for status in [CameraSetupStepStatus.refused, .notRun, .restored] {
            #expect(BridgeEngine.watchedServer(after: status, was: "192.168.77.2", server: "192.168.77.2") == nil, "\(status)")
        }
        for status in [CameraSetupStepStatus.notSupported, .notOffered] {
            #expect(BridgeEngine.watchedServer(after: status, was: "192.168.77.2", server: nil) == "192.168.77.2", "\(status)")
            #expect(BridgeEngine.watchedServer(after: status, was: nil, server: "192.168.77.2") == nil, "\(status)")
        }
    }

    /// A record saved by a build before the watch decodes without one (its step's record says); the watch is kept with the record, and an
    /// odd value loses only the watch.
    @Test func aRecordKeepsItsWatchAndAnOlderOneHasNone() throws {
        let older = #"{"version":1,"started":814032990,"applied":814032991,"steps":[{"id":"internetWatch","status":"done","needsRestart":false}]}"#
        let decoded = try JSONDecoder().decode(CameraSetupState.self, from: Data(older.utf8))
        #expect(decoded.watchedServer == nil && decoded.steps.map(\.status) == [.done])

        let state = CameraSetupState(started: Date(timeIntervalSinceReferenceDate: 814_032_990), steps: [.init(id: .internetWatch, status: .done)],
                                     watchedServer: "192.168.77.2")
        let encoded = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(CameraSetupState.self, from: encoded) == state)
        #expect(String(decoding: encoded, as: UTF8.self).contains(#""watchedServer":"192.168.77.2""#))

        let odd = #"{"version":1,"started":814032990,"steps":[{"id":"cloud","status":"done","needsRestart":false}],"watchedServer":7}"#
        let kept = try JSONDecoder().decode(CameraSetupState.self, from: Data(odd.utf8))
        #expect(kept.watchedServer == nil && kept.steps.map(\.id) == [.cloud])
    }
}
