import SwiftUI
import AppKit

@main
struct StickSVGApp: App {
    @StateObject private var model = ConversionModel()
    var body: some Scene {
        WindowGroup("AI转SVG") {
            ContentView(model: model)
                .frame(minWidth: 1000, minHeight: 640)
                .tint(Color(red: 0.18, green: 0.54, blue: 0.32))
                .onOpenURL { model.importFiles([$0]) }
        }
        .defaultSize(width: 1080, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .pasteboard) {
                Button("从剪贴板导入矢量对象") { model.importClipboard() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(model.isImporting || model.isExporting)
            }
            CommandGroup(replacing: .newItem) {
                Button("导入 AI 素材…") { model.chooseInputs() }.keyboardShortcut("o")
                Button("导出选中的 SVG…") { model.chooseOutput() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(model.selectedCount == 0 || model.isExporting || model.isImporting)
            }
        }
    }
}

