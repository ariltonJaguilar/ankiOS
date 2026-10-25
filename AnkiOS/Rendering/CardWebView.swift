import SwiftUI
import WebKit
import UIKit

struct CardWebView: UIViewRepresentable {
    let html: String
    let baseURL: URL
    var onSoundTap: ((String) -> Void)?
    var onSpeechTap: ((CardHTMLRenderer.SpeechRequest) -> Void)?
    var onVideoFramesChanged: (([CGRect]) -> Void)?
    var scrollRequest = 0
    var scrollDirection = 0
    var userActionRequest = 0
    var userActionNumber: Int?
    var userActionScript = ""

    func makeCoordinator() -> Coordinator {
        Coordinator(onSoundTap: onSoundTap, onSpeechTap: onSpeechTap, onVideoFramesChanged: onVideoFramesChanged)
    }

    func makeUIView(context: Context) -> WKWebView {
        let web = makeWebView(handler: context.coordinator)
        context.coordinator.webView = web
        context.coordinator.lastHTML = html
        context.coordinator.lastScrollRequest = scrollRequest
        context.coordinator.lastUserActionRequest = userActionRequest
        web.loadHTMLString(html, baseURL: baseURL)
        return web
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onSoundTap = onSoundTap
        context.coordinator.onSpeechTap = onSpeechTap
        context.coordinator.onVideoFramesChanged = onVideoFramesChanged
        context.coordinator.webView = webView
        context.coordinator.updateRequests(
            scrollRequest: scrollRequest,
            scrollDirection: scrollDirection,
            userActionRequest: userActionRequest,
            userActionNumber: userActionNumber,
            userActionScript: userActionScript,
            webView: webView
        )
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        var lastHTML: String?
        var onSoundTap: ((String) -> Void)?
        var onSpeechTap: ((CardHTMLRenderer.SpeechRequest) -> Void)?
        var onVideoFramesChanged: (([CGRect]) -> Void)?
        weak var webView: WKWebView?
        var lastScrollRequest = 0
        var pendingScrollDirection = 0
        var lastUserActionRequest = 0
        var pendingUserAction: (number: Int, script: String)?

        init(
            onSoundTap: ((String) -> Void)?,
            onSpeechTap: ((CardHTMLRenderer.SpeechRequest) -> Void)?,
            onVideoFramesChanged: (([CGRect]) -> Void)?
        ) {
            self.onSoundTap = onSoundTap
            self.onSpeechTap = onSpeechTap
            self.onVideoFramesChanged = onVideoFramesChanged
        }

        func updateRequests(
            scrollRequest: Int,
            scrollDirection: Int,
            userActionRequest: Int,
            userActionNumber: Int?,
            userActionScript: String,
            webView: WKWebView
        ) {
            if scrollRequest != lastScrollRequest {
                lastScrollRequest = scrollRequest
                pendingScrollDirection = scrollDirection
            }
            if userActionRequest != lastUserActionRequest {
                lastUserActionRequest = userActionRequest
                if let userActionNumber {
                    pendingUserAction = (userActionNumber, userActionScript)
                }
            }
            flushRequests(in: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            flushRequests(in: webView)
        }

        private func flushRequests(in webView: WKWebView) {
            guard !webView.isLoading else { return }
            if pendingScrollDirection != 0 {
                let distance = max(webView.scrollView.bounds.height * 0.8, 120)
                let offset = Int(distance * CGFloat(pendingScrollDirection))
                webView.evaluateJavaScript("window.scrollBy({top:\(offset), behavior:'smooth'});")
                pendingScrollDirection = 0
            }
            if let request = pendingUserAction {
                pendingUserAction = nil
                let actionName = "userJs\(request.number)"
                let setup = request.script.contains(actionName)
                    ? request.script
                    : "window.\(actionName) = \(request.script);"
                webView.evaluateJavaScript("\(setup)\nif (typeof window.\(actionName) === 'function') window.\(actionName)();")
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "ankiVideoFrames", let rawFrames = message.body as? [[String: Any]], let webView {
                let frames = rawFrames.compactMap { frame -> CGRect? in
                    guard let x = (frame["x"] as? NSNumber)?.doubleValue,
                          let y = (frame["y"] as? NSNumber)?.doubleValue,
                          let width = (frame["width"] as? NSNumber)?.doubleValue,
                          let height = (frame["height"] as? NSNumber)?.doubleValue else { return nil }
                    return webView.convert(CGRect(x: x, y: y, width: width, height: height), to: nil)
                }
                onVideoFramesChanged?(frames)
            } else if message.name == "ankiSound", let file = message.body as? String {
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
    UIApplication.shared.open(url)
}

@MainActor private func makeWebView(handler: WKScriptMessageHandler) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.defaultWebpagePreferences.allowsContentJavaScript = true
    config.setURLSchemeHandler(MathJaxResourceHandler(), forURLScheme: "ankimathjax")
    let uc = config.userContentController
    uc.removeScriptMessageHandler(forName: "ankiSound")
    uc.removeScriptMessageHandler(forName: "ankiSpeech")
    uc.add(handler, name: "ankiSound")
    uc.add(handler, name: "ankiSpeech")
    uc.add(handler, name: "ankiVideoFrames")
    let videoFrameScript = """
    (function(){
      let pending = false;
      function report(){
        pending = false;
        const frames = Array.from(document.querySelectorAll('video')).map(video => {
          const rect = video.getBoundingClientRect();
          return {x:rect.x,y:rect.y,width:rect.width,height:rect.height};
        }).filter(rect => rect.width > 0 && rect.height > 0);
        window.webkit.messageHandlers.ankiVideoFrames.postMessage(frames);
      }
      function schedule(){
        if (pending) return;
        pending = true;
        requestAnimationFrame(report);
      }
      window.addEventListener('scroll', schedule, {passive:true});
      window.addEventListener('resize', schedule);
      new MutationObserver(schedule).observe(document.documentElement, {childList:true,subtree:true,attributes:true});
      schedule();
    })();
    """
    uc.addUserScript(WKUserScript(source: videoFrameScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
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
    web.isOpaque = false
    web.backgroundColor = .clear
    web.scrollView.backgroundColor = .clear
    web.scrollView.contentInsetAdjustmentBehavior = .never
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
