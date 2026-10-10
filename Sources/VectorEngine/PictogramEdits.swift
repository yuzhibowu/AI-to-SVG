import Foundation
import CoreGraphics

public enum PictogramEdits {
    public static func merge(_ icons: [Pictogram], ids: Set<UUID>) throws -> [Pictogram] {
        let picked = icons.filter { ids.contains($0.id) }
        guard picked.count >= 2 else { throw ConversionError.malformed("请至少选择两个要合并的图标") }
        let first = picked.min { $0.number < $1.number }!
        var used = Set<Int>()
        let shapes = picked.flatMap(\.shapes).sorted { $0.id < $1.id }.filter { used.insert($0.id).inserted }
        let merged = Pictogram(id: first.id, number: first.number, shapes: shapes)
        return (icons.filter { !ids.contains($0.id) } + [merged]).sorted { $0.number < $1.number }
    }

    public static func split(_ icon: Pictogram, shapeIDs: Set<Int>, newNumber: Int) throws -> [Pictogram] {
        let separate = icon.shapes.filter { shapeIDs.contains($0.id) }
        let rest = icon.shapes.filter { !shapeIDs.contains($0.id) }
        guard !separate.isEmpty, !rest.isEmpty else { throw ConversionError.malformed("请选中要分出的完整人物，并留下另一部分") }
        return [Pictogram(id: icon.id, number: icon.number, shapes: rest), Pictogram(number: newNumber, shapes: separate)]
    }

    public static func select(in rect: CGRect, shapes: [VectorShape]) -> Set<Int> {
        Set(shapes.filter { shape in
            let b = shape.bounds
            let intersection = b.intersection(rect)
            return !b.isEmpty && !intersection.isNull && intersection.width * intersection.height >= b.width * b.height * 0.65
        }.map(\.id))
    }
}
