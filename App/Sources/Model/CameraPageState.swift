import Foundation

/// The camera page's tabs: the long form split by what you are trying to do.
enum CameraTab: String, CaseIterable, Identifiable {
    case overview, streams, recording, motion, advanced

    var id: String { rawValue }
}

/// Where a tap on the dashboard (a stat tile, the Apple Home card) takes the camera page.
enum CameraPageDestination: Equatable, CaseIterable {
    /// The Apple Home pairing: the QR code and setup code (Overview).
    case pairing
    /// The HomeKit Readiness checklist, open (Overview).
    case readinessChecklist
    case streams
    case recording
    case liveView
    case motion

    /// The tab that holds what the destination shows.
    var tab: CameraTab {
        switch self {
        case .pairing, .readinessChecklist: .overview
        case .streams, .liveView: .streams
        case .recording: .recording
        case .motion: .motion
        }
    }
}

/// A place the camera page can scroll to. (The tab's content: its sections sit in grouped forms, which an enclosing scroll view
/// cannot address one by one, and the dashboard above the tabs can fill the window, so the content a tap selects may start
/// below the fold.)
enum CameraPageAnchor: Hashable {
    case tabContent
}

/// What the camera page shows beyond the dashboard: the selected tab, whether the readiness checklist is open, and the
/// scroll the last navigation asked for. Navigation (`show`) changes all three at once: a tap on "View Checklist" selects
/// the Overview tab, opens the checklist and scrolls the page to the tab's content, wherever the page was.
struct CameraPageState: Equatable {
    /// A scroll the view performs when `serial` changes (the same anchor asked for twice scrolls twice).
    struct ScrollRequest: Equatable {
        var anchor = CameraPageAnchor.tabContent
        var serial: Int
    }

    var tab: CameraTab = .overview
    var isChecklistExpanded = false
    private(set) var scrollRequest: ScrollRequest?
    private var serial = 0

    init(tab: CameraTab = .overview, isChecklistExpanded: Bool = false) {
        self.tab = tab
        self.isChecklistExpanded = isChecklistExpanded
    }

    mutating func show(_ destination: CameraPageDestination) {
        tab = destination.tab
        if destination == .readinessChecklist { isChecklistExpanded = true }
        serial += 1
        scrollRequest = ScrollRequest(serial: serial)
    }
}
