import SwiftUI
import AppKit

/// A behind-window vibrancy surface.
///
/// This is deliberately `NSVisualEffectView` rather than a SwiftUI material:
/// SwiftUI's `.ultraThinMaterial` and friends blur what is behind them *within
/// the app*, so on an opaque window they just render as flat grey. Only
/// `blendingMode = .behindWindow` samples the desktop and windows underneath,
/// which is what makes Apple's lock screens pick up the wallpaper.
///
/// The window must also be non-opaque with a clear background colour for this
/// to show — `WindowChrome` handles that.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = .behindWindow
        // `.active` keeps the vibrancy alive even when the window is not key,
        // so the lock screen does not flatten out when focus moves away.
        view.state = .active
    }
}
