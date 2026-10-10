import SwiftUI
import WebKit

struct SVGPreview: NSViewRepresentable {
    let svg: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        return webView
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.previous != svg else { return }
        context.coordinator.previous = svg
        let body = svg.replacingOccurrences(of: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>", with: "")
        view.loadHTMLString("""
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <style>html,body{margin:0;width:100%;height:100%;background:transparent;overflow:hidden;pointer-events:none}body{display:flex;align-items:center;justify-content:center}svg{width:auto;height:auto;max-width:100%;max-height:100%}</style></head><body>\(body)</body></html>
        """, baseURL: nil)
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var previous: String?
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
        }
    }
}

struct TransparencyGrid: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 12
            let a = colorScheme == .dark ? Color(white: 0.21) : Color(red: 0.96, green: 0.97, blue: 0.98)
            let b = colorScheme == .dark ? Color(white: 0.26) : Color(red: 0.90, green: 0.92, blue: 0.94)
            for row in 0...Int(size.height/tile) {
                for column in 0...Int(size.width/tile) {
                    let rect = CGRect(x: CGFloat(column)*tile, y: CGFloat(row)*tile, width: tile, height: tile)
                    context.fill(Path(rect), with: .color((row+column)%2 == 0 ? a : b))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

