import SwiftUI

/// Anki Browser / Painel: sidebar filters + card list + note editor.
struct BrowserView: View {
    @EnvironmentObject private var store: CollectionStore

    @State private var selectedFilter: BrowserFilter = .all
    @State private var query = ""
    @State private var rows: [CollectionStore.BrowserRow] = []
    @State private var selectedCardID: Int64?
    @State private var selectedIDs = Set<Int64>()
    @State private var editFields: [String] = []
    @State private var editTags = ""
    @State private var showAnswerPreview = false
    @State private var showMove = false
    @State private var showChangeType = false
    @State private var showTagEditor = false
    @State private var showRemoveTag = false
    @State private var showReplaceTag = false
    @State private var tagInput = ""
    @State private var tagFrom = ""
    @State private var tagTo = ""
    @State private var dueDays = 1
    @State private var showSetDue = false
    @State private var showFindReplace = false
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var exportURL: URL?
    @State private var showSearchHelp = false
    @State private var useRichEditor = false
    @State private var sortKey: BrowserSort = .sortField
    @State private var notesMode = false
    @State private var previewRow: CollectionStore.BrowserRow?
    @State private var showSaveSearch = false
    @State private var saveSearchName = ""
    @State private var showCardInfo = false
    @State private var cardInfoText = ""
    @State private var showReposition = false
    @State private var repositionStart = 0
    @State private var repositionStep = 1
    @State private var repositionRandom = false
    @State private var repositionShift = false

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let useSplit = geo.size.width > 700
                if useSplit {
                    HStack(spacing: 0) {
                        filterSidebar
                            .frame(width: min(240, geo.size.width * 0.28))
                        Divider()
                        cardList
                            .frame(minWidth: 220)
                        Divider()
                        editorPane
                            .frame(minWidth: 260)
                    }
                } else {
                    VStack(spacing: 0) {
                        filterChips
                        cardList
                        if selectedCardID != nil {
                            Divider()
                            editorPane
                                .frame(maxHeight: geo.size.height * 0.45)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                browserActionBar
            }
            .background(AppBackground())
            .navigationTitle("Painel")
            .sheet(isPresented: $showMove) { moveSheet }
            .sheet(isPresented: $showReposition) { repositionSheet }
            .sheet(isPresented: $showCardInfo) {
                CardInfoView(text: cardInfoText)
            }
            .sheet(item: $previewRow) { row in
                CardPreviewSheet(row: row)
                    .environmentObject(store)
                    #if os(macOS)
                    .frame(minWidth: 480, minHeight: 420)
                    #endif
            }
            .confirmationDialog("Mudar tipo de nota", isPresented: $showChangeType) {
                ForEach(store.notetypes) { nt in
                    Button(nt.name) {
                        let nids = Array(Set(rows.filter { targets().contains($0.id) }.map(\.note.id)))
                        try? store.changeNoteType(noteIDs: nids, to: nt.id)
                        runSearch()
                    }
                }
            }
            .alert("Adicionar tag", isPresented: $showTagEditor) {
                TextField("tag", text: $tagInput)
                Button("OK") {
                    let nids = Array(Set(rows.filter { targets().contains($0.id) }.map(\.note.id)))
                    try? store.addTag(to: nids, tag: tagInput)
                    tagInput = ""
                    runSearch()
                }
                Button("Cancelar", role: .cancel) {}
            }
            .alert("Remover tag", isPresented: $showRemoveTag) {
                TextField("tag", text: $tagInput)
                Button("OK") {
                    let nids = Array(Set(rows.filter { targets().contains($0.id) }.map(\.note.id)))
                    try? store.removeTag(from: nids, tag: tagInput)
                    tagInput = ""
                    runSearch()
                }
                Button("Cancelar", role: .cancel) {}
            }
            .alert("Substituir tag", isPresented: $showReplaceTag) {
                TextField("De", text: $tagFrom)
                TextField("Para", text: $tagTo)
                Button("OK") {
                    let nids = Array(Set(rows.filter { targets().contains($0.id) }.map(\.note.id)))
                    try? store.replaceTag(in: nids, from: tagFrom, to: tagTo)
                    tagFrom = ""; tagTo = ""
                    runSearch()
                }
                Button("Cancelar", role: .cancel) {}
            }
            .alert("Definir due (dias)", isPresented: $showSetDue) {
                TextField("Dias", value: $dueDays, format: .number)
                Button("OK") {
                    try? store.setDueDate(cardIDs: targets(), daysFromToday: dueDays)
                    runSearch()
                }
                Button("Cancelar", role: .cancel) {}
            }
            .alert("Salvar busca atual", isPresented: $showSaveSearch) {
                TextField("Nome da busca", text: $saveSearchName)
                Button("Salvar") {
                    let q = effectiveSearchQuery
                    do {
                        try store.addSavedSearch(name: saveSearchName, query: q)
                        saveSearchName = ""
                    } catch {
                        store.lastError = error.localizedDescription
                    }
                }
                Button("Cancelar", role: .cancel) { saveSearchName = "" }
            } message: {
                Text("A busca “\(effectiveSearchQuery)” será salva na coleção.")
            }
            .alert("Localizar e substituir", isPresented: $showFindReplace) {
                TextField("Localizar", text: $findText)
                TextField("Substituir por", text: $replaceText)
                Button("Substituir") {
                    let nids = Array(Set(rows.filter { targets().contains($0.id) }.map(\.note.id)))
                    let n = (try? store.findReplaceFields(noteIDs: nids, find: findText, replace: replaceText)) ?? 0
                    store.lastError = "Substituído em \(n) nota(s)."
                    runSearch()
                }
                Button("Cancelar", role: .cancel) {}
            }
            .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
                if let exportURL { ShareSheet(items: [exportURL]) }
            }
            .sheet(isPresented: $showSearchHelp) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Group {
                                Text("deck:Nome · deck:current").font(.headline)
                                Text("is:new · is:learn · is:review · is:due · is:old · is:suspended · is:buried · is:marked")
                                Text("flag:0…7 · tag:nome · tag:* · tag:marked · tag:leech · deck:filtered")
                                Text("note:Tipo · card:Nome · nid:123 · cid:123 · field:texto · field:Front:valor · Front:valor")
                                Text("prop:due<=7 · prop:ivl>=30 · prop:reps>=5 · prop:lapses>=2 · prop:ease>=2.5 · prop:pos<=10")
                                Text("flag:red · added:1 · introduced:1 · rated:1 · rated:1:1 · dupe: · OR · -is:suspended")
                            }
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding()
                    }
                    .background(AppBackground())
                    .navigationTitle("Busca do Painel")
                    .safeAreaInset(edge: .bottom) {
                        Button("Fechar") { showSearchHelp = false }
                            .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.18, expands: true))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                    }
                }
            }
            .task {
                sortKey = BrowserSort.fromCollectionSortType(store.conf["sortType"] as? Int ?? 0)
                try? store.rebuildTagRegistry()
                runSearch()
            }
            .onChange(of: query) { _, _ in runSearch() }
            .onChange(of: sortKey) { _, key in
                var conf = store.conf
                conf["sortType"] = key.collectionSortType
                try? store.saveConf(conf)
            }
            .onChange(of: selectedFilter) { _, _ in
                query = selectedFilter.searchQuery
                runSearch()
            }
            .onChange(of: selectedCardID) { _, id in
                loadEditor(for: id)
            }
        }
    }

    // MARK: - Sidebar

    private var filterSidebar: some View {
        List {
            Section("Buscas salvas") {
                if store.savedSearches.isEmpty {
                    Text("Nenhuma busca salva")
                        .foregroundStyle(AppTheme.secondaryText)
                } else {
                    ForEach(store.savedSearches, id: \.name) { item in
                        HStack(spacing: 0) {
                            Button {
                                applySavedSearch(item.query)
                            } label: {
                                HStack {
                                    Text(item.name)
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button {
                                try? store.removeSavedSearch(named: item.name)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(AppTheme.secondaryText)
                            }
                            .buttonStyle(.plain)
                            .help("Remover busca salva")
                        }
                        .glassListRow(selected: false)
                    }
                }
                Button("Salvar busca atual…") {
                    saveSearchName = suggestedSaveSearchName
                    showSaveSearch = true
                }
                .foregroundStyle(AppTheme.accent)
            }
            Section("Hoje") {
                filterRow(.dueToday)
                filterRow(.addedToday)
                filterRow(.studiedToday)
            }
            Section("Bandeiras") {
                ForEach(1...7, id: \.self) { flag in
                    filterRow(.flag(flag))
                }
            }
            Section("Estado") {
                filterRow(.isNew)
                filterRow(.isLearn)
                filterRow(.isReview)
                filterRow(.isSuspended)
                filterRow(.isBuried)
                filterRow(.isMarked)
                filterRow(.isLeech)
                filterRow(.noFlag)
            }
            Section("Baralhos") {
                filterRow(.all)
                ForEach(store.decks) { deck in
                    filterRow(.deck(deck.name))
                }
            }
            Section("Tipos de nota") {
                ForEach(store.notetypes) { nt in
                    filterRow(.noteType(nt.name))
                }
            }
            Section("Tags") {
                let tagNames = store.tags.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                if tagNames.isEmpty {
                    Text("Nenhuma tag")
                        .foregroundStyle(AppTheme.secondaryText)
                } else {
                    ForEach(tagNames, id: \.self) { tag in
                        filterRow(.tag(tag))
                    }
                }
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #endif
        .scrollContentBackground(.hidden)
    }

    private func filterRow(_ filter: BrowserFilter) -> some View {
        Button {
            selectedFilter = filter
        } label: {
            HStack {
                Text(filter.title)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer()
                if selectedFilter == filter {
                    Image(systemName: "checkmark")
                        .foregroundStyle(AppTheme.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassListRow(selected: selectedFilter == filter)
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(BrowserFilter.mobileDefaults, id: \.self) { filter in
                    Button(filter.title) {
                        selectedFilter = filter
                    }
                    .buttonStyle(GlassButtonStyle(
                        tint: selectedFilter == filter ? AppTheme.accent : .white,
                        prominent: false,
                        tintStrength: selectedFilter == filter ? 0.4 : 0.14
                    ))
                }
            }
            .padding()
        }
    }

    // MARK: - List

    private var cardList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppTheme.secondaryText)
                TextField("Busca (deck:, tag:, is:new…)", text: $query)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .foregroundStyle(AppTheme.primaryText)
            }
            .padding(12)
            .glassEffect(.regular.tint(.white.opacity(0.08)), in: .capsule)
            .padding(.horizontal)
            .padding(.vertical, 8)

            HStack {
                Picker("Modo", selection: $notesMode) {
                    Text("Cartões").tag(false)
                    Text("Notas").tag(true)
                }
                .pickerStyle(.segmented)
                Picker("Ordenar", selection: $sortKey) {
                    ForEach(BrowserSort.allCases, id: \.self) { s in
                        Text(s.title).tag(s)
                    }
                }
                .pickerStyle(.menu)
            }
            .padding(.horizontal)

            if displayRows.isEmpty {
                EmptyStateView(
                    title: "Nenhum cartão",
                    subtitle: "Ajuste o filtro ou a busca.",
                    systemImage: "magnifyingglass"
                )
            } else {
                List {
                    ForEach(displayRows) { row in
                        BrowserRowView(row: row, isSelected: selectedCardID == row.id || selectedIDs.contains(row.id))
                            .environmentObject(store)
                            .glassListRow(selected: selectedCardID == row.id || selectedIDs.contains(row.id))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedCardID = row.id
                                if selectedIDs.contains(row.id) {
                                    selectedIDs.remove(row.id)
                                } else {
                                    selectedIDs.insert(row.id)
                                }
                            }
                            .contextMenu {
                                Button("Pré-visualizar", systemImage: "eye") { previewRow = row }
                                Button("Editar") { selectedCardID = row.id }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var sortedRows: [CollectionStore.BrowserRow] {
        switch sortKey {
        case .sortField: return rows.sorted { $0.note.sfld.localizedCaseInsensitiveCompare($1.note.sfld) == .orderedAscending }
        case .due: return rows.sorted { $0.card.due < $1.card.due }
        case .created: return rows.sorted { $0.note.id > $1.note.id }
        case .modified: return rows.sorted { $0.note.mod > $1.note.mod }
        case .interval: return rows.sorted { $0.card.ivl > $1.card.ivl }
        case .ease: return rows.sorted { $0.card.factor > $1.card.factor }
        case .reps: return rows.sorted { $0.card.reps > $1.card.reps }
        case .lapses: return rows.sorted { $0.card.lapses > $1.card.lapses }
        case .deck: return rows.sorted { $0.deckName.localizedCaseInsensitiveCompare($1.deckName) == .orderedAscending }
        }
    }

    /// Notes mode: one row per note (first card).
    private var displayRows: [CollectionStore.BrowserRow] {
        guard notesMode else { return sortedRows }
        var seen = Set<Int64>()
        return sortedRows.filter { seen.insert($0.note.id).inserted }
    }

    // MARK: - Editor

    private var editorPane: some View {
        Group {
            if let id = selectedCardID, let row = rows.first(where: { $0.id == id }),
               let nt = store.notetype(id: row.note.mid) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(nt.name)
                                .font(.headline)
                            Spacer()
                            Button(showAnswerPreview ? "Frente" : "Verso") {
                                showAnswerPreview.toggle()
                            }
                            .buttonStyle(GlassChipButtonStyle())
                        }

                        let card = row.card
                        let note = editedNote(from: row.note)
                        let result = CardHTMLRenderer.renderCard(
                            note: note,
                            card: card,
                            notetype: nt,
                            side: showAnswerPreview ? .answer : .question,
                            mediaBase: store.mediaRoot
                        )
                        CardWebView(html: result.html, baseURL: store.mediaRoot)
                            .frame(height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 16))

                        ForEach(Array(nt.flds.enumerated()), id: \.offset) { idx, field in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(field.name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.mist)
                                FieldFormatBar(text: fieldBinding(idx), isClozeType: nt.isCloze)
                                if useRichEditor {
                                    RichFieldEditor(html: fieldBinding(idx), minHeight: 90)
                                } else {
                                    TextField(field.name, text: fieldBinding(idx), axis: .vertical)
                                        .lineLimit(2...8)
                                        .padding(8)
                                        .glassEffect(.regular, in: .rect(cornerRadius: 12))
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Etiquetas")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.mist)
                            TextField("tags", text: $editTags)
                                .padding(8)
                                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                        }

                        VStack(spacing: 10) {
                            Button("Salvar") { saveEditor(row: row) }
                                .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, expands: true))
                            if row.card.queue == -2 || row.card.queue == -3 {
                                Button("Desocultar") {
                                    try? store.unburyCards([row.card.id])
                                    runSearch()
                                }
                                .buttonStyle(GlassButtonStyle(tint: AppTheme.good, expands: true))
                            }
                            if row.card.queue == -1 {
                                Button("Dessuspender") {
                                    try? store.unsuspendCards([row.card.id])
                                    runSearch()
                                }
                                .buttonStyle(GlassButtonStyle(tint: AppTheme.good, expands: true))
                            }
                        }
                    }
                    .padding()
                }
            } else {
                EmptyStateView(
                    title: "Selecione um cartão",
                    subtitle: "O editor aparece aqui, como no Painel do Anki.",
                    systemImage: "sidebar.squares.right"
                )
            }
        }
    }

    private var browserActionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
            Menu {
                ForEach(store.savedSearches, id: \.name) { item in
                    Button(item.name) { applySavedSearch(item.query) }
                }
                if !store.savedSearches.isEmpty { Divider() }
                Button("Salvar busca atual…", systemImage: "bookmark") {
                    saveSearchName = suggestedSaveSearchName
                    showSaveSearch = true
                }
            } label: {
                Image(systemName: "bookmark")
            }
            .panelGlassMenu()
            Menu {
                Button("Pré-visualizar cartão", systemImage: "eye") {
                    if let id = selectedCardID, let row = rows.first(where: { $0.id == id }) {
                        previewRow = row
                    }
                }
                Button("Informações", systemImage: "info.circle") {
                    if let id = selectedCardID, let row = rows.first(where: { $0.id == id }) {
                        cardInfoText = store.cardInfoText(row.card, note: row.note)
                        showCardInfo = true
                    }
                }
                Button("Selecionar todos") {
                    selectedIDs = Set(displayRows.map(\.id))
                }
                Button("Inverter seleção") {
                    let visible = Set(displayRows.map(\.id))
                    selectedIDs = visible.subtracting(selectedIDs)
                }
                Button("Procurar duplicatas") {
                    query = "dupe:"
                    selectedFilter = .all
                    runSearch()
                }
                Button("Duplicar nota(s)", systemImage: "plus.square.on.square") {
                    let nids = Array(Set(rows.filter { targets().contains($0.id) }.map(\.note.id)))
                    try? store.duplicateNotes(nids)
                    runSearch()
                }
                Button("Limpar seleção") { selectedIDs.removeAll() }
                Divider()
                Menu("Bandeira", systemImage: "flag") {
                    Button("Sem bandeira") { setBulkFlag(0) }
                    ForEach(1...7, id: \.self) { n in
                        Button(AnkiFlagColor.name(n)) { setBulkFlag(n) }
                    }
                    Divider()
                    Button("Ciclar") { bulkFlag() }
                }
                Button("Marcar / desmarcar", systemImage: "star") { bulkMark() }
                Button("Suspender", systemImage: "pause.circle") { bulkQueue(-1) }
                Button("Suspender nota", systemImage: "pause.circle.fill") { suspendNotes() }
                Button("Dessuspender", systemImage: "play.circle") { bulkUnsuspend() }
                Button("Ocultar", systemImage: "eye.slash") { bulkQueue(-3) }
                Button("Desocultar", systemImage: "eye") { bulkUnbury() }
                Button("Desocultar todos", systemImage: "eye.circle") {
                    try? store.unburyAll(); runSearch()
                }
                Divider()
                Button("Mover…", systemImage: "folder") { showMove = true }
                Button("Mudar tipo de nota…", systemImage: "doc.badge.gearshape") { showChangeType = true }
                Button("Adicionar tag…", systemImage: "tag") { showTagEditor = true }
                Button("Remover tag…", systemImage: "tag.slash") { showRemoveTag = true }
                Button("Substituir tag…", systemImage: "arrow.left.arrow.right") { showReplaceTag = true }
                Button("Localizar e substituir…", systemImage: "text.magnifyingglass") { showFindReplace = true }
                Button("Definir due…", systemImage: "calendar") { showSetDue = true }
                Button("Repor (esquecer)", systemImage: "arrow.counterclockwise") { bulkReset() }
                Button("Exportar seleção (.apkg)", systemImage: "square.and.arrow.up") { exportSelection() }
                Button("Exportar seleção (TSV)", systemImage: "tablecells") { exportSelectionTSV() }
                Button("Criar filtrado desta busca", systemImage: "line.3.horizontal.decrease.circle") {
                    createFilteredFromSearch()
                }
                Button("Reposicionar novos…", systemImage: "arrow.up.arrow.down") {
                    showReposition = true
                }
                Divider()
                Button("Apagar", systemImage: "trash", role: .destructive) { bulkDelete() }
            } label: {
                Text("Ações ▾")
            }
            .panelGlassMenu()
            Button("Desocultar") { bulkUnbury() }
                .buttonStyle(GlassChipButtonStyle())
            Button("Dessuspender") { bulkUnsuspend() }
                .buttonStyle(GlassChipButtonStyle())
            Button(useRichEditor ? "Texto" : "HTML") { useRichEditor.toggle() }
                .buttonStyle(GlassChipButtonStyle())
            Button {
                showSearchHelp = true
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(GlassChipButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var repositionSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        GlassOptionRow(title: "Posição inicial") {
                            Stepper("\(repositionStart)", value: $repositionStart, in: 0...999_999)
                        }
                        GlassOptionRow(title: "Passo") {
                            Stepper("\(repositionStep)", value: $repositionStep, in: 1...999)
                        }
                        GlassOptionRow(title: "Ordem aleatória") {
                            Toggle("", isOn: $repositionRandom).labelsHidden().tint(AppTheme.accent)
                        }
                        GlassOptionRow(title: "Deslocar os existentes") {
                            Toggle("", isOn: $repositionShift).labelsHidden().tint(AppTheme.accent)
                        }
                    }
                    .padding(20)
                }
                HStack(spacing: 12) {
                    Button("Cancelar") { showReposition = false }
                        .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.18, expands: true))
                    Button("Reposicionar") {
                        try? store.repositionNewCards(
                            targets(),
                            startingFrom: repositionStart,
                            step: repositionStep,
                            random: repositionRandom,
                            shift: repositionShift
                        )
                        showReposition = false
                        runSearch()
                    }
                    .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.42, expands: true))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .background(AppBackground())
            .navigationTitle("Reposicionar")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }

    private var moveSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(store.decks) { deck in
                            Button {
                                try? store.moveCards(Array(selectedIDs), toDeck: deck.id)
                                selectedIDs.removeAll()
                                showMove = false
                                runSearch()
                            } label: {
                                HStack {
                                    Text(deck.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Image(systemName: "folder")
                                        .foregroundStyle(.white.opacity(0.55))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .glassEffect(.regular.tint(.white.opacity(0.08)), in: .rect(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                }
                Button("Cancelar") { showMove = false }
                    .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.18, expands: true))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
            }
            .background(AppBackground())
            .navigationTitle("Mover para baralho")
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }

    // MARK: - Actions

    private var effectiveSearchQuery: String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { return q }
        return selectedFilter.searchQuery
    }

    private var suggestedSaveSearchName: String {
        let q = effectiveSearchQuery
        if q.isEmpty { return "Busca" }
        if q.count <= 28 { return q }
        return String(q.prefix(28)) + "…"
    }

    private func applySavedSearch(_ savedQuery: String) {
        query = savedQuery
        selectedFilter = .all
        runSearch()
    }

    private func runSearch() {
        do {
            rows = try store.search(query: query)
            if let id = selectedCardID, !rows.contains(where: { $0.id == id }) {
                #if os(macOS)
                selectedCardID = rows.first?.id
                #else
                selectedCardID = nil
                #endif
            } else if selectedCardID == nil {
                #if os(macOS)
                selectedCardID = rows.first?.id
                #endif
            }
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func loadEditor(for id: Int64?) {
        guard let id, let row = rows.first(where: { $0.id == id }) else { return }
        editFields = row.note.fields
        editTags = row.note.tagList.joined(separator: " ")
        showAnswerPreview = false
    }

    private func fieldBinding(_ idx: Int) -> Binding<String> {
        Binding(
            get: { idx < editFields.count ? editFields[idx] : "" },
            set: { v in
                while editFields.count <= idx { editFields.append("") }
                editFields[idx] = v
            }
        )
    }

    private func editedNote(from note: AnkiNote) -> AnkiNote {
        var n = note
        n.flds = editFields.joined(separator: "\u{1f}")
        n.sfld = editFields.first ?? ""
        n.tags = editTags
        return n
    }

    private func saveEditor(row: CollectionStore.BrowserRow) {
        do {
            try store.updateNote(row.note, fields: editFields, tags: editTags)
            runSearch()
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func targets() -> [Int64] {
        if !selectedIDs.isEmpty { return Array(selectedIDs) }
        if let id = selectedCardID { return [id] }
        return []
    }

    private func bulkFlag() {
        let ids = targets()
        guard let first = ids.first, let card = try? store.fetchCard(id: first) else { return }
        let next = ((card.flags & 7) + 1) % 8
        setBulkFlag(next)
    }

    private func suspendNotes() {
        let nids = Array(Set(rows.filter { targets().contains($0.id) }.map(\.note.id)))
        let cards = (try? store.cardIDs(ofNotes: nids)) ?? []
        try? store.setCardsQueue(cards, queue: -1)
        runSearch()
    }

    private func setBulkFlag(_ flag: Int) {
        try? store.setCardsFlag(targets(), flag: flag)
        runSearch()
    }

    private func bulkQueue(_ q: Int) {
        try? store.setCardsQueue(targets(), queue: q)
        runSearch()
    }

    private func bulkDelete() {
        let nids = rows.filter { targets().contains($0.id) }.map(\.note.id)
        try? store.deleteNotes(ids: Array(Set(nids)))
        selectedIDs.removeAll()
        selectedCardID = nil
        runSearch()
    }

    private func bulkUnbury() {
        try? store.unburyCards(targets())
        runSearch()
    }

    private func bulkUnsuspend() {
        try? store.unsuspendCards(targets())
        runSearch()
    }

    private func bulkReset() {
        try? store.resetCards(targets())
        runSearch()
    }

    private func bulkMark() {
        let nids = Array(Set(rows.filter { targets().contains($0.id) }.map(\.note.id)))
        for nid in nids {
            if let note = try? store.fetchNote(id: nid) {
                try? store.toggleMark(note: note)
            }
        }
        runSearch()
    }

    private func exportSelection() {
        let ids = targets()
        guard !ids.isEmpty else {
            store.lastError = "Selecione cartões para exportar."
            return
        }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("AnkiOS-selection.apkg")
            try ApkgExporter(store: store).export(cardIDs: ids, to: url)
            exportURL = url
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func exportSelectionTSV() {
        let nids = Array(Set(rows.filter { targets().contains($0.id) }.map(\.note.id)))
        guard !nids.isEmpty else {
            store.lastError = "Selecione cartões para exportar."
            return
        }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("AnkiOS-selection.tsv")
            try CSVExporter(store: store).exportNotes(noteIDs: nids, to: url)
            exportURL = url
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func createFilteredFromSearch() {
        let search = query.trimmingCharacters(in: .whitespaces)
        guard !search.isEmpty else {
            store.lastError = "Digite uma busca antes de criar o filtrado."
            return
        }
        do {
            let id = store.timestampID()
            let name = "Filtered::Painel \(id % 10000)"
            var decks = store.decks
            let filtered = AnkiDeck(
                id: id,
                name: name,
                mod: Int64(Date().timeIntervalSince1970),
                usn: -1,
                collapsed: false,
                browserCollapsed: false,
                desc: search,
                dyn: 1,
                conf: 1,
                extendNew: 0,
                extendRev: 0,
                newToday: [0, 0],
                revToday: [0, 0],
                lrnToday: [0, 0],
                timeToday: [0, 0],
                searchTerms: search,
                termLimit: min(rows.count, 100),
                resched: true,
                previewDelay: 0
            )
            decks.append(filtered)
            try store.saveDecks(decks)
            try FilteredDeckSupport.rebuild(filtered, store: store)
            store.lastError = "Baralho filtrado criado: \(name)"
        } catch {
            store.lastError = error.localizedDescription
        }
    }
}

// MARK: - Sort / Filter

enum BrowserSort: CaseIterable, Hashable {
    case sortField, due, created, modified, interval, deck, ease, reps, lapses

    /// Maps collection `sortType` from Preferences (Anki queue order labels).
    static func fromCollectionSortType(_ sortType: Int) -> BrowserSort {
        switch sortType {
        case 0: .sortField
        case 1: .due
        case 2: .created
        case 3: .modified
        case 4: .interval
        case 5: .deck
        case 6: .ease
        case 7: .reps
        case 8: .lapses
        default: .sortField
        }
    }

    /// Persist back into conf["sortType"].
    var collectionSortType: Int {
        switch self {
        case .sortField: 0
        case .due: 1
        case .created: 2
        case .modified: 3
        case .interval: 4
        case .deck: 5
        case .ease: 6
        case .reps: 7
        case .lapses: 8
        }
    }

    var title: String {
        switch self {
        case .sortField: "Campo de ordenação"
        case .due: "Vencimento"
        case .created: "Criado"
        case .modified: "Modificado"
        case .interval: "Intervalo"
        case .deck: "Baralho"
        case .ease: "Facilidade"
        case .reps: "Revisões"
        case .lapses: "Falhas"
        }
    }
}

enum AnkiFlagColor {
    static func name(_ flag: Int) -> String {
        switch flag {
        case 1: "Vermelho"
        case 2: "Laranja"
        case 3: "Verde"
        case 4: "Azul"
        case 5: "Rosa"
        case 6: "Turquesa"
        case 7: "Roxo"
        default: "Bandeira \(flag)"
        }
    }
}

enum BrowserFilter: Hashable {
    case all
    case dueToday
    case addedToday
    case studiedToday
    case flag(Int)
    case isNew, isLearn, isReview, isSuspended, isBuried, isMarked, isLeech, noFlag
    case deck(String)
    case noteType(String)
    case tag(String)

    var title: String {
        switch self {
        case .all: "Todos"
        case .dueToday: "A revisar agora"
        case .addedToday: "Adicionados hoje"
        case .studiedToday: "Estudados hoje"
        case .flag(let n): AnkiFlagColor.name(n)
        case .isNew: "Novo"
        case .isLearn: "Aprendizagem"
        case .isReview: "Revisão"
        case .isSuspended: "Suspenso"
        case .isBuried: "Oculto"
        case .isMarked: "Marcado"
        case .isLeech: "Leech"
        case .noFlag: "Sem bandeira"
        case .deck(let n): n.components(separatedBy: "::").last ?? n
        case .noteType(let n): n
        case .tag(let n): n
        }
    }

    var searchQuery: String {
        switch self {
        case .all: ""
        case .dueToday: "is:due"
        case .addedToday: "added:1"
        case .studiedToday: "rated:1"
        case .flag(let n): "flag:\(n)"
        case .isNew: "is:new"
        case .isLearn: "is:learn"
        case .isReview: "is:review"
        case .isSuspended: "is:suspended"
        case .isBuried: "is:buried"
        case .isMarked: "tag:marked"
        case .isLeech: "tag:leech"
        case .noFlag: "flag:0"
        case .deck(let n): "deck:\"\(n)\""
        case .noteType(let n): "note:\"\(n)\""
        case .tag(let n): "tag:\(n)"
        }
    }

    static var mobileDefaults: [BrowserFilter] {
        [.all, .dueToday, .isNew, .isLearn, .isReview, .isSuspended, .isBuried, .isMarked]
    }
}

struct BrowserRowView: View {
    let row: CollectionStore.BrowserRow
    var isSelected: Bool = false
    @EnvironmentObject private var store: CollectionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(browserQuestionText)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
            HStack {
                Text(cardTypeLabel)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.mist)
                Text("·")
                Text(row.deckName.components(separatedBy: "::").last ?? row.deckName)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                Text("·")
                Text("due \(row.card.due)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryText)
                Spacer()
                queueLabel
            }
            if !row.note.tagList.isEmpty {
                Text(row.note.tagList.joined(separator: " "))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.mist.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .opacity(isSelected ? 1 : 0.95)
    }

    private var cardTypeLabel: String {
        if let nt = store.notetype(id: row.note.mid),
           let tmpl = nt.tmpls.first(where: { $0.ord == row.card.ord }) ?? nt.tmpls.first {
            return tmpl.name
        }
        return "Card \(row.card.ord + 1)"
    }

    /// Prefer Anki browser question template (`bqfmt`) when present.
    private var browserQuestionText: String {
        guard let nt = store.notetype(id: row.note.mid),
              let tmpl = nt.tmpls.first(where: { $0.ord == row.card.ord }) ?? nt.tmpls.first,
              !tmpl.bqfmt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return row.note.sfld
        }
        let fields = TemplateEngine.fieldMap(note: row.note, notetype: nt, deckName: row.deckName)
        let html = TemplateEngine.render(
            template: tmpl.bqfmt,
            fields: fields,
            clozeOrd: nt.isCloze ? row.card.ord : nil,
            questionSide: true,
            omitTypeInput: true
        )
        let plain = html
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.isEmpty ? row.note.sfld : plain
    }

    @ViewBuilder
    private var queueLabel: some View {
        HStack(spacing: 6) {
            if row.card.flags > 0 {
                Image(systemName: "flag.fill")
                    .foregroundStyle(flagColor(row.card.flags))
                    .font(.caption2)
            }
            switch row.card.queue {
            case 0: Text("novo").foregroundStyle(AppTheme.easy)
            case 1, 3: Text("aprender").foregroundStyle(AppTheme.danger)
            case 2: Text("revisar").foregroundStyle(AppTheme.good)
            case -1: Text("suspenso").foregroundStyle(AppTheme.danger)
            default: Text("oculto").foregroundStyle(AppTheme.secondaryText)
            }
        }
    }

    private func flagColor(_ flag: Int) -> Color {
        switch flag {
        case 1: .red
        case 2: .orange
        case 3: .green
        case 4: .blue
        case 5: .pink
        case 6: .cyan
        case 7: .purple
        default: .secondary
        }
    }
}

struct CardPreviewSheet: View {
    let row: CollectionStore.BrowserRow
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.dismiss) private var dismiss
    @State private var showAnswer = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                if let nt = store.notetype(id: row.note.mid) {
                    let result = CardHTMLRenderer.renderCard(
                        note: row.note,
                        card: row.card,
                        notetype: nt,
                        side: showAnswer ? .answer : .question,
                        mediaBase: store.mediaRoot
                    )
                    CardWebView(
                        html: result.html,
                        baseURL: store.mediaRoot,
                        onSoundTap: { store.mediaStore.play($0) }
                    )
                    .padding()
                }
            }
            .navigationTitle("Pré-visualização")
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button("Fechar") { dismiss() }
                        .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.18, expands: true))
                    Button(showAnswer ? "Pergunta" : "Resposta") { showAnswer.toggle() }
                        .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.42, expands: true))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
        }
    }
}
