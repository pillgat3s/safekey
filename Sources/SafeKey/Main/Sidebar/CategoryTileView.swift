import SwiftUI

/// One tile in the sidebar's 2-column category grid — the Passwords-app
/// signature: gradient icon badge top-left, bold count top-right, caption
/// title underneath.
struct CategoryTileView: View {
    let icon: String
    let color: Color
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top) {
                    IconTile(systemName: icon, color: color, size: 28)
                    Spacer(minLength: 0)
                    Text("\(count)")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .monospacedDigit()
                }
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.22))
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary.opacity(0.55))
            }
        }
        .accessibilityLabel("\(title), \(count) items")
    }
}
