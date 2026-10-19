import CameraAdapters
import Foundation
import Observation

/// The HomeKit readiness report for one camera page, loaded once and shared by the hero's Optimize button, the score
/// tile and the Overview tab's checklist. Reloaded whenever the optimize sheet closes (its optimization or undo may
/// have changed the camera's settings).
@MainActor
@Observable
final class ReadinessState {
    var report: HomeKitReadinessReport?
    var isLoading = true
    var loadError: String?
    var showingOptimizeSheet = false

    /// Whether any check can be fixed automatically.
    var canOptimize: Bool {
        report?.checks.contains { if case .automatic = $0.fixMethod { true } else { false } } ?? false
    }

    /// Whether any failing check has manual steps to show.
    var hasManualFixes: Bool {
        report?.checks.contains { if case .manual = $0.fixMethod { $0.status != .ok } else { false } } ?? false
    }

    /// The button has something to show: automatic fixes, or manual steps.
    var canAct: Bool { report != nil && (canOptimize || hasManualFixes) }

    /// `recheck`: the person asked to check again (Check Again, or the optimize sheet closed), so a camera whose ONVIF
    /// service refused the credentials is asked again; opening the page does not (the engine remembers the refusal for
    /// 10 minutes: every ask is another failed login).
    func load(model: AppModel, cameraID: UUID, recheck: Bool = false) async {
        isLoading = true
        loadError = nil
        do {
            report = try await model.homeKitReadiness(cameraID: cameraID, recheck: recheck)
        } catch {
            loadError = ErrorText.describe(error)
        }
        isLoading = false
    }
}
