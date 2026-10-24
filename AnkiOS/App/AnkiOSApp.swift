import SwiftUI
#if os(iOS)
import UIKit
#endif

@main
struct AnkiOSApp: App {
    @StateObject private var store = CollectionStore.shared
    @AppStorage("ankios.themeMode", store: SharedProfiles.defaults) private var themeMode = 0
    @State private var launchLanguageCode: String
    @Environment(\.scenePhase) private var scenePhase
    private var selectedLanguage: AnkiLanguage {
        AnkiLanguageCatalog.language(for: launchLanguageCode)
    }
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    init() {
        #if os(iOS)
        let storedLanguageCode = AnkiLanguageCatalog.appLanguageCode
        #else
        let storedLanguageCode = SharedProfiles.defaults.string(forKey: AnkiLanguageCatalog.preferenceKey)
            .flatMap(AnkiLanguageCatalog.normalizedCode) ?? AnkiLanguageCatalog.defaultLanguageCode
        #endif
        _launchLanguageCode = State(initialValue: storedLanguageCode)
        WidgetStudyBridge.install()
        #if os(iOS)
        UIWindow.appearance().backgroundColor = UIColor.systemBackground
        #endif
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup("AnkiOS", id: "main") {
            rootContent
        }
        .restorationBehavior(.automatic)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CollectionUndoCommands(store: store)
            CommandGroup(replacing: .newItem) {
                Button("Nova janela") {
                    openWindow(id: "main")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("Nova nota") {
                    NotificationCenter.default.post(name: .ankiOpenAdd, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            CommandMenu("AnkiOS") {
                Button("Importar coleção…") {
                    NotificationCenter.default.post(name: .ankiImportApkg, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Importar CSV…") {
                    NotificationCenter.default.post(name: .ankiImportCSV, object: nil)
                }
                Button("mac.command.export-collection") {
                    NotificationCenter.default.post(name: .ankiExportCollection, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                Divider()
                Button("Desocultar todos") {
                    NotificationCenter.default.post(name: .ankiUnburyAll, object: nil)
                }
                Button("mac.command.preferences") {
                    NotificationCenter.default.post(name: .ankiOpenPrefs, object: nil)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
            BrowserNavigationCommands()
            CommandMenu("Estudo") {
                Button("Estudar baralho principal") {
                    NotificationCenter.default.post(name: .ankiStudyMain, object: nil)
                }
                .keyboardShortcut("y", modifiers: [.command])
            }
        }
        #else
        WindowGroup {
            rootContent
        }
        #endif
    }

    private var rootContent: some View {
        RootView()
            .environmentObject(store)
            .environment(\.locale, selectedLanguage.locale)
            .environment(\.layoutDirection, selectedLanguage.isRightToLeft ? .rightToLeft : .leftToRight)
            .preferredColorScheme(preferredColorScheme)
            .task {
                await store.bootstrapIfNeeded()
                #if os(iOS) && !WIDGET_EXTENSION && !ANKIOS_PARITY_HARNESS
                StudyReminderScheduler.refresh(store: store)
                #endif
                #if !WIDGET_EXTENSION && !ANKIOS_PARITY_HARNESS
                await store.syncWithAnkiWebIfAutomaticEnabled()
                #endif
            }
            .onChange(of: store.deckCounts) { _, _ in
                #if os(iOS) && !WIDGET_EXTENSION && !ANKIOS_PARITY_HARNESS
                StudyReminderScheduler.refresh(store: store)
                #endif
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                #if os(iOS) && !WIDGET_EXTENSION && !ANKIOS_PARITY_HARNESS
                StudyReminderScheduler.refresh(store: store)
                #endif
            }
    }

    private var preferredColorScheme: ColorScheme? {
        switch themeMode {
        case 1: .light
        case 2: .dark
        default: nil
        }
    }

}

#if os(macOS)
private struct CollectionUndoCommands: Commands {
    @ObservedObject var store: CollectionStore
    @Environment(\.undoManager) private var undoManager

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(undoTitle) {
                if undoManager?.canUndo == true {
                    undoManager?.undo()
                } else {
                    do { try store.undoMostRecentCollectionAction() }
                    catch { store.lastError = error.localizedDescription }
                }
            }
            .keyboardShortcut("z", modifiers: [.command])
            .disabled(store.collectionSyncing || (undoManager?.canUndo != true && !store.canUndoCollectionAction))

            Button(redoTitle) {
                if undoManager?.canRedo == true {
                    undoManager?.redo()
                } else {
                    do { try store.redoMostRecentCollectionAction() }
                    catch { store.lastError = error.localizedDescription }
                }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(store.collectionSyncing || (undoManager?.canRedo != true && !store.canRedoCollectionAction))
        }
    }

    private var undoTitle: String {
        guard undoManager?.canUndo == true else { return "Desfazer \(store.collectionUndoMessage ?? "")".trimmingCharacters(in: .whitespaces) }
        let action = undoManager?.undoActionName ?? ""
        return action.isEmpty ? "Desfazer" : "Desfazer \(action)"
    }

    private var redoTitle: String {
        guard undoManager?.canRedo == true else { return "Refazer \(store.collectionRedoMessage ?? "")".trimmingCharacters(in: .whitespaces) }
        let action = undoManager?.redoActionName ?? ""
        return action.isEmpty ? "Refazer" : "Refazer \(action)"
    }
}

private struct BrowserNavigationCommands: Commands {
    @FocusedValue(\.activeAppTab) private var activeAppTab

    var body: some Commands {
        CommandMenu("Navegação") {
            Button("Abrir Painel") {
                NotificationCenter.default.post(name: .ankiOpenBrowser, object: nil)
            }
            .keyboardShortcut("b", modifiers: [])
            .disabled(activeAppTab != .decks)
        }
    }
}
#endif

extension Notification.Name {
    static let ankiOpenAdd = Notification.Name("ankiOpenAdd")
    static let ankiImportApkg = Notification.Name("ankiImportApkg")
    static let ankiImportCSV = Notification.Name("ankiImportCSV")
    static let ankiExportCollection = Notification.Name("ankiExportCollection")
    static let ankiUnburyAll = Notification.Name("ankiUnburyAll")
    static let ankiOpenPrefs = Notification.Name("ankiOpenPrefs")
    static let ankiStudyMain = Notification.Name("ankiStudyMain")
    static let ankiOpenBrowser = Notification.Name("ankiOpenBrowser")
}
