import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Anki's image occlusion note: one cloze card per mask, stored in the note's cloze field.
struct ImageOcclusionEditor: View {
    var deckID: Int64
    var noteID: Int64?
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.dismiss) private var dismiss

    @State private var header = ""
    @State private var backExtra = ""
    @State private var comments = ""
    @State private var hideAll = true
    @State private var tool = "rect"
    @State private var imageFilename: String?
    @State private var image: PlatformPicture?
    @State private var masks: [OcclusionMask] = []
    @State private var preservedMasks: [String] = []
    @State private var drag: CGRect?
    @State private var showImporter = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        canvas
                        GlassFormSection(title: "Máscaras") {
                            Picker("Forma", selection: $tool) {
                                Text("Retângulo").tag("rect")
                                Text("Elipse").tag("ellipse")
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("imageOcclusion.shape")
                            GlassOptionRow(title: "Ocultar as outras") {
                                Toggle("", isOn: $hideAll)
                                    .labelsHidden()
                                    .tint(AppTheme.accent)
                                    .accessibilityIdentifier("imageOcclusion.hideOthers")
                            }
                            Text(hideAll
                                 ? "Cada cartão esconde todas as máscaras e revela uma na resposta."
                                 : "Cada cartão esconde só a própria máscara.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .padding(.horizontal, 4)
                            if masks.isEmpty {
                                Text("Arraste sobre a imagem para desenhar um retângulo.")
                                    .font(.subheadline)
                                    .foregroundStyle(AppTheme.secondaryText)
                                    .padding(.horizontal, 4)
                            } else {
                                ForEach(masks) { mask in
                                    HStack {
                                        Text("Máscara \(index(of: mask) + 1)")
                                            .foregroundStyle(AppTheme.primaryText)
                                        Spacer()
                                        Button("Apagar", role: .destructive) {
                                            masks.removeAll { $0.id == mask.id }
                                        }
                                        .buttonStyle(GlassChipButtonStyle(tint: AppTheme.danger.opacity(0.22)))
                                    }
                                    .padding(.horizontal, 4)
                                }
                                Button("Desfazer última") { _ = masks.popLast() }
                                    .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.16, expands: true))
                            }
                        }
                        GlassFormSection(title: "Texto") {
                            labeledField("Cabeçalho", text: $header)
                            labeledField("Extra do verso", text: $backExtra)
                            labeledField("Comentários", text: $comments)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                HStack(spacing: 12) {
                    Button("Fechar") { dismiss() }
                        .accessibilityIdentifier("imageOcclusion.close")
                        .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.18, expands: true))
                    Button(noteID == nil ? "Adicionar" : "Salvar") { save() }
                        .accessibilityIdentifier("imageOcclusion.save")
                        .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.42, expands: true))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .background(AppBackground())
            .navigationTitle("Oclusão de imagem")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: loadExisting)
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
                importImage(result)
            }
            .alert("Oclusão de imagem", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }

    @ViewBuilder
    private var canvas: some View {
        GlassFormSection(title: "Imagem") {
            Button("Escolher imagem") { showImporter = true }
                .accessibilityIdentifier("imageOcclusion.chooseImage")
                .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.16, expands: true))
            if let image {
                OcclusionCanvas(image: image, masks: masks, drag: drag) { rect in
                    drag = rect
                } onCommit: { rect in
                    drag = nil
                    guard rect.width > 0.015, rect.height > 0.015 else { return }
                    masks.append(OcclusionMask(rect: rect, shape: tool))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 420)
            } else {
                Text("Nenhuma imagem ainda.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func labeledField(_ title: String, text: Binding<String>) -> some View {
        GlassInset {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mist)
                TextField(title, text: text, axis: .vertical)
                    .lineLimit(1...4)
            }
        }
    }

    private func index(of mask: OcclusionMask) -> Int {
        masks.firstIndex(where: { $0.id == mask.id }) ?? 0
    }

    private func loadExisting() {
        guard let noteID else { return }
        let note: AnkiNote
        do {
            guard let fetched = try store.fetchNote(id: noteID) else {
                message = "A nota desta oclusão não existe mais."
                return
            }
            note = fetched
        }
        catch { message = error.localizedDescription; return }
        guard let nt = store.notetype(id: note.mid) else {
            message = "O tipo de nota desta oclusão não está disponível."
            return
        }
        let values = note.fields
        func value(_ names: [String], fallback: Int) -> String {
            if let idx = ImageOcclusionNotetype.fieldIndex(nt, names: names), idx < values.count {
                return values[idx]
            }
            return fallback < values.count ? values[fallback] : ""
        }
        let occlusion = value(["Oclusão", "Occlusion", "Occlusions"], fallback: 0)
        let imageField = value(["Imagem", "Image"], fallback: 1)
        header = value(["Cabeçalho", "Header"], fallback: 2)
        backExtra = value(["Extra do verso", "Back Extra"], fallback: 3)
        comments = value(["Comentários", "Comments"], fallback: 4)
        let parsed = ImageOcclusionNotetype.parseMasks(occlusion)
        masks = parsed.masks
        preservedMasks = parsed.preserved
        hideAll = parsed.hideAll
        if let name = ImageOcclusionNotetype.imageFilename(in: imageField) {
            imageFilename = name
            if let url = store.mediaStore.url(for: name) {
                image = PlatformPicture(contentsOf: url)
            }
        }
    }

    private func importImage(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = try store.mediaStore.importFile(from: url)
            imageFilename = name
            image = PlatformPicture(contentsOf: store.mediaStore.url(for: name) ?? url)
        } catch {
            message = error.localizedDescription
        }
    }

    private func save() {
        guard let imageFilename, image != nil else {
            message = "Escolha uma imagem."
            return
        }
        guard !masks.isEmpty || !preservedMasks.isEmpty else {
            message = "Desenhe pelo menos uma máscara."
            return
        }
        do {
            let mid = try ImageOcclusionNotetype.ensure(store)
            guard let nt = store.notetype(id: mid) else { return }
            var fields = Array(repeating: "", count: max(nt.flds.count, 5))
            func put(_ names: [String], _ fallback: Int, _ text: String) {
                if let idx = ImageOcclusionNotetype.fieldIndex(nt, names: names), idx < fields.count {
                    fields[idx] = text
                } else if fallback < fields.count {
                    fields[fallback] = text
                }
            }
            put(["Oclusão", "Occlusion", "Occlusions"], 0, ImageOcclusionNotetype.clozeText(masks: masks, hideAll: hideAll, preserved: preservedMasks))
            put(["Imagem", "Image"], 1, "<img src=\"\(imageFilename)\">")
            put(["Cabeçalho", "Header"], 2, header)
            put(["Extra do verso", "Back Extra"], 3, backExtra)
            put(["Comentários", "Comments"], 4, comments)
            if let noteID, let note = try store.fetchNote(id: noteID) {
                try store.updateNote(note, fields: fields, tags: note.tags)
            } else {
                try store.addNote(mid: mid, did: deckID, fields: fields, tags: "")
            }
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}

struct OcclusionMask: Identifiable, Hashable {
    let id = UUID()
    var rect: CGRect
    var shape: String = "rect"
    var ordinal: Int? = nil
}

private struct OcclusionCanvas: View {
    let image: PlatformPicture
    let masks: [OcclusionMask]
    let drag: CGRect?
    var onDrag: (CGRect?) -> Void
    var onCommit: (CGRect) -> Void

    var body: some View {
        GeometryReader { geo in
            let fitted = aspectFit(imageSize: image.pixelSize, in: geo.size)
            ZStack(alignment: .topLeading) {
                picture(image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: fitted.width, height: fitted.height)
                    .position(x: fitted.midX, y: fitted.midY)
                ForEach(masks) { mask in
                    maskShape(mask.shape)
                        .fill(Color.yellow.opacity(0.45))
                        .overlay(maskShape(mask.shape).stroke(Color.black.opacity(0.8), lineWidth: 1.5))
                        .frame(width: mask.rect.width * fitted.width, height: mask.rect.height * fitted.height)
                        .position(
                            x: fitted.minX + (mask.rect.midX * fitted.width),
                            y: fitted.minY + (mask.rect.midY * fitted.height)
                        )
                }
                if let drag {
                    Rectangle()
                        .fill(Color.yellow.opacity(0.35))
                        .overlay(Rectangle().stroke(Color.white, lineWidth: 1.5))
                        .frame(width: drag.width * fitted.width, height: drag.height * fitted.height)
                        .position(
                            x: fitted.minX + (drag.midX * fitted.width),
                            y: fitted.minY + (drag.midY * fitted.height)
                        )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Imagem")
            .accessibilityIdentifier("imageOcclusion.canvas")
            .accessibilityAddTraits(.allowsDirectInteraction)
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        onDrag(unitRect(from: value.startLocation, to: value.location, fitted: fitted))
                    }
                    .onEnded { value in
                        onCommit(unitRect(from: value.startLocation, to: value.location, fitted: fitted))
                    }
            )
        }
    }

    private func maskShape(_ shape: String) -> AnyShape {
        shape == "ellipse" ? AnyShape(Ellipse()) : AnyShape(Rectangle())
    }

    private func unitRect(from start: CGPoint, to end: CGPoint, fitted: CGRect) -> CGRect {
        guard fitted.width > 1, fitted.height > 1 else { return .zero }
        func unit(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: min(1, max(0, (point.x - fitted.minX) / fitted.width)),
                y: min(1, max(0, (point.y - fitted.minY) / fitted.height))
            )
        }
        let a = unit(start)
        let b = unit(end)
        return CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    private func aspectFit(imageSize: CGSize, in bounds: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }
}

typealias PlatformPicture = UIImage

private extension PlatformPicture {
    var pixelSize: CGSize { size }
    convenience init?(contentsOf url: URL) {
        self.init(contentsOfFile: url.path)
    }
}

private func picture(_ image: PlatformPicture) -> Image {
    Image(uiImage: image)
}

enum ImageOcclusionNotetype {
    static func isImageOcclusion(_ nt: AnkiNotetype) -> Bool {
        if nt.name == "Oclusão de imagem" || nt.name == "Image Occlusion" { return true }
        let names = Set(nt.flds.map { $0.name.lowercased() })
        let hasMask = names.contains("oclusão") || names.contains("occlusion") || names.contains("occlusions")
        let hasImage = names.contains("imagem") || names.contains("image")
        return nt.isCloze && hasMask && hasImage
    }

    static func fieldIndex(_ nt: AnkiNotetype, names: [String]) -> Int? {
        let wanted = Set(names.map { $0.lowercased() })
        return nt.flds.firstIndex { wanted.contains($0.name.lowercased()) }
    }

    @MainActor
    static func ensure(_ store: CollectionStore) throws -> Int64 {
        if let existing = store.notetypes.first(where: isImageOcclusion) {
            return existing.id
        }
        let id = store.timestampID()
        let now = Int64(Date().timeIntervalSince1970)
        let qfmt = """
        {{#Cabeçalho}}<div>{{Cabeçalho}}</div>{{/Cabeçalho}}
        {{cloze:Oclusão}}
        {{Imagem}}
        """
        let afmt = """
        {{#Cabeçalho}}<div>{{Cabeçalho}}</div>{{/Cabeçalho}}
        {{cloze:Oclusão}}
        {{Imagem}}
        <hr id=answer>
        {{#Extra do verso}}<div>{{Extra do verso}}</div>{{/Extra do verso}}
        """
        let nt = AnkiNotetype(
            id: id,
            name: "Oclusão de imagem",
            type: 1,
            mod: now,
            tmpls: [AnkiTemplate(name: "Oclusão de imagem", ord: 0, qfmt: qfmt, afmt: afmt)],
            flds: [
                AnkiField(name: "Oclusão", ord: 0),
                AnkiField(name: "Imagem", ord: 1),
                AnkiField(name: "Cabeçalho", ord: 2),
                AnkiField(name: "Extra do verso", ord: 3),
                AnkiField(name: "Comentários", ord: 4)
            ],
            css: """
            .card { font-family: -apple-system, sans-serif; text-align: center; }
            .io-header { margin-bottom: 12px; }
            """
        )
        var types = store.notetypes
        types.append(nt)
        try store.saveNotetypes(types)
        return id
    }

    static func clozeText(masks: [OcclusionMask], hideAll: Bool, preserved: [String] = []) -> String {
        var entries: [(ordinal: Int, order: Int, text: String)] = []
        var usedOrdinals = Set<Int>()
        for (index, token) in preserved.enumerated() {
            guard let ordinal = clozeOrdinal(in: token) else { continue }
            entries.append((ordinal, index, token))
            usedOrdinals.insert(ordinal)
        }

        var nextOrdinal = max(usedOrdinals.max() ?? 0, masks.compactMap(\.ordinal).max() ?? 0) + 1
        for (index, mask) in masks.enumerated() {
            var ordinal = mask.ordinal ?? nextOrdinal
            if usedOrdinals.contains(ordinal) {
                while usedOrdinals.contains(nextOrdinal) { nextOrdinal += 1 }
                ordinal = nextOrdinal
            }
            usedOrdinals.insert(ordinal)
            nextOrdinal = max(nextOrdinal, ordinal + 1)
            let rect = mask.rect
            let oi = hideAll ? ":oi=1" : ""
            let shape = mask.shape == "ellipse" ? "ellipse" : "rect"
            let token: String
            if shape == "ellipse" {
                token = String(
                    format: "{{c%d::image-occlusion:ellipse:left=%.4f:top=%.4f:rx=%.4f:ry=%.4f%@}}",
                    ordinal, rect.minX, rect.minY, rect.width / 2, rect.height / 2, oi
                )
            } else {
                token = String(
                    format: "{{c%d::image-occlusion:rect:left=%.4f:top=%.4f:width=%.4f:height=%.4f%@}}",
                    ordinal, rect.minX, rect.minY, rect.width, rect.height, oi
                )
            }
            entries.append((ordinal, preserved.count + index, token))
        }
        return entries.sorted {
            $0.ordinal == $1.ordinal ? $0.order < $1.order : $0.ordinal < $1.ordinal
        }.map(\.text).joined(separator: " ")
    }

    static func parseMasks(_ text: String) -> (masks: [OcclusionMask], hideAll: Bool, preserved: [String]) {
        guard let tokenRegex = try? NSRegularExpression(
            pattern: #"\{\{c([0-9]+)::(.*?)\}\}"#,
            options: [.dotMatchesLineSeparators]
        ), let maskRegex = try? NSRegularExpression(
            pattern: #"^image-occlusion:(rect|ellipse):left=([0-9]+(?:\.[0-9]+)?):top=([0-9]+(?:\.[0-9]+)?):(?:width=([0-9]+(?:\.[0-9]+)?):height=([0-9]+(?:\.[0-9]+)?)|rx=([0-9]+(?:\.[0-9]+)?):ry=([0-9]+(?:\.[0-9]+)?))(?::oi=1)?$"#
        ) else { return ([], true, [text].filter { !$0.isEmpty }) }

        var masks: [OcclusionMask] = []
        var preserved: [String] = []
        var hideAll = false
        let range = NSRange(text.startIndex..., in: text)
        tokenRegex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match,
                  let tokenRange = Range(match.range(at: 0), in: text),
                  let ordinalRange = Range(match.range(at: 1), in: text),
                  let bodyStringRange = Range(match.range(at: 2), in: text),
                  let ordinal = Int(text[ordinalRange]) else { return }
            let token = String(text[tokenRange])
            let body = String(text[bodyStringRange])
            if token.contains(":oi=1") { hideAll = true }
            let bodyNSRange = NSRange(body.startIndex..., in: body)
            guard let mask = maskRegex.firstMatch(in: body, range: bodyNSRange),
                  let shapeRange = Range(mask.range(at: 1), in: body),
                  let leftRange = Range(mask.range(at: 2), in: body),
                  let topRange = Range(mask.range(at: 3), in: body),
                  let left = Double(body[leftRange]),
                  let top = Double(body[topRange]) else {
                preserved.append(token)
                return
            }
            let shape = String(body[shapeRange])
            let width: Double
            let height: Double
            if let widthRange = Range(mask.range(at: 4), in: body),
               let heightRange = Range(mask.range(at: 5), in: body),
               let parsedWidth = Double(body[widthRange]),
               let parsedHeight = Double(body[heightRange]),
               shape == "rect" || shape == "ellipse" {
                width = parsedWidth
                height = parsedHeight
            } else if shape == "ellipse",
                      let rxRange = Range(mask.range(at: 6), in: body),
                      let ryRange = Range(mask.range(at: 7), in: body),
                      let rx = Double(body[rxRange]),
                      let ry = Double(body[ryRange]) {
                width = rx * 2
                height = ry * 2
            } else {
                preserved.append(token)
                return
            }
            masks.append(OcclusionMask(
                rect: CGRect(x: left, y: top, width: width, height: height),
                shape: shape,
                ordinal: ordinal
            ))
        }
        return (masks, hideAll || masks.isEmpty, preserved)
    }

    private static func clozeOrdinal(in token: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"^\{\{c([0-9]+)::"#),
              let match = regex.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)),
              let range = Range(match.range(at: 1), in: token) else { return nil }
        return Int(token[range])
    }

    static func imageFilename(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"src=["']([^"']+)["']"#),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range])
    }
}
