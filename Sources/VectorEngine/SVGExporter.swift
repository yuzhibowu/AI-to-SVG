import Foundation

public enum SVGExportLayout: String, CaseIterable, Identifiable {
    case flat, byDocument
    public var id: String { rawValue }
    public var title: String { self == .flat ? "全部放在同一个文件夹" : "按原文档分文件夹" }
}

public struct SVGExportJob {
    public let name: String
    public let icons: [Pictogram]
    public init(name: String, icons: [Pictogram]) { self.name = name; self.icons = icons }
}

public struct SVGExportProgress: Sendable {
    public let fraction: Double
    public let completed: Int
    public let total: Int
    public let currentFile: String
    public let phase: String
    public init(fraction: Double, completed: Int, total: Int, currentFile: String, phase: String) {
        self.fraction = fraction; self.completed = completed; self.total = total
        self.currentFile = currentFile; self.phase = phase
    }
}

public struct SVGExporter {
    public init() {}
    public func export(_ jobs: [SVGExportJob], color: ExportColor, to destination: URL, layout: SVGExportLayout = .byDocument, progress: ((SVGExportProgress) -> Void)? = nil) throws -> Int {
        let count = jobs.reduce(0) { $0 + $1.icons.count }
        func report(_ completed: Int, _ file: String) {
            progress?(SVGExportProgress(fraction: count == 0 ? 1 : Double(completed)/Double(count), completed: completed, total: count, currentFile: file, phase: "导出 SVG"))
        }
        report(0, "")
        let jobs = jobs.enumerated().sorted {
            let order = $0.element.name.localizedStandardCompare($1.element.name)
            return order == .orderedSame ? $0.offset < $1.offset : order == .orderedAscending
        }.map(\.element)
        if layout == .flat {
            var created: [URL] = []
            do {
                for job in jobs {
                    let stem = job.name.replacingOccurrences(of: "/", with: "-")
                    guard !stem.isEmpty, stem != ".", stem != ".." else { throw ConversionError.malformed("文件名为空") }
                    for icon in job.icons.sorted(by: { $0.number < $1.number }) {
                        let base = String(format: "%@-%02d", stem, icon.number)
                        var file = destination.appendingPathComponent(base + ".svg")
                        var suffix = 1
                        while FileManager.default.fileExists(atPath: file.path) {
                            suffix += 1
                            file = destination.appendingPathComponent("\(base) (\(suffix)).svg")
                        }
                        try Data(icon.svg(color: color).utf8).write(to: file, options: .withoutOverwriting)
                        created.append(file)
                        report(created.count, file.lastPathComponent)
                    }
                }
                return created.count
            } catch {
                for file in created { try? FileManager.default.removeItem(at: file) }
                throw error
            }
        }
        var total = 0
        for job in jobs where !job.icons.isEmpty {
            // Keep source names as labels, never interpret them as relative paths.
            let stem = job.name.replacingOccurrences(of: "/", with: "-")
            guard !stem.isEmpty, stem != ".", stem != ".." else { throw ConversionError.malformed("文件名为空") }
            var number = 1
            var folder = destination.appendingPathComponent(stem, isDirectory: true)
            while FileManager.default.fileExists(atPath: folder.path) {
                number += 1; folder = destination.appendingPathComponent("\(stem) (\(number))", isDirectory: true)
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            do {
                for icon in job.icons.sorted(by: { $0.number < $1.number }) {
                    let file = folder.appendingPathComponent(String(format: "%@-%02d.svg", stem, icon.number))
                    try icon.svg(color: color).write(to: file, atomically: true, encoding: .utf8)
                    total += 1
                    report(total, file.lastPathComponent)
                }
            } catch {
                // Only this newly created folder is eligible for cleanup.
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }
        return total
    }

    public func exportArchive(_ jobs: [SVGExportJob], color: ExportColor, to destination: URL, layout: SVGExportLayout = .byDocument, progress: ((SVGExportProgress) -> Void)? = nil) throws -> (count: Int, url: URL) {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("sticksvg-archive-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let tree = staging.appendingPathComponent("SVG图标", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        let count = try export(jobs, color: color, to: tree, layout: layout) { update in
            progress?(SVGExportProgress(fraction: update.fraction*0.75, completed: update.completed, total: update.total, currentFile: update.currentFile, phase: update.phase))
        }
        let file = staging.appendingPathComponent("package.zip")
        progress?(SVGExportProgress(fraction: 0.75, completed: count, total: count, currentFile: "", phase: "打包 ZIP"))
        try ZIPWriter.write(directory: tree, to: file) { completed, total, name in
            progress?(SVGExportProgress(fraction: 0.75 + 0.24*Double(completed)/Double(max(total,1)), completed: count, total: count, currentFile: name, phase: "打包 ZIP"))
        }
        // Copying instead of replacing also protects a same-name archive created meanwhile.
        let base = destination.deletingPathExtension().lastPathComponent
        var target = destination
        var suffix = 1
        while FileManager.default.fileExists(atPath: target.path) {
            suffix += 1
            target = destination.deletingLastPathComponent().appendingPathComponent("\(base) (\(suffix)).zip")
        }
        progress?(SVGExportProgress(fraction: 0.99, completed: count, total: count, currentFile: target.lastPathComponent, phase: "保存 ZIP"))
        try FileManager.default.copyItem(at: file, to: target)
        progress?(SVGExportProgress(fraction: 1, completed: count, total: count, currentFile: target.lastPathComponent, phase: "导出完成"))
        return (count, target)
    }
}
