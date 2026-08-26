import SwiftUI
import UIKit

/// Whether the screen is currently being recorded, mirrored, or streamed.
///
/// iOS cannot block a screenshot the way the Mac app blocks window capture —
/// there is no API for it. What *is* observable is ongoing capture: a screen
/// recording, AirPlay mirroring to a TV, a QuickTime capture over cable, or a
/// call sharing the screen. Those are exactly the channels through which a
/// revealed seed phrase leaves the device without the user thinking of this
/// app at all — so while any of them is active, the detail screen refuses to
/// reveal and re-hides anything already showing.
@MainActor
@Observable
final class ScreenCapture {
    static let shared = ScreenCapture()

    private(set) var isCaptured: Bool
    /// Held for the lifetime of the singleton: a block observer is unregistered
    /// the moment its token deallocates, so discarding it would silently turn
    /// the whole feature off.
    @ObservationIgnored private var observation: (any NSObjectProtocol)?

    private init() {
        isCaptured = Self.anyScreenCaptured()
        // The notification names the screen that changed; re-deriving from all
        // connected scenes is simpler than tracking which one it was, and this
        // fires rarely.
        observation = NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                ScreenCapture.shared.isCaptured = Self.anyScreenCaptured()
            }
        }
    }

    private static func anyScreenCaptured() -> Bool {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.isCaptured }
            .contains(true)
    }
}
