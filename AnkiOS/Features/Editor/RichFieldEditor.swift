import SwiftUI
import WebKit
import UniformTypeIdentifiers
import PhotosUI
import PencilKit
import UIKit

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
    @State private var showAttachmentOptions = false
    @State private var sourceSelection: TextSelection?
    @State private var lastSourceSelection: TextSelection?
    @State private var pendingFormatSelection: TextSelection?
    @State private var pendingFormattedSourceHTML: String?
    @State private var isRecordingNoteAudio = false
    @State private var noteAudioStartTask: Task<Void, Never>?
    @State private var showPhotoPicker = false
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showCameraPicker = false
    @State private var showDrawingEditor = false
    @State private var drawingBackground: UIImage?
    @State private var drawingFilename: String?

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
                if showHTML {
                    TextEditor(text: $html, selection: $sourceSelection)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.custom(field.font, size: CGFloat(max(1, field.size))))
                        .frame(minHeight: 120, maxHeight: 220)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel(field.name)
                        .accessibilityIdentifier("field.source.\(field.name)")
                        .environment(\.layoutDirection, field.rtl ? .rightToLeft : .leftToRight)
                    formatBar
                } else {
                    formatBar
                    RichFieldEditor(
                        html: $html,
                        baseURL: mediaBase,
                        font: field.font,
                        fontSize: field.size,
                        rtl: field.rtl,
                        command: command,
                        onEditDrawing: drawingEditHandler
                    )
                }
                HStack {
                    Button(showHTML ? "Editor visual" : "Editar HTML") { showHTML.toggle() }
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
        .onChange(of: sourceSelection) { _, selection in
            guard let selection, case .selection(let range) = selection.indices, !range.isEmpty else { return }
            lastSourceSelection = selection
        }
        .onChange(of: html) { _, value in
            if pendingFormattedSourceHTML == value {
                pendingFormattedSourceHTML = nil
            } else {
                lastSourceSelection = nil
            }
        }
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
        .confirmationDialog("Add Media", isPresented: $showAttachmentOptions, titleVisibility: .visible) {
            Button("From Photos", systemImage: "photo") { showPhotoPicker = true }
            #if !COND_targetEnvironment_simulator
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("From Camera", systemImage: "camera") { showCameraPicker = true }
                    .accessibilityIdentifier("noteField.fromCamera")
            }
            #endif
            if UIDevice.current.userInterfaceIdiom == .pad {
                Button("Draw", systemImage: "pencil.tip.crop.circle") {
                    drawingFilename = nil
                    drawingBackground = nil
                    showDrawingEditor = true
                }
                .accessibilityIdentifier("noteField.draw")
            }
            if UIDevice.current.userInterfaceIdiom != .pad {
                Button(isRecordingNoteAudio ? "Parar" : "Record Voice", systemImage: isRecordingNoteAudio ? "stop.fill" : "mic.fill") {
                    toggleNoteAudioRecording()
                }
                .accessibilityIdentifier("noteField.recordVoice")
            }
            Button("From File", systemImage: "folder") { showMediaPicker = true }
            Button("Cancelar", role: .cancel) {}
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoPickerItem, matching: .images)
        .onChange(of: photoPickerItem) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
                    let maxDimension = store.conf["imageMaxDimension"] as? Int ?? 1024
                    let filename = try store.mediaStore.importPhotoImage(data, maxDimension: maxDimension)
                    insertMediaSnippet("<img src=\"\(filename)\">")
                } catch {
                    store.lastError = error.localizedDescription
                }
                photoPickerItem = nil
            }
        }
        .fullScreenCover(isPresented: $showCameraPicker) {
            CameraImagePicker { image in
                showCameraPicker = false
                guard let image, let data = image.jpegData(compressionQuality: 0.94) else { return }
                do {
                    let maxDimension = store.conf["imageMaxDimension"] as? Int ?? 1024
                    let filename = try store.mediaStore.importPhotoImage(data, maxDimension: maxDimension)
                    insertMediaSnippet("<img src=\"\(filename)\">")
                } catch {
                    store.lastError = error.localizedDescription
                }
            }
        }
        .sheet(isPresented: $showDrawingEditor) {
            NoteDrawingEditor(backgroundImage: drawingBackground) { data in
                do {
                    let filename = try store.mediaStore.importDrawingImage(data)
                    if let drawingFilename {
                        replaceDrawing(named: drawingFilename, with: filename)
                    } else {
                        insertMediaSnippet("<img src=\"\(filename)\">")
                    }
                    self.drawingFilename = nil
                    drawingBackground = nil
                } catch {
                    store.lastError = error.localizedDescription
                }
            }
        }
    }

    private var formatBar: some View {
        FieldFormatBar(text: $html, fieldName: field.name, isClozeType: isClozeType, onAction: { action, value in
            if showHTML { formatSource(action, value: value) }
            else {
                let commandValue = action == .cloze ? String(nextClozeNumber) : value
                command = FieldEditorCommand(action: action, value: commandValue)
            }
        }, onMenuOpen: {
            let selection = sourceSelection ?? lastSourceSelection
            if let selection, case .selection(let range) = selection.indices, !range.isEmpty {
                pendingFormatSelection = selection
            } else {
                pendingFormatSelection = nil
            }
        }, onMedia: { showAttachmentOptions = true }, isRecording: isRecordingNoteAudio, onRecord: toggleNoteAudioRecording, recordButtonTitle: recordVoiceTitle, showsRecordButton: showsRecordButtonInFormatBar)
    }

    private var recordVoiceTitle: LocalizedStringKey {
        "Record Voice"
    }

    private var showsRecordButtonInFormatBar: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private func insertMediaSnippet(_ snippet: String) {
        if showHTML {
            html += snippet
        } else {
            command = FieldEditorCommand(action: .insertHTML, value: snippet)
        }
    }

    private var drawingEditHandler: ((String) -> Void)? {
        { filename in editDrawing(named: filename) }
    }

    private func editDrawing(named filename: String) {
        let url = mediaBase.appendingPathComponent(filename)
        guard let image = UIImage(contentsOfFile: url.path) else {
            store.lastError = "Não foi possível abrir o desenho."
            return
        }
        drawingFilename = filename
        drawingBackground = image
        showDrawingEditor = true
    }

    private func replaceDrawing(named oldName: String, with newName: String) {
        let source = html as NSString
        guard let expression = try? NSRegularExpression(pattern: #"(<img\b[^>]*\bsrc\s*=\s*[\"'])([^\"']+)([\"'][^>]*>)"#, options: [.caseInsensitive]) else { return }
        let matches = expression.matches(in: html, range: NSRange(location: 0, length: source.length))
        for match in matches.reversed() where match.numberOfRanges > 2 {
            let valueRange = match.range(at: 2)
            let reference = source.substring(with: valueRange)
            let name = URL(string: reference)?.lastPathComponent ?? reference
            guard name == oldName else { continue }
            html = source.replacingCharacters(in: valueRange, with: newName)
            return
        }
        insertMediaSnippet("<img src=\"\(newName)\">")
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
        if let sourceSelection, case .selection(let selected) = sourceSelection.indices, !selected.isEmpty {
            range = selected
        } else if let pendingFormatSelection,
                  case .selection(let selected) = pendingFormatSelection.indices,
                  !selected.isEmpty {
            range = selected
        } else if let lastSourceSelection,
                  case .selection(let selected) = lastSourceSelection.indices,
                  !selected.isEmpty {
            range = selected
        }
        else { range = html.endIndex..<html.endIndex }
        pendingFormatSelection = nil
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
                let updatedHTML = String(unwrapped)
                pendingFormattedSourceHTML = updatedHTML
                html = updatedHTML
                let selectionStart = prefix.count + contentBeforeSelection.count
                let lower = html.index(html.startIndex, offsetBy: selectionStart)
                let upper = html.index(lower, offsetBy: selected.count)
                let selection = TextSelection(range: lower..<upper)
                sourceSelection = selection
                lastSourceSelection = selection
            }
            return
        case .alignLeft: (prefix, suffix) = ("<div style=\"text-align: left\">", "</div>")
        case .alignCenter: (prefix, suffix) = ("<div style=\"text-align: center\">", "</div>")
        case .alignRight: (prefix, suffix) = ("<div style=\"text-align: right\">", "</div>")
        case .removeFormatting:
            clearFormatting(in: range)
            return
        case .cloze: (prefix, suffix) = ("{{c\(nextClozeNumber)::", "}}")
        case .math: (prefix, suffix) = ("\\(", "\\)")
        case .lineBreak: (prefix, suffix) = ("<br>", "")
        case .sound, .image, .insertHTML: return
        }
        let updatedHTML = html.replacingCharacters(in: range, with: prefix + selected + suffix)
        pendingFormattedSourceHTML = updatedHTML
        html = updatedHTML
        let lower = html.index(html.startIndex, offsetBy: start + prefix.count)
        let upper = html.index(lower, offsetBy: selected.count)
        let selection = TextSelection(range: lower..<upper)
        sourceSelection = selection
        lastSourceSelection = selection
    }

    private func clearFormatting(in range: Range<String.Index>) {
        let formattingTags: Set<String> = [
            "b", "strong", "i", "em", "u", "span", "code", "sup", "sub",
            "blockquote", "ul", "ol", "li", "div", "font", "s", "strike", "del", "small", "big", "mark"
        ]
        let voidTags: Set<String> = ["br", "hr", "img", "input", "meta", "link", "source", "wbr"]
        let tagExpression = try? NSRegularExpression(pattern: #"<(/?)([A-Za-z][A-Za-z0-9:-]*)\b[^>]*>"#)
        var prefix = String(html[..<range.lowerBound])
        let selected = String(html[range])
        let suffix = String(html[range.upperBound...])
        var stack: [(name: String, markup: String, range: Range<String.Index>)] = []

        if let tagExpression {
            let searchRange = NSRange(prefix.startIndex..., in: prefix)
            for match in tagExpression.matches(in: prefix, range: searchRange) {
                guard let nameRange = Range(match.range(at: 2), in: prefix),
                      let tagRange = Range(match.range, in: prefix) else { continue }
                let name = String(prefix[nameRange]).lowercased()
                guard formattingTags.contains(name) else { continue }
                if match.range(at: 1).length > 0 {
                    if let index = stack.lastIndex(where: { $0.name == name }) {
                        stack.removeSubrange(index...)
                    }
                } else {
                    let markup = String(prefix[tagRange])
                    if !voidTags.contains(name) && !markup.hasSuffix("/>") {
                        stack.append((name, markup, tagRange))
                    }
                }
            }
        }

        var closingTags: [(name: String, range: Range<String.Index>)] = []
        var cursor = suffix.startIndex
        while cursor < suffix.endIndex, suffix[cursor] == "<" {
            let slash = suffix.index(after: cursor)
            guard slash < suffix.endIndex, suffix[slash] == "/" else { break }
            let nameStart = suffix.index(after: slash)
            var nameEnd = nameStart
            while nameEnd < suffix.endIndex {
                let character = suffix[nameEnd]
                guard character.isLetter || character.isNumber || character == ":" || character == "-" else { break }
                nameEnd = suffix.index(after: nameEnd)
            }
            guard nameStart < nameEnd,
                  let tagEnd = suffix[nameEnd...].firstIndex(of: ">") else { break }
            let name = String(suffix[nameStart..<nameEnd]).lowercased()
            guard formattingTags.contains(name) else { break }
            let afterTag = suffix.index(after: tagEnd)
            closingTags.append((name, cursor..<afterTag))
            cursor = afterTag
        }

        var pairedTagCount = 0
        for tag in stack.reversed() {
            guard pairedTagCount < closingTags.count,
                  closingTags[pairedTagCount].name == tag.name else { break }
            pairedTagCount += 1
        }

        let pairedOpenTags = Array(stack.suffix(pairedTagCount))
        for tag in pairedOpenTags.reversed() {
            prefix.replaceSubrange(tag.range, with: "")
        }
        let remainingTags = Array(stack.dropLast(pairedTagCount))
        let closeBeforeSelection = remainingTags.reversed().map { "</\($0.name)>" }.joined()
        let reopenAfterSelection = remainingTags.map(\.markup).joined()
        let suffixStart = pairedTagCount == 0 ? suffix.startIndex : closingTags[pairedTagCount - 1].range.upperBound
        let remainingSuffix = String(suffix[suffixStart...])
        let tagNames = formattingTags.sorted().joined(separator: "|")
        let plain = selected.replacingOccurrences(
            of: "(?i)</?(?:\(tagNames))\\b[^>]*>",
            with: "",
            options: .regularExpression
        )
        let beforeSelection = prefix + closeBeforeSelection
        let updatedHTML = beforeSelection + plain + reopenAfterSelection + remainingSuffix
        let lower = updatedHTML.index(updatedHTML.startIndex, offsetBy: beforeSelection.count)
        let upper = updatedHTML.index(lower, offsetBy: plain.count)
        pendingFormattedSourceHTML = updatedHTML
        html = updatedHTML
        let selection = TextSelection(range: lower..<upper)
        sourceSelection = selection
        lastSourceSelection = selection
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
    var onEditDrawing: ((String) -> Void)? = nil

    var body: some View {
        RichFieldWebView(html: $html, baseURL: baseURL, font: font, fontSize: fontSize, rtl: rtl, command: command, onEditDrawing: onEditDrawing)
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
    let onEditDrawing: ((String) -> Void)?

    func makeCoordinator() -> FieldEditorCoordinator { FieldEditorCoordinator(html: $html, onEditDrawing: onEditDrawing) }

    @MainActor func makeWebView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "ankiField")
        config.userContentController.add(context.coordinator, name: "ankiPasteImage")
        config.userContentController.add(context.coordinator, name: "ankiDrawing")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        context.coordinator.webView = web
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
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
        coordinator.onEditDrawing = onEditDrawing
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

extension RichFieldWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ webView: WKWebView, context: Context) { updateWebView(webView, context: context) }
}

@MainActor private final class FieldEditorCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var html: Binding<String>
    var lastHTML: String?
    var lastCommand: UUID?
    var onEditDrawing: ((String) -> Void)?
    weak var webView: WKWebView?

    init(html: Binding<String>, onEditDrawing: ((String) -> Void)?) {
        self.html = html
        self.onEditDrawing = onEditDrawing
    }

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
        if message.name == "ankiDrawing", let filename = message.body as? String {
            onEditDrawing?(filename)
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
      let drawingHold = null;
      let drawingTarget = null;
      const clearDrawingHold = () => {
        if (drawingHold) clearTimeout(drawingHold);
        drawingHold = null;
        drawingTarget = null;
      };
      ed.addEventListener('touchstart', event => {
        clearDrawingHold();
        if (event.touches.length !== 2) return;
        const point = event.touches[0];
        const target = document.elementFromPoint(point.clientX, point.clientY);
        const image = target && target.closest ? target.closest('img') : null;
        const source = image && image.getAttribute('src');
        if (!source) return;
        const filename = source.split('/').pop().split(/[?#]/)[0];
        if (!filename.startsWith('drawing-')) return;
        drawingTarget = filename;
        drawingHold = setTimeout(() => {
          if (drawingTarget) window.webkit.messageHandlers.ankiDrawing.postMessage(drawingTarget);
          clearDrawingHold();
        }, 700);
      }, {passive:true});
      ed.addEventListener('touchend', clearDrawingHold, {passive:true});
      ed.addEventListener('touchcancel', clearDrawingHold, {passive:true});
    </script>
    </body></html>
    """
}

private struct CameraImagePicker: UIViewControllerRepresentable {
    let onImage: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image"]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImage: (UIImage?) -> Void

        init(onImage: @escaping (UIImage?) -> Void) { self.onImage = onImage }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onImage(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onImage(nil)
        }
    }
}

private struct NoteDrawingEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var drawing = PKDrawing()
    @State private var canvasView: PKCanvasView?

    let backgroundImage: UIImage?
    let onSave: (Data) -> Void

    private var outputSize: CGSize {
        guard let backgroundImage else { return CGSize(width: 1024, height: 768) }
        let sourceSize = backgroundImage.size
        let scale = min(1, 1024 / max(sourceSize.width, sourceSize.height))
        return CGSize(width: max(1, (sourceSize.width * scale).rounded()), height: max(1, (sourceSize.height * scale).rounded()))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ZStack {
                    Color.white
                    if let backgroundImage {
                        Image(uiImage: backgroundImage)
                            .resizable()
                            .scaledToFit()
                    }
                    PencilDrawingCanvas(drawing: $drawing) { canvasView = $0 }
                        .accessibilityIdentifier("noteDrawing.canvas")
                }
                .aspectRatio(outputSize.width / outputSize.height, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(AppTheme.primaryText.opacity(0.18), lineWidth: 1)
                }
                .padding()
            }
            .navigationTitle(backgroundImage == nil ? "Draw" : "Edit Drawing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") { saveDrawing() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("noteDrawing.save")
                }
            }
        }
    }

    private func saveDrawing() {
        guard let canvasView else { return }
        let bounds = canvasView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let target = CGRect(origin: .zero, size: outputSize)
        let drawingScale = max(outputSize.width / bounds.width, outputSize.height / bounds.height)
        let ink = drawing.image(from: CGRect(origin: .zero, size: bounds.size), scale: drawingScale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(target)
            backgroundImage?.draw(in: target)
            ink.draw(in: target)
        }
        guard let data = image.pngData() else { return }
        onSave(data)
        dismiss()
    }
}

private struct PencilDrawingCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let onReady: (PKCanvasView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(drawing: $drawing) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .black, width: 5)
        canvas.delegate = context.coordinator
        context.coordinator.canvas = canvas
        DispatchQueue.main.async {
            let picker = PKToolPicker()
            picker.addObserver(canvas)
            picker.setVisible(true, forFirstResponder: canvas)
            context.coordinator.toolPicker = picker
            canvas.becomeFirstResponder()
            onReady(canvas)
        }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if canvas.drawing != drawing { canvas.drawing = drawing }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var drawing: Binding<PKDrawing>
        weak var canvas: PKCanvasView?
        var toolPicker: PKToolPicker?

        init(drawing: Binding<PKDrawing>) { self.drawing = drawing }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            drawing.wrappedValue = canvasView.drawing
        }
    }
}
