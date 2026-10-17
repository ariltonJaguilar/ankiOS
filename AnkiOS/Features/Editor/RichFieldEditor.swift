import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct NoteFieldEditor: View {
    @EnvironmentObject private var store: CollectionStore
    @Binding var html: String
    let field: AnkiField
    let isClozeType: Bool
    let mediaBase: URL
    var sourceMode: Bool
    var nextClozeNumber: Int
    @State private var expanded: Bool
    @State private var showHTML: Bool
    @State private var command: FieldEditorCommand?
    @State private var showMediaPicker = false
    @State private var sourceSelection: TextSelection?
    @State private var isRecordingNoteAudio = false
    @State private var noteAudioStartTask: Task<Void, Never>?

    init(html: Binding<String>, field: AnkiField, isClozeType: Bool, mediaBase: URL, sourceMode: Bool = false, nextClozeNumber: Int = 1) {
        _html = html
        self.field = field
        self.isClozeType = isClozeType
        self.mediaBase = mediaBase
        self.sourceMode = sourceMode
        self.nextClozeNumber = nextClozeNumber
        _expanded = State(initialValue: !field.collapsed)
        _showHTML = State(initialValue: field.plainText || sourceMode)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if !field.description.isEmpty {
                    Text(field.description)
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                FieldFormatBar(text: $html, isClozeType: isClozeType, onAction: { action, value in
                    if showHTML { formatSource(action, value: value) }
                    else {
                        let commandValue = action == .cloze ? String(nextClozeNumber) : value
                        command = FieldEditorCommand(action: action, value: commandValue)
                    }
                }, onMedia: { showMediaPicker = true }, isRecording: isRecordingNoteAudio, onRecord: toggleNoteAudioRecording)
                if showHTML {
                    TextEditor(text: $html, selection: $sourceSelection)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .font(.custom(field.font, size: CGFloat(max(1, field.size))))
                        .frame(minHeight: 120, maxHeight: 220)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel(field.name)
                        .accessibilityIdentifier("field.source.\(field.name)")
                        .environment(\.layoutDirection, field.rtl ? .rightToLeft : .leftToRight)
                } else {
                    RichFieldEditor(html: $html, baseURL: mediaBase, font: field.font, fontSize: field.size, rtl: field.rtl, command: command)
                }
                HStack {
                    Button(showHTML ? "Editor visual" : "Editar HTML") { showHTML.toggle() }
                    Button("Anexar mídia…") { showMediaPicker = true }
                }
                .buttonStyle(GlassChipButtonStyle())
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Text(field.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mist)
                if field.sticky {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.secondaryText)
                        .accessibilityLabel("Manter conteúdo ao adicionar outra nota")
                }
            }
        }
        .onChange(of: sourceMode) { _, value in showHTML = value }
        .onDisappear {
            noteAudioStartTask?.cancel()
            noteAudioStartTask = nil
            if isRecordingNoteAudio {
                store.mediaStore.cancelNoteAudioRecording()
                isRecordingNoteAudio = false
            }
        }
        .fileImporter(isPresented: $showMediaPicker, allowedContentTypes: [.image, .audio, .movie, .data]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let name = try store.mediaStore.importFile(from: url)
                let escaped = name.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "\"", with: "&quot;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                let type = UTType(filenameExtension: url.pathExtension)
                let fileExtension = url.pathExtension.lowercased()
                let snippet: String
                if type?.conforms(to: .audio) == true || ["mp3", "wav", "m4a", "ogg", "aac", "flac", "opus", "aiff", "aif", "spx"].contains(fileExtension) {
                    snippet = "[sound:\(name)]"
                } else if type?.conforms(to: .movie) == true || ["mp4", "mov", "m4v", "webm"].contains(fileExtension) {
                    snippet = "<video controls src=\"\(escaped)\"></video>"
                } else if type?.conforms(to: .image) == true || ["jpg", "jpeg", "png", "gif", "webp", "svg"].contains(fileExtension) {
                    snippet = "<img src=\"\(escaped)\">"
                } else {
                    snippet = "<a href=\"\(escaped)\">\(escaped)</a>"
                }
                if showHTML {
                    html += snippet
                } else {
                    command = FieldEditorCommand(action: .insertHTML, value: snippet)
                }
            } catch { store.lastError = error.localizedDescription }
        }
    }

    private func toggleNoteAudioRecording() {
        if isRecordingNoteAudio {
            do {
                let filename = try store.mediaStore.stopNoteAudioRecording()
                if showHTML {
                    html += "[sound:\(filename)]"
                } else {
                    command = FieldEditorCommand(action: .insertHTML, value: "[sound:\(filename)]")
                }
            } catch {
                store.lastError = error.localizedDescription
            }
            isRecordingNoteAudio = false
            return
        }
        noteAudioStartTask = Task {
            do {
                try await store.mediaStore.startNoteAudioRecording()
                isRecordingNoteAudio = true
            } catch {
                if !(error is CancellationError) {
                    store.lastError = error.localizedDescription
                }
            }
            noteAudioStartTask = nil
        }
    }

    private func formatSource(_ action: FieldFormattingAction, value: String) {
        let range: Range<String.Index>
        if let sourceSelection, case .selection(let selected) = sourceSelection.indices { range = selected }
        else { range = html.endIndex..<html.endIndex }
        let selected = String(html[range])
        let start = html.distance(from: html.startIndex, to: range.lowerBound)
        let prefix: String
        let suffix: String
        switch action {
        case .bold: (prefix, suffix) = ("<b>", "</b>")
        case .italic: (prefix, suffix) = ("<i>", "</i>")
        case .underline: (prefix, suffix) = ("<u>", "</u>")
        case .larger: (prefix, suffix) = ("<span style=\"font-size:1.2em\">", "</span>")
        case .textColor: (prefix, suffix) = ("<span style=\"color: \(value)\">", "</span>")
        case .highlight: (prefix, suffix) = (value == "transparent" ? "<span style=\"background-color: transparent\">" : "<span style=\"background-color: \(value)\">", "</span>")
        case .code: (prefix, suffix) = ("<code>", "</code>")
        case .superscript: (prefix, suffix) = ("<sup>", "</sup>")
        case .subscriptText: (prefix, suffix) = ("<sub>", "</sub>")
        case .unorderedList: (prefix, suffix) = ("<ul><li>", "</li></ul>")
        case .orderedList: (prefix, suffix) = ("<ol><li>", "</li></ol>")
        case .indent: (prefix, suffix) = ("<blockquote>", "</blockquote>")
        case .outdent:
            let before = String(html[..<range.lowerBound])
            let after = String(html[range.upperBound...])
            if let opening = before.range(of: "<blockquote>", options: [.backwards, .caseInsensitive]),
               let closing = after.range(of: "</blockquote>", options: [.caseInsensitive]) {
                let prefix = String(before[..<opening.lowerBound])
                let contentBeforeSelection = String(before[opening.upperBound...])
                let unwrapped = String(before[..<opening.lowerBound])
                    + contentBeforeSelection
                    + selected
                    + String(after[..<closing.lowerBound])
                    + String(after[closing.upperBound...])
                html = String(unwrapped)
                let selectionStart = prefix.count + contentBeforeSelection.count
                let lower = html.index(html.startIndex, offsetBy: selectionStart)
                let upper = html.index(lower, offsetBy: selected.count)
                sourceSelection = TextSelection(range: lower..<upper)
            }
            return
        case .alignLeft: (prefix, suffix) = ("<div style=\"text-align: left\">", "</div>")
        case .alignCenter: (prefix, suffix) = ("<div style=\"text-align: center\">", "</div>")
        case .alignRight: (prefix, suffix) = ("<div style=\"text-align: right\">", "</div>")
        case .removeFormatting:
            let plain = selected.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            html.replaceSubrange(range, with: plain)
            return
        case .cloze: (prefix, suffix) = ("{{c\(nextClozeNumber)::", "}}")
        case .math: (prefix, suffix) = ("\\(", "\\)")
        case .lineBreak: (prefix, suffix) = ("<br>", "")
        case .sound, .image, .insertHTML: return
        }
        html.replaceSubrange(range, with: prefix + selected + suffix)
        let lower = html.index(html.startIndex, offsetBy: start + prefix.count)
        let upper = html.index(lower, offsetBy: selected.count)
        sourceSelection = TextSelection(range: lower..<upper)
    }
}

enum FieldFormattingAction: String {
    case bold, italic, underline, larger, sound, image, cloze, math, lineBreak, code, insertHTML
    case textColor, highlight, superscript, subscriptText, removeFormatting
    case unorderedList, orderedList, indent, outdent, alignLeft, alignCenter, alignRight
}

struct FieldEditorCommand {
    let id = UUID()
    let action: FieldFormattingAction
    var value: String = ""
}

struct RichFieldEditor: View {
    @Binding var html: String
    var minHeight: CGFloat = 120
    var baseURL: URL? = nil
    var font: String = "Arial"
    var fontSize: Int = 20
    var rtl = false
    var command: FieldEditorCommand? = nil

    var body: some View {
        RichFieldWebView(html: $html, baseURL: baseURL, font: font, fontSize: fontSize, rtl: rtl, command: command)
            .id(baseURL)
            .frame(minHeight: minHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .ankiGlass(interactive: true, in: RoundedRectangle(cornerRadius: 12))
    }
}

@MainActor private struct RichFieldWebView {
    @Binding var html: String
    let baseURL: URL?
    let font: String
    let fontSize: Int
    let rtl: Bool
    let command: FieldEditorCommand?

    func makeCoordinator() -> FieldEditorCoordinator { FieldEditorCoordinator(html: $html) }

    @MainActor func makeWebView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "ankiField")
        config.userContentController.add(context.coordinator, name: "ankiPasteImage")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        context.coordinator.webView = web
        #if os(macOS)
        web.setValue(false, forKey: "drawsBackground")
        #else
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        #endif
        context.coordinator.lastHTML = html
        let conf = CollectionStore.shared.conf
        web.loadHTMLString(
            editorDocument(
                html,
                font: font,
                fontSize: fontSize,
                rtl: rtl,
                pasteStripsFormatting: conf["pasteStripsFormatting"] as? Bool ?? false,
                pasteImagesAsPNG: conf["pasteImagesAsPng"] as? Bool ?? false
            ),
            baseURL: baseURL
        )
        return web
    }

    @MainActor func updateWebView(_ web: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.html = $html
        if coordinator.lastHTML != html {
            coordinator.lastHTML = html
            web.evaluateJavaScript("window.ankiSetHTML(\(editorJSON(html)))")
        }
        web.evaluateJavaScript("window.ankiStyle(\(editorJSON(font)), \(max(1, fontSize)), \(rtl))")
        let conf = CollectionStore.shared.conf
        let pasteStripsFormatting = conf["pasteStripsFormatting"] as? Bool ?? false
        let pasteImagesAsPNG = conf["pasteImagesAsPng"] as? Bool ?? false
        web.evaluateJavaScript(
            "window.ankiPasteOptions(\(pasteStripsFormatting), \(pasteImagesAsPNG))"
        )
        if let command, coordinator.lastCommand != command.id {
            coordinator.lastCommand = command.id
            web.evaluateJavaScript("window.ankiFormat(\(editorJSON(command.action.rawValue)), \(editorJSON(command.value)))")
        }
    }
}

#if os(iOS)
extension RichFieldWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ webView: WKWebView, context: Context) { updateWebView(webView, context: context) }
}
#else
extension RichFieldWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ webView: WKWebView, context: Context) { updateWebView(webView, context: context) }
}
#endif

@MainActor private final class FieldEditorCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var html: Binding<String>
    var lastHTML: String?
    var lastCommand: UUID?
    weak var webView: WKWebView?

    init(html: Binding<String>) { self.html = html }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "ankiPasteImage", let dataURL = message.body as? String,
           let separator = dataURL.firstIndex(of: ","),
           let data = Data(base64Encoded: String(dataURL[dataURL.index(after: separator)...])) {
            do {
                let format = dataURL.hasPrefix("data:image/png") ? "png" : "jpg"
                let filename = try CollectionStore.shared.mediaStore.importClipboardImage(data, format: format)
                let snippet = "<img src=\"\(filename)\">"
                webView?.evaluateJavaScript("window.ankiFormat('insertHTML', \(editorJSON(snippet)))")
            } catch {
                CollectionStore.shared.lastError = error.localizedDescription
            }
            return
        }
        guard message.name == "ankiField", let body = message.body as? String else { return }
        lastHTML = body
        html.wrappedValue = body
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("window.ankiSetHTML(\(editorJSON(html.wrappedValue)))")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.navigationType == .linkActivated ? .cancel : .allow
    }
}

private func editorJSON(_ value: String) -> String {
    let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
    return String(decoding: data, as: UTF8.self)
        .replacingOccurrences(of: "<", with: "\\u003c")
        .replacingOccurrences(of: ">", with: "\\u003e")
        .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
}

private func editorDocument(
    _ html: String,
    font: String,
    fontSize: Int,
    rtl: Bool,
    pasteStripsFormatting: Bool,
    pasteImagesAsPNG: Bool
) -> String {
    """
    <!DOCTYPE html><html><head>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      html,body{margin:0;padding:0;background:transparent;color:#182127;}
      @media(prefers-color-scheme:dark){html,body{color:#e8f4f5;}}
      #ed{min-height:100px;padding:10px;outline:none;overflow-wrap:anywhere;}
      img,video{max-width:100%;height:auto;}
    </style></head><body>
    <div id="ed" contenteditable="true"></div>
    <script>
      const ed = document.getElementById('ed');
      let savedRange = null;
      let stripFormattingOnPaste = false;
      let pasteImagesAsPNG = false;
      window.ankiSetHTML = value => { if (ed.innerHTML !== value) ed.innerHTML = value; };
      window.ankiPasteOptions = (stripFormatting, imagesAsPNG) => {
        stripFormattingOnPaste = stripFormatting;
        pasteImagesAsPNG = imagesAsPNG;
      };
      window.ankiStyle = (font, size, rtl) => {
        ed.style.fontFamily = font;
        ed.style.fontSize = size + 'px';
        ed.dir = rtl ? 'rtl' : 'ltr';
      };
      window.ankiSetHTML(\(editorJSON(html)));
      window.ankiStyle(\(editorJSON(font)), \(max(1, fontSize)), \(rtl));
      window.ankiPasteOptions(\(pasteStripsFormatting), \(pasteImagesAsPNG));
      function push(){ window.webkit.messageHandlers.ankiField.postMessage(ed.innerHTML); }
      document.addEventListener('selectionchange', () => {
        const selection = window.getSelection();
        if (selection.rangeCount && ed.contains(selection.anchorNode) && ed.contains(selection.focusNode)) {
          savedRange = selection.getRangeAt(0).cloneRange();
        }
      });
      ed.addEventListener('paste', event => {
        const clipboard = event.clipboardData;
        if (!clipboard) return;
        const imageItem = Array.from(clipboard.items).find(item => item.type.startsWith('image/'));
        const imageFile = imageItem && imageItem.getAsFile();
        if (imageFile) {
          event.preventDefault();
          const reader = new FileReader();
          reader.onload = () => {
            const image = new Image();
            image.onload = () => {
              const canvas = document.createElement('canvas');
              canvas.width = image.naturalWidth;
              canvas.height = image.naturalHeight;
              const context = canvas.getContext('2d');
              if (!context) return;
              context.drawImage(image, 0, 0);
              const format = pasteImagesAsPNG ? 'image/png' : 'image/jpeg';
              const quality = pasteImagesAsPNG ? undefined : 0.92;
              const dataURL = canvas.toDataURL(format, quality);
              window.webkit.messageHandlers.ankiPasteImage.postMessage(dataURL);
            };
            image.src = reader.result;
          };
          reader.readAsDataURL(imageFile);
          return;
        }
        if (stripFormattingOnPaste !== event.shiftKey) {
          event.preventDefault();
          const text = clipboard.getData('text/plain');
          document.execCommand('insertText', false, text);
          push();
        }
      });
        window.ankiFormat = (action, value) => {
        ed.focus();
        const selection = window.getSelection();
        if (savedRange && ed.contains(savedRange.commonAncestorContainer)) {
          selection.removeAllRanges(); selection.addRange(savedRange);
        } else {
          const range = document.createRange(); range.selectNodeContents(ed); range.collapse(false);
          selection.removeAllRanges(); selection.addRange(range);
        }
        if (action === 'insertHTML') document.execCommand('insertHTML', false, value);
        else if (['bold','italic','underline','superscript','indent','outdent'].includes(action)) document.execCommand(action);
        else if (action === 'textColor') document.execCommand('foreColor', false, value);
        else if (action === 'highlight') document.execCommand('hiliteColor', false, value);
        else if (action === 'subscriptText') document.execCommand('subscript');
        else if (action === 'removeFormatting') document.execCommand('removeFormat');
        else if (action === 'unorderedList') document.execCommand('insertUnorderedList');
        else if (action === 'orderedList') document.execCommand('insertOrderedList');
        else if (action === 'alignLeft') document.execCommand('justifyLeft');
        else if (action === 'alignCenter') document.execCommand('justifyCenter');
        else if (action === 'alignRight') document.execCommand('justifyRight');
        else if (action === 'larger') document.execCommand('fontSize', false, '5');
        else if (action === 'lineBreak') document.execCommand('insertHTML', false, '<br>');
        else if (action === 'code') {
          const range = selection.getRangeAt(0);
          const node = document.createElement('code'); node.appendChild(range.extractContents());
          range.insertNode(node); range.selectNodeContents(node);
        } else if (action === 'cloze') {
          const indexes = [...ed.innerHTML.matchAll(/{{c([0-9]+)::/g)].map(match => Number(match[1]));
          const index = Number(value) > 0 ? Number(value) : Math.max(0, ...indexes) + 1;
          const range = selection.getRangeAt(0);
          const fragment = range.extractContents();
          const wrapper = document.createElement('span');
          wrapper.append(document.createTextNode('{{c' + index + '::'), fragment, document.createTextNode('}}'));
          range.insertNode(wrapper);
        }
        else {
          const value = action === 'sound' ? '[sound:]' : action === 'image' ? '<img src="">' : '\\\\(\\\\)';
          document.execCommand('insertText', false, value);
        }
        push();
      };
      ed.addEventListener('input', push);
      ed.addEventListener('blur', push);
    </script>
    </body></html>
    """
}
