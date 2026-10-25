import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("ankios.reduceMotion", store: SharedProfiles.defaults) private var reduceMotion = true
    @AppStorage("ankios.minimalistMode", store: SharedProfiles.defaults) private var minimalistMode = false
    @SceneStorage("ankios.selectedTab") private var selectedTab: AppTab = .decks
    @State private var pendingToolAction: SettingsView.Action?
    @State private var studyRequested = false
    @State private var pendingNoteCopy: AddNoteCopyRequest?
    @State private var pendingBrowserSearchQuery: String?
    @State private var syncAnkiWebAfterLoginDismissal = false
    @State private var pendingAnkiInfoSuccessURL: URL?

    var body: some View {
        ZStack {
            AppBackground()
            iosRoot
        }
        .disabled(store.collectionSyncing)
        .overlay {
            if store.isBootstrapping {
                BootSplashView()
            }
        }
        .overlay {
            if store.collectionSyncing {
                ZStack {
                    Color.black.opacity(0.28).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(AppTheme.accent)
                        #if !WIDGET_EXTENSION
                        if let progress = store.collectionSyncMediaProgress {
                            AnkiWebMediaProgressView(progress: progress)
                        } else {
                            Text(store.collectionSyncMessage ?? "Sincronizando coleção…")
                                .font(.headline)
                                .foregroundStyle(AppTheme.primaryText)
                                .multilineTextAlignment(.center)
                        }
                        #else
                        Text(store.collectionSyncMessage ?? "Sincronizando coleção…")
                            .font(.headline)
                            .foregroundStyle(AppTheme.primaryText)
                            .multilineTextAlignment(.center)
                        #endif
                        if store.collectionSyncCanCancel {
                            Button("Cancelar sincronização", systemImage: "xmark") {
                                store.cancelAnkiWebSync()
                            }
                            .buttonStyle(GlassButtonStyle(tint: AppTheme.danger, prominent: false, tintStrength: 0.24))
                        }
                    }
                    .padding(28)
                    .ankiGlass(in: RoundedRectangle(cornerRadius: 22))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if store.canUndoNoteDeletion, let undoMessage = store.undoMessage {
                HStack(spacing: 14) {
                    Text(undoMessage)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppTheme.primaryText)
                    Spacer(minLength: 8)
                    Button("Desfazer", systemImage: "arrow.uturn.backward") {
                        do { try store.undoMostRecentCollectionAction() }
                        catch { store.lastError = error.localizedDescription }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.accent)
                    .disabled(store.collectionSyncing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 520)
                .ankiGlass(tint: .black.opacity(0.52), interactive: true, in: Capsule())
                .padding(.horizontal, 16)
                .padding(.bottom, 78)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .fullScreenCover(isPresented: $store.shouldShowTutorial) {
            AnkiTutorialView { store.shouldShowTutorial = false }
                .environmentObject(store)
        }
        #if !WIDGET_EXTENSION
        .sheet(isPresented: Binding(
            get: { store.pendingAnkiWebLoginPanel },
            set: { store.pendingAnkiWebLoginPanel = $0 }
        ), onDismiss: {
            guard syncAnkiWebAfterLoginDismissal else { return }
            syncAnkiWebAfterLoginDismissal = false
            Task { await store.syncWithAnkiWeb() }
        }) {
            AnkiWebLoginPanel(onConnected: { syncAnkiWebAfterLoginDismissal = true })
                .environmentObject(store)
        }
        .sheet(item: $store.pendingAnkiWebFullSync) { prompt in
            AnkiWebFullSyncPanel(
                prompt: prompt,
                onUpload: {
                    Task { await store.completeAnkiWebFullSync(upload: true, prompt: prompt) }
                },
                onDownload: {
                    Task { await store.completeAnkiWebFullSync(upload: false, prompt: prompt) }
                },
                onCancel: { store.pendingAnkiWebFullSync = nil }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        #endif
        .alert("Error", isPresented: errorAlertPresented) {
            Button("OK", role: .cancel) {
                store.lastError = nil
            }
        } message: {
            Text(store.lastError ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            #if !WIDGET_EXTENSION
            guard phase == .background else { return }
            Task {
                let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "AnkiWebSync") {}
                defer { UIApplication.shared.endBackgroundTask(backgroundTask) }
                await store.syncWithAnkiWebIfAutomaticEnabled()
            }
            #endif
        }
        #if !WIDGET_EXTENSION
        .task(id: periodicMediaSyncKey) {
            await runPeriodicMediaSync()
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .ankiOpenAdd)) { _ in
            selectedTab = .add
        }
        .onReceive(NotificationCenter.default.publisher(for: .ankiOpenPrefs)) { _ in
            pendingToolAction = .preferences
            selectedTab = .tools
        }
        .onReceive(NotificationCenter.default.publisher(for: .ankiUnburyAll)) { _ in
            do {
                try store.unburyAll()
                store.lastError = "Cartões ocultos restaurados."
            } catch {
                store.lastError = error.localizedDescription
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ankiImportApkg)) { _ in
            pendingToolAction = .importPackage
            selectedTab = .tools
        }
        .onReceive(NotificationCenter.default.publisher(for: .ankiImportCSV)) { _ in
            pendingToolAction = .importText
            selectedTab = .tools
        }
        .onReceive(NotificationCenter.default.publisher(for: .ankiExportCollection)) { _ in
            pendingToolAction = .exportCollection
            selectedTab = .tools
        }
        .onReceive(NotificationCenter.default.publisher(for: .ankiStudyMain)) { _ in
            studyRequested = true
            selectedTab = .decks
        }
        .onReceive(NotificationCenter.default.publisher(for: .ankiOpenBrowser)) { _ in
            selectedTab = .browse
        }
        .onOpenURL { handleSystemURL($0) }
        .confirmationDialog(
            "Allow access to add information?",
            isPresented: Binding(
                get: { pendingAnkiInfoSuccessURL != nil },
                set: { if !$0 { pendingAnkiInfoSuccessURL = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Permitir") { copyAnkiInfoAndReturn() }
            Button("Cancelar", role: .cancel) { pendingAnkiInfoSuccessURL = nil }
        } message: {
            Text("The requesting app will receive the profile, deck, and note type names via the clipboard.")
        }
        .task(id: store.activeProfile) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                do {
                    try store.createAutomaticBackupIfNeeded()
                } catch {
                    store.lastError = error.localizedDescription
                }
            }
        }
        .modifier(ReducedMotionViewModifier(isEnabled: reduceMotion || systemReduceMotion || minimalistMode, isMinimalist: minimalistMode))
    }

    #if !WIDGET_EXTENSION
    private var periodicMediaSyncKey: String {
        "\(store.activeProfile):\(store.ankiWebSyncSettingsRevision):\(scenePhase == .active)"
    }

    private func runPeriodicMediaSync() async {
        let interval = store.ankiWebPeriodicMediaSyncMinutes
        guard scenePhase == .active,
              store.ankiWebConfigured,
              store.ankiWebMediaSyncEnabled,
              interval > 0 else { return }
        let delay = Duration.seconds(Double(interval) * 60)
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let isSceneActive = scenePhase == ScenePhase.active
            guard isSceneActive else { return }
            await store.syncAnkiWebMediaOnly()
        }
    }
    #endif

    private var errorAlertPresented: Binding<Bool> {
        Binding(
            get: { store.lastError != nil },
            set: { isPresented in
                if !isPresented { store.lastError = nil }
            }
        )
    }

    private func openCopyInAddScreen(_ request: AddNoteCopyRequest) {
        pendingNoteCopy = request
        selectedTab = .add
    }

    private func openAddScreen() {
        pendingNoteCopy = nil
        selectedTab = .add
    }

    private func openNoteTypes() {
        pendingToolAction = .noteTypes
        selectedTab = .tools
    }

    private func handleSystemURL(_ url: URL) {
        if handleAnkiMobileURL(url) { return }
        let scheme = url.scheme
        let host = url.host
        if scheme == "ankios" && host == "study" {
            selectedTab = .decks
            studyRequested = true
            return
        }
        guard PackageImportRoute.canOpenFromSystem(url) else { return }
        let packageImport = PendingPackageImport(
            url: url,
            securityScopedAccess: url.startAccessingSecurityScopedResource()
        )
        Task { @MainActor in
            while store.isBootstrapping || store.collectionSyncing {
                try? await Task.sleep(for: .milliseconds(50))
            }
            await store.bootstrapIfNeeded()
            selectedTab = .decks
            store.pendingPackageImport = packageImport
        }
    }

    private func handleAnkiMobileURL(_ url: URL) -> Bool {
        guard let request = AnkiMobileURLRequest(url: url) else { return false }
        switch request {
        case .launch:
            return true
        case .search(let query):
            Task { @MainActor in
                await waitForCollectionReady()
                pendingBrowserSearchQuery = query
                selectedTab = .browse
            }
        case .sync:
            Task { @MainActor in
                await waitForCollectionReady()
                await store.syncWithAnkiWeb()
            }
        case .addNote(let typeName, let deckName, let fields, let tags, let profile, let allowsDuplicates, let successURL):
            Task { @MainActor in
                await waitForCollectionReady()
                await addNoteFromAnkiURL(
                    typeName: typeName,
                    deckName: deckName,
                    fields: fields,
                    tags: tags,
                    profile: profile,
                    allowsDuplicates: allowsDuplicates,
                    successURL: successURL
                )
            }
        case .infoForAdding(let successURL):
            guard let successURL else {
                store.lastError = AnkiMobileURLRequestError.missingSuccessURL.localizedDescription
                return true
            }
            Task { @MainActor in
                await waitForCollectionReady()
                pendingAnkiInfoSuccessURL = successURL
            }
        }
        return true
    }

    private func waitForCollectionReady() async {
        while store.isBootstrapping || store.collectionSyncing {
            try? await Task.sleep(for: .milliseconds(50))
        }
        await store.bootstrapIfNeeded()
    }

    private func addNoteFromAnkiURL(
        typeName: String?,
        deckName: String?,
        fields: [String: String],
        tags: String?,
        profile: String?,
        allowsDuplicates: Bool,
        successURL: URL?
    ) async {
        do {
            if let profile, profile != store.activeProfile {
                throw AnkiMobileURLRequestError.invalidProfileName
            }
            guard let typeName, let noteType = store.notetypes.first(where: { $0.name == typeName }) else {
                throw AnkiMobileURLRequestError.noteTypeNotFound
            }
            guard let deckName, let deck = store.decks.first(where: { !$0.isFiltered && $0.name == deckName }) else {
                throw AnkiMobileURLRequestError.deckNotFound
            }
            var noteFields = noteType.flds.map { fields[$0.name] ?? "" }
            guard let firstField = noteFields.first,
                  !store.stripHTMLPreservingMediaFilenames(firstField).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AnkiMobileURLRequestError.emptyFirstField
            }
            noteFields = try await importRemoteMedia(in: noteFields)
            if !allowsDuplicates,
               !(try store.duplicateNoteIDs(mid: noteType.id, fields: noteFields)).isEmpty {
                throw AnkiMobileURLRequestError.duplicateNote
            }
            try store.addNote(mid: noteType.id, did: deck.id, fields: noteFields, tags: tags ?? "")
            if let successURL {
                UIApplication.shared.open(successURL, options: [:], completionHandler: nil)
            }
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func importRemoteMedia(in fields: [String]) async throws -> [String] {
        var imported = fields
        for index in imported.indices {
            guard let media = AnkiRemoteMedia(fieldValue: imported[index]) else { continue }
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(from: media.url)
            } catch {
                throw AnkiMobileURLRequestError.mediaDownloadFailed
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw AnkiMobileURLRequestError.mediaDownloadFailed
            }
            let filename = try store.mediaStore.importRemoteFile(data, suggestedName: media.filename)
            let escapedFilename = filename.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            imported[index] = media.isAudio ? "[sound:\(filename)]" : "<img src=\"\(escapedFilename)\">"
        }
        return imported
    }

    private func copyAnkiInfoAndReturn() {
        guard let successURL = pendingAnkiInfoSuccessURL else { return }
        pendingAnkiInfoSuccessURL = nil
        let payload: [String: Any] = [
            "profile": store.activeProfile,
            "decks": store.decks.filter { !$0.isFiltered }.map(\.name),
            "notetypes": store.notetypes.map(\.name)
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            UIPasteboard.general.setData(data, forPasteboardType: "net.ankimobile.json")
            UIApplication.shared.open(successURL, options: [:], completionHandler: nil)
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private var iosRoot: some View {
        TabView(selection: $selectedTab) {
            DecksHomeView(studyRequested: $studyRequested)
                .tabItem { Label("tab.decks", systemImage: "rectangle.stack.fill") }
                .tag(AppTab.decks)

            AddNoteHomeView(copyRequest: $pendingNoteCopy)
                .tabItem { Label("Adicionar", systemImage: "plus.circle.fill") }
                .tag(AppTab.add)

            BrowserView(
                onCreateCopy: openCopyInAddScreen,
                onAddNote: openAddScreen,
                onManageNoteTypes: openNoteTypes,
                isActive: selectedTab == .browse,
                pendingSearchQuery: $pendingBrowserSearchQuery
            )
                .tabItem { Label("Painel", systemImage: "sidebar.left") }
                .tag(AppTab.browse)

            StatsHomeView()
                .tabItem { Label("Estatísticas", systemImage: "chart.bar.fill") }
                .tag(AppTab.stats)

            SettingsView(requestedAction: $pendingToolAction)
                .tabItem { Label("Ferramentas", systemImage: "wrench.and.screwdriver.fill") }
                .tag(AppTab.tools)
        }
    }

}

#if !WIDGET_EXTENSION
private struct AnkiWebMediaProgressView: View {
    let progress: AnkiWebMediaProgress

    var body: some View {
        VStack(spacing: 7) {
            Text("Sincronizando mídia…")
                .font(.headline)
                .foregroundStyle(AppTheme.primaryText)
                .multilineTextAlignment(.center)

            if let count = progress.checkedCount {
                Text("Verificado: \(count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryText)
            }

            if let counts = progress.addedCounts {
                Text("Adicionado: \(counts.uploaded)↑ \(counts.downloaded)↓")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryText)
            }

            if let counts = progress.removedCounts {
                Text("Removido: \(counts.uploaded)↑ \(counts.downloaded)↓")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}
#endif

enum AppTab: String, Hashable {
    case decks, add, browse, stats, tools
}

private struct ReducedMotionViewModifier: ViewModifier {
    let isEnabled: Bool
    let isMinimalist: Bool

    func body(content: Content) -> some View {
        content
            .environment(\.ankiMinimalistMode, isMinimalist)
            .transaction { transaction in
                if isEnabled {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
    }
}

struct ActiveAppTabKey: FocusedValueKey {
    typealias Value = AppTab
}

extension FocusedValues {
    var activeAppTab: AppTab? {
        get { self[ActiveAppTabKey.self] }
        set { self[ActiveAppTabKey.self] = newValue }
    }
}

struct BootSplashView: View {
    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(AppTheme.accent)
                Text("Carregando coleção…")
                    .font(.headline)
                    .foregroundStyle(AppTheme.primaryText)
            }
            .padding(28)
            .ankiGlass(tint: .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 24))
        }
    }
}

private enum AnkiMobileURLRequest {
    case launch
    case addNote(
        typeName: String?,
        deckName: String?,
        fields: [String: String],
        tags: String?,
        profile: String?,
        allowsDuplicates: Bool,
        successURL: URL?
    )
    case infoForAdding(successURL: URL?)
    case search(String)
    case sync

    init?(url: URL) {
        guard url.scheme?.lowercased() == "anki" else { return nil }
        guard url.host?.lowercased() == "x-callback-url" else {
            self = .launch
            return
        }
        let action = url.pathComponents.dropFirst().joined(separator: "/")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var values: [String: String] = [:]
        for item in items where values[item.name] == nil {
            values[item.name] = item.value ?? ""
        }
        let successURL = values["x-success"].flatMap { URL(string: $0) }

        switch action {
        case "addnote":
            var fields: [String: String] = [:]
            for item in items where item.name.hasPrefix("fld") && item.name.count > 3 {
                let name = String(item.name.dropFirst(3))
                if fields[name] == nil { fields[name] = item.value ?? "" }
            }
            self = .addNote(
                typeName: values["type"],
                deckName: values["deck"],
                fields: fields,
                tags: values["tags"],
                profile: values["profile"],
                allowsDuplicates: values["dupes"] == "1",
                successURL: successURL
            )
        case "infoForAdding":
            self = .infoForAdding(successURL: successURL)
        case "search":
            self = .search(values["query"] ?? "")
        case "sync":
            self = .sync
        case "":
            self = .launch
        default:
            return nil
        }
    }
}

private enum AnkiMobileURLRequestError: LocalizedError {
    case missingSuccessURL
    case invalidProfileName
    case noteTypeNotFound
    case deckNotFound
    case emptyFirstField
    case duplicateNote
    case mediaDownloadFailed

    var errorDescription: String? {
        switch self {
        case .missingSuccessURL: String(localized: "An x-success URL must be provided.", table: "Localizable", bundle: .main)
        case .invalidProfileName: String(localized: "Invalid profile name.", table: "Localizable", bundle: .main)
        case .noteTypeNotFound: String(localized: "The provided note type does not exist.", table: "Localizable", bundle: .main)
        case .deckNotFound: String(localized: "The provided deck does not exist.", table: "Localizable", bundle: .main)
        case .emptyFirstField: String(localized: "The first field can not be blank.", table: "Localizable", bundle: .main)
        case .duplicateNote: String(localized: "A note with the same first field already exists.", table: "Localizable", bundle: .main)
        case .mediaDownloadFailed: String(localized: "Unable to download media from the provided URL.", table: "Localizable", bundle: .main)
        }
    }
}

private struct AnkiRemoteMedia {
    let url: URL
    let filename: String
    let isAudio: Bool

    init?(fieldValue: String) {
        let value = fieldValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let url = components.url else { return nil }
        let pathName = components.path.split(separator: "/").last.map(String.init) ?? ""
        let fakePath = components.queryItems?.first(where: { $0.name == "fakePath" })?.value
        let candidate = fakePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? pathName
        let fileExtension = URL(fileURLWithPath: candidate).pathExtension.lowercased()
        let audioExtensions: Set<String> = ["mp3", "wav", "m4a", "ogg", "aac", "flac", "opus", "aiff", "aif", "spx"]
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "svg"]
        guard audioExtensions.contains(fileExtension) || imageExtensions.contains(fileExtension) else { return nil }
        self.url = url
        self.filename = candidate
        self.isAudio = audioExtensions.contains(fileExtension)
    }
}
