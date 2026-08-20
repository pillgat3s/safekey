import SwiftUI

/// Numbered word chips in a 3-column grid — the standard way wallets present
/// a seed phrase for careful reading.
struct SeedPhraseGridView: View {
    let phrase: String

    private var words: [String] {
        phrase.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
            spacing: 8
        ) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                HStack(spacing: 6) {
                    Text("\(index + 1)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, alignment: .trailing)
                    Text(word)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}
