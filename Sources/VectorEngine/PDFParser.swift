import Foundation
import CoreGraphics

/// Reads compatible PDF-backed AI path artwork with the system PDF scanner.
/// Unsupported painting features fail explicitly rather than exporting missing artwork.
enum PDFParser {
    static func parse(data: Data) throws -> Group {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              !document.isEncrypted, document.numberOfPages == 1, let page = document.page(at: 1), page.rotationAngle == 0 else {
            throw ConversionError.unsupported("PDF 型 AI 需要是未加密的单页矢量素材。")
        }
        let context = PDFPathContext(page: page)
        guard let table = CGPDFOperatorTableCreate() else { throw ConversionError.malformed("无法建立 PDF 解析器") }
        defer { CGPDFOperatorTableRelease(table) }
        let callbacks: [(String, CGPDFOperatorCallback)] = [
            ("m", { s,p in pdfOperation(s,p,"m") }), ("l", { s,p in pdfOperation(s,p,"l") }),
            ("c", { s,p in pdfOperation(s,p,"c") }), ("v", { s,p in pdfOperation(s,p,"v") }),
            ("y", { s,p in pdfOperation(s,p,"y") }), ("h", { s,p in pdfOperation(s,p,"h") }),
            ("re", { s,p in pdfOperation(s,p,"re") }), ("f", { s,p in pdfOperation(s,p,"f") }),
            ("F", { s,p in pdfOperation(s,p,"f") }), ("f*", { s,p in pdfOperation(s,p,"f*") }),
            ("n", { s,p in pdfOperation(s,p,"n") }), ("q", { s,p in pdfOperation(s,p,"q") }),
            ("Q", { s,p in pdfOperation(s,p,"Q") }), ("cm", { s,p in pdfOperation(s,p,"cm") }),
            ("k", { s,p in pdfOperation(s,p,"k") }), ("rg", { s,p in pdfOperation(s,p,"rg") }),
            ("g", { s,p in pdfOperation(s,p,"g") }), ("W", { s,p in pdfOperation(s,p,"W") }),
            ("W*", { s,p in pdfOperation(s,p,"W") }), ("gs", { s,p in pdfOperation(s,p,"gs") }),
            ("BDC", { s,p in pdfOperation(s,p,"BDC") }), ("BMC", { s,p in pdfOperation(s,p,"BMC") }),
            ("EMC", { s,p in pdfOperation(s,p,"EMC") }), ("ri", { s,p in pdfOperation(s,p,"ri") }),
            ("i", { s,p in pdfOperation(s,p,"i") })
        ]
        for (name, callback) in callbacks { CGPDFOperatorTableSetCallback(table, name, callback) }
        // These standard PDF operators change visible content and cannot be silently skipped.
        for name in ["S","s","B","B*","b","b*","Do","sh","BI","EI","BT","ET","Tj","TJ","'","\"",
                     "CS","cs","SC","sc","SCN","scn","K","RG","G","w","J","j","M","d","Tr","Tc","Tw","Tz","TL","Tf","Ts","Td","TD","Tm","T*","BX","EX"] {
            CGPDFOperatorTableSetCallback(table, name) { _, pointer in
                guard let pointer else { return }
                let context = Unmanaged<PDFPathContext>.fromOpaque(pointer).takeUnretainedValue()
                if context.error == nil { context.error = ConversionError.unsupported("PDF 型 AI 包含暂未支持的描边、文字、图片或特殊效果，未导出不完整结果。") }
            }
        }
        let stream = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(stream) }
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(context).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        let complete = CGPDFScannerScan(scanner)
        if let error = context.error { throw error }
        guard complete, context.saved.isEmpty, context.path.isEmpty, context.markedDepth == 0 else {
            throw ConversionError.malformed("PDF 绘图状态未结束")
        }
        return context.root
    }
}

private func pdfOperation(_ scanner: CGPDFScannerRef?, _ pointer: UnsafeMutableRawPointer?, _ op: String) {
    guard let scanner, let pointer else { return }
    let context = Unmanaged<PDFPathContext>.fromOpaque(pointer).takeUnretainedValue()
    guard context.error == nil else { return }
    do { try context.handle(op, scanner: scanner) } catch { context.error = error }
}

private final class PDFPathContext {
    struct State { var transform = CGAffineTransform.identity; var ink = Ink(red: 0, green: 0, blue: 0) }
    let root = Group()
    let page: CGPDFPage
    var state = State()
    var saved: [State] = []
    var groups: [Group] = []
    var path = CGMutablePath()
    var pendingClip = false
    var markedDepth = 0
    var error: Error?
    var count = 0
    var segmentCount = 0
    init(page: CGPDFPage) { self.page = page; root.usesExplicitArtworkGroups = false; groups = [root] }

    func handle(_ op: String, scanner: CGPDFScannerRef) throws {
        count += 1
        if count % 1024 == 0, Task.isCancelled { throw CancellationError() }
        func numbers(_ count: Int) throws -> [CGFloat] {
            var values = Array(repeating: CGFloat.zero, count: count)
            for i in (0..<count).reversed() {
                var number: CGPDFReal = 0
                guard CGPDFScannerPopNumber(scanner, &number), number.isFinite, abs(number) <= 10_000_000 else {
                    throw ConversionError.malformed("PDF 绘图参数无效")
                }
                values[i] = CGFloat(number)
            }
            return values
        }
        func name() throws -> String {
            var value: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &value), let value else { throw ConversionError.malformed("PDF 名称参数无效") }
            return String(cString: value)
        }
        func transformedPath() -> CGPath {
            let box = page.getBoxRect(.mediaBox)
            var transform = state.transform.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: box.maxY))
            return path.copy(using: &transform)!
        }
        switch op {
        case "m": let v = try numbers(2); path.move(to: CGPoint(x: v[0], y: v[1]))
        case "l":
            guard !path.isEmpty else { throw ConversionError.malformed("PDF 路径缺少起点") }
            let v = try numbers(2); path.addLine(to: CGPoint(x: v[0], y: v[1]))
        case "c":
            guard !path.isEmpty else { throw ConversionError.malformed("PDF 曲线缺少起点") }
            let v = try numbers(6)
            path.addCurve(to: CGPoint(x: v[4], y: v[5]), control1: CGPoint(x: v[0], y: v[1]), control2: CGPoint(x: v[2], y: v[3]))
        case "v", "y":
            guard !path.isEmpty else { throw ConversionError.malformed("PDF 曲线缺少起点") }
            let v = try numbers(4), end = CGPoint(x: v[2], y: v[3])
            path.addCurve(to: end, control1: op == "v" ? path.currentPoint : CGPoint(x: v[0], y: v[1]), control2: op == "v" ? CGPoint(x: v[0], y: v[1]) : end)
        case "h": path.closeSubpath()
        case "re":
            let v = try numbers(4)
            // Negative rectangle dimensions must preserve the contour direction for holes.
            path.move(to: CGPoint(x: v[0], y: v[1])); path.addLine(to: CGPoint(x: v[0]+v[2], y: v[1]))
            path.addLine(to: CGPoint(x: v[0]+v[2], y: v[1]+v[3])); path.addLine(to: CGPoint(x: v[0], y: v[1]+v[3])); path.closeSubpath()
        case "f", "f*":
            guard !path.isEmpty, !pendingClip else { throw ConversionError.unsupported("PDF 包含不支持的填充剪切组合。") }
            let shape = VectorShape(id: root.allShapes.count, path: transformedPath(), ink: state.ink, evenOdd: op == "f*")
            if !shape.bounds.isEmpty { groups.last!.shapes.append(shape) }
            guard root.allShapes.count <= 200_000 else { throw ConversionError.unsupported("PDF 图形数量过多。") }
            path = CGMutablePath(); segmentCount = 0
        case "n": path = CGMutablePath(); segmentCount = 0; pendingClip = false
        case "W":
            let candidate = transformedPath()
            let box = page.getBoxRect(.mediaBox), bounds = candidate.boundingBoxOfPath
            var lines = 0, curves = 0
            candidate.applyWithBlock { p in
                switch p.pointee.type { case .addLineToPoint: lines += 1; case .addCurveToPoint, .addQuadCurveToPoint: curves += 1; default: break }
            }
            guard curves == 0, lines == 3, abs(bounds.width-box.width) < 0.02, abs(bounds.height-box.height) < 0.02,
                  abs(bounds.minX-box.minX) < 0.02, abs(bounds.minY) < 0.02,
                  candidate.contains(CGPoint(x: bounds.midX, y: bounds.midY)) else {
                throw ConversionError.unsupported("PDF 型 AI 使用了局部剪切蒙版，暂不支持。")
            }
            pendingClip = true
        case "q":
            saved.append(state)
            let group = Group(); groups.last!.children.append(group); groups.append(group)
            guard saved.count <= 256 else { throw ConversionError.malformed("PDF 分组过深") }
        case "Q":
            guard let previous = saved.popLast(), groups.count > 1 else { throw ConversionError.malformed("PDF 状态未配对") }
            state = previous; groups.removeLast()
        case "cm":
            let v = try numbers(6)
            state.transform = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(state.transform)
        case "k", "rg", "g":
            let v = try numbers(op == "k" ? 4 : op == "rg" ? 3 : 1)
            guard v.allSatisfy({ (0...1).contains($0) }) else { throw ConversionError.malformed("PDF 颜色超出范围") }
            if op == "k" { state.ink = .cmyk(v[0], v[1], v[2], v[3]) }
            else if op == "rg" { state.ink = Ink(red: v[0], green: v[1], blue: v[2]) }
            else { state.ink = Ink(red: v[0], green: v[0], blue: v[0]) }
        case "gs":
            let resourceName = try name()
            let stream = CGPDFScannerGetContentStream(scanner)
            guard let object = CGPDFContentStreamGetResource(stream, "ExtGState", resourceName) else { throw ConversionError.malformed("PDF 图形资源缺失") }
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else { throw ConversionError.malformed("PDF 图形状态无效") }
            for key in ["ca", "CA"] {
                var opacity: CGPDFReal = 1
                if CGPDFDictionaryGetNumber(dictionary, key, &opacity), opacity != 1 { throw ConversionError.unsupported("PDF 型 AI 使用了透明度效果，暂不支持。") }
            }
            for (key, accepted) in [("BM", "Normal"), ("SMask", "None")] {
                var object: CGPDFObjectRef?
                if CGPDFDictionaryGetObject(dictionary, key, &object), let object {
                    var value: UnsafePointer<CChar>?
                    guard CGPDFObjectGetValue(object, .name, &value), let value, String(cString: value) == accepted else {
                        throw ConversionError.unsupported("PDF 型 AI 使用了混合或遮罩效果，暂不支持。")
                    }
                }
            }
        case "BDC":
            var object: CGPDFObjectRef?
            guard CGPDFScannerPopObject(scanner, &object) else { throw ConversionError.malformed("PDF 标记缺少参数") }
            _ = try name(); markedDepth += 1
        case "BMC": _ = try name(); markedDepth += 1
        case "EMC":
            guard markedDepth > 0 else { throw ConversionError.malformed("PDF 标记未配对") }; markedDepth -= 1
        case "ri": _ = try name()
        case "i": _ = try numbers(1)
        default: throw ConversionError.unsupported("PDF 绘图指令未支持：\(op)")
        }
        segmentCount += 1
        guard segmentCount <= 200_000 else { throw ConversionError.unsupported("PDF 路径过于复杂。") }
    }
}
