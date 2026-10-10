import Foundation
import CoreGraphics

/// Human Pictogram sheets mark the corners of each icon slot with small crosses.
/// Using those slots keeps balls, detached limbs, equipment and multiple people together.
struct TemplateGrid {
    let columns: [CGFloat]
    let rows: [CGFloat]
    let markerIDs: Set<Int>
    var bounds: CGRect {
        CGRect(x: columns.first!, y: rows.first!, width: columns.last!-columns.first!, height: rows.last!-rows.first!)
    }
    var artworkRegion: CGRect {
        let horizontal = (columns.last!-columns.first!)/CGFloat(columns.count-1)
        let vertical = (rows.last!-rows.first!)/CGFloat(rows.count-1)
        // Some originals extend equipment below the last registration row (e.g. scooter wheels).
        // These margins select entire paths; no geometry is clipped to the slot boundaries.
        return CGRect(x: bounds.minX-horizontal*0.35, y: bounds.minY-vertical*0.15,
                      width: bounds.width+horizontal*0.7, height: bounds.height+vertical*0.55)
    }

    static func detect(in shapes: [VectorShape]) -> TemplateGrid? {
        let crosses = shapes.filter { shape in
            let b = shape.bounds
            guard (3...30).contains(b.width), abs(b.width-b.height) < b.width*0.03,
                  shape.segments.count >= 10, shape.segments.count <= 30,
                  !shape.segments.contains(where: { if case .curve = $0 { return true }; return false }) else { return false }
            let samples: [(CGFloat, CGFloat, Bool)] = [(0.5,0.5,true), (0.1,0.5,true), (0.9,0.5,true),
                (0.5,0.1,true), (0.5,0.9,true), (0.2,0.2,false), (0.8,0.8,false)]
            return samples.allSatisfy { x, y, inside in
                shape.path.contains(CGPoint(x: b.minX+b.width*x, y: b.minY+b.height*y), using: shape.evenOdd ? .evenOdd : .winding) == inside
            }
        }
        guard crosses.count >= 6 else { return nil }
        func cluster(_ values: [CGFloat]) -> [CGFloat] {
            var groups: [[CGFloat]] = []
            for value in values.sorted() {
                if let last = groups.last, abs(value-last[0]) < 0.8 { groups[groups.count-1].append(value) }
                else { groups.append([value]) }
            }
            return groups.map { $0.reduce(0,+)/CGFloat($0.count) }
        }
        let columns = cluster(crosses.map { $0.bounds.midX }), rows = cluster(crosses.map { $0.bounds.midY })
        guard columns.count >= 3, rows.count >= 2, columns.count <= 12, rows.count <= 12,
              columns.count*rows.count == crosses.count else { return nil }
        let locations = Set(crosses.map { shape in
            let x = columns.firstIndex { abs($0-shape.bounds.midX) < 0.8 }!
            let y = rows.firstIndex { abs($0-shape.bounds.midY) < 0.8 }!
            return y*columns.count+x
        })
        guard locations.count == crosses.count else { return nil }
        return TemplateGrid(columns: columns, rows: rows, markerIDs: Set(crosses.map(\.id)))
    }

    func extract(_ root: Group) -> [Pictogram] {
        let shapes = root.allShapes
        var slots: [[VectorShape]] = Array(repeating: [], count: (columns.count-1)*(rows.count-1))
        var artworkGroups: [[VectorShape]] = []
        var used = Set<Int>()
        // These sheets paint header/credits first, then the icon groups. Extra variants
        // can sit below the last row; preserve them in full instead of taking only a limb.
        let firstGroupedArtworkID: Int? = root.usesExplicitArtworkGroups ? root.descendants.dropFirst().compactMap { group in
            let members = group.allShapes
            let b = members.reduce(CGRect.null) { $0.union($1.bounds) }
            guard max(b.width,b.height) > 30, bounds.contains(CGPoint(x: b.midX, y: b.midY)),
                  members.allSatisfy({ !markerIDs.contains($0.id) }) else { return nil }
            return members.map(\.id).min()
        }.min() : nil
        let firstLooseArtworkID = root.usesExplicitArtworkGroups ? shapes.filter {
            !markerIDs.contains($0.id) && !$0.ink.isNearlyWhite && artworkRegion.contains(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY))
        }.map(\.id).min() : nil
        let firstArtworkID = [firstGroupedArtworkID, firstLooseArtworkID].compactMap { $0 }.min()
        func slot(at center: CGPoint, bounded: Bool = true) -> Int? {
            guard (!bounded || artworkRegion.contains(center)),
                  let x = (0..<columns.count-1).first(where: { (center.x >= columns[$0] || $0 == 0) && (center.x < columns[$0+1] || $0 == columns.count-2) }),
                  let y = (0..<rows.count-1).first(where: { (center.y >= rows[$0] || $0 == 0) && (center.y < rows[$0+1] || $0 == rows.count-2) }) else { return nil }
            return y*(columns.count-1)+x
        }
        func gather(_ group: Group) {
            let members = group.allShapes
            let b = members.reduce(CGRect.null) { $0.union($1.bounds) }
            let width = (columns.last!-columns.first!)/CGFloat(columns.count-1)
            let height = (rows.last!-rows.first!)/CGFloat(rows.count-1)
            if let firstArtworkID, !members.isEmpty, members.allSatisfy({ $0.id >= firstArtworkID }),
               max(b.width, b.height) > min(width,height)*0.2,
               members.allSatisfy({ !markerIDs.contains($0.id) }),
               members.contains(where: { !$0.ink.isNearlyWhite }) {
                // Prefer the author's complete group, even when its limbs cross a slot line.
                artworkGroups.append(members); used.formUnion(members.map(\.id))
            } else {
                for child in group.children { gather(child) }
            }
        }
        if root.usesExplicitArtworkGroups { for child in root.children { gather(child) } }
        let attachmentMargin = min((columns.last!-columns.first!)/CGFloat(columns.count-1),
                                   (rows.last!-rows.first!)/CGFloat(rows.count-1))*0.1
        var sourceGroupBounds: [Int: CGRect] = [:]
        for group in root.children {
            let members = group.allShapes
            guard members.allSatisfy({ !markerIDs.contains($0.id) }) else { continue }
            let box = members.reduce(CGRect.null) { $0.union($1.bounds) }
            for member in members { sourceGroupBounds[member.id] = box }
        }
        func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
            hypot(max(a.minX-b.maxX, 0, b.minX-a.maxX),
                  max(a.minY-b.maxY, 0, b.minY-a.maxY))
        }
        for shape in shapes.sorted(by: { $0.id < $1.id }) where !markerIDs.contains(shape.id) {
            guard !used.contains(shape.id) else { continue }
            let b = shape.bounds, center = CGPoint(x: b.midX, y: b.midY)
            // Header, credit lines and page-sized backgrounds are outside the artwork slots.
            guard (firstArtworkID.map { shape.id >= $0 } ?? artworkRegion.contains(center)),
                  !(shape.ink.isNearlyWhite && b.width > bounds.width*0.9 && b.height > bounds.height*0.9),
                  !shape.bounds.isEmpty else { continue }
            // Paint order alone does not establish ownership: the footer's ® is
            // painted after the figures. A small standalone object outside the grid
            // must be near an intact author group. Measure its source group, not
            // individual paths: heads and clothing in a larger off-grid variant
            // still belong to that complete drawing.
            if let sourceBox = sourceGroupBounds[shape.id],
               max(sourceBox.width,sourceBox.height) <= attachmentMargin*2,
               !artworkRegion.contains(center),
               !artworkGroups.contains(where: { members in
                   gap(sourceBox, members.reduce(CGRect.null) { $0.union($1.bounds) }) <= attachmentMargin
               }) { continue }
            if let index = slot(at: center, bounded: firstArtworkID == nil) { slots[index].append(shape) }
        }
        if !artworkGroups.isEmpty {
            for loose in slots where !loose.isEmpty {
                let b = loose.reduce(CGRect.null) { $0.union($1.bounds) }
                func distance(_ index: Int) -> CGFloat {
                    let box = artworkGroups[index].reduce(CGRect.null) { $0.union($1.bounds) }
                    let dx = max(box.minX-b.maxX, 0, b.minX-box.maxX)
                    let dy = max(box.minY-b.maxY, 0, b.minY-box.maxY)
                    return hypot(dx,dy)
                }
                let nearest = artworkGroups.indices.min { a,c in
                    let da = distance(a), dc = distance(c)
                    if abs(da-dc) > 0.01 { return da < dc }
                    let ba = artworkGroups[a].reduce(CGRect.null) { $0.union($1.bounds) }
                    let bc = artworkGroups[c].reduce(CGRect.null) { $0.union($1.bounds) }
                    return hypot(ba.midX-b.midX,ba.midY-b.midY) < hypot(bc.midX-b.midX,bc.midY-b.midY)
                }!
                let spacing = (columns.last!-columns.first!)/CGFloat(columns.count-1)
                if max(b.width,b.height) > 30, distance(nearest) > spacing*0.1,
                   loose.contains(where: { !$0.ink.isNearlyWhite }) {
                    // A complete ungrouped variant occupies its own slot, rather than
                    // being attached to a neighboring grouped character.
                    artworkGroups.append(loose)
                } else { artworkGroups[nearest].append(contentsOf: loose) }
            }
        }
        let groups = artworkGroups.isEmpty ? slots : artworkGroups
        return orderedPictograms(groups.filter { $0.contains { !$0.ink.isNearlyWhite } })
    }
}
