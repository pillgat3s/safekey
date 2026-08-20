import SwiftUI
import AppKit

/// Reaches the hosting NSWindow to apply settings SwiftUI has no API for:
/// blocking screen capture and disabling state restoration. Re-asserts on
/// every window move because SwiftUI can recreate windows across scene
/// updates.
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowObservingView {
        let view = WindowObservingView()
        view.blocksScreenCapture = blocksScreenCapture
        return view
    }

    func updateNSView(_ nsView: WindowObservingView, context: Context) {
        nsView.blocksScreenCapture = blocksScreenCapture
        nsView.apply()
    }

    /// Set false on the lock screen. A window excluded from screen capture may
    /// not be a valid host for a system-presented sheet, which pushes the
    /// biometric prompt out into a free-floating panel. The lock screen
    /// displays nothing secret — no entries, no secrets, just the icon and a
    /// password field — so exempting it costs nothing and may let the prompt
    /// attach where it belongs.
    var blocksScreenCapture: Bool = true

    final class WindowObservingView: NSView {
        var blocksScreenCapture = true

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let window else { return }
            window.sharingType = (blocksScreenCapture && !DebugSupport.allowsCapture) ? .none : .readOnly
            window.isRestorable = false
        }
    }
}

extension View {
    /// Hides window contents from screenshots/screen recording and disables
    /// window restoration snapshots.
    func protectedWindow(blocksScreenCapture: Bool = true) -> some View {
        background(WindowAccessor(blocksScreenCapture: blocksScreenCapture))
    }
}
