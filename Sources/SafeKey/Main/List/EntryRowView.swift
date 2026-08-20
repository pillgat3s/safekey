import SwiftUI
import SafeKeyCore

struct EntryRowView: View {
    let entry: WalletEntry

    var body: some View {
        HStack(spacing: 10) {
            ChainLogo(chain: entry.chain, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.name)
                        .font(.body)
                        .lineLimit(1)
                    if entry.favorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                Text("\(entry.chain.displayName) · \(entry.kind.shortName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}
