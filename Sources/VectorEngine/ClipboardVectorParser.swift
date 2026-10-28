import Foundation
import CoreGraphics

/// Reads Apple's public content-language representation without decoding private iWork archives.
public enum ClipboardVectorParser {
    public static let appleType = "com.apple.apps.content-language.canvas-object-1.0"
    public static func parseApple(_ data: Data) throws -> [Pictogram] {
        guard data.count <= 50_000_000,
              let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], !objects.isEmpty else {
            throw ConversionError.unsupported("剪贴板中的苹果对象数据无效或过大。")
        }
        var nextID = 0
        func number(_ object: [String: Any], _ key: String, default fallback: Double = 0) throws -> Double {
            guard let value = object[key] else { return fallback }
            guard let n = value as? NSNumber, n.doubleValue.isFinite, abs(n.doubleValue) < 10_000_000 else {
                throw ConversionError.malformed("剪贴板坐标无效")
            }
            return n.doubleValue
        }
        func read(_ object: [String: Any], depth: Int = 0) throws -> [VectorShape] {
            guard depth < 64, nextID < 200_000 else { throw ConversionError.unsupported("剪贴板对象过于复杂。") }
            let content = object["shape"] as? [String: Any] ?? object
            let geometry = content["geometry"] as? [String: Any] ?? [:]
            let position = geometry["position"] as? [String: Any] ?? [:]
            let size = geometry["size"] as? [String: Any] ?? [:]
            let x = try number(position, "x"), y = try number(position, "y")
            let width = try number(size, "width"), height = try number(size, "height")
            let angle = try number(geometry, "angle")
            let flip = geometry["flip_horizontally"] as? Bool ?? false
            if let children = object["children"] as? [[String: Any]] {
                // Apple child positions are canvas coordinates, not offsets from the group.
                // Rotated groups need additional source-coordinate semantics; reject rather than distort.
                guard angle == 0, !flip else { throw ConversionError.unsupported("暂不支持旋转或翻转的成组对象。请先在原应用中拆分，再复制。") }
                return try children.flatMap { try read($0, depth: depth + 1) }
            }
            if let text = content["text"] as? [String: Any], let runs = text["attributed_string"] as? [Any] {
                let visible = runs.compactMap { $0 as? String }.joined().replacingOccurrences(of: "\u{200B}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard visible.isEmpty else { throw ConversionError.unsupported("复制的对象包含文字。当前剪贴板转换支持矢量形状，请单独复制形状；不会静默丢弃文字。") }
            }
            guard (content["stroke"] == nil || content["stroke"] as? String == "empty"),
                  ["none", "empty"].contains(content["head"] as? String ?? (content["head"] == nil ? "none" : "unsupported")),
                  ["none", "empty"].contains(content["tail"] as? String ?? (content["tail"] == nil ? "none" : "unsupported")) else {
                throw ConversionError.unsupported("此对象包含暂未支持的描边或箭头，未导出不完整结果。")
            }
            guard let pathInfo = content["path"] as? [String: Any],
                  let bezier = pathInfo["bezier"] as? [String: Any], let pathText = bezier["path"] as? String,
                  let fill = content["fill"] as? [String: Any], let color = fill["color"] as? [String: Any],
                  let rgba = color["rgba"] as? [String: Any] else {
                throw ConversionError.unsupported("当前支持带纯色填充的贝塞尔矢量形状；图片、渐变及其他苹果对象暂不支持。")
            }
            let alpha = try number(rgba, "alpha", default: 1)
            guard alpha == 1 else { throw ConversionError.unsupported("此形状包含透明度效果，暂不支持完整转换。") }
            let r = try number(rgba, "red"), g = try number(rgba, "green"), b = try number(rgba, "blue")
            guard [r,g,b].allSatisfy({ (0...1).contains($0) }) else { throw ConversionError.malformed("剪贴板颜色无效") }
            var transform = CGAffineTransform(translationX: -width/2, y: -height/2)
            transform = transform.concatenating(CGAffineTransform(scaleX: flip ? -1 : 1, y: 1))
            transform = transform.concatenating(CGAffineTransform(rotationAngle: angle))
            transform = transform.concatenating(CGAffineTransform(translationX: x+width/2, y: y+height/2))
            let path = try parsePath(pathText)
            guard let transformed = path.copy(using: &transform), !transformed.boundingBoxOfPath.isEmpty else { throw ConversionError.malformed("剪贴板路径为空") }
            nextID += 1
            return [VectorShape(id: nextID, path: transformed, ink: Ink(red: r, green: g, blue: b), whiteIsKnockout: false)]
        }
        return try objects.enumerated().map { index, object in
            let shapes = try read(object)
            guard !shapes.isEmpty else { throw ConversionError.unsupported("剪贴板对象没有可转换的路径。") }
            return Pictogram(number: index+1, shapes: shapes)
        }
    }
    public static func parsePDF(_ data: Data) throws -> [Pictogram] {
        let shapes = try PDFParser.parse(data: data).allShapes.sorted { $0.id < $1.id }.map {
            VectorShape(id: $0.id, segments: $0.segments, ink: $0.ink, evenOdd: $0.evenOdd, whiteIsKnockout: false)
        }
        guard !shapes.isEmpty else { throw ConversionError.unsupported("剪贴板 PDF 中没有矢量路径。") }
        return [Pictogram(number: 1, shapes: shapes)]
    }
    static func parsePath(_ text: String) throws -> CGPath {
        guard text.count <= 10_000_000 else { throw ConversionError.unsupported("剪贴板路径过大。") }
        let pattern = #"[A-Za-z]|[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?"#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let tokens = matches.map { ns.substring(with: $0.range) }
        // Reject unrecognized syntax rather than silently skipping it.
        var end = 0
        for match in matches {
            let gap = ns.substring(with: NSRange(location: end, length: match.range.location-end))
            guard gap.allSatisfy({ $0.isWhitespace || $0 == "," }) else { throw ConversionError.malformed("剪贴板路径语法无效") }
            end = NSMaxRange(match.range)
        }
        guard ns.substring(from: end).allSatisfy({ $0.isWhitespace }) else { throw ConversionError.malformed("剪贴板路径语法无效") }
        let path = CGMutablePath(); var i = 0; var command = ""
        func value() throws -> CGFloat {
            guard i < tokens.count, let v = Double(tokens[i]), v.isFinite, abs(v) < 10_000_000 else { throw ConversionError.malformed("剪贴板路径参数无效") }
            i += 1; return CGFloat(v)
        }
        func point() throws -> CGPoint { CGPoint(x: try value(), y: try value()) }
        while i < tokens.count {
            if tokens[i].first?.isLetter == true { command = tokens[i]; i += 1 }
            switch command {
            case "M": path.move(to: try point()); command = "L"
            case "L": guard !path.isEmpty else { throw ConversionError.malformed("路径缺少起点") }; path.addLine(to: try point())
            case "C": let a = try point(), b = try point(), c = try point(); guard !path.isEmpty else { throw ConversionError.malformed("路径缺少起点") }; path.addCurve(to: c, control1: a, control2: b)
            case "Q": let a = try point(), b = try point(); guard !path.isEmpty else { throw ConversionError.malformed("路径缺少起点") }; path.addQuadCurve(to: b, control: a)
            case "H": path.addLine(to: CGPoint(x: try value(), y: path.currentPoint.y))
            case "V": path.addLine(to: CGPoint(x: path.currentPoint.x, y: try value()))
            case "Z", "z": path.closeSubpath(); command = ""
            default: throw ConversionError.unsupported("暂不支持这类剪贴板路径指令：\(command)")
            }
        }
        return path
    }
}
