import SwiftUI
import UniformTypeIdentifiers

/// First-class Add screen (Anki “Adicionar”).
struct AddNoteHomeView: View {
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.colorScheme) private var colorScheme
    @Binding private var copyRequest: AddNoteCopyRequest?
    private let onClose: (() -> Void)?
    @State private var didLoadDefaults = false
    @State private var loadedProfile: String?
    @State private var skipNextTypeSync = false
    @State private var previousTypeID: Int64?
    @State private var selectedTypeID: Int64 = 0
    @State private var selectedDeckID: Int64 = 1
    @State private var fieldValues: [String] = []
    @State private var tags = ""
    @State private var statusMessage: String?
    @State private var showPreview = false
    @State private var useRichEditor = true
    @State private var showOcclusion = false
    @State private var recentNotes: [RecentAddedNote] = []
    @State private var historyNoteID: Int64?
    @State private var duplicateIDs: [Int64] = []
    @State private var showDuplicateWarning = false
    @State private var showMissingClozeConfirmation = false
    @State private var pendingAllowMissingCloze = false

    init(copyRequest: Binding<AddNoteCopyRequest?> = .constant(nil), onClose: (() -> Void)? = nil) {
        _copyRequest = copyRequest
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        GlassFormSection(title: "decks.deck.label") {
                            GlassOptionRow(title: "decks.deck.label") {
                                Picker("", selection: $selectedDeckID) {
                                    ForEach(store.decks.filter { !$0.isFiltered }) { d in
                                        Text(d.name).tag(d.id)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .accessibilityIdentifier("add.deck")
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
                                .onChange(of: selectedTypeID) { _, newTypeID in
                                    if skipNextTypeSync {
                                        skipNextTypeSync = false
                                        previousTypeID = newTypeID
                                        return
                                    }
                                    if let previousTypeID,
                                       let previousType = store.notetype(id: previousTypeID),
                                       let newType = store.notetype(id: newTypeID) {
                                        fieldValues = NotetypeEditMapping.transferNoteFieldValues(fieldValues, from: previousType, to: newType)
                                    } else {
                                        syncFields()
                                    }
                                    previousTypeID = newTypeID
                                    selectSavedDeckForCurrentType()
                                }
                            }
                        }
                        Button("Oclusão de imagem") { showOcclusion = true }
                            .accessibilityIdentifier("add.imageOcclusion")
                            .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.16, expands: true))
                        GlassFormSection(title: "editor.fields.section") {
                            if let nt = store.notetype(id: selectedTypeID) {
                                ForEach(Array(nt.flds.enumerated()), id: \.offset) { idx, field in
                                    GlassInset {
                                        VStack(alignment: .leading, spacing: 6) {
                                            NoteFieldEditor(
                                                html: binding(idx), field: field, isClozeType: nt.isCloze,
                                                mediaBase: store.mediaRoot, sourceMode: !useRichEditor,
                                                nextClozeNumber: (ClozeHelper.ords(in: fieldValues).max() ?? -1) + 2
                                            )
                                            .id("\(nt.id)-\(field.ord)")

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
                                            .foregroundStyle(AppTheme.primaryText)
                                            .lineLimit(1)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(GlassButtonStyle(tint: .white, prominent: false, tintStrength: 0.14, expands: true))
                                    .accessibilityIdentifier("add.history.\(item.id)")
                                }
                            }
                        }
                        if let statusMessage {
                            Text(statusMessage)
                                .foregroundStyle(statusMessage == "Nota adicionada." ? AppTheme.good : AppTheme.danger)
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
                            .accessibilityIdentifier("add.preview")
                            .buttonStyle(GlassButtonStyle(tint: .white, prominent: false, tintStrength: 0.16, expands: true))
                        Button(useRichEditor ? "Editar HTML" : "Editor visual") { useRichEditor.toggle() }
                            .accessibilityIdentifier("add.source")
                            .buttonStyle(GlassButtonStyle(tint: .white, prominent: false, tintStrength: 0.16, expands: true))
                    }
                    HStack(spacing: 12) {
                        Button("Adicionar") { addNote() }
                            .accessibilityIdentifier("add.submit")
                            .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.42, expands: true))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .alert("Nota Cloze sem omissões", isPresented: $showMissingClozeConfirmation) {
                    Button("Adicionar mesmo assim") {
                        addNote(allowMissingCloze: true)
                    }
                    Button("Cancelar", role: .cancel) {}
                } message: {
                    Text("Esta nota não contém nenhuma omissão Cloze. Deseja adicioná-la mesmo assim?")
                }
            }
            .background(AppBackground())
            .navigationTitle("Adicionar")
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Fechar", action: onClose)
                    }
                }
            }
            .ankiKeyboardDismissToolbar()
            .alert("Nota possivelmente duplicada", isPresented: $showDuplicateWarning) {
                Button("Adicionar mesmo assim") {
                    addNote(
                        skipDuplicateCheck: true,
                        allowMissingCloze: pendingAllowMissingCloze
                    )
                }
                Button("Cancelar", role: .cancel) { duplicateIDs = [] }
            } message: {
                Text("O primeiro campo já aparece em \(duplicateIDs.count) nota(s) deste tipo.")
            }
            .sheet(isPresented: $showPreview) {
                previewSheet
            }
            .onAppear {
                if !didLoadDefaults || loadedProfile != store.activeProfile {
                    if loadedProfile != nil {
                        fieldValues = []
                        tags = ""
                        statusMessage = nil
                    }
                    loadDefaults()
                    loadedProfile = store.activeProfile
                    didLoadDefaults = true
                }
                reloadHistory()
                consumeCopyRequest()
            }
            .onChange(of: copyRequest) { _, _ in consumeCopyRequest() }
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
                    side: .question, mediaBase: store.mediaRoot,
                    deckName: store.deck(id: selectedDeckID)?.name ?? "",
                    nightMode: colorScheme == .dark
                )
                CardWebView(
                    html: result.html,
                    baseURL: store.mediaRoot,
                    onSpeechTap: { request in store.mediaStore.speak(request) }
                )
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
        if addToCur, let cur = store.currentDeckID(), store.deck(id: cur)?.isFiltered == false {
            selectedDeckID = cur
        } else {
            selectedDeckID = store.decks.first(where: { !$0.isFiltered && $0.name != "Default" })?.id
                ?? store.decks.first(where: { !$0.isFiltered })?.id ?? 1
        }
        selectSavedDeckForCurrentType()
        syncFields()
        previousTypeID = selectedTypeID
    }

    private func consumeCopyRequest() {
        guard didLoadDefaults, let request = copyRequest else { return }
        guard store.notetype(id: request.note.mid) != nil else {
            store.lastError = "O tipo da nota original não está disponível."
            copyRequest = nil
            return
        }
        skipNextTypeSync = selectedTypeID != request.note.mid
        selectedTypeID = request.note.mid
        previousTypeID = request.note.mid
        selectedDeckID = request.deckID
        fieldValues = request.note.fields
        tags = request.note.tagList.joined(separator: " ")
        store.setCurrentDeck(request.deckID)
        statusMessage = nil
        copyRequest = nil
    }

    private func selectSavedDeckForCurrentType() {
        guard store.conf["deckSelectionBehavior"] as? String == "noteType",
              let remembered = store.conf["lastDeckByNoteType"] as? [String: Any],
              let value = remembered[String(selectedTypeID)] else { return }
        let deckID: Int64?
        if let number = value as? NSNumber { deckID = number.int64Value }
        else if let integer = value as? Int64 { deckID = integer }
        else if let integer = value as? Int { deckID = Int64(integer) }
        else { deckID = nil }
        guard let deckID, store.deck(id: deckID)?.isFiltered == false else { return }
        selectedDeckID = deckID
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

    private func addNote(skipDuplicateCheck: Bool = false, allowMissingCloze: Bool = false) {
        let fieldIssue = store.notetype(id: selectedTypeID).map {
            ClozeHelper.fieldIssue(fields: fieldValues, notetype: $0)
        } ?? .normal
        switch fieldIssue {
        case .clozeOutsideClozeNotetype:
            statusMessage = "Omissões Cloze só podem ser usadas em um tipo de nota Cloze."
            return
        case .clozeInNonClozeField:
            statusMessage = "Este campo não aceita omissões Cloze."
            return
        case .normal, .missingCloze:
            break
        }
        guard let firstField = fieldValues.first,
              !store.stripHTMLPreservingMediaFilenames(firstField).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "O primeiro campo precisa ter conteúdo para adicionar a nota."
            return
        }
        if fieldIssue == .missingCloze && !allowMissingCloze {
            showMissingClozeConfirmation = true
            return
        }
        do {
            if !skipDuplicateCheck {
                let matches = try store.duplicateNoteIDs(mid: selectedTypeID, fields: fieldValues)
                if !matches.isEmpty {
                    duplicateIDs = matches
                    pendingAllowMissingCloze = allowMissingCloze
                    showDuplicateWarning = true
                    return
                }
            }
            try store.addNote(mid: selectedTypeID, did: selectedDeckID, fields: fieldValues, tags: tags)
            store.setCurrentDeck(selectedDeckID)
            var conf = store.conf
            conf["curModel"] = selectedTypeID
            if conf["deckSelectionBehavior"] as? String == "noteType" {
                var remembered = conf["lastDeckByNoteType"] as? [String: Any] ?? [:]
                remembered[String(selectedTypeID)] = selectedDeckID
                conf["lastDeckByNoteType"] = remembered
            }
            try store.saveConf(conf)
            statusMessage = "Nota adicionada."
            reloadHistory()
            if let nt = store.notetype(id: selectedTypeID) {
                let addedValues = fieldValues
                fieldValues = nt.flds.enumerated().map { index, field in
                    field.sticky ? (addedValues[safe: index] ?? "") : ""
                }
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
