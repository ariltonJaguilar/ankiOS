import SwiftUI

struct NoteTypesView: View {
    @EnvironmentObject private var store: CollectionStore
    @State private var editing: AnkiNotetype?

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
                                    .foregroundStyle(.white)
                                Text("\(nt.flds.count) campos · \(nt.tmpls.count) templates\(nt.isCloze ? " · cloze" : "")")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.secondaryText)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .glassEffect(.regular.tint(.white.opacity(0.08)), in: .rect(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Duplicar") { duplicateNoteType(nt) }
                        Button("Apagar", role: .destructive) { deleteNoteType(nt) }
                    }
                }
                typeAction("Adicionar Basic", systemImage: "plus") { createBasic() }
                typeAction("Adicionar Basic (e invertido)", systemImage: "arrow.left.arrow.right") { createBasicAndReversed() }
                typeAction("Adicionar Basic (invertido opcional)", systemImage: "arrow.uturn.left") { createBasicOptionalReversed() }
                typeAction("Adicionar Basic (digite a resposta)", systemImage: "keyboard") { createBasicTyping() }
                typeAction("Adicionar tipo Cloze", systemImage: "plus.square.on.square") { createCloze() }
                typeAction("Adicionar oclusão de imagem", systemImage: "square.dashed") {
                    _ = try? ImageOcclusionNotetype.ensure(store)
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
    }

    private func typeAction(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(GlassButtonStyle(tint: .white, prominent: false, tintStrength: 0.16, expands: true))
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
        try? store.saveNotetypes(types)
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
        try? store.saveNotetypes(types)
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
        try? store.saveNotetypes(types)
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
        try? store.saveNotetypes(types)
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
        try? store.saveNotetypes(types)
    }

    private func duplicateNoteType(_ nt: AnkiNotetype) {
        var copy = nt
        copy.id = store.timestampID()
        copy.name = "\(nt.name) copy"
        copy.mod = Int64(Date().timeIntervalSince1970)
        var types = store.notetypes
        types.append(copy)
        try? store.saveNotetypes(types)
    }

    private func deleteNoteType(_ nt: AnkiNotetype) {
        let inUse = (try? store.db.scalarInt("SELECT COUNT(*) FROM notes WHERE mid = ?", bind: {
            SQLiteDatabase.bindInt64($0, 1, nt.id)
        })) ?? 0
        guard inUse == 0 else {
            store.lastError = "Tipo em uso por \(inUse) nota(s). Mude o tipo delas antes."
            return
        }
        guard store.notetypes.count > 1 else {
            store.lastError = "É preciso manter ao menos um tipo de nota."
            return
        }
        var types = store.notetypes
        types.removeAll { $0.id == nt.id }
        try? store.saveNotetypes(types)
    }
}

struct TemplateEditorView: View {
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.dismiss) private var dismiss
    @State var notetype: AnkiNotetype
    @State private var selectedTemplate = 0
    @State private var previewSide = 0

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
                        GlassFormSection(title: "Campos") {
                            ForEach(Array(notetype.flds.enumerated()), id: \.offset) { idx, _ in
                                GlassOptionRow(title: "Campo \(idx + 1)") {
                                    HStack(spacing: 10) {
                                        TextField("Nome", text: $notetype.flds[idx].name)
                                            .textFieldStyle(.plain)
                                            .multilineTextAlignment(.trailing)
                                            .frame(minWidth: 120)
                                        Toggle("Fixo", isOn: $notetype.flds[idx].sticky)
                                            .labelsHidden()
                                            .tint(AppTheme.accent)
                                    }
                                }
                            }
                            Button("Adicionar campo") {
                                let ord = notetype.flds.count
                                notetype.flds.append(AnkiField(name: "Campo \(ord + 1)", ord: ord))
                            }
                            .buttonStyle(GlassButtonStyle(tint: .white, prominent: false, tintStrength: 0.16, expands: true))
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
                        if !notetype.tmpls.isEmpty {
                            GlassFormSection(title: "Template") {
                                GlassOptionRow(title: "Cartão") {
                                    Picker("", selection: $selectedTemplate) {
                                        ForEach(Array(notetype.tmpls.indices), id: \.self) { i in
                                            Text(notetype.tmpls[i].name).tag(i)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                }
                                templateField("Frente (qfmt)", text: $notetype.tmpls[selectedTemplate].qfmt)
                                templateField("Verso (afmt)", text: $notetype.tmpls[selectedTemplate].afmt)
                                templateField("Painel — pergunta (bqfmt)", text: $notetype.tmpls[selectedTemplate].bqfmt)
                                templateField("Painel — resposta (bafmt)", text: $notetype.tmpls[selectedTemplate].bafmt)
                            }
                        }
                        GlassFormSection(title: "CSS") {
                            GlassInset {
                                TextField("CSS", text: $notetype.css, axis: .vertical)
                                    .lineLimit(6...20)
                                    .font(.system(.footnote, design: .monospaced))
                            }
                        }
                        GlassFormSection(title: "Pré-visualização") {
                            Picker("Lado", selection: $previewSide) {
                                Text("Frente").tag(0)
                                Text("Verso").tag(1)
                            }
                            .pickerStyle(.segmented)
                            CardWebView(html: previewHTML, baseURL: store.mediaRoot)
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
                        .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.18, expands: true))
                    Button("Salvar") {
                        var types = store.notetypes
                        if let idx = types.firstIndex(where: { $0.id == notetype.id }) {
                            notetype.mod = Int64(Date().timeIntervalSince1970)
                            types[idx] = notetype
                        } else {
                            types.append(notetype)
                        }
                        try? store.saveNotetypes(types)
                        try? store.syncCardsForNotetype(mid: notetype.id)
                        dismiss()
                    }
                    .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.42, expands: true))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .background(AppBackground())
            .navigationTitle("Editar tipo de nota")
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
            }
        }
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
        return CardHTMLRenderer_wrap(body: body, css: notetype.css)
    }
}

private func CardHTMLRenderer_wrap(body: String, css: String) -> String {
    """
    <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
    <style>body{color:#e8f4f5;background:transparent;font-family:-apple-system;padding:16px;} \(css)</style>
    </head><body><div class="card">\(body)</div></body></html>
    """
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
