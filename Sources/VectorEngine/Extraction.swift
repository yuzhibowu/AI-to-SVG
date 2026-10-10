import Foundation
import CoreGraphics

func findPeople(in root: Group) -> [Pictogram] {
    if let grid = TemplateGrid.detect(in: root.allShapes) {
        return grid.extract(root)
    }
    var candidates: [[VectorShape]] = []
    for group in root.descendants {
        let shapes = group.allShapes.filter { !$0.ink.isNearlyWhite }
        guard shapes.count >= 2 else { continue }
        let bounds = shapes.reduce(CGRect.null) { $0.union($1.bounds) }
        let heads = shapes.filter { shape in
            let h = shape.bounds
            let span = max(bounds.width, bounds.height)
            return shape.isCircle && h.height < span * 0.40 && h.height > span * 0.06
        }
        guard let head = heads.max(by: { $0.bounds.height < $1.bounds.height }),
              max(bounds.width, bounds.height) >= head.bounds.height * 2.5,
              min(bounds.width, bounds.height) >= head.bounds.width * 0.85,
              max(bounds.width, bounds.height) < head.bounds.height * 15 else { continue }
        candidates.append(shapes)
    }
    // Missing Illustrator groups are recoverable for simple figures. Attach each round head
    // to a nearby large body of the same ink, then include small details inside that body.
    let groupedIDs = Set(candidates.flatMap { $0.map(\.id) })
    let visible = root.allShapes.filter { !$0.ink.isNearlyWhite }
    for head in visible where head.isCircle && !groupedIDs.contains(head.id) {
        let size = head.bounds.height
        let bodies = visible.filter { body in
            let b = body.bounds
            let span = max(b.width, b.height)
            let dx = max(b.minX-head.bounds.midX, 0, head.bounds.midX-b.maxX)
            let dy = max(b.minY-head.bounds.midY, 0, head.bounds.midY-b.maxY)
            return !body.isCircle && !groupedIDs.contains(body.id) && body.ink.resembles(head.ink)
                && span > size * 2.4 && span < size * 14
                && hypot(dx, dy) < size * 0.85
        }
        guard let body = bodies.min(by: {
            let a = $0.bounds, b = $1.bounds
            return hypot(a.midX-head.bounds.midX, a.midY-head.bounds.midY) < hypot(b.midX-head.bounds.midX, b.midY-head.bounds.midY)
        }) else { continue }
        let nearby = body.bounds.insetBy(dx: -size*0.08, dy: -size*0.08)
        let details = visible.filter {
            $0.id != head.id && $0.id != body.id && !groupedIDs.contains($0.id) && !$0.isCircle
                && $0.ink.resembles(head.ink) && max($0.bounds.width, $0.bounds.height) < size*2
                && nearby.contains(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY))
        }
        candidates.append([head, body] + details)
    }
    guard let maximumSpan = candidates.map({ shapes -> CGFloat in
        let b = shapes.reduce(CGRect.null) { $0.union($1.bounds) }
        return max(b.width, b.height)
    }).max() else { return [] }
    candidates = candidates.filter {
        let b = $0.reduce(CGRect.null) { $0.union($1.bounds) }
        return max(b.width, b.height) >= max(24, maximumSpan * 0.32)
    }
    // Keep the complete outer group when an inner group describes the same character.
    candidates.sort { $0.count > $1.count }
    var chosen: [[VectorShape]] = []
    var used = Set<Int>()
    for shapes in candidates {
        let ids = Set(shapes.map(\.id))
        guard ids.isDisjoint(with: used) else { continue }
        chosen.append(shapes.sorted { $0.id < $1.id }); used.formUnion(ids)
    }
    guard !chosen.isEmpty else { return [] }
    return orderedPictograms(chosen)
}

func orderedPictograms(_ chosen: [[VectorShape]]) -> [Pictogram] {
    // Cluster rows by vertical overlap before sorting left-to-right. Raised arms must not change ordering.
    let boxes = chosen.map { $0.reduce(CGRect.null) { $0.union($1.bounds) } }
    var remaining = Array(chosen.indices).sorted { boxes[$0].midY < boxes[$1].midY }
    var order: [Int] = []
    while let first = remaining.first {
        let center = boxes[first].midY
        let row = remaining.filter { abs(boxes[$0].midY-center) <= max(boxes[$0].height, boxes[first].height)*0.4 }
        order.append(contentsOf: row.sorted { boxes[$0].midX < boxes[$1].midX })
        let ids = Set(row); remaining.removeAll { ids.contains($0) }
    }
    return order.enumerated().map { Pictogram(number: $0.offset + 1, shapes: chosen[$0.element].sorted { $0.id < $1.id }) }
}
