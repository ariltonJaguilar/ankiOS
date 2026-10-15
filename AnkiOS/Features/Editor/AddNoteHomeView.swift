import SwiftUI
import UniformTypeIdentifiers

/// First-class Add screen (Anki “Adicionar”).
struct AddNoteHomeView: View {
    @EnvironmentObject private var store: CollectionStore
    @State private var selectedTypeID: Int64 = 0
    @State private var selectedDeckID: Int64 = 1
    @State private var fieldValues: [String] = []
    @State private var tags = ""
    @State private var statusMessage: String?
    @State private var showPreview = false
    @State private var showMediaPicker = false
    @State private var mediaTargetField = 0
    @State private var useRichEditor = false
    @State private var showOcclusion = false
    @State private var recentNotes: [RecentAddedNote] = []
    @State private var historyNoteID: Int64?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        GlassFormSection(title: "Baralho") {
                            GlassOptionRow(title: "Baralho") {
                                Picker("", selection: $selectedDeckID) {
                                    ForEach(store.decks) { d in
                                        Text(d.name).tag(d.id)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .onChange(of: selectedDeckID) { _, id in
                                    store.setCurrentDeck(id)
                                }
                            }
                        }
                        GlassFormSection(title: "Tipo de nota") {
                            GlassOptionRow(title: "Tipo") {
                                Picker("", selection: $selectedTypeID) {
                                    ForEach(store.notetypes) { nt in
                                        Text(nt.name).tag(nt.id)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .onChange(of: selectedTypeID) { _, _ in syncFields() }
                            }
                        }
                        Button("Oclusão de imagem") { showOcclusion = true }
                            .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.16, expands: true))
                        GlassFormSection(title: "Campos") {
                            if let nt = store.notetype(id: selectedTypeID) {
                                ForEach(Array(nt.flds.enumerated()), id: \.offset) { idx, field in
                                    GlassInset {
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                Text(field.name)
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(AppTheme.mist)
                                                if field.sticky {
                                                    Text("sticky")
                                                        .font(.caption2)
                                                        .foregroundStyle(AppTheme.secondaryText)
                                                }
                                            }
                                            FieldFormatBar(text: binding(idx), isClozeType: nt.isCloze)
                                            if useRichEditor {
                                                RichFieldEditor(html: binding(idx))
                                            } else {
                                                TextField(field.name, text: binding(idx), axis: .vertical)
                                                    .lineLimit(3...10)
                                            }
                                            Button("Anexar mídia…") {
                                                mediaTargetField = idx
                                                showMediaPicker = true
                                            }
                                            .buttonStyle(GlassChipButtonStyle())
                                        }
                                    }
                                }
                            }
                        }
                        GlassFormSection(title: "Etiquetas") {
                            GlassInset {
                                TextField("tags separadas por espaço", text: $tags)
                                    .textFieldStyle(.plain)
                            }
                        }
                        if !recentNotes.isEmpty {
                            GlassFormSection(title: "Histórico") {
                                ForEach(recentNotes) { item in
                                    Button {
                                        historyNoteID = item.id
                                    } label: {
                                        Text(item.title)
                                            .font(.subheadline)
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        if let statusMessage {
                            Text(statusMessage)
                                .foregroundStyle(AppTheme.good)
                                .padding(.horizontal, 4)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Button("Pré-visualizar") { showPreview = true }
                            .buttonStyle(GlassButtonStyle(tint: .white, prominent: false, tintStrength: 0.16, expands: true))
                        Button(useRichEditor ? "Texto" : "HTML") { useRichEditor.toggle() }
                            .buttonStyle(GlassButtonStyle(tint: .white, prominent: false, tintStrength: 0.16, expands: true))
                    }
                    HStack(spacing: 12) {
                        Button("Adicionar e novo") { addNote(keepOpen: true) }
                            .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.18, expands: true))
                        Button("Adicionar") { addNote(keepOpen: false) }
                            .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.42, expands: true))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .background(AppBackground())
            .navigationTitle("Adicionar")
            .sheet(isPresented: $showPreview) {
                previewSheet
            }
            .fileImporter(
                isPresented: $showMediaPicker,
                allowedContentTypes: [.image, .audio, .movie, .data],
                allowsMultipleSelection: false
            ) { result in
                attachMedia(result)
            }
            .onAppear {
                loadDefaults()
                reloadHistory()
            }
            .sheet(isPresented: Binding(
                get: { historyNoteID != nil },
                set: { if !$0 { historyNoteID = nil; reloadHistory() } }
            )) {
                if let historyNoteID {
                    NoteEditorView(mode: .edit(historyNoteID))
                        .environmentObject(store)
                }
            }
            .sheet(isPresented: $showOcclusion) {
                ImageOcclusionEditor(deckID: selectedDeckID)
                    .environmentObject(store)
            }
        }
    }

    private func attachMedia(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = try store.mediaStore.importFile(from: url)
            let lower = name.lowercased()
            let snippet: String
            if ["mp3", "wav", "m4a", "ogg", "aac"].contains(where: { lower.hasSuffix($0) }) {
                snippet = "[sound:\(name)]"
            } else {
                snippet = #"<img src="\#(name)">"#
            }
            while fieldValues.count <= mediaTargetField { fieldValues.append("") }
            fieldValues[mediaTargetField] += (fieldValues[mediaTargetField].isEmpty ? "" : " ") + snippet
            statusMessage = "Mídia anexada: \(name)"
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var previewSheet: some View {
        NavigationStack {
            if let nt = store.notetype(id: selectedTypeID) {
                let note = AnkiNote(
                    id: 0, guid: "", mid: nt.id, mod: 0, usn: -1, tags: tags,
                    flds: fieldValues.joined(separator: "\u{1f}"),
                    sfld: fieldValues.first ?? "", csum: 0, flags: 0, data: ""
                )
                let card = AnkiCard(
                    id: 0, nid: 0, did: selectedDeckID, ord: 0, mod: 0, usn: -1,
                    type: 0, queue: 0, due: 0, ivl: 0, factor: 0, reps: 0, lapses: 0,
                    left: 0, odue: 0, odid: 0, flags: 0, data: ""
                )
                let result = CardHTMLRenderer.renderCard(
                    note: note, card: card, notetype: nt,
                    side: .question, mediaBase: store.mediaRoot
                )
                CardWebView(html: result.html, baseURL: store.mediaRoot)
                    .navigationTitle("Pré-visualização")
                    .safeAreaInset(edge: .bottom) {
                        Button("Fechar") { showPreview = false }
                            .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.18, expands: true))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                    }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 360)
        #endif
    }

    private func binding(_ idx: Int) -> Binding<String> {
        Binding(
            get: { idx < fieldValues.count ? fieldValues[idx] : "" },
            set: { newValue in
                while fieldValues.count <= idx { fieldValues.append("") }
                fieldValues[idx] = newValue
            }
        )
    }

    private func loadDefaults() {
        let curModel = (store.conf["curModel"] as? Int64)
            ?? (store.conf["curModel"] as? Int).map(Int64.init)
            ?? (store.conf["curModel"] as? NSNumber)?.int64Value
        if let curModel, store.notetype(id: curModel) != nil {
            selectedTypeID = curModel
        } else {
            selectedTypeID = store.notetypes.first?.id ?? 0
        }
        let addToCur = store.conf["addToCur"] as? Bool ?? true
        if addToCur, let cur = store.currentDeckID(), store.deck(id: cur) != nil {
            selectedDeckID = cur
        } else {
            selectedDeckID = store.decks.first(where: { $0.name != "Default" })?.id
                ?? store.decks.first?.id ?? 1
        }
        syncFields()
    }

    private func syncFields() {
        guard let nt = store.notetype(id: selectedTypeID) else { return }
        var next = Array(repeating: "", count: nt.flds.count)
        for (i, field) in nt.flds.enumerated() where field.sticky && i < fieldValues.count {
            next[i] = fieldValues[i]
        }
        fieldValues = next
    }

    private func reloadHistory() {
        recentNotes = store.recentNoteSummaries().map { RecentAddedNote(id: $0.id, title: $0.title) }
    }

    private func addNote(keepOpen: Bool) {
        do {
            try store.addNote(mid: selectedTypeID, did: selectedDeckID, fields: fieldValues, tags: tags)
            store.setCurrentDeck(selectedDeckID)
            var conf = store.conf
            conf["curModel"] = selectedTypeID
            try? store.saveConf(conf)
            statusMessage = "Nota adicionada."
            reloadHistory()
            if keepOpen {
                // Clear non-sticky
                if let nt = store.notetype(id: selectedTypeID) {
                    fieldValues = nt.flds.map { $0.sticky ? (fieldValues[safe: $0.ord] ?? "") : "" }
                }
            } else {
                fieldValues = fieldValues.map { _ in "" }
            }
            store.notifyDeckContentAdded()
        } catch {
            store.lastError = error.localizedDescription
        }
    }
}

private struct RecentAddedNote: Identifiable {
    var id: Int64
    var title: String
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
