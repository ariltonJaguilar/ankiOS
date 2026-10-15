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
    @State private var selectedDeckID: Int64 = 1
    @State private var fieldValues: [String] = []
    @State private var tags = ""
    @State private var noteID: Int64?
    @State private var showOcclusion = false

    private var title: String {
        switch mode {
        case .add: return "Adicionar nota"
        case .edit: return "Editar nota"
        case .copy: return "Criar cópia"
        }
    }

    var body: some View {
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
                    if let nt = store.notetype(id: selectedTypeID), ImageOcclusionNotetype.isImageOcclusion(nt) {
                        Button("Editar máscaras") { showOcclusion = true }
                            .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.16, expands: true))
                    }
                    GlassFormSection(title: "Campos") {
                        if let nt = store.notetype(id: selectedTypeID) {
                            ForEach(Array(nt.flds.enumerated()), id: \.offset) { idx, field in
                                GlassInset {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(field.name)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(AppTheme.mist)
                                        FieldFormatBar(text: binding(idx), isClozeType: nt.isCloze)
                                        TextField(field.name, text: binding(idx), axis: .vertical)
                                            .lineLimit(3...8)
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
        }
        .background(AppBackground())
        .navigationTitle(title)
        .onAppear(perform: load)
        .sheet(isPresented: $showOcclusion, onDismiss: reloadAfterOcclusion) {
            ImageOcclusionEditor(deckID: selectedDeckID, noteID: noteID)
                .environmentObject(store)
        }
    }

    private func reloadAfterOcclusion() {
        guard let noteID, let note = try? store.fetchNote(id: noteID) else { return }
        apply(note: note)
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
        selectedDeckID = store.currentDeckID()
            ?? store.decks.first(where: { $0.name != "Default" })?.id
            ?? store.decks.first?.id ?? 1
        switch mode {
        case .edit(let id):
            guard let note = try? store.fetchNote(id: id) else { syncFields(); return }
            noteID = id
            apply(note: note)
        case .copy(let id):
            guard let note = try? store.fetchNote(id: id) else { syncFields(); return }
            noteID = nil // save creates a new note
            apply(note: note)
        case .add:
            syncFields()
        }
    }

    private func apply(note: AnkiNote) {
        selectedTypeID = note.mid
        fieldValues = note.fields
        tags = note.tagList.joined(separator: " ")
        if let did = try? store.db.scalarInt64(
            "SELECT did FROM cards WHERE nid = ? LIMIT 1",
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

    private func save() {
        do {
            if let noteID, let note = try store.fetchNote(id: noteID) {
                try store.updateNote(note, fields: fieldValues, tags: tags)
            } else {
                try store.addNote(mid: selectedTypeID, did: selectedDeckID, fields: fieldValues, tags: tags)
            }
            store.setCurrentDeck(selectedDeckID)
            var conf = store.conf
            conf["curModel"] = selectedTypeID
            try? store.saveConf(conf)
            dismiss()
        } catch {
            store.lastError = error.localizedDescription
        }
    }
}
