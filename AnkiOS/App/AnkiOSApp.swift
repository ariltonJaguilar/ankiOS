import SwiftUI
#if os(iOS)
import UIKit
#endif

@main
struct AnkiOSApp: App {
    @StateObject private var store = CollectionStore.shared
    @AppStorage("ankios.themeMode", store: SharedProfiles.defaults) private var themeMode = 0

    init() {
        WidgetStudyBridge.install()
        #if os(iOS)
        UIWindow.appearance().backgroundColor = UIColor.systemBackground
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(preferredColorScheme)
                .task {
                    await store.bootstrapIfNeeded()
                    #if !WIDGET_EXTENSION && !ANKIOS_PARITY_HARNESS
                    await store.syncWithAnkiWebIfAutomaticEnabled()
                    #endif
                }
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CollectionUndoCommands(store: store)
            CommandGroup(replacing: .newItem) {
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
                Button("Exportar coleção…") {
                    NotificationCenter.default.post(name: .ankiExportCollection, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                Divider()
                Button("Desocultar todos") {
                    NotificationCenter.default.post(name: .ankiUnburyAll, object: nil)
                }
                Button("Preferências…") {
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
        #endif
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
