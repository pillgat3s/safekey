#!/usr/bin/env swift
// Generates the SafeKey app icon into
// Sources/SafeKey/Resources/Assets.xcassets.
//
// Run from the repo root:  swift scripts/make_app_icon.swift
//
// Two things worth knowing:
//
// 1. Images are rasterised straight into an NSBitmapImageRep at an exact pixel
//    count. Drawing into `NSImage(size:)` + `lockFocus()` inherits the main
//    display's backing scale, which silently produces 2× files on a Retina Mac
//    — actool then rejects every one of them and emits no icon at all.
//
// 2. A macOS `.appiconset` has no light/dark appearance support — that is an
//    iOS feature, and the macOS 26 equivalent is an Icon Composer `.icon`
//    document, whose schema Xcode does not publish. Rather than ship an icon
//    that only follows the system appearance in the Dock and not in Finder,
//    there is one icon: a near-black tile with the brand-blue key, which sits
//    correctly on light and dark backgrounds alike.
import AppKit

struct Appearance {
    let top: NSColor
    let bottom: NSColor
    let glyph: NSColor
    let rim: NSColor?
}

// Near-black tile with the vivid brand-blue glyph, the way Apple's own icons
// present in dark mode.
let iconAppearance = Appearance(
    top: NSColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1),
    bottom: NSColor(srgbRed: 0.06, green: 0.06, blue: 0.07, alpha: 1),
    glyph: NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1),
    rim: NSColor(white: 1.0, alpha: 0.08)
)

let symbolName = "key.radiowaves.forward.fill"

func renderPNG(_ appearance: Appearance, pixels: Int) -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("could not allocate bitmap") }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let size = CGFloat(pixels)
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let shape = rect.insetBy(dx: size * 0.08, dy: size * 0.08)
    let path = NSBezierPath(roundedRect: shape, xRadius: size * 0.22, yRadius: size * 0.22)

    NSGraphicsContext.current?.cgContext.saveGState()
    path.addClip()
    NSGradient(colors: [appearance.top, appearance.bottom])?.draw(in: shape, angle: -90)
    NSGraphicsContext.current?.cgContext.restoreGState()

    if let rim = appearance.rim {
        rim.setStroke()
        path.lineWidth = max(1, size * 0.008)
        path.stroke()
    }

    let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [appearance.glyph]))
    if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let symbolSize = symbol.size
        let origin = NSPoint(x: (size - symbolSize.width) / 2, y: (size - symbolSize.height) / 2)
        symbol.draw(in: NSRect(origin: origin, size: symbolSize), from: .zero,
                    operation: .sourceOver, fraction: 1.0, respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode PNG")
    }
    return png
}

let assets = "Sources/SafeKey/Resources/Assets.xcassets"
let iconset = "\(assets)/AppIcon.appiconset"
// Left over from the abandoned runtime light/dark swap.
try? FileManager.default.removeItem(atPath: "\(assets)/AppIconDark.imageset")
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func writeJSON(_ object: [String: Any], to path: String) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: URL(fileURLWithPath: path))
}

// MARK: App icon (light)

struct Variant { let points: Int; let scale: Int }
let variants = [
    Variant(points: 16, scale: 1), Variant(points: 16, scale: 2),
    Variant(points: 32, scale: 1), Variant(points: 32, scale: 2),
    Variant(points: 128, scale: 1), Variant(points: 128, scale: 2),
    Variant(points: 256, scale: 1), Variant(points: 256, scale: 2),
    Variant(points: 512, scale: 1), Variant(points: 512, scale: 2),
]

var iconImages: [[String: Any]] = []
for variant in variants {
    let pixels = variant.points * variant.scale
    let filename = "icon_\(variant.points)x\(variant.points)@\(variant.scale)x.png"
    try! renderPNG(iconAppearance, pixels: pixels).write(to: URL(fileURLWithPath: "\(iconset)/\(filename)"))
    iconImages.append([
        "idiom": "mac",
        "size": "\(variant.points)x\(variant.points)",
        "scale": "\(variant.scale)x",
        "filename": filename,
    ])
}
writeJSON(["images": iconImages, "info": ["version": 1, "author": "xcode"]], to: "\(iconset)/Contents.json")
writeJSON(["info": ["version": 1, "author": "xcode"]], to: "\(assets)/Contents.json")

print("wrote \(iconImages.count) app-icon images")
