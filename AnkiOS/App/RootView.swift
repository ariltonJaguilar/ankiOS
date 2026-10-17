import SwiftUI
#if os(iOS)
import UIKit
#endif

struct RootView: View {
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("ankios.reduceMotion", store: SharedProfiles.defaults) private var reduceMotion = true
    @AppStorage("ankios.minimalistMode", store: SharedProfiles.defaults) private var minimalistMode = false
    @State private var selectedTab: AppTab = .decks
    @State private var pendingToolAction: SettingsView.Action?
    @State private var studyRequested = false
    @State private var pendingNoteCopy: AddNoteCopyRequest?

    var body: some View {
        ZStack {
            AppBackground()
            #if os(macOS)
            macRoot
            #else
            iosRoot
            #endif
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
                        Text(store.collectionSyncMessage ?? "Sincronizando coleção…")
                            .font(.headline)
                            .foregroundStyle(AppTheme.primaryText)
                            .multilineTextAlignment(.center)
                        #if !ANKIOS_PARITY_HARNESS
                        if store.collectionSyncCanCancel {
                            Button("Cancelar sincronização", systemImage: "xmark") {
                                store.cancelAnkiWebSync()
                            }
                            .buttonStyle(GlassButtonStyle(tint: AppTheme.danger, prominent: false, tintStrength: 0.24))
                        }
                        #endif
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
                #if os(iOS)
                .padding(.bottom, 78)
                #else
                .padding(.bottom, 18)
                #endif
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $store.shouldShowTutorial) {
            AnkiTutorialView { store.shouldShowTutorial = false }
                .environmentObject(store)
        }
        #else
        .sheet(isPresented: $store.shouldShowTutorial) {
            AnkiTutorialView { store.shouldShowTutorial = false }
                .environmentObject(store)
                .frame(minWidth: 560, minHeight: 640)
        }
        #endif
        .alert("Error", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            #if !WIDGET_EXTENSION && !ANKIOS_PARITY_HARNESS
            guard phase == .background else { return }
            Task {
                #if os(iOS)
                let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "AnkiWebSync") {}
                defer { UIApplication.shared.endBackgroundTask(backgroundTask) }
                #endif
                await store.syncWithAnkiWebIfAutomaticEnabled()
            }
            #endif
        }
        .task(id: periodicMediaSyncKey) {
            #if !WIDGET_EXTENSION && !ANKIOS_PARITY_HARNESS
            let interval = store.ankiWebPeriodicMediaSyncMinutes
            guard scenePhase == .active,
                  store.ankiWebConfigured,
                  store.ankiWebMediaSyncEnabled,
                  interval > 0 else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(Double(interval * 60)))
                } catch {
                    return
                }
                guard !Task.isCancelled, scenePhase == .active else { return }
                await store.syncAnkiWebMediaOnly()
            }
            #endif
        }
        #if !ANKIOS_PARITY_HARNESS
        .confirmationDialog(
            "Sincronização completa necessária",
            isPresented: Binding(
                get: { store.pendingAnkiWebFullSync != nil },
                set: { if !$0 { store.pendingAnkiWebFullSync = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let prompt = store.pendingAnkiWebFullSync {
                if prompt.direction == .upload || prompt.direction == .either {
                    Button("Enviar coleção local", role: .destructive) {
                        Task { await store.completeAnkiWebFullSync(upload: true) }
                    }
                }
                if prompt.direction == .download || prompt.direction == .either {
                    Button("Baixar coleção do AnkiWeb", role: .destructive) {
                        Task { await store.completeAnkiWebFullSync(upload: false) }
                    }
                }
            }
            Button("Cancelar", role: .cancel) { store.pendingAnkiWebFullSync = nil }
        } message: {
            if let prompt = store.pendingAnkiWebFullSync {
                switch prompt.direction {
                case .either:
                    Text("\(prompt.message) Enviar substitui a coleção do AnkiWeb; baixar substitui a coleção deste aparelho.")
                case .upload:
                    Text("\(prompt.message) A coleção do AnkiWeb será substituída pela coleção deste aparelho.")
                case .download:
                    Text("\(prompt.message) A coleção deste aparelho será substituída pela coleção do AnkiWeb.")
                }
            }
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
        .onOpenURL { url in
            let fileExtension = url.pathExtension.lowercased()
            guard fileExtension == "apkg" || fileExtension == "colpkg" else { return }
            Task { @MainActor in
                while store.isBootstrapping || store.collectionSyncing {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                await store.bootstrapIfNeeded()
                selectedTab = .decks
                store.pendingPackageImport = url
            }
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

    private var periodicMediaSyncKey: String {
        "\(store.activeProfile):\(store.ankiWebSyncSettingsRevision):\(scenePhase == .active)"
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

    #if os(iOS)
    private var iosRoot: some View {
        TabView(selection: $selectedTab) {
            DecksHomeView(studyRequested: $studyRequested)
                .tabItem { Label("Baralhos", systemImage: "rectangle.stack.fill") }
                .tag(AppTab.decks)

            AddNoteHomeView(copyRequest: $pendingNoteCopy)
                .tabItem { Label("Adicionar", systemImage: "plus.circle.fill") }
                .tag(AppTab.add)

            BrowserView(
                onCreateCopy: openCopyInAddScreen,
                onAddNote: openAddScreen,
                onManageNoteTypes: openNoteTypes
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
    #endif

    #if os(macOS)
    private var macRoot: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                Label("Baralhos", systemImage: "rectangle.stack.fill").tag(AppTab.decks)
                Label("Adicionar", systemImage: "plus.circle.fill").tag(AppTab.add)
                Label("Painel", systemImage: "sidebar.left").tag(AppTab.browse)
                Label("Estatísticas", systemImage: "chart.bar.fill").tag(AppTab.stats)
                Label("Ferramentas", systemImage: "wrench.and.screwdriver.fill").tag(AppTab.tools)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            .listStyle(.sidebar)
        } detail: {
            Group {
                switch selectedTab {
                case .decks: DecksHomeView(studyRequested: $studyRequested)
                case .add: AddNoteHomeView(copyRequest: $pendingNoteCopy)
                case .browse:
                    BrowserView(
                        onCreateCopy: openCopyInAddScreen,
                        onAddNote: openAddScreen,
                        onManageNoteTypes: openNoteTypes
                    )
                case .stats: StatsHomeView()
                case .tools: SettingsView(requestedAction: $pendingToolAction)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .focusedSceneValue(\.activeAppTab, selectedTab)
    }
    #endif
}

enum AppTab: Hashable {
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
