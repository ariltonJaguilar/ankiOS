#if os(iOS)
import SwiftUI
import WebKit

struct SharedDeckBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    let onDeckDownloaded: (URL) -> Void

    @State private var isLoading = true
    @State private var isDownloading = false
    @State private var requiresAuthentication = false
    @State private var isShowingLogin = false
    @State private var loginRequestID = 0
    @State private var returnRequestID = 0
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                AppBackground()
                SharedDeckBrowserWebView(
                    onLoadingChanged: { isLoading = $0 },
                    onDownloadStarted: { isLoading = false; isDownloading = true },
                    onDownloadCancelled: { isLoading = false; isDownloading = false },
                    onDeckDownloaded: onDeckDownloaded,
                    onDownloadFailed: { errorMessage = $0; isLoading = false; isDownloading = false },
                    onAuthenticationRequired: { requiresAuthentication = true },
                    onLoginFlowEnded: { isShowingLogin = false },
                    loginRequestID: $loginRequestID,
                    returnRequestID: $returnRequestID
                )
                .ignoresSafeArea(edges: .bottom)

                if isLoading || isDownloading {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(AppTheme.accent)
                        Text(isDownloading ? "Baixando baralho…" : "Carregando…")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AppTheme.primaryText)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .ankiGlass(in: Capsule())
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .contentShape(Rectangle())
                }

                if requiresAuthentication {
                    VStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                            .font(.system(size: 34))
                            .foregroundStyle(AppTheme.accent)
                        Text("Entre no AnkiWeb para continuar")
                            .font(.headline)
                            .foregroundStyle(AppTheme.primaryText)
                        Text("O login de sincronização do app não inicia a sessão do site. Entre no AnkiWeb nesta tela e depois volte à lista para buscar e baixar baralhos.")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText)
                            .multilineTextAlignment(.center)
                        Button {
                            requiresAuthentication = false
                            isShowingLogin = true
                            loginRequestID += 1
                        } label: {
                            Label("Entrar no AnkiWeb", systemImage: "person.crop.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.accent)
                        .accessibilityIdentifier("sharedDecks.login")
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity)
                    .ankiGlass(in: RoundedRectangle(cornerRadius: 24))
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.35))
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("sharedDecks.loginRequired")
                }
            }
            .navigationTitle("Baralhos compartilhados")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isShowingLogin {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Voltar à lista") {
                            isShowingLogin = false
                            returnRequestID += 1
                        }
                        .accessibilityIdentifier("sharedDecks.returnToList")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fechar") { dismiss() }
                }
            }
            .alert("Não foi possível abrir ou baixar", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}

private struct SharedDeckBrowserWebView: UIViewRepresentable {
    private static let authenticationMessageHandlerName = "ankiOSSharedDeckAuthentication"

    var onLoadingChanged: (Bool) -> Void
    var onDownloadStarted: () -> Void
    var onDownloadCancelled: () -> Void
    var onDeckDownloaded: (URL) -> Void
    var onDownloadFailed: (String) -> Void
    var onAuthenticationRequired: () -> Void
    var onLoginFlowEnded: () -> Void
    @Binding var loginRequestID: Int
    @Binding var returnRequestID: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onLoadingChanged: onLoadingChanged,
            onDownloadStarted: onDownloadStarted,
            onDownloadCancelled: onDownloadCancelled,
            onDeckDownloaded: onDeckDownloaded,
            onDownloadFailed: onDownloadFailed,
            onAuthenticationRequired: onAuthenticationRequired,
            onLoginFlowEnded: onLoginFlowEnded
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: Self.authenticationMessageHandlerName)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: URL(string: "https://ankiweb.net/shared/decks/")!))
        return webView
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: authenticationMessageHandlerName)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.loginRequestID != loginRequestID {
            context.coordinator.loginRequestID = loginRequestID
            context.coordinator.beginLogin(in: webView)
        } else if context.coordinator.returnRequestID != returnRequestID {
            context.coordinator.returnRequestID = returnRequestID
            context.coordinator.returnToRequestedPage(in: webView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
        private let onLoadingChanged: (Bool) -> Void
        private let onDownloadStarted: () -> Void
        private let onDownloadCancelled: () -> Void
        private let onDeckDownloaded: (URL) -> Void
        private let onDownloadFailed: (String) -> Void
        private let onAuthenticationRequired: () -> Void
        private let onLoginFlowEnded: () -> Void
        private var destinationURL: URL?
        private var activeDownload: WKDownload?
        private weak var currentWebView: WKWebView?
        private var loginReturnURL: URL?
        private var loginReturnItem: WKBackForwardListItem?
        private var isLoginFlowActive = false
        var loginRequestID = 0
        var returnRequestID = 0

        init(
            onLoadingChanged: @escaping (Bool) -> Void,
            onDownloadStarted: @escaping () -> Void,
            onDownloadCancelled: @escaping () -> Void,
            onDeckDownloaded: @escaping (URL) -> Void,
            onDownloadFailed: @escaping (String) -> Void,
            onAuthenticationRequired: @escaping () -> Void,
            onLoginFlowEnded: @escaping () -> Void
        ) {
            self.onLoadingChanged = onLoadingChanged
            self.onDownloadStarted = onDownloadStarted
            self.onDownloadCancelled = onDownloadCancelled
            self.onDeckDownloaded = onDeckDownloaded
            self.onDownloadFailed = onDownloadFailed
            self.onAuthenticationRequired = onAuthenticationRequired
            self.onLoginFlowEnded = onLoginFlowEnded
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            currentWebView = webView
            onLoadingChanged(true)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadingChanged(false)
            webView.evaluateJavaScript(Self.authenticationObserverScript)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == SharedDeckBrowserWebView.authenticationMessageHandlerName else { return }
            switch message.body as? String {
            case "authenticationRequired":
                onAuthenticationRequired()
            case "authenticated":
                guard isLoginFlowActive, let currentWebView else { return }
                returnToRequestedPage(in: currentWebView)
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if Self.isNavigationInterruption(error) {
                onLoadingChanged(false)
                return
            }
            onLoadingChanged(false)
            onDownloadFailed(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard Self.isApkgURL(navigationAction.request.url) else { return .allow }
            return .download
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            guard Self.isDownloadResponse(navigationResponse.response) else { return .allow }
            return .download
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            configure(download)
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            configure(download)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil else { return nil }
            webView.load(navigationAction.request)
            return nil
        }

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
        ) {
            guard Self.isApkgResponse(response) || suggestedFilename.lowercased().hasSuffix(".apkg") else {
                completionHandler(nil)
                onDownloadFailed("O arquivo recebido não é um pacote .apkg do Anki.")
                return
            }
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("AnkiOS-Shared-\(UUID().uuidString).apkg")
            destinationURL = destination
            completionHandler(destination)
        }

        func downloadDidFinish(_ download: WKDownload) {
            activeDownload = nil
            guard let destinationURL,
                  FileManager.default.fileExists(atPath: destinationURL.path) else {
                self.destinationURL = nil
                onDownloadFailed("O download terminou sem gerar um arquivo .apkg.")
                return
            }
            self.destinationURL = nil
            onDeckDownloaded(destinationURL)
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            activeDownload = nil
            if let destinationURL {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            destinationURL = nil
            if Self.isNavigationInterruption(error) {
                onDownloadCancelled()
                return
            }
            onDownloadFailed(error.localizedDescription)
        }

        private func configure(_ download: WKDownload) {
            activeDownload = download
            download.delegate = self
            onDownloadStarted()
        }

        private static let authenticationObserverScript = """
        (() => {
          if (window.__ankiOSSharedDeckAuthObserver) return;
          window.__ankiOSSharedDeckAuthObserver = true;
          const checkAuthentication = () => {
            const text = (document.body?.innerText || '').toLowerCase();
            const needsAuthentication = text.includes('please log in to download more decks')
              || text.includes('please log in to perform more searches');
            if (needsAuthentication && !window.__ankiOSSharedDeckAuthReported) {
              window.__ankiOSSharedDeckAuthReported = true;
              window.webkit.messageHandlers.ankiOSSharedDeckAuthentication.postMessage('authenticationRequired');
            }
            const hasPasswordField = !!document.querySelector('input[type="password"]');
            const isAuthenticatedHome = !hasPasswordField && text.includes('collection:');
            if (isAuthenticatedHome && !window.__ankiOSSharedDeckAuthCompleted) {
              window.__ankiOSSharedDeckAuthCompleted = true;
              window.webkit.messageHandlers.ankiOSSharedDeckAuthentication.postMessage('authenticated');
            }
          };
          const observer = new MutationObserver(checkAuthentication);
          observer.observe(document.documentElement, { childList: true, subtree: true, characterData: true });
          checkAuthentication();
          window.addEventListener('pagehide', () => observer.disconnect(), { once: true });
        })();
        """

        func beginLogin(in webView: WKWebView) {
            if loginReturnURL == nil {
                loginReturnURL = webView.url
                loginReturnItem = webView.backForwardList.currentItem
            }
            isLoginFlowActive = true
            guard let url = URL(string: "https://ankiweb.net/decks") else { return }
            webView.load(URLRequest(url: url))
        }

        func returnToRequestedPage(in webView: WKWebView) {
            isLoginFlowActive = false
            onLoginFlowEnded()
            let returnItem = loginReturnItem
            let returnURL = loginReturnURL
            loginReturnItem = nil
            loginReturnURL = nil
            if let returnItem, webView.go(to: returnItem) != nil {
                return
            }
            guard let returnURL else { return }
            webView.load(URLRequest(url: returnURL))
        }

        private static func isApkgURL(_ url: URL?) -> Bool {
            url?.pathExtension.lowercased() == "apkg"
        }

        private static func isApkgResponse(_ response: URLResponse) -> Bool {
            response.url?.pathExtension.lowercased() == "apkg"
                || response.suggestedFilename?.lowercased().hasSuffix(".apkg") == true
        }

        private static func isDownloadResponse(_ response: URLResponse) -> Bool {
            isApkgResponse(response)
                || (response as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "Content-Disposition")?
                    .localizedCaseInsensitiveContains("attachment") == true
        }

        private static func isNavigationInterruption(_ error: Error) -> Bool {
            let navigationError = error as NSError
            if navigationError.domain == NSURLErrorDomain,
               navigationError.code == NSURLErrorCancelled {
                return true
            }
            let description = error.localizedDescription.lowercased()
            return description.contains("frame load interrupted")
                || description.contains("carregamento do quadro interrompido")
        }
    }
}
#endif
