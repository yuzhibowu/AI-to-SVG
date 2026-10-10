import SwiftUI
import VectorEngine

struct ManualEditor: View {
    let request: EditorRequest
    let onSave: (Set<Int>) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Int>
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
    private var shapes: [VectorShape] {
        if request.mode.isSplit { return request.document.icons.first { $0.id == request.mode.targetID }?.shapes ?? [] }
        return request.document.shapes
    }
    private var locked: Set<Int> {
        Set(request.document.icons.filter { $0.id != request.mode.targetID }.flatMap { $0.shapes.map(\.id) })
    }
    private var available: [VectorShape] { shapes.filter { !locked.contains($0.id) } }
    private var chosen: [VectorShape] { available.filter { selected.contains($0.id) } }
    init(request: EditorRequest, onSave: @escaping (Set<Int>) -> Bool) {
        self.request = request; self.onSave = onSave
        let ids = request.mode.isSplit ? [] : request.document.icons.first { $0.id == request.mode.targetID }?.shapes.map(\.id) ?? []
        _selected = State(initialValue: Set(ids))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(request.mode.isSplit ? "拆分图标" : request.mode.targetID == nil ? "补选遗漏人物" : "编辑人物路径").font(.title2.bold())
            Text(request.mode.isSplit ? "框选要分出的一个完整人物，记得包含头部和身体。其余路径留在原图标中。" : "点选路径，或拖动框选完整人物。已属于其他图标的路径显示为淡色；需要调整时可先合并图标。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 18) {
                GeometryReader { geometry in
                    let bounds = shapes.reduce(CGRect.null) { $0.union($1.bounds) }.insetBy(dx: -10, dy: -10)
                    let scale = min(geometry.size.width / max(1, bounds.width), geometry.size.height / max(1, bounds.height))
                    let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                        tx: (geometry.size.width-bounds.width*scale)/2-bounds.minX*scale,
                        ty: (geometry.size.height-bounds.height*scale)/2-bounds.minY*scale)
                    ZStack {
                        TransparencyGrid()
                        Canvas { context, _ in
                            for shape in shapes {
                                let path = Path(shape.path).applying(transform)
                                let selectable = !locked.contains(shape.id)
                                let ink = Color(red: shape.ink.red, green: shape.ink.green, blue: shape.ink.blue).opacity(selectable ? 0.85 : 0.2)
                                context.fill(path, with: .color(ink), style: FillStyle(eoFill: shape.evenOdd))
                                if selected.contains(shape.id) { context.stroke(path, with: .color(.accentColor), lineWidth: 2) }
                            }
                            if let start = dragStart, let end = dragEnd {
                                let rect = rectangle(start, end)
                                context.fill(Path(rect), with: .color(.accentColor.opacity(0.12)))
                                context.stroke(Path(rect), with: .color(.accentColor), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                            }
                        }
                    }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in dragStart = value.startLocation; dragEnd = value.location }
                        .onEnded { value in
                            let inverse = transform.inverted()
                            if hypot(value.translation.width, value.translation.height) < 4 {
                                let point = value.location.applying(inverse)
                                if let hit = available.reversed().first(where: { $0.path.contains(point, using: $0.evenOdd ? .evenOdd : .winding) }) {
                                    if selected.contains(hit.id) { selected.remove(hit.id) } else { selected.insert(hit.id) }
                                }
                            } else {
                                let rect = rectangle(value.startLocation.applying(inverse), value.location.applying(inverse))
                                selected.formUnion(PictogramEdits.select(in: rect, shapes: available))
                            }
                            dragStart = nil; dragEnd = nil
                        })
                }.clipShape(RoundedRectangle(cornerRadius: 10)).frame(minWidth: 510)
                VStack(alignment: .leading, spacing: 12) {
                    Text("选中 \(chosen.count) 条矢量路径").font(.system(size: 12, weight: .medium))
                    ZStack {
                        TransparencyGrid()
                        if !chosen.isEmpty { SVGPreview(svg: artworkSVG(shapes: chosen)).padding(20).allowsHitTesting(false) }
                    }.clipShape(RoundedRectangle(cornerRadius: 10))
                    Text("右侧是保存结果，棋盘格不会导出。").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("清除选择") { selected.removeAll() }
                }.frame(width: 220)
            }
            HStack {
                Text("修改保留原始矢量路径，可以撤销。").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.mode.isSplit ? "分出新图标" : "保存人物") { if onSave(selected) { dismiss() } }
                    .buttonStyle(.borderedProminent).disabled(chosen.isEmpty || (request.mode.isSplit && chosen.count == available.count)).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 810, height: 590)
    }
    private func rectangle(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x-b.x), height: abs(a.y-b.y))
    }
}
