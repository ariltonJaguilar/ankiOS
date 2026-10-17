import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(iOS)
struct CardWebView: UIViewRepresentable {
    let html: String
    let baseURL: URL
    var onSoundTap: ((String) -> Void)?
    var onSpeechTap: ((CardHTMLRenderer.SpeechRequest) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(onSoundTap: onSoundTap, onSpeechTap: onSpeechTap) }

    func makeUIView(context: Context) -> WKWebView {
        let web = makeWebView(handler: context.coordinator)
        context.coordinator.lastHTML = html
        web.loadHTMLString(html, baseURL: baseURL)
        return web
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onSoundTap = onSoundTap
        context.coordinator.onSpeechTap = onSpeechTap
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        var lastHTML: String?
        var onSoundTap: ((String) -> Void)?
        var onSpeechTap: ((CardHTMLRenderer.SpeechRequest) -> Void)?

        init(onSoundTap: ((String) -> Void)?, onSpeechTap: ((CardHTMLRenderer.SpeechRequest) -> Void)?) {
            self.onSoundTap = onSoundTap
            self.onSpeechTap = onSpeechTap
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "ankiSound", let file = message.body as? String {
                onSoundTap?(file)
            } else if message.name == "ankiSpeech", let request = speechRequest(from: message.body) {
                onSpeechTap?(request)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                return .allow
            }
            guard !isSameDocumentAnchor(url, currentURL: webView.url) else {
                return .allow
            }
            openCardLink(url)
            return .cancel
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let url = navigationAction.request.url else { return nil }
            openCardLink(url)
            return nil
        }
    }
}
#else
struct CardWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL
    var onSoundTap: ((String) -> Void)?
    var onSpeechTap: ((CardHTMLRenderer.SpeechRequest) -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(onSoundTap: onSoundTap, onSpeechTap: onSpeechTap) }

    func makeNSView(context: Context) -> WKWebView {
        let web = makeWebView(handler: context.coordinator)
        web.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        context.coordinator.lastHTML = html
        web.loadHTMLString(html, baseURL: baseURL)
        return web
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onSoundTap = onSoundTap
        context.coordinator.onSpeechTap = onSpeechTap
        webView.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        var lastHTML: String?
        var onSoundTap: ((String) -> Void)?
        var onSpeechTap: ((CardHTMLRenderer.SpeechRequest) -> Void)?

        init(onSoundTap: ((String) -> Void)?, onSpeechTap: ((CardHTMLRenderer.SpeechRequest) -> Void)?) {
            self.onSoundTap = onSoundTap
            self.onSpeechTap = onSpeechTap
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "ankiSound", let file = message.body as? String {
                onSoundTap?(file)
            } else if message.name == "ankiSpeech", let request = speechRequest(from: message.body) {
                onSpeechTap?(request)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                return .allow
            }
            guard !isSameDocumentAnchor(url, currentURL: webView.url) else {
                return .allow
            }
            openCardLink(url)
            return .cancel
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let url = navigationAction.request.url else { return nil }
            openCardLink(url)
            return nil
        }
    }
}
#endif

private func isSameDocumentAnchor(_ url: URL, currentURL: URL?) -> Bool {
    guard let currentURL,
          var destination = URLComponents(url: url, resolvingAgainstBaseURL: true),
          var current = URLComponents(url: currentURL, resolvingAgainstBaseURL: true),
          destination.fragment != nil else { return false }
    destination.fragment = nil
    current.fragment = nil
    return destination.url == current.url
}

@MainActor private func openCardLink(_ url: URL) {
    guard let scheme = url.scheme?.lowercased(),
          !["javascript", "data", "file", "blob", "about"].contains(scheme) else { return }
    #if os(iOS)
    UIApplication.shared.open(url)
    #else
    NSWorkspace.shared.open(url)
    #endif
}

@MainActor private func makeWebView(handler: WKScriptMessageHandler) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.defaultWebpagePreferences.allowsContentJavaScript = true
    config.setURLSchemeHandler(MathJaxResourceHandler(), forURLScheme: "ankimathjax")
    #if os(macOS)
    config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
    #endif
    let uc = config.userContentController
    uc.removeScriptMessageHandler(forName: "ankiSound")
    uc.removeScriptMessageHandler(forName: "ankiSpeech")
    uc.add(handler, name: "ankiSound")
    uc.add(handler, name: "ankiSpeech")
    let ankiTemplateBootstrap = """
    window.anki = window.anki || {};
    if (typeof window.anki.qFade === 'undefined') window.anki.qFade = 100;
    """
    uc.addUserScript(WKUserScript(source: ankiTemplateBootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    let clickJS = """
    document.addEventListener('click', function(e) {
      var speech = e.target.closest('anki-tts');
      if (speech) {
        if (window.webkit && window.webkit.messageHandlers.ankiSpeech) {
          window.webkit.messageHandlers.ankiSpeech.postMessage({
            language: speech.getAttribute('data-lang') || '',
            speed: speech.getAttribute('data-speed') || '1',
            voices: speech.getAttribute('data-voices') || '',
            text: speech.getAttribute('data-text') || ''
          });
        }
        return;
      }
      var el = e.target.closest('.sound');
      if (!el) return;
      var file = el.getAttribute('data-file');
      if (file && window.webkit && window.webkit.messageHandlers.ankiSound) {
        window.webkit.messageHandlers.ankiSound.postMessage(file);
      }
    }, true);
    """
    uc.addUserScript(WKUserScript(source: clickJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    let ankiTemplateFinish = """
    (function(){
      var card = document.querySelector('.card');
      if (!card) return;
      if (document.body.dataset.side === 'answer') {
        var answer = document.getElementById('answer');
        if (answer) answer.scrollIntoView({block: 'start'});
        return;
      }
      var duration = Number(window.anki && window.anki.qFade !== undefined ? window.anki.qFade : window.qFade);
      if (!Number.isFinite(duration) || duration <= 0) return;
      card.style.opacity = '0';
      card.style.transition = 'opacity ' + duration + 'ms';
      requestAnimationFrame(function(){
        requestAnimationFrame(function(){ card.style.opacity = '1'; });
      });
    })();
    """
    uc.addUserScript(WKUserScript(source: ankiTemplateFinish, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    if !MathJaxBridge.source.isEmpty {
        uc.addUserScript(WKUserScript(source: MathJaxBridge.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }
    let web = WKWebView(frame: .zero, configuration: config)
    web.navigationDelegate = handler as? WKNavigationDelegate
    web.uiDelegate = handler as? WKUIDelegate
    #if os(macOS)
    web.setValue(false, forKey: "drawsBackground")
    #endif
    #if os(iOS)
    web.isOpaque = false
    web.backgroundColor = .clear
    web.scrollView.backgroundColor = .clear
    web.scrollView.contentInsetAdjustmentBehavior = .never
    #endif
    return web
}

private func speechRequest(from body: Any) -> CardHTMLRenderer.SpeechRequest? {
    guard let payload = body as? [String: Any],
          let language = payload["language"] as? String,
          let speedText = payload["speed"] as? String,
          let speed = Float(speedText),
          let encodedVoices = payload["voices"] as? String,
          let voiceData = Data(base64Encoded: encodedVoices),
          let voices = try? JSONDecoder().decode([String].self, from: voiceData),
          let encodedText = payload["text"] as? String,
          let textData = Data(base64Encoded: encodedText),
          let text = String(data: textData, encoding: .utf8) else { return nil }
    return CardHTMLRenderer.SpeechRequest(language: language, text: text, speed: speed, voices: voices)
}

private enum MathJaxBridge {
    static let source = """
    (function(){
      var root = document.querySelector('.card');
      if (!root) return;
      var content = root.innerHTML;
      if (content.indexOf('\\\\(') === -1 && content.indexOf('\\\\[') === -1) return;
      var config = window.MathJax || {};
      config.loader = config.loader || {};
      config.loader.paths = Object.assign({mathjax:'ankimathjax://bundle'}, config.loader.paths || {});
      config.tex = config.tex || {};
      config.tex.inlineMath = config.tex.inlineMath || [['\\\\(', '\\\\)']];
      config.tex.displayMath = config.tex.displayMath || [['\\\\[', '\\\\]']];
      config.tex.packages = config.tex.packages || ['base','ams','autoload','newcommand','noundefined','require','mhchem','mathtools','physics','unicode'];
      config.chtml = Object.assign({fontURL:'ankimathjax://bundle/output/chtml/fonts/woff-v2'}, config.chtml || {});
      config.startup = config.startup || {};
      config.startup.typeset = false;
      window.MathJax = config;
      var script = document.createElement('script');
      script.src = 'ankimathjax://bundle/tex-chtml-full.js';
      script.onload = function(){
        if (window.MathJax && window.MathJax.startup && window.MathJax.startup.promise) {
          window.MathJax.startup.promise.then(function(){
            return window.MathJax.typesetPromise([document.body]);
          });
        }
      };
      document.head.appendChild(script);
    })();
    """
}

@MainActor
private final class MathJaxResourceHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              url.host == "bundle",
              let root = Bundle.main.url(forResource: "MathJax", withExtension: nil)?.appendingPathComponent("es5", isDirectory: true) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let relativePath = url.pathComponents.dropFirst().joined(separator: "/")
        let fileURL = root.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard fileURL.path.hasPrefix(rootPath + "/"),
              let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mimeType: String
        switch fileURL.pathExtension.lowercased() {
        case "js": mimeType = "application/javascript"
        case "woff": mimeType = "font/woff"
        case "json": mimeType = "application/json"
        default: mimeType = "application/octet-stream"
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mimeType, "Access-Control-Allow-Origin": "*"]
        ) ?? URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil)
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
