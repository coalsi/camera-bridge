import AVFoundation
import AppKit
import SwiftUI

/// A camera's live picture: hosts the `AVSampleBufferDisplayLayer` of a feed's `LiveVideoRenderer`. `.resizeAspect` fits the
/// whole picture with bars in the app's dark colour (the single-camera viewer); `.resizeAspectFill` fills the frame and
/// crops what overflows (grid tiles, cropped to 16:9). Transparent until the first picture arrives, so the snapshot placed
/// under it shows meanwhile (`LiveFeed.hasPicture`).
struct LiveVideoView: NSViewRepresentable {
    let feed: LiveFeed
    var gravity: AVLayerVideoGravity = .resizeAspect

    #if DEBUG
    /// `-demoStillLive YES` (screenshots with sample data): live tiles, the camera page and the viewer keep showing the camera's
    /// snapshot (the `-demoImages` picture) instead of the preview engine's test pattern.
    static let showsStillsInstead = UserDefaults.standard.bool(forKey: "demoStillLive")
    #else
    static let showsStillsInstead = false
    #endif

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.host(renderer: feed.sink as? LiveVideoRenderer, gravity: gravity)
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        view.host(renderer: feed.sink as? LiveVideoRenderer, gravity: gravity)
    }

    static func dismantleNSView(_ view: HostView, coordinator: ()) {
        view.release()
    }

    final class HostView: NSView {
        private var renderer: LiveVideoRenderer?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.masksToBounds = true
        }

        required init?(coder: NSCoder) { nil }

        func host(renderer: LiveVideoRenderer?, gravity: AVLayerVideoGravity) {
            if let renderer, renderer !== self.renderer {
                self.renderer = renderer
                renderer.layer.removeFromSuperlayer()
                layer?.addSublayer(renderer.layer)
                needsLayout = true
            }
            if let layer = renderer?.layer, layer.videoGravity != gravity { layer.videoGravity = gravity }
        }

        func release() {
            renderer?.layer.removeFromSuperlayer()
            renderer = nil
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            renderer?.layer.frame = bounds
            CATransaction.commit()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks go to the SwiftUI controls around it
    }
}
