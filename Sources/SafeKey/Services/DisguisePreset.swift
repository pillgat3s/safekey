import SwiftUI
import AppKit

/// A disguise: what the app calls itself and what its icon looks like.
/// Icons are drawn at runtime from SF Symbols so no binary assets need to
/// ship, and the same drawing code produces the .icns written into the bundle.
struct DisguisePreset: Identifiable, Hashable {
    let id: String
    let displayName: String
    let symbolName: String
    let topColor: Color
    let bottomColor: Color
    /// Document-style icons draw a page with a folded corner instead of the
    /// rounded-rect app tile — convincing when file extensions are hidden.
    let style: Style

    enum Style: Hashable {
        case appTile
        case document
    }

    static let original = DisguisePreset(
        id: "safekey",
        displayName: "SafeKey",
        symbolName: "key.radiowaves.forward.fill",
        topColor: Color(red: 0.29, green: 0.56, blue: 0.99),
        bottomColor: Color(red: 0.13, green: 0.32, blue: 0.85),
        style: .appTile
    )

    static let all: [DisguisePreset] = [
        original,
        DisguisePreset(
            id: "quarterly-report",
            displayName: "Quarterly Report",
            symbolName: "doc.text",
            topColor: Color(white: 0.97),
            bottomColor: Color(white: 0.88),
            style: .document
        ),
        DisguisePreset(
            id: "receipts-2024",
            displayName: "Receipts 2024",
            symbolName: "tablecells",
            topColor: Color(red: 0.85, green: 0.94, blue: 0.86),
            bottomColor: Color(red: 0.60, green: 0.83, blue: 0.64),
            style: .document
        ),
        DisguisePreset(
            id: "calculator",
            displayName: "Calculator",
            symbolName: "plus.forwardslash.minus",
            topColor: Color(white: 0.42),
            bottomColor: Color(white: 0.22),
            style: .appTile
        ),
        DisguisePreset(
            id: "notes",
            displayName: "Notes",
            symbolName: "note.text",
            topColor: Color(red: 1.0, green: 0.87, blue: 0.44),
            bottomColor: Color(red: 0.98, green: 0.74, blue: 0.18),
            style: .appTile
        ),
        DisguisePreset(
            id: "system-config",
            displayName: "System Configuration",
            symbolName: "gearshape.2.fill",
            topColor: Color(white: 0.55),
            bottomColor: Color(white: 0.33),
            style: .appTile
        ),
        DisguisePreset(
            id: "photos-backup",
            displayName: "Photos Backup",
            symbolName: "photo.on.rectangle.angled",
            topColor: Color(red: 0.55, green: 0.80, blue: 0.98),
            bottomColor: Color(red: 0.24, green: 0.55, blue: 0.90),
            style: .appTile
        ),
        DisguisePreset(
            id: "archive",
            displayName: "Archive",
            symbolName: "archivebox.fill",
            topColor: Color(red: 0.82, green: 0.72, blue: 0.55),
            bottomColor: Color(red: 0.61, green: 0.48, blue: 0.31),
            style: .appTile
        ),
    ]

    static func preset(id: String) -> DisguisePreset? {
        all.first { $0.id == id }
    }
}

/// Renders preset icons to NSImage at any size (Dock, previews, .icns).
enum DisguiseIconRenderer {
    static func image(for preset: DisguisePreset, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        guard let context = NSGraphicsContext.current?.cgContext else { return image }
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        // macOS icons sit inset in their canvas.
        let inset = size * 0.08
        let shape = rect.insetBy(dx: inset, dy: inset)

        let path: NSBezierPath
        switch preset.style {
        case .appTile:
            path = NSBezierPath(roundedRect: shape, xRadius: size * 0.22, yRadius: size * 0.22)
        case .document:
            path = documentPath(in: shape, fold: size * 0.22)
        }

        context.saveGState()
        path.addClip()
        let gradient = NSGradient(
            colors: [NSColor(preset.topColor), NSColor(preset.bottomColor)]
        )
        gradient?.draw(in: shape, angle: -90)
        context.restoreGState()

        // Symbol glyph, tinted for contrast against the background.
        let isLightBackground = NSColor(preset.bottomColor).usingColorSpace(.deviceRGB).map {
            (0.299 * $0.redComponent + 0.587 * $0.greenComponent + 0.114 * $0.blueComponent) > 0.6
        } ?? false
        let glyphColor: NSColor = isLightBackground ? NSColor.black.withAlphaComponent(0.72) : .white
        // paletteColors tints the glyph itself; compositing a colored rect over
        // it would paint the background too.
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [glyphColor]))
        if let symbol = NSImage(systemSymbolName: preset.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let symbolSize = symbol.size
            let origin = NSPoint(
                x: (size - symbolSize.width) / 2,
                y: (size - symbolSize.height) / 2 - (preset.style == .document ? size * 0.03 : 0)
            )
            symbol.draw(
                in: NSRect(origin: origin, size: symbolSize),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high.rawValue]
            )
        }

        if preset.style == .document {
            NSColor.black.withAlphaComponent(0.12).setStroke()
            path.lineWidth = max(1, size * 0.004)
            path.stroke()
        }
        return image
    }

    /// A page rect with the top-right corner folded away.
    private static func documentPath(in rect: NSRect, fold: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - fold))
        path.line(to: NSPoint(x: rect.maxX - fold, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.close()
        return path
    }
}
