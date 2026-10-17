import SwiftUI

struct NoteEditorView: View {
    enum Mode: Hashable {
        case add
        case edit(Int64)
        /// Anki “Create Copy” — editor prefilled; saving inserts a new note.
        case copy(Int64)
    }

    let mode: Mode
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTypeID: Int64 = 0
    @State private var previousTypeID: Int64?
    @State private var selectedDeckID: Int64 = 1
    @State private var fieldValues: [String] = []
    @State private var tags = ""
    @State private var noteID: Int64?
    @State private var showOcclusion = false
    @State private var showDuplicateWarning = false
    @State private var showMissingClozeConfirmation = false
    @State private var pendingAllowMissingCloze = false
    @State private var duplicateCount = 0

    private var title: String {
        switch mode {
        case .add: return "Adicionar nota"
        case .edit: return "Editar nota"
        case .copy: return "Criar cópia"
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !isEditing {
                        GlassFormSection(title: "Baralho") {
                            GlassOptionRow(title: "Baralho") {
                                Picker("", selection: $selectedDeckID) {
                                    ForEach(store.decks.filter { !$0.isFiltered }) { d in
                                        Text(d.name).tag(d.id)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
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
                                .onChange(of: selectedTypeID) { _, newTypeID in changeNotetype(to: newTypeID) }
                            }
                        }
                    }
                    if let nt = store.notetype(id: selectedTypeID), ImageOcclusionNotetype.isImageOcclusion(nt) {
                        Button("Editar máscaras") { showOcclusion = true }
                            .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.16, expands: true))
                    }
                    GlassFormSection(title: "Campos") {
                        if let nt = store.notetype(id: selectedTypeID) {
                            ForEach(Array(nt.flds.enumerated()), id: \.offset) { idx, field in
                                GlassInset {
                                    VStack(alignment: .leading, spacing: 6) {
                                        NoteFieldEditor(
                                            html: binding(idx), field: field, isClozeType: nt.isCloze,
                                            mediaBase: store.mediaRoot,
                                            nextClozeNumber: (ClozeHelper.ords(in: fieldValues).max() ?? -1) + 2
                                        )
                                        .id("\(selectedTypeID)-\(field.ord)")
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
                }
                .padding(20)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            HStack(spacing: 12) {
                Button("Fechar") { dismiss() }
                    .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.18, expands: true))
                Button("Salvar") { save() }
                    .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.42, expands: true))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .alert("Nota Cloze sem omissões", isPresented: $showMissingClozeConfirmation) {
                Button("Salvar mesmo assim") { save(allowMissingCloze: true) }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Esta nota não contém nenhuma omissão Cloze. Deseja salvá-la mesmo assim?")
            }
        }
        .background(AppBackground())
        .navigationTitle(title)
        .ankiKeyboardDismissToolbar()
        .onAppear(perform: load)
        .alert("Nota possivelmente duplicada", isPresented: $showDuplicateWarning) {
            Button("Salvar mesmo assim") {
                save(skipDuplicateCheck: true, allowMissingCloze: pendingAllowMissingCloze)
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("O primeiro campo já aparece em \(duplicateCount) nota(s) deste tipo.")
        }
        .sheet(isPresented: $showOcclusion, onDismiss: reloadAfterOcclusion) {
            ImageOcclusionEditor(deckID: selectedDeckID, noteID: noteID)
                .environmentObject(store)
        }
    }

    private func reloadAfterOcclusion() {
        guard let noteID else { return }
        do {
            if let note = try store.fetchNote(id: noteID) { apply(note: note) }
        }
        catch { store.lastError = error.localizedDescription }
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

    private func load() {
        selectedTypeID = store.notetypes.first?.id ?? 0
        previousTypeID = selectedTypeID
        selectedDeckID = store.currentDeckID().flatMap { id in store.deck(id: id)?.isFiltered == false ? id : nil }
            ?? store.decks.first(where: { !$0.isFiltered && $0.name != "Default" })?.id
            ?? store.decks.first(where: { !$0.isFiltered })?.id ?? 1
        selectSavedDeckForCurrentType()
        switch mode {
        case .edit(let id):
            do {
                guard let note = try store.fetchNote(id: id) else {
                    store.lastError = "A nota não foi encontrada."
                    syncFields()
                    return
                }
                noteID = id
                apply(note: note)
            } catch {
                store.lastError = error.localizedDescription
                syncFields()
            }
        case .copy(let id):
            do {
                guard let note = try store.fetchNote(id: id) else {
                    store.lastError = "A nota não foi encontrada."
                    syncFields()
                    return
                }
                noteID = nil
                apply(note: note)
            } catch {
                store.lastError = error.localizedDescription
                syncFields()
            }
        case .add:
            syncFields()
        }
    }

    private func apply(note: AnkiNote) {
        previousTypeID = note.mid
        selectedTypeID = note.mid
        fieldValues = note.fields
        tags = note.tagList.joined(separator: " ")
        if let did = try? store.db.scalarInt64(
            "SELECT CASE WHEN odid != 0 THEN odid ELSE did END FROM cards WHERE nid = ? LIMIT 1",
            bind: { SQLiteDatabase.bindInt64($0, 1, note.id) }
        ) {
            selectedDeckID = did
        }
    }

    private func syncFields() {
        guard let nt = store.notetype(id: selectedTypeID) else { return }
        if fieldValues.count != nt.flds.count {
            fieldValues = nt.flds.map { _ in "" }
        }
    }

    private func changeNotetype(to newTypeID: Int64) {
        guard let newType = store.notetype(id: newTypeID) else { return }
        if let previousTypeID, let previousType = store.notetype(id: previousTypeID) {
            fieldValues = NotetypeEditMapping.transferNoteFieldValues(fieldValues, from: previousType, to: newType)
        } else {
            fieldValues = newType.flds.map { _ in "" }
        }
        previousTypeID = newTypeID
        selectSavedDeckForCurrentType()
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

    private func save(skipDuplicateCheck: Bool = false, allowMissingCloze: Bool = false) {
        do {
            if !isEditing {
                let fieldIssue = store.notetype(id: selectedTypeID).map {
                    ClozeHelper.fieldIssue(fields: fieldValues, notetype: $0)
                } ?? .normal
                switch fieldIssue {
                case .clozeOutsideClozeNotetype:
                    store.lastError = "Omissões Cloze só podem ser usadas em um tipo de nota Cloze."
                    return
                case .clozeInNonClozeField:
                    store.lastError = "Este campo não aceita omissões Cloze."
                    return
                case .normal, .missingCloze:
                    break
                }
                guard let firstField = fieldValues.first,
                      !store.stripHTMLPreservingMediaFilenames(firstField).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    store.lastError = "O primeiro campo precisa ter conteúdo para adicionar a nota."
                    return
                }
                if fieldIssue == .missingCloze && !allowMissingCloze {
                    showMissingClozeConfirmation = true
                    return
                }
                if !skipDuplicateCheck {
                    let matches = try store.duplicateNoteIDs(mid: selectedTypeID, fields: fieldValues)
                    if !matches.isEmpty {
                        duplicateCount = matches.count
                        pendingAllowMissingCloze = allowMissingCloze
                        showDuplicateWarning = true
                        return
                    }
                }
            }
            if let noteID, let note = try store.fetchNote(id: noteID) {
                try store.updateNote(note, fields: fieldValues, tags: tags)
            } else {
                try store.addNote(mid: selectedTypeID, did: selectedDeckID, fields: fieldValues, tags: tags)
            }
            if !isEditing {
                store.setCurrentDeck(selectedDeckID)
                var conf = store.conf
                conf["curModel"] = selectedTypeID
                if conf["deckSelectionBehavior"] as? String == "noteType" {
                    var remembered = conf["lastDeckByNoteType"] as? [String: Any] ?? [:]
                    remembered[String(selectedTypeID)] = selectedDeckID
                    conf["lastDeckByNoteType"] = remembered
                }
                try store.saveConf(conf)
            }
            dismiss()
        } catch {
            store.lastError = error.localizedDescription
        }
    }
}
