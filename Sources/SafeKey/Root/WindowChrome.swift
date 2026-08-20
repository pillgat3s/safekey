import SwiftUI
import AppKit

/// Hides the window's title and blends the titlebar into the content, so the
/// lock screen is a single uncluttered surface with only the traffic lights —
/// the way Apple's own lock screens present.
///
/// The previous state is captured and restored on disappear, so unlocking
/// returns the normal titled, toolbar-bearing window.
struct WindowChrome: NSViewRepresentable {
    var hidesTitle: Bool
    /// Shrinks the window to this size while shown, restoring the user's own
    /// frame afterwards. Apple's lock screens are compact windows that grow
    /// once unlocked, rather than a small panel adrift in a large one.
    var compactSize: NSSize?
    /// Makes the window non-opaque so a behind-window vibrancy view can sample
    /// the desktop. Without this the material renders as flat grey.
    var translucent: Bool = false

    func makeNSView(context: Context) -> ChromeView {
        let view = ChromeView()
        view.hidesTitle = hidesTitle
        view.compactSize = compactSize
        view.translucent = translucent
        return view
    }

    func updateNSView(_ nsView: ChromeView, context: Context) {
        nsView.hidesTitle = hidesTitle
        nsView.compactSize = compactSize
        nsView.translucent = translucent
        nsView.apply()
    }

    static func dismantleNSView(_ nsView: ChromeView, coordinator: ()) {
        nsView.restore()
    }

    final class ChromeView: NSView {
        var hidesTitle = false
        var compactSize: NSSize?
        var translucent = false

        private var savedChrome: (titleVisibility: NSWindow.TitleVisibility, transparent: Bool)?
        private var savedFrame: NSRect?
        private var savedOpacity: (isOpaque: Bool, background: NSColor)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let window else { return }
            if savedChrome == nil {
                savedChrome = (window.titleVisibility, window.titlebarAppearsTransparent)
            }
            window.titleVisibility = hidesTitle ? .hidden : (savedChrome?.titleVisibility ?? .visible)
            window.titlebarAppearsTransparent = hidesTitle ? true : (savedChrome?.transparent ?? false)

            if translucent {
                if savedOpacity == nil {
                    savedOpacity = (window.isOpaque, window.backgroundColor)
                }
                window.isOpaque = false
                window.backgroundColor = .clear
            }

            if let compactSize, savedFrame == nil {
                savedFrame = window.frame
                // Keep the window centred on where it already was.
                let origin = NSPoint(
                    x: window.frame.midX - compactSize.width / 2,
                    y: window.frame.midY - compactSize.height / 2
                )
                window.setFrame(NSRect(origin: origin, size: compactSize), display: true, animate: false)
            }
        }

        func restore() {
            guard let window else { return }
            if let savedChrome {
                window.titleVisibility = savedChrome.titleVisibility
                window.titlebarAppearsTransparent = savedChrome.transparent
            }
            if let savedOpacity {
                window.isOpaque = savedOpacity.isOpaque
                window.backgroundColor = savedOpacity.background
            }
            if let savedFrame {
                window.setFrame(savedFrame, display: true, animate: false)
            }
            savedChrome = nil
            savedFrame = nil
            savedOpacity = nil
        }

        deinit {
            MainActor.assumeIsolated { restore() }
        }
    }
}

extension View {
    /// Strips the window down to traffic lights, optionally shrinking it and
    /// making it translucent while shown.
    func chromelessWindow(compactSize: NSSize? = nil, translucent: Bool = false) -> some View {
        background(WindowChrome(hidesTitle: true, compactSize: compactSize, translucent: translucent))
            .toolbar(removing: .title)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}
