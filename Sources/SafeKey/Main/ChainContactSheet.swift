import SwiftUI
import SafeKeyCore

/// A grid of every chain tile at two sizes. Rendered offscreen by the
/// `SAFEKEY_CHAIN_SHEET` debug hook so artwork changes can be checked without
/// clicking through the app.
struct ChainContactSheet: View {
    let chains: [Chain]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("SafeKey chain marks")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)

            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(140), spacing: 12), count: 6),
                spacing: 16
            ) {
                ForEach(chains, id: \.self) { chain in
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            ChainLogo(chain: chain, size: 52)
                            ChainLogo(chain: chain, size: 20)
                        }
                        Text(chain.displayName)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                    .frame(width: 140)
                }
            }
        }
        .padding(24)
        .background(Color(red: 0.09, green: 0.09, blue: 0.1))
    }
}
