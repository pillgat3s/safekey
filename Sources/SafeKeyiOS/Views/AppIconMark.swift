import SwiftUI

/// The app icon drawn in SwiftUI.
///
/// The asset-catalog icon cannot be loaded reliably by name at runtime, and the
/// mark is simple enough that redrawing it is more dependable than shipping a
/// second copy of the artwork that could drift out of step with the real icon.
struct AppIconMark: View {
    var size: CGFloat = 88

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(.sRGB, red: 0.20, green: 0.20, blue: 0.22),
                        Color(.sRGB, red: 0.05, green: 0.05, blue: 0.06),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: size, height: size)
            // The same hairline rim the real icon has. Without it a dark tile
            // on a dark background loses its edges entirely.
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }
            .overlay {
                Image(systemName: "key.radiowaves.forward.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Color(.sRGB, red: 0.04, green: 0.52, blue: 1.00))
            }
            .accessibilityHidden(true)
    }
}
