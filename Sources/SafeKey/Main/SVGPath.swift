import SwiftUI

/// Parses the SVG path mini-language into a SwiftUI `Path`.
///
/// This exists so chain logos can be stored as the official artwork's `d`
/// strings verbatim instead of being re-drawn by hand. Adding a new chain is
/// then a paste, not a geometry exercise.
///
/// Supports the full command set: M/m L/l H/h V/v C/c S/s Q/q T/t A/a Z/z,
/// including elliptical arcs (converted to cubic Béziers).
enum SVGPath {
    static func parse(_ d: String) -> Path {
        var path = Path()
        var scanner = Scanner(d)
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        var command: Character?

        while true {
            scanner.skipSeparators()
            if let next = scanner.peek(), next.isLetter {
                command = next
                scanner.advance()
            } else if scanner.isAtEnd {
                break
            } else if command == nil {
                break
            } else if command == "M" {
                // Repeated coordinate pairs after a moveto are implicit linetos.
                command = "L"
            } else if command == "m" {
                command = "l"
            }
            guard let cmd = command else { break }

            let relative = cmd.isLowercase
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }

            switch cmd {
            case "M", "m":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = point(x, y)
                subpathStart = current
                path.move(to: current)
                lastCubicControl = nil; lastQuadControl = nil

            case "L", "l":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = point(x, y)
                path.addLine(to: current)
                lastCubicControl = nil; lastQuadControl = nil

            case "H", "h":
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                lastCubicControl = nil; lastQuadControl = nil

            case "V", "v":
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
                lastCubicControl = nil; lastQuadControl = nil

            case "C", "c":
                guard let x1 = scanner.number(), let y1 = scanner.number(),
                      let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let c1 = point(x1, y1), c2 = point(x2, y2), end = point(x, y)
                path.addCurve(to: end, control1: c1, control2: c2)
                current = end; lastCubicControl = c2; lastQuadControl = nil

            case "S", "s":
                guard let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                // Reflect the previous control point about the current point.
                let c1 = lastCubicControl.map {
                    CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                let c2 = point(x2, y2), end = point(x, y)
                path.addCurve(to: end, control1: c1, control2: c2)
                current = end; lastCubicControl = c2; lastQuadControl = nil

            case "Q", "q":
                guard let x1 = scanner.number(), let y1 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let c = point(x1, y1), end = point(x, y)
                path.addQuadCurve(to: end, control: c)
                current = end; lastQuadControl = c; lastCubicControl = nil

            case "T", "t":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                let c = lastQuadControl.map {
                    CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                let end = point(x, y)
                path.addQuadCurve(to: end, control: c)
                current = end; lastQuadControl = c; lastCubicControl = nil

            case "A", "a":
                guard let rx = scanner.number(), let ry = scanner.number(),
                      let rotation = scanner.number(),
                      let largeArc = scanner.flag(), let sweep = scanner.flag(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let end = point(x, y)
                appendArc(
                    to: &path, from: current, to: end,
                    rx: rx, ry: ry, rotationDegrees: rotation,
                    largeArc: largeArc, sweep: sweep
                )
                current = end; lastCubicControl = nil; lastQuadControl = nil

            case "Z", "z":
                path.closeSubpath()
                current = subpathStart
                lastCubicControl = nil; lastQuadControl = nil

            default:
                return path
            }
        }
        return path
    }

    /// Endpoint-parameterised elliptical arc → centre parameterisation → cubic
    /// Bézier segments (SVG spec appendix F.6).
    private static func appendArc(
        to path: inout Path,
        from start: CGPoint, to end: CGPoint,
        rx rxIn: CGFloat, ry ryIn: CGFloat,
        rotationDegrees: CGFloat,
        largeArc: Bool, sweep: Bool
    ) {
        guard rxIn != 0, ryIn != 0 else {
            path.addLine(to: end)
            return
        }
        if start == end { return }

        var rx = abs(rxIn), ry = abs(ryIn)
        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)

        let dx2 = (start.x - end.x) / 2, dy2 = (start.y - end.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        // Scale radii up if they are too small to span the endpoints.
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            rx *= sqrt(lambda); ry *= sqrt(lambda)
        }

        let sign: CGFloat = largeArc == sweep ? -1 : 1
        let numerator = max(0, rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p)
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let coefficient = denominator == 0 ? 0 : sign * sqrt(numerator / denominator)
        let cxp = coefficient * rx * y1p / ry
        let cyp = -coefficient * ry * x1p / rx

        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            guard len != 0 else { return 0 }
            let value = max(-1, min(1, dot / len))
            let result = acos(value)
            return (ux * vy - uy * vx) < 0 ? -result : result
        }

        let startAngle = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        // One cubic per ≤90° of sweep keeps the approximation error invisible.
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let segmentDelta = delta / CGFloat(segments)
        let alpha = 4.0 / 3.0 * tan(segmentDelta / 4)

        var theta = startAngle
        for _ in 0..<segments {
            let theta2 = theta + segmentDelta
            let cosT1 = cos(theta), sinT1 = sin(theta)
            let cosT2 = cos(theta2), sinT2 = sin(theta2)

            func map(_ ex: CGFloat, _ ey: CGFloat) -> CGPoint {
                CGPoint(
                    x: cosPhi * rx * ex - sinPhi * ry * ey + cx,
                    y: sinPhi * rx * ex + cosPhi * ry * ey + cy
                )
            }
            let p2 = map(cosT2, sinT2)
            let c1 = map(cosT1 - alpha * sinT1, sinT1 + alpha * cosT1)
            let c2 = map(cosT2 + alpha * sinT2, sinT2 - alpha * cosT2)
            path.addCurve(to: p2, control1: c1, control2: c2)
            theta = theta2
        }
    }

    /// Character scanner tolerant of SVG's compact number syntax: implicit
    /// separators, "1.5.5" meaning two numbers, "-1-2", exponents, and arc
    /// flags written without delimiters ("1,0,0,1" or "1001").
    private struct Scanner {
        private let characters: [Character]
        private var index: Int = 0

        init(_ string: String) {
            characters = Array(string)
        }

        var isAtEnd: Bool { index >= characters.count }

        func peek() -> Character? {
            index < characters.count ? characters[index] : nil
        }

        mutating func advance() { index += 1 }

        mutating func skipSeparators() {
            while index < characters.count {
                let c = characters[index]
                if c == "," || c == " " || c == "\n" || c == "\t" || c == "\r" {
                    index += 1
                } else {
                    break
                }
            }
        }

        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < characters.count else { return nil }
            let c = characters[index]
            guard c == "0" || c == "1" else { return number().map { $0 != 0 } }
            index += 1
            return c == "1"
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            var start = index
            var sawDigit = false
            var sawDot = false

            if index < characters.count, characters[index] == "+" || characters[index] == "-" {
                index += 1
            }
            while index < characters.count {
                let c = characters[index]
                if c.isNumber {
                    sawDigit = true; index += 1
                } else if c == ".", !sawDot {
                    sawDot = true; index += 1
                } else if (c == "e" || c == "E"), sawDigit {
                    let save = index
                    index += 1
                    if index < characters.count, characters[index] == "+" || characters[index] == "-" {
                        index += 1
                    }
                    if index < characters.count, characters[index].isNumber {
                        while index < characters.count, characters[index].isNumber { index += 1 }
                    } else {
                        index = save
                        break
                    }
                } else {
                    break
                }
            }
            guard sawDigit else {
                index = start
                return nil
            }
            let text = String(characters[start..<index])
            start = index
            return Double(text).map { CGFloat($0) }
        }
    }
}

/// Renders one or more SVG subpaths, scaled to fit and preserving aspect ratio.
/// The bounding box is computed across *all* subpaths so multi-part logos keep
/// their relative alignment.
struct SVGArtworkShape: Shape {
    let commands: [String]
    /// Index into `commands`; when set, only that subpath is drawn (with the
    /// transform still derived from the whole artwork).
    var subpathIndex: Int?

    func path(in rect: CGRect) -> Path {
        let parsed = commands.map(SVGPath.parse)
        guard !parsed.isEmpty else { return Path() }

        var union: CGRect = .null
        for p in parsed where !p.isEmpty {
            union = union.union(p.boundingRect)
        }
        guard !union.isNull, union.width > 0, union.height > 0 else { return Path() }

        let scale = min(rect.width / union.width, rect.height / union.height)
        let offsetX = rect.minX + (rect.width - union.width * scale) / 2
        let offsetY = rect.minY + (rect.height - union.height * scale) / 2
        let transform = CGAffineTransform(translationX: offsetX, y: offsetY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -union.minX, y: -union.minY)

        var result = Path()
        if let subpathIndex, parsed.indices.contains(subpathIndex) {
            result.addPath(parsed[subpathIndex], transform: transform)
        } else {
            for p in parsed {
                result.addPath(p, transform: transform)
            }
        }
        return result
    }
}
