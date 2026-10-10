import SwiftUI
import AppKit
import VectorEngine

struct ColorPalette: View {
    @ObservedObject var model: ConversionModel
    @State private var hexDraft = "#FFC400"
    private let presets: [(String, String)] = [("黑色", "#000000"), ("白色", "#FFFFFF"), ("黄色", "#FFC400"), ("红色", "#E64040"), ("蓝色", "#2878E0"), ("紫色", "#9254DE"), ("绿色", "#2E8B57"), ("橙色", "#F58220")]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("批量调色").font(.system(size: 12, weight: .medium))
                Button("原色") { model.exportColor = .original }
                    .buttonStyle(.bordered).tint(model.exportColor == .original ? .accentColor : .secondary)
                ForEach(presets, id: \.1) { name, hex in
                    Button { model.setHexColor(hex) } label: {
                        Circle().fill(color(hex)).frame(width: 22, height: 22)
                            .overlay(Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 1))
                            .padding(3)
                            .overlay(Circle().stroke(model.exportColor.hex == hex ? Color.accentColor : .clear, lineWidth: 2))
                    }.buttonStyle(.plain).help(name).accessibilityLabel("改为" + name)
                }
                Spacer(minLength: 4)
                ColorPicker("自选颜色", selection: Binding(get: { color(model.exportColor.hex ?? hexDraft) }, set: { value in
                    guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
                    model.setHexColor(String(format: "#%02X%02X%02X", Int((rgb.redComponent*255).rounded()), Int((rgb.greenComponent*255).rounded()), Int((rgb.blueComponent*255).rounded())))
                }), supportsOpacity: false).font(.system(size: 11)).fixedSize()
                TextField("#FFC400", text: $hexDraft).font(.system(size: 11, design: .monospaced)).frame(width: 78)
                    .onSubmit { model.setHexColor(hexDraft) }.accessibilityLabel("HEX 色值")
                Button("应用") { model.setHexColor(hexDraft) }.font(.system(size: 11))
            }
            Text("统一应用到所有素材中勾选的 \(model.selectedCount) 个图标，背景和镂空保持透明。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .onAppear { if let hex = model.exportColor.hex { hexDraft = hex } }
        .onChange(of: model.exportColor) { value in if let hex = value.hex { hexDraft = hex } }
        .disabled(model.isExporting)
    }
    private func color(_ hex: String) -> Color {
        let canonical = ExportColor(hex: hex)?.hex ?? "#FFC400"
        let value = UInt32(canonical.dropFirst(), radix: 16) ?? 0xFFC400
        return Color(red: Double((value >> 16) & 255)/255, green: Double((value >> 8) & 255)/255, blue: Double(value & 255)/255)
    }
}
