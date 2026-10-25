import SwiftUI
import UIKit

@main
struct AnkiOSApp: App {
    @StateObject private var store = CollectionStore.shared
    @AppStorage("ankios.themeMode", store: SharedProfiles.defaults) private var themeMode = 0
    @State private var launchLanguageCode: String
    @Environment(\.scenePhase) private var scenePhase
    private var selectedLanguage: AnkiLanguage {
        AnkiLanguageCatalog.language(for: launchLanguageCode)
    }

    init() {
        let storedLanguageCode = AnkiLanguageCatalog.appLanguageCode
        _launchLanguageCode = State(initialValue: storedLanguageCode)
        WidgetStudyBridge.install()
        UIWindow.appearance().backgroundColor = UIColor.systemBackground
    }

    var body: some Scene {
        WindowGroup {
            rootContent
        }
    }

    private var rootContent: some View {
        RootView()
            .environmentObject(store)
            .environment(\.locale, selectedLanguage.locale)
            .environment(\.layoutDirection, selectedLanguage.isRightToLeft ? .rightToLeft : .leftToRight)
            .preferredColorScheme(preferredColorScheme)
            .task {
                await store.bootstrapIfNeeded()
                #if !WIDGET_EXTENSION
                StudyReminderScheduler.refresh(store: store)
                #endif
                #if !WIDGET_EXTENSION
                await store.syncWithAnkiWebIfAutomaticEnabled()
                #endif
            }
            .onChange(of: store.deckCounts) { _, _ in
                #if !WIDGET_EXTENSION
                StudyReminderScheduler.refresh(store: store)
                #endif
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                #if !WIDGET_EXTENSION
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
