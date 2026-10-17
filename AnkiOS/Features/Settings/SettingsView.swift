import SwiftUI
import SQLite3
import UniformTypeIdentifiers
import CommonCrypto

struct SettingsView: View {
    enum Action: Hashable {
        case importPackage, importText, exportCollection, preferences, noteTypes
    }

    @Binding var requestedAction: Action?
    @EnvironmentObject private var store: CollectionStore
    @State private var showImport = false
    @State private var showCSVImport = false
    @State private var pendingCSVName: String?
    @State private var pendingCSVText: String?
    @State private var exportURL: URL?
    @State private var rollday: Double = 4
    @State private var schedulerFSRS = false
    @State private var duplicates: [String] = []
    @State private var exportDeckID: Int64?
    @State private var csvDeckID: Int64?
    @State private var csvNotetypeID: Int64?
    @State private var csvAllowHTML = true
    @State private var csvExistingNotePolicy = CSVImporter.ExistingNotePolicy.update
    @State private var csvMatchWithinDeck = false
    @State private var csvSeparator = "auto"
    @State private var pendingCollectionPackage: URL?
    @State private var pendingCollectionPackageScoped = false
    @State private var showRestoreCollectionConfirm = false
    @State private var restoringCollectionPackage = false
    @State private var automaticBackupURLs: [URL] = []
    @State private var pendingDeckPackage: URL?
    @State private var pendingDeckPackageScoped = false
    @State private var showDeckImportOptions = false
    @State private var importingDeckPackage = false
    @State private var apkgIncludeScheduling = false
    @State private var apkgIncludeDeckPresets = false
    @State private var apkgIncludeMedia = true
    @State private var showPreferences = false
    @State private var showNoteTypes = false
    @State private var showMediaCheck = false
    @State private var mediaReport: MediaCheckReport?
    @State private var mediaCheckStatus: String?
    @State private var ankiWebUsername = ""
    @State private var ankiWebPassword = ""
    @State private var ankiWebEndpoint = ""
    @State private var changingAnkiWebAccount = false

    init(requestedAction: Binding<Action?> = .constant(nil)) {
        _requestedAction = requestedAction
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    #if !WIDGET_EXTENSION && !ANKIOS_PARITY_HARNESS
                    GlassFormSection(title: "AnkiWeb") {
                        if store.ankiWebConfigured && !changingAnkiWebAccount {
                            Label("Conectado como \(store.ankiWebUsername)", systemImage: "checkmark.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppTheme.good)
                                .padding(.horizontal, 4)
                            Button {
                                Task { await store.syncWithAnkiWeb() }
                            } label: {
                                Label("Sincronizar agora", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.42, expands: true))
                            .disabled(store.collectionSyncing)
                            Button("Usar outra conta") {
                                changingAnkiWebAccount = true
                                ankiWebPassword = ""
                            }
                            .buttonStyle(GlassButtonStyle(tint: .white, prominent: false, tintStrength: 0.16, expands: true))
                            Button("Desconectar conta") {
                                store.disconnectAnkiWeb()
                                changingAnkiWebAccount = false
                                ankiWebPassword = ""
                            }
                            .buttonStyle(GlassButtonStyle(tint: AppTheme.danger, prominent: false, tintStrength: 0.18, expands: true))
                        }
                        if !store.ankiWebConfigured || changingAnkiWebAccount {
                            TextField("Usuário ou e-mail", text: $ankiWebUsername)
                                .textFieldStyle(.plain)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                                .glassField()
                            SecureField("Senha do AnkiWeb", text: $ankiWebPassword)
                                .textFieldStyle(.plain)
                                .glassField()
                            TextField("Servidor personalizado (opcional)", text: $ankiWebEndpoint)
                                .textFieldStyle(.plain)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                                .glassField()
                            Button {
                                Task {
                                    await store.loginAnkiWeb(
                                        username: ankiWebUsername,
                                        password: ankiWebPassword,
                                        endpoint: ankiWebEndpoint
                                    )
                                    if store.ankiWebConfigured {
                                        ankiWebPassword = ""
                                        changingAnkiWebAccount = false
                                    }
                                }
                            } label: {
                                Label("Conectar ao AnkiWeb", systemImage: "person.crop.circle.badge.checkmark")
                            }
                            .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.42, expands: true))
                            .disabled(store.collectionSyncing)
                            if changingAnkiWebAccount {
                                Button("Cancelar") {
                                    changingAnkiWebAccount = false
                                    ankiWebPassword = ""
                                }
                                .buttonStyle(GlassButtonStyle(tint: .white, prominent: false, tintStrength: 0.16, expands: true))
                            }
                        }
                        Text("Use sua conta AnkiWeb para sincronizar a coleção e a mídia com o Anki oficial.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(.horizontal, 4)
                        if let ankiWebStatus = store.ankiWebStatus {
                            Text(ankiWebStatus)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.good)
                                .padding(.horizontal, 4)
                        }
                    }
                    #endif
                    GlassFormSection(title: "iCloud") {
                        Button {
                            Task { await store.syncWithICloud() }
                        } label: {
                            Label(
                                store.collectionSyncing ? "Sincronizando…" : "Sincronizar com iCloud",
                                systemImage: "icloud"
                            )
                        }
                        .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.42, expands: true))
                        .disabled(store.collectionSyncing)
                        Text("Envia e recebe a coleção e a mídia pela mesma conta iCloud. Em conflito, a versão mais recente prevalece e a outra é salva em Backups.")
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
                        toolButton("Importar .apkg, .colpkg ou Mnemosyne .db") { showImport = true }
                        toolButton("Importar CSV / texto") { showCSVImport = true }
                        GlassOptionRow(title: "Exportar agendamento e histórico") {
                            Toggle("", isOn: $apkgIncludeScheduling)
                                .labelsHidden()
                                .tint(AppTheme.accent)
                                .onChange(of: apkgIncludeScheduling) { _, _ in saveApkgExportOptions() }
                        }
                        GlassOptionRow(title: "Exportar predefinições de baralho") {
                            Toggle("", isOn: $apkgIncludeDeckPresets)
                                .labelsHidden()
                                .tint(AppTheme.accent)
                                .onChange(of: apkgIncludeDeckPresets) { _, _ in saveApkgExportOptions() }
                        }
                        GlassOptionRow(title: "Exportar mídia") {
                            Toggle("", isOn: $apkgIncludeMedia)
                                .labelsHidden()
                                .tint(AppTheme.accent)
                                .onChange(of: apkgIncludeMedia) { _, _ in saveApkgExportOptions() }
                        }
                        Text("Essas opções também se aplicam à exportação de baralhos e cartões selecionados.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(.horizontal, 4)
                        GlassOptionRow(title: "Importar para baralho") {
                            GlassChoiceMenu(
                                selection: $csvDeckID,
                                choices: store.decks.filter { !$0.isFiltered }.map {
                                    GlassChoice(id: Optional($0.id), title: $0.displayName)
                                }
                            )
                            .onChange(of: csvDeckID) { _, _ in saveCSVImportOptions() }
                        }
                        GlassOptionRow(title: "Tipo de nota (CSV)") {
                            GlassChoiceMenu(
                                selection: $csvNotetypeID,
                                choices: store.notetypes.map {
                                    GlassChoice(id: Optional($0.id), title: $0.name)
                                }
                            )
                            .onChange(of: csvNotetypeID) { _, _ in saveCSVImportOptions() }
                        }
                        GlassOptionRow(title: "Permitir HTML no CSV") {
                            Toggle("", isOn: $csvAllowHTML)
                                .labelsHidden()
                                .tint(AppTheme.accent)
                                .onChange(of: csvAllowHTML) { _, _ in saveCSVImportOptions() }
                        }
                        GlassOptionRow(title: "Separador do CSV") {
                            Picker("", selection: $csvSeparator) {
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
                            .onChange(of: csvSeparator) { _, _ in saveCSVImportOptions() }
                        }
                        GlassOptionRow(title: "Duplicatas no CSV") {
                            Picker("", selection: $csvExistingNotePolicy) {
                                ForEach(CSVImporter.ExistingNotePolicy.allCases) { policy in
                                    Text(policy.title).tag(policy)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .onChange(of: csvExistingNotePolicy) { _, _ in saveCSVImportOptions() }
                        }
                        GlassOptionRow(title: "Comparar duplicatas no baralho selecionado") {
                            Toggle("", isOn: $csvMatchWithinDeck)
                                .labelsHidden()
                                .tint(AppTheme.accent)
                                .onChange(of: csvMatchWithinDeck) { _, _ in saveCSVImportOptions() }
                        }
                        toolButton("Exportar coleção .apkg") { exportAll() }
                        toolButton("Exportar coleção completa (.colpkg)") { exportCollectionPackage() }
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
                        Button("Criar backup agora", systemImage: "externaldrive.badge.timemachine") { backupCollection() }
                            .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.42, expands: true))
                        if automaticBackupURLs.isEmpty {
                            Text("Ainda não há backups automáticos neste perfil.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .padding(.horizontal, 4)
                        } else {
                            ForEach(automaticBackupURLs, id: \.path) { url in
                                Button("Restaurar backup de \(backupTitle(url))", systemImage: "clock.arrow.circlepath") {
                                    pendingCollectionPackage = url
                                    pendingCollectionPackageScoped = false
                                    showRestoreCollectionConfirm = true
                                }
                                .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.3, expands: true))
                            }
                        }
                        toolButton("Verificar banco de dados") { checkDB() }
                        toolButton("Otimizar banco (VACUUM)") { optimizeDB() }
                        toolButton("Procurar duplicatas") { findDuplicates() }
                        toolButton("Verificar mídia") { checkMedia() }
                    }
                    GlassFormSection(title: "Agendador") {
                        GlassOptionRow(title: "Usar FSRS") {
                            Toggle("", isOn: $schedulerFSRS)
                                .labelsHidden()
                                .tint(AppTheme.accent)
                                .onChange(of: schedulerFSRS) { _, v in
                                    let previousFSRS = store.fsrsEnabled
                                    var conf = store.conf
                                    conf["fsrs"] = v
                                    do {
                                        try store.saveConf(conf)
                                        if previousFSRS != v {
                                            try store.rebuildFSRSMemoryStates(enabled: v)
                                        }
                                    }
                                    catch { store.lastError = error.localizedDescription }
                                }
                        }
                        GlassInset {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Novo dia começa às \(Int(rollday)):00")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(AppTheme.primaryText)
                                Slider(value: $rollday, in: 0...23, step: 1)
                                    .onChange(of: rollday) { _, v in
                                        guard Int(v) != store.rolloverHour else { return }
                                        do {
                                            try store.setRolloverHour(Int(v))
                                            try store.refreshCounts()
                                        } catch { store.lastError = error.localizedDescription }
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
                                Text(line).font(.caption).foregroundStyle(AppTheme.primaryText)
                            }
                        }
                    }
                    GlassFormSection(title: "Cartões") {
                        toolButton("Desocultar todos os cartões ocultos") {
                            do {
                                try store.unburyAll()
                                store.lastError = "Cartões ocultos foram restaurados à fila."
                            } catch {
                                store.lastError = error.localizedDescription
                            }
                        }
                        toolButton("Remover cartões vazios") {
                            do {
                                let n = try store.emptyCards()
                                store.lastError = "Removidos \(n) cartões vazios/órfãos."
                            } catch {
                                store.lastError = error.localizedDescription
                            }
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
                            Text("AnkiOS").foregroundStyle(AppTheme.primaryText)
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
                #if !WIDGET_EXTENSION && !ANKIOS_PARITY_HARNESS
                if ankiWebUsername.isEmpty { ankiWebUsername = store.ankiWebUsername }
                if ankiWebEndpoint.isEmpty { ankiWebEndpoint = store.ankiWebEndpoint }
                #endif
                rollday = Double(store.rolloverHour)
                schedulerFSRS = store.fsrsEnabled
                apkgIncludeScheduling = store.conf["apkgIncludeScheduling"] as? Bool ?? false
                apkgIncludeDeckPresets = store.conf["apkgIncludeDeckPresets"] as? Bool ?? false
                apkgIncludeMedia = store.conf["apkgIncludeMedia"] as? Bool ?? true
                csvAllowHTML = store.conf["csvAllowHTML"] as? Bool ?? true
                csvExistingNotePolicy = CSVImporter.ExistingNotePolicy(rawValue: store.conf["csvExistingNotePolicy"] as? String ?? "") ?? .update
                csvMatchWithinDeck = store.conf["csvMatchWithinDeck"] as? Bool ?? false
                csvSeparator = store.conf["csvSeparator"] as? String ?? "auto"
                if csvDeckID == nil {
                    csvDeckID = (store.conf["csvDeckID"] as? NSNumber)?.int64Value
                        ?? store.decks.first(where: { !$0.isFiltered && $0.name != "Default" })?.id
                        ?? store.decks.first(where: { !$0.isFiltered })?.id
                }
                if csvNotetypeID == nil {
                    csvNotetypeID = (store.conf["csvNotetypeID"] as? NSNumber)?.int64Value ?? store.notetypes.first?.id
                }
                refreshAutomaticBackups()
                consumeRequestedAction()
            }
            .onChange(of: store.activeProfile) { _, _ in refreshAutomaticBackups() }
            .onChange(of: store.automaticBackupRevision) { _, _ in refreshAutomaticBackups() }
            .onChange(of: requestedAction) { _, _ in consumeRequestedAction() }
            .onChange(of: store.isBootstrapping) { _, _ in consumeRequestedAction() }
            .onChange(of: store.collectionSyncing) { _, _ in consumeRequestedAction() }
            .navigationDestination(isPresented: $showPreferences) {
                PreferencesView()
            }
            .navigationDestination(isPresented: $showNoteTypes) {
                NoteTypesView()
            }
            .fileImporter(
                isPresented: $showImport,
                allowedContentTypes: [.ankiApkg, .ankiColpkg, .mnemosyneDB, .archive, .data],
                allowsMultipleSelection: false
            ) { result in
                Task {
                    do {
                        guard let url = try result.get().first else { return }
                        let scoped = url.startAccessingSecurityScopedResource()
                        if url.pathExtension.lowercased() == "colpkg" {
                            pendingCollectionPackage = url
                            pendingCollectionPackageScoped = scoped
                            showRestoreCollectionConfirm = true
                            return
                        }
                        if url.pathExtension.lowercased() == "db" {
                            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            store.lastError = try MnemosyneImporter(store: store).importFile(at: url)
                        } else {
                            pendingDeckPackage = url
                            pendingDeckPackageScoped = scoped
                            showDeckImportOptions = true
                        }
                    } catch {
                        store.lastError = error.localizedDescription
                    }
                }
            }
            .fileImporter(isPresented: $showCSVImport, allowedContentTypes: [.commaSeparatedText, .plainText, .text, .data], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let text = try String(contentsOf: url, encoding: .utf8)
                    pendingCSVName = url.lastPathComponent
                    pendingCSVText = text
                } catch {
                    store.lastError = error.localizedDescription
                }
            }
            .sheet(isPresented: Binding(get: { pendingCSVText != nil }, set: { if !$0 { pendingCSVText = nil; pendingCSVName = nil } })) {
                if let pendingCSVText {
                    CSVImportReviewView(
                        fileName: pendingCSVName ?? "Texto",
                        text: pendingCSVText,
                        store: store,
                        deckID: csvDeckID,
                        notetypeID: csvNotetypeID
                    )
                    .environmentObject(store)
                }
            }
            .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
                if let exportURL { ShareSheet(items: [exportURL]) }
            }
            .sheet(isPresented: $showMediaCheck, onDismiss: {
                mediaReport = nil
                mediaCheckStatus = nil
            }) {
                if let mediaReport {
                    MediaCheckSheet(
                        report: mediaReport,
                        status: mediaCheckStatus,
                        onRescan: { refreshMediaReport() },
                        onTagMissingNotes: { tagNotesWithMissingMedia() },
                        onTrashUnused: { trashUnusedMedia() },
                        onRestoreTrash: { restoreMediaTrash() },
                        onEmptyTrash: { emptyMediaTrash() },
                        onRenderLatex: { renderMissingLatex() }
                    )
                }
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
            .onChange(of: showDeckImportOptions) { _, isPresented in
                if !isPresented && !importingDeckPackage {
                    releasePendingDeckPackage()
                }
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
        }
    }

    private func consumeRequestedAction() {
        guard let action = requestedAction, !store.isBootstrapping, !store.collectionSyncing else { return }
        requestedAction = nil
        switch action {
        case .importPackage: showImport = true
        case .importText: showCSVImport = true
        case .exportCollection: exportAll()
        case .preferences: showPreferences = true
        case .noteTypes: showNoteTypes = true
        }
    }

    private func toolButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(GlassButtonStyle(tint: .white, prominent: false, tintStrength: 0.16, expands: true))
    }

    private func restorePendingCollectionPackage() async {
        guard let url = pendingCollectionPackage else { return }
        do {
            store.lastError = try await ApkgImporter(store: store).importPackage(at: url)
            refreshAutomaticBackups()
        } catch {
            store.lastError = error.localizedDescription
        }
        releasePendingCollectionPackage()
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

    private func releasePendingCollectionPackage() {
        if pendingCollectionPackageScoped, let pendingCollectionPackage {
            pendingCollectionPackage.stopAccessingSecurityScopedResource()
        }
        pendingCollectionPackage = nil
        pendingCollectionPackageScoped = false
    }

    private func settingsLink<Destination: View>(_ title: String, @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.primaryText)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(AppTheme.primaryText.opacity(0.55))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .ankiGlass(tint: .white.opacity(0.08), interactive: true, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func exportAll() {
        exportDeck(id: nil)
    }

    private func exportCollectionPackage() {
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("AnkiOS-collection.colpkg")
            try ApkgExporter(store: store).exportCollectionPackage(to: url)
            exportURL = url
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func saveApkgExportOptions() {
        var conf = store.conf
        conf["apkgIncludeScheduling"] = apkgIncludeScheduling
        conf["apkgIncludeDeckPresets"] = apkgIncludeDeckPresets
        conf["apkgIncludeMedia"] = apkgIncludeMedia
        do { try store.saveConf(conf) }
        catch { store.lastError = error.localizedDescription }
    }

    private func saveCSVImportOptions() {
        var conf = store.conf
        conf["csvAllowHTML"] = csvAllowHTML
        conf["csvExistingNotePolicy"] = csvExistingNotePolicy.rawValue
        conf["csvMatchWithinDeck"] = csvMatchWithinDeck
        conf["csvSeparator"] = csvSeparator
        conf["csvDeckID"] = csvDeckID
        conf["csvNotetypeID"] = csvNotetypeID
        do { try store.saveConf(conf) }
        catch { store.lastError = error.localizedDescription }
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
            guard let backup = try store.createAutomaticBackupIfNeeded(force: true) else { return }
            refreshAutomaticBackups()
            store.lastError = "Backup criado: \(backup.lastPathComponent)"
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func refreshAutomaticBackups() {
        automaticBackupURLs = (try? store.collectionBackupPackages()) ?? []
    }

    private func backupTitle(_ url: URL) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "'backup-'yyyy-MM-dd-HH.mm.ss'.colpkg'"
        guard let date = formatter.date(from: url.lastPathComponent) else { return url.lastPathComponent }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }

    private func checkDB() {
        do {
            let integrity = try store.db.scalarText("PRAGMA quick_check")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "sem resultado"
            guard integrity == "ok" else {
                store.lastError = "A coleção apresenta um problema de integridade: \(integrity)"
                return
            }

            let backupDirectory = store.profileDirectory.appendingPathComponent("Backups", isDirectory: true)
            try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            let stamp = Int64(Date().timeIntervalSince1970 * 1000)
            let backup = backupDirectory.appendingPathComponent("collection-check-\(stamp).anki2")
            try store.db.backup(to: backup)

            try store.db.run("VACUUM")
            try store.db.run("ANALYZE")

            var repairedFieldCounts = 0
            var removedInvalidCards = 0
            var notesWithoutNotetype = 0
            var repairedCardProperties = 0
            var repairedRevlogProperties = 0
            var recoveredDecks = 0
            var recoveredNotetypes = 0
            var repairedIDs = 0
            var orphanedCards: [Int64] = []
            try store.db.exec("BEGIN IMMEDIATE")
            do {
                repairedCardProperties += try repairCardProperties()

                try store.db.query("SELECT id FROM cards WHERE nid NOT IN (SELECT id FROM notes)") { statement in
                    orphanedCards.append(sqlite3_column_int64(statement, 0))
                }
                try store.recordGraves(ids: orphanedCards, type: 0)
                try store.db.run("DELETE FROM cards WHERE nid NOT IN (SELECT id FROM notes)")

                recoveredDecks += try recoverMissingDecks()
                repairedCardProperties += try clearInvalidFilteredDeckState()
                recoveredNotetypes = try recoverMissingNotetypes()

                var noteIDs: [Int64] = []
                try store.db.query("SELECT id FROM notes ORDER BY id") { statement in
                    noteIDs.append(sqlite3_column_int64(statement, 0))
                }
                for noteID in noteIDs {
                    guard var note = try store.fetchNote(id: noteID) else { continue }
                    guard let model = store.notetype(id: note.mid) else {
                        notesWithoutNotetype += 1
                        continue
                    }

                    let expectedFieldCount = max(1, (model.flds.map(\.ord).max() ?? -1) + 1)
                    if note.fields.count != expectedFieldCount {
                        var fields = Array(note.fields.prefix(expectedFieldCount))
                        if fields.count < expectedFieldCount {
                            fields.append(contentsOf: repeatElement("", count: expectedFieldCount - fields.count))
                        }
                        var tags = note.tagList
                        if !tags.contains("db-check") { tags.append("db-check") }
                        try store.updateNote(note, fields: fields, tags: tags.joined(separator: " "))
                        repairedFieldCounts += 1
                        guard let repaired = try store.fetchNote(id: noteID) else { continue }
                        note = repaired
                    }

                    let wanted = model.isCloze
                        ? Set(ClozeHelper.ords(in: note.fields))
                        : Set(store.activeTemplateOrds(model: model, fields: note.fields, tags: note.tagList))
                    var cardRows: [(id: Int64, ord: Int)] = []
                    try store.db.query("SELECT id, ord FROM cards WHERE nid = ? ORDER BY id", bind: {
                        SQLiteDatabase.bindInt64($0, 1, noteID)
                    }) { statement in
                        cardRows.append((sqlite3_column_int64(statement, 0), Int(sqlite3_column_int(statement, 1))))
                    }
                    var seenOrds = Set<Int>()
                    let invalidCardIDs = cardRows.compactMap { card in
                        !wanted.contains(card.ord) || !seenOrds.insert(card.ord).inserted ? card.id : nil
                    }
                    if !invalidCardIDs.isEmpty {
                        try store.recordGraves(ids: invalidCardIDs, type: 0)
                        for cardID in invalidCardIDs {
                            try store.db.run("DELETE FROM cards WHERE id = ?", bind: {
                                SQLiteDatabase.bindInt64($0, 1, cardID)
                            })
                        }
                        removedInvalidCards += invalidCardIDs.count
                    }
                    if !wanted.isEmpty {
                        try store.regenerateCards(forNoteID: noteID)
                    }
                }

                try store.rebuildTagRegistry()
                repairedRevlogProperties = try repairRevlogProperties()
                recoveredDecks += try recoverMissingDeckParents()

                var updatedConf = store.conf
                let nextPosition = try store.db.scalarInt("SELECT COALESCE(MAX(due), 0) + 1 FROM cards WHERE type = 0")
                updatedConf["nextPos"] = max((updatedConf["nextPos"] as? Int ?? 1), nextPosition)
                try store.saveConf(updatedConf)
                repairedIDs = try repairInvalidIDs()
                try store.refreshCounts()
                try store.db.exec("COMMIT")
            } catch {
                try? store.db.exec("ROLLBACK")
                try? store.reloadMeta()
                try? store.refreshCounts()
                throw error
            }

            let notes = try store.db.scalarInt("SELECT COUNT(*) FROM notes")
            let cards = try store.db.scalarInt("SELECT COUNT(*) FROM cards")
            store.lastError = "Coleção verificada e otimizada: \(notes) notas, \(cards) cartões; \(orphanedCards.count) cartões órfãos removidos, \(removedInvalidCards) cartões sem modelo removidos, \(repairedFieldCounts) notas ajustadas, \(repairedCardProperties) propriedades de cartões corrigidas, \(repairedRevlogProperties) registros de revisão corrigidos, \(recoveredDecks) baralhos restaurados, \(recoveredNotetypes) tipos de nota restaurados e \(repairedIDs) IDs corrigidos. \(notesWithoutNotetype) notas sem tipo compatível foram preservadas. Tags reconstruídas; backup salvo no perfil."
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func repairCardProperties() throws -> Int {
        let now = Int64(Date().timeIntervalSince1970)
        let today = store.schedDay()
        var repaired = 0

        let newDueExpression = "CASE WHEN type = 0 AND queue != 4 THEN 1000000 + due % 1000000 ELSE due END"
        repaired += try store.db.scalarInt("SELECT COUNT(*) FROM cards WHERE due >= 1000000 AND due != \(newDueExpression)")
        try store.db.run("""
            UPDATE cards
            SET due = \(newDueExpression), mod = \(now), usn = -1
            WHERE due >= 1000000 AND due != \(newDueExpression)
        """)

        let dueExpression = "CASE WHEN queue = 2 AND due > 100000 THEN \(today) ELSE min(max(round(due), -2147483648), 2147483647) END"
        repaired += try store.db.scalarInt("SELECT COUNT(*) FROM cards WHERE due != \(dueExpression)")
        try store.db.run("""
            UPDATE cards
            SET due = \(dueExpression), mod = \(now), usn = -1
            WHERE due != \(dueExpression)
        """)

        let intervalExpression = "min(max(round(ivl), -2147483648), 2147483647)"
        repaired += try store.db.scalarInt("SELECT COUNT(*) FROM cards WHERE ivl != \(intervalExpression)")
        try store.db.run("""
            UPDATE cards
            SET ivl = \(intervalExpression), mod = \(now), usn = -1
            WHERE ivl != \(intervalExpression)
        """)

        let originalDueExpression = "CASE WHEN odid = 0 THEN 0 ELSE min(max(round(odue), -2147483648), 2147483647) END"
        repaired += try store.db.scalarInt("SELECT COUNT(*) FROM cards WHERE odue != \(originalDueExpression)")
        try store.db.run("""
            UPDATE cards
            SET odue = \(originalDueExpression), mod = \(now), usn = -1
            WHERE odue != \(originalDueExpression)
        """)

        let ordinalExpression = "min(max(ord, 0), 65535)"
        repaired += try store.db.scalarInt("SELECT COUNT(*) FROM cards WHERE ord != \(ordinalExpression)")
        try store.db.run("""
            UPDATE cards
            SET ord = \(ordinalExpression), mod = \(now), usn = -1
            WHERE ord != \(ordinalExpression)
        """)

        let modificationExpression = "min(max(round(mod), 0), \(now))"
        repaired += try store.db.scalarInt("SELECT COUNT(*) FROM cards WHERE mod != \(modificationExpression)")
        try store.db.run("""
            UPDATE cards
            SET mod = \(modificationExpression), usn = -1
            WHERE mod != \(modificationExpression)
        """)
        return repaired
    }

    private func recoverMissingDecks() throws -> Int {
        var referencedIDs: [Int64] = []
        try store.db.query("SELECT DISTINCT did FROM cards ORDER BY did") { statement in
            referencedIDs.append(sqlite3_column_int64(statement, 0))
        }
        let missingIDs = referencedIDs.filter { store.deck(id: $0) == nil }
        guard !missingIDs.isEmpty else { return 0 }

        var nextDecks = store.decks
        var names = Set(nextDecks.map { $0.name.lowercased() })
        let now = Int64(Date().timeIntervalSince1970)
        for id in missingIDs {
            var name = "recovered\(id)"
            var suffix = 2
            while names.contains(name.lowercased()) {
                name = "recovered\(id)-\(suffix)"
                suffix += 1
            }
            names.insert(name.lowercased())
            nextDecks.append(AnkiDeck(
                id: id,
                name: name,
                mod: now,
                usn: -1,
                collapsed: false,
                browserCollapsed: false,
                desc: "",
                dyn: 0,
                conf: 1,
                extendNew: 0,
                extendRev: 0,
                newToday: [0, 0],
                revToday: [0, 0],
                lrnToday: [0, 0],
                timeToday: [0, 0]
            ))
        }
        try store.saveDecks(nextDecks)
        return missingIDs.count
    }

    private func clearInvalidFilteredDeckState() throws -> Int {
        var invalidIDs: [Int64] = []
        try store.db.query("SELECT id, did FROM cards WHERE odid > 0") { statement in
            let cardID = sqlite3_column_int64(statement, 0)
            let deckID = sqlite3_column_int64(statement, 1)
            if store.deck(id: deckID)?.isFiltered != true {
                invalidIDs.append(cardID)
            }
        }
        guard !invalidIDs.isEmpty else { return 0 }

        let now = Int64(Date().timeIntervalSince1970)
        for cardID in invalidIDs {
            try store.db.run(
                "UPDATE cards SET odid = 0, odue = 0, mod = ?, usn = -1 WHERE id = ?",
                bind: {
                    SQLiteDatabase.bindInt64($0, 1, now)
                    SQLiteDatabase.bindInt64($0, 2, cardID)
                }
            )
        }
        return invalidIDs.count
    }

    private func recoverMissingNotetypes() throws -> Int {
        var noteRows: [(id: Int64, mid: Int64)] = []
        try store.db.query("SELECT id, mid FROM notes ORDER BY mid, id") { statement in
            noteRows.append((
                sqlite3_column_int64(statement, 0),
                sqlite3_column_int64(statement, 1)
            ))
        }
        var noteGroups: [Int64: [(id: Int64, fields: Int)]] = [:]
        for row in noteRows where store.notetype(id: row.mid) == nil {
            guard let note = try store.fetchNote(id: row.id) else { continue }
            noteGroups[row.mid, default: []].append((row.id, note.fields.count))
        }
        guard !noteGroups.isEmpty else {
            guard store.notetypes.isEmpty else { return 0 }
            var typeID = store.timestampID()
            while store.notetype(id: typeID) != nil {
                typeID = store.timestampID()
            }
            let data = try JSONSerialization.data(withJSONObject: CollectionSchema.makeBasicNotetype(
                id: typeID,
                now: Int64(Date().timeIntervalSince1970)
            ))
            let basic = try JSONDecoder().decode(AnkiNotetype.self, from: data)
            try store.saveNotetypes([basic])
            return 1
        }

        let now = Int64(Date().timeIntervalSince1970)
        var recoveredTypes: [AnkiNotetype] = []
        var idMappings: [(oldID: Int64, newID: Int64)] = []
        var names = Set(store.notetypes.map { $0.name.lowercased() })
        for (missingID, notes) in noteGroups.sorted(by: { $0.key < $1.key }) {
            var maxOrdinal = 0
            for note in notes {
                let ordinal = try store.db.scalarInt(
                    "SELECT COALESCE(MAX(ord), 0) FROM cards WHERE nid = ?",
                    bind: { SQLiteDatabase.bindInt64($0, 1, note.id) }
                )
                maxOrdinal = max(maxOrdinal, ordinal)
            }

            var typeID = store.timestampID()
            while store.notetype(id: typeID) != nil || recoveredTypes.contains(where: { $0.id == typeID }) {
                typeID = store.timestampID()
            }
            let data = try JSONSerialization.data(withJSONObject: CollectionSchema.makeBasicNotetype(id: typeID, now: now))
            var recovered = try JSONDecoder().decode(AnkiNotetype.self, from: data)
            var name = "db-check-\(now)-\(missingID)"
            var suffix = 2
            while names.contains(name.lowercased()) {
                name = "db-check-\(now)-\(missingID)-\(suffix)"
                suffix += 1
            }
            names.insert(name.lowercased())
            recovered.name = name

            let fieldCount = max(2, notes.map { $0.fields }.max() ?? 2)
            while recovered.flds.count < fieldCount {
                let ordinal = recovered.flds.count
                recovered.flds.append(AnkiField(name: "\(ordinal + 1)", ord: ordinal))
            }

            let questionFormat = recovered.tmpls[0].qfmt
            let answerFormat = recovered.tmpls[0].afmt
            let templateCount = max(maxOrdinal + 1, 1)
            while recovered.tmpls.count < templateCount {
                let ordinal = recovered.tmpls.count
                recovered.tmpls.append(AnkiTemplate(
                    name: "Card \(ordinal + 1)",
                    ord: ordinal,
                    qfmt: questionFormat,
                    afmt: answerFormat
                ))
            }
            recovered.assignMissingComponentIDs()
            recoveredTypes.append(recovered)
            idMappings.append((missingID, typeID))
        }

        try store.saveNotetypes(store.notetypes + recoveredTypes)
        for mapping in idMappings {
            try store.db.run(
                "UPDATE notes SET mid = ?, mod = ?, usn = -1 WHERE mid = ?",
                bind: {
                    SQLiteDatabase.bindInt64($0, 1, mapping.newID)
                    SQLiteDatabase.bindInt64($0, 2, now)
                    SQLiteDatabase.bindInt64($0, 3, mapping.oldID)
                }
            )
        }
        return recoveredTypes.count
    }

    private func repairRevlogProperties() throws -> Int {
        let interval = "min(max(round(ivl), -2147483648), 2147483647)"
        let lastInterval = "min(max(round(lastIvl), -2147483648), 2147483647)"
        let time = "min(max(round(time), 0), 2147483647)"
        let kind = "CASE WHEN type = 0 AND time = 0 AND ease = 0 THEN 5 ELSE type END"
        let invalidCount = try store.db.scalarInt("""
            SELECT COUNT(*) FROM revlog
            WHERE ivl != \(interval)
               OR lastIvl != \(lastInterval)
               OR time != \(time)
               OR type != \(kind)
        """)
        try store.db.run("""
            UPDATE revlog
            SET ivl = \(interval),
                lastIvl = \(lastInterval),
                time = \(time),
                type = \(kind)
            WHERE ivl != \(interval)
               OR lastIvl != \(lastInterval)
               OR time != \(time)
               OR type != \(kind)
        """)
        return invalidCount
    }

    private func recoverMissingDeckParents() throws -> Int {
        var names = Set(store.decks.map { $0.name.lowercased() })
        var nextDecks = store.decks
        let now = Int64(Date().timeIntervalSince1970)
        var created = 0
        let deckNames = nextDecks.map(\.name)
        for deckName in deckNames {
            let components = deckName.components(separatedBy: "::")
            guard components.count > 1 else { continue }
            for index in 1..<components.count {
                let parent = components.prefix(index).joined(separator: "::")
                guard names.insert(parent.lowercased()).inserted else { continue }
                var id = store.timestampID()
                while nextDecks.contains(where: { $0.id == id }) {
                    id = store.timestampID()
                }
                nextDecks.append(AnkiDeck(
                    id: id,
                    name: parent,
                    mod: now,
                    usn: -1,
                    collapsed: false,
                    browserCollapsed: false,
                    desc: "",
                    dyn: 0,
                    conf: 1,
                    extendNew: 0,
                    extendRev: 0,
                    newToday: [0, 0],
                    revToday: [0, 0],
                    lrnToday: [0, 0],
                    timeToday: [0, 0]
                ))
                created += 1
            }
        }
        if created > 0 {
            try store.saveDecks(nextDecks)
        }
        return created
    }

    private func repairInvalidIDs() throws -> Int {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let cutoff = now + 86_400_000
        let invalidCount = try store.db.scalarInt("""
            SELECT
                (SELECT COUNT(*) FROM notes WHERE id > \(cutoff)) +
                (SELECT COUNT(*) FROM cards WHERE id > \(cutoff)) +
                (SELECT COUNT(*) FROM revlog WHERE id > \(cutoff))
        """)
        guard invalidCount > 0 else { return 0 }

        try repairIDs(in: "notes", relatedTable: "cards", relatedColumn: "nid", cutoff: cutoff, preferredID: now)
        try repairIDs(in: "cards", relatedTable: "revlog", relatedColumn: "cid", cutoff: cutoff, preferredID: now)
        try repairIDs(in: "revlog", relatedTable: nil, relatedColumn: nil, cutoff: cutoff, preferredID: now)
        return invalidCount
    }

    private func repairIDs(
        in table: String,
        relatedTable: String?,
        relatedColumn: String?,
        cutoff: Int64,
        preferredID: Int64
    ) throws {
        var invalidIDs: [Int64] = []
        try store.db.query("SELECT id FROM \(table) WHERE id > \(cutoff) ORDER BY id") { statement in
            invalidIDs.append(sqlite3_column_int64(statement, 0))
        }
        guard !invalidIDs.isEmpty else { return }

        var occupiedIDs = Set<Int64>()
        try store.db.query("SELECT id FROM \(table) WHERE id <= \(cutoff)") { statement in
            occupiedIDs.insert(sqlite3_column_int64(statement, 0))
        }
        let maxValidID = try store.db.scalarInt64("SELECT COALESCE(MAX(id), 0) FROM \(table) WHERE id <= \(cutoff)")
        var nextID = max(preferredID, maxValidID + 1)
        for invalidID in invalidIDs {
            while nextID > cutoff || occupiedIDs.contains(nextID) {
                nextID = nextID >= cutoff ? 1 : nextID + 1
            }
            try store.db.run(
                "UPDATE \(table) SET id = ? WHERE id = ?",
                bind: {
                    SQLiteDatabase.bindInt64($0, 1, nextID)
                    SQLiteDatabase.bindInt64($0, 2, invalidID)
                }
            )
            if let relatedTable, let relatedColumn {
                try store.db.run(
                    "UPDATE \(relatedTable) SET \(relatedColumn) = ? WHERE \(relatedColumn) = ?",
                    bind: {
                        SQLiteDatabase.bindInt64($0, 1, nextID)
                        SQLiteDatabase.bindInt64($0, 2, invalidID)
                    }
                )
            }
            occupiedIDs.insert(nextID)
            nextID += 1
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
        do {
            try store.db.query("SELECT mid, sfld, COUNT(*) FROM notes GROUP BY mid, sfld HAVING COUNT(*) > 1") { stmt in
                let mid = sqlite3_column_int64(stmt, 0)
                let value = SQLiteDatabase.text(stmt, 1)
                let count = Int(sqlite3_column_int(stmt, 2))
                let typeName = store.notetype(id: mid)?.name ?? "Tipo \(mid)"
                map["\(typeName) · \(value)"] = count
            }
        } catch {
            store.lastError = error.localizedDescription
            return
        }
        duplicates = map.filter { $0.value > 1 }.map { "\($0.key) × \($0.value)" }.sorted()
        if duplicates.isEmpty {
            store.lastError = "Nenhum campo de ordenação duplicado encontrado dentro do mesmo tipo de nota."
        }
    }

    private func checkMedia() {
        do {
            mediaReport = try makeMediaCheckReport()
            mediaCheckStatus = nil
            showMediaCheck = true
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func refreshMediaReport(status: String? = nil) {
        do {
            mediaReport = try makeMediaCheckReport()
            mediaCheckStatus = status
        } catch {
            store.lastError = error.localizedDescription
            mediaCheckStatus = error.localizedDescription
        }
    }

    private func makeMediaCheckReport() throws -> MediaCheckReport {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: store.mediaRoot, withIntermediateDirectories: true)
        let trashRoot = store.profileDirectory.appendingPathComponent("media.trash", isDirectory: true)
        try fileManager.createDirectory(at: trashRoot, withIntermediateDirectories: true)

        var files: [String] = []
        var folders: [String] = []
        for url in try fileManager.contentsOfDirectory(at: store.mediaRoot, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { continue }
            if values.isDirectory == true {
                folders.append(url.lastPathComponent)
            } else if values.isRegularFile == true, !url.lastPathComponent.hasPrefix(".") {
                files.append(url.lastPathComponent)
            }
        }

        var referencesByName: [String: Set<Int64>] = [:]
        var latexTasks: [AnkiLatexRenderTask] = []
        var seenLatexNames = Set<String>()
        try store.db.query("SELECT id, mid, flds FROM notes") { stmt in
            let noteID = sqlite3_column_int64(stmt, 0)
            let notetypeID = sqlite3_column_int64(stmt, 1)
            let fields = SQLiteDatabase.text(stmt, 2)
            for rawName in MediaStore.mediaFiles(in: fields) {
                let name = Self.decodeMediaFilename(rawName)
                guard Self.isLocalMediaFilename(name) else { continue }
                referencesByName[name, default: []].insert(noteID)
            }
            if let notetype = store.notetype(id: notetypeID) {
                let extraction = AnkiLatexMarkup.extract(in: fields, svg: notetype.latexsvg, expandClozes: true)
                for asset in extraction.assets {
                    referencesByName[asset.filename, default: []].insert(noteID)
                    if seenLatexNames.insert(asset.filename).inserted {
                        latexTasks.append(AnkiLatexRenderTask(
                            asset: asset,
                            header: notetype.latexPre,
                            footer: notetype.latexPost,
                            svg: notetype.latexsvg
                        ))
                    }
                }
            }
        }

        let caseSensitive = (try? store.mediaRoot.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? false
        let key: (String) -> String = { value in
            caseSensitive ? value : value.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        let existingNames = Set(files.map(key))
        let usedNames = Set(referencesByName.keys.map(key))
        let unused = files.filter { !$0.hasPrefix("_") && !usedNames.contains(key($0)) }.sorted()
        let missing = referencesByName.keys.filter { !existingNames.contains(key($0)) }.sorted()
        let missingNoteIDs = Set(missing.flatMap { referencesByName[$0] ?? [] }).sorted()
        let missingLatex = latexTasks.filter { !existingNames.contains(key($0.asset.filename)) }

        var trashCount = 0
        var trashBytes: Int64 = 0
        for url in try fileManager.contentsOfDirectory(at: trashRoot, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            guard url.lastPathComponent != ".DS_Store" else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            trashCount += 1
            trashBytes += Int64(values.fileSize ?? 0)
        }

        return MediaCheckReport(
            fileCount: files.count,
            unused: unused,
            missing: missing,
            missingLatex: missingLatex,
            missingNoteIDs: missingNoteIDs,
            folders: folders.sorted(),
            trashCount: trashCount,
            trashBytes: trashBytes
        )
    }

    private func renderMissingLatex() {
        guard let mediaReport, !mediaReport.missingLatex.isEmpty else { return }
        #if os(macOS)
        let tasks = mediaReport.missingLatex
        let mediaRoot = store.mediaRoot
        let enabled = store.conf["renderLatex"] as? Bool ?? false
        mediaCheckStatus = "Gerando imagens LaTeX…"
        Task {
            let errors = await Task.detached(priority: .userInitiated) {
                AnkiLatexImageGenerator.renderMissing(tasks, mediaRoot: mediaRoot, enabled: enabled, stopOnError: true)
            }.value
            let status: String
            if let error = errors.first {
                status = error
                    .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&quot;", with: "\"")
            } else {
                status = "Imagens LaTeX geradas."
            }
            refreshMediaReport(status: status)
        }
        #endif
    }

    private static func decodeMediaFilename(_ rawName: String) -> String {
        var name = rawName
        for (encoded, decoded) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&#x27;", "'")] {
            name = name.replacingOccurrences(of: encoded, with: decoded, options: .caseInsensitive)
        }
        return name.removingPercentEncoding ?? name
    }

    private static func isLocalMediaFilename(_ name: String) -> Bool {
        !name.isEmpty
            && !name.hasPrefix("data:")
            && !name.hasPrefix("#")
            && !name.hasPrefix("//")
            && !name.contains("://")
            && !name.contains("/")
            && !name.contains("\\")
    }

    private var mediaTrashRoot: URL {
        store.profileDirectory.appendingPathComponent("media.trash", isDirectory: true)
    }

    private func trashUnusedMedia() {
        guard let report = mediaReport else { return }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: mediaTrashRoot, withIntermediateDirectories: true)
            var moved = 0
            var failures: [String] = []
            for filename in report.unused {
                let source = store.mediaRoot.appendingPathComponent(filename)
                let destination = mediaTrashRoot.appendingPathComponent(filename)
                do {
                    guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                    if fileManager.fileExists(atPath: destination.path) {
                        try fileManager.removeItem(at: destination)
                    }
                    try fileManager.moveItem(at: source, to: destination)
                    moved += 1
                } catch {
                    failures.append(filename)
                }
            }
            let status = failures.isEmpty
                ? "Movidos \(moved) arquivo(s) não usado(s) para a lixeira de mídia."
                : "Movidos \(moved); falha ao mover: \(failures.joined(separator: ", "))."
            store.lastError = status
            refreshMediaReport(status: status)
        } catch {
            store.lastError = error.localizedDescription
            mediaCheckStatus = error.localizedDescription
        }
    }

    private func tagNotesWithMissingMedia() {
        guard let report = mediaReport else { return }
        do {
            var tagged = 0
            for noteID in report.missingNoteIDs {
                guard let note = try store.fetchNote(id: noteID), !note.tagList.contains("missing-media") else { continue }
                try store.updateNote(note, fields: note.fields, tags: (note.tagList + ["missing-media"]).joined(separator: " "))
                tagged += 1
            }
            let status = "Adicionada a tag missing-media a \(tagged) nota(s)."
            store.lastError = status
            refreshMediaReport(status: status)
        } catch {
            store.lastError = error.localizedDescription
            mediaCheckStatus = error.localizedDescription
        }
    }

    private func restoreMediaTrash() {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: store.mediaRoot, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: mediaTrashRoot, withIntermediateDirectories: true)
            var restored = 0
            var failures: [String] = []
            for source in try fileManager.contentsOfDirectory(at: mediaTrashRoot, includingPropertiesForKeys: [.isRegularFileKey]) {
                guard source.lastPathComponent != ".DS_Store",
                      try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                do {
                    let destination = store.mediaRoot.appendingPathComponent(source.lastPathComponent)
                    if fileManager.fileExists(atPath: destination.path) {
                        if try mediaFilesAreEqual(source, destination) {
                            try fileManager.removeItem(at: source)
                            restored += 1
                            continue
                        }
                        let name = try uniqueRestoredMediaFilename(for: source)
                        let restoredURL = store.mediaRoot.appendingPathComponent(name)
                        if fileManager.fileExists(atPath: restoredURL.path), try mediaFilesAreEqual(source, restoredURL) {
                            try fileManager.removeItem(at: source)
                        } else {
                            try fileManager.moveItem(at: source, to: restoredURL)
                        }
                    } else {
                        try fileManager.moveItem(at: source, to: destination)
                    }
                    restored += 1
                } catch {
                    failures.append(source.lastPathComponent)
                }
            }
            let status = failures.isEmpty
                ? "Restaurados \(restored) arquivo(s) da lixeira de mídia."
                : "Restaurados \(restored); falha ao restaurar: \(failures.joined(separator: ", "))."
            store.lastError = status
            refreshMediaReport(status: status)
        } catch {
            store.lastError = error.localizedDescription
            mediaCheckStatus = error.localizedDescription
        }
    }

    private func emptyMediaTrash() {
        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: mediaTrashRoot, withIntermediateDirectories: true)
            var removed = 0
            var failures: [String] = []
            for url in try fileManager.contentsOfDirectory(at: mediaTrashRoot, includingPropertiesForKeys: [.isRegularFileKey]) {
                guard url.lastPathComponent != ".DS_Store",
                      try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                do {
                    try fileManager.removeItem(at: url)
                    removed += 1
                } catch {
                    failures.append(url.lastPathComponent)
                }
            }
            let status = failures.isEmpty
                ? "Esvaziada a lixeira de mídia (\(removed) arquivo(s))."
                : "Removidos \(removed); falha ao apagar: \(failures.joined(separator: ", "))."
            store.lastError = status
            refreshMediaReport(status: status)
        } catch {
            store.lastError = error.localizedDescription
            mediaCheckStatus = error.localizedDescription
        }
    }

    private func mediaFilesAreEqual(_ first: URL, _ second: URL) throws -> Bool {
        let firstSize = try FileManager.default.attributesOfItem(atPath: first.path)[.size] as? NSNumber
        let secondSize = try FileManager.default.attributesOfItem(atPath: second.path)[.size] as? NSNumber
        guard firstSize?.int64Value == secondSize?.int64Value else { return false }
        let firstHandle = try FileHandle(forReadingFrom: first)
        let secondHandle = try FileHandle(forReadingFrom: second)
        defer {
            try? firstHandle.close()
            try? secondHandle.close()
        }
        while true {
            let firstChunk = try firstHandle.read(upToCount: 65_536) ?? Data()
            let secondChunk = try secondHandle.read(upToCount: 65_536) ?? Data()
            if firstChunk != secondChunk { return false }
            if firstChunk.isEmpty { return true }
        }
    }

    private func uniqueRestoredMediaFilename(for source: URL) throws -> String {
        let url = URL(fileURLWithPath: source.lastPathComponent)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA1(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        let hashedStem = "\(stem)-\(hash)"
        var suffix = 1
        while true {
            let name: String
            if suffix == 1 {
                name = ext.isEmpty ? hashedStem : "\(hashedStem).\(ext)"
            } else {
                name = ext.isEmpty ? "\(hashedStem)-\(suffix)" : "\(hashedStem)-\(suffix).\(ext)"
            }
            let destination = store.mediaRoot.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: destination.path) { return name }
            if try mediaFilesAreEqual(source, destination) { return name }
            suffix += 1
        }
    }

}

private struct MediaCheckReport {
    var fileCount: Int
    var unused: [String]
    var missing: [String]
    var missingLatex: [AnkiLatexRenderTask]
    var missingNoteIDs: [Int64]
    var folders: [String]
    var trashCount: Int
    var trashBytes: Int64
}

private struct MediaCheckSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showTrashUnusedConfirmation = false
    @State private var showEmptyTrashConfirmation = false

    let report: MediaCheckReport
    let status: String?
    let onRescan: () -> Void
    let onTagMissingNotes: () -> Void
    let onTrashUnused: () -> Void
    let onRestoreTrash: () -> Void
    let onEmptyTrash: () -> Void
    let onRenderLatex: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GlassFormSection(title: "Resumo") {
                        Text("\(report.fileCount) arquivos, \(report.unused.count) não usados e \(report.missing.count) ausentes.")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AppTheme.primaryText)
                        Text("Arquivos iniciados por _ são mantidos. Referências em templates não são verificadas.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(.horizontal, 4)
                        if let status {
                            Text(status)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.good)
                                .padding(.horizontal, 4)
                        }
                        toolButton("Verificar novamente", action: onRescan)
                        #if os(macOS)
                        if !report.missingLatex.isEmpty {
                            toolButton("Gerar imagens LaTeX (\(report.missingLatex.count))", action: onRenderLatex)
                        }
                        #endif
                    }

                    GlassFormSection(title: "Arquivos ausentes (\(report.missing.count))") {
                        if report.missing.isEmpty {
                            Text("Nenhum arquivo ausente.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                        } else {
                            fileList(report.missing)
                            toolButton("Adicionar a tag missing-media às notas", action: onTagMissingNotes)
                                .disabled(report.missingNoteIDs.isEmpty)
                        }
                    }

                    GlassFormSection(title: "Arquivos não usados (\(report.unused.count))") {
                        if report.unused.isEmpty {
                            Text("Nenhum arquivo não usado.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                        } else {
                            fileList(report.unused)
                            Button("Mover arquivos não usados para a lixeira", systemImage: "trash") {
                                showTrashUnusedConfirmation = true
                            }
                            .buttonStyle(GlassButtonStyle(tint: AppTheme.danger, prominent: false, tintStrength: 0.22, expands: true))
                        }
                    }

                    GlassFormSection(title: "Lixeira de mídia (\(report.trashCount))") {
                        Text("\(ByteCountFormatter.string(fromByteCount: report.trashBytes, countStyle: .file))")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(.horizontal, 4)
                        toolButton("Restaurar arquivos da lixeira", action: onRestoreTrash)
                            .disabled(report.trashCount == 0)
                        Button("Esvaziar lixeira", systemImage: "trash.slash", role: .destructive) {
                            showEmptyTrashConfirmation = true
                        }
                        .buttonStyle(GlassButtonStyle(tint: AppTheme.danger, prominent: false, tintStrength: 0.22, expands: true))
                        .disabled(report.trashCount == 0)
                    }

                    if !report.folders.isEmpty {
                        GlassFormSection(title: "Subpastas (\(report.folders.count))") {
                            fileList(report.folders)
                            Text("Subpastas dentro da pasta de mídia não são suportadas pelo Anki.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .padding(.horizontal, 4)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .background(AppBackground())
            .navigationTitle("Verificar mídia")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Concluído") { dismiss() }
                }
            }
            .confirmationDialog("Mover mídia não usada para a lixeira?", isPresented: $showTrashUnusedConfirmation, titleVisibility: .visible) {
                Button("Mover para a lixeira", role: .destructive, action: onTrashUnused)
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Os arquivos poderão ser restaurados ou apagados depois.")
            }
            .confirmationDialog("Esvaziar a lixeira de mídia?", isPresented: $showEmptyTrashConfirmation, titleVisibility: .visible) {
                Button("Esvaziar lixeira", role: .destructive, action: onEmptyTrash)
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Os arquivos removidos não poderão ser restaurados pelo AnkiOS.")
            }
        }
    }

    private func fileList(_ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(names, id: \.self) { name in
                Text(name)
                    .font(.caption.monospaced())
                    .foregroundStyle(AppTheme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 4)
    }

    private func toolButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(GlassButtonStyle(tint: .white, prominent: false, tintStrength: 0.16, expands: true))
    }
}
