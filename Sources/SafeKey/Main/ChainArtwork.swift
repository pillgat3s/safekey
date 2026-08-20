import SwiftUI
import SafeKeyCore

/// Official chain marks, stored as the artwork's own SVG path data.
///
/// Only the *glyph* is kept — where the source artwork wraps its mark in a
/// coloured disc, that disc is dropped, because the tile already supplies the
/// background.
///
/// Adding a chain is a paste: drop the `d` string(s) here and add a
/// `KnownChain` case. `SVGArtworkShape` handles fitting and alignment.
struct ChainArtwork {
    /// Subpaths in draw order.
    let commands: [String]
    /// Opacity per subpath, for logos whose facets are distinguished by shade
    /// (Ethereum). Defaults to fully opaque.
    var opacities: [Double]?
    /// Fill treatment. Most marks are white on the brand colour; Solana keeps
    /// its own gradient because that gradient *is* the logo.
    var fill: Fill = .white
    /// Fraction of the tile left as padding around the glyph.
    var inset: CGFloat = 0.24
    /// Overrides the tile background (Solana's mark needs a dark field).
    var tileColorHex: String?
    /// Non-zero winding for marks whose subpaths overlap by design (Stellar,
    /// Cosmos); even-odd elsewhere so counters punch through.
    var usesEvenOddFill = true
    /// A currency glyph instead of paths, where the character *is* the mark.
    var glyph: String?
    /// Masks the glyph to a circle. Aptos' mark is a set of bands that only
    /// read as an "A" when clipped by the logo's disc; without the mask they
    /// are just stripes.
    var clipsToCircle = false

    enum Fill {
        case white
        case gradient(from: String, to: String)
    }

    static func artwork(for chain: Chain) -> ChainArtwork? {
        guard case .known(let known) = chain else { return nil }
        return catalog[known]
    }

    // MARK: - Catalogue

    private static let catalog: [KnownChain: ChainArtwork] = [
        .bitcoin: ChainArtwork(commands: [bitcoinGlyph], inset: 0.26),
        .evm: ChainArtwork(
            commands: ethereumFacets,
            // The official mark distinguishes its six faces by shade; mapping
            // those to white opacities keeps the 3-D read on a colour tile.
            opacities: [1.0, 0.62, 1.0, 0.62, 0.45, 0.8],
            inset: 0.26
        ),
        .solana: ChainArtwork(
            commands: solanaBars,
            fill: .gradient(from: "#00FFA3", to: "#DC1FFF"),
            inset: 0.24,
            tileColorHex: "#1A1A20"
        ),
        .ton: ChainArtwork(commands: [tonGem], inset: 0.26),
        .tron: ChainArtwork(commands: [tronMark], inset: 0.24),
        .cardano: ChainArtwork(commands: cardanoConstellation, inset: 0.2, usesEvenOddFill: false),
        .polkadot: ChainArtwork(commands: polkadotPetals, inset: 0.18, usesEvenOddFill: false),
        .xrp: ChainArtwork(commands: xrpMark, inset: 0.24),
        .litecoin: ChainArtwork(commands: [litecoinGlyph], inset: 0.26),
        .monero: ChainArtwork(commands: [moneroGlyph], inset: 0.24),
        .cosmos: ChainArtwork(commands: cosmosMark, inset: 0.18, usesEvenOddFill: false),
        .sui: ChainArtwork(commands: [suiDrop], inset: 0.26),
        .aptos: ChainArtwork(commands: aptosBars, inset: 0.16, usesEvenOddFill: false, clipsToCircle: true),
        .near: ChainArtwork(commands: [nearMark], inset: 0.28),
        .stellar: ChainArtwork(commands: stellarMark, inset: 0.22, usesEvenOddFill: false),
        .dogecoin: ChainArtwork(commands: [], inset: 0.24, glyph: "Ð"),
        .bitcoinCash: ChainArtwork(commands: [bitcoinCashGlyph], inset: 0.26),
        .zcash: ChainArtwork(commands: [zcashGlyph], inset: 0.28),
        .tezos: ChainArtwork(commands: [tezosGlyph], inset: 0.3),
        .algorand: ChainArtwork(commands: [algorandMark], inset: 0.28),
        .hedera: ChainArtwork(commands: [hederaMark], inset: 0.3),
        .filecoin: ChainArtwork(commands: [filecoinGlyph], inset: 0.26),
    ]

    // MARK: - Geometry helpers

    /// A circle as an SVG path, for logos built from dot constellations.
    private static func circle(_ cx: Double, _ cy: Double, _ r: Double) -> String {
        "M\(cx - r),\(cy) a\(r),\(r) 0 1,0 \(r * 2),0 a\(r),\(r) 0 1,0 \(-r * 2),0 Z"
    }

    /// A rotated ellipse as an SVG path, using the arc command's own
    /// x-axis-rotation rather than a transform attribute.
    private static func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ degrees: Double) -> String {
        let radians = degrees * .pi / 180
        let dx = rx * cos(radians), dy = rx * sin(radians)
        let x0 = cx - dx, y0 = cy - dy
        let x1 = cx + dx, y1 = cy + dy
        return "M\(x0),\(y0) A\(rx),\(ry) \(degrees) 1 0 \(x1),\(y1) A\(rx),\(ry) \(degrees) 1 0 \(x0),\(y0) Z"
    }

    // MARK: - Path data (official artwork, glyph only)

    /// Bitcoin ₿ — the white glyph from the 4091×4091 mark.
    private static let bitcoinGlyph = """
    M2947.77 1754.38c40.72,-272.26 -166.56,-418.61 -450,-516.24l91.95 -368.8 -224.5 -55.94 -89.51 359.09c-59.02,\
    -14.72 -119.63,-28.59 -179.87,-42.34l90.16 -361.46 -224.36 -55.94 -92 368.68c-48.84,-11.12 -96.81,-22.11 \
    -143.35,-33.69l0.26 -1.16 -309.59 -77.31 -59.72 239.78c0,0 166.56,38.18 163.05,40.53 90.91,22.69 107.35,82.87 \
    104.62,130.57l-104.74 420.15c6.26,1.59 14.38,3.89 23.34,7.49 -7.49,-1.86 -15.46,-3.89 -23.73,-5.87l-146.81 \
    588.57c-11.11,27.62 -39.31,69.07 -102.87,53.33 2.25,3.26 -163.17,-40.72 -163.17,-40.72l-111.46 256.98 292.15 \
    72.83c54.35,13.63 107.61,27.89 160.06,41.3l-92.9 373.03 224.24 55.94 92 -369.07c61.26,16.63 120.71,31.97 \
    178.91,46.43l-91.69 367.33 224.51 55.94 92.89 -372.33c382.82,72.45 670.67,43.24 791.83,-303.02 97.63,-278.78 \
    -4.86,-439.58 -206.26,-544.44 146.69,-33.83 257.18,-130.31 286.64,-329.61l-0.07 -0.05zm-512.93 719.26c-69.38,\
    278.78 -538.76,128.08 -690.94,90.29l123.28 -494.2c152.17,37.99 640.17,113.17 567.67,403.91zm69.43 -723.3c-63.29,\
    253.58 -453.96,124.75 -580.69,93.16l111.77 -448.21c126.73,31.59 534.85,90.55 468.94,355.05l-0.02 0z
    """

    /// The Ethereum octahedron's six faces, from the 784×1277 artwork.
    private static let ethereumFacets = [
        "M392.07,0 L383.5,29.11 L383.5,873.74 L392.07,882.29 L784.13,650.54 Z",
        "M392.07,0 L0,650.54 L392.07,882.29 L392.07,472.33 Z",
        "M392.07,956.52 L387.24,962.41 L387.24,1263.28 L392.07,1277.38 L784.37,724.89 Z",
        "M392.07,1277.38 L392.07,956.52 L0,724.89 Z",
        "M392.07,882.29 L784.13,650.54 L392.07,472.33 Z",
        "M0,650.54 L392.07,882.29 L392.07,472.33 Z",
    ]

    /// Solana's three skewed bars, from the 397.7×311.7 artwork.
    private static let solanaBars = [
        """
        M64.6,237.9c2.4-2.4,5.7-3.8,9.2-3.8h317.4c5.8,0,8.7,7,4.6,11.1l-62.7,62.7c-2.4,2.4-5.7,3.8-9.2,3.8H6.5\
        c-5.8,0-8.7-7-4.6-11.1L64.6,237.9z
        """,
        """
        M64.6,3.8C67.1,1.4,70.4,0,73.8,0h317.4c5.8,0,8.7,7,4.6,11.1l-62.7,62.7c-2.4,2.4-5.7,3.8-9.2,3.8H6.5\
        c-5.8,0-8.7-7-4.6-11.1L64.6,3.8z
        """,
        """
        M333.1,120.1c-2.4-2.4-5.7-3.8-9.2-3.8H6.5c-5.8,0-8.7,7-4.6,11.1l62.7,62.7c2.4,2.4,5.7,3.8,9.2,3.8h317.4\
        c5.8,0,8.7-7,4.6-11.1L333.1,120.1z
        """,
    ]

    /// The TON gem, from the 56×56 artwork (the blue disc is dropped).
    private static let tonGem = """
    M37.6,15.6H18.4c-3.5,0-5.7,3.8-4,6.9l11.8,20.5c0.8,1.3,2.7,1.3,3.5,0l11.8-20.5C43.3,19.4,41.1,15.6,37.6,15.6\
    L37.6,15.6z M26.3,36.8l-2.6-5l-6.2-11.1c-0.4-0.7,0.1-1.6,1-1.6h7.8L26.3,36.8L26.3,36.8z M38.5,20.7l-6.2,11.1l-2.6,5\
    V19.1h7.8C38.4,19.1,38.9,20,38.5,20.7z
    """

    /// The Tron mark, from the 64×64 artwork.
    private static let tronMark = """
    M61.55,19.28c-3-2.77-7.15-7-10.53-10l-.2-.14a3.82,3.82,0,0,0-1.11-.62l0,0C41.56,7,3.63-.09,2.89,0a1.4,1.4,0,0,0\
    -.58.22L2.12.37a2.23,2.23,0,0,0-.52.84l-.05.13v.71l0,.11C5.82,14.05,22.68,53,26,62.14c.2.62.58,1.8,1.29,1.86h.16\
    c.38,0,2-2.14,2-2.14S58.41,26.74,61.34,23a9.46,9.46,0,0,0,1-1.48A2.41,2.41,0,0,0,61.55,19.28ZM36.88,23.37,49.24,\
    13.12l7.25,6.68Zm-4.8-.67L10.8,5.26l34.43,6.35ZM34,27.27l21.78-3.51-24.9,30ZM7.91,7,30.3,26,27.06,53.78Z
    """

    /// The XRP "X", from the 512×424 artwork.
    private static let xrpMark = [
        "M437,0h74L357,152.48c-55.77,55.19-146.19,55.19-202,0L.94,0H75L192,115.83a91.11,91.11,0,0,0,127.91,0Z",
        """
        M74.05,424H0L155,270.58c55.77-55.19,146.19-55.19,202,0L512,424H438L320,307.23a91.11,91.11,0,0,0-127.91,0Z
        """,
    ]

    /// Litecoin's Ł, from the 82.6×82.6 artwork.
    private static let litecoinGlyph = """
    M42,42.7,37.7,57.2h23a1.16,1.16,0,0,1,1.2,1.12v.38l-2,6.9a1.49,1.49,0,0,1-1.5,1.1H23.2l5.9-20.1-6.6,2L24,44l6.6-2\
    ,8.3-28.2a1.51,1.51,0,0,1,1.5-1.1h8.9a1.16,1.16,0,0,1,1.2,1.12v.38L43.5,38l6.6-2-1.4,4.8Z
    """

    /// Monero's M. The source artwork splits the mark across an orange upper
    /// region and a grey lower one, neither of which reads as an M alone, so
    /// the letterform is expressed directly at the same proportions.
    private static let moneroGlyph = """
    M10,82 L10,20 L50,62 L90,20 L90,82 L74,82 L74,50 L50,74 L26,50 L26,82 Z
    """

    /// Cardano's dot constellation. The mark is a geometric arrangement rather
    /// than freeform art, so it is generated at its true proportions: a centre
    /// dot, a hexagonal inner ring, a twelve-dot outer ring, and two poles.
    private static let cardanoConstellation: [String] = {
        var dots = [circle(0, 0, 13)]
        for index in 0..<6 {
            let angle = Double(index) / 6 * 2 * .pi
            dots.append(circle(cos(angle) * 34, sin(angle) * 34, 9))
        }
        for index in 0..<12 {
            let angle = Double(index) / 12 * 2 * .pi + .pi / 12
            dots.append(circle(cos(angle) * 62, sin(angle) * 62, 6.5))
        }
        for index in 0..<12 {
            let angle = Double(index) / 12 * 2 * .pi
            dots.append(circle(cos(angle) * 88, sin(angle) * 88, 4.5))
        }
        return dots
    }()

    /// Polkadot's six petals, from the 1326×1410 artwork's ellipses.
    private static let polkadotPetals: [String] = [
        ellipse(663, 147.9, 254.3, 147.9, 0),
        ellipse(663, 1262.3, 254.3, 147.9, 0),
        ellipse(180.5, 426.5, 254.3, 148, -60),
        ellipse(1145.6, 983.7, 254.3, 147.9, -60),
        ellipse(180.5, 983.7, 254.3, 148, 60),
        ellipse(1145.6, 426.6, 254.3, 147.9, 60),
    ]

    /// Cosmos: the atom's three orbits, three electrons and nucleus, from the
    /// 2500×2500 artwork (both background discs dropped).
    private static let cosmosMark: [String] = [
        """
        M1252.57,159.47c-134.93,0-244.34,489.4-244.34,1093.11s109.41,1093.11,244.34,1093.11,244.34-489.4,244.34-1093.11\
        S1387.5,159.47,1252.57,159.47ZM1269.44,2284c-15.43,20.58-30.86,5.14-30.86,5.14-62.14-72-93.21-205.76-93.21-205.76\
        -108.69-349.79-82.82-1100.82-82.82-1100.82,51.08-596.24,144-737.09,175.62-768.36a19.29,19.29,0,0,1,24.74-2\
        c45.88,32.51,84.36,168.47,84.36,168.47,113.63,421.81,103.34,817.9,103.34,817.9,10.29,344.65-56.94,730.45-56.94,\
        730.45C1341.92,2222.22,1269.44,2284,1269.44,2284Z
        """,
        """
        M2200.72,708.59c-67.18-117.08-546.09,31.58-1070,332s-893.47,638.89-826.34,755.92,546.09-31.58,1070-332,893.47\
        -638.89,826.34-755.92h0ZM366.36,1780.45c-25.72-3.24-19.91-24.38-19.91-24.38C378,1666.36,478.4,1572.84,478.4,\
        1572.84c249.43-268.36,913.79-619.65,913.79-619.65,542.54-252.42,711.06-241.77,753.81-230a19.29,19.29,0,0,1,14,\
        20.58c-5.14,56-104.17,157-104.17,157C1746.71,1209.36,1398,1397.58,1398,1397.58c-293.83,180.5-661.93,314.09\
        -661.93,314.09-280.09,100.93-369.7,68.78-369.7,68.78h0Z
        """,
        """
        M2198.35,1800.41c67.7-116.77-300.93-456.79-823-759.47S374.43,587.76,306.79,704.73s300.93,456.79,823.3,759.47\
        S2130.71,1917.39,2198.35,1800.41ZM351.65,749.85c-10-23.71,11.11-29.42,11.11-29.42C456.22,702.78,587.5,743,587.5,\
        743c357.15,81.33,994,480.25,994,480.25,490.33,343.11,565.53,494.24,576.8,537.14a19.29,19.29,0,0,1-10.7,22.43\
        c-51.13,23.41-188.07-11.47-188.07-11.47-422.07-113.17-759.62-320.52-759.62-320.52-303.29-163.58-603.19-415.28\
        -603.19-415.28-227.88-191.87-245-285.44-245-285.44Z
        """,
        circle(1250, 1250, 128.6),
        ellipse(1777.26, 756.17, 74.59, 77.16, 0),
        ellipse(552.98, 1018.52, 74.59, 77.16, 0),
        ellipse(1098.25, 1965.02, 74.59, 77.16, 0),
    ]

    /// Sui's droplet, from the 300×383.5 artwork.
    private static let suiDrop = """
    M240.1,159.9c15.6,19.6,25,44.5,25,71.5s-9.6,52.6-25.7,72.4l-1.4,1.7l-0.4-2.2c-0.3-1.8-0.7-3.7-1.1-5.6c-8-35.3\
    -34.2-65.6-77.4-90.2c-29.1-16.5-45.8-36.4-50.2-59c-2.8-14.6-0.7-29.3,3.3-41.9c4.1-12.6,10.1-23.1,15.2-29.4l16.8-20.5\
    c2.9-3.6,8.5-3.6,11.4,0L240.1,159.9L240.1,159.9z M266.6,139.4L154.2,2c-2.1-2.6-6.2-2.6-8.3,0L33.4,139.4l-0.4,0.5\
    C12.4,165.6,0,198.2,0,233.7c0,82.7,67.2,149.8,150,149.8c82.8,0,150-67.1,150-149.8c0-35.5-12.4-68.1-33.1-93.8L266.6,\
    139.4L266.6,139.4z M60.3,159.5l10-12.3l0.3,2.3c0.2,1.8,0.5,3.6,0.9,5.4c6.5,34.1,29.8,62.6,68.6,84.6c33.8,19.2,53.4,\
    41.3,59.1,65.6c2.4,10.1,2.8,20.1,1.8,28.8l-0.1,0.5l-0.5,0.2c-15.2,7.4-32.4,11.6-50.5,11.6c-63.5,0-115-51.4-115-114.8\
    C34.9,204.2,44.4,179.1,60.3,159.5L60.3,159.5z
    """

    /// Aptos' four strokes, from the 479.3×481.2 artwork.
    private static let aptosBars = [
        """
        M371.2,161h-42.4c-4.9,0-9.6-2.1-12.9-5.8l-17.2-19.4c-2.6-2.9-6.2-4.6-10.1-4.6s-7.5,1.7-10.1,4.6l-14.8,16.7\
        c-4.8,5.4-11.8,8.6-19,8.6H12.6C6,179.8,1.7,199.7,0,220.4h219.1c3.9,0,7.5-1.6,10.2-4.4l20.4-21.3c2.5-2.7,6.1-4.2,\
        9.7-4.2h0.8c3.9,0,7.5,1.7,10.1,4.6l17.2,19.4c3.3,3.7,8,5.8,12.9,5.8h178.8c-1.7-20.6-6-40.6-12.6-59.4L371.2,161\
        L371.2,161z
        """,
        """
        M132.6,345.2c3.9,0,7.5-1.6,10.2-4.4l20.4-21.3c2.6-2.7,6.1-4.2,9.8-4.2h0.8c3.9,0,7.6,1.7,10.1,4.5l17.2,19.4c3.3,\
        3.7,8,5.8,12.9,5.8h242.4c9.1-18.8,15.7-38.9,19.7-60H243.4c-4.9,0-9.6-2.1-12.9-5.8L213.3,260c-2.6-2.9-6.2-4.5-10.1\
        -4.5s-7.6,1.7-10.1,4.5l-14.8,16.7c-4.8,5.5-11.8,8.6-19.1,8.6H3.3c4,21.1,10.6,41.2,19.7,60L132.6,345.2L132.6,345.2z
        """,
        """
        M304.5,96.1c3.9,0,7.5-1.6,10.2-4.4l20.4-21.3c2.5-2.7,6.1-4.2,9.8-4.2h0.8c3.9,0,7.5,1.7,10.1,4.6L373,90.3c3.3,3.7,\
        8,5.8,12.9,5.8H432C388.1,37.7,318.3,0,239.7,0S91.2,37.7,47.3,96.1H304.5z
        """,
        """
        M212,404.7h-63c-4.9,0-9.6-2.1-12.9-5.8l-17.2-19.4c-2.6-2.9-6.2-4.5-10.1-4.5s-7.6,1.7-10.1,4.5l-14.8,16.7c-4.8,\
        5.5-11.8,8.6-19.1,8.6h-1c43.9,47,106.4,76.5,175.9,76.5s131.9-29.5,175.9-76.5L212,404.7L212,404.7z
        """,
    ]

    /// NEAR's N, from the 90.1×90 artwork.
    private static let nearMark = """
    M72.2,4.6L53.4,32.5c-1.3,1.9,1.2,4.2,3,2.6L74.9,19c0.5-0.4,1.2-0.1,1.2,0.6v50.3c0,0.7-0.9,1-1.3,0.5l-56-67\
    C17,1.2,14.4,0,11.5,0h-2C4.3,0,0,4.3,0,9.6v70.8C0,85.7,4.3,90,9.6,90c3.3,0,6.4-1.7,8.2-4.6l18.8-27.9c1.3-1.9-1.2-4.2\
    -3-2.6l-18.5,16c-0.5,0.4-1.2,0.1-1.2-0.6V20.1c0-0.7,0.9-1,1.3-0.5l56,67c1.8,2.2,4.5,3.4,7.3,3.4h2c5.3,0,9.6-4.3,9.6\
    -9.6V9.6c0-5.3-4.3-9.6-9.6-9.6C77.1,0,74,1.7,72.2,4.6z
    """

    /// Stellar's twin arcs, from the 236.36×200 artwork.
    private static let stellarMark = [
        """
        M203,26.16l-28.46,14.5-137.43,70a82.49,82.49,0,0,1-.7-10.69A81.87,81.87,0,0,1,158.2,28.6l16.29-8.3,2.43-1.24\
        A100,100,0,0,0,18.18,100q0,3.82.29,7.61a18.19,18.19,0,0,1-9.88,17.58L0,129.57V150l25.29-12.89,0,0,8.19-4.18,8.07\
        -4.11v0L186.43,55l16.28-8.29,33.65-17.15V9.14Z
        """,
        """
        M236.36,50,49.78,145,33.5,153.31,0,170.38v20.41l33.27-16.95,28.46-14.5L199.3,89.24A83.45,83.45,0,0,1,200,100,81.87,\
        81.87,0,0,1,78.09,171.36l-1,.53-17.66,9A100,100,0,0,0,218.18,100c0-2.57-.1-5.14-.29-7.68a18.2,18.2,0,0,1,9.87\
        -17.58l8.6-4.38Z
        """,
    ]

    /// Bitcoin Cash's ₿, from the 788×788 artwork.
    private static let bitcoinCashGlyph = """
    M516.9,261.7c-19.8-44.9-65.3-54.5-121-45.2L378,147.1L335.8,158l17.6,69.2c-11.1,2.8-22.5,5.2-33.8,8.4L302,166.8\
    l-42.2,10.9l17.9,69.4c-9.1,2.6-85.2,22.1-85.2,22.1l11.6,45.2c0,0,31-8.7,30.7-8c17.2-4.5,25.3,4.1,29.1,12.2l49.2,190.2\
    c0.6,5.5-0.4,14.9-12.2,18.1c0.7,0.4-30.7,7.9-30.7,7.9l4.6,52.7c0,0,75.4-19.3,85.3-21.8l18.1,70.2l42.2-10.9l-18.1-70.7\
    c11.6-2.7,22.9-5.5,33.9-8.4l18,70.3l42.2-10.9l-18.1-70.1c65-15.8,110.9-56.8,101.5-119.5c-6-37.8-47.3-68.8-81.6-72.3\
    C519.3,324.7,530,297.4,516.9,261.7L516.9,261.7z M496.6,427.2c8.4,62.1-77.9,69.7-106.4,77.2l-24.8-92.9\
    C394,404,482.4,372.5,496.6,427.2z M444.6,300.7c8.9,55.2-64.9,61.6-88.7,67.7l-22.6-84.3C357.2,278.2,426.5,249.6,444.6,\
    300.7z
    """

    /// Zcash's ⓩ glyph, from the 2500×2500 artwork (discs dropped).
    private static let zcashGlyph = """
    M1221.05,1588.59h541.67v270.84h-319.6v229.16H1165.18V1866.53H831.85c0-90.44-13.73-180.4,7.1-263.73,7.1-41.67,\
    55.4-83.34,90.43-125,104.17-125,208.34-250,319.61-375,41.66-48.77,83.33-90.44,132.1-145.83H860.26V686.13h305.39V457h270.84\
    V679h333.33c0,90.43,13.73,180.4-7.1,263.73-7.1,41.67-55.4,83.33-90.44,125-104.16,125-208.33,250-319.6,375\
    C1311,1491.53,1269.35,1539.82,1221.05,1588.59Z
    """

    /// Tezos' ꜩ, from the 1169.87×1593 artwork.
    private static let tezosGlyph = """
    M755.68,1593q-170.51,0-248.91-82.14a253.6,253.6,0,0,1-78.15-177,117.39,117.39,0,0,1,13.69-58.5A101.21,101.21,0,0,1,\
    479.64,1238a130.22,130.22,0,0,1,116.24,0A99.55,99.55,0,0,1,633,1275.36a115,115,0,0,1,14.18,58.5,111.73,111.73,0,0,1\
    -19.91,68.45,92.78,92.78,0,0,1-47.31,34.62,129.18,129.18,0,0,0,74.67,46.55,370,370,0,0,0,101.8,14.68,226.91,226.91,0,0,\
    0,128.19-38.33,224,224,0,0,0,83.63-113.25,492,492,0,0,0,27.38-169.5,465.07,465.07,0,0,0-29.87-176.23,217.54,217.54,0,0,\
    0-86.37-109.52,229.68,229.68,0,0,0-124.43-35.59,236.75,236.75,0,0,0-107.78,36.59L567.26,932.4V892.33L926.43,410.5H428.62\
    v500A178.9,178.9,0,0,0,456,1012.8a94.34,94.34,0,0,0,83.63,40.07,139.85,139.85,0,0,0,82.63-29.12,298.38,298.38,0,0,0,\
    69.2-71.19,24.86,24.86,0,0,1,9-11.94,18.4,18.4,0,0,1,12-4.48,41.55,41.55,0,0,1,23.4,9.95,49.82,49.82,0,0,1,12.69,33.85,\
    197.86,197.86,0,0,1-4.48,24.89,241,241,0,0,1-85.38,106,211.78,211.78,0,0,1-119.76,36.38q-161.67,0-224-63.72A238.67,\
    238.67,0,0,1,253.2,909.25V410.5H0V317.6H254.38V105.78L196.14,47.5V0h169l63.48,32.86V317.6l657.6-2,65.47,65.71L748.46,\
    786.5a271,271,0,0,1,76.16-18.42A330.1,330.1,0,0,1,972,810.15a302.7,302.7,0,0,1,126.95,113.29,399.78,399.78,0,0,1,57.25,\
    136.65,575.65,575.65,0,0,1,13.69,117,489.39,489.39,0,0,1-49.78,216.79,317.92,317.92,0,0,1-149.35,149.35A483.27,483.27,\
    0,0,1,755.68,1593Z
    """

    /// Algorand's A, from the 113×113.4 artwork (polygon converted to a path).
    private static let algorandMark = """
    M19.6,113.4 L36,85 L52.4,56.7 L68.7,28.3 L71.4,23.8 L72.6,28.3 L77.6,47 L72,56.7 L55.6,85 L39.3,113.4 L58.9,113.4 \
    L75.3,85 L83.8,70.3 L87.8,85 L95.4,113.4 L113,113.4 L105.4,85 L97.8,56.7 L95.8,49.4 L108,28.3 L90.2,28.3 L89.6,26.2 \
    L83.4,3 L82.6,0 L65.5,0 L65.1,0.6 L49.1,28.3 L32.7,56.7 L16.4,85 L0,113.4 Z
    """

    /// Hedera's H, from the 2500×2500 artwork (disc dropped).
    private static let hederaMark = """
    M1758.12,1790.62H1599.38V1453.13H900.62v337.49H741.87V696.25H900.62v329.37h698.76V696.25h158.75Zm-850-463.75h698.75\
    V1152.5H908.12Z
    """

    /// Filecoin's ⨎, from the 40×40 artwork (disc dropped).
    private static let filecoinGlyph = """
    M21.9,17.6l-0.6,3.2l5.7,0.8l-0.4,1.5L21,22.3c-0.4,1.3-0.6,2.7-1.1,3.9c-0.5,1.4-1,2.8-1.6,4.1c-0.8,1.7-2.2,2.9-4.1,3.2\
    c-1.1,0.2-2.3,0.1-3.2-0.6c-0.3-0.2-0.6-0.6-0.6-0.9c0-0.4,0.2-0.9,0.5-1.1c0.2-0.1,0.7,0,1,0.1c0.3,0.3,0.6,0.7,0.8,1.1\
    c0.6,0.8,1.4,0.9,2.2,0.3c0.9-0.8,1.4-1.9,1.7-3c0.6-2.4,1.2-4.7,1.7-7.1v-0.4L13,21.1l0.2-1.5l5.5,0.8l0.7-3.1l-5.7-0.9\
    l0.2-1.6l5.9,0.8c0.2-0.6,0.3-1.1,0.5-1.6c0.5-1.8,1-3.6,2.2-5.2s2.6-2.6,4.7-2.5c0.9,0,1.8,0.3,2.4,1c0.1,0.1,0.3,0.3,0.3,0.5\
    c0,0.4,0,0.9-0.3,1.2c-0.4,0.3-0.9,0.2-1.3-0.2c-0.3-0.3-0.5-0.6-0.8-0.9C26.9,7.1,26,7,25.3,7.7c-0.5,0.5-1,1.2-1.3,1.9\
    c-0.7,2.1-1.2,4.3-1.9,6.5l5.5,0.8l-0.4,1.5L21.9,17.6
    """
}
