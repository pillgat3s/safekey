import SwiftUI
import SafeKeyCore

/// A chain's logo on a rounded tile.
///
/// Chains in the artwork catalogue render their real mark from the official SVG
/// path data. Everything else falls back to a ticker lettermark on the brand
/// colour — which is how most wallets present the long tail anyway, and reads
/// far better than a wrong-looking approximation.
struct ChainLogo: View {
    let chain: Chain
    var size: CGFloat = 32

    private var artwork: ChainArtwork? { ChainArtwork.artwork(for: chain) }

    private var tileColor: Color {
        if let hex = artwork?.tileColorHex {
            return Color(hex: hex)
        }
        return chain.color.legibleOnDarkBackground
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [tileColor.opacity(0.88), tileColor],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: size, height: size)
            .overlay { glyph }
            .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityLabel(chain.displayName)
    }

    @ViewBuilder
    private var glyph: some View {
        if let symbol = artwork?.glyph {
            // Where a currency character *is* the mark (Ð), the type designer's
            // shape beats redrawing it.
            Text(symbol)
                .font(.system(size: size * 0.6, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        } else if let artwork {
            ArtworkGlyph(artwork: artwork, size: size)
        } else {
            Text(chain.shortCode)
                .font(.system(size: lettermarkPointSize, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .padding(.horizontal, size * 0.1)
        }
    }

    private var lettermarkPointSize: CGFloat {
        switch chain.shortCode.count {
        case ...2: size * 0.42
        case 3: size * 0.33
        default: size * 0.26
        }
    }
}

/// Draws the catalogue artwork, honouring per-facet opacity and gradient fills.
private struct ArtworkGlyph: View {
    let artwork: ChainArtwork
    let size: CGFloat

    var body: some View {
        ZStack {
            if let opacities = artwork.opacities, opacities.count == artwork.commands.count {
                // Shade-differentiated facets (Ethereum): draw each subpath at
                // its own opacity so the 3-D form survives on a flat tile.
                ForEach(Array(artwork.commands.indices), id: \.self) { index in
                    SVGArtworkShape(commands: artwork.commands, subpathIndex: index)
                        .fill(fillStyle, style: FillStyle(eoFill: false))
                        .opacity(opacities[index])
                }
            } else {
                // Even-odd so counters (the Bitcoin ₿ bowls, the TON notch,
                // Tron's inner facets) punch through instead of filling in.
                // Marks whose subpaths deliberately overlap opt out.
                SVGArtworkShape(commands: artwork.commands)
                    .fill(fillStyle, style: FillStyle(eoFill: artwork.usesEvenOddFill))
            }
        }
        .clipShape(artwork.clipsToCircle ? AnyShape(Circle()) : AnyShape(Rectangle()))
        .padding(size * artwork.inset)
    }

    private var fillStyle: AnyShapeStyle {
        switch artwork.fill {
        case .white:
            AnyShapeStyle(.white)
        case .gradient(let from, let to):
            AnyShapeStyle(
                LinearGradient(
                    colors: [Color(hex: from), Color(hex: to)],
                    startPoint: .bottomLeading,
                    endPoint: .topTrailing
                )
            )
        }
    }
}
