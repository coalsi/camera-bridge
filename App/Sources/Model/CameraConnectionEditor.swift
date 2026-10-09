import BridgeEngine
import BridgeSupport
import CameraAdapters
import Foundation
import MediaCore
import Observation

/// The camera detail's Connection sheet: the camera's address, ports, HTTPS and stream URLs, changed in place. Save
/// checks the camera there first (with its stored password), then saves it as the same camera, so its Home accessory,
/// pairing, recordings and automations stay (before, the only fix for a new address was removing the camera and adding
/// it again as a new accessory).
///
/// Plain RTSP cameras are reached through their stream URLs (the address and RTSP port come from the main URL); other
/// cameras through the address and ports, with the stream URLs as optional overrides. Stream URLs that still point at
/// the old address and RTSP port follow the new ones. URLs are saved without user info (`Change Password…` holds the
/// sign-in).
@MainActor @Observable
final class CameraConnectionEditor {
    typealias Probe = @MainActor (_ candidate: CameraConfiguration) async throws -> CameraProbeResult
    /// Saves the checked connection; throws why it wasn't saved (shown in the sheet).
    typealias Save = @MainActor (_ endpoint: CameraEndpoint, _ mainStreamURL: URL?, _ subStreamURL: URL?) async throws -> Void

    enum State: Equatable {
        case editing, checking
        case failed(String)
    }

    let original: CameraConfiguration

    var host: String { didSet { edited() } }
    var httpPort: Int { didSet { edited() } }
    var rtspPort: Int { didSet { edited() } }
    /// nil: the HTTP port.
    var onvifPort: Int? { didSet { edited() } }
    /// Moves a default port with it (80 ↔ 443), like the wizard.
    var useHTTPS: Bool {
        didSet {
            guard useHTTPS != oldValue else { return }
            httpPort = AddCameraWizardModel.httpPort(httpPort, afterSwitchingHTTPS: useHTTPS)
            edited()
        }
    }
    var mainStreamURLText: String { didSet { edited() } }
    var subStreamURLText: String { didSet { edited() } }

    private(set) var state: State = .editing
    /// Set by `cancel()` (Cancel, Escape, the sheet going away): a check under way saves nothing and nothing new starts.
    private(set) var isClosed = false

    @ObservationIgnored private let probe: Probe
    @ObservationIgnored private let save: Save
    /// Check and Save in progress (`startSave()`), cancelled by `cancel()`.
    @ObservationIgnored private var saving: Task<Bool, Never>?

    init(configuration: CameraConfiguration, probe: @escaping Probe, save: @escaping Save) {
        original = configuration
        host = configuration.endpoint.host
        httpPort = configuration.endpoint.httpPort
        rtspPort = configuration.endpoint.rtspPort
        onvifPort = configuration.endpoint.onvifPort
        useHTTPS = configuration.endpoint.useHTTPS
        mainStreamURLText = configuration.mainStreamURL?.absoluteString ?? ""
        subStreamURLText = configuration.subStreamURL?.absoluteString ?? ""
        self.probe = probe
        self.save = save
    }

    /// The HTTP port field's label: which protocol the port is for.
    var httpPortTitle: String { AddCameraWizardModel.httpPortTitle(useHTTPS: useHTTPS) }

    /// Plain RTSP cameras have no address of their own: it comes from the main stream URL.
    var showsAddressFields: Bool { original.vendor != .rtsp }
    var showsONVIFPort: Bool { original.vendor == .onvif }

    /// Why Save can't run, or nil.
    var problem: String? {
        let sub = subStreamURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sub.isEmpty, AddCameraWizardModel.streamURL(sub) == nil {
            return AddCameraWizardModel.isRTSPOverTLS(sub) ? AddCameraWizardModel.rtspOverTLSUnsupported
                : String(localized: "The sub stream URL must start with rtsp://.")
        }
        let main = mainStreamURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        if original.vendor == .rtsp {
            guard AddCameraWizardModel.streamURL(main) != nil else {
                return AddCameraWizardModel.isRTSPOverTLS(main) ? AddCameraWizardModel.rtspOverTLSUnsupported
                    : String(localized: "Enter the main stream URL, starting with rtsp://.")
            }
            return nil
        }
        if HostInput(host) == nil { return String(localized: "Enter the camera’s address.") }
        if !(1...65_535).contains(httpPort) || !(1...65_535).contains(rtspPort) || onvifPort.map({ !(1...65_535).contains($0) }) == true {
            return String(localized: "Ports must be between 1 and 65535.")
        }
        if !main.isEmpty, AddCameraWizardModel.streamURL(main) == nil {
            return AddCameraWizardModel.isRTSPOverTLS(main) ? AddCameraWizardModel.rtspOverTLSUnsupported
                : String(localized: "The main stream URL must start with rtsp://.")
        }
        return nil
    }

    /// For the camera page: a camera saved with an `rtsps://` stream URL (before such URLs were refused) can't stream;
    /// this says why and how to fix it. Nil otherwise.
    static func unsupportedStreamNotice(for configuration: CameraConfiguration) -> String? {
        let urls = [configuration.mainStreamURL, configuration.subStreamURL].compactMap { $0 }
        guard urls.contains(where: { $0.scheme?.lowercased() == "rtsps" }) else { return nil }
        return String(localized: "This camera’s stream URL uses RTSP over TLS (rtsps://), which Camera Bridge can’t use yet, so it can’t stream. Use Change Address… to enter its plain rtsp:// URL.")
    }

    var hasChanges: Bool {
        guard let candidate else { return true }
        return candidate.endpoint != original.endpoint || candidate.mainStreamURL != original.mainStreamURL
            || candidate.subStreamURL != original.subStreamURL
    }

    var canSave: Bool { problem == nil && hasChanges && state != .checking && !isClosed }

    /// The fields stay as they are while the camera is checked: the check saves what was entered when it started.
    var canEdit: Bool { state != .checking }

    /// The camera as it would be saved (before the check fills in what the camera reports), or nil while an entry is
    /// unusable.
    var candidate: CameraConfiguration? {
        guard problem == nil else { return nil }
        var camera = original
        var main = AddCameraWizardModel.streamURL(mainStreamURLText)?.removingUserInfo
        var sub = AddCameraWizardModel.streamURL(subStreamURLText)?.removingUserInfo
        if original.vendor == .rtsp {
            guard let url = main, let urlHost = url.host(percentEncoded: false) else { return nil }
            camera.endpoint.host = urlHost
            camera.endpoint.rtspPort = url.port ?? AddCameraWizardModel.defaultRTSPPort(scheme: url.scheme)
        } else {
            guard let input = HostInput(host) else { return nil }
            camera.endpoint = CameraEndpoint(host: input.host, httpPort: httpPort, rtspPort: rtspPort,
                                             onvifPort: original.vendor == .onvif ? onvifPort : original.endpoint.onvifPort, useHTTPS: useHTTPS)
            main = main.map { follow($0, to: camera.endpoint) }
            sub = sub.map { follow($0, to: camera.endpoint) }
        }
        camera.mainStreamURL = main
        camera.subStreamURL = sub
        return camera
    }

    /// Check and Save: `save()` in a task the editor keeps, so `cancel()` stops it. The sheet closes when it returns true.
    @discardableResult
    func startSave() -> Task<Bool, Never> {
        let task = Task { await save() }
        saving = task
        return task
    }

    /// The sheet is going away (Cancel, Escape, closed): stops a check under way, and nothing is saved afterwards — the
    /// person may have noticed a wrong address (another camera's, which the stored password may also open). A save the
    /// engine already started is left to finish.
    func cancel() {
        isClosed = true
        saving?.cancel()
        saving = nil
        if state == .checking { state = .editing }
    }

    /// Checks the camera with the new connection, then saves it. Returns whether it was saved; a failed check or save
    /// shows why in `state` (the sheet), and a failed or cancelled check saves nothing.
    func save() async -> Bool {
        guard canSave, var camera = candidate else { return false }
        state = .checking
        do {
            let result = try await probe(camera)
            guard !isClosed, !Task.isCancelled else { return false }
            // What the camera reports wins (API cameras name their streams); entered URLs stay otherwise.
            if original.vendor != .rtsp {
                camera.mainStreamURL = (result.mainStream?.url ?? camera.mainStreamURL)?.removingUserInfo
                camera.subStreamURL = (result.subStream?.url ?? camera.subStreamURL)?.removingUserInfo
            }
            if original.vendor == .onvif, camera.endpoint.onvifPort == nil { camera.endpoint.onvifPort = result.onvifPort }
        } catch {
            guard !isClosed, !Task.isCancelled else { return false }
            state = .failed(ErrorText.describe(error))
            return false
        }
        do {
            try await save(camera.endpoint, camera.mainStreamURL, camera.subStreamURL)
        } catch {
            state = .failed(ErrorText.describe(error))
            return false
        }
        state = .editing
        return true
    }

    private func edited() {
        if state != .checking { state = .editing }
    }

    /// `url` with the new host and RTSP port when it still points at the old ones.
    private func follow(_ url: URL, to endpoint: CameraEndpoint) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == original.endpoint.host.lowercased() else { return url }
        components.host = endpoint.host
        let oldPort = components.port ?? AddCameraWizardModel.defaultRTSPPort(scheme: components.scheme)
        if oldPort == original.endpoint.rtspPort, endpoint.rtspPort != original.endpoint.rtspPort { components.port = endpoint.rtspPort }
        return components.url ?? url
    }
}
