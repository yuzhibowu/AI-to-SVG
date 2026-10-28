import Foundation
import CoreGraphics
import AppKit

public struct Point: Equatable {
    public var x: Double
    public var y: Double
    var cg: CGPoint { CGPoint(x: x, y: y) }
}

public enum Segment: Equatable {
    case move(Point), line(Point), curve(Point, Point, Point), close
}

public struct Ink: Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var css: String {
        "rgb(\(Int((red * 255).rounded())),\(Int((green * 255).rounded())),\(Int((blue * 255).rounded())))"
    }
    static func cmyk(_ c: Double, _ m: Double, _ y: Double, _ k: Double) -> Ink {
        if let rgb = NSColor(deviceCyan: c, magenta: m, yellow: y, black: k, alpha: 1).usingColorSpace(.sRGB) {
            return Ink(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
        }
        return Ink(red: (1-c)*(1-k), green: (1-m)*(1-k), blue: (1-y)*(1-k))
    }
    public var isNearlyWhite: Bool { min(red, min(green, blue)) > 0.94 }
    func resembles(_ other: Ink) -> Bool {
        abs(red-other.red) + abs(green-other.green) + abs(blue-other.blue) < 0.12
    }
}

public struct VectorShape {
    public let id: Int
    public let segments: [Segment]
    public let ink: Ink
    public let evenOdd: Bool
    public let whiteIsKnockout: Bool
    public let path: CGPath
    public let bounds: CGRect
    public init(id: Int, segments: [Segment], ink: Ink, evenOdd: Bool, whiteIsKnockout: Bool = true) {
        self.id = id; self.segments = segments; self.ink = ink; self.evenOdd = evenOdd; self.whiteIsKnockout = whiteIsKnockout
        let result = CGMutablePath()
        for segment in segments {
            switch segment {
            case .move(let p): result.move(to: p.cg)
            case .line(let p): result.addLine(to: p.cg)
            case .curve(let a, let b, let c): result.addCurve(to: c.cg, control1: a.cg, control2: b.cg)
            case .close: result.closeSubpath()
            }
        }
        path = result.copy()!
        bounds = result.boundingBoxOfPath
    }
    var isCircle: Bool {
        let b = bounds
        guard b.width > 0.5, b.height > 0.5, b.width / b.height > 0.85, b.width / b.height < 1.18 else { return false }
        let curves = segments.filter { if case .curve = $0 { return true }; return false }.count
        let lines = segments.filter { if case .line = $0 { return true }; return false }.count
        let moves = segments.filter { if case .move = $0 { return true }; return false }.count
        guard curves == 4, lines == 0, moves == 1 else { return false }
        // A head is a filled circle with a single contour, not an outlined letter.
        return path.contains(CGPoint(x: b.midX, y: b.midY), using: evenOdd ? .evenOdd : .winding)
    }
    public var pathData: String {
        segments.map {
            switch $0 {
            case .move(let p): return "M \(n(p.x)) \(n(p.y))"
            case .line(let p): return "L \(n(p.x)) \(n(p.y))"
            case .curve(let a, let b, let c): return "C \(n(a.x)) \(n(a.y)) \(n(b.x)) \(n(b.y)) \(n(c.x)) \(n(c.y))"
            case .close: return "Z"
            }
        }.joined(separator: " ")
    }
}

extension VectorShape {
    init(id: Int, path: CGPath, ink: Ink, evenOdd: Bool = false, whiteIsKnockout: Bool = true) {
        var segments: [Segment] = []
        var current = CGPoint.zero
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            func point(_ index: Int) -> Point { Point(x: element.points[index].x, y: element.points[index].y) }
            switch element.type {
            case .moveToPoint: segments.append(.move(point(0))); current = element.points[0]
            case .addLineToPoint: segments.append(.line(point(0))); current = element.points[0]
            case .addCurveToPoint: segments.append(.curve(point(0), point(1), point(2))); current = element.points[2]
            case .addQuadCurveToPoint:
                let control = element.points[0], end = element.points[1]
                segments.append(.curve(Point(x: current.x + (control.x-current.x)*2/3, y: current.y + (control.y-current.y)*2/3),
                                       Point(x: end.x + (control.x-end.x)*2/3, y: end.y + (control.y-end.y)*2/3), point(1)))
                current = end
            case .closeSubpath: segments.append(.close)
            @unknown default: break
            }
        }
        self.init(id: id, segments: segments, ink: ink, evenOdd: evenOdd, whiteIsKnockout: whiteIsKnockout)
    }
}

public struct ExportColor: Equatable, Sendable {
    public let hex: String?
    public static let original = ExportColor(value: nil)
    public static let black = ExportColor(value: "#000000")
    public static let white = ExportColor(value: "#FFFFFF")
    public static let yellow = ExportColor(value: "#FFC400")
    private init(value: String?) { hex = value }
    public init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 3 || value.count == 6,
              value.allSatisfy({ "0123456789ABCDEF".contains($0) }) else { return nil }
        if value.count == 3 { value = value.map { String(repeating: String($0), count: 2) }.joined() }
        self.hex = "#" + value
    }
    var css: String? { hex }
}

public struct Pictogram: Identifiable {
    public let id: UUID
    public let number: Int
    public let shapes: [VectorShape]
    public init(id: UUID = UUID(), number: Int, shapes: [VectorShape]) {
        self.id = id; self.number = number; self.shapes = shapes
    }
    public var bounds: CGRect { shapes.reduce(CGRect.null) { $0.union($1.bounds) } }
    public func svg(color: ExportColor = .original) -> String {
        let b = bounds.insetBy(dx: -2, dy: -2)
        var lines = ""
        var masks: [String] = []
        for shape in shapes.sorted(by: { $0.id < $1.id }) {
            if shape.whiteIsKnockout && shape.ink.isNearlyWhite {
                // White knockout paths erase previously painted content, and must stay
                // transparent when the foreground is recolored. Later paint stays on top.
                guard !lines.isEmpty else { continue }
                let mask = "cutout-\(shape.id)"
                masks.append("""
                  <mask id="\(mask)" maskUnits="userSpaceOnUse" x="\(n(b.minX))" y="\(n(b.minY))" width="\(n(b.width))" height="\(n(b.height))" style="mask-type:luminance">
                    <rect x="\(n(b.minX))" y="\(n(b.minY))" width="\(n(b.width))" height="\(n(b.height))" fill="white"/>
                    <path fill="black" fill-rule="\(shape.evenOdd ? "evenodd" : "nonzero")" d="\(shape.pathData)"/>
                  </mask>
                """)
                lines = "  <g mask=\"url(#\(mask))\">\n\(lines)\n  </g>"
            } else {
                lines += "  <path fill=\"\(color.css ?? shape.ink.css)\" fill-rule=\"\(shape.evenOdd ? "evenodd" : "nonzero")\" d=\"\(shape.pathData)\"/>\n"
            }
        }
        if !masks.isEmpty { lines = "  <defs>\n" + masks.joined(separator: "\n") + "\n  </defs>\n" + lines }
        // Only selected vector paths are serialized. No background or bitmap is added.
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="\(n(b.width))" height="\(n(b.height))" viewBox="\(n(b.minX)) \(n(b.minY)) \(n(b.width)) \(n(b.height))">
        \(lines)
        </svg>
        """
    }
}

public func artworkSVG(shapes: [VectorShape]) -> String {
    Pictogram(number: 1, shapes: shapes).svg()
}

func n(_ x: Double) -> String {
    let value = abs(x) < 0.00000005 ? 0 : x
    return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
        .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
}

final class Group {
    var usesExplicitArtworkGroups = true
    var shapes: [VectorShape] = []
    var children: [Group] = []
    var allShapes: [VectorShape] { shapes + children.flatMap(\.allShapes) }
    var descendants: [Group] { [self] + children.flatMap(\.descendants) }
}
