import SwiftUI
import UniformTypeIdentifiers

struct DecksHomeView: View {
    @EnvironmentObject private var store: CollectionStore
    @State private var path = NavigationPath()
    @State private var showImport = false
    @State private var showCSVImport = false
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
                                renameText = $0.displayName
                            },
                            onOptions: { optionsDeck = $0 },
                            onCustomStudy: { customStudyDeck = $0 },
                            onExport: { exportDeck($0) },
                            onDelete: { try? store.deleteDeck($0) },
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
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await store.syncWithICloud() }
                    } label: {
                        Image(systemName: store.iCloudSyncing ? "arrow.triangle.2.circlepath" : "icloud")
                    }
                    .disabled(store.iCloudSyncing)
                    .accessibilityLabel(store.iCloudSyncing ? "Sincronizando" : "Sincronizar com iCloud")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Importar .apkg", systemImage: "square.and.arrow.down") { showImport = true }
                        Button("Importar CSV", systemImage: "tablecells") { showCSVImport = true }
                        Button("Novo baralho", systemImage: "folder.badge.plus") {
                            newDeckParent = nil
                            showNewDeck = true
                        }
                        Button("Baralho filtrado", systemImage: "line.3.horizontal.decrease.circle") {
                            if let created = try? store.createFilteredDeck() {
                                optionsDeck = created
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
                    .glassMenuToolbar(prominent: true)
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
            allowedContentTypes: [.ankiApkg, .ankiColpkg, .archive, .data],
            allowsMultipleSelection: false
        ) { result in
            Task {
                do {
                    guard let url = try result.get().first else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let msg = try await ApkgImporter(store: store).importPackage(at: url)
                    store.lastError = msg
                } catch {
                    store.lastError = error.localizedDescription
                }
            }
        }
        .fileImporter(isPresented: $showCSVImport, allowedContentTypes: [.commaSeparatedText, .plainText, .text, .data], allowsMultipleSelection: false) { result in
            Task {
                do {
                    guard let url = try result.get().first else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let n = try CSVImporter(store: store).importFile(at: url)
                    store.lastError = "CSV: \(n) nota(s) importada(s)."
                } catch {
                    store.lastError = error.localizedDescription
                }
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
        .alert("Novo baralho", isPresented: $showNewDeck) {
            TextField("Nome", text: $newDeckName)
            Button("Criar") {
                try? store.createDeck(name: newDeckName, parent: newDeckParent)
                newDeckParent = nil
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
                    try? store.renameDeck(d, to: renameText)
                }
                renameTarget = nil
            }
            Button("Cancelar", role: .cancel) { renameTarget = nil }
        }
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
            if let exportURL {
                ShareSheet(items: [exportURL])
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ankiTriggerStudyMain)) { _ in
            if let main = store.recommendedStudyDeck {
                studyDeck = main
            } else if let first = rootDecks.first(where: { $0.name != "Default" }) ?? rootDecks.first {
                studyDeck = first
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ankiTriggerImportApkg)) { _ in
            showImport = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .ankiTriggerImportCSV)) { _ in
            showCSVImport = true
        }
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
        try? store.saveDecks(decks)
    }
}

enum EditorRoute: Hashable {
    case add
    case edit(Int64)
    case noteTypes
}
