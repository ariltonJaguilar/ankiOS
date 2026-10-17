import SwiftUI
import UniformTypeIdentifiers

struct DecksHomeView: View {
    @Binding var studyRequested: Bool
    @EnvironmentObject private var store: CollectionStore
    @State private var path = NavigationPath()
    @State private var showImport = false
    @State private var showCSVImport = false
    @State private var pendingCSVName: String?
    @State private var pendingCSVText: String?
    @State private var showNewDeck = false
    @State private var newDeckName = ""
    @State private var renameTarget: AnkiDeck?
    @State private var renameText = ""
    @State private var studyDeck: AnkiDeck?
    @State private var optionsDeck: AnkiDeck?
    @State private var customStudyDeck: AnkiDeck?
    @State private var pendingSession: AnkiDeck?
    @State private var exportDeck: AnkiDeck?
    @State private var exportURL: URL?
    @State private var newDeckParent: AnkiDeck?
    @State private var deleteTarget: AnkiDeck?
    @State private var pendingCollectionPackage: URL?
    @State private var pendingCollectionPackageScoped = false
    @State private var showRestoreCollectionConfirm = false
    @State private var restoringCollectionPackage = false
    @State private var pendingDeckPackage: URL?
    @State private var pendingDeckPackageScoped = false
    @State private var showDeckImportOptions = false
    @State private var importingDeckPackage = false

    init(studyRequested: Binding<Bool> = .constant(false)) {
        _studyRequested = studyRequested
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 12) {
                    header
                    ForEach(visibleDeckRows) { row in
                        DeckRowView(
                            deck: row.deck,
                            counts: store.deckCounts[row.deck.id] ?? .init(new: 0, learn: 0, review: 0),
                            depth: row.depth,
                            onStudy: { studyDeck = $0 },
                            onRename: {
                                renameTarget = $0
                                renameText = $0.name
                            },
                            onOptions: { optionsDeck = $0 },
                            onCustomStudy: { customStudyDeck = $0 },
                            onExport: { exportDeck($0) },
                            onDelete: { deleteTarget = $0 },
                            onAddSubdeck: { parent in
                                newDeckName = ""
                                renameTarget = nil
                                newDeckParent = parent
                                showNewDeck = true
                            }
                        )
                    }
                }
                .padding()
            }
            .navigationTitle("AnkiOS")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                #if os(macOS)
                let syncPlacement: ToolbarItemPlacement = .navigation
                #else
                let syncPlacement: ToolbarItemPlacement = .topBarLeading
                #endif
                ToolbarItem(placement: syncPlacement) {
                    Menu {
                        #if !ANKIOS_PARITY_HARNESS
                        Button("Sincronizar com AnkiWeb", systemImage: "arrow.triangle.2.circlepath") {
                            Task { await store.syncWithAnkiWeb() }
                        }
                        Divider()
                        #endif
                        Button("Sincronizar com iCloud", systemImage: "icloud") {
                            Task { await store.syncWithICloud() }
                        }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .disabled(store.collectionSyncing)
                    .accessibilityLabel(store.collectionSyncing ? "Sincronizando" : "Opções de sincronização")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Importar coleção…", systemImage: "square.and.arrow.down") { showImport = true }
                        Button("Importar CSV", systemImage: "tablecells") { showCSVImport = true }
                        Button("Novo baralho", systemImage: "folder.badge.plus") {
                            newDeckParent = nil
                            showNewDeck = true
                        }
                        Button("Baralho filtrado", systemImage: "line.3.horizontal.decrease.circle") {
                            do {
                                let created = try store.createFilteredDeck()
                                optionsDeck = created
                            } catch {
                                store.lastError = error.localizedDescription
                            }
                        }
                        Button("Adicionar nota", systemImage: "plus.circle") {
                            path.append(EditorRoute.add)
                        }
                        Button("Tipos de nota", systemImage: "doc.badge.gearshape") {
                            path.append(EditorRoute.noteTypes)
                        }
                        Divider()
                        Button("Recolher todos", systemImage: "rectangle.compress.vertical") {
                            collapseAll(true)
                        }
                        Button("Expandir todos", systemImage: "rectangle.expand.vertical") {
                            collapseAll(false)
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Ações dos baralhos")
                }
            }
            .navigationDestination(for: EditorRoute.self) { route in
                switch route {
                case .add:
                    NoteEditorView(mode: .add)
                case .edit(let noteID):
                    NoteEditorView(mode: .edit(noteID))
                case .noteTypes:
                    NoteTypesView()
                }
            }
        }
        .fileImporter(
            isPresented: $showImport,
            allowedContentTypes: [.ankiApkg, .ankiColpkg, .mnemosyneDB, .archive, .data],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                receivePackage(at: url)
            } catch {
                store.lastError = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $showCSVImport, allowedContentTypes: [.commaSeparatedText, .plainText, .text, .data], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let importedText = try String(contentsOf: url, encoding: .utf8)
                pendingCSVName = url.lastPathComponent
                pendingCSVText = importedText
            } catch {
                store.lastError = error.localizedDescription
            }
        }
        .sheet(isPresented: Binding(get: { pendingCSVText != nil }, set: { if !$0 { pendingCSVText = nil; pendingCSVName = nil } })) {
            if let pendingCSVText {
                CSVImportReviewView(fileName: pendingCSVName ?? "Texto", text: pendingCSVText, store: store)
                    .environmentObject(store)
            }
        }
        .sheet(item: $studyDeck) { deck in
            DeckOverviewView(deck: deck)
                .environmentObject(store)
        }
        .sheet(item: $optionsDeck) { deck in
            DeckOptionsView(deck: deck)
                .environmentObject(store)
        }
        .sheet(item: $customStudyDeck, onDismiss: {
            if let pending = pendingSession {
                pendingSession = nil
                studyDeck = pending
            }
        }) { deck in
            CustomStudyView(deck: deck) { pendingSession = $0 }
                .environmentObject(store)
        }
        .sheet(isPresented: $showDeckImportOptions) {
            ApkgImportOptionsSheet { withScheduling, withDeckConfigs, mergeNotetypes, updateNotes, updateNotetypes in
                importingDeckPackage = true
                showDeckImportOptions = false
                Task {
                    await importPendingDeckPackage(
                        withScheduling: withScheduling,
                        withDeckConfigs: withDeckConfigs,
                        mergeNotetypes: mergeNotetypes,
                        updateNotes: updateNotes,
                        updateNotetypes: updateNotetypes
                    )
                }
            }
        }
        .alert("Novo baralho", isPresented: $showNewDeck) {
            TextField("Nome", text: $newDeckName)
            Button("Criar") {
                guard !newDeckName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                do {
                    try store.createDeck(name: newDeckName, parent: newDeckParent)
                    newDeckParent = nil
                } catch {
                    store.lastError = error.localizedDescription
                }
            }
            Button("Cancelar", role: .cancel) { newDeckParent = nil }
        }
        .alert("Renomear baralho", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Nome", text: $renameText)
            Button("Renomear") {
                if let d = renameTarget {
                    do { try store.renameDeck(d, to: renameText) }
                    catch { store.lastError = error.localizedDescription }
                }
                renameTarget = nil
            }
            Button("Cancelar", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(
            deleteTarget.map { "Apagar \($0.displayName)?" } ?? "Apagar baralho?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            if deleteTarget?.isFiltered == true {
                Button("Apagar filtrado e devolver cartões") { deleteDeck(cardsToo: false) }
            } else {
                Button("Apagar baralho", role: .destructive) { deleteDeck(cardsToo: true) }
            }
            Button("Cancelar", role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteTarget?.isFiltered == true
                 ? "Os cartões voltam aos baralhos de origem."
                 : "Os cartões dos subbaralhos também serão apagados.")
        }
        .confirmationDialog(
            "Restaurar coleção do .colpkg?",
            isPresented: $showRestoreCollectionConfirm,
            titleVisibility: .visible
        ) {
            Button("Substituir coleção", role: .destructive) {
                restoringCollectionPackage = true
                Task {
                    await restorePendingCollectionPackage()
                    restoringCollectionPackage = false
                }
            }
            Button("Cancelar", role: .cancel) {
                showRestoreCollectionConfirm = false
                releasePendingCollectionPackage()
            }
        } message: {
            Text("A coleção atual será substituída. O app salvará um backup e manterá a mídia existente.")
        }
        .onChange(of: showRestoreCollectionConfirm) { _, isPresented in
            if !isPresented && !restoringCollectionPackage {
                releasePendingCollectionPackage()
            }
        }
        .onChange(of: showDeckImportOptions) { _, isPresented in
            if !isPresented && !importingDeckPackage {
                releasePendingDeckPackage()
            }
        }
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
            if let exportURL {
                ShareSheet(items: [exportURL])
            }
        }
        .onAppear(perform: consumeStudyRequest)
        .onChange(of: studyRequested) { _, _ in consumeStudyRequest() }
        .onChange(of: store.isBootstrapping) { _, _ in consumeStudyRequest() }
        .onChange(of: store.collectionSyncing) { _, _ in consumeStudyRequest() }
        .onChange(of: store.pendingPackageImport) { _, url in
            guard let url else { return }
            store.pendingPackageImport = nil
            receivePackage(at: url)
        }
    }

    private func consumeStudyRequest() {
        guard studyRequested, !store.isBootstrapping, !store.collectionSyncing else { return }
        studyRequested = false
        studyDeck = store.currentDeckID().flatMap { store.deck(id: $0) }
            ?? store.recommendedStudyDeck
            ?? rootDecks.first(where: { $0.name != "Default" })
            ?? rootDecks.first
    }

    private func receivePackage(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        if url.pathExtension.lowercased() == "colpkg" {
            pendingCollectionPackage = url
            pendingCollectionPackageScoped = scoped
            showRestoreCollectionConfirm = true
            return
        }
        if url.pathExtension.lowercased() == "db" {
            Task {
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    store.lastError = try MnemosyneImporter(store: store).importFile(at: url)
                } catch {
                    store.lastError = error.localizedDescription
                }
            }
            return
        }
        pendingDeckPackage = url
        pendingDeckPackageScoped = scoped
        showDeckImportOptions = true
    }

    private func importPendingDeckPackage(
        withScheduling: Bool,
        withDeckConfigs: Bool,
        mergeNotetypes: Bool,
        updateNotes: PackageUpdateCondition,
        updateNotetypes: PackageUpdateCondition
    ) async {
        guard let url = pendingDeckPackage else { return }
        do {
            store.lastError = try await ApkgImporter(store: store).importPackage(
                at: url,
                withScheduling: withScheduling,
                withDeckConfigs: withDeckConfigs,
                mergeNotetypes: mergeNotetypes,
                updateNotes: updateNotes,
                updateNotetypes: updateNotetypes
            )
        } catch {
            store.lastError = error.localizedDescription
        }
        importingDeckPackage = false
        releasePendingDeckPackage()
    }

    private func releasePendingDeckPackage() {
        if pendingDeckPackageScoped, let pendingDeckPackage {
            pendingDeckPackage.stopAccessingSecurityScopedResource()
        }
        pendingDeckPackage = nil
        pendingDeckPackageScoped = false
    }

    private var header: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Baralhos")
                    .font(AppTheme.titleFont)
                    .foregroundStyle(AppTheme.primaryText)
                Text("Toque num baralho para ver o resumo e estudar.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                let rootTotals = rootDecks.map { store.deckCounts[$0.id] ?? .init(new: 0, learn: 0, review: 0) }
                    .reduce(DeckCounts(new: 0, learn: 0, review: 0)) { DeckCounts(new: $0.new + $1.new, learn: $0.learn + $1.learn, review: $0.review + $1.review) }
                HStack(spacing: 8) {
                    CountChip(label: "Novo", count: rootTotals.new, color: AppTheme.easy)
                    CountChip(label: "Aprender", count: rootTotals.learn, color: AppTheme.danger)
                    CountChip(label: "Revisar", count: rootTotals.review, color: AppTheme.good)
                }
                .padding(.top, 2)
            }
        }
    }

    /// Root decks like Anki: alphabetical, with Default always last.
    private var rootDecks: [AnkiDeck] {
        let roots = store.decks.filter { $0.parentName == nil }
        return roots.sorted { a, b in
            let aDefault = a.name == "Default"
            let bDefault = b.name == "Default"
            if aDefault != bDefault { return !aDefault }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private struct VisibleDeckRow: Identifiable {
        let deck: AnkiDeck
        let depth: Int
        var id: Int64 { deck.id }
    }

    /// Flat deck list like Anki: collapsed parents hide all `parent::…` descendants.
    private var visibleDeckRows: [VisibleDeckRow] {
        var rows: [VisibleDeckRow] = []
        func walk(_ deck: AnkiDeck, depth: Int) {
            rows.append(VisibleDeckRow(deck: deck, depth: depth))
            guard !deck.collapsed else { return }
            let prefix = deck.name + "::"
            for child in store.decks
                .filter({ $0.name.hasPrefix(prefix) && $0.parentName == deck.name })
                .sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
                walk(child, depth: depth + 1)
            }
        }
        for root in rootDecks {
            walk(root, depth: 0)
        }
        return rows
    }

    private func children(of deck: AnkiDeck) -> [AnkiDeck] {
        store.decks
            .filter { $0.parentName == deck.name }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func exportDeck(_ deck: AnkiDeck) {
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(deck.displayName).apkg")
            try ApkgExporter(store: store).export(deckID: deck.id, to: url)
            exportURL = url
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func collapseAll(_ collapsed: Bool) {
        var decks = store.decks
        for i in decks.indices {
            decks[i].collapsed = collapsed
        }
        do { try store.saveDecks(decks) }
        catch { store.lastError = error.localizedDescription }
    }

    private func deleteDeck(cardsToo: Bool) {
        guard let deck = deleteTarget else { return }
        do {
            try store.deleteDeck(deck, cardsToo: cardsToo)
        } catch {
            store.lastError = error.localizedDescription
        }
        deleteTarget = nil
    }

    private func restorePendingCollectionPackage() async {
        guard let url = pendingCollectionPackage else { return }
        do {
            store.lastError = try await ApkgImporter(store: store).importPackage(at: url)
        } catch {
            store.lastError = error.localizedDescription
        }
        releasePendingCollectionPackage()
    }

    private func releasePendingCollectionPackage() {
        if pendingCollectionPackageScoped, let pendingCollectionPackage {
            pendingCollectionPackage.stopAccessingSecurityScopedResource()
        }
        pendingCollectionPackage = nil
        pendingCollectionPackageScoped = false
    }
}

enum EditorRoute: Hashable {
    case add
    case edit(Int64)
    case noteTypes
}
