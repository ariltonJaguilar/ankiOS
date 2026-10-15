import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: CollectionStore
    @State private var showImport = false
    @State private var showCSVImport = false
    @State private var exportURL: URL?
    @State private var rollday: Double = 4
    @State private var schedulerFSRS = false
    @State private var duplicates: [String] = []
    @State private var exportDeckID: Int64?
    @State private var csvDeckID: Int64?
    @State private var csvNotetypeID: Int64?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    GlassFormSection(title: "iCloud") {
                        Button {
                            Task { await store.syncWithICloud() }
                        } label: {
                            Label(
                                store.iCloudSyncing ? "Sincronizando…" : "Sincronizar com iCloud",
                                systemImage: "icloud"
                            )
                        }
                        .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.42, expands: true))
                        .disabled(store.iCloudSyncing)
                        Text("Envia e recebe a coleção e a mídia pela mesma conta iCloud. A versão mais recente de cada perfil fica nos aparelhos.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(.horizontal, 4)
                        if let iCloudStatus = store.iCloudStatus {
                            Text(iCloudStatus)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.good)
                                .padding(.horizontal, 4)
                        }
                    }
                    GlassFormSection(title: "Coleção") {
                        toolButton("Importar .apkg / .colpkg") { showImport = true }
                        toolButton("Importar CSV / texto") { showCSVImport = true }
                        GlassOptionRow(title: "Importar para baralho") {
                            GlassChoiceMenu(
                                selection: $csvDeckID,
                                choices: store.decks.filter { !$0.isFiltered }.map {
                                    GlassChoice(id: Optional($0.id), title: $0.displayName)
                                }
                            )
                        }
                        GlassOptionRow(title: "Tipo de nota (CSV)") {
                            GlassChoiceMenu(
                                selection: $csvNotetypeID,
                                choices: store.notetypes.map {
                                    GlassChoice(id: Optional($0.id), title: $0.name)
                                }
                            )
                        }
                        toolButton("Exportar coleção .apkg") { exportAll() }
                        GlassOptionRow(title: "Exportar baralho") {
                            GlassChoiceMenu(
                                selection: $exportDeckID,
                                choices: [GlassChoice(id: Int64?.none, title: "Coleção inteira")]
                                    + store.decks.filter { !$0.isFiltered }.map {
                                        GlassChoice(id: Optional($0.id), title: $0.displayName)
                                    }
                            )
                        }
                        toolButton("Exportar baralho selecionado .apkg") { exportDeck(id: exportDeckID) }
                            .disabled(exportDeckID == nil)
                        toolButton("Exportar notas como TSV") { exportTSV() }
                        toolButton("Backup do arquivo da coleção") { backupCollection() }
                        toolButton("Verificar banco de dados") { checkDB() }
                        toolButton("Otimizar banco (VACUUM)") { optimizeDB() }
                        toolButton("Procurar duplicatas") { findDuplicates() }
                        toolButton("Verificar mídia") { checkMedia() }
                        toolButton("Apagar mídia não usada") { deleteUnusedMedia() }
                    }
                    GlassFormSection(title: "Agendador") {
                        GlassOptionRow(title: "Usar FSRS") {
                            Toggle("", isOn: $schedulerFSRS)
                                .labelsHidden()
                                .tint(AppTheme.accent)
                                .onChange(of: schedulerFSRS) { _, v in
                                    var conf = store.conf
                                    conf["scheduler"] = v ? "fsrs" : "sm2"
                                    try? store.saveConf(conf)
                                }
                        }
                        GlassInset {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Novo dia começa às \(Int(rollday)):00")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.white)
                                Slider(value: $rollday, in: 0...23, step: 1)
                                    .onChange(of: rollday) { _, v in
                                        var conf = store.conf
                                        conf["rollday"] = Int(v)
                                        try? store.saveConf(conf)
                                    }
                            }
                        }
                    }
                    GlassFormSection(title: "Preferências") {
                        settingsLink("Preferências do AnkiOS") { PreferencesView() }
                        settingsLink("Perfis") { ProfilesView() }
                    }
                    GlassFormSection(title: "Tipos de nota") {
                        settingsLink("Gerenciar tipos de nota") { NoteTypesView() }
                        settingsLink("Adicionar nota") { NoteEditorView(mode: .add) }
                    }
                    if !duplicates.isEmpty {
                        GlassFormSection(title: "Duplicatas") {
                            ForEach(duplicates, id: \.self) { line in
                                Text(line).font(.caption).foregroundStyle(.white)
                            }
                        }
                    }
                    GlassFormSection(title: "Cartões") {
                        toolButton("Desocultar todos os cartões ocultos") {
                            try? store.unburyAll()
                            store.lastError = "Cartões ocultos foram restaurados à fila."
                        }
                        toolButton("Remover cartões vazios") {
                            let n = (try? store.emptyCards()) ?? 0
                            store.lastError = "Removidos \(n) cartões vazios/órfãos."
                        }
                    }
                    GlassFormSection(title: "Ajuda") {
                        toolButton("Como usar o Anki (tutorial)") {
                            TutorialGate.resetForDebug()
                            store.shouldShowTutorial = true
                        }
                    }
                    GlassFormSection(title: "Sobre") {
                        GlassOptionRow(title: "App") {
                            Text("AnkiOS").foregroundStyle(.white)
                        }
                        Text("Estudo local compatível com Anki. A sincronização usa o iCloud da sua conta Apple.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(20)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .background(AppBackground())
            .navigationTitle("Ferramentas")
            .onAppear {
                rollday = Double(store.conf["rollday"] as? Int ?? 4)
                schedulerFSRS = (store.conf["scheduler"] as? String)?.lowercased() == "fsrs"
                if csvDeckID == nil {
                    csvDeckID = store.decks.first(where: { !$0.isFiltered && $0.name != "Default" })?.id
                        ?? store.decks.first(where: { !$0.isFiltered })?.id
                }
                if csvNotetypeID == nil {
                    csvNotetypeID = store.notetypes.first?.id
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .ankiTriggerImportApkg)) { _ in
                showImport = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .ankiTriggerImportCSV)) { _ in
                showCSVImport = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .ankiTriggerExport)) { _ in
                exportAll()
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
                        let n = try CSVImporter(store: store).importFile(
                            at: url,
                            deckID: csvDeckID,
                            notetypeID: csvNotetypeID
                        )
                        store.lastError = "CSV: \(n) nota(s) importada(s)."
                    } catch {
                        store.lastError = error.localizedDescription
                    }
                }
            }
            .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
                if let exportURL { ShareSheet(items: [exportURL]) }
            }
        }
    }

    private func toolButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(GlassButtonStyle(tint: .white, prominent: false, tintStrength: 0.16, expands: true))
    }

    private func settingsLink<Destination: View>(_ title: String, @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular.tint(.white.opacity(0.08)), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func exportAll() {
        exportDeck(id: nil)
    }

    private func exportDeck(id: Int64?) {
        do {
            let name: String
            if let id, let deck = store.deck(id: id) {
                name = deck.displayName.replacingOccurrences(of: "/", with: "-")
            } else {
                name = "collection"
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("AnkiOS-\(name).apkg")
            try ApkgExporter(store: store).export(deckID: id, to: url)
            exportURL = url
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func exportTSV() {
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("AnkiOS-notes.tsv")
            try CSVExporter(store: store).exportNotes(to: url)
            exportURL = url
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func backupCollection() {
        do {
            let src = store.collectionPath
            let stamp = Int(Date().timeIntervalSince1970)
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("collection-backup-\(stamp).anki2")
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: src, to: dest)
            exportURL = dest
            store.lastError = "Backup pronto para compartilhar."
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func checkDB() {
        do {
            let notes = try store.db.scalarInt("SELECT COUNT(*) FROM notes")
            let cards = try store.db.scalarInt("SELECT COUNT(*) FROM cards")
            let orphans = try store.db.scalarInt("SELECT COUNT(*) FROM cards WHERE nid NOT IN (SELECT id FROM notes)")
            store.lastError = "OK — \(notes) notes, \(cards) cards, \(orphans) orphan cards."
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func optimizeDB() {
        do {
            try store.db.run("VACUUM")
            try store.db.run("ANALYZE")
            store.lastError = "Banco otimizado (VACUUM + ANALYZE)."
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func findDuplicates() {
        var map: [String: Int] = [:]
        try? store.db.query("SELECT sfld FROM notes") { stmt in
            let s = SQLiteDatabase.text(stmt, 0)
            map[s, default: 0] += 1
        }
        duplicates = map.filter { $0.value > 1 }.map { "\($0.key) × \($0.value)" }.sorted()
        if duplicates.isEmpty {
            store.lastError = "No duplicate sort fields found."
        }
    }

    private func checkMedia() {
        do {
            try FileManager.default.createDirectory(at: store.mediaRoot, withIntermediateDirectories: true)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: store.mediaRoot.path)) ?? []
            var referenced = Set<String>()
            try store.db.query("SELECT flds FROM notes") { stmt in
                let flds = SQLiteDatabase.text(stmt, 0)
                referenced.formUnion(Self.mediaFilenames(in: flds))
            }
            let unused = files.filter { !referenced.contains($0) && $0 != "media" && !$0.hasPrefix(".") }
            let missing = referenced.filter { !files.contains($0) }
            store.lastError = "Mídia: \(files.count) arquivos, \(unused.count) não usados, \(missing.count) faltando."
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func deleteUnusedMedia() {
        do {
            try FileManager.default.createDirectory(at: store.mediaRoot, withIntermediateDirectories: true)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: store.mediaRoot.path)) ?? []
            var referenced = Set<String>()
            try store.db.query("SELECT flds FROM notes") { stmt in
                referenced.formUnion(Self.mediaFilenames(in: SQLiteDatabase.text(stmt, 0)))
            }
            var removed = 0
            for file in files where !referenced.contains(file) && !file.hasPrefix(".") && file != "media" {
                let url = store.mediaRoot.appendingPathComponent(file)
                try? FileManager.default.removeItem(at: url)
                removed += 1
            }
            store.lastError = "Removidos \(removed) arquivo(s) de mídia não usados."
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private static func mediaFilenames(in text: String) -> Set<String> {
        var names = Set<String>()
        var rest = text[...]
        while let r = rest.range(of: "[sound:") {
            let after = rest[r.upperBound...]
            if let end = after.firstIndex(of: "]") {
                names.insert(String(after[..<end]))
                rest = after[end...]
            } else { break }
        }
        rest = text[...]
        while let r = rest.range(of: "src=\"") ?? rest.range(of: "src='") {
            let quote = rest[r].hasSuffix("\"") ? "\"" : "'"
            let after = rest[r.upperBound...]
            if let end = after.firstIndex(of: Character(quote)) {
                let name = String(after[..<end]).components(separatedBy: "/").last ?? String(after[..<end])
                if !name.isEmpty { names.insert(name) }
                rest = after[end...]
            } else { break }
        }
        return names
    }
}
