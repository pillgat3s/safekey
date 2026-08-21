import SwiftUI
import SafeKeyCore

/// A group's icon: the emoji the user chose, an SF Symbol, or a folder.
///
/// Emoji are detected rather than stored under a separate flag, so the field
/// stays a single portable string in the vault format.
struct GroupMark: View {
    let group: WalletGroup
    var size: CGFloat = 26

    private var tint: Color {
        group.colorHex.map { Color(hex: $0) } ?? .blue
    }

    var body: some View {
        Group {
            if let icon = group.icon, !icon.isEmpty {
                if icon.isSingleEmoji {
                    Text(icon).font(.system(size: size * 0.82))
                } else {
                    Image(systemName: icon)
                        .font(.system(size: size * 0.6))
                        .foregroundStyle(tint)
                }
            } else {
                Image(systemName: "folder.fill")
                    .font(.system(size: size * 0.6))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
    }
}

extension String {
    /// True for a string that is one emoji — including multi-scalar ones like
    /// flags and skin-tone variants, which are several scalars but one glyph.
    var isSingleEmoji: Bool {
        guard count == 1, let character = first else { return false }
        return character.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0x238C }
    }
}
