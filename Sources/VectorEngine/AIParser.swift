import Foundation
import CoreGraphics

public enum ConversionError: LocalizedError {
    case unsupported(String), malformed(String), noPeople
    public var errorDescription: String? {
        switch self {
        case .unsupported(let detail): return detail
        case .malformed(let detail): return "文件内容无法完整解析：\(detail)"
        case .noPeople: return "未识别到人物分组。当前版本适用于保留分组的 Human Pictogram 旧版 AI 素材。"
        }
    }
}

public struct Analysis {
    public let pictograms: [Pictogram]
    public let totalShapes: Int
    public let shapes: [VectorShape]
}

enum Token {
    case number(Double), word(String), metadata, bracket
}

struct Tokenizer {
    let bytes: [UInt8]
    var index = 0
    mutating func next() throws -> Token? {
        while index < bytes.count {
            let c = bytes[index]
            if c <= 32 { index += 1; continue }
            if c == 37 { // A PostScript comment ends at either CR or LF.
                while index < bytes.count && bytes[index] != 10 && bytes[index] != 13 { index += 1 }
                continue
            }
            if c == 40 {
                index += 1
                var depth = 1
                while index < bytes.count && depth > 0 {
                    let ch = bytes[index]; index += 1
                    if ch == 92 { if index < bytes.count { index += 1 }; continue }
                    if ch == 40 { depth += 1 }; if ch == 41 { depth -= 1 }
                }
                guard depth == 0 else { throw ConversionError.malformed("字符串未结束") }
                return .metadata
            }
            if c == 91 || c == 93 { index += 1; return .bracket }
            let start = index
            while index < bytes.count && bytes[index] > 32 && ![37, 40, 41, 91, 93].contains(bytes[index]) { index += 1 }
            guard index > start else { throw ConversionError.malformed("意外的符号") }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            if let number = Double(text) {
                guard number.isFinite && abs(number) <= 10_000_000 else { throw ConversionError.malformed("坐标超出支持范围") }
                return .number(number)
            }
            if text.hasPrefix("/") { return .metadata }
            return .word(text)
        }
        return nil
    }
}

public struct AIParser {
    public init() {}
    public func analyze(url: URL) throws -> Analysis {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= 50_000_000 else {
            throw ConversionError.unsupported("文件超过 50 MB，暂不支持处理。")
        }
        return try analyze(data: Data(contentsOf: url))
    }

    public func analyze(data: Data) throws -> Analysis {
        let root = try parseDrawing(data: data)
        let shapes = root.allShapes.sorted { $0.id < $1.id }
        return Analysis(pictograms: findPeople(in: root), totalShapes: shapes.count, shapes: shapes)
    }

    func parseDrawing(data: Data) throws -> Group {
        guard data.count <= 50_000_000 else { throw ConversionError.unsupported("文件超过 50 MB，暂不支持处理。") }
        if data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil {
            return try PDFParser.parse(data: data)
        }
        guard data.starts(with: Data("%!PS-Adobe".utf8)),
              let text = String(data: data, encoding: .isoLatin1),
              text.contains("Adobe Illustrator"),
              let bodyStart = text.range(of: "%%EndSetup"),
              let bodyEnd = text.range(of: "%%PageTrailer", range: bodyStart.upperBound..<text.endIndex) else {
            throw ConversionError.unsupported("不是当前支持的旧版 Illustrator AI 素材。")
        }
        let body = String(text[bodyStart.upperBound..<bodyEnd.lowerBound])
        let root = Group()
        var stack: [Group] = [root]
        var operands: [Double] = []
        var metadataOperands = false
        var segments: [Segment] = []
        var current = Point(x: 0, y: 0)
        var start = current
        var ink = Ink(red: 0, green: 0, blue: 0)
        var strokeInk = ink
        var lineWidth: CGFloat = 1
        var lineCap: CGLineCap = .butt
        var lineJoin: CGLineJoin = .miter
        var miterLimit: CGFloat = 10
        var dash: [CGFloat] = []
        var dashPhase: CGFloat = 0
        var paintFill = true
        var paintStroke = false
        var evenOdd = false
        var compoundDepth = 0
        var shapeID = 0
        var tokenCount = 0
        var lexer = Tokenizer(bytes: Array(body.utf8))
        func values(_ count: Int) throws -> [Double] {
            guard operands.count == count, !metadataOperands else { throw ConversionError.malformed("绘图参数数量不正确") }
            return operands
        }
        func point(_ x: Double, _ y: Double) -> Point { Point(x: x, y: -y) }
        func emit() throws {
            guard !segments.isEmpty else { throw ConversionError.malformed("空的填充路径") }
            let shape = VectorShape(id: shapeID, segments: segments, ink: ink, evenOdd: evenOdd)
            if paintFill {
                if !shape.bounds.isEmpty { stack.last!.shapes.append(shape) }
                shapeID += 1
            }
            if paintStroke {
                let dashed = dash.isEmpty ? shape.path : shape.path.copy(dashingWithPhase: dashPhase, lengths: dash)
                let outline = dashed.copy(strokingWithWidth: lineWidth == 0 ? 0.25 : lineWidth, lineCap: lineCap, lineJoin: lineJoin, miterLimit: miterLimit)
                let stroke = VectorShape(id: shapeID, path: outline, ink: strokeInk)
                if !stroke.bounds.isEmpty { stack.last!.shapes.append(stroke) }
                shapeID += 1
            }
            guard shapeID <= 200_000 else { throw ConversionError.unsupported("文件中的图形数量过多。") }
            segments.removeAll(keepingCapacity: true)
        }
        while let token = try lexer.next() {
            tokenCount += 1
            if tokenCount % 1024 == 0 && Task.isCancelled { throw CancellationError() }
            switch token {
            case .number(let v):
                operands.append(v)
                guard operands.count < 256 else { throw ConversionError.malformed("参数数量过多") }
            case .metadata, .bracket: metadataOperands = true
            case .word(let op):
                switch op {
                case "m":
                    let v = try values(2); current = point(v[0], v[1]); start = current; segments.append(.move(current))
                case "l", "L":
                    guard !segments.isEmpty else { throw ConversionError.malformed("缺少路径起点") }
                    let v = try values(2); current = point(v[0], v[1]); segments.append(.line(current))
                case "c", "C":
                    guard !segments.isEmpty else { throw ConversionError.malformed("缺少路径起点") }
                    let v = try values(6); current = point(v[4], v[5]); segments.append(.curve(point(v[0], v[1]), point(v[2], v[3]), current))
                case "v", "V":
                    guard !segments.isEmpty else { throw ConversionError.malformed("缺少路径起点") }
                    let v = try values(4); let endpoint = point(v[2], v[3]); segments.append(.curve(current, point(v[0], v[1]), endpoint)); current = endpoint
                case "y", "Y":
                    guard !segments.isEmpty else { throw ConversionError.malformed("缺少路径起点") }
                    let v = try values(4); let endpoint = point(v[2], v[3]); segments.append(.curve(point(v[0], v[1]), endpoint, endpoint)); current = endpoint
                case "h": segments.append(.close); current = start
                case "f", "F", "s", "S", "b", "B":
                    if ["f", "s", "b"].contains(op) { segments.append(.close); current = start }
                    paintFill = ["f", "F", "b", "B"].contains(op)
                    paintStroke = ["s", "S", "b", "B"].contains(op)
                    if compoundDepth == 0 { try emit() }
                case "*u":
                    guard compoundDepth > 0 || segments.isEmpty else { throw ConversionError.malformed("复合路径起点异常") }
                    compoundDepth += 1
                case "*U":
                    guard compoundDepth > 0 else { throw ConversionError.malformed("复合路径未配对") }
                    compoundDepth -= 1
                    if compoundDepth == 0 { try emit() }
                case "u":
                    let group = Group(); stack.last!.children.append(group); stack.append(group)
                    guard stack.count <= 256 else { throw ConversionError.malformed("分组嵌套过深") }
                case "U":
                    guard stack.count > 1 else { throw ConversionError.malformed("分组未配对") }; stack.removeLast()
                case "k", "K":
                    let v = try values(4)
                    guard v.allSatisfy({ (0...1).contains($0) }) else { throw ConversionError.malformed("颜色数值超出范围") }
                    let color = Ink.cmyk(v[0], v[1], v[2], v[3])
                    if op == "k" { ink = color } else { strokeInk = color }
                case "g", "G":
                    let v = try values(1)[0]; guard (0...1).contains(v) else { throw ConversionError.malformed("颜色数值超出范围") }
                    let color = Ink(red: v, green: v, blue: v)
                    if op == "g" { ink = color } else { strokeInk = color }
                case "Xa", "XA":
                    let v = try values(3)
                    guard v.allSatisfy({ (0...1).contains($0) }) else { throw ConversionError.malformed("颜色数值超出范围") }
                    let color = Ink(red: v[0], green: v[1], blue: v[2])
                    if op == "Xa" { ink = color } else { strokeInk = color }
                case "w":
                    let v = try values(1)[0]
                    guard v >= 0 else { throw ConversionError.malformed("描边宽度为负数") }
                    lineWidth = v
                case "J", "j":
                    let v = try values(1)[0]
                    guard [0.0, 1.0, 2.0].contains(v) else { throw ConversionError.malformed("描边端点或连接样式无效") }
                    if op == "J" { lineCap = CGLineCap(rawValue: Int32(v))! }
                    else { lineJoin = CGLineJoin(rawValue: Int32(v))! }
                case "M": miterLimit = max(1, try values(1)[0])
                case "d":
                    guard let phase = operands.last, operands.dropLast().allSatisfy({ $0 >= 0 }), operands.count == 1 || operands.dropLast().contains(where: { $0 > 0 }) else { throw ConversionError.malformed("虚线参数无效") }
                    dash = operands.dropLast().map { CGFloat($0) }; dashPhase = phase
                case "XR": evenOdd = try values(1)[0] != 0
                case "n", "N":
                    guard compoundDepth == 0 else { throw ConversionError.unsupported("暂不支持这种复合剪切路径。") }
                    segments.removeAll()
                case "Lb", "LB", "Ln", "A", "D", "Ap", "XT", "O", "R", "i", "H":
                    // Group/layer metadata, stroke settings and point-editing flags do not alter filled geometry.
                    break
                default:
                    throw ConversionError.unsupported("素材包含当前未支持的绘图内容（\(op)），没有导出不完整的结果。")
                }
                operands.removeAll(keepingCapacity: true); metadataOperands = false
            }
            guard segments.count <= 200_000 else { throw ConversionError.unsupported("单个路径过于复杂，暂不支持处理。") }
        }
        guard stack.count == 1, compoundDepth == 0, segments.isEmpty, operands.isEmpty else {
            throw ConversionError.malformed("路径或分组未结束")
        }
        return root
    }
}
