import SwiftUI
import SafeKeyCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

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
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return self }
        #else
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return self }
        let (r, g, b) = (ns.redComponent, ns.greenComponent, ns.blueComponent)
        #endif
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        guard luminance < 0.22 else { return self }
        // Blend 35% toward white — the same lift on both platforms.
        let lift: (CGFloat) -> Double = { Double($0 + (1 - $0) * 0.35) }
        return Color(.sRGB, red: lift(r), green: lift(g), blue: lift(b))
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
