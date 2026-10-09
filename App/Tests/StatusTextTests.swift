import BridgeEngine
import CameraAdapters
import Foundation
import MediaCore
import Testing

@Suite struct StatusTextTests {
    private func camera(_ connection: ConnectionState, paired: Bool = true, recording: Bool = false, motion: Bool = false,
                        viewers: Int = 0) -> CameraStatus {
        CameraStatus(id: UUID(), name: "Driveway", kind: .camera, vendor: .hikvision, connection: connection, isPaired: paired,
                     motionActive: motion, recordingNow: recording, liveViewers: viewers)
    }

    @Test func menuLinesAreTextOnlyStatus() {
        #expect(StatusText.menuLine(for: camera(.online, recording: true, motion: true)) == "● Driveway — Live · Recording")
        #expect(StatusText.menuLine(for: camera(.online, motion: true)) == "● Driveway — Live · Motion")
        #expect(StatusText.menuLine(for: camera(.online)) == "● Driveway — Live")
        #expect(StatusText.menuLine(for: camera(.online, viewers: 2)) == "● Driveway — Live · 2 Viewers")
        #expect(StatusText.menuLine(for: camera(.online, paired: false)) == "● Driveway — Live · Not Paired")
        #expect(StatusText.menuLine(for: camera(.offline("timed out"))) == "○ Driveway — Offline — retrying")
        #expect(StatusText.menuLine(for: camera(.connecting)) == "○ Driveway — Connecting…")
        #expect(StatusText.menuLine(for: camera(.disabled)) == "○ Driveway — Disabled")
        #expect(StatusText.menuLine(for: camera(.idle)) == "○ Driveway — Idle")
    }

    @Test func menuLinesCanShowTheCameraAddress() {
        #expect(StatusText.menuLine(for: camera(.online), address: "192.0.2.21") == "● Driveway · 192.0.2.21 — Live")
        #expect(StatusText.accessibleMenuLine(for: camera(.online), address: "192.0.2.21") == "Driveway, 192.0.2.21, Live")
    }

    @Test func addressesShowThePortOnlyWhenItIsNotTheDefault() {
        #expect(CameraAddress.display(CameraEndpoint(host: "192.0.2.21")) == "192.0.2.21")
        #expect(CameraAddress.display(CameraEndpoint(host: "192.0.2.21", httpPort: 8080)) == "192.0.2.21:8080")
        #expect(CameraAddress.display(CameraEndpoint(host: "cam.local", httpPort: 443, useHTTPS: true)) == "cam.local")
        #expect(CameraAddress.display(CameraEndpoint(host: "cam.local", httpPort: 80, useHTTPS: true)) == "cam.local:80")
    }

    @Test func accessibleMenuLineOmitsTheGlyph() {
        #expect(StatusText.accessibleMenuLine(for: camera(.online, recording: true)) == "Driveway, Live · Recording")
    }

    @Test func connectionDetail() {
        #expect(StatusText.connection(.online) == "Live")
        #expect(StatusText.connection(.offline("Connection timed out")) == "Offline — Connection timed out")
        #expect(StatusText.connection(.offline("")) == "Offline")
        #expect(StatusText.health(.online) == .good)
        #expect(StatusText.health(.connecting) == .warning)
        #expect(StatusText.health(.offline("x")) == .error)
        #expect(StatusText.health(.disabled) == .inactive)
        #expect(StatusText.health(.idle) == .inactive)
    }

    @Test func engineStateAndPauseResumeTitles() {
        #expect(StatusText.engineState(.running) == "Running")
        #expect(StatusText.engineState(.failed("Port in use")) == "Error — Port in use")
        #expect(StatusText.menuHeader(.paused) == "Camera Bridge — Paused")
        #expect(StatusText.pauseResumeTitle(.running) == "Pause Bridge")
        #expect(StatusText.pauseResumeTitle(.starting) == "Pause Bridge")
        #expect(StatusText.pauseResumeTitle(.paused) == "Resume Bridge")
        #expect(StatusText.pauseResumeTitle(.stopped) == "Start Bridge")
        #expect(StatusText.pauseResumeTitle(.failed("x")) == "Start Bridge")
    }

    /// The status item's symbol and its VoiceOver label come from the same inputs: a Local Network denial shows the
    /// warning triangle and is also what VoiceOver says.
    @Test func menuBarSymbolAndLabelAgree() {
        func symbol(_ state: EngineState, _ access: LocalNetworkAccess) -> String {
            StatusText.menuBarSymbol(state: state, issue: BridgeIssue.current(state: state, localNetworkAccess: access))
        }
        func label(_ state: EngineState, _ access: LocalNetworkAccess) -> String {
            StatusText.menuBarAccessibilityLabel(state: state, issue: BridgeIssue.current(state: state, localNetworkAccess: access))
        }
        #expect(symbol(.running, .granted) == "video")
        #expect(label(.running, .granted) == "Camera Bridge, Running")
        #expect(symbol(.paused, .unknown) == "video.slash")
        #expect(label(.paused, .unknown) == "Camera Bridge, Paused")
        #expect(symbol(.running, .denied) == "exclamationmark.triangle")
        #expect(label(.running, .denied) == "Camera Bridge, Local Network Access Denied")
        #expect(symbol(.failed("Port in use"), .granted) == "exclamationmark.triangle")
        #expect(label(.failed("Port in use"), .denied) == "Camera Bridge, Error — Port in use")
    }

    /// Review finding (W4 round 4): a damaged configuration set aside (every camera gone from the Home app) showed only
    /// in the manager's banner: the status item stayed "video", VoiceOver said "CameraBridge, Running" and the menu
    /// offered only Add Camera…. A webhook that isn't listening didn't show anywhere but Settings. Every bridge issue
    /// shows in the menu bar: the warning symbol, the VoiceOver label and an item under the header that opens it.
    @Test func everyBridgeIssueShowsInTheMenuBar() throws {
        let backup = URL(fileURLWithPath: "/tmp/CameraBridge/config.corrupt-20261001T101058Z.json")
        let recovered = try #require(BridgeIssue.current(state: .running, localNetworkAccess: .granted, configurationBackup: backup))
        #expect(recovered == .configurationRecovered(backup))
        #expect(StatusText.menuBarSymbol(state: .running, issue: recovered) == "exclamationmark.triangle")
        #expect(StatusText.menuBarAccessibilityLabel(state: .running, issue: recovered) == "Camera Bridge, Your Cameras Couldn’t Be Loaded")
        #expect(recovered.menuItemTitle == "Your Cameras Couldn’t Be Loaded — Show…")

        let problem = "The webhook cannot listen on port 21090 (another app uses the port)."
        let webhook = try #require(BridgeIssue.current(state: .running, localNetworkAccess: .granted, webhookProblem: problem))
        #expect(webhook == .webhookNotListening(problem))
        #expect(StatusText.menuBarSymbol(state: .running, issue: webhook) == "exclamationmark.triangle")
        #expect(StatusText.menuBarAccessibilityLabel(state: .running, issue: webhook) == "Camera Bridge, The Webhook Isn’t Listening")
        #expect(webhook.menuItemTitle == "The Webhook Isn’t Listening — Show…" && webhook.actionTitle == "Try Again")
        #expect(webhook.detail.hasPrefix(problem) && webhook.detail.contains("lost until it listens"))

        #expect(BridgeIssue.localNetworkDenied.menuItemTitle == "Local Network Access Denied — Fix…")
        #expect(BridgeIssue.startFailed("x").menuItemTitle == nil, "the header says Error, next to Start Bridge")
        #expect(BridgeIssue.current(state: .running, localNetworkAccess: .denied, webhookProblem: problem) == .localNetworkDenied,
                "Local Network first: nothing reaches the webhook either")
    }

    /// Review finding (W4 round 4): Trigger Motion sends a real motion event (an HKSV clip, notifications) and sat on
    /// every camera page unexplained. It says what it does, and why it is off while the accessory isn't published.
    @Test func triggerMotionSaysWhatItDoes() {
        #expect(StatusText.testMotionExplanation.contains("records a clip") && StatusText.testMotionExplanation.contains("notified"))
        #expect(StatusText.testMotionUnavailable(.bridgePaused) == "The bridge is paused, so a motion event can’t reach the Home app.")
        #expect(StatusText.testMotionUnavailable(.cameraDisabled) == "This camera is turned off, so a motion event can’t reach the Home app.")
    }

    /// The QR code is offered only while the accessory is published: a paused or stopped bridge, a disabled camera or an
    /// accessory that didn't start say why instead (and how to fix it), like the Sensors Bridge page.
    @Test func pairingIsBlockedWhileTheAccessoryIsntPublished() {
        #expect(PairingBlocker.current(state: .running, isEnabled: true, hapPort: 21_100) == nil)
        #expect(PairingBlocker.current(state: .paused, isEnabled: true, hapPort: nil) == .bridgePaused)
        #expect(PairingBlocker.current(state: .stopped, isEnabled: true, hapPort: nil) == .bridgeNotRunning)
        #expect(PairingBlocker.current(state: .failed("x"), isEnabled: true, hapPort: nil) == .bridgeNotRunning)
        #expect(PairingBlocker.current(state: .starting, isEnabled: true, hapPort: nil) == .bridgeStarting)
        #expect(PairingBlocker.current(state: .running, isEnabled: false, hapPort: nil) == .cameraDisabled)
        #expect(PairingBlocker.current(state: .paused, isEnabled: false, hapPort: nil) == .cameraDisabled, "the camera's own switch first")
        #expect(PairingBlocker.current(state: .running, isEnabled: true, hapPort: nil) == .accessoryNotRunning)
        #expect(PairingBlocker.bridgePaused.message == "The bridge is paused, so the Home app can’t find this accessory. Resume the bridge to add it.")
        #expect(PairingBlocker.bridgePaused.action == .resumeBridge && PairingBlocker.bridgePaused.action?.title == "Resume Bridge")
        #expect(PairingBlocker.bridgeNotRunning.action == .startBridge && PairingBlocker.bridgeNotRunning.action?.title == "Start Bridge")
        #expect(PairingBlocker.cameraDisabled.message == "This camera is turned off, so the Home app can’t find it. Turn it on to add it.")
        #expect(PairingBlocker.cameraDisabled.action == nil && PairingBlocker.bridgeStarting.action == nil)
    }

    /// Detection sensors come from the camera, or from the webhook when it is the camera's motion source (Frigate, Home
    /// Assistant), matching what the engine publishes.
    @Test func sensorKindsFollowTheCameraOrTheWebhook() {
        let rtsp = CameraCapabilities()
        #expect(SensorKind.available(in: rtsp, motionSource: .softMotion).isEmpty)
        #expect(SensorKind.available(in: rtsp, motionSource: .webhook) == [.person, .vehicle, .animal, .package])
        let hikvision = CameraCapabilities(events: [.motion, .person, .dayNight])
        #expect(SensorKind.available(in: hikvision, motionSource: .cameraEvents) == [.person, .dayNight])
        #expect(SensorKind.available(in: hikvision, motionSource: .webhook) == [.person, .vehicle, .animal, .package, .dayNight])
        #expect(SensorKind.available(in: nil, motionSource: .webhook) == [.person, .vehicle, .animal, .package])
        #expect(SensorKind.vehicle.isFromWebhook(in: hikvision, motionSource: .webhook))
        #expect(!SensorKind.person.isFromWebhook(in: hikvision, motionSource: .webhook))
        var options = SensorOptions()
        options.vehicle = true
        options.dayNight = true
        #expect(SensorKind.filtered(options, by: rtsp, motionSource: .webhook).vehicle)
        #expect(!SensorKind.filtered(options, by: rtsp, motionSource: .webhook).dayNight)
        #expect(!SensorKind.filtered(options, by: rtsp, motionSource: .cameraEvents).vehicle)
    }

    /// Review finding (W4 round 2): detection sensors turned on under Webhook stayed on (hidden, unpublished) after the
    /// motion source changed, and the Sensors Bridge page still listed them. Review finding (W4 round 4): the page then
    /// worked the list out from the options with a copy of the engine's rule, which already differed (Alarm Inputs listed
    /// for a camera that had reported no input, which publishes none). The page lists the engine's own list
    /// (`SensorsBridgeStatus.publishedSensors`); the camera page offers a toggle for every sensor that may be published.
    @Test func theSensorsBridgePageListsWhatTheEnginePublishes() {
        var camera = CameraConfiguration(name: "Gate", kind: .camera, vendor: .hikvision, endpoint: CameraEndpoint(host: "192.0.2.24"), username: "admin")
        camera.capabilities = CameraCapabilities(events: [.motion, .person, .digitalInput])
        camera.sensors.person = true
        camera.sensors.digitalInputs = true
        let other = CameraConfiguration(name: "Yard", kind: .camera, vendor: .rtsp, endpoint: CameraEndpoint(host: "192.0.2.25"), username: "")
        // No alarm input reported yet: the engine publishes the person sensor only.
        #expect(SensorKind.cameraRows([camera, other], published: [camera.id: [.occupancy(.person)]])
                == [SensorKind.CameraRow(id: camera.id, name: "Gate", sensors: ["Person Detection"])])
        #expect(SensorKind.cameraRows([camera], published: [:]).isEmpty, "nothing published, nothing listed (whatever the options)")
        #expect(SensorKind.names(of: [.occupancy(.person), .contact(input: "1"), .contact(input: "2"), .light])
                == ["Person Detection", "2 Alarm Inputs", "Day and Night"])
        #expect(SensorKind.names(of: [.contact(input: "1")]) == ["1 Alarm Input"])

        camera.capabilities = nil   // unknown: the engine trusts the options, so each of them has its toggle
        #expect(SensorKind.shown(in: nil, motionSource: .softMotion, options: camera.sensors) == [.person, .digitalInputs])
        #expect(SensorKind.shown(in: nil, motionSource: .webhook, options: SensorOptions()) == [.person, .vehicle, .animal, .package])
        #expect(SensorKind.shown(in: CameraCapabilities(), motionSource: .softMotion, options: camera.sensors).isEmpty,
                "known capabilities: only what the camera offers")
    }

    /// Changing the motion source turns off the sensors only the old one offered (the webhook's detections); sensors
    /// the camera reports itself keep their setting.
    @Test func changingTheMotionSourceDropsTheSensorsItHides() {
        let hikvision = CameraCapabilities(events: [.motion, .person, .dayNight])
        var options = SensorOptions()
        options.person = true
        options.vehicle = true
        options.dayNight = true
        let adjusted = SensorKind.adjusted(options, capabilities: hikvision, from: .webhook, to: .cameraEvents)
        #expect(adjusted.person && adjusted.dayNight && !adjusted.vehicle)
        #expect(SensorKind.adjusted(options, capabilities: hikvision, from: .cameraEvents, to: .webhook) == options)
        #expect(!SensorKind.adjusted(options, capabilities: CameraCapabilities(), from: .webhook, to: .softMotion).person)
        // Unknown capabilities: the engine publishes whatever is on, so the toggles stay and so do the settings.
        #expect(SensorKind.adjusted(options, capabilities: nil, from: .webhook, to: .softMotion) == options)
    }

    /// Review finding (W4 round 2): plain RTSP cameras have no event channel, and the camera page always said
    /// "Camera Events: Not connected" next to a healthy stream.
    @Test func camerasWithoutAnEventChannelDontLookFaulty() {
        let rtsp = CameraStatus(id: UUID(), name: "Side Yard", kind: .camera, vendor: .rtsp, connection: .online)
        #expect(StatusText.cameraEvents(rtsp) == "None — RTSP cameras send no events")
        var hikvision = camera(.online)
        #expect(StatusText.cameraEvents(hikvision) == "Not connected")
        hikvision.eventChannelConnected = true
        #expect(StatusText.cameraEvents(hikvision) == "Connected")
    }

    @Test func setupCodesDisplayAsXXXdashXXdashXXX() {
        #expect(StatusText.setupCode("48217935") == "482-17-935")
        #expect(StatusText.setupCode("482-17-935") == "482-17-935")
        #expect(StatusText.setupCode(" 482 17 935 ") == "482-17-935")
        #expect(StatusText.setupCode("") == "")
        #expect(StatusText.setupCode("12345") == "12345")
    }

    @Test func namesForKindsVendorsAndSources() {
        #expect(StatusText.kind(.doorbell) == "Video Doorbell")
        #expect(StatusText.vendor(.onvif) == "ONVIF")
        #expect(StatusText.vendor(.demo) == "Demo")
        #expect(StatusText.motionSource(.softMotion) == "Built-in Motion Detection")
        #expect(StatusText.motionSource(.cameraEvents) == "Camera Events")
        #expect(StatusText.motionSource(.webhook) == "Webhook")
    }

    @Test func streamSummary() {
        let info = StreamInfo(url: URL(string: "rtsp://192.0.2.1/s")!, videoCodec: .h264, width: 1920, height: 1080, fps: 20,
                              audioCodec: .aac, audioSampleRate: 16_000, audioChannels: 1)
        #expect(StatusText.stream(info) == "H.264 1920×1080 · 20 fps · AAC 16 kHz")
        let bare = StreamInfo(url: URL(string: "rtsp://192.0.2.1/s")!)
        #expect(StatusText.stream(bare) == "Unknown format")
        let hevc = StreamInfo(url: URL(string: "rtsp://192.0.2.1/s")!, videoCodec: .hevc, width: 3840, height: 2160, fps: 12.5)
        #expect(StatusText.stream(hevc) == "HEVC 3840×2160 · 12.5 fps")
    }

    @Test func audioSummaryNamesWhatIsOn() {
        #expect(StatusText.audioSummary(cameraAudio: true, twoWayAudio: true) == "Camera audio and two-way audio")
        #expect(StatusText.audioSummary(cameraAudio: true, twoWayAudio: false) == "Camera audio")
        #expect(StatusText.audioSummary(cameraAudio: false, twoWayAudio: true) == "Two-way audio only")
        #expect(StatusText.audioSummary(cameraAudio: false, twoWayAudio: false) == "Off")
    }
}

/// Review finding (W4 App): the camera page's "Last Event · 2 min. ago" was formatted once, against the time it was
/// drawn, and froze on a quiet camera (nothing else redraws the row). The text is computed for the time the page's
/// timeline gives, so it moves on by itself.
@Suite struct RelativeTimeTests {
    @Test func lastEventFollowsTheGivenTime() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(StatusText.lastEvent("Motion", at: date, now: date + 5) == "Motion · 5 sec. ago")
        #expect(StatusText.lastEvent("Motion", at: date, now: date + 300) == "Motion · 5 min. ago")
        #expect(StatusText.lastEvent("Doorbell", at: nil, now: date) == "Doorbell")
        #expect(StatusText.lastEvent(nil, at: date, now: date) == nil)
    }

    @Test func recentEventsFollowTheGivenTime() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(StatusText.timeAgo(date, now: date + 7_200) == "2 hours ago")
        #expect(StatusText.timeAgo(date, now: date + 60) == "1 minute ago")
    }
}
