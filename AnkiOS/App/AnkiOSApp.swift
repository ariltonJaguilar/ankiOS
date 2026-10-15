import SwiftUI
#if os(iOS)
import UIKit
#endif

@main
struct AnkiOSApp: App {
    @StateObject private var store = CollectionStore.shared

    init() {
        WidgetStudyBridge.install()
        #if os(iOS)
        UIWindow.appearance().backgroundColor = UIColor(red: 0.031, green: 0.051, blue: 0.071, alpha: 1)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .task {
                    await store.bootstrapIfNeeded()
                }
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nova nota") {
                    NotificationCenter.default.post(name: .ankiOpenAdd, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            CommandMenu("AnkiOS") {
                Button("Importar .apkg…") {
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
            CommandMenu("Estudo") {
                Button("Estudar baralho principal") {
                    NotificationCenter.default.post(name: .ankiStudyMain, object: nil)
                }
                .keyboardShortcut("y", modifiers: [.command])
            }
        }
        #endif
    }
}

extension Notification.Name {
    static let ankiOpenAdd = Notification.Name("ankiOpenAdd")
    static let ankiImportApkg = Notification.Name("ankiImportApkg")
    static let ankiImportCSV = Notification.Name("ankiImportCSV")
    static let ankiExportCollection = Notification.Name("ankiExportCollection")
    static let ankiUnburyAll = Notification.Name("ankiUnburyAll")
    static let ankiOpenPrefs = Notification.Name("ankiOpenPrefs")
    static let ankiStudyMain = Notification.Name("ankiStudyMain")
    static let ankiTriggerImportApkg = Notification.Name("ankiTriggerImportApkg")
    static let ankiTriggerImportCSV = Notification.Name("ankiTriggerImportCSV")
    static let ankiTriggerExport = Notification.Name("ankiTriggerExport")
    static let ankiTriggerStudyMain = Notification.Name("ankiTriggerStudyMain")
}
