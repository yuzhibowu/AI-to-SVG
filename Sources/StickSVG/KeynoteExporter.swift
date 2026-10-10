import AppKit
import VectorEngine

/// Keynote's document API saves only the unique document created by this export.
/// The intermediate package stays private and alive until Keynote has finished.
enum KeynoteExporter {
    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    private static func execute(_ body: String, timeout: Int = 15) throws -> String {
        let source = "with timeout of \(timeout) seconds\ntell application id \"com.apple.iWork.Keynote\"\n\(body)\nend tell\nend timeout"
        var info: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw NSError(domain: "KeynoteExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建 Keynote 转换请求。"])
        }
        let result = script.executeAndReturnError(&info)
        if let info {
            let number = info[NSAppleScript.errorNumber] as? Int ?? -1
            let message = number == -1743 ? "请在系统设置 → 隐私与安全性 → 自动化中允许 AI转SVG 控制 Keynote。" : (info[NSAppleScript.errorMessage] as? String ?? "Keynote 转换请求未完成。")
            throw NSError(domain: "KeynoteExport", code: number, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return result.stringValue ?? ""
    }
    static func export(_ jobs: [SVGExportJob], color: ExportColor, to requested: URL,
                       progress: @escaping (SVGExportProgress) -> Void) throws -> (count: Int, url: URL) {
        guard let keynoteApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.Keynote") else {
            throw NSError(domain: "KeynoteExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先安装 Keynote，再导出 Keynote 文稿。"])
        }
        var target = requested
        var suffix = 1
        while FileManager.default.fileExists(atPath: target.path) {
            suffix += 1
            target = requested.deletingLastPathComponent().appendingPathComponent("\(requested.deletingPathExtension().lastPathComponent) (\(suffix)).key")
        }
        // Persistent private staging: a failed or timed-out import may still be
        // reading the package. Removing it at that point breaks Keynote's import.
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.sticksvg.converter/KeynoteExports", isDirectory: true)
        let staging = cache.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var saved = false
        defer { if saved { try? FileManager.default.removeItem(at: staging) } }
        let name = "AI-SVG-" + UUID().uuidString
        let pptx = staging.appendingPathComponent(name + ".pptx")
        let pages = try PresentationExporter.write(jobs, color: color, to: pptx, progress: progress)
        let total = jobs.reduce(0) { $0 + $1.icons.count }
        func report(_ phase: String, _ fraction: Double) {
            progress(SVGExportProgress(fraction: fraction, completed: total, total: total, currentFile: target.lastPathComponent, phase: phase))
        }
        report("Keynote 正在导入 \(pages) 个主题页…", 0.85)
        // Launch Services confirms the file handoff. A fire-and-forget Apple
        // event could be discarded while Keynote was busy, leaving us polling
        // for a document that had never been opened.
        let handoff = DispatchSemaphore(value: 0)
        var openError: Error?
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([pptx], withApplicationAt: keynoteApp, configuration: configuration) { _, error in
            openError = error
            handoff.signal()
        }
        guard handoff.wait(timeout: .now() + 60) == .success else {
            throw NSError(domain: "KeynoteExport", code: 4, userInfo: [NSLocalizedDescriptionKey: "未收到 Keynote 打开文件的确认，未开始保存 .key。转换数据已保留，请检查 Keynote 是否有等待处理的对话框。"])
        }
        if let openError { throw openError }
        let started = Date()
        // Large libraries can contain over 1,000 slides. A 60-second name poll
        // was not an import-completion signal; wait for the full slide count.
        let deadline = started.addingTimeInterval(1800)
        var createdID: String?
        while Date() < deadline {
            do {
                let response = try execute("""
                repeat with candidateDocument in documents
                    if name of candidateDocument is \(quote(name)) or name of candidateDocument is \(quote(name + ".pptx")) then
                        if (count of slides of candidateDocument) is \(pages) then return id of candidateDocument
                    end if
                end repeat
                return ""
                """, timeout: 10)
                if !response.isEmpty { createdID = response; break }
            } catch let error as NSError {
                // The importer may temporarily prevent document queries. A short
                // query timeout must not terminate the whole large import.
                guard [-1712, -1728].contains(error.code) else { throw error }
            }
            report("Keynote 正在导入 \(pages) 个主题页…", 0.85)
            Thread.sleep(forTimeInterval: 3)
        }
        guard let id = createdID else {
            throw NSError(domain: "KeynoteExport", code: 2, userInfo: [NSLocalizedDescriptionKey: "Keynote 尚未完成这批素材的导入，未生成 .key 文件。转换数据仍保留在应用缓存中。请关闭 Keynote 中未完成的导入后重试，或减少一次导出的主题数。"])
        }
        report("Keynote 正在保存 \(pages) 页文稿…", 0.95)
        _ = try execute("save document id \(quote(id)) in (POSIX file \(quote(target.path)))", timeout: 1800)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw NSError(domain: "KeynoteExport", code: 3, userInfo: [NSLocalizedDescriptionKey: "Keynote 未保存 .key 文件，请检查保存位置和磁盘空间。"])
        }
        // A close error should not invalidate a successfully saved presentation.
        let closed = (try? execute("close document id \(quote(id)) saving no", timeout: 10)) != nil
        saved = closed
        report("Keynote 导出完成", 1)
        return (total, target)
    }
}
