import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#endif

#if os(iOS)
struct CardWebView: UIViewRepresentable {
    let html: String
    let baseURL: URL
    var onSoundTap: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(onSoundTap: onSoundTap) }

    func makeUIView(context: Context) -> WKWebView {
        let web = makeWebView(handler: context.coordinator)
        context.coordinator.lastHTML = html
        web.loadHTMLString(html, baseURL: baseURL)
        return web
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onSoundTap = onSoundTap
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var lastHTML: String?
        var onSoundTap: ((String) -> Void)?

        init(onSoundTap: ((String) -> Void)?) {
            self.onSoundTap = onSoundTap
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "ankiSound", let file = message.body as? String else { return }
            onSoundTap?(file)
        }
    }
}
#else
struct CardWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL
    var onSoundTap: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(onSoundTap: onSoundTap) }

    func makeNSView(context: Context) -> WKWebView {
        let web = makeWebView(handler: context.coordinator)
        context.coordinator.lastHTML = html
        web.loadHTMLString(html, baseURL: baseURL)
        return web
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onSoundTap = onSoundTap
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var lastHTML: String?
        var onSoundTap: ((String) -> Void)?

        init(onSoundTap: ((String) -> Void)?) {
            self.onSoundTap = onSoundTap
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "ankiSound", let file = message.body as? String else { return }
            onSoundTap?(file)
        }
    }
}
#endif

private func makeWebView(handler: WKScriptMessageHandler) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.defaultWebpagePreferences.allowsContentJavaScript = true
    #if os(macOS)
    config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
    #endif
    let uc = config.userContentController
    uc.removeScriptMessageHandler(forName: "ankiSound")
    uc.add(handler, name: "ankiSound")
    let clickJS = """
    document.addEventListener('click', function(e) {
      var el = e.target.closest('.sound');
      if (!el) return;
      var file = el.getAttribute('data-file');
      if (file && window.webkit && window.webkit.messageHandlers.ankiSound) {
        window.webkit.messageHandlers.ankiSound.postMessage(file);
      }
    }, true);
    """
    uc.addUserScript(WKUserScript(source: clickJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    if !MathJaxBridge.source.isEmpty {
        uc.addUserScript(WKUserScript(source: MathJaxBridge.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }
    let web = WKWebView(frame: .zero, configuration: config)
    #if os(macOS)
    web.setValue(false, forKey: "drawsBackground")
    #endif
    #if os(iOS)
    web.isOpaque = false
    web.backgroundColor = .clear
    web.scrollView.backgroundColor = .clear
    web.scrollView.contentInsetAdjustmentBehavior = .never
    #else
    web.appearance = NSAppearance(named: .darkAqua)
    #endif
    return web
}

/// Anki's MathJax delimiters, typeset offline with the bundled KaTeX build.
private enum MathJaxBridge {
    static let source: String = {
        let bootstrap = """
        function ankiosTypesetMath(root){
          if (typeof katex === 'undefined' || !root) return;
          var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
          var nodes = [];
          var n;
          while ((n = walker.nextNode())) nodes.push(n);
          var re = /\\\\\\[([\\s\\S]+?)\\\\\\]|\\\\\\(([\\s\\S]+?)\\\\\\)/g;
          nodes.forEach(function(node){
            var parent = node.parentNode;
            if (!parent || parent.tagName === 'SCRIPT' || parent.tagName === 'STYLE') return;
            var text = node.nodeValue;
            if (!text || text.indexOf('\\\\') === -1) return;
            re.lastIndex = 0;
            if (!re.test(text)) return;
            re.lastIndex = 0;
            var frag = document.createDocumentFragment();
            var last = 0, m;
            while ((m = re.exec(text))) {
              if (m.index > last) frag.appendChild(document.createTextNode(text.slice(last, m.index)));
              var display = m[1] != null;
              var tex = display ? m[1] : m[2];
              var holder = document.createElement(display ? 'div' : 'span');
              holder.className = 'mathjax';
              try {
                holder.innerHTML = katex.renderToString(tex, {throwOnError:false, displayMode:display, output:'mathml'});
              } catch (e) {
                holder.textContent = tex;
              }
              frag.appendChild(holder);
              last = re.lastIndex;
            }
            if (last < text.length) frag.appendChild(document.createTextNode(text.slice(last)));
            parent.replaceChild(frag, node);
          });
        }
        ankiosTypesetMath(document.body);
        """
        guard let url = Bundle.main.url(forResource: "katex.min", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8),
              !js.isEmpty else { return "" }
        return js + "\n" + bootstrap
    }()
}
