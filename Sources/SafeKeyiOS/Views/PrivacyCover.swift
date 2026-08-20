import SwiftUI

/// What the app switcher is allowed to photograph.
///
/// Shown whenever the scene is not active, so the snapshot iOS takes on the way
/// to the background can never contain a wallet list or a revealed secret.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.background)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: "key.radiowaves.forward.fill")
                    .font(.system(size: 52, weight: .medium))
                    .foregroundStyle(.tint)
                Text("SafeKey")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
    }
}
