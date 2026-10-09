import Foundation
import ServiceManagement

enum LoginItemStatus: Equatable {
    case enabled
    case disabled
    /// Registered, but the person must allow it in System Settings › General › Login Items.
    case requiresApproval
    /// The system can't find the app (e.g. run from a disk image or a build folder).
    case unavailable
}

/// Launch at Login. Always read the live status: people can change it in System Settings.
protocol LoginItemService: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// `SMAppService.mainApp` (opt-in, off by default — App Review 2.4.5(iii)).
final class MainAppLoginItemService: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        case .notRegistered: .disabled
        @unknown default: .disabled
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Preview mode and tests: never touches the system's login items.
final class InMemoryLoginItemService: LoginItemService {
    var status: LoginItemStatus = .disabled
    /// Status after a successful `register()`.
    var statusAfterRegister: LoginItemStatus = .enabled
    var registerError: (any Error)?
    private(set) var openedSystemSettings = 0

    func register() throws {
        if let registerError { throw registerError }
        status = statusAfterRegister
    }

    func unregister() throws {
        status = .disabled
    }

    func openSystemSettings() {
        openedSystemSettings += 1
    }
}
