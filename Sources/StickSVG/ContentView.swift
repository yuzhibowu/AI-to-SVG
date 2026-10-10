import SwiftUI
import UniformTypeIdentifiers
import VectorEngine

private let leaf = Color(red: 0.18, green: 0.54, blue: 0.32)

struct ContentView: View {
    @ObservedObject var model: ConversionModel
    @State private var isDropTarget = false
    @State private var editorRequest: EditorRequest?
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 252)
            Divider()
            workspace
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 14).stroke(leaf, style: StrokeStyle(lineWidth: 3, dash: [10, 6])).padding(8).allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget, perform: receiveDrop)
        .sheet(item: $editorRequest) { request in
            ManualEditor(request: request) { model.saveSelection($0, request: request) }
        }
        .alert("需要查看", isPresented: $model.showError) { Button("知道了", role: .cancel) {} } message: { Text(model.errorMessage) }
        .alert("导出完成", isPresented: $model.showExportComplete) {
            Button("在 Finder 中查看", action: model.revealOutput)
            Button("完成", role: .cancel) {}
        } message: { Text(model.exportCompleteMessage) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSImage(named: "AppLogo") ?? NSImage(systemSymbolName: "figure.arms.open", accessibilityDescription: nil)!)
                    .resizable().scaledToFit().frame(width: 42, height: 42).clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI转SVG").font(.system(size: 19, weight: .bold))
                    Text("人物与道具，完整导出").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(.top, 40).padding(.horizontal, 20)

            Button(action: model.chooseInputs) {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc").font(.system(size: 27, weight: .light)).foregroundStyle(leaf)
                    Text("拖入 AI 文件或文件夹").font(.system(size: 13, weight: .semibold))
                    Text("也可以点这里选择素材").font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 22)
                    .background(leaf.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(leaf.opacity(0.24), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            }.buttonStyle(.plain).disabled(model.isImporting || model.isExporting).padding(18)

            HStack {
                Text("素材").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.documents.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Button(action: model.clearDocuments) { Label("清空", systemImage: "trash") }
                    .font(.system(size: 11)).help("清空导入列表，保留原始素材和导出文件")
                    .disabled(model.documents.isEmpty || model.isImporting || model.isExporting)
            }.padding(.horizontal, 22).padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(model.documents) { document in
                        Button { model.activeDocumentID = document.id } label: {
                            HStack(spacing: 10) {
                                Image(systemName: document.error == nil ? "doc.richtext" : "exclamationmark.triangle")
                                    .font(.system(size: 17)).foregroundStyle(document.error == nil ? leaf : .orange)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(document.url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(document.isAnalyzing ? "正在识别…" : document.error == nil ? "\(document.icons.count) 个图标" : "暂不支持")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if document.isAnalyzing { ProgressView().controlSize(.small) }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.activeDocumentID == document.id ? leaf.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .contextMenu { Button("移除素材") { model.removeDocument(document.id) }.disabled(model.isImporting || model.isExporting) }
                    }
                }.padding(.horizontal, 12)
            }
            Spacer(minLength: 14)
            if model.isImporting {
                VStack(alignment: .leading, spacing: 9) {
                    ProgressView(value: model.progress)
                    HStack { Text(model.currentFile).font(.system(size: 10)).lineLimit(1); Spacer(); Button("停止", action: model.cancelImport).font(.system(size: 10)) }
                }.padding(18)
            }
            Divider().padding(.horizontal, 18)
            VStack(alignment: .leading, spacing: 6) {
                Label("完全离线 · 透明背景", systemImage: "lock.shield").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("适用于 Human Pictogram AI 素材").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(20)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.activeDocument?.stem ?? "提取你需要的人物").font(.system(size: 24, weight: .bold))
                    Text(model.activeDocument.map { $0.isAnalyzing ? "正在读取矢量路径…" : "选择要导出的图标，人物与道具一起保存为 SVG。" } ?? "保留人物和道具，不带网站标识和背景。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                Picker("导出方式", selection: $model.exportLayout) {
                    ForEach(SVGExportLayout.allCases) { layout in Text(layout.title).tag(layout) }
                }.labelsHidden().frame(width: 190)
                    .disabled(model.isExporting || model.isImporting)
                Button("ZIP 打包", action: model.chooseArchive)
                    .disabled(model.selectedCount == 0 || model.isExporting || model.isImporting)
                Button("导出 Keynote", action: model.chooseKeynote)
                    .disabled(model.selectedCount == 0 || model.isExporting || model.isImporting)
                    .help("每个主题一页，每个图标一个可编辑形状组")
                Spacer(minLength: 0)
                Button(action: model.chooseOutput) {
                    Label(model.isExporting ? "正在导出…" : "导出 \(model.selectedCount) 个 SVG", systemImage: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                }.buttonStyle(.borderedProminent).disabled(model.selectedCount == 0 || model.isExporting || model.isImporting)
                }
            }.padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 24)
            Divider()

            if model.isExporting {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(model.exportPhase).font(.system(size: 13, weight: .semibold))
                        Spacer()
                        if model.isWaitingForKeynote {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let elapsed = max(0, Int(context.date.timeIntervalSince(model.keynoteWaitStarted ?? context.date)))
                                Text("已等待 \(elapsed / 60) 分 \(elapsed % 60) 秒")
                                    .font(.system(size: 12, design: .monospaced))
                            }
                        } else {
                            Text("\(model.exportCompleted) / \(model.exportTotal) 个图标 · \(Int(model.exportProgress*100))%")
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                    if model.isWaitingForKeynote {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("由 Keynote 处理，暂时无法获取准确进度，请保持 Keynote 打开。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView(value: model.exportProgress).progressViewStyle(.linear).tint(leaf)
                    }
                    Text(model.exportCurrentFile.isEmpty ? "正在准备导出…" : model.exportCurrentFile)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }.padding(18).background(leaf.opacity(0.08)).padding(.horizontal, 28).padding(.top, 16)
            }
            if let document = model.activeDocument {
                if document.isAnalyzing {
                    Spacer(); ProgressView("正在识别人物分组…"); Spacer()
                } else if let error = document.error {
                    VStack(spacing: 14) {
                        Image(systemName: "doc.badge.ellipsis").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
                        Text("这份素材还不能转换").font(.system(size: 20, weight: .semibold))
                        Text(error).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                        Button("试试内置示例", action: model.loadExample).padding(.top, 5)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
                } else {
                    controls
                    ScrollView {
                        if document.icons.isEmpty {
                            Text("暂未自动识别出人物，可以用「修正识别 → 补选人物」手动框选。")
                                .font(.system(size: 13)).foregroundStyle(.secondary).padding(30)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 164, maximum: 250), spacing: 16)], spacing: 16) {
                            ForEach(document.icons) { icon in iconCard(icon, stem: document.stem) }
                        }.padding(24)
                    }
                }
            } else { emptyState }
            footer
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            HStack {
                Text("\(model.activeDocument?.icons.count ?? 0) 个独立图标").font(.system(size: 12, weight: .medium))
                Button("全选") { model.selectCurrent(true) }.buttonStyle(.link).font(.system(size: 11))
                Button("取消选择") { model.selectCurrent(false) }.buttonStyle(.link).font(.system(size: 11))
                Spacer()
                Menu("修正识别") {
                    Button("补选人物…") { openEditor(.add) }
                    Button("合并当前所选图标") { model.mergeCurrent() }.disabled(model.currentSelectedCount < 2)
                    Button("撤销上次修改") { model.undoEdit() }.disabled(!model.canUndo)
                }.fixedSize()
            }.disabled(model.isImporting || model.isExporting)
            ColorPalette(model: model)
        }.padding(.horizontal, 26).padding(.vertical, 14)
    }

    private func openEditor(_ mode: EditorMode) {
        if let document = model.activeDocument { editorRequest = EditorRequest(document: document, mode: mode) }
    }

    private func iconCard(_ icon: Pictogram, stem: String) -> some View {
        let selected = model.selectedIcons.contains(icon.id)
        return Button { model.toggle(icon) } label: {
            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    TransparencyGrid()
                    SVGPreview(svg: icon.svg(color: selected ? model.exportColor : .original)).padding(23).allowsHitTesting(false).accessibilityHidden(true)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19)).foregroundStyle(selected ? leaf : Color.secondary.opacity(0.6))
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor))).padding(10)
                }.frame(height: 194).clipShape(RoundedRectangle(cornerRadius: 10))
                HStack {
                    Text(String(format: "%@-%02d.svg", stem, icon.number)).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 3)
                    Text("SVG").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }.padding(12).background(Color(nsColor: .controlBackgroundColor))
            }.clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? leaf.opacity(0.50) : Color.secondary.opacity(0.16), lineWidth: 1))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .contextMenu {
            Button("编辑人物路径…") { openEditor(.edit(icon.id)) }
            Button("拆分图标…") { openEditor(.split(icon.id)) }.disabled(icon.shapes.count < 2)
            Divider()
            Button("删除", role: .destructive) { model.deleteIcon(icon.id) }
        }.disabled(model.isExporting || model.isImporting)
        .accessibilityLabel("图标 \(icon.number)，\(selected ? "已选中" : "未选中")")
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle().fill(leaf.opacity(0.065)).frame(width: 154, height: 154)
                Image(systemName: "figure.arms.open").font(.system(size: 76, weight: .light)).foregroundStyle(leaf)
                Image(systemName: "sparkle").font(.system(size: 22)).foregroundStyle(leaf.opacity(0.65)).offset(x: 61, y: -54)
            }.padding(.bottom, 28)
            Text("把素材页变成独立图标").font(.system(size: 24, weight: .bold))
            Text("拖入文件，检查人物，一次导出。\n头部和身体保留在一起，背景始终透明。")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(6).padding(.top, 12)
            HStack(spacing: 12) {
                Button("选择 AI 素材", action: model.chooseInputs).buttonStyle(.borderedProminent)
                Button("用示例试试", action: model.loadExample).buttonStyle(.bordered)
            }.controlSize(.large).padding(.top, 25)
            Spacer()
            HStack(spacing: 28) {
                Label("不需要 Illustrator", systemImage: "checkmark.circle")
                Label("不会上传文件", systemImage: "lock")
                Label("保持矢量路径", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 34)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: model.exportLocation == nil ? "info.circle" : "checkmark.circle.fill").foregroundStyle(model.exportLocation == nil ? Color.secondary : leaf)
            Text(model.notice ?? "棋盘格仅用于预览，导出的 SVG 没有背景。")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            if model.exportLocation != nil { Button("在 Finder 中查看", action: model.revealOutput).font(.system(size: 11)) }
        }.padding(.horizontal, 26).padding(.vertical, 15).background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !model.isImporting, !model.isExporting else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let value = item as? URL { url = value }
                else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { model.importFiles(urls) }
        return true
    }
}
