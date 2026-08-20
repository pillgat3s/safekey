import SwiftUI
import SafeKeyCore

extension Chain {
    var color: Color { Color(hex: colorHex) }
}

extension Color {
    /// `#RRGGBB` → Color. Chain brand colours live in SafeKeyCore as hex
    /// strings so the framework stays free of UI imports.
    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt64(cleaned, radix: 16) ?? 0x8E8E93
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// Brand colours like Aptos black or Cosmos near-black vanish against a
    /// dark sidebar; nudge very dark colours up so the tile stays legible.
    var legibleOnDarkBackground: Color {
        let nsColor = NSColor(self).usingColorSpace(.sRGB)
        guard let nsColor else { return self }
        let luminance = 0.299 * nsColor.redComponent
            + 0.587 * nsColor.greenComponent
            + 0.114 * nsColor.blueComponent
        guard luminance < 0.22 else { return self }
        return Color(nsColor.blended(withFraction: 0.35, of: .white) ?? nsColor)
    }
}

/// The Passwords-app style icon tile: rounded rect with a vertical gradient
/// and a white SF Symbol.
struct IconTile: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [color.opacity(0.75), color],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}
