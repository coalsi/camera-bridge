import BridgeSupport
import Foundation
import TestSupport
import Testing
@testable import CameraAdapters

/// Which ONVIF calls change something on the camera, and which prove the login: the pure pieces behind `.notPermitted`.
@Suite struct ONVIFWriteNameTests {
    @Test func theWritesAreTheCallsThatChangeTheCamera() {
        let device = "http://www.onvif.org/ver10/device/wsdl/", media = "http://www.onvif.org/ver10/media/wsdl/"
        let ptz = "\(ONVIFClient.ptzNamespace)/", imaging = "http://www.onvif.org/ver20/imaging/wsdl/"
        for (action, name) in [(device + "SetNTP", "SetNTP"), (device + "SetDNS", "SetDNS"), (device + "SetSystemDateAndTime", "SetSystemDateAndTime"),
                               (device + "SystemReboot", "SystemReboot"), (media + "SetVideoEncoderConfiguration", "SetVideoEncoderConfiguration"),
                               (media + "SetOSD", "SetOSD"), (media + "CreateOSD", "CreateOSD"), (media + "DeleteOSD", "DeleteOSD"),
                               (media + "SetSynchronizationPoint", "SetSynchronizationPoint"), (imaging + "SetImagingSettings", "SetImagingSettings"),
                               (ptz + "ContinuousMove", "ContinuousMove"), (ptz + "Stop", "Stop"), (ptz + "SendAuxiliaryCommand", "SendAuxiliaryCommand")] {
            #expect(ONVIFClient.writeName(action: action) == name, "\(action)")
        }
        let reads = [device + "GetNTP", device + "GetDNS", device + "GetDeviceInformation", media + "GetProfiles", media + "GetStreamUri",
                     imaging + "GetOptions", ptz + "GetNodes",
                     // The event service's messages: a subscription is not a change of the camera's settings.
                     "http://www.onvif.org/ver10/events/wsdl/EventPortType/CreatePullPointSubscriptionRequest",
                     "http://www.onvif.org/ver10/events/wsdl/PullPointSubscription/PullMessagesRequest",
                     "http://docs.oasis-open.org/wsn/bw-2/SubscriptionManager/RenewRequest",
                     "http://docs.oasis-open.org/wsn/bw-2/SubscriptionManager/UnsubscribeRequest"]
        for action in reads { #expect(ONVIFClient.writeName(action: action) == nil, "\(action)") }
        #expect(ONVIFClient.writeName(action: nil) == nil)
    }

    /// ONVIF's calls before authentication (its PRE_AUTH class) may be answered to anyone, whatever password they carry: they prove nothing.
    @Test func onlyACallTheCameraAnswersToTheRightPasswordProvesTheLogin() {
        let device = "http://www.onvif.org/ver10/device/wsdl/"
        for name in ["GetNTP", "GetDNS", "GetDeviceInformation", "SetDNS"] { #expect(ONVIFClient.provesLogin(action: device + name), "\(name)") }
        #expect(ONVIFClient.provesLogin(action: "http://www.onvif.org/ver10/media/wsdl/GetProfiles"))
        for name in ["GetSystemDateAndTime", "GetCapabilities", "GetServices", "GetServiceCapabilities", "GetWsdlUrl", "GetHostname", "GetEndpointReference"] {
            #expect(!ONVIFClient.provesLogin(action: device + name), "\(name)")
        }
        #expect(!ONVIFClient.provesLogin(action: "http://www.onvif.org/ver10/events/wsdl/PullPointSubscription/PullMessagesRequest"))
        #expect(!ONVIFClient.provesLogin(action: nil))
    }

    /// The account may not make the change: the camera answered and its login works, so it is no login refusal, ends no chain and pauses
    /// nothing; a step says so in words.
    @Test func aChangeTheAccountMayNotMakeIsTheCamerasAnswer() {
        let error = CameraAdapterError.notPermitted("SetNTP")
        #expect(!error.isLoginRefusal)
        #expect(CameraConfigFailure.from(CameraAdapterError.notPermitted("SetVideoEncoderConfiguration")) == .notPermitted)
        #expect(!CameraConfigFailure.notPermitted.stopsChain)
        #expect(CameraConfigFailure.notPermitted.summary == "this account may not change it")
        #expect(CameraSettingsService.cameraAnswered(error) && !CameraSettingsService.cameraSilent(error))
        #expect(ReconnectPolicy.pauseEnd(error) == nil)
        #expect(CameraAdapterError.refusalWords(error) == CameraAdapterError.notPermittedReason)
        #expect(CameraSetupOutcome.refused(error) == .notPermittedRefusal && CameraSetupOutcome.notPermittedRefusal.notPermitted)
        #expect(!CameraSetupOutcome.refused(CameraAdapterError.soapFault("ter:InvalidArgVal")).notPermitted, "another refusal is not one")
        #expect(CameraSettingsService.refusedOnlyForTheAccount([error, CameraAdapterError.unsupported("no OSD")]))
        #expect(!CameraSettingsService.refusedOnlyForTheAccount([error, CameraAdapterError.soapFault("ter:InvalidArgVal")]))
        #expect(!CameraSettingsService.refusedOnlyForTheAccount([CameraAdapterError.unsupported("no OSD")]))
        #expect(CameraAdapterError.notPermittedReason
                == "the account Camera Bridge uses may not change this; use an administrator account in the camera’s settings")
        #expect(CameraAdapterError.refusalWords(CameraAdapterError.soapFault("ter:InvalidArgVal")) == #"soapFault("ter:InvalidArgVal")"#,
                "any other refusal is quoted as it came")
    }
}

#if os(macOS) || os(Linux)
/// The Reolink doorbell (Oct 18): its ONVIF account signs in and reads (`GetNTP`, `GetDNS`), but answers the setup's `SetNTP` with a
/// `NotAuthorized` fault. Camera Bridge took that for a wrong password and paused the doorbell's ONVIF logins for 2 minutes, which made the
/// security check's DNS read fail and stopped "Watch its internet". A write refused after a call that signed in on the same client is a change
/// this account may not make (`.notPermitted`): no login pause. A refusal before any login worked is still a refused login.
@Suite(.timeLimit(.minutes(1))) struct ONVIFWriteRefusalTests {
    private static let ntp = ONVIFNTPSettings(fromDHCP: false, servers: ["192.0.2.28"])

    private func client(_ camera: MockONVIFCamera, now: @escaping @Sendable () -> Date = { Date() }) throws -> ONVIFClient {
        let url = try #require(ONVIFClient.deviceServiceURL(for: camera.endpoint))
        return ONVIFClient(deviceServiceURL: url, credentials: HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password),
                           now: now)
    }

    private func started() async throws -> (MockONVIFCamera, String) {
        let camera = try await MockONVIFCamera.start()
        let host = "127.0.0.1:\(camera.server.port)"
        ONVIFLoginGuard.shared.clear(host: host)
        return (camera, host)
    }

    @Test(arguments: [MockONVIFCamera.WriteRefusal.notAuthorizedFault, .http401])
    func aWriteRefusedAfterASignedInReadIsNotPermittedAndPausesNothing(_ refusal: MockONVIFCamera.WriteRefusal) async throws {
        let (camera, host) = try await started()
        defer { camera.stop(); ONVIFLoginGuard.shared.clear(host: host) }
        camera.refusedWrites.set(["SetNTP": refusal, "SetDNS": refusal])
        let client = try client(camera)
        _ = try await client.ntp()   // the login works
        await #expect(throws: CameraAdapterError.notPermitted("SetNTP")) { try await client.setNTP(Self.ntp) }
        #expect(ONVIFLoginGuard.shared.pause(host: host) == nil, "no login pause")
        #expect(try await client.dns().fromDHCP, "the reads go on")
        await #expect(throws: CameraAdapterError.notPermitted("SetDNS")) { try await client.setDNS(fromDHCP: false, servers: ["192.0.2.28"]) }
        #expect(ONVIFLoginGuard.shared.pause(host: host) == nil)
        #expect(camera.clock.value.ntpServers == ["pool.ntp.org"] && camera.dns.value.fromDHCP, "nothing changed")
    }

    /// A refused first call says nothing about what the account may do: it is a refused login, and logins pause as before.
    @Test func aRefusedFirstCallIsStillARefusedLogin() async throws {
        let (camera, host) = try await started()
        defer { camera.stop(); ONVIFLoginGuard.shared.clear(host: host) }
        camera.refusedWrites.set(["SetNTP": .notAuthorizedFault])
        let client = try client(camera)
        await #expect(throws: CameraAdapterError.unauthorized) { try await client.setNTP(Self.ntp) }
        #expect(ONVIFLoginGuard.shared.pause(host: host)?.cause == .refused)
    }

    /// `GetSystemDateAndTime`, `GetCapabilities` and `GetServices` may be answered to anyone (ONVIF's calls before authentication): a write
    /// refused after only those is a refused login.
    @Test func callsAnyoneGetsProveNoLogin() async throws {
        let (camera, host) = try await started()
        defer { camera.stop(); ONVIFLoginGuard.shared.clear(host: host) }
        camera.refusedWrites.set(["SetNTP": .notAuthorizedFault])
        let client = try client(camera)
        _ = try await client.systemDateAndTime()
        _ = try await client.capabilities()
        _ = try await client.services()
        await #expect(throws: CameraAdapterError.unauthorized) { try await client.setNTP(Self.ntp) }
        #expect(ONVIFLoginGuard.shared.pause(host: host)?.cause == .refused)
    }

    /// The proof lasts `loginProofWindow` after the last call that signed in: a client that has not signed in for longer (a camera's
    /// long-lived driver, whose password may have changed on the camera since) takes a refused write for a refused login again.
    @Test func aLoginProvesItselfOnlyForAWhile() async throws {
        let (camera, host) = try await started()
        defer { camera.stop(); ONVIFLoginGuard.shared.clear(host: host) }
        camera.refusedWrites.set(["SetNTP": .notAuthorizedFault])
        let clock = Box(Date(timeIntervalSince1970: 1_792_340_000))
        let client = try client(camera, now: { clock.value })
        _ = try await client.ntp()
        clock.update { $0 = $0.addingTimeInterval(ONVIFClient.loginProofWindow - 1) }
        await #expect(throws: CameraAdapterError.notPermitted("SetNTP")) { try await client.setNTP(Self.ntp) }
        clock.update { $0 = $0.addingTimeInterval(2) }
        await #expect(throws: CameraAdapterError.unauthorized) { try await client.setNTP(Self.ntp) }
        #expect(ONVIFLoginGuard.shared.pause(host: host)?.cause == .refused)
    }

    /// A refused login (the password changed on the camera) ends the proof: the next refused write is a refused login too, until a call signs
    /// in again.
    @Test func aRefusedLoginEndsTheProof() async throws {
        let (camera, host) = try await started()
        defer { camera.stop(); ONVIFLoginGuard.shared.clear(host: host) }
        let client = try client(camera)
        _ = try await client.ntp()
        camera.rejectCredentials.set(true)
        await #expect(throws: CameraAdapterError.unauthorized) { try await client.dns() }
        ONVIFLoginGuard.shared.clear(host: host)   // the pause is over
        camera.rejectCredentials.set(false)
        camera.refusedWrites.set(["SetNTP": .notAuthorizedFault])
        await #expect(throws: CameraAdapterError.unauthorized) { try await client.setNTP(Self.ntp) }
        ONVIFLoginGuard.shared.clear(host: host)
        _ = try await client.ntp()
        await #expect(throws: CameraAdapterError.notPermitted("SetNTP")) { try await client.setNTP(Self.ntp) }
    }

    /// Set up for Camera Bridge's time source on such a camera: refused in the account's words, read and written through the same service,
    /// with no login pause, so the steps after it (Watch's DNS) can still sign in.
    @Test func aStepTheAccountMayNotChangeSaysSoAndPausesNothing() async throws {
        let (camera, host) = try await started()
        defer { camera.stop(); ONVIFLoginGuard.shared.clear(host: host) }
        camera.refusedWrites.set(["SetNTP": .notAuthorizedFault, "SetSystemDateAndTime": .notAuthorizedFault])
        let service = CameraSettingsService(endpoint: camera.endpoint,
                                            credentials: HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password),
                                            vendor: .onvif)
        #expect(try await service.readTimeSource(server: "192.0.2.28").0.state == .willChange)
        let refused = try await service.applyTimeSource(server: "192.0.2.28")
        #expect(refused == CameraSetupOutcome(succeeded: false, detail: CameraAdapterError.notPermittedReason, notPermitted: true))
        #expect(refused.notPermitted, "typed, so the setup goes on with the steps after it")
        #expect(ONVIFLoginGuard.shared.pause(host: host) == nil)
        #expect(try await service.applyTimeZone(posix: "MST7") == .notPermittedRefusal)
        #expect(try await service.applyDNS(server: "192.0.2.28").succeeded, "the DNS step still signs in and writes")
        #expect(ONVIFLoginGuard.shared.pause(host: host) == nil)
    }

    /// Clean picture on such a camera: every way to take its labels off (`DeleteOSD`, then blanking with `SetOSD`) refused to the account
    /// is said in the account's words and marked, so the setup goes on after it; nothing is paused.
    @Test func cleanPictureTheAccountMayNotMakeIsMarked() async throws {
        let (camera, host) = try await started()
        defer { camera.stop(); ONVIFLoginGuard.shared.clear(host: host) }
        camera.refusedWrites.set(["DeleteOSD": .notAuthorizedFault, "SetOSD": .notAuthorizedFault])
        let service = CameraSettingsService(endpoint: camera.endpoint,
                                            credentials: HTTPCredentials(username: MockONVIFCamera.username, password: MockONVIFCamera.password),
                                            vendor: .onvif)
        #expect(try await service.readCleanPicture().state == .willChange)
        let change = try await service.cleanPicture()
        #expect(!change.succeeded && change.notPermitted)
        #expect(change.summary == CameraAdapterError.notPermittedReason)
        #expect(ONVIFLoginGuard.shared.pause(host: host) == nil)

        camera.refusedWrites.set([:])
        camera.osdMode.set(.refuseAll)
        let other = try await service.cleanPicture()
        #expect(!other.succeeded && !other.notPermitted, "the camera's own refusal is not one: \(other.summary)")
    }
}
#endif
