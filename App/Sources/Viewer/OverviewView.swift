import AppKit
import BridgeEngine
import SwiftUI

/// Every camera at a glance: tiles that show the latest snapshot, or the live picture of the camera's sub stream while Play
/// All, or the tile's own play button, says so. The layout is Auto (a responsive grid of two to four columns that scrolls) or
/// a fixed number of columns and rows that fits the window exactly, with the cameras beyond it on further pages
/// (`OverviewLayout`). What is live is decided by `OverviewModel` (the tiles that can be seen, online, at most nine, only while
/// the page and the window can be seen).
struct OverviewView: View {
    let model: AppModel
    @State private var overview: OverviewModel
    @State private var columns = 3
    private let activity = WindowActivity.shared

    init(model: AppModel) {
        self.model = model
        var cap = OverviewModel.maximumLiveTiles
        #if DEBUG
        // `-demoLiveCap 5` (CPU measurements): fewer simultaneous live tiles than the app's cap.
        if let value = UserDefaults.standard.string(forKey: "demoLiveCap").flatMap({ Int($0) }) { cap = value }
        #endif
        _overview = State(initialValue: OverviewModel(defaults: model.preferences, cap: cap, makeSink: { LiveVideoRenderer() }, open: model.liveVideoOpener))
    }

    var body: some View {
        let cameras = model.engine.cameras
        Group {
            if cameras.isEmpty {
                EmptyCamerasHero { model.showAddCamera() }
            } else {
                VStack(spacing: 0) {
                    OverviewHeader(overview: overview)
                    if overview.layout.grid == nil {
                        autoGrid
                    } else {
                        FixedOverviewGrid(model: model, overview: overview)
                    }
                }
                .background {
                    OverviewEventMonitor(isActive: model.presentedSheet == nil && model.expandedCameraID == nil) { event in
                        switch event {
                        case .previousPage: overview.previousPage()
                        case .nextPage: overview.nextPage()
                        case .layout(let digit):
                            if let layout = OverviewLayout.forShortcut(digit) { overview.layout = layout }
                        }
                    } canTurnPages: { overview.layout.grid != nil && overview.pageCount > 1 }
                }
            }
        }
        .navigationTitle("Overview")
        .onAppear {
            overview.isPageVisible = model.expandedCameraID == nil
            overview.update(cameras: cameras)
            #if DEBUG
            // `-demoPlayAll YES|NO` (UI review): Play All without clicking.
            if let value = UserDefaults.standard.string(forKey: "demoPlayAll") { overview.playAll = ["YES", "TRUE", "1"].contains(value.uppercased()) }
            // `-demoOverviewLayout auto|1x1|2x2|3x3|4x4|custom:5x2` and `-demoOverviewPage 1`: the layout and page (UI review).
            if let value = UserDefaults.standard.string(forKey: "demoOverviewLayout") { overview.layout = Self.layout(named: value) }
            if let page = UserDefaults.standard.string(forKey: "demoOverviewPage").flatMap({ Int($0) }) { overview.goToPage(page) }
            if let value = UserDefaults.standard.string(forKey: "demoShowOffline") { overview.showsOfflineCameras = ["YES", "TRUE", "1"].contains(value.uppercased()) }
            #endif
        }
        .onDisappear { overview.stopAll() }
        .onChange(of: cameras) { _, updated in overview.update(cameras: updated) }
        // Nothing plays while the window cannot be seen, or while the single-camera viewer covers the page.
        .onChange(of: activity.isVisible, initial: true) { _, visible in overview.isWindowVisible = visible }
        .onChange(of: model.expandedCameraID) { _, expanded in overview.isPageVisible = expanded == nil }
    }

    private var autoGrid: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: OverviewModel.tileSpacing, alignment: .top), count: columns),
                      spacing: OverviewModel.tileSpacing) {
                ForEach(overview.pageCameras) { camera in
                    OverviewTile(model: model, overview: overview, status: camera)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 6)
            .padding(.bottom, 28)
            .frame(maxWidth: 1_900)
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: Int.self, of: { OverviewModel.columns(forWidth: $0.size.width - 56) }) { columns = $0 }
    }

    #if DEBUG
    private static func layout(named name: String) -> OverviewLayout {
        let numbers = name.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        if name.hasPrefix("custom"), numbers.count == 2 { return OverviewLayout(mode: .custom, customColumns: numbers[0], customRows: numbers[1]) }
        switch name {
        case "1x1": return OverviewLayout(mode: .grid1)
        case "2x2": return OverviewLayout(mode: .grid2)
        case "3x3": return OverviewLayout(mode: .grid3)
        case "4x4": return OverviewLayout(mode: .grid4)
        default: return OverviewLayout()
        }
    }
    #endif
}

// MARK: - Header

/// Title, the camera and live counts, the layout menu and the Play All toggle.
private struct OverviewHeader: View {
    let overview: OverviewModel

    var body: some View {
        let live = overview.liveCount
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Overview")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle(live: live))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 12)
            OverviewLayoutMenu(overview: overview)
            PlayAllButton(isOn: Binding(get: { overview.playAll }, set: { overview.playAll = $0 }))
        }
        .padding(.horizontal, 28)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .frame(maxWidth: 1_900)
        .frame(maxWidth: .infinity)
    }

    private func subtitle(live: Int) -> String {
        let shown = overview.arrangedCameras.count
        var count = shown == 1 ? String(localized: "1 camera") : String(localized: "\(shown) cameras")
        if shown != overview.allCameras.count { count += " " + String(localized: "(\(overview.allCameras.count - shown) hidden)") }
        guard live > 0 else { return overview.playAll ? count : String(localized: "\(count) · showing snapshots") }
        return String(localized: "\(count) · \(live) live")
    }
}

/// The layout control: Auto, 1×1 to 4×4 (⌘1–⌘4), Custom… with columns and rows, and Show Offline Cameras.
struct OverviewLayoutMenu: View {
    let overview: OverviewModel
    @State private var showsCustom = false

    var body: some View {
        Menu {
            layoutItem(.auto, shortcut: nil)
            layoutItem(.grid1, shortcut: "1")
            layoutItem(.grid2, shortcut: "2")
            layoutItem(.grid3, shortcut: "3")
            layoutItem(.grid4, shortcut: "4")
            Toggle(isOn: Binding(get: { overview.layout.mode == .custom }, set: { _ in chooseCustom() })) {
                Text(overview.layout.mode == .custom ? overview.layout.title + "…" : String(localized: "Custom…"))
            }
            Divider()
            Toggle("Show Offline Cameras", isOn: Binding(get: { overview.showsOfflineCameras }, set: { overview.showsOfflineCameras = $0 }))
        } label: {
            Label(overview.layout.title, systemImage: "square.grid.2x2")
                .frame(minWidth: 70)
        }
        .menuStyle(.button)
        .buttonStyle(.brand(.secondary, large: true))
        .menuIndicator(.visible)
        .fixedSize()
        .popover(isPresented: $showsCustom, arrowEdge: .bottom) {
            CustomLayoutPopover(overview: overview)
        }
        .help("Choose how many cameras the grid shows at once")
        .accessibilityLabel(Text("Layout"))
        .accessibilityValue(Text(overview.layout.title))
    }

    private func layoutItem(_ mode: OverviewLayout.Mode, shortcut: KeyEquivalent?) -> some View {
        let isOn = Binding(get: { overview.layout.mode == mode }, set: { _ in overview.layout = OverviewLayout(mode: mode, customColumns: overview.layout.customColumns, customRows: overview.layout.customRows) })
        let title = OverviewLayout(mode: mode).title
        return Group {
            if let shortcut {
                Toggle(title, isOn: isOn).keyboardShortcut(shortcut, modifiers: .command)
            } else {
                Toggle(title, isOn: isOn)
            }
        }
    }

    private func chooseCustom() {
        overview.layout = OverviewLayout(mode: .custom, customColumns: overview.layout.customColumns, customRows: overview.layout.customRows)
        showsCustom = true
    }
}

private struct CustomLayoutPopover: View {
    let overview: OverviewModel

    var body: some View {
        let columns = Binding(get: { overview.layout.customColumns },
                              set: { overview.layout = OverviewLayout(mode: .custom, customColumns: $0, customRows: overview.layout.customRows) })
        let rows = Binding(get: { overview.layout.customRows },
                           set: { overview.layout = OverviewLayout(mode: .custom, customColumns: overview.layout.customColumns, customRows: $0) })
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Layout")
                .font(.headline)
            Stepper(value: columns, in: OverviewLayout.customRange) {
                HStack {
                    Text("Columns")
                    Spacer()
                    Text("\(columns.wrappedValue)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Stepper(value: rows, in: OverviewLayout.customRange) {
                HStack {
                    Text("Rows")
                    Spacer()
                    Text("\(rows.wrappedValue)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            let perPage = columns.wrappedValue * rows.wrappedValue
            Text(perPage == 1 ? String(localized: "One camera per page") : String(localized: "\(perPage) cameras per page"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 240)
    }
}

/// The big Play All / Pause All button: a toggle, amber while it is off (the main action), gray while everything plays.
struct PlayAllButton: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { isOn.toggle() }
        } label: {
            Label(isOn ? "Pause All" : "Play All", systemImage: isOn ? "pause.fill" : "play.fill")
                .frame(minWidth: 108)
        }
        .buttonStyle(.brand(isOn ? .secondary : .primary, large: true))
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .help(isOn ? "Show snapshots instead of live pictures" : "Show every camera live (the sub streams)")
        .accessibilityValue(Text(isOn ? "On" : "Off"))
        .accessibilityAddTraits(.isToggle)
    }
}

// MARK: - Fixed layouts

/// A fixed layout: `columns × rows` tiles that fill the room exactly (no scrolling), the cameras beyond them on further
/// pages with a page bar, arrow keys and swipes to turn them.
private struct FixedOverviewGrid: View {
    let model: AppModel
    let overview: OverviewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let grid = overview.layout.grid ?? (columns: 2, rows: 2)
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let fit = OverviewGridMetrics.fit(available: CGSize(width: max(1, proxy.size.width - 56), height: max(1, proxy.size.height - 6)),
                                                  columns: grid.columns, rows: grid.rows)
                ZStack(alignment: .top) {
                    pageGrid(fit: fit, columns: grid.columns)
                        .id(overview.page)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .move(edge: overview.pageDirection > 0 ? .trailing : .leading),
                            removal: .move(edge: overview.pageDirection > 0 ? .leading : .trailing)))
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .animation(reduceMotion ? nil : .smooth(duration: 0.32), value: overview.page)
            }
            if overview.pageCount > 1 {
                PageBar(overview: overview)
            }
        }
        .padding(.top, 6)
    }

    private func pageGrid(fit: OverviewGridMetrics.Fit, columns: Int) -> some View {
        let tiles = overview.pageCameras
        let rows = stride(from: 0, to: tiles.count, by: columns).map { Array(tiles[$0..<min(tiles.count, $0 + columns)]) }
        return VStack(alignment: .leading, spacing: fit.spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: fit.spacing) {
                    ForEach(row) { camera in
                        OverviewTile(model: model, overview: overview, status: camera, density: fit.density, fixedWidth: fit.tileWidth)
                    }
                }
            }
        }
        .frame(width: fit.tileWidth * CGFloat(columns) + fit.spacing * CGFloat(columns - 1), alignment: .topLeading)
    }
}

/// "Page 2 of 3" with previous and next buttons and a dot per page.
private struct PageBar: View {
    let overview: OverviewModel

    var body: some View {
        HStack(spacing: 14) {
            Button { overview.previousPage() } label: {
                Image(systemName: "chevron.left").frame(width: 28, height: 28).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glass(in: Circle(), interactive: true)
            .disabled(!overview.canGoBack)
            .opacity(overview.canGoBack ? 1 : 0.4)
            .help("Previous Page (←)")
            .accessibilityLabel(Text("Previous Page"))

            VStack(spacing: 5) {
                Text("Page \(overview.page + 1) of \(overview.pageCount)")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                if overview.pageCount <= 12 {
                    HStack(spacing: 7) {
                        ForEach(0..<overview.pageCount, id: \.self) { index in
                            Button { overview.goToPage(index) } label: {
                                Circle()
                                    .fill(index == overview.page ? Brand.amber : Color.white.opacity(0.28))
                                    .frame(width: 7, height: 7)
                                    .frame(width: 12, height: 12)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Page \(index + 1)"))
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityValue(Text("Page \(overview.page + 1) of \(overview.pageCount)"))

            Button { overview.nextPage() } label: {
                Image(systemName: "chevron.right").frame(width: 28, height: 28).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glass(in: Circle(), interactive: true)
            .disabled(!overview.canGoForward)
            .opacity(overview.canGoForward ? 1 : 0.4)
            .help("Next Page (→)")
            .accessibilityLabel(Text("Next Page"))
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Arrow keys and swipes

/// What turns the page.
enum OverviewPageEvent {
    case previousPage, nextPage
    /// ⌘1…⌘4: the 1×1…4×4 layouts.
    case layout(Int)
}

/// Turns pages for the left and right arrow keys and a horizontal trackpad swipe, and picks the layouts for ⌘1–⌘4, while this
/// window is the key window and no text is being edited. Local event monitors, so it works whatever has focus;
/// `canTurnPages` says whether there is a page to turn.
private struct OverviewEventMonitor: NSViewRepresentable {
    let isActive: Bool
    let handle: (OverviewPageEvent) -> Void
    let canTurnPages: () -> Bool

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.isActive = isActive
        view.handle = handle
        view.canTurnPages = canTurnPages
    }

    final class MonitorView: NSView {
        var isActive = true
        var handle: (OverviewPageEvent) -> Void = { _ in }
        var canTurnPages: () -> Bool = { false }
        private var monitor: Any?
        /// Horizontal scroll collected in the swipe under way; a swipe turns one page.
        private var swipe: CGFloat = 0
        private var swipeHandled = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
                self?.route(event) ?? event
            }
        }

        private func route(_ event: NSEvent) -> NSEvent? {
            guard isActive, let window, event.window === window, window.isKeyWindow else { return event }
            switch event.type {
            case .keyDown:
                let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                if modifiers == .command, let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }), (1...4).contains(digit) {
                    handle(.layout(digit))
                    return nil
                }
                guard modifiers.isEmpty, canTurnPages(), !(window.firstResponder is NSText) else { return event }
                switch event.keyCode {
                case 123: handle(.previousPage); return nil   // left arrow
                case 124: handle(.nextPage); return nil       // right arrow
                default: return event
                }
            case .scrollWheel:
                guard canTurnPages() else { return event }
                let location = convert(event.locationInWindow, from: nil)
                guard bounds.contains(location), event.hasPreciseScrollingDeltas else { return event }
                if event.phase == .began || event.phase == .mayBegin { swipe = 0; swipeHandled = false }
                guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
                swipe += event.scrollingDeltaX
                if !swipeHandled, abs(swipe) > 60 {
                    swipeHandled = true
                    // Content follows the fingers: swiping right shows the earlier page.
                    handle(swipe > 0 ? .previousPage : .nextPage)
                }
                if event.phase == .ended || event.phase == .cancelled { swipe = 0; swipeHandled = false }
                return event
            default:
                return event
            }
        }
    }
}

#Preview {
    OverviewView(model: .preview())
        .frame(width: 1_200, height: 800)
        .background(BrandCanvas())
        .preferredColorScheme(.dark)
}
