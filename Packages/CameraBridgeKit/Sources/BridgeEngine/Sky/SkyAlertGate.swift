import Foundation

/// What the alert gate decides of an entry: raise an alert, count it as part of the alert already raised (`join`, by that alert's entry), or
/// nothing (`none`, and why: "not a candidate", "learning", "sky not visible").
enum SkyAlertDecision: Equatable, Sendable {
    case alert
    case join(entryID: String)
    case none(String)
}

/// The alert gate of one camera (the plan's Task 11; Task 12 raises the alerts it lets through: the toast, the Notifications page and the
/// Home sensor). Nothing here notifies anyone.
///
/// **Pinned:** an entry alerts only when it is a candidate (unexplained and unusual), the camera has learned its sky (`SkyLearning.ready`), the
/// sky was not known to be hidden (`skyVisible` is not false: cloudy or not-visible hours never alert), and no alert was raised for this camera
/// in the last `window` (300 s). Within the window it joins the alert raised; one gate per camera, so another camera's alerts are its own.
struct SkyAlertGate: Codable, Sendable, Equatable {
    static let window: TimeInterval = 300

    /// The last alert: when, and its entry.
    private(set) var lastAlert: Date?
    private(set) var lastEntryID: String?

    init() {}

    mutating func consider(_ entry: SkyEntry, at date: Date, learning: SkyLearning, skyVisible: Bool?) -> SkyAlertDecision {
        guard entry.candidate else { return .none("not a candidate") }
        guard learning.ready else { return .none("learning") }
        guard skyVisible != false else { return .none("sky not visible") }
        if let last = lastAlert, let id = lastEntryID, date >= last, date.timeIntervalSince(last) <= Self.window {
            return .join(entryID: id)
        }
        lastAlert = date
        lastEntryID = entry.id
        return .alert
    }
}
