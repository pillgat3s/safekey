import SwiftUI
import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI

/// Apple's in-window Touch ID control.
///
/// `LAContext.evaluatePolicy` on its own always raises an app-modal system
/// panel. The in-window presentation Apple's own apps use comes from this
/// separate framework: an `LAAuthenticationView` mounted in the view hierarchy
/// and bound to the *same* `LAContext` the policy is evaluated against. The
/// authentication UI then draws inside this view.
///
/// Two ordering rules matter, and getting them wrong makes the view look
/// broken rather than misconfigured:
///
/// 1. The view must already be mounted when `evaluatePolicy` is called — it
///    renders a *pending* evaluation, so a view added afterwards shows nothing.
/// 2. The context is single-use. After an evaluation completes the view must be
///    rebuilt against a fresh context, which is what the `.id(...)` on the call
///    site forces.
struct EmbeddedAuthenticationView: NSViewRepresentable {
    let context: LAContext
    var controlSize: NSControl.ControlSize = .large

    func makeNSView(context representableContext: Context) -> LAAuthenticationView {
        LAAuthenticationView(context: self.context, controlSize: controlSize)
    }

    func updateNSView(_ nsView: LAAuthenticationView, context: Context) {}
}
