import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers
import VectorEngine

struct InputDocument: Identifiable {
    let id = UUID()
    let url: URL
    var icons: [Pictogram] = []
    var shapes: [VectorShape] = []
    var error: String?
    var isAnalyzing = true
    var stem: String { url.deletingPathExtension().lastPathComponent }
}

enum EditorMode {
    case add, edit(UUID), split(UUID)
    var targetID: UUID? {
        switch self { case .add: return nil; case .edit(let id), .split(let id): return id }
    }
    var isSplit: Bool { if case .split = self { return true }; return false }
}

struct EditorRequest: Identifiable {
    let id = UUID()
    let document: InputDocument
    let mode: EditorMode
}

private struct EditSnapshot {
    let documentID: UUID
    let icons: [Pictogram]
    let selected: Set<UUID>
}

@MainActor
final class ConversionModel: ObservableObject {
    @Published var documents: [InputDocument] = []
    @Published var activeDocumentID: UUID?
    @Published var selectedIcons = Set<UUID>()
    @Published var exportColor: ExportColor = .original
    @Published var exportLayout: SVGExportLayout = .flat
    @Published var isImporting = false
    @Published var isExporting = false
    @Published var isCopyingSVG = false
    @Published var exportProgress = 0.0
    @Published var exportCompleted = 0
    @Published var exportTotal = 0
    @Published var exportCurrentFile = ""
    @Published var exportPhase = "导出 SVG"
    @Published var keynoteWaitStarted: Date?
    var isWaitingForKeynote: Bool { exportPhase.hasPrefix("Keynote 正在") && exportProgress >= 0.85 && exportProgress < 1 }
    @Published var showExportComplete = false
    @Published var exportCompleteMessage = ""
    @Published var progress = 0.0
    @Published var currentFile = ""
    @Published var notice: String?
    @Published var exportLocation: URL?
    @Published var showError = false
    @Published var errorMessage = ""
    @Published private var editHistory: [EditSnapshot] = []
    private var importTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var exportRunID = UUID()
    var activeDocument: InputDocument? { documents.first { $0.id == activeDocumentID } }
    var selectedCount: Int { documents.flatMap(\.icons).filter { selectedIcons.contains($0.id) }.count }
    var iconCount: Int { documents.flatMap(\.icons).count }
    var canRevealOutput: Bool { exportLocation.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    var canUndo: Bool { !editHistory.isEmpty }
    var currentSelectedCount: Int { activeDocument?.icons.filter { selectedIcons.contains($0.id) }.count ?? 0 }

    func clearDocuments() {
        guard !isImporting, !isExporting else { return }
        exportLocation = nil
        documents.removeAll()
        selectedIcons.removeAll()
        activeDocumentID = nil
        editHistory.removeAll()
        notice = "已清空导入列表，原始素材和导出的文件仍保留。"
    }

    func chooseInputs() {
        guard !isImporting, !isExporting else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 AI 素材或文件夹"
        panel.prompt = "导入"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "ai") ?? .data]
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    func importClipboard() {
        guard !isImporting, !isExporting else { return }
        let pasteboard = NSPasteboard.general
        let apple = pasteboard.data(forType: NSPasteboard.PasteboardType(ClipboardVectorParser.appleType))
        let pdf = pasteboard.data(forType: .pdf)
        guard let data = apple ?? pdf else {
            fail("剪贴板中没有可读取的矢量对象。请在 Keynote 或无边记中复制形状再粘贴；当前不把图片预览冒充矢量路径。")
            return
        }
        exportLocation = nil
        isImporting = true; progress = 0; currentFile = "剪贴板对象"
        importTask = Task {
            defer { isImporting = false; currentFile = "" }
            let result = await Task.detached(priority: .userInitiated) {
                Result { try apple != nil ? ClipboardVectorParser.parseApple(data) : ClipboardVectorParser.parsePDF(data) }
            }.value
            switch result {
            case .success(let icons):
                let name = "剪贴板-" + DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium).replacingOccurrences(of: ":", with: "-")
                let url = URL(fileURLWithPath: "/剪贴板/" + name + ".svg")
                var document = InputDocument(url: url)
                document.icons = icons; document.shapes = icons.flatMap(\.shapes); document.isAnalyzing = false
                documents.append(document); activeDocumentID = document.id
                selectedIcons.formUnion(icons.map(\.id)); progress = 1
                notice = "已从剪贴板导入 \(icons.count) 个矢量对象，可预览、调色并导出 SVG。"
            case .failure(let error): fail(error.localizedDescription)
            }
        }
    }

    func loadExample() {
        if let url = Bundle.main.url(forResource: "p0941", withExtension: "ai", subdirectory: "Samples") {
            importFiles([url])
        } else {
            let fallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Fixtures/p0941.ai")
            if FileManager.default.fileExists(atPath: fallback.path) { importFiles([fallback]) }
            else { fail("找不到内置示例，请拖入你的 AI 文件。") }
        }
    }

    func importFiles(_ roots: [URL]) {
        guard !isImporting, !isExporting else { notice = "正在处理素材，请稍后继续添加。"; return }
        exportLocation = nil
        isImporting = true; notice = nil; progress = 0
        let existing = Set(documents.map { $0.url.resolvingSymlinksInPath().path })
        importTask = Task {
            let scoped = roots.filter { $0.startAccessingSecurityScopedResource() }
            defer { for url in scoped { url.stopAccessingSecurityScopedResource() }; isImporting = false; currentFile = "" }
            let urls = await Task.detached(priority: .userInitiated) { Self.collect(roots) }.value
            var seen = existing
            let inputs = urls.filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
            guard !inputs.isEmpty else {
                notice = urls.isEmpty ? "没有找到 AI 文件。文件夹内的说明文件会自动跳过。" : "这些素材已经导入。"
                return
            }
            for (index, url) in inputs.enumerated() {
                if Task.isCancelled { break }
                let document = InputDocument(url: url)
                documents.append(document); currentFile = url.lastPathComponent
                if activeDocumentID == nil { activeDocumentID = document.id }
                let worker = Task.detached(priority: .userInitiated) { try AIParser().analyze(url: url) }
                let result = await withTaskCancellationHandler {
                    await worker.result
                } onCancel: { worker.cancel() }
                if Task.isCancelled { documents.removeAll { $0.id == document.id }; break }
                guard let position = documents.firstIndex(where: { $0.id == document.id }) else { continue }
                documents[position].isAnalyzing = false
                switch result {
                case .success(let analysis):
                    documents[position].icons = analysis.pictograms
                    documents[position].shapes = analysis.shapes
                    selectedIcons.formUnion(analysis.pictograms.map(\.id))
                case .failure(let error): documents[position].error = error.localizedDescription
                }
                progress = Double(index+1) / Double(inputs.count)
            }
            if !Task.isCancelled {
                let failures = documents.filter { $0.error != nil }.count
                notice = "已识别 \(iconCount) 个图标" + (failures > 0 ? "，\(failures) 份素材需要查看" : "。导出前可以取消不需要的图标。")
            } else { notice = "已停止导入，完成的结果已保留。" }
            if activeDocument == nil { activeDocumentID = documents.first?.id }
        }
    }

    nonisolated static func collect(_ roots: [URL]) -> [URL] {
        var files: [URL] = []
        for root in roots where root.isFileURL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                if let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                    for case let file as URL in iterator where file.pathExtension.lowercased() == "ai" {
                        if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(file) }
                    }
                }
            } else if root.pathExtension.lowercased() == "ai" { files.append(root) }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func cancelImport() { importTask?.cancel() }
    func toggle(_ icon: Pictogram) {
        guard !isExporting else { return }
        if selectedIcons.contains(icon.id) { selectedIcons.remove(icon.id) } else { selectedIcons.insert(icon.id) }
    }
    func selectCurrent(_ selected: Bool) {
        guard !isExporting else { return }
        let ids = activeDocument?.icons.map(\.id) ?? []
        if selected { selectedIcons.formUnion(ids) } else { selectedIcons.subtract(ids) }
    }
    func removeDocument(_ id: UUID) {
        guard !isImporting && !isExporting else { return }
        if let document = documents.first(where: { $0.id == id }) { selectedIcons.subtract(document.icons.map(\.id)) }
        documents.removeAll { $0.id == id }
        editHistory.removeAll { $0.documentID == id }
        if activeDocumentID == id { activeDocumentID = documents.first?.id }
        notice = nil
    }

    func setHexColor(_ hex: String) {
        guard let color = ExportColor(hex: hex) else { fail("请输入 3 位或 6 位 HEX 色值，例如 #FFC400。"); return }
        exportColor = color
    }

    private func remember(_ document: InputDocument) {
        editHistory.append(EditSnapshot(documentID: document.id, icons: document.icons, selected: selectedIcons.intersection(document.icons.map(\.id))))
        if editHistory.count > 30 { editHistory.removeFirst() }
    }

    func undoEdit() {
        guard !isExporting, !isImporting, let snapshot = editHistory.popLast(), let index = documents.firstIndex(where: { $0.id == snapshot.documentID }) else { return }
        selectedIcons.subtract(documents[index].icons.map(\.id))
        documents[index].icons = snapshot.icons
        selectedIcons.formUnion(snapshot.selected)
        activeDocumentID = snapshot.documentID
        notice = "已撤销上一次人物修改。"
    }

    func mergeCurrent() {
        guard !isExporting, !isImporting, let document = activeDocument, let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        let ids = selectedIcons.intersection(document.icons.map(\.id))
        do {
            let icons = try PictogramEdits.merge(document.icons, ids: ids)
            remember(document); documents[index].icons = icons
            selectedIcons.subtract(ids)
            selectedIcons.formUnion(icons.filter { ids.contains($0.id) }.map(\.id))
            notice = "已将 \(ids.count) 个所选图标合并为一个，可撤销。"
        } catch { fail(error.localizedDescription) }
    }

    func deleteIcon(_ id: UUID) {
        guard !isExporting, !isImporting, let document = activeDocument,
              document.icons.contains(where: { $0.id == id }),
              let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        remember(document)
        documents[index].icons.removeAll { $0.id == id }
        selectedIcons.remove(id)
        notice = "已删除这个图标，可在“修正识别”中撤销。原始 AI 文件保留。"
    }

    func saveSelection(_ shapeIDs: Set<Int>, request: EditorRequest) -> Bool {
        guard !isExporting, let index = documents.firstIndex(where: { $0.id == request.document.id }) else { return false }
        let document = documents[index]
        let otherIDs = Set(document.icons.filter { $0.id != request.mode.targetID }.flatMap { $0.shapes.map(\.id) })
        guard shapeIDs.isDisjoint(with: otherIDs) else { fail("这些路径已属于其他图标。可以先合并图标，再进行编辑。"); return false }
        let shapes = document.shapes.filter { shapeIDs.contains($0.id) }
        guard shapes.contains(where: { !$0.ink.isNearlyWhite }) else { fail("请点选人物轮廓，或拖动框选一个完整图标。白色镂空路径需要和主体一起选择。"); return false }
        let next = (document.icons.map(\.number).max() ?? 0) + 1
        do {
            var icons = document.icons
            var select: [UUID] = []
            switch request.mode {
            case .add:
                let icon = Pictogram(number: next, shapes: shapes)
                icons.append(icon); select = [icon.id]
            case .edit(let id):
                guard let position = icons.firstIndex(where: { $0.id == id }) else { return false }
                icons[position] = Pictogram(id: id, number: icons[position].number, shapes: shapes); select = [id]
            case .split(let id):
                guard let position = icons.firstIndex(where: { $0.id == id }) else { return false }
                let split = try PictogramEdits.split(icons[position], shapeIDs: shapeIDs, newNumber: next)
                icons[position] = split[0]; icons.append(split[1]); select = split.map(\.id)
            }
            remember(document); documents[index].icons = icons
            selectedIcons.formUnion(select)
            notice = "人物路径已更新，可继续预览或撤销修改。"
            return true
        } catch { fail(error.localizedDescription); return false }
    }

    func chooseArchive() {
        guard selectedCount > 0, !isExporting, !isImporting else { return }
        let panel = NSSavePanel()
        panel.title = "打包导出所有选中的 SVG"
        panel.message = exportLayout == .flat ? "所有 SVG 放在 ZIP 内的同一个文件夹，按素材名称和图标编号排列。" : "ZIP 内按原文档分别建文件夹，背景全部透明。"
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "AI转SVG.zip"
        panel.canCreateDirectories = true
        panel.prompt = "打包导出"
        if panel.runModal() == .OK, let url = panel.url { export(to: url, archive: true) }
    }

    func copySVG(_ onlyIcon: Pictogram? = nil) {
        guard !isCopyingSVG, !isImporting, !isExporting else { return }
        let entries = documents.sorted { $0.stem.localizedStandardCompare($1.stem) == .orderedAscending }.flatMap { document in
            document.icons.sorted { $0.number < $1.number }.filter { candidate in
                onlyIcon.map { icon in icon.id == candidate.id } ?? selectedIcons.contains(candidate.id)
            }.map { (String(format: "%@-%02d.svg", document.stem, $0.number), $0) }
        }
        guard !entries.isEmpty else { return }
        let color = exportColor
        isCopyingSVG = true; notice = "正在准备复制 \(entries.count) 个 SVG…"
        Task {
            defer { isCopyingSVG = false }
            let result = await Task.detached(priority: .userInitiated) {
                Result { () -> [(String, URL)] in
                    let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("local.sticksvg.converter/ClipboardSVG/" + UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    do {
                        return try entries.enumerated().map { index, entry in
                            let svg = entry.1.svg(color: color)
                            let safeName = entry.0.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                            let file = directory.appendingPathComponent(String(format: "%04d-", index+1) + safeName)
                            try svg.write(to: file, atomically: true, encoding: .utf8)
                            return (svg, file)
                        }
                    } catch { try? FileManager.default.removeItem(at: directory); throw error }
                }
            }.value
            switch result {
            case .success(let entries):
                let items = entries.map { svg, file -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    item.setData(Data(svg.utf8), forType: NSPasteboard.PasteboardType(UTType.svg.identifier))
                    item.setString(svg, forType: .string)
                    item.setString(file.absoluteString, forType: .fileURL)
                    return item
                }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                if pasteboard.writeObjects(items) { notice = "已复制 \(items.count) 个 SVG 到剪贴板，保留当前颜色与矢量路径。" }
                else { fail("无法写入剪贴板，请重试。") }
            case .failure(let error): fail("复制 SVG 失败：\(error.localizedDescription)")
            }
        }
    }

    func chooseOutput() {
        guard selectedCount > 0, !isExporting, !isImporting else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 SVG 保存位置"
        panel.message = exportLayout == .flat ? "所有 SVG 直接保存到所选文件夹，按素材名称和图标编号排列；同名文件自动加序号。" : "每份素材会保存到独立文件夹，已有文件不会被覆盖。"
        panel.prompt = "导出 \(selectedCount) 个 SVG"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { export(to: url) }
    }

    func chooseKeynote() {
        guard selectedCount > 0, !isImporting, !isExporting else { return }
        let panel = NSSavePanel()
        panel.title = "导出 Keynote 文稿"
        panel.message = "每份素材对应一页，勾选的图标保存为可编辑形状组。首次使用时，请允许控制 Keynote。"
        panel.allowedContentTypes = [UTType(filenameExtension: "key") ?? .data]
        panel.nameFieldStringValue = "AI转SVG-主题图标.key"
        if panel.runModal() == .OK, let url = panel.url { export(to: url, keynote: true) }
    }

    func export(to destination: URL, archive: Bool = false, keynote: Bool = false) {
        let jobs = documents.compactMap { doc -> SVGExportJob? in
            let icons = doc.icons.filter { selectedIcons.contains($0.id) }
            return icons.isEmpty ? nil : SVGExportJob(name: doc.stem, icons: icons)
        }
        let color = exportColor
        let layout = exportLayout
        let runID = UUID()
        exportRunID = runID
        isExporting = true; notice = nil; exportLocation = nil
        exportProgress = 0; exportCompleted = 0
        exportTotal = jobs.reduce(0) { $0 + $1.icons.count }
        exportCurrentFile = ""; exportPhase = "导出 SVG"; keynoteWaitStarted = nil
        showExportComplete = false
        exportTask = Task {
            let scoped = destination.startAccessingSecurityScopedResource()
            defer { if scoped { destination.stopAccessingSecurityScopedResource() }; isExporting = false }
            let result = await Task.detached(priority: .userInitiated) {
                var lastUpdate = Date.distantPast
                var lastPhase = ""
                let report: (SVGExportProgress) -> Void = { update in
                    let now = Date()
                    guard now.timeIntervalSince(lastUpdate) >= 0.08 || update.fraction == 1 || update.phase != lastPhase else { return }
                    lastUpdate = now
                    lastPhase = update.phase
                    Task { @MainActor [weak self] in
                        guard let self, self.isExporting, self.exportRunID == runID,
                              update.fraction >= self.exportProgress else { return }
                        self.exportProgress = update.fraction
                        self.exportCompleted = update.completed
                        self.exportCurrentFile = update.currentFile
                        self.exportPhase = update.phase
                        if self.isWaitingForKeynote && self.keynoteWaitStarted == nil { self.keynoteWaitStarted = Date() }
                    }
                }
                return Result { () -> (count: Int, url: URL) in
                    if keynote { return try KeynoteExporter.export(jobs, color: color, to: destination, progress: report) }
                    if archive { return try SVGExporter().exportArchive(jobs, color: color, to: destination, layout: layout, progress: report) }
                    return (try SVGExporter().export(jobs, color: color, to: destination, layout: layout, progress: report), destination)
                }
            }.value
            switch result {
            case .success(let result):
                exportLocation = result.url
                let arrangement = layout == .flat ? "全部放在同一个文件夹。" : "按 \(jobs.count) 份原文档分别归类。"
                notice = keynote ? "已导出 Keynote：\(jobs.count) 个主题页，\(result.count) 个可编辑图标。" : "已\(archive ? "打包" : "导出") \(result.count) 个 SVG，\(arrangement)"
                exportProgress = 1; exportCompleted = result.count
                exportCompleteMessage = "\(notice!)\n保存位置：\(result.url.path)"
                showExportComplete = true
            case .failure(let error): fail("导出没有完成：\(error.localizedDescription)")
            }
        }
    }

    func revealOutput() {
        if let url = exportLocation, canRevealOutput {
            if ["zip", "key", "pptx"].contains(url.pathExtension.lowercased()) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else { NSWorkspace.shared.open(url) }
        }
    }
    func fail(_ message: String) { errorMessage = message; showError = true }
}
