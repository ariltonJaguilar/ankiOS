import SwiftUI
import WebKit

/// Minimal contenteditable HTML field (Anki-style rich text).
struct RichFieldEditor: View {
    @Binding var html: String
    var minHeight: CGFloat = 120

    var body: some View {
        RichFieldWebView(html: $html)
            .frame(minHeight: minHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

#if os(iOS)
private struct RichFieldWebView: UIViewRepresentable {
    @Binding var html: String

    func makeCoordinator() -> Coordinator { Coordinator(html: $html) }

    func makeUIView(context: Context) -> WKWebView {
        let web = makeEditorWebView(coordinator: context.coordinator)
        context.coordinator.webView = web
        load(web)
        return web
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.html = $html
        // Avoid clobbering caret while typing
        if !context.coordinator.isEditing {
            load(webView)
        }
    }

    private func load(_ web: WKWebView) {
        web.loadHTMLString(editorDocument(html), baseURL: nil)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var html: Binding<String>
        weak var webView: WKWebView?
        var isEditing = false

        init(html: Binding<String>) { self.html = html }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "ankiField", let body = message.body as? String else { return }
            isEditing = true
            html.wrappedValue = body
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.isEditing = false
            }
        }
    }
}
#else
private struct RichFieldWebView: NSViewRepresentable {
    @Binding var html: String

    func makeCoordinator() -> Coordinator { Coordinator(html: $html) }

    func makeNSView(context: Context) -> WKWebView {
        let web = makeEditorWebView(coordinator: context.coordinator)
        context.coordinator.webView = web
        web.loadHTMLString(editorDocument(html), baseURL: nil)
        return web
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.html = $html
        if !context.coordinator.isEditing {
            webView.loadHTMLString(editorDocument(html), baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var html: Binding<String>
        weak var webView: WKWebView?
        var isEditing = false

        init(html: Binding<String>) { self.html = html }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "ankiField", let body = message.body as? String else { return }
            isEditing = true
            html.wrappedValue = body
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.isEditing = false
            }
        }
    }
}
#endif

private func makeEditorWebView(coordinator: NSObject & WKScriptMessageHandler) -> WKWebView {
    let config = WKWebViewConfiguration()
    let uc = config.userContentController
    uc.add(coordinator, name: "ankiField")
    let web = WKWebView(frame: .zero, configuration: config)
    #if os(macOS)
    web.setValue(false, forKey: "drawsBackground")
    #endif
    #if os(iOS)
    web.isOpaque = false
    web.backgroundColor = .clear
    web.scrollView.backgroundColor = .clear
    #endif
    return web
}

private func editorDocument(_ html: String) -> String {
    let escaped = html
        .replacingOccurrences(of: "</script>", with: "<\\/script>")
    return """
    <!DOCTYPE html><html><head>
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
    <style>
      html,body{margin:0;padding:0;background:transparent;color:#e8f4f5;
        font:16px -apple-system,BlinkMacSystemFont,sans-serif;}
      #ed{min-height:100px;padding:10px;outline:none;}
    </style></head><body>
    <div id="ed" contenteditable="true">\(escaped)</div>
    <script>
      const ed = document.getElementById('ed');
      function push(){ window.webkit.messageHandlers.ankiField.postMessage(ed.innerHTML); }
      ed.addEventListener('input', push);
      ed.addEventListener('blur', push);
    </script>
    </body></html>
    """
}
