import SwiftUI

struct NoteTypesView: View {
    @EnvironmentObject private var store: CollectionStore
    @State private var editing: AnkiNotetype?
    @State private var pendingDeletion: AnkiNotetype?
    @State private var pendingDeletionNoteCount = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(store.notetypes) { nt in
                    Button {
                        editing = nt
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(nt.name)
                                    .font(.headline)
                                    .foregroundStyle(AppTheme.primaryText)
                                Text("\(nt.flds.count) campos · \(nt.tmpls.count) templates\(nt.isCloze ? " · cloze" : "")")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.secondaryText)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .foregroundStyle(AppTheme.primaryText.opacity(0.55))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .ankiGlass(tint: .white.opacity(0.08), interactive: true, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Duplicar: \(nt.name)") { duplicateNoteType(nt) }
                        Button("Apagar", role: .destructive) { requestDeleteNoteType(nt) }
                    }
                }
                typeAction("Adicionar Basic", systemImage: "plus") { createBasic() }
                typeAction("Adicionar Basic (e invertido)", systemImage: "arrow.left.arrow.right") { createBasicAndReversed() }
                typeAction("Adicionar Basic (invertido opcional)", systemImage: "arrow.uturn.left") { createBasicOptionalReversed() }
                typeAction("Adicionar Basic (digite a resposta)", systemImage: "keyboard") { createBasicTyping() }
                typeAction("Adicionar tipo Cloze", systemImage: "plus.square.on.square") { createCloze() }
                typeAction("Adicionar oclusão de imagem", systemImage: "square.dashed") {
                    do { _ = try ImageOcclusionNotetype.ensure(store) }
                    catch { store.lastError = error.localizedDescription }
                }
            }
            .padding(20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(AppBackground())
        .navigationTitle("Tipos de nota")
        .sheet(item: $editing) { nt in
            TemplateEditorView(notetype: nt)
                .environmentObject(store)
        }
        .confirmationDialog("Apagar tipo de nota?", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible) {
            if let nt = pendingDeletion {
                Button("Apagar", role: .destructive) { deleteNoteType(nt) }
            }
            Button("Cancelar", role: .cancel) { pendingDeletion = nil }
        } message: {
            if pendingDeletionNoteCount > 0 {
                let noteLabel = pendingDeletionNoteCount == 1 ? "nota" : "notas"
                Text("Este tipo de nota tem \(pendingDeletionNoteCount) \(noteLabel). Apagá-lo também apagará essas notas e os cartões associados.")
            } else {
                Text("Este tipo de nota não está em uso.")
            }
        }
    }

    private func typeAction(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(GlassButtonStyle(tint: .white, prominent: false, tintStrength: 0.16, expands: true))
        .accessibilityIdentifier("notetypes.action.\(title)")
    }

    private func createBasic() {
        let id = store.timestampID()
        let now = Int64(Date().timeIntervalSince1970)
        let nt = AnkiNotetype(
            id: id,
            name: "Basic \(id % 1000)",
            type: 0,
            mod: now,
            tmpls: [
                AnkiTemplate(name: "Card 1", ord: 0, qfmt: "{{Front}}", afmt: "{{FrontSide}}<hr id=answer>{{Back}}")
            ],
            flds: [
                AnkiField(name: "Front", ord: 0),
                AnkiField(name: "Back", ord: 1)
            ]
        )
        var types = store.notetypes
        types.append(nt)
        save(types)
    }

    private func createBasicAndReversed() {
        let id = store.timestampID()
        let now = Int64(Date().timeIntervalSince1970)
        let nt = AnkiNotetype(
            id: id,
            name: "Basic (and reversed) \(id % 1000)",
            type: 0,
            mod: now,
            tmpls: [
                AnkiTemplate(name: "Card 1", ord: 0, qfmt: "{{Front}}", afmt: "{{FrontSide}}<hr id=answer>{{Back}}"),
                AnkiTemplate(name: "Card 2", ord: 1, qfmt: "{{Back}}", afmt: "{{FrontSide}}<hr id=answer>{{Front}}")
            ],
            flds: [
                AnkiField(name: "Front", ord: 0),
                AnkiField(name: "Back", ord: 1)
            ]
        )
        var types = store.notetypes
        types.append(nt)
        save(types)
    }

    private func createBasicOptionalReversed() {
        let id = store.timestampID()
        let now = Int64(Date().timeIntervalSince1970)
        let nt = AnkiNotetype(
            id: id,
            name: "Basic (optional reversed) \(id % 1000)",
            type: 0,
            mod: now,
            tmpls: [
                AnkiTemplate(name: "Card 1", ord: 0, qfmt: "{{Front}}", afmt: "{{FrontSide}}<hr id=answer>{{Back}}"),
                AnkiTemplate(
                    name: "Card 2",
                    ord: 1,
                    qfmt: "{{#Add Reverse}}{{Back}}{{/Add Reverse}}",
                    afmt: "{{FrontSide}}<hr id=answer>{{Front}}"
                )
            ],
            flds: [
                AnkiField(name: "Front", ord: 0),
                AnkiField(name: "Back", ord: 1),
                AnkiField(name: "Add Reverse", ord: 2)
            ]
        )
        var types = store.notetypes
        types.append(nt)
        save(types)
    }

    private func createBasicTyping() {
        let id = store.timestampID()
        let now = Int64(Date().timeIntervalSince1970)
        let nt = AnkiNotetype(
            id: id,
            name: "Basic (type in the answer) \(id % 1000)",
            type: 0,
            mod: now,
            tmpls: [
                AnkiTemplate(
                    name: "Card 1",
                    ord: 0,
                    qfmt: "{{Front}}\n{{type:Back}}",
                    afmt: "{{FrontSide}}\n\n<hr id=answer>\n\n{{type:Back}}"
                )
            ],
            flds: [
                AnkiField(name: "Front", ord: 0),
                AnkiField(name: "Back", ord: 1)
            ]
        )
        var types = store.notetypes
        types.append(nt)
        save(types)
    }

    private func createCloze() {
        let id = store.timestampID()
        let now = Int64(Date().timeIntervalSince1970)
        let nt = AnkiNotetype(
            id: id,
            name: "Cloze \(id % 1000)",
            type: 1,
            mod: now,
            tmpls: [
                AnkiTemplate(name: "Cloze", ord: 0, qfmt: "{{cloze:Text}}", afmt: "{{cloze:Text}}<br>{{Extra}}")
            ],
            flds: [
                AnkiField(name: "Text", ord: 0),
                AnkiField(name: "Extra", ord: 1)
            ]
        )
        var types = store.notetypes
        types.append(nt)
        save(types)
    }

    private func duplicateNoteType(_ nt: AnkiNotetype) {
        var copy = nt
        copy.id = store.timestampID()
        copy.name = "\(nt.name) copy"
        copy.mod = Int64(Date().timeIntervalSince1970)
        var types = store.notetypes
        types.append(copy)
        save(types)
    }

    private func requestDeleteNoteType(_ nt: AnkiNotetype) {
        guard store.notetypes.count > 1 else {
            store.lastError = "Adicione outro tipo de nota antes de apagar este."
            return
        }
        do {
            pendingDeletionNoteCount = try store.db.scalarInt("SELECT COUNT(*) FROM notes WHERE mid = ?", bind: {
                SQLiteDatabase.bindInt64($0, 1, nt.id)
            })
        } catch {
            store.lastError = error.localizedDescription
            return
        }
        pendingDeletion = nt
    }

    private func deleteNoteType(_ nt: AnkiNotetype) {
        do { try store.deleteNotetypeUndoably(id: nt.id) }
        catch { store.lastError = error.localizedDescription }
        pendingDeletion = nil
    }

    private func save(_ types: [AnkiNotetype]) {
        do { try store.saveNotetypes(types) }
        catch { store.lastError = error.localizedDescription }
    }
}

struct TemplateEditorView: View {
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.dismiss) private var dismiss
    @State var notetype: AnkiNotetype
    private let originalNotetype: AnkiNotetype
    @State private var selectedTemplate = 0
    @State private var previewSide = 0

    init(notetype: AnkiNotetype) {
        var prepared = notetype
        prepared.assignMissingComponentIDs()
        originalNotetype = prepared
        _notetype = State(initialValue: prepared)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        GlassFormSection(title: "Nome") {
                            GlassInset {
                                TextField("Nome", text: $notetype.name)
                                    .textFieldStyle(.plain)
                            }
                        }
                        GlassFormSection(title: "editor.fields.section") {
                            ForEach(Array(notetype.flds.enumerated()), id: \.offset) { idx, _ in
                                GlassOptionRow(title: "Campo \(idx + 1)") {
                                    VStack(alignment: .trailing, spacing: 10) {
                                        HStack(spacing: 10) {
                                            TextField("Nome", text: $notetype.flds[idx].name)
                                                .textFieldStyle(.plain)
                                                .multilineTextAlignment(.trailing)
                                                .frame(minWidth: 120)
                                                .accessibilityIdentifier("notetype.field.name.\(idx)")
                                            Toggle("Fixo", isOn: $notetype.flds[idx].sticky)
                                                .labelsHidden()
                                                .tint(AppTheme.accent)
                                                .accessibilityIdentifier("notetype.field.sticky.\(idx)")
                                            Button {
                                                moveField(at: idx, by: -1)
                                            } label: {
                                                Image(systemName: "chevron.up")
                                            }
                                            .buttonStyle(GlassIconButtonStyle())
                                            .accessibilityLabel("Mover campo para cima")
                                            .accessibilityIdentifier("notetype.field.moveUp.\(idx)")
                                            .disabled(idx == 0)
                                            Button {
                                                moveField(at: idx, by: 1)
                                            } label: {
                                                Image(systemName: "chevron.down")
                                            }
                                            .buttonStyle(GlassIconButtonStyle())
                                            .accessibilityLabel("Mover campo para baixo")
                                            .disabled(idx == notetype.flds.count - 1)
                                            Button {
                                                removeField(at: idx)
                                            } label: {
                                                Image(systemName: "minus.circle.fill")
                                                    .foregroundStyle(AppTheme.danger)
                                            }
                                            .buttonStyle(GlassIconButtonStyle(tint: AppTheme.danger))
                                            .disabled(notetype.flds.count <= 1 || notetype.flds[idx].preventDeletion)
                                        }
                                        VStack(alignment: .leading, spacing: 10) {
                                            Toggle("RTL", isOn: $notetype.flds[idx].rtl)
                                            Toggle("Editor HTML por padrão", isOn: $notetype.flds[idx].plainText)
                                            Toggle("Recolher por padrão", isOn: $notetype.flds[idx].collapsed)
                                            Toggle("Excluir busca", isOn: $notetype.flds[idx].excludeFromSearch)
                                        }
                                        .tint(AppTheme.accent)
                                        HStack {
                                            TextField("Fonte", text: $notetype.flds[idx].font)
                                                .textFieldStyle(.plain)
                                            Stepper("\(notetype.flds[idx].size) pt", value: $notetype.flds[idx].size, in: 6...200)
                                                .fixedSize()
                                        }
                                        TextField("Descrição do campo", text: $notetype.flds[idx].description)
                                            .textFieldStyle(.plain)
                                            .multilineTextAlignment(.trailing)
                                    }
                                }
                            }
                            GlassOptionRow(title: "Campo de ordenação") {
                                Picker("", selection: $notetype.sortf) {
                                    ForEach(notetype.flds.sorted { $0.ord < $1.ord }, id: \.ord) { field in
                                        Text(field.name).tag(field.ord)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                            }
                            Button("Adicionar campo") {
                                let ord = notetype.flds.count
                                notetype.flds.append(AnkiField(name: "Campo \(ord + 1)", ord: ord))
                            }
                            .buttonStyle(GlassButtonStyle(tint: .white, prominent: false, tintStrength: 0.16, expands: true))
                            if !notetype.isCloze {
                                Button("Adicionar template") {
                                    let ord = notetype.tmpls.count
                                    notetype.tmpls.append(AnkiTemplate(
                                        name: "Card \(ord + 1)",
                                        ord: ord,
                                        qfmt: "{{\(notetype.flds.first?.name ?? "Front")}}",
                                        afmt: "{{FrontSide}}<hr id=answer>{{\(notetype.flds.dropFirst().first?.name ?? "Back")}}"
                                    ))
                                }
                                .buttonStyle(GlassButtonStyle(tint: .white, prominent: false, tintStrength: 0.16, expands: true))
                            }
                        }
                        if !notetype.tmpls.isEmpty {
                            GlassFormSection(title: "Template") {
                                templateField("Nome", text: $notetype.tmpls[selectedTemplate].name)
                                GlassOptionRow(title: "Cartão") {
                                    HStack(spacing: 10) {
                                        Picker("", selection: $selectedTemplate) {
                                            ForEach(Array(notetype.tmpls.indices), id: \.self) { i in
                                                Text(notetype.tmpls[i].name).tag(i)
                                            }
                                        }
                                        .labelsHidden()
                                        .pickerStyle(.menu)
                                        Button {
                                            moveTemplate(at: selectedTemplate, by: -1)
                                        } label: {
                                            Image(systemName: "chevron.up")
                                        }
                                        .buttonStyle(GlassIconButtonStyle())
                                        .accessibilityLabel("Mover cartão para cima")
                                        .disabled(selectedTemplate == 0)
                                        Button {
                                            moveTemplate(at: selectedTemplate, by: 1)
                                        } label: {
                                            Image(systemName: "chevron.down")
                                        }
                                        .buttonStyle(GlassIconButtonStyle())
                                        .accessibilityLabel("Mover cartão para baixo")
                                        .disabled(selectedTemplate == notetype.tmpls.count - 1)
                                    }
                                }
                                templateField("Frente (qfmt)", text: $notetype.tmpls[selectedTemplate].qfmt)
                                templateField("Verso (afmt)", text: $notetype.tmpls[selectedTemplate].afmt)
                                templateField("Painel — pergunta (bqfmt)", text: $notetype.tmpls[selectedTemplate].bqfmt)
                                templateField("Painel — resposta (bafmt)", text: $notetype.tmpls[selectedTemplate].bafmt)
                                GlassOptionRow(title: "Fonte no verso") {
                                    TextField("Arial", text: $notetype.tmpls[selectedTemplate].bfont)
                                        .textFieldStyle(.plain)
                                        .multilineTextAlignment(.trailing)
                                }
                                GlassOptionRow(title: "Tamanho no verso") {
                                    Stepper("\(notetype.tmpls[selectedTemplate].bsize) pt", value: $notetype.tmpls[selectedTemplate].bsize, in: 6...200)
                                        .fixedSize()
                                }
                                GlassOptionRow(title: "Baralho deste cartão") {
                                    Picker("", selection: templateDeckBinding(selectedTemplate)) {
                                        Text("Usar baralho da nota").tag(Optional<Int64>.none)
                                        ForEach(store.decks.filter { !$0.isFiltered }) { deck in
                                            Text(deck.name).tag(Optional(deck.id))
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                }
                                Button("Apagar template", systemImage: "trash", role: .destructive) {
                                    removeTemplate(at: selectedTemplate)
                                }
                                .disabled(notetype.tmpls.count <= 1)
                                .buttonStyle(GlassButtonStyle(tint: AppTheme.danger, prominent: false, tintStrength: 0.18, expands: true))
                            }
                        }
                        GlassFormSection(title: "CSS") {
                            GlassInset {
                                TextField("CSS", text: $notetype.css, axis: .vertical)
                                    .lineLimit(6...20)
                                    .font(.system(.footnote, design: .monospaced))
                                    .accessibilityIdentifier("notetype.editor.css")
                            }
                        }
                        GlassFormSection(title: "LaTeX") {
                            Toggle("Criar imagens escaláveis com dvisvgm", isOn: $notetype.latexsvg)
                                .tint(AppTheme.accent)
                            templateField("Cabeçalho", text: $notetype.latexPre)
                            templateField("Rodapé", text: $notetype.latexPost)
                        }
                        GlassFormSection(title: "note-types.preview.section") {
                            Picker("Lado", selection: $previewSide) {
                                Text("Frente").tag(0)
                                Text("Verso").tag(1)
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("notetype.editor.previewSide")
                            CardWebView(
                                html: previewHTML,
                                baseURL: store.mediaRoot,
                                onSpeechTap: { request in store.mediaStore.speak(request) }
                            )
                                .frame(height: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                HStack(spacing: 12) {
                    Button("Cancelar") { dismiss() }
                        .accessibilityIdentifier("notetype.editor.cancel")
                        .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.18, expands: true))
                    Button("Salvar") {
                        let normalizedFields = notetype.flds.map { AnkiField.normalizedName($0.name) }
                        guard normalizedFields.allSatisfy({ $0 != nil }) else {
                            store.lastError = "O nome de cada campo precisa conter pelo menos um caractere válido."
                            return
                        }
                        notetype.flds = notetype.flds.enumerated().map { index, field in
                            var field = field
                            field.name = normalizedFields[index] ?? field.name
                            return field
                        }
                        let fieldNames = notetype.flds.map { $0.name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) }
                        let templateNames = notetype.tmpls.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                        guard fieldNames.allSatisfy({ !$0.isEmpty }), Set(fieldNames).count == fieldNames.count else {
                            store.lastError = "Cada campo precisa ter um nome único."
                            return
                        }
                        guard templateNames.allSatisfy({ !$0.isEmpty }), Set(templateNames).count == templateNames.count else {
                            store.lastError = "Cada template precisa ter um nome único."
                            return
                        }
                        do {
                            notetype.assignMissingComponentIDs()
                            notetype.flds = notetype.flds.enumerated().map { index, field in
                                var field = field
                                field.ord = index
                                return field
                            }
                            notetype.tmpls = notetype.tmpls.enumerated().map { index, template in
                                var template = template
                                template.ord = index
                                return template
                            }
                            notetype.sortf = min(max(notetype.sortf, 0), max(notetype.flds.count - 1, 0))
                            notetype.mod = Int64(Date().timeIntervalSince1970)
                            try store.saveEditedNotetype(notetype, replacing: originalNotetype)
                            dismiss()
                        } catch {
                            store.lastError = error.localizedDescription
                        }
                    }
                    .accessibilityIdentifier("notetype.editor.save")
                    .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.42, expands: true))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .background(AppBackground())
            .navigationTitle("Editar tipo de nota")
            .ankiKeyboardDismissToolbar()
        }
    }

    private func templateField(_ title: String, text: Binding<String>) -> some View {
        GlassInset {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mist)
                TextField(title, text: text, axis: .vertical)
                    .lineLimit(3...10)
                    .font(.system(.footnote, design: .monospaced))
                    .accessibilityIdentifier("notetype.template.\(title)")
            }
        }
    }

    private func templateDeckBinding(_ index: Int) -> Binding<Int64?> {
        Binding(
            get: { notetype.tmpls.indices.contains(index) ? notetype.tmpls[index].did : nil },
            set: { if notetype.tmpls.indices.contains(index) { notetype.tmpls[index].did = $0 } }
        )
    }

    private func removeField(at index: Int) {
        guard notetype.flds.count > 1, notetype.flds.indices.contains(index), !notetype.flds[index].preventDeletion else { return }
        notetype.flds.remove(at: index)
        notetype.flds = notetype.flds.enumerated().map { ord, field in
            var field = field
            field.ord = ord
            return field
        }
        if notetype.sortf == index {
            notetype.sortf = min(index, notetype.flds.count - 1)
        } else if notetype.sortf > index {
            notetype.sortf -= 1
        }
    }

    private func moveField(at index: Int, by offset: Int) {
        let destination = index + offset
        guard notetype.flds.indices.contains(index), notetype.flds.indices.contains(destination) else { return }
        let sortFieldName = notetype.flds.first(where: { $0.ord == notetype.sortf })?.name
        notetype.flds.swapAt(index, destination)
        notetype.flds = notetype.flds.enumerated().map { ord, field in
            var field = field
            field.ord = ord
            return field
        }
        if let sortFieldName, let newIndex = notetype.flds.firstIndex(where: { $0.name == sortFieldName }) {
            notetype.sortf = newIndex
        }
    }

    private func moveTemplate(at index: Int, by offset: Int) {
        let destination = index + offset
        guard notetype.tmpls.indices.contains(index), notetype.tmpls.indices.contains(destination) else { return }
        notetype.tmpls.swapAt(index, destination)
        notetype.tmpls = notetype.tmpls.enumerated().map { ord, template in
            var template = template
            template.ord = ord
            return template
        }
        selectedTemplate = destination
    }

    private func removeTemplate(at index: Int) {
        guard notetype.tmpls.count > 1, notetype.tmpls.indices.contains(index) else { return }
        notetype.tmpls.remove(at: index)
        notetype.tmpls = notetype.tmpls.enumerated().map { ord, template in
            var template = template
            template.ord = ord
            return template
        }
        selectedTemplate = min(selectedTemplate, notetype.tmpls.count - 1)
    }

    private var previewHTML: String {
        let fields = Dictionary(uniqueKeysWithValues: notetype.flds.enumerated().map { ($0.element.name, "Sample \($0.element.name)") })
        let tmpl = notetype.tmpls[safe: selectedTemplate]
        let front = TemplateEngine.render(template: tmpl?.qfmt ?? "", fields: fields, frontSide: nil, clozeOrd: nil, questionSide: true)
        let body: String
        if previewSide == 0 {
            body = front
        } else {
            body = TemplateEngine.render(template: tmpl?.afmt ?? "", fields: fields, frontSide: front, clozeOrd: nil, questionSide: false)
        }
        return CardHTMLRenderer_wrap(
            body: AnkiLatexMarkup.replacing(in: body, svg: notetype.latexsvg),
            css: notetype.css
        )
    }
}

private func CardHTMLRenderer_wrap(body: String, css: String) -> String {
    """
    <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
    <style>body{color:#182127;background:transparent;font-family:-apple-system;padding:16px;} @media(prefers-color-scheme:dark){body{color:#e8f4f5;}} \(css)</style>
    </head><body><div class="card">\(body)</div></body></html>
    """
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
