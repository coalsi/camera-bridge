import CameraAdapters
import Foundation

/// One check `optimizeForHomeKit` tried to fix automatically and couldn't.
public struct HomeKitOptimizationFailure: Sendable, Equatable {
    public var checkID: String
    /// Every method's reason when the camera's encoder couldn't be changed ("ONVIF minimal: InvalidArgVal; ISAPI: unsupported").
    public var reason: String
    /// The methods that were tried, with why each failed (empty for failures that aren't encoder changes).
    public var attempts: [CameraConfigAttempt]

    public init(checkID: String, reason: String, attempts: [CameraConfigAttempt] = []) {
        self.checkID = checkID
        self.reason = reason
        self.attempts = attempts
    }
}

/// `BridgeEngine.optimizeForHomeKit(cameraID:)`'s before/after report.
public struct HomeKitOptimizationResult: Sendable, Equatable {
    public var before: HomeKitReadinessReport
    public var after: HomeKitReadinessReport
    /// Check IDs (`HomeKitReadinessCheck.id`) the optimizer successfully changed on the camera.
    public var appliedFixes: [String]
    public var failedFixes: [HomeKitOptimizationFailure]
    /// Which method changed each applied fix (check ID → method). A fix missing here was already in place, or isn't an
    /// encoder change with a method choice.
    public var fixMethods: [String: CameraConfigMethod]
    /// Whether `BridgeEngine.undoHomeKitOptimization(cameraID:)` can restore what this call changed (false once
    /// nothing was changed, or after an undo already consumed the snapshot).
    public var canUndo: Bool
    /// Set when the resolution or codec changed: HomeKit Secure Video recording may need to be re-enabled for this
    /// camera in the Home app.
    public var mayNeedRecordingReEnabled: Bool

    public init(before: HomeKitReadinessReport, after: HomeKitReadinessReport, appliedFixes: [String] = [],
                failedFixes: [HomeKitOptimizationFailure] = [], fixMethods: [String: CameraConfigMethod] = [:], canUndo: Bool,
                mayNeedRecordingReEnabled: Bool = false) {
        self.before = before
        self.after = after
        self.appliedFixes = appliedFixes
        self.failedFixes = failedFixes
        self.fixMethods = fixMethods
        self.canUndo = canUndo
        self.mayNeedRecordingReEnabled = mayNeedRecordingReEnabled
    }
}

/// One stream's encoder change `optimizeForHomeKit` decided on.
struct PlannedEncoderFix: Sendable {
    var isSub: Bool
    /// The stream's settings before the change (what undo restores).
    var before: CameraVideoEncoderSettings
    var options: [CameraVideoEncoderOptions]
    /// The readiness checks this change fixes ("codec", "keyframeInterval", …; "subStream" for the sub stream).
    var fixes: [String]
    var edit: CameraEncoderEdit
}

/// What `optimizeForHomeKit` changed, kept so `undoHomeKitOptimization` can put it back.
struct HomeKitOptimizationSnapshot: Sendable {
    /// The encoder settings before the change (from ONVIF, or from ISAPI for a Hikvision camera ONVIF can't read).
    var mainEncoder: CameraVideoEncoderSettings?
    var subEncoder: CameraVideoEncoderSettings?
    /// Options the camera reported for each stream (clamp on restore).
    var mainOptions: [CameraVideoEncoderOptions] = []
    var subOptions: [CameraVideoEncoderOptions] = []
    var hikvisionMainSmartCodec: Bool?
    var hikvisionSubSmartCodec: Bool?

    var isEmpty: Bool {
        mainEncoder == nil && subEncoder == nil && hikvisionMainSmartCodec == nil && hikvisionSubSmartCodec == nil
    }
}
