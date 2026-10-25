import SwiftUI

struct CSVImportReviewView: View {
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.dismiss) private var dismiss
    let fileName: String
    let text: String
    @Binding var offerTutorialAfterDismissal: Bool

    @State private var importSummary: String?
    @State private var importFailed = false

    @State private var deckID: Int64?
    @State private var notetypeID: Int64?
    @State private var separatorChoice: String
    @State private var allowHTML: Bool
    @State private var existingNotePolicy: CSVImporter.ExistingNotePolicy
    @State private var matchWithinDeck: Bool
    @State private var tagsForAllNotes: String
    @State private var tagsForUpdatedNotes: String
    @State private var skipFirstRow = false
    @State private var columnMappings: [CSVImporter.ColumnMapping] = []
    @State private var preview: CSVImporter.Preview?

    init(
        fileName: String,
        text: String,
        store: CollectionStore,
        offerTutorialAfterDismissal: Binding<Bool>,
        deckID: Int64? = nil,
        notetypeID: Int64? = nil
    ) {
        self.fileName = fileName
        self.text = text
        _offerTutorialAfterDismissal = offerTutorialAfterDismissal
        let preferredDeck = (store.conf["csvDeckID"] as? NSNumber)?.int64Value
        let defaultDeck = store.decks.first(where: { !$0.isFiltered && $0.name != "Default" })?.id
            ?? store.decks.first(where: { !$0.isFiltered })?.id
        _deckID = State(initialValue: deckID ?? preferredDeck ?? defaultDeck)
        let preferredNotetype = (store.conf["csvNotetypeID"] as? NSNumber)?.int64Value
        _notetypeID = State(initialValue: notetypeID ?? preferredNotetype ?? store.notetypes.first?.id)
        _separatorChoice = State(initialValue: store.conf["csvSeparator"] as? String ?? "auto")
        _allowHTML = State(initialValue: store.conf["csvAllowHTML"] as? Bool ?? true)
        _existingNotePolicy = State(
            initialValue: CSVImporter.ExistingNotePolicy(rawValue: store.conf["csvExistingNotePolicy"] as? String ?? "") ?? .update
        )
        _matchWithinDeck = State(initialValue: store.conf["csvMatchWithinDeck"] as? Bool ?? false)
        _tagsForAllNotes = State(initialValue: store.conf["csvTagsForAllNotes"] as? String ?? "")
        _tagsForUpdatedNotes = State(initialValue: store.conf["csvTagsForUpdatedNotes"] as? String ?? "")
    }

    var body: some View {
        NavigationStack {
            Group {
                if let importSummary {
                    VStack(alignment: .leading, spacing: 18) {
                        GlassFormSection(title: importFailed ? "Falha na importação" : "Importação concluída") {
                            Text(importSummary)
                                .font(.body)
                                .foregroundStyle(AppTheme.primaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("csv.import.summary")
                        }
                        Button("OK") { dismiss() }
                            .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.42, expands: true))
                    }
                    .padding(20)
                    .frame(maxWidth: 760, maxHeight: .infinity, alignment: .top)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                    GlassFormSection(title: "Arquivo") {
                        GlassOptionRow(title: "Nome") {
                            Text(fileName).foregroundStyle(AppTheme.secondaryText)
                        }
                        GlassOptionRow(title: "Separador") {
                            Picker("", selection: $separatorChoice) {
                                Text("Detectar").tag("auto")
                                Text("Tabulação").tag("tab")
                                Text("Vírgula").tag("comma")
                                Text("Ponto e vírgula").tag("semicolon")
                                Text("Espaço").tag("space")
                                Text("Barra vertical").tag("pipe")
                                Text("Dois-pontos").tag("colon")
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("csv.separator")
                            .onChange(of: separatorChoice) { _, _ in refreshPreview(resetMappings: true) }
                        }
                        GlassOptionRow(title: "A primeira linha contém nomes de coluna") {
                            Toggle("", isOn: $skipFirstRow)
                                .labelsHidden()
                                .tint(AppTheme.accent)
                                .accessibilityIdentifier("csv.skipFirstRow")
                                .onChange(of: skipFirstRow) { _, _ in refreshPreview(resetMappings: false) }
                        }
                        GlassOptionRow(title: "Permitir HTML nos campos") {
                            Toggle("", isOn: $allowHTML)
                                .labelsHidden()
                                .tint(AppTheme.accent)
                                .accessibilityIdentifier("csv.allowHTML")
                        }
                    }

                    GlassFormSection(title: "Destino e duplicatas") {
                        GlassOptionRow(title: "decks.deck.label") {
                            Picker("", selection: $deckID) {
                                Text("Padrão da importação").tag(Optional<Int64>.none)
                                ForEach(store.decks.filter { !$0.isFiltered }) { deck in
                                    Text(deck.displayName).tag(Optional(deck.id))
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("csv.deck")
                        }
                        GlassOptionRow(title: "Tipo de nota") {
                            Picker("", selection: $notetypeID) {
                                ForEach(store.notetypes) { notetype in
                                    Text(notetype.name).tag(Optional(notetype.id))
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .onChange(of: notetypeID) { _, _ in refreshPreview(resetMappings: true) }
                        }
                        GlassOptionRow(title: "Notas duplicadas") {
                            Picker("", selection: $existingNotePolicy) {
                                ForEach(CSVImporter.ExistingNotePolicy.allCases) { policy in
                                    Text(policy.title).tag(policy)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("csv.existingNotePolicy")
                        }
                        GlassOptionRow(title: "Comparar duplicatas apenas neste baralho") {
                            Toggle("", isOn: $matchWithinDeck)
                                .labelsHidden()
                                .tint(AppTheme.accent)
                                .accessibilityIdentifier("csv.matchWithinDeck")
                        }
                    }

                    GlassFormSection(title: "Etiquetas") {
                        GlassInset {
                            VStack(alignment: .leading, spacing: 10) {
                                TextField("Adicionar a todas as notas", text: $tagsForAllNotes)
                                    .textFieldStyle(.plain)
                                    .accessibilityIdentifier("csv.tagsForAllNotes")
                                TextField("Adicionar às notas atualizadas", text: $tagsForUpdatedNotes)
                                    .textFieldStyle(.plain)
                                    .accessibilityIdentifier("csv.tagsForUpdatedNotes")
                            }
                        }
                    }

                    if let preview {
                        GlassFormSection(title: "Mapeamento de colunas") {
                            ForEach(preview.columnNames.indices, id: \.self) { index in
                                GlassOptionRow(verbatimTitle: preview.columnNames[index]) {
                                    Picker("", selection: mappingBinding(at: index)) {
                                        ForEach(availableMappings, id: \.self) { mapping in
                                            Text(mappingTitle(mapping)).tag(mapping)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                }
                            }
                        }
                        GlassFormSection(title: "Prévia") {
                            ScrollView(.horizontal) {
                                HStack(alignment: .top, spacing: 8) {
                                    ForEach(preview.columnNames.indices, id: \.self) { column in
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(preview.columnNames[column])
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(AppTheme.accent)
                                            ForEach(preview.rows.indices, id: \.self) { row in
                                                Text(preview.rows[row].indices.contains(column) ? preview.rows[row][column] : "")
                                                    .font(.caption)
                                                    .foregroundStyle(AppTheme.primaryText)
                                                    .lineLimit(3)
                                                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                                                    .padding(8)
                                                    .ankiGlass(tint: .white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                                            }
                                        }
                                        .frame(width: 160, alignment: .leading)
                                    }
                                }
                            }
                            .scrollIndicators(.visible)
                        }
                    }
                        }
                        .padding(20)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollIndicators(.visible)
                }
            }
            .background(AppBackground())
            .navigationTitle(importSummary == nil ? "Importar texto" : (importFailed ? "Falha na importação" : "Importação concluída"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if importSummary == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancelar") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Importar") { importFile() }
                            .buttonStyle(GlassChipButtonStyle(tint: AppTheme.accent.opacity(0.32)))
                            .disabled(preview == nil || columnMappings.isEmpty)
                    }
                }
            }
            .onAppear {
                let fileOptions = CSVImporter(store: store).preview(text, notetypeID: notetypeID)
                if let fileNotetypeID = fileOptions.directiveNotetypeID { notetypeID = fileNotetypeID }
                if fileOptions.directiveDeck != nil { deckID = fileOptions.directiveDeckID }
                if let policy = fileOptions.existingNotePolicy { existingNotePolicy = policy }
                if let matchWithinDeck = fileOptions.matchWithinDeck { self.matchWithinDeck = matchWithinDeck }
                refreshPreview(resetMappings: true)
            }
        }
    }

    private var availableMappings: [CSVImporter.ColumnMapping] {
        let fields = store.notetype(id: notetypeID ?? 0)?.flds.indices.map(CSVImporter.ColumnMapping.field) ?? []
        return fields + [.tags, .deck, .notetype, .guid, .ignore]
    }

    private func mappingBinding(at index: Int) -> Binding<CSVImporter.ColumnMapping> {
        Binding(
            get: { columnMappings.indices.contains(index) ? columnMappings[index] : .ignore },
            set: { value in
                guard columnMappings.indices.contains(index) else { return }
                columnMappings[index] = value
            }
        )
    }

    private func mappingTitle(_ mapping: CSVImporter.ColumnMapping) -> String {
        if case .field(let index) = mapping,
           let model = store.notetype(id: notetypeID ?? 0),
           model.flds.indices.contains(index) {
            return model.flds[index].name
        }
        return mapping.title
    }

    private func refreshPreview(resetMappings: Bool) {
        let importer = CSVImporter(store: store)
        let current = importer.preview(
            text,
            delimiter: selectedDelimiter,
            notetypeID: notetypeID,
            skipFirstRow: skipFirstRow
        )
        if resetMappings || columnMappings.count != current.columnNames.count {
            skipFirstRow = current.suggestsHeader
            let adjusted = importer.preview(
                text,
                delimiter: selectedDelimiter,
                notetypeID: notetypeID,
                skipFirstRow: skipFirstRow
            )
            preview = adjusted
            if let model = store.notetype(id: notetypeID ?? 0) {
                columnMappings = importer.suggestedMappings(for: adjusted, notetype: model)
            } else {
                columnMappings = adjusted.columnNames.indices.map { _ in .ignore }
            }
        } else {
            preview = current
        }
    }

    private var selectedDelimiter: Character? {
        switch separatorChoice {
        case "tab": "\t"
        case "comma": ","
        case "semicolon": ";"
        case "space": " "
        case "pipe": "|"
        case "colon": ":"
        default: nil
        }
    }

    private func importFile() {
        do {
            let result = try CSVImporter(store: store).importText(
                text,
                deckID: deckID,
                notetypeID: notetypeID,
                delimiter: selectedDelimiter,
                allowHTML: allowHTML,
                existingNotePolicy: existingNotePolicy,
                matchWithinDeck: matchWithinDeck,
                tagsForAllNotes: tagsForAllNotes,
                tagsForUpdatedNotes: tagsForUpdatedNotes,
                columnMappings: columnMappings,
                skipFirstRow: skipFirstRow,
                offerTutorial: false
            )
            offerTutorialAfterDismissal = true
            var conf = store.conf
            conf["csvDeckID"] = deckID
            conf["csvNotetypeID"] = notetypeID
            conf["csvSeparator"] = separatorChoice
            conf["csvAllowHTML"] = allowHTML
            conf["csvExistingNotePolicy"] = existingNotePolicy.rawValue
            conf["csvMatchWithinDeck"] = matchWithinDeck
            conf["csvTagsForAllNotes"] = tagsForAllNotes
            conf["csvTagsForUpdatedNotes"] = tagsForUpdatedNotes
            do {
                try store.saveConf(conf)
                importSummary = result.summary
            } catch {
                importFailed = true
                importSummary = "\(result.summary) As opções de importação não foram salvas: \(error.localizedDescription)"
            }
        } catch {
            importFailed = true
            importSummary = error.localizedDescription
        }
    }
}
