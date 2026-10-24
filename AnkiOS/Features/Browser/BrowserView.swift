import SwiftUI

/// Anki Browser / Painel: sidebar filters + card list + note editor.
struct BrowserView: View {
    private enum BrowserAlert: Equatable {
        case addTag, removeTag, replaceTag, setDue, saveSearch, renameSavedSearch
    }

    @EnvironmentObject private var store: CollectionStore
    @Environment(\.colorScheme) private var colorScheme
    let onCreateCopy: (AddNoteCopyRequest) -> Void
    let onAddNote: () -> Void
    let onManageNoteTypes: () -> Void
    let onClose: (() -> Void)?
    let isActive: Bool
    @Binding private var pendingSearchQuery: String?

    @State private var selectedFilter: BrowserFilter = .all
    @State private var query = ""
    @State private var committedSearchQuery = "deck:current"
    @State private var searchHistory: [String] = []
    @State private var loadedInitialQuery = false
    @State private var browserStatusMessage: String?
    @State private var rows: [CollectionStore.BrowserRow] = []
    @State private var hasMoreRows = false
    @State private var selectedCardID: Int64?
    @State private var selectedIDs = Set<Int64>()
    @State private var editFields: [String] = []
    @State private var editTags = ""
    @State private var showAnswerPreview = false
    @State private var showMove = false
    @State private var showChangeType = false
    @State private var activeAlert: BrowserAlert?
    @State private var tagInput = ""
    @State private var tagFrom = ""
    @State private var tagTo = ""
    @State private var dueDateInput = "1"
    @State private var showFindReplace = false
    @State private var exportURL: URL?
    @State private var showSearchHelp = false
    @State private var useRichEditor = true
    @State private var sortKey: BrowserSort = .sortField
    @State private var sortDescending = false
    @State private var notesMode = false
    @State private var restoredSortKey: BrowserSort?
    @State private var restoredSortDirection: Bool?
    @State private var previewRow: CollectionStore.BrowserRow?
    @State private var saveSearchName = ""
    @State private var savedSearchToRename = ""
    @State private var savedSearchRenameText = ""
    @State private var replaceTagAcrossCollection = false
    @State private var showCardInfo = false
    @State private var cardInfoText = ""
    @State private var showDuplicateFinder = false
    @State private var showForgetCards = false
    @State private var showGradeNow = false
    @State private var forgetRestorePosition = false
    @State private var forgetResetCounts = false
    @State private var showReposition = false
    @State private var showDeleteConfirmation = false
    @State private var repositionStart = 0
    @State private var repositionStep = 1
    @State private var repositionRandom = false
    @State private var repositionShift = false
    @State private var browserColumns: Set<String> = ["question", "answer", "type", "deck", "due", "tags"]
    @State private var sidebarSearch = ""
    @State private var isSelectingRows = false

    init(
        onCreateCopy: @escaping (AddNoteCopyRequest) -> Void = { _ in },
        onAddNote: @escaping () -> Void = {},
        onManageNoteTypes: @escaping () -> Void = {},
        onClose: (() -> Void)? = nil,
        isActive: Bool = true,
        pendingSearchQuery: Binding<String?> = .constant(nil)
    ) {
        self.onCreateCopy = onCreateCopy
        self.onAddNote = onAddNote
        self.onManageNoteTypes = onManageNoteTypes
        self.onClose = onClose
        self.isActive = isActive
        _pendingSearchQuery = pendingSearchQuery
    }

    private var exportSheetPresented: Binding<Bool> {
        Binding(
            get: { exportURL != nil },
            set: { isPresented in if !isPresented { exportURL = nil } }
        )
    }

    private var browserAlertPresented: Binding<Bool> {
        Binding(
            get: { activeAlert != nil },
            set: { if !$0 { activeAlert = nil } }
        )
    }

    private var browserAlertTitle: String {
        switch activeAlert {
        case .some(.addTag): "Adicionar tag"
        case .some(.removeTag): "Remover tag"
        case .some(.replaceTag): "Substituir tag"
        case .some(.setDue): "Definir due (dias)"
        case .some(.saveSearch): "Salvar busca atual"
        case .some(.renameSavedSearch): "Renomear busca salva"
        case nil: ""
        }
    }

    @ViewBuilder
    private var browserAlertActions: some View {
        switch activeAlert {
        case .some(.addTag):
            TextField("tag", text: $tagInput)
                .accessibilityIdentifier("browser.addTag.input")
            Button("OK") {
                let nids = targetNoteIDs()
                performUndoableBrowserAction(noteIDs: nids, message: "Etiquetas adicionadas") {
                    try store.addTag(to: nids, tag: tagInput)
                }
                tagInput = ""
                runSearch()
            }
            Button("Cancelar", role: .cancel) {}
        case .some(.removeTag):
            TextField("tag", text: $tagInput)
            Button("OK") {
                let nids = targetNoteIDs()
                performUndoableBrowserAction(noteIDs: nids, message: "Etiquetas removidas") {
                    try store.removeTag(from: nids, tag: tagInput)
                }
                tagInput = ""
                runSearch()
            }
            Button("Cancelar", role: .cancel) {}
        case .some(.replaceTag):
            TextField("De", text: $tagFrom)
            TextField("Para", text: $tagTo)
            Button("OK") {
                let nids: [Int64]
                do {
                    nids = replaceTagAcrossCollection ? try store.noteIDs(matchingTag: tagFrom) : targetNoteIDs()
                } catch {
                    store.lastError = error.localizedDescription
                    return
                }
                performUndoableBrowserAction(noteIDs: nids, message: "Etiquetas substituídas") {
                    try store.replaceTag(in: nids, from: tagFrom, to: tagTo)
                }
                replaceTagAcrossCollection = false
                tagFrom = ""
                tagTo = ""
                runSearch()
            }
            Button("Cancelar", role: .cancel) { replaceTagAcrossCollection = false }
        case .some(.setDue):
            TextField("5, 0-2 ou 60-90!", text: $dueDateInput)
            Button("OK") {
                guard let due = CollectionStore.parseDueDateInput(dueDateInput) else {
                    store.lastError = "Use dias, um intervalo como 0-2 ou ! para atualizar o intervalo."
                    return
                }
                let ids = targets()
                performUndoableBrowserAction(cardIDs: ids, message: "Datas due alteradas", removeManualRevlog: true) {
                    try store.setDueDate(
                        cardIDs: ids,
                        minDays: due.min,
                        maxDays: due.max,
                        updateInterval: due.updateInterval
                    )
                }
                runSearch()
            }
            Button("Cancelar", role: .cancel) {}
        case .some(.saveSearch):
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
        case .some(.renameSavedSearch):
            TextField("Nome da busca", text: $savedSearchRenameText)
            Button("Salvar") {
                do {
                    try store.renameSavedSearch(from: savedSearchToRename, to: savedSearchRenameText)
                    savedSearchToRename = ""
                    savedSearchRenameText = ""
                } catch {
                    store.lastError = error.localizedDescription
                }
            }
            Button("Cancelar", role: .cancel) {
                savedSearchToRename = ""
                savedSearchRenameText = ""
            }
        case nil:
            Button("OK", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var browserAlertMessage: some View {
        if activeAlert == .saveSearch {
            Text("A busca “\(effectiveSearchQuery)” será salva na coleção.")
        }
    }

    private var browserPanels: some View {
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
                    if selectedCardID != nil && !isSelectingRows {
                        Divider()
                        editorPane
                            .frame(maxHeight: geo.size.height * 0.45)
                    }
                }
            }
        }
    }

    var body: some View {
        browserContent
            .modifier(BrowserSearchRequestModifier { request in
                applyBrowserSearchRequest(request)
                runSearch()
            })
            .onChange(of: pendingSearchQuery) { _, _ in
                if applyPendingSearchQuery() { runSearch() }
            }
            .onChange(of: isActive) { _, _ in
                if applyPendingSearchQuery() { runSearch() }
            }
    }

    private var browserContent: some View {
        NavigationStack {
            browserPanels
            .safeAreaInset(edge: .top, spacing: 0) {
                browserActionBar
            }
            .background(AppBackground())
            .background(browserUndoShortcut)
            .navigationTitle("Painel")
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Fechar", action: onClose)
                    }
                }
            }
            .ankiKeyboardDismissToolbar()
            .onChange(of: store.undoRevision) { _, _ in runSearch() }
            .onChange(of: store.activeProfile) { _, _ in
                searchHistory = SharedProfiles.defaults.stringArray(forKey: searchHistoryDefaultsKey) ?? []
            }
            .sheet(isPresented: $showMove) { moveSheet }
            .sheet(isPresented: $showReposition) { repositionSheet }
            .sheet(isPresented: $showForgetCards) { forgetCardsSheet }
            .sheet(isPresented: $showGradeNow) {
                GradeNowView(answerKeys: store.reviewKeyboardPreferences.answerKeys) { rating in
                    do {
                        try store.schedulerForStudySession().gradeNow(cardIDs: targets(), rating: rating)
                    } catch {
                        store.lastError = error.localizedDescription
                    }
                    showGradeNow = false
                    runSearch()
                }
            }
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
                        performUndoableBrowserAction(noteIDs: nids, message: "Tipo de nota alterado") {
                            try store.changeNoteType(noteIDs: nids, to: nt.id)
                        }
                        runSearch()
                    }
                    .accessibilityIdentifier("browser.noteType.\(nt.name)")
                }
            }
            .confirmationDialog("Apagar notas selecionadas?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("Apagar notas", role: .destructive) { bulkDelete() }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Essa ação remove as notas selecionadas e todos os cartões correspondentes. Você poderá desfazer logo depois.")
            }
            .alert(browserAlertTitle, isPresented: browserAlertPresented) {
                browserAlertActions
            } message: {
                browserAlertMessage
            }
            .sheet(isPresented: $showFindReplace) {
                let noteIDs = targetNoteIDs()
                FindReplaceSheet(
                    noteIDs: noteIDs,
                    selectedFieldNames: (try? store.fieldNames(forNoteIDs: noteIDs)) ?? [],
                    allFieldNames: Array(Set(store.notetypes.flatMap { $0.flds.map(\.name) })).sorted()
                ) { count in
                    runSearch()
                    showBrowserStatus("Substituído em \(count) nota(s).")
                }
                .environmentObject(store)
            }
            .sheet(isPresented: $showDuplicateFinder) {
                FindDuplicatesSheet(
                    fieldNames: Array(Set(store.notetypes.flatMap { $0.flds.map(\.name) })).sorted(),
                    selectedNoteIDs: Set(targetNoteIDs()),
                    initialQuery: effectiveSearchQuery,
                    onSelect: { selectNotes($0) },
                    onComplete: { runSearch() }
                )
                .environmentObject(store)
            }
            .sheet(isPresented: exportSheetPresented) {
                if let exportURL {
                    ShareSheet(items: [exportURL])
                        .accessibilityIdentifier("browser.export.share-sheet")
                }
            }
            .sheet(isPresented: $showSearchHelp) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Group {
                                Text("deck:Nome · deck:Nome::* · deck:current · deck:filtered · preset:\"Nome\"").font(.headline)
                                Text("is:new · is:learn · is:review · is:due · is:suspended · is:buried · is:buried-sibling · is:buried-manually")
                                Text("flag:0…7 · tag:nome · tag:prefixo* · tag:none · tag:marked · tag:leech · deck:filtered · -deck:filtered")
                                Text("note:Tipo · card:Forward · card:2 · nid:123 · cid:123,456 · Front:valor · re:padrão")
                                Text("w:palavra · nc:acao · tag:nc:conjuncao · sc:resposta · Front:re:padrão · tag:re:padrão")
                                Text("prop:due<=7 · prop:ivl>=30 · prop:reps>=5 · prop:lapses>=2 · prop:ease>=2.5 · prop:pos<=10")
                                Text("flag:red · added:1 · edited:1 · introduced:1 · rated:1 · rated:1:1 · prop:resched=0 · dupe: · OR · -is:suspended")
                                Text("has-cd:key · prop:cdn:key>=1 · prop:cds:key=valor · prop:s>=1 · prop:d<=5 · prop:r>=0.9")
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
            .task { loadBrowser() }
            .onChange(of: sortKey) { _, key in
                if restoredSortKey == key {
                    restoredSortKey = nil
                    runSearch()
                    return
                }
                restoredSortKey = nil
                let descending = key.defaultDescending
                if sortDescending != descending {
                    restoredSortDirection = descending
                    sortDescending = descending
                }
                persistBrowserSortPreference(key, descending: descending, notesMode: notesMode)
                runSearch()
            }
            .onChange(of: sortDescending) { _, descending in
                if restoredSortDirection == descending {
                    restoredSortDirection = nil
                    runSearch()
                    return
                }
                restoredSortDirection = nil
                persistBrowserSortPreference(sortKey, descending: descending, notesMode: notesMode)
                runSearch()
            }
            .onChange(of: browserColumns) { _, columns in
                var conf = store.conf
                conf["browserColumns"] = columns.sorted()
                do { try store.saveConf(conf) }
                catch { store.lastError = error.localizedDescription }
            }
            .onChange(of: notesMode) { _, enabled in
                restoreBrowserSortPreference(for: enabled)
                runSearch()
            }
            .onChange(of: selectedCardID) { _, id in
                loadEditor(for: id)
            }
            .overlay(alignment: .bottom) {
                if let browserStatusMessage {
                    Text(browserStatusMessage)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppTheme.primaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(AppTheme.primaryText.opacity(0.14), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                        .accessibilityIdentifier("browser.operation.status")
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    private func showBrowserStatus(_ message: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            browserStatusMessage = message
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard browserStatusMessage == message else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                browserStatusMessage = nil
            }
        }
    }

    // MARK: - Sidebar

    private var filterSidebar: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(AppTheme.secondaryText)
                    TextField("Filtrar itens", text: $sidebarSearch)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                }
            }
            Section("Buscas salvas") {
                let visibleSearches = store.savedSearches.filter { sidebarMatches($0.name) }
                if visibleSearches.isEmpty {
                    Text("Nenhuma busca salva")
                        .foregroundStyle(AppTheme.secondaryText)
                } else {
                    ForEach(visibleSearches, id: \.name) { item in
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
                                do { try store.removeSavedSearch(named: item.name) }
                                catch { store.lastError = error.localizedDescription }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(AppTheme.secondaryText)
                            }
                            .buttonStyle(GlassIconButtonStyle(tint: AppTheme.danger))
                            .help("Remover busca salva")
                        }
                        .contextMenu {
                            Button("browser.rename", systemImage: "pencil") {
                                savedSearchToRename = item.name
                                savedSearchRenameText = item.name
                                activeAlert = .renameSavedSearch
                            }
                            Button("Remover", systemImage: "trash", role: .destructive) {
                                do { try store.removeSavedSearch(named: item.name) }
                                catch { store.lastError = error.localizedDescription }
                            }
                        }
                        .glassListRow(selected: false)
                    }
                }
                Button("browser.save-current-search") {
                    saveSearchName = suggestedSaveSearchName
                    activeAlert = .saveSearch
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
            Section("browser.sidebar.decks") {
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
                Button("Limpar tags não usadas") {
                    do { try store.rebuildTagRegistry() }
                    catch { store.lastError = error.localizedDescription }
                }
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #endif
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func filterRow(_ filter: BrowserFilter) -> some View {
        let searchValue = filterSearchValue(filter)
        let row = Button {
            selectFilter(filter)
        } label: {
            HStack {
                filter.localizedTitle
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
        if !sidebarMatches(searchValue) {
            EmptyView()
        } else if case .tag(let tag) = filter {
            row.contextMenu {
                Button("browser.rename-tag", systemImage: "pencil") {
                    tagFrom = tag
                    tagTo = ""
                    replaceTagAcrossCollection = true
                    activeAlert = .replaceTag
                }
                Button("Excluir tag", systemImage: "trash", role: .destructive) {
                    do {
                        let noteIDs = try store.noteIDs(matchingTag: tag)
                        performUndoableBrowserAction(noteIDs: noteIDs, message: "Tag removida") {
                            try store.removeTag(from: noteIDs, tag: tag)
                        }
                        runSearch()
                    } catch {
                        store.lastError = error.localizedDescription
                    }
                }
            }
        } else {
            row
        }
    }

    private func filterSearchValue(_ filter: BrowserFilter) -> String {
        switch filter {
        case .deck(let name), .noteType(let name), .tag(let name): return name
        default: return filter.title
        }
    }

    private func sidebarMatches(_ value: String) -> Bool {
        let search = sidebarSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty || value.localizedCaseInsensitiveContains(search)
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(BrowserFilter.mobileDefaults, id: \.self) { filter in
                    Button {
                        selectFilter(filter)
                    } label: {
                        filter.localizedTitle
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
                    .submitLabel(.search)
                    #endif
                    .autocorrectionDisabled()
                    .foregroundStyle(AppTheme.primaryText)
                    .onSubmit { submitSearch() }
                Menu {
                    if searchHistory.isEmpty {
                        Text("Nenhuma busca recente")
                    } else {
                        ForEach(Array(searchHistory.enumerated()), id: \.offset) { _, recent in
                            Button(recent) { query = recent }
                        }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .accessibilityLabel("Buscas recentes")
                }
                .menuIndicator(.hidden)
                .buttonStyle(GlassIconButtonStyle(tint: AppTheme.accent))
                .disabled(searchHistory.isEmpty)
            }
            .padding(12)
            .ankiGlass(tint: .white.opacity(0.08), interactive: true, in: Capsule())
            .padding(.horizontal)
            .padding(.vertical, 8)

            HStack {
                Picker("Modo", selection: $notesMode) {
                    Text("browser.cards-mode").tag(false)
                    Text("Notas").tag(true)
                }
                .pickerStyle(.segmented)
                Picker("browser.sort", selection: $sortKey) {
                    ForEach(BrowserSort.allCases.filter { !notesMode || $0.supportsNotesMode }, id: \.self) { s in
                        Text(s.title).tag(s)
                    }
                }
                .pickerStyle(.menu)
                Button {
                    sortDescending.toggle()
                } label: {
                    Image(systemName: sortDescending ? "arrow.down" : "arrow.up")
                        .accessibilityLabel(sortDescending ? "Ordem decrescente" : "Ordem crescente")
                }
                .buttonStyle(GlassIconButtonStyle(tint: AppTheme.accent))
                Menu("Colunas") {
                    ForEach(availableBrowserColumns, id: \.id) { column in
                        Button {
                            if browserColumns.contains(column.id) {
                                browserColumns.remove(column.id)
                            } else {
                                browserColumns.insert(column.id)
                            }
                        } label: {
                            if browserColumns.contains(column.id) {
                                Label {
                                    browserColumnTitle(column)
                                } icon: {
                                    Image(systemName: "checkmark")
                                }
                            } else {
                                browserColumnTitle(column)
                            }
                        }
                    }
                }
                .panelGlassMenu()
            }
            .padding(.horizontal)

            if displayRows.isEmpty {
                EmptyStateView(
                    title: "Nenhum cartão",
                    subtitle: "Ajuste o filtro ou a busca.",
                    systemImage: "magnifyingglass"
                )
            } else {
                browserRowsList
            }
        }
    }

    private var browserRowsList: some View {
        #if os(macOS)
        List(selection: $selectedIDs) { browserRows }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        #else
        List { browserRows }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        #endif
    }

    @ViewBuilder
    private var browserRows: some View {
        ForEach(displayRows) { row in
            BrowserRowView(
                row: row,
                isSelected: isSelectingRows ? selectedIDs.contains(row.id) : (selectedCardID == row.id || selectedIDs.contains(row.id)),
                columns: browserColumns,
                notesMode: notesMode,
                selectionMode: isSelectingRows
            )
                .environmentObject(store)
                .glassListRow(
                    selected: isSelectingRows
                        ? selectedIDs.contains(row.id)
                        : (selectedCardID == row.id || selectedIDs.contains(row.id)),
                    tint: browserRowTint(row)
                )
                .contentShape(Rectangle())
                #if os(macOS)
                .tag(row.id)
                .onTapGesture { selectedCardID = row.id }
                #else
                .onTapGesture {
                    if isSelectingRows {
                        if !selectedIDs.insert(row.id).inserted {
                            selectedIDs.remove(row.id)
                        }
                    } else {
                        selectedCardID = row.id
                        selectedIDs = [row.id]
                    }
                }
                #endif
                .contextMenu {
                    Button("Pré-visualizar", systemImage: "eye") { previewRow = row }
                    Button("Criar cópia", systemImage: "doc.on.doc") { requestCopy(of: row) }
                    Button("Editar") { selectedCardID = row.id }
                }
        }
        if hasMoreRows {
            Button("Carregar mais cartões") { loadMoreRows() }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
        }
    }

    private var sortedRows: [CollectionStore.BrowserRow] {
        rows
    }

    private var availableBrowserColumns: [(id: String, title: String)] {
        var columns: [(String, String)] = [
            ("question", "Pergunta"), ("answer", "Resposta"), ("type", "Cartão"), ("noteType", "Nota"), ("deck", "browser.column.deck"),
            ("due", "Vencimento"), ("interval", "Intervalo"), ("ease", "Facilidade"),
            ("reps", "browser.review-count"), ("lapses", "Falhas"), ("tags", "Etiquetas"),
            ("created", "Criado"), ("cardModified", "Cartão modificado"),
            ("noteModified", "Nota modificada"), ("sortField", "Campo de ordenação"),
            ("originalPosition", "Posição original"), ("stability", "Estabilidade FSRS"),
            ("difficulty", "Dificuldade FSRS"), ("retrievability", "Retenção prevista")
        ]
        let fields = Set(store.notetypes.flatMap { $0.flds.map(\.name) })
        columns += fields.sorted().map { ("field:\($0)", $0) }
        return columns.map { (id: $0.0, title: $0.1) }
    }

    private func browserColumnTitle(_ column: (id: String, title: String)) -> Text {
        if column.id.hasPrefix("field:") {
            return Text(verbatim: column.title)
        }
        return Text(LocalizedStringKey(column.title))
    }

    /// Notes mode: one row per note (first card).
    private var displayRows: [CollectionStore.BrowserRow] {
        guard notesMode else { return sortedRows }
        var seen = Set<Int64>()
        return sortedRows.filter { seen.insert($0.note.id).inserted }
    }

    private func browserRowTint(_ row: CollectionStore.BrowserRow) -> Color {
        if notesMode {
            return row.note.tagList.contains("marked") ? Color.purple : .white
        }
        if row.card.flags > 0 { return BrowserRowView.flagColor(row.card.flags) }
        if row.card.queue == -1 { return AppTheme.warn }
        if row.note.tagList.contains("marked") { return .purple }
        return .white
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
                            mediaBase: store.mediaRoot,
                            deckName: row.templateDeckName,
                            nightMode: colorScheme == .dark
                        )
                        CardWebView(
                            html: result.html,
                            baseURL: store.mediaRoot,
                            onSpeechTap: { request in store.mediaStore.speak(request) }
                        )
                            .frame(height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 16))

                        ForEach(Array(nt.flds.enumerated()), id: \.offset) { idx, field in
                            VStack(alignment: .leading, spacing: 4) {
                                NoteFieldEditor(
                                    html: fieldBinding(idx), field: field, isClozeType: nt.isCloze,
                                    mediaBase: store.mediaRoot, sourceMode: !useRichEditor,
                                                nextClozeNumber: (ClozeHelper.ords(in: editFields).max() ?? -1) + 2
                                )
                                .id("\(row.note.id)-\(nt.id)-\(field.ord)")
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Etiquetas")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.mist)
                            TextField("tags", text: $editTags)
                                .padding(8)
                                .ankiGlass(interactive: true, in: RoundedRectangle(cornerRadius: 12))
                        }

                        VStack(spacing: 10) {
                            Button("Salvar") { saveEditor(row: row) }
                                .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, expands: true))
                                .accessibilityIdentifier("browser.editor.save")
                            if row.card.queue == -2 || row.card.queue == -3 {
                                Button("Desocultar") {
                                    performUndoableBrowserAction(cardIDs: [row.card.id], message: "Cartão desocultado") {
                                        try store.unburyCards([row.card.id])
                                    }
                                    runSearch()
                                }
                                .buttonStyle(GlassButtonStyle(tint: AppTheme.good, expands: true))
                            }
                            if row.card.queue == -1 {
                                Button("Dessuspender") {
                                    performUndoableBrowserAction(cardIDs: [row.card.id], message: "Cartão dessuspenso") {
                                        try store.unsuspendCards([row.card.id])
                                    }
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
            if store.canUndoCollectionAction {
                Button {
                    undoBrowserAction()
                } label: {
                    Label("Desfazer", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(GlassChipButtonStyle())
                .help("Desfazer \(store.collectionUndoMessage ?? "ação")")
            }
            if store.canRedoCollectionAction {
                Button {
                    redoBrowserAction()
                } label: {
                    Label("Refazer", systemImage: "arrow.uturn.forward")
                }
                .buttonStyle(GlassChipButtonStyle())
                .help("Refazer \(store.collectionRedoMessage ?? "ação")")
            }
            #if os(iOS)
            Button {
                isSelectingRows.toggle()
                if !isSelectingRows { selectedCardID = selectedIDs.first }
            } label: {
                Label(isSelectingRows ? "Concluir" : "Selecionar", systemImage: isSelectingRows ? "checkmark" : "checkmark.circle")
            }
            .buttonStyle(GlassChipButtonStyle())
            #endif
            Menu {
                ForEach(store.savedSearches, id: \.name) { item in
                    Button(item.name) { applySavedSearch(item.query) }
                        .accessibilityIdentifier("browser.savedSearch.item.\(item.name)")
                }
                if !store.savedSearches.isEmpty { Divider() }
                Button("browser.save-current-search", systemImage: "bookmark") {
                    saveSearchName = suggestedSaveSearchName
                    activeAlert = .saveSearch
                }
                .accessibilityIdentifier("browser.savedSearch.saveCurrent")
            } label: {
                Image(systemName: "bookmark")
            }
            .panelGlassMenu()
            .accessibilityIdentifier("browser.savedSearch.menu")
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
                    selectAllSearchResults()
                }
                .accessibilityIdentifier("browser.selectAll")
                Button("Inverter seleção") {
                    do {
                        selectedIDs = try allSearchCardIDs().subtracting(selectedIDs)
                        #if os(iOS)
                        isSelectingRows = true
                        #endif
                    }
                    catch { store.lastError = error.localizedDescription }
                }
                .accessibilityIdentifier("browser.selection.invert")
                Button("Procurar duplicatas") {
                    selectedIDs.removeAll()
                    query = "dupe:"
                    selectedFilter = .all
                    committedSearchQuery = "dupe:"
                    runSearch()
                }
                Button("Selecionar notas", systemImage: "note.text") {
                    selectNotes(targetNoteIDs())
                }
                .accessibilityIdentifier("browser.selection.notes")
                Button("Encontrar duplicatas por campo…", systemImage: "doc.on.doc") {
                    showDuplicateFinder = true
                }
                Button("Adicionar nota", systemImage: "plus") {
                    onAddNote()
                }
                Button("Gerenciar tipos de nota", systemImage: "doc.badge.gearshape") {
                    onManageNoteTypes()
                }
                Button("Criar cópia", systemImage: "doc.on.doc") {
                    if let row = currentBrowserRow { requestCopy(of: row) }
                }
                .disabled(currentBrowserRow == nil)
                Button("Limpar seleção") { selectedIDs.removeAll() }
                Divider()
                Menu("Bandeira", systemImage: "flag") {
                    Button {
                        setBulkFlag(0)
                    } label: {
                        if currentBrowserFlag == 0 {
                            Label("Sem bandeira", systemImage: "checkmark")
                        } else {
                            Text("Sem bandeira")
                        }
                    }
                    ForEach(1...7, id: \.self) { n in
                        Button {
                            setBulkFlag(n)
                        } label: {
                            if currentBrowserFlag == n {
                                Label(AnkiFlagColor.name(n), systemImage: "checkmark")
                            } else {
                                Text(AnkiFlagColor.name(n))
                            }
                        }
                    }
                }
                Button("Marcar / desmarcar", systemImage: "star") { bulkMark() }
                    .accessibilityIdentifier("browser.selection.mark")
                Toggle("Suspender", isOn: Binding(
                    get: { currentBrowserRow?.card.queue == -1 },
                    set: { setSelectionSuspended($0) }
                ))
                .accessibilityIdentifier("browser.selection.suspend")
                Button("Suspender nota", systemImage: "pause.circle.fill") { suspendNotes() }
                Toggle("Ocultar", isOn: Binding(
                    get: { currentBrowserRow.map { $0.card.queue == -2 || $0.card.queue == -3 } ?? false },
                    set: { setSelectionBuried($0) }
                ))
                .accessibilityIdentifier("browser.selection.bury")
                Button("Desocultar todos", systemImage: "eye.circle") {
                    do {
                        let cards = try store.cards(inQueue: -2) + store.cards(inQueue: -3)
                        let snapshot = try store.makeBrowserUndoSnapshot(cardIDs: cards.map(\.id), message: "Cartões desocultados")
                        try store.unburyAll()
                        store.registerBrowserUndo(snapshot)
                    } catch { store.lastError = error.localizedDescription }
                    runSearch()
                }
                Divider()
                Button("Mover…", systemImage: "folder") { showMove = true }
                Button("Mudar tipo de nota…", systemImage: "doc.badge.gearshape") { showChangeType = true }
                    .accessibilityIdentifier("browser.changeNoteType")
                Button("browser.add-tags", systemImage: "tag") { activeAlert = .addTag }
                    .accessibilityIdentifier("browser.addTag")
                Button("Remover tag…", systemImage: "tag.slash") { activeAlert = .removeTag }
                Button("Substituir tag…", systemImage: "arrow.left.arrow.right") { activeAlert = .replaceTag }
                Button("browser.find-replace", systemImage: "text.magnifyingglass") { showFindReplace = true }
                    #if os(macOS)
                    .accessibilityIdentifier("browser.findReplace")
                    #endif
                Button("Definir due…", systemImage: "calendar") { activeAlert = .setDue }
                Button("browser.grade-now", systemImage: "checkmark") { showGradeNow = true }
                    .disabled(targets().isEmpty)
                Button("Repor (esquecer)…", systemImage: "arrow.counterclockwise") {
                    forgetRestorePosition = store.conf["browserForgetRestorePosition"] as? Bool ?? false
                    forgetResetCounts = store.conf["browserForgetResetCounts"] as? Bool ?? false
                    showForgetCards = true
                }
                .accessibilityIdentifier("browser.forgetCards")
                Button("Exportar seleção (.apkg)", systemImage: "square.and.arrow.up") { exportSelection() }
                    .accessibilityIdentifier("browser.export.apkg")
                Button("Exportar seleção (TSV)", systemImage: "tablecells") { exportSelectionTSV() }
                    .accessibilityIdentifier("browser.export.tsv")
                Button("Criar filtrado desta busca", systemImage: "line.3.horizontal.decrease.circle") {
                    createFilteredFromSearch()
                }
                Button("browser.reposition-new", systemImage: "arrow.up.arrow.down") {
                    showReposition = true
                }
                .accessibilityIdentifier("browser.reposition")
                Divider()
                Button("Apagar…", systemImage: "trash", role: .destructive) { showDeleteConfirmation = true }
            } label: {
                HStack(spacing: 0) {
                    Text("browser.actions")
                    Text(verbatim: " ▾")
                }
            }
            .panelGlassMenu()
            .accessibilityElement(children: .combine)
            .accessibilityLabel("browser.actions")
            .accessibilityIdentifier("browser.actions.menu")
            Button("Desocultar") { bulkUnbury() }
                .buttonStyle(GlassChipButtonStyle())
            Button("Dessuspender") { bulkUnsuspend() }
                .buttonStyle(GlassChipButtonStyle())
            Button(useRichEditor ? "Editar HTML" : "Editor visual") { useRichEditor.toggle() }
                .buttonStyle(GlassChipButtonStyle())
                .accessibilityIdentifier("browser.toggleRichEditor")
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

    private var browserUndoShortcut: some View {
        Group {
            Button("") { undoBrowserAction() }
                .keyboardShortcut("z", modifiers: [.command])
            Button("") { redoBrowserAction() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            #if os(macOS)
            Button("") { notesMode.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            #endif
        }
        .opacity(0.001)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }

    private var repositionSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        GlassOptionRow(title: "Posição inicial") {
                            Stepper("\(repositionStart)", value: $repositionStart, in: 0...999_999)
                                .accessibilityIdentifier("browser.reposition.start")
                        }
                        GlassOptionRow(title: "Passo") {
                            Stepper("\(repositionStep)", value: $repositionStep, in: 1...999)
                                .accessibilityIdentifier("browser.reposition.step")
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
                        do {
                            let ids = targets()
                            let cardIDs = repositionShift ? try store.cards(inQueue: 0).map(\.id) : ids
                            let snapshot = try store.makeBrowserUndoSnapshot(cardIDs: cardIDs, message: "Cartões reposicionados")
                            try store.repositionNewCards(
                                ids,
                                startingFrom: repositionStart,
                                step: repositionStep,
                                random: repositionRandom,
                                shift: repositionShift
                            )
                            store.registerBrowserUndo(snapshot)
                        } catch {
                            store.lastError = error.localizedDescription
                        }
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

    private var forgetCardsSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        GlassOptionRow(title: "Restaurar posição original") {
                            Toggle("", isOn: $forgetRestorePosition).labelsHidden().tint(AppTheme.accent)
                        }
                        GlassOptionRow(title: "Zerar reps e lapsos") {
                            Toggle("", isOn: $forgetResetCounts).labelsHidden().tint(AppTheme.accent)
                        }
                        Text("O histórico de revisões será mantido. Essas opções serão lembradas para a próxima vez.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(.horizontal, 4)
                    }
                    .padding(20)
                }
                HStack(spacing: 12) {
                    Button("Cancelar") { showForgetCards = false }
                        .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.18, expands: true))
                    Button("Repor cartões") { bulkReset() }
                        .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.42, expands: true))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .background(AppBackground())
            .navigationTitle("Repor cartões")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 280)
        #endif
    }

    private var moveSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(store.decks) { deck in
                            Button {
                                do {
                                    let ids = targets()
                                    let snapshot = try store.makeBrowserUndoSnapshot(cardIDs: ids, message: "Cartões movidos")
                                    try store.moveCards(ids, toDeck: deck.id)
                                    store.registerBrowserUndo(snapshot)
                                    selectedIDs.removeAll()
                                } catch {
                                    store.lastError = error.localizedDescription
                                }
                                showMove = false
                                runSearch()
                            } label: {
                                HStack {
                                    Text(deck.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(AppTheme.primaryText)
                                    Spacer()
                                    Image(systemName: "folder")
                                        .foregroundStyle(AppTheme.primaryText.opacity(0.55))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(GlassButtonStyle(tint: .white, prominent: false, tintStrength: 0.14, expands: true))
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
        committedSearchQuery
    }

    private func loadBrowser() {
        if !loadedInitialQuery {
            let defaultSearch = store.conf["defaultSearchText"] as? String
                ?? store.conf["browserDefaultSearch"] as? String ?? ""
            let hasDefaultSearch = !defaultSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            query = hasDefaultSearch ? defaultSearch : ""
            committedSearchQuery = hasDefaultSearch ? defaultSearch : "deck:current"
            searchHistory = SharedProfiles.defaults.stringArray(forKey: searchHistoryDefaultsKey) ?? []
            loadedInitialQuery = true
        }
        restoreBrowserSortPreference(for: notesMode)
        if let savedColumns = store.conf["browserColumns"] as? [String], !savedColumns.isEmpty {
            browserColumns = Set(savedColumns)
            if browserColumns.remove("cardCount") != nil {
                browserColumns.insert("type")
            }
        }
        do { try store.rebuildTagRegistry() }
        catch { store.lastError = error.localizedDescription }
        if let request = store.browserSearchRequest {
            applyBrowserSearchRequest(request)
            store.consumeBrowserSearchRequest(id: request.id)
        }
        applyPendingSearchQuery()
        runSearch()
    }

    private func restoreBrowserSortPreference(for notesMode: Bool) {
        let preference = BrowserSort.preference(from: store.conf, notesMode: notesMode)
        let key = notesMode && !preference.sortKey.supportsNotesMode ? .sortField : preference.sortKey
        let descending = key == preference.sortKey ? preference.descending : key.defaultDescending
        if sortKey != key {
            restoredSortKey = key
            sortKey = key
        }
        if sortDescending != descending {
            restoredSortDirection = descending
            sortDescending = descending
        }
        let sortTypeKey = notesMode ? "noteSortType" : "sortType"
        let directionKey = notesMode ? "browserNoteSortBackwards" : "sortBackwards"
        if key != preference.sortKey || store.conf[sortTypeKey] as? String == nil || store.conf[directionKey] as? Bool == nil {
            persistBrowserSortPreference(key, descending: descending, notesMode: notesMode)
        }
    }

    private func persistBrowserSortPreference(_ key: BrowserSort, descending: Bool, notesMode: Bool) {
        var conf = store.conf
        BrowserSort.savePreference(key, descending: descending, notesMode: notesMode, into: &conf)
        do { try store.saveConf(conf) }
        catch { store.lastError = error.localizedDescription }
    }

    private func selectFilter(_ filter: BrowserFilter) {
        selectedIDs.removeAll()
        selectedFilter = filter
        query = filter.searchQuery
        committedSearchQuery = filter.searchQuery
        runSearch()
    }

    private var suggestedSaveSearchName: String {
        let q = effectiveSearchQuery
        if q.isEmpty { return "Busca" }
        if q.count <= 28 { return q }
        return String(q.prefix(28)) + "…"
    }

    private func applySavedSearch(_ savedQuery: String) {
        selectedIDs.removeAll()
        query = savedQuery
        selectedFilter = .all
        committedSearchQuery = savedQuery
        runSearch()
    }

    private var searchHistoryDefaultsKey: String {
        "ankios.browser.searchHistory.\(store.activeProfile)"
    }

    private func submitSearch(_ value: String? = nil) {
        let raw = value ?? query
        let normalized = raw
            .replacingOccurrences(of: "\\s", with: " ", options: .regularExpression)
        query = normalized
        selectedFilter = .all
        selectedIDs.removeAll()
        committedSearchQuery = normalized
        if runSearch() {
            rememberSearch(normalized)
        }
    }

    private func applyBrowserSearchRequest(_ request: BrowserSearchRequest) {
        let normalized = request.query
            .replacingOccurrences(of: "\\s", with: " ", options: .regularExpression)
        selectedFilter = .all
        selectedIDs.removeAll()
        query = normalized
        committedSearchQuery = normalized
    }

    private func applyPendingSearchQuery() -> Bool {
        guard isActive, loadedInitialQuery, let pendingSearchQuery else { return false }
        applyBrowserSearchRequest(BrowserSearchRequest(query: pendingSearchQuery))
        self.pendingSearchQuery = nil
        return true
    }

    private func rememberSearch(_ value: String) {
        guard !value.isEmpty else { return }
        searchHistory.removeAll { $0 == value }
        searchHistory.insert(value, at: 0)
        if searchHistory.count > 30 {
            searchHistory.removeLast(searchHistory.count - 30)
        }
        SharedProfiles.defaults.set(searchHistory, forKey: searchHistoryDefaultsKey)
    }

    @discardableResult
    private func runSearch() -> Bool {
        do {
            rows = try store.search(query: effectiveSearchQuery, limit: 500, sortType: sortKey.sortValue(notesMode: notesMode), sortDescending: sortDescending, notesMode: notesMode)
            hasMoreRows = rows.count == 500
            if !selectedIDs.isEmpty {
                selectedIDs.formIntersection(try allSearchCardIDs())
            }
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
            return true
        } catch {
            store.lastError = error.localizedDescription
            return false
        }
    }

    private func loadMoreRows() {
        do {
            let currentCount = rows.count
            let requestedCount = currentCount + 500
            let expanded = try store.search(
                query: effectiveSearchQuery,
                limit: requestedCount + 1,
                sortType: sortKey.sortValue(notesMode: notesMode),
                sortDescending: sortDescending,
                notesMode: notesMode
            )
            rows = Array(expanded.prefix(requestedCount))
            hasMoreRows = expanded.count > requestedCount
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func selectAllSearchResults() {
        do {
            selectedIDs = try allSearchCardIDs()
            #if os(iOS)
            isSelectingRows = true
            #endif
        }
        catch { store.lastError = error.localizedDescription }
    }

    private func allSearchCardIDs() throws -> Set<Int64> {
        Set(try BrowserSelection.allRowIDs(
            query: effectiveSearchQuery,
            sortType: sortKey.sortValue(notesMode: notesMode),
            sortDescending: sortDescending,
            notesMode: notesMode,
            store: store
        ))
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
        performUndoableBrowserAction(noteIDs: [row.note.id], message: "Nota editada") {
            try store.updateNote(row.note, fields: editFields, tags: editTags)
        }
        runSearch()
    }

    private func targets() -> [Int64] {
        let rowIDs: [Int64]
        if isSelectingRows || !selectedIDs.isEmpty {
            rowIDs = selectedCardIDsInSearchOrder()
        } else {
            rowIDs = selectedCardID.map { [$0] } ?? []
        }
        do {
            return try BrowserSelection.targetCardIDs(rowIDs, notesMode: notesMode, store: store)
        } catch {
            store.lastError = error.localizedDescription
            return []
        }
    }

    private func selectedCardIDsInSearchOrder() -> [Int64] {
        guard !selectedIDs.isEmpty else { return [] }
        do {
            return try BrowserSelection.orderedRowIDs(
                selectedIDs: selectedIDs,
                query: effectiveSearchQuery,
                sortType: sortKey.sortValue(notesMode: notesMode),
                sortDescending: sortDescending,
                notesMode: notesMode,
                store: store
            )
        } catch {
            store.lastError = error.localizedDescription
            return selectedIDs.sorted()
        }
    }

    private func targetNoteIDs() -> [Int64] {
        do { return try store.noteIDs(ofCards: targets()) }
        catch {
            store.lastError = error.localizedDescription
            return []
        }
    }

    private var currentBrowserRow: CollectionStore.BrowserRow? {
        if let selectedCardID, let row = rows.first(where: { $0.id == selectedCardID }) {
            return row
        }
        return sortedRows.first { selectedIDs.contains($0.id) }
    }

    private var currentBrowserFlag: Int {
        (currentBrowserRow?.card.flags ?? 0) & 7
    }

    private func requestCopy(of row: CollectionStore.BrowserRow) {
        let deckID = row.card.odid == 0 ? row.card.did : row.card.odid
        onCreateCopy(AddNoteCopyRequest(note: row.note, deckID: deckID))
    }

    private func suspendNotes() {
        let nids = targetNoteIDs()
        do {
            let cards = try store.cardIDs(ofNotes: nids)
            let snapshot = try store.makeBrowserUndoSnapshot(noteIDs: nids, cardIDs: cards, message: "Notas suspensas")
            try store.setCardsQueue(cards, queue: -1)
            store.registerBrowserUndo(snapshot)
        } catch {
            store.lastError = error.localizedDescription
        }
        runSearch()
    }

    private func setBulkFlag(_ flag: Int) {
        let ids = targets()
        guard !ids.isEmpty else { return }
        let selectedFlag = flag > 0 && currentBrowserFlag == flag ? 0 : flag
        performUndoableBrowserAction(cardIDs: ids, message: "Bandeiras alteradas") {
            try store.setCardsFlag(ids, flag: selectedFlag)
        }
        runSearch()
    }

    private func setSelectionSuspended(_ suspended: Bool) {
        let ids = targets()
        guard !ids.isEmpty else { return }
        performUndoableBrowserAction(
            cardIDs: ids,
            message: suspended ? "Cartões suspensos" : "Cartões dessuspensos"
        ) {
            if suspended {
                try store.setCardsQueue(ids, queue: -1)
            } else {
                try store.unsuspendCards(ids)
            }
        }
        runSearch()
    }

    private func setSelectionBuried(_ buried: Bool) {
        let ids = targets()
        guard !ids.isEmpty else { return }
        performUndoableBrowserAction(
            cardIDs: ids,
            message: buried ? "Cartões ocultos" : "Cartões desocultados"
        ) {
            if buried {
                try store.buryCards(ids)
            } else {
                try store.unburyCards(ids)
            }
        }
        runSearch()
    }

    private func bulkQueue(_ q: Int) {
        let ids = targets()
        performUndoableBrowserAction(cardIDs: ids, message: q == -1 ? "Cartões suspensos" : "Cartões ocultos") {
            if q == -1 {
                try store.setCardsQueue(ids, queue: q)
            } else {
                try store.buryCards(ids)
            }
        }
        runSearch()
    }

    private func bulkDelete() {
        let nids = targetNoteIDs()
        do {
            try store.deleteNotesUndoably(ids: Array(Set(nids)))
            selectedIDs.removeAll()
            selectedCardID = nil
        } catch {
            store.lastError = error.localizedDescription
        }
        runSearch()
    }

    private func bulkUnbury() {
        let ids = targets()
        performUndoableBrowserAction(cardIDs: ids, message: "Cartões desocultados") {
            try store.unburyCards(ids)
        }
        runSearch()
    }

    private func bulkUnsuspend() {
        let ids = targets()
        performUndoableBrowserAction(cardIDs: ids, message: "Cartões dessuspensos") {
            try store.unsuspendCards(ids)
        }
        runSearch()
    }

    private func bulkReset() {
        let ids = targets()
        var conf = store.conf
        conf["browserForgetRestorePosition"] = forgetRestorePosition
        conf["browserForgetResetCounts"] = forgetResetCounts
        do {
            try store.saveConf(conf)
        } catch {
            store.lastError = error.localizedDescription
            return
        }
        performUndoableBrowserAction(cardIDs: ids, message: "Cartões repostos", removeManualRevlog: true) {
            try store.resetCards(
                ids,
                restoreOriginalPosition: forgetRestorePosition,
                clearCounts: forgetResetCounts
            )
        }
        showForgetCards = false
        runSearch()
    }

    private func bulkMark() {
        let nids = targetNoteIDs()
        guard let currentID = currentBrowserRow?.note.id ?? nids.first else { return }
        let shouldMark: Bool
        do {
            guard let current = try store.fetchNote(id: currentID) else { return }
            shouldMark = !current.tagList.contains("marked")
        } catch {
            store.lastError = error.localizedDescription
            return
        }
        performUndoableBrowserAction(noteIDs: nids, message: "Notas marcadas") {
            for nid in nids {
                guard let note = try store.fetchNote(id: nid),
                      note.tagList.contains("marked") != shouldMark else { continue }
                try store.toggleMark(note: note)
            }
        }
        runSearch()
    }

    private func performUndoableBrowserAction(
        noteIDs: [Int64] = [],
        cardIDs: [Int64] = [],
        message: String,
        removeManualRevlog: Bool = false,
        action: () throws -> Void
    ) {
        do {
            let snapshot = try store.makeBrowserUndoSnapshot(
                noteIDs: noteIDs,
                cardIDs: cardIDs,
                message: message,
                removeManualRevlog: removeManualRevlog
            )
            try action()
            store.registerBrowserUndo(snapshot)
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func undoBrowserAction() {
        do {
            try store.undoMostRecentCollectionAction()
            runSearch()
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func redoBrowserAction() {
        do {
            try store.redoMostRecentCollectionAction()
            runSearch()
        } catch {
            store.lastError = error.localizedDescription
        }
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
        let nids = targetNoteIDs()
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
        let search = effectiveSearchQuery
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
            let chosen = try FilteredDeckSupport.selectedCardIDs(filtered, store: store)
            let snapshot = try store.makeBrowserUndoSnapshot(
                cardIDs: chosen,
                message: "Baralho filtrado criado",
                deleteDeckIDs: [id]
            )
            decks.append(filtered)
            try store.saveDecks(decks)
            try FilteredDeckSupport.install(cardIDs: chosen, deckID: id, reschedule: true, store: store)
            try store.refreshCounts()
            store.registerBrowserUndo(snapshot)
            store.lastError = "Baralho filtrado criado: \(name)"
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func selectNotes(_ noteIDs: [Int64]) {
        do {
            let cardIDs = try store.cardIDs(ofNotes: noteIDs)
            guard !cardIDs.isEmpty else { return }
            notesMode = true
            selectedFilter = .all
            query = cardIDs.map { "cid:\($0)" }.joined(separator: " OR ")
            committedSearchQuery = query
            selectedIDs = Set(cardIDs)
            selectedCardID = cardIDs.first
            #if os(iOS)
            isSelectingRows = true
            #endif
            runSearch()
        } catch {
            store.lastError = error.localizedDescription
        }
    }
}

@MainActor
enum BrowserSelection {
    static func allRowIDs(
        query: String,
        sortType: Int,
        sortDescending: Bool,
        notesMode: Bool,
        store: CollectionStore
    ) throws -> [Int64] {
        var ids: [Int64] = []
        var offset = 0
        while true {
            let batch = try store.search(
                query: query,
                limit: 500,
                offset: offset,
                sortType: sortType,
                sortDescending: sortDescending,
                notesMode: notesMode
            )
            ids.append(contentsOf: batch.map(\.id))
            offset += batch.count
            if batch.count < 500 { return ids }
        }
    }

    static func orderedRowIDs(
        selectedIDs: Set<Int64>,
        query: String,
        sortType: Int,
        sortDescending: Bool,
        notesMode: Bool,
        store: CollectionStore
    ) throws -> [Int64] {
        guard !selectedIDs.isEmpty else { return [] }
        return try allRowIDs(
            query: query,
            sortType: sortType,
            sortDescending: sortDescending,
            notesMode: notesMode,
            store: store
        ).filter { selectedIDs.contains($0) }
    }

    static func targetCardIDs(_ rowIDs: [Int64], notesMode: Bool, store: CollectionStore) throws -> [Int64] {
        guard notesMode else { return rowIDs }
        let noteIDs = try store.noteIDs(ofCards: rowIDs)
        return try store.cardIDs(ofNotes: noteIDs)
    }
}

private struct BrowserSearchRequestModifier: ViewModifier {
    @EnvironmentObject private var store: CollectionStore
    let action: (BrowserSearchRequest) -> Void

    func body(content: Content) -> some View {
        content.task(id: store.browserSearchRequest?.id) {
            guard let request = store.browserSearchRequest else { return }
            action(request)
            store.consumeBrowserSearchRequest(id: request.id)
        }
    }
}

// MARK: - Sort / Filter

enum BrowserSort: CaseIterable, Hashable {
    case sortField, due, created, modified, interval, deck, ease, reps, lapses, template, noteType, tags, originalPosition, stability, difficulty, retrievability

    static func fromStoredBrowserSortType(_ sortType: Int) -> BrowserSort {
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
        case 10: .template
        case 11: .noteType
        case 12: .tags
        case 13: .originalPosition
        case 20: .stability
        case 21: .difficulty
        case 22: .retrievability
        default: .sortField
        }
    }

    var sortValue: Int {
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
        case .template: 10
        case .noteType: 11
        case .tags: 12
        case .originalPosition: 13
        case .stability: 20
        case .difficulty: 21
        case .retrievability: 22
        }
    }

    func sortValue(notesMode: Bool) -> Int {
        if self == .modified && !notesMode { return 9 }
        if notesMode {
            switch self {
            case .deck: return 23
            case .due: return 15
            case .interval: return 16
            case .ease: return 17
            case .reps: return 18
            case .lapses: return 19
            case .template: return 14
            default: break
            }
        }
        return sortValue
    }

    var defaultDescending: Bool {
        switch self {
        case .sortField, .deck, .noteType, .tags: false
        case .due, .created, .modified, .interval, .ease, .reps, .lapses, .template, .originalPosition,
             .stability, .difficulty, .retrievability: true
        }
    }

    var supportsNotesMode: Bool {
        switch self {
        case .stability, .difficulty, .retrievability: false
        default: true
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .sortField: "Campo de ordenação"
        case .due: "Vencimento"
        case .created: "Criado"
        case .modified: "Modificado"
        case .interval: "Intervalo"
        case .deck: "browser.column.deck"
        case .ease: "Facilidade"
        case .reps: "browser.review-count"
        case .lapses: "Falhas"
        case .template: "browser.cards-mode"
        case .noteType: "Tipo de nota"
        case .tags: "Etiquetas"
        case .originalPosition: "Posição original"
        case .stability: "Estabilidade FSRS"
        case .difficulty: "Dificuldade FSRS"
        case .retrievability: "Retenção prevista"
        }
    }

    func ankiColumn(notesMode: Bool) -> String {
        switch self {
        case .sortField: "noteFld"
        case .due: "cardDue"
        case .created: "noteCrt"
        case .modified: notesMode ? "noteMod" : "cardMod"
        case .interval: "cardIvl"
        case .deck: "deck"
        case .ease: "cardEase"
        case .reps: "cardReps"
        case .lapses: "cardLapses"
        case .template: "template"
        case .noteType: "note"
        case .tags: "noteTags"
        case .originalPosition: "originalPosition"
        case .stability: "stability"
        case .difficulty: "difficulty"
        case .retrievability: "retrievability"
        }
    }

    static func fromAnkiColumn(_ column: String) -> BrowserSort? {
        switch column {
        case "noteFld": .sortField
        case "cardDue": .due
        case "noteCrt": .created
        case "cardMod", "noteMod": .modified
        case "cardIvl": .interval
        case "deck": .deck
        case "cardEase": .ease
        case "cardReps": .reps
        case "cardLapses": .lapses
        case "template": .template
        case "note": .noteType
        case "noteTags": .tags
        case "originalPosition": .originalPosition
        case "stability": .stability
        case "difficulty": .difficulty
        case "retrievability": .retrievability
        default: nil
        }
    }

    static func preference(from conf: [String: Any], notesMode: Bool) -> (sortKey: BrowserSort, descending: Bool) {
        let sortTypeKey = notesMode ? "noteSortType" : "sortType"
        let directionKey = notesMode ? "browserNoteSortBackwards" : "sortBackwards"
        let officialSort = (conf[sortTypeKey] as? String).flatMap(fromAnkiColumn)
        let legacySort = notesMode
            ? (conf["browserNoteSortType"] as? Int ?? conf["browserSortType"] as? Int)
            : (conf["browserSortType"] as? Int ?? conf["sortType"] as? Int)
        let sortKey = officialSort ?? fromStoredBrowserSortType(legacySort ?? 0)
        let legacyDirection = notesMode
            ? (conf["browserNoteSortDescending"] as? Bool ?? conf["browserSortDescending"] as? Bool)
            : (conf["browserSortDescending"] as? Bool)
        let descending = conf[directionKey] as? Bool ?? legacyDirection ?? sortKey.defaultDescending
        return (sortKey, descending)
    }

    static func savePreference(_ sortKey: BrowserSort, descending: Bool, notesMode: Bool, into conf: inout [String: Any]) {
        conf[notesMode ? "noteSortType" : "sortType"] = sortKey.ankiColumn(notesMode: notesMode)
        conf[notesMode ? "browserNoteSortBackwards" : "sortBackwards"] = descending
        if !notesMode {
            conf.removeValue(forKey: "browserSortType")
            conf.removeValue(forKey: "browserSortDescending")
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

    static func localizedName(_ flag: Int) -> LocalizedStringKey {
        LocalizedStringKey(name(flag))
    }
}

extension Rating {
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .again: "De novo"
        case .hard: "Difícil"
        case .good: "Bom"
        case .easy: "Fácil"
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
        case .isNew: String(localized: "browser.card-state.new")
        case .isLearn: String(localized: "browser.card-state.learning")
        case .isReview: String(localized: "browser.card-state.review")
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

    var localizedTitle: Text {
        switch self {
        case .all: Text("Todos")
        case .dueToday: Text("A revisar agora")
        case .addedToday: Text("Adicionados hoje")
        case .studiedToday: Text("Estudados hoje")
        case .flag(let n): Text(AnkiFlagColor.localizedName(n))
        case .isNew: Text("browser.card-state.new")
        case .isLearn: Text("browser.card-state.learning")
        case .isReview: Text("browser.card-state.review")
        case .isSuspended: Text("Suspenso")
        case .isBuried: Text("Oculto")
        case .isMarked: Text("Marcado")
        case .isLeech: Text("Leech")
        case .noFlag: Text("Sem bandeira")
        case .deck(let name): Text(verbatim: name.components(separatedBy: "::").last ?? name)
        case .noteType(let name), .tag(let name): Text(verbatim: name)
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
    var columns: Set<String> = ["question", "answer", "type", "deck", "due", "tags"]
    var notesMode = false
    var selectionMode = false
    @EnvironmentObject private var store: CollectionStore

    var body: some View {
        HStack(spacing: 10) {
            if selectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AppTheme.accent : AppTheme.secondaryText)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                if columns.contains("question") {
                    Text(browserQuestionText)
                        .font(.headline)
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(1)
                }
                HStack(spacing: 10) {
                    ForEach(columns.filter { $0 != "question" }.sorted(), id: \.self) { column in
                        if let value = columnValue(column) {
                            HStack(spacing: 0) {
                                columnTitle(column)
                                Text(verbatim: ": \(value)")
                            }
                                .font(.caption2)
                                .foregroundStyle(column == "type" ? AppTheme.mist : AppTheme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    queueLabel
                }
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

    static func flagColor(_ flag: Int) -> Color {
        switch flag {
        case 1: .red
        case 2: .orange
        case 3: .green
        case 4: .blue
        case 5: .pink
        case 6: .cyan
        case 7: .purple
        default: .white
        }
    }

    private func columnTitle(_ column: String) -> Text {
        switch column {
        case "question": return Text("browser.question-column")
        case "answer": return Text("Resposta")
        case "type": return notesMode ? Text("browser.cards-mode") : Text("Cartão")
        case "noteType": return Text("Tipo de nota")
        case "deck": return Text("browser.column.deck")
        case "due": return Text("Vencimento")
        case "interval": return Text("Intervalo")
        case "ease": return Text("Facilidade")
        case "reps": return Text("browser.review-count")
        case "lapses": return Text("Falhas")
        case "tags": return Text("Etiquetas")
        case "created": return Text("Criado")
        case "cardModified": return Text("Cartão modificado")
        case "noteModified": return Text("Nota modificada")
        case "cardCount": return Text("browser.cards-mode")
        case "sortField": return Text("Campo de ordenação")
        case "originalPosition": return Text("Posição original")
        case "stability": return Text("Estabilidade FSRS")
        case "difficulty": return Text("Dificuldade FSRS")
        case "retrievability": return Text("Retenção prevista")
        default:
            if column.hasPrefix("field:") {
                return Text(verbatim: String(column.dropFirst("field:".count)))
            }
            return Text(LocalizedStringKey(column))
        }
    }

    private func columnValue(_ column: String) -> String? {
        switch column {
        case "question": return browserQuestionText
        case "answer": return browserAnswerText
        case "type": return notesMode ? String(row.cardCount) : cardTypeLabel
        case "noteType": return row.notetypeName
        case "deck":
            if notesMode && row.deckCount > 1 { return "\(row.deckCount) baralhos" }
            if let originalDeckName = row.originalDeckName { return "\(row.deckName) (\(originalDeckName))" }
            return row.deckName
        case "due":
            if notesMode {
                guard let due = row.nextDueTimestamp else { return nil }
                return Date(timeIntervalSince1970: TimeInterval(due)).formatted(date: .abbreviated, time: .omitted)
            }
            if row.card.odid != 0 { return "Filtrado" }
            if row.card.type == 0 {
                let position = String(row.card.due)
                return row.card.queue < 0 ? "[\(position)]" : position
            }
            let dueTimestamp: Int64
            if row.card.queue == 1 || row.card.queue == 4 {
                dueTimestamp = Int64(row.card.due)
            } else {
                let base = store.schedDayStartTimestamp() - Int64(store.schedDay()) * 86_400
                dueTimestamp = base + Int64(row.card.due) * 86_400
            }
            let date = Date(timeIntervalSince1970: TimeInterval(dueTimestamp)).formatted(date: .abbreviated, time: .omitted)
            return row.card.queue < 0 ? "[\(date)]" : date
        case "interval":
            if !notesMode {
                if row.card.type == 0 { return String(localized: "browser.card-state.new") }
                if row.card.type == 1 { return "Aprendendo" }
            }
            let interval = notesMode ? row.averageInterval : Double(row.card.ivl)
            guard let interval else { return nil }
            return "\(Int(interval.rounded()))d"
        case "ease":
            if !notesMode && row.card.type == 0 { return String(localized: "browser.card-state.new") }
            let factor = notesMode ? row.averageEase : Double(row.card.factor)
            guard let factor else { return nil }
            return "\(Int(factor / 10))%"
        case "reps": return String(notesMode ? row.totalReps : row.card.reps)
        case "lapses": return String(notesMode ? row.totalLapses : row.card.lapses)
        case "tags": return row.note.tagList.isEmpty ? nil : row.note.tagList.joined(separator: " ")
        case "created": return Date(timeIntervalSince1970: Double(row.note.id) / 1000).formatted(date: .abbreviated, time: .omitted)
        case "cardModified": return formattedTimestamp(notesMode ? row.latestCardMod : row.card.mod)
        case "noteModified": return formattedTimestamp(row.note.mod)
        case "cardCount": return notesMode ? String(row.cardCount) : nil
        case "sortField": return row.note.sfld.isEmpty ? nil : row.note.sfld
        case "originalPosition":
            let position = FSRSCardData.originalPosition(in: row.card.data) ?? (row.card.type == 0 ? row.card.due : nil)
            return position.map(String.init)
        case "stability":
            guard let memory = FSRSCardData.memory(in: row.card.data) else { return nil }
            return String(format: "%.1f dias", Double(memory.stability))
        case "difficulty":
            guard let memory = FSRSCardData.memory(in: row.card.data) else { return nil }
            return String(format: "%.0f%%", Double(FSRS6.shiftedDifficulty(memory.difficulty) * 100))
        case "retrievability":
            guard let value = store.browserRetrievability(for: row.card) else { return nil }
            return String(format: "%.0f%%", Double(value * 100))
        default:
            guard column.hasPrefix("field:"),
                  let type = store.notetype(id: row.note.mid),
                  let index = type.flds.firstIndex(where: { $0.name == String(column.dropFirst("field:".count)) }),
                  row.note.fields.indices.contains(index) else { return nil }
            let value = row.note.fields[index]
            return value.isEmpty ? nil : value
        }
    }

    private func formattedTimestamp(_ timestamp: Int64) -> String {
        guard timestamp > 0 else { return "—" }
        return Date(timeIntervalSince1970: TimeInterval(timestamp)).formatted(date: .abbreviated, time: .omitted)
    }

    /// Prefer Anki browser question template (`bqfmt`) when present.
    private var browserQuestionText: String {
        guard let nt = store.notetype(id: row.note.mid),
              let tmpl = nt.tmpls.first(where: { $0.ord == row.card.ord }) ?? nt.tmpls.first,
              !tmpl.bqfmt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return row.note.sfld
        }
        var fields = TemplateEngine.fieldMap(note: row.note, notetype: nt, deckName: row.templateDeckName)
        TemplateEngine.addCardFields(to: &fields, name: tmpl.name, flag: row.card.flags, id: row.card.id, ordinal: row.card.ord)
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

    private var browserAnswerText: String {
        guard let notetype = store.notetype(id: row.note.mid),
              let template = notetype.tmpls.first(where: { $0.ord == row.card.ord }) ?? notetype.tmpls.first else { return "" }
        if !template.bafmt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var fields = TemplateEngine.fieldMap(note: row.note, notetype: notetype, deckName: row.templateDeckName)
            TemplateEngine.addCardFields(to: &fields, name: template.name, flag: row.card.flags, id: row.card.id, ordinal: row.card.ord)
            fields["Card"] = template.name
            fields["CardFlag"] = "flag\(row.card.flags & 7)"
            fields["CardID"] = String(row.card.id)
            fields["c\(row.card.ord + 1)"] = "1"
            let questionTemplate = template.bqfmt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? row.note.sfld
                : TemplateEngine.render(
                    template: template.bqfmt,
                    fields: fields,
                    clozeOrd: notetype.isCloze ? row.card.ord : nil,
                    questionSide: true,
                    omitTypeInput: true
                )
            let answerHTML = TemplateEngine.render(
                template: template.bafmt,
                fields: fields,
                frontSide: questionTemplate,
                clozeOrd: notetype.isCloze ? row.card.ord : nil,
                questionSide: false,
                omitTypeInput: true
            )
            let rendered = answerHTML
                .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let question = browserQuestionText
            if !question.isEmpty, rendered.hasPrefix(question) {
                return String(rendered.dropFirst(question.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return rendered
        }
        let rendered = CardHTMLRenderer.renderCard(
            note: row.note,
            card: row.card,
            notetype: notetype,
            side: .answer,
            mediaBase: store.mediaRoot,
            deckName: row.templateDeckName
        ).plainText
        let question = browserQuestionText
        guard !question.isEmpty, rendered.hasPrefix(question) else { return rendered }
        return String(rendered.dropFirst(question.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var queueLabel: some View {
        HStack(spacing: 6) {
            if row.card.flags > 0 {
                Image(systemName: "flag.fill")
                    .foregroundStyle(Self.flagColor(row.card.flags))
                    .font(.caption2)
            }
            switch row.card.queue {
            case 0: Text("browser.card-state.new").foregroundStyle(AppTheme.easy)
            case 1, 3: Text("browser.card-state.learning").foregroundStyle(AppTheme.danger)
            case 2: Text("revisar").foregroundStyle(AppTheme.good)
            case -1: Text("suspenso").foregroundStyle(AppTheme.danger)
            default: Text("oculto").foregroundStyle(AppTheme.secondaryText)
            }
        }
    }

}

struct CardPreviewSheet: View {
    let row: CollectionStore.BrowserRow
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
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
                        mediaBase: store.mediaRoot,
                        deckName: row.templateDeckName,
                        nightMode: colorScheme == .dark
                    )
                    CardWebView(
                        html: result.html,
                        baseURL: store.mediaRoot,
                        onSoundTap: { store.mediaStore.play($0) },
                        onSpeechTap: { request in store.mediaStore.speak(request) }
                    )
                    .padding()
                }
            }
            .navigationTitle("Pré-visualização")
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button("Fechar") { dismiss() }
                        .accessibilityIdentifier("browser.preview.close")
                        .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.18, expands: true))
                    Button(showAnswer ? "Pergunta" : "Resposta") { showAnswer.toggle() }
                        .accessibilityIdentifier("browser.preview.toggleAnswer")
                        .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.42, expands: true))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
        }
    }
}

struct FindReplaceSheet: View {
    let noteIDs: [Int64]
    let selectedFieldNames: [String]
    let allFieldNames: [String]
    let onComplete: (Int) -> Void
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.dismiss) private var dismiss
    @State private var find = ""
    @State private var replace = ""
    @State private var target = 0
    @State private var selectedField = ""
    @State private var selectedOnly = true
    @State private var regularExpression = false
    @State private var matchCase = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        GlassFormSection(title: "Localizar e substituir") {
                            Picker("Onde", selection: $target) {
                                Text("browser.find-replace.fields").tag(0)
                                Text("Etiquetas").tag(1)
                            }
                            .pickerStyle(.segmented)
                            if target == 0 {
                                Picker("browser.field-label", selection: $selectedField) {
                                    Text("Todos os campos").tag("")
                                    ForEach(selectedOnly ? selectedFieldNames : allFieldNames, id: \.self) { field in
                                        Text(field).tag(field)
                                    }
                                }
                                .pickerStyle(.menu)
                            }
                            Toggle("Somente notas selecionadas", isOn: $selectedOnly)
                            TextField(target == 0 ? "Texto para localizar" : "Texto na etiqueta", text: $find)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .ankiGlass(tint: .white.opacity(0.08), interactive: true, in: RoundedRectangle(cornerRadius: 12))
                            TextField(target == 0 ? "Substituir nos campos" : "Nova etiqueta (vazio remove)", text: $replace)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .ankiGlass(tint: .white.opacity(0.08), interactive: true, in: RoundedRectangle(cornerRadius: 12))
                            Toggle("Expressão regular", isOn: $regularExpression)
                            Toggle("Diferenciar maiúsculas/minúsculas", isOn: $matchCase)
                            Text(target == 0 ? "A busca considera o campo escolhido nas notas afetadas." : "A busca percorre as etiquetas das notas afetadas; a substituição pode criar mais de uma etiqueta ou remover a etiqueta correspondente.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                        Text(selectedOnly ? "Notas selecionadas: \(noteIDs.count)" : "Aplicar a toda a coleção")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    .padding(20)
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                HStack(spacing: 12) {
                    Button("Cancelar") { dismiss() }
                        .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.18, expands: true))
                    Button("Substituir") { apply() }
                        .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.42, expands: true))
                        .disabled(find.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (selectedOnly && noteIDs.isEmpty))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .background(AppBackground())
            .navigationTitle("Localizar e substituir")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(macOS)
            .frame(minWidth: 440, minHeight: 340)
            #endif
        }
    }

    private func apply() {
        do {
            let affectedNoteIDs = selectedOnly ? noteIDs : try store.allNoteIDs()
            let snapshot = try store.makeBrowserUndoSnapshot(
                noteIDs: affectedNoteIDs,
                message: target == 0 ? "Texto substituído" : "Etiquetas substituídas"
            )
            let count = target == 0
                ? try store.findReplaceFields(
                    noteIDs: affectedNoteIDs,
                    find: find,
                    replace: replace,
                    fieldName: selectedField.isEmpty ? nil : selectedField,
                    regularExpression: regularExpression,
                    matchCase: matchCase
                )
                : try store.findReplaceTags(
                    noteIDs: affectedNoteIDs,
                    find: find,
                    replace: replace,
                    regularExpression: regularExpression,
                    matchCase: matchCase
                )
            if count > 0 { store.registerBrowserUndo(snapshot) }
            onComplete(count)
            dismiss()
        } catch {
            store.lastError = error.localizedDescription
        }
    }
}

struct FindDuplicatesSheet: View {
    let fieldNames: [String]
    let selectedNoteIDs: Set<Int64>
    let initialQuery: String
    let onSelect: ([Int64]) -> Void
    let onComplete: () -> Void

    @EnvironmentObject private var store: CollectionStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedField: String
    @State private var searchQuery: String
    @State private var selectedOnly: Bool
    @State private var groups: [CollectionStore.DuplicateNoteGroup] = []
    @State private var message: String?

    init(
        fieldNames: [String],
        selectedNoteIDs: Set<Int64>,
        initialQuery: String,
        onSelect: @escaping ([Int64]) -> Void,
        onComplete: @escaping () -> Void
    ) {
        self.fieldNames = fieldNames
        self.selectedNoteIDs = selectedNoteIDs
        self.initialQuery = initialQuery
        self.onSelect = onSelect
        self.onComplete = onComplete
        _selectedField = State(initialValue: fieldNames.first ?? "")
        _searchQuery = State(initialValue: initialQuery)
        _selectedOnly = State(initialValue: !selectedNoteIDs.isEmpty)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        GlassFormSection(title: "Duplicatas") {
                            Picker("browser.field-label", selection: $selectedField) {
                                ForEach(fieldNames, id: \.self) { field in
                                    Text(field).tag(field)
                                }
                            }
                            .pickerStyle(.menu)
                            TextField("Filtro de busca (opcional)", text: $searchQuery)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .ankiGlass(tint: .white.opacity(0.08), interactive: true, in: RoundedRectangle(cornerRadius: 12))
                            Toggle("Somente notas selecionadas", isOn: $selectedOnly)
                                .disabled(selectedNoteIDs.isEmpty)
                            Button("Buscar") { find() }
                                .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.42, expands: true))
                                .disabled(selectedField.isEmpty || (selectedOnly && selectedNoteIDs.isEmpty))
                        }
                        if !groups.isEmpty {
                            Button("Marcar todas com a etiqueta duplicate") { markDuplicates() }
                                .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.16, expands: true))
                            ForEach(groups) { group in
                                GlassOptionRow(title: "\(group.noteIDs.count) notas") {
                                    Button("Selecionar") {
                                        onSelect(group.noteIDs)
                                        dismiss()
                                    }
                                    .buttonStyle(GlassChipButtonStyle())
                                }
                                Text(group.value)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.secondaryText)
                                    .padding(.horizontal, 5)
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                Button("Fechar") { dismiss() }
                    .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.18, expands: true))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
            }
            .background(AppBackground())
            .navigationTitle("Encontrar duplicatas")
            .alert("Duplicatas", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
        }
    }

    private func find() {
        do {
            groups = try store.duplicateNoteGroups(
                fieldName: selectedField,
                searchQuery: searchQuery,
                selectedNoteIDs: selectedOnly ? selectedNoteIDs : nil
            )
            if groups.isEmpty { message = "Nenhuma duplicata encontrada neste campo." }
        } catch {
            message = error.localizedDescription
        }
    }

    private func markDuplicates() {
        let noteIDs = Array(Set(groups.flatMap(\.noteIDs)))
        do {
            let snapshot = try store.makeBrowserUndoSnapshot(noteIDs: noteIDs, message: "Notas duplicadas marcadas")
            try store.addTag(to: noteIDs, tag: "duplicate")
            store.registerBrowserUndo(snapshot)
            message = "\(noteIDs.count) notas marcadas com duplicate."
            onComplete()
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct GradeNowView: View {
    let answerKeys: [Int: String]
    let onGrade: (Rating) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                VStack(spacing: 12) {
                    ForEach(Rating.allCases, id: \.self) { rating in
                        Button(rating.localizedTitle) {
                            onGrade(rating)
                            dismiss()
                        }
                        .buttonStyle(GlassButtonStyle(tint: tint(for: rating), expands: true))
                    }
                }
                .padding(20)
                .frame(maxWidth: 440)
            }
            .background {
                Group {
                    ForEach(Rating.allCases, id: \.self) { rating in
                        if let shortcut = keyboardShortcut(for: rating) {
                            Button("") {
                                onGrade(rating)
                                dismiss()
                            }
                            .keyboardShortcut(shortcut)
                        }
                    }
                }
                .opacity(0.001)
                .frame(width: 0, height: 0)
            }
            .navigationTitle("Avaliar agora")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 300)
        #endif
    }

    private func tint(for rating: Rating) -> Color {
        switch rating {
        case .again: AppTheme.danger
        case .hard: AppTheme.warn
        case .good: AppTheme.good
        case .easy: AppTheme.easy
        }
    }

    private func keyboardShortcut(for rating: Rating) -> KeyboardShortcut? {
        guard let value = answerKeys[rating.rawValue] else { return nil }
        let parts = value.split(separator: "+").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let keyText = parts.last, !keyText.isEmpty else { return nil }
        var modifiers: EventModifiers = []
        for part in parts.dropLast() {
            switch part.lowercased() {
            case "ctrl", "control": modifiers.insert(.control)
            case "alt", "option": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            case "cmd", "command", "meta": modifiers.insert(.command)
            default: return nil
            }
        }
        let key: KeyEquivalent
        switch keyText.lowercased() {
        case "space": key = .space
        case "return", "enter": key = .return
        case "tab": key = .tab
        case "delete", "backspace": key = .delete
        case "escape", "esc": key = .escape
        default:
            guard keyText.count == 1, let character = keyText.first else { return nil }
            key = KeyEquivalent(character)
        }
        return KeyboardShortcut(key, modifiers: modifiers)
    }
}
