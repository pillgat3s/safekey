import SwiftUI
import SafeKeyCore

/// Offscreen render of the lock screen for the `SAFEKEY_UNLOCK_SHEET` debug
/// hook, so layout changes can be checked without a screenshot.
///
/// Useful for spacing and hierarchy only. `ImageRenderer` cannot draw
/// AppKit-backed controls, so the `SecureField` comes out as a placeholder
/// block, and the render has no window appearance so it is always light.
struct UnlockPreviewSheet: View {
    var body: some View {
        UnlockView()
            .frame(width: 640, height: 560)
    }
}
