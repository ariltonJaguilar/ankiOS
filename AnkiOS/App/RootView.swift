import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: CollectionStore
    @State private var selectedTab: AppTab = .decks

    var body: some View {
        ZStack {
            AppBackground()
            #if os(macOS)
            macRoot
            #else
            iosRoot
            #endif
        }
        .overlay {
            if store.isBootstrapping {
                BootSplashView()
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
        .onReceive(NotificationCenter.default.publisher(for: .ankiOpenAdd)) { _ in
            selectedTab = .add
        }
        .onReceive(NotificationCenter.default.publisher(for: .ankiOpenPrefs)) { _ in
            selectedTab = .tools
        }
        .onReceive(NotificationCenter.default.publisher(for: .ankiUnburyAll)) { _ in
            try? store.unburyAll()
            store.lastError = "Cartões ocultos restaurados."
        }
        .onReceive(NotificationCenter.default.publisher(for: .ankiImportApkg)) { _ in
            selectedTab = .tools
            NotificationCenter.default.post(name: .ankiTriggerImportApkg, object: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ankiImportCSV)) { _ in
            selectedTab = .tools
            NotificationCenter.default.post(name: .ankiTriggerImportCSV, object: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ankiExportCollection)) { _ in
            selectedTab = .tools
            NotificationCenter.default.post(name: .ankiTriggerExport, object: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ankiStudyMain)) { _ in
            selectedTab = .decks
            NotificationCenter.default.post(name: .ankiTriggerStudyMain, object: nil)
        }
    }

    #if os(iOS)
    private var iosRoot: some View {
        TabView(selection: $selectedTab) {
            DecksHomeView()
                .tabItem { Label("Baralhos", systemImage: "rectangle.stack.fill") }
                .tag(AppTab.decks)

            AddNoteHomeView()
                .tabItem { Label("Adicionar", systemImage: "plus.circle.fill") }
                .tag(AppTab.add)

            BrowserView()
                .tabItem { Label("Painel", systemImage: "sidebar.left") }
                .tag(AppTab.browse)

            StatsHomeView()
                .tabItem { Label("Estatísticas", systemImage: "chart.bar.fill") }
                .tag(AppTab.stats)

            SettingsView()
                .tabItem { Label("Ferramentas", systemImage: "wrench.and.screwdriver.fill") }
                .tag(AppTab.tools)
        }
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
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
                case .decks: DecksHomeView()
                case .add: AddNoteHomeView()
                case .browse: BrowserView()
                case .stats: StatsHomeView()
                case .tools: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
    }
    #endif
}

enum AppTab: Hashable {
    case decks, add, browse, stats, tools
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
            .glassEffect(.regular.tint(.white.opacity(0.08)), in: .rect(cornerRadius: 24))
        }
    }
}
