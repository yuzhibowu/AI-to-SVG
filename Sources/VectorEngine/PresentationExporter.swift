import Foundation
import CoreGraphics

/// Native DrawingML shapes, one selected source document per slide.
/// Keynote imports these as editable groups rather than embedded SVG images.
public enum PresentationExporter {
    static let drawing = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let presentation = "http://schemas.openxmlformats.org/presentationml/2006/main"
    static let office = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let package = "http://schemas.openxmlformats.org/package/2006/relationships"
    static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func emu(_ value: Double) -> Int { Int((value * 12700).rounded()) }
    static func transform(x: Double, y: Double, w: Double, h: Double, group: Bool = false) -> String {
        "<a:xfrm><a:off x=\"\(emu(x))\" y=\"\(emu(y))\"/><a:ext cx=\"\(emu(w))\" cy=\"\(emu(h))\"/>" + (group ? "<a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"\(emu(w))\" cy=\"\(emu(h))\"/>" : "") + "</a:xfrm>"
    }
    // Convert white knockout paint to actual holes before writing native shapes.
    static func editableShapes(_ icon: Pictogram) -> [VectorShape] {
        var painted: [VectorShape] = []
        for shape in icon.shapes.sorted(by: { $0.id < $1.id }) {
            let path = shape.path.normalized(using: shape.evenOdd ? .evenOdd : .winding)
            if shape.ink.isNearlyWhite {
                painted = painted.compactMap { previous in
                    guard previous.bounds.intersects(shape.bounds) else { return previous }
                    let cut = previous.path.subtracting(path, using: .winding)
                    return cut.isEmpty ? nil : VectorShape(id: previous.id, path: cut, ink: previous.ink)
                }
            } else { painted.append(VectorShape(id: shape.id, path: path, ink: shape.ink)) }
        }
        return painted
    }
    static func group(_ icon: Pictogram, name: String, color: ExportColor, cell: CGRect, nextID: inout Int) -> String {
        let shapes = editableShapes(icon)
        let bounds = shapes.reduce(CGRect.null) { $0.union($1.bounds) }
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return "" }
        let scale = min(cell.width / bounds.width, cell.height / bounds.height)
        let w = bounds.width * scale, h = bounds.height * scale
        nextID += 1
        var result = "<p:grpSp><p:nvGrpSpPr><p:cNvPr id=\"\(nextID)\" name=\"\(escaped(name))\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr>\(transform(x: cell.midX-w/2, y: cell.midY-h/2, w: w, h: h, group: true))</p:grpSpPr>"
        for shape in shapes {
            nextID += 1
            func point(_ p: Point) -> String { "<a:pt x=\"\(emu((p.x-bounds.minX)*scale))\" y=\"\(emu((p.y-bounds.minY)*scale))\"/>" }
            let path = shape.segments.map { segment -> String in
                switch segment {
                case .move(let p): return "<a:moveTo>\(point(p))</a:moveTo>"
                case .line(let p): return "<a:lnTo>\(point(p))</a:lnTo>"
                case .curve(let a, let b, let c): return "<a:cubicBezTo>\(point(a))\(point(b))\(point(c))</a:cubicBezTo>"
                case .close: return "<a:close/>"
                }
            }.joined()
            let hex = color.hex.map { String($0.dropFirst()) } ?? String(format: "%02X%02X%02X", Int((shape.ink.red*255).rounded()), Int((shape.ink.green*255).rounded()), Int((shape.ink.blue*255).rounded()))
            result += "<p:sp><p:nvSpPr><p:cNvPr id=\"\(nextID)\" name=\"Path \(shape.id)\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr>\(transform(x: 0, y: 0, w: w, h: h))<a:custGeom><a:avLst/><a:gdLst/><a:ahLst/><a:cxnLst/><a:rect l=\"0\" t=\"0\" r=\"r\" b=\"b\"/><a:pathLst><a:path w=\"\(emu(w))\" h=\"\(emu(h))\" stroke=\"false\">\(path)</a:path></a:pathLst></a:custGeom><a:solidFill><a:srgbClr val=\"\(hex)\"/></a:solidFill><a:ln><a:noFill/></a:ln></p:spPr></p:sp>"
        }
        return result + "</p:grpSp>"
    }
    public static func write(_ input: [SVGExportJob], color: ExportColor, to destination: URL, progress: ((SVGExportProgress) -> Void)? = nil) throws -> Int {
        let jobs = input.filter { !$0.icons.isEmpty }.enumerated().sorted {
            let order = $0.element.name.localizedStandardCompare($1.element.name)
            return order == .orderedSame ? $0.offset < $1.offset : order == .orderedAscending
        }.map(\.element)
        guard !jobs.isEmpty else { throw ConversionError.malformed("请先勾选要导出的图标。") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sticksvg-presentation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ xml: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" + xml).write(to: url, atomically: true, encoding: .utf8)
        }
        func rels(_ items: [(String, String, String)]) -> String {
            "<Relationships xmlns=\"\(package)\">" + items.map { "<Relationship Id=\"\($0.0)\" Type=\"\(office)/\($0.1)\" Target=\"\($0.2)\"/>" }.joined() + "</Relationships>"
        }
        let emptyTree = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr>\(transform(x: 0, y: 0, w: 1280, h: 720, group: true))</p:grpSpPr>"
        let namespaces = "xmlns:a=\"\(drawing)\" xmlns:r=\"\(office)\" xmlns:p=\"\(presentation)\""
        var completed = 0
        let total = jobs.reduce(0) { $0 + $1.icons.count }
        progress?(SVGExportProgress(fraction: 0, completed: 0, total: total, currentFile: "", phase: "创建可编辑形状"))
        for (index, job) in jobs.enumerated() {
            var nextID = 2
            let title = "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"主题\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr>\(transform(x: 56, y: 36, w: 1168, h: 84))<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln></p:spPr><p:txBody><a:bodyPr wrap=\"square\"><a:normAutofit/></a:bodyPr><a:lstStyle/><a:p><a:r><a:rPr lang=\"zh-CN\" sz=\"3000\" b=\"1\"><a:solidFill><a:srgbClr val=\"FFFFFF\"/></a:solidFill><a:latin typeface=\"Helvetica Neue\"/><a:ea typeface=\"PingFang SC\"/></a:rPr><a:t>\(escaped(job.name))</a:t></a:r><a:endParaRPr lang=\"zh-CN\"/></a:p></p:txBody></p:sp>"
            let icons = job.icons.sorted { $0.number < $1.number }
            let columns = icons.count <= 5 ? icons.count : Int(ceil(sqrt(Double(icons.count)*1.8)))
            let rows = Int(ceil(Double(icons.count)/Double(columns)))
            let cellW = 1168.0/Double(columns), cellH = 528.0/Double(rows)
            var content = title
            for (i, icon) in icons.enumerated() {
                let cell = CGRect(x: 56+Double(i%columns)*cellW+20, y: 140+Double(i/columns)*cellH+20, width: max(1,cellW-40), height: max(1,cellH-40))
                let name = String(format: "%@-%02d", job.name, icon.number)
                content += group(icon, name: name, color: color, cell: cell, nextID: &nextID)
                completed += 1
                progress?(SVGExportProgress(fraction: Double(completed)/Double(total)*0.8, completed: completed, total: total, currentFile: name, phase: "创建可编辑形状"))
            }
            // Use the requested black Keynote background with a white theme title.
            try write("ppt/slides/slide\(index+1).xml", "<p:sld \(namespaces)><p:cSld name=\"\(escaped(job.name))\"><p:bg><p:bgPr><a:solidFill><a:srgbClr val=\"000000\"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree>\(emptyTree)\(content)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>")
            try write("ppt/slides/_rels/slide\(index+1).xml.rels", rels([("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml")]))
        }
        try write("_rels/.rels", rels([("rId1", "officeDocument", "ppt/presentation.xml")]))
        let ids = jobs.indices.map { "<p:sldId id=\"\(256+$0)\" r:id=\"rId\($0+2)\"/>" }.joined()
        try write("ppt/presentation.xml", "<p:presentation \(namespaces)><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst><p:sldIdLst>\(ids)</p:sldIdLst><p:sldSz cx=\"16256000\" cy=\"9144000\" type=\"screen16x9\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>")
        try write("ppt/_rels/presentation.xml.rels", rels([("rId1", "slideMaster", "slideMasters/slideMaster1.xml")] + jobs.indices.map { ("rId\($0+2)", "slide", "slides/slide\($0+1).xml") }))
        let map = "<p:clrMap accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" bg1=\"lt1\" bg2=\"lt2\" folHlink=\"folHlink\" hlink=\"hlink\" tx1=\"dk1\" tx2=\"dk2\"/>"
        try write("ppt/slideMasters/slideMaster1.xml", "<p:sldMaster \(namespaces)><p:cSld><p:spTree>\(emptyTree)</p:spTree></p:cSld>\(map)<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>")
        try write("ppt/slideMasters/_rels/slideMaster1.xml.rels", rels([("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"), ("rId2", "theme", "../theme/theme1.xml")]))
        try write("ppt/slideLayouts/slideLayout1.xml", "<p:sldLayout \(namespaces) type=\"blank\" preserve=\"1\"><p:cSld name=\"Blank\"><p:spTree>\(emptyTree)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>")
        try write("ppt/slideLayouts/_rels/slideLayout1.xml.rels", rels([("rId1", "slideMaster", "../slideMasters/slideMaster1.xml")]))
        let colors = [("dk1","202020"),("lt1","FFFFFF"),("dk2","404040"),("lt2","F0F1F2"),("accent1","2D8647"),("accent2","FFC400"),("accent3","2979D6"),("accent4","E33E41"),("accent5","9250DD"),("accent6","F58220"),("hlink","0066CC"),("folHlink","663399")].map { "<a:\($0.0)><a:srgbClr val=\"\($0.1)\"/></a:\($0.0)>" }.joined()
        let fills = String(repeating: "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>", count: 3)
        let lines = String(repeating: "<a:ln w=\"12700\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:prstDash val=\"solid\"/></a:ln>", count: 3)
        let font = "<a:latin typeface=\"Helvetica Neue\"/><a:ea typeface=\"PingFang SC\"/><a:cs typeface=\"Arial\"/>"
        try write("ppt/theme/theme1.xml", "<a:theme xmlns:a=\"\(drawing)\" name=\"AI转SVG\"><a:themeElements><a:clrScheme name=\"AI转SVG\">\(colors)</a:clrScheme><a:fontScheme name=\"System\"><a:majorFont>\(font)</a:majorFont><a:minorFont>\(font)</a:minorFont></a:fontScheme><a:fmtScheme name=\"Simple\"><a:fillStyleLst>\(fills)</a:fillStyleLst><a:lnStyleLst>\(lines)</a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst>\(fills)</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>")
        var parts = [("/ppt/presentation.xml","presentation"),("/ppt/slideMasters/slideMaster1.xml","slideMaster"),("/ppt/slideLayouts/slideLayout1.xml","slideLayout")]
        parts += jobs.indices.map { ("/ppt/slides/slide\($0+1).xml", "slide") }
        let overrides = parts.map { "<Override PartName=\"\($0.0)\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.\($0.1)+xml\"/>" }.joined()
        try write("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>\(overrides)<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/></Types>")
        try ZIPWriter.write(directory: root, to: destination, includeRoot: false)
        return jobs.count
    }
}
