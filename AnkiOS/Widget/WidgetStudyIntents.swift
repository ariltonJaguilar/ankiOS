import AppIntents
import WidgetKit

/// The widget runs these intents itself. They never bring the app to the foreground.
@MainActor
enum WidgetStudyBridge {
    static func performGrade(cardID: Int64, rating: Int) async {
        await WidgetSnapshotPublisher.grade(cardID: cardID, rating: rating)
    }
}

struct RevealWidgetCardIntent: AppIntent {
    static let title: LocalizedStringResource = "Mostrar resposta"
    static let openAppWhenRun = false
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .background

    @available(iOS 27.0, macOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .widgetKitExtension }

    @Parameter(title: "Cartão")
    var cardID: String

    init() {
        cardID = ""
    }

    init(cardID: Int64) {
        self.cardID = String(cardID)
    }

    func perform() async throws -> some IntentResult {
        guard let id = Int64(cardID), id != 0 else { return .result() }
        WidgetStudyStore.reveal(cardID: id)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct GradeWidgetCardIntent: AppIntent {
    static let title: LocalizedStringResource = "Responder cartão"
    static let openAppWhenRun = false
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .background

    @available(iOS 27.0, macOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .widgetKitExtension }

    @Parameter(title: "Cartão")
    var cardID: String

    @Parameter(title: "Nota")
    var rating: Int

    init() {
        cardID = ""
        rating = 3
    }

    init(cardID: Int64, rating: Int) {
        self.cardID = String(cardID)
        self.rating = rating
    }

    func perform() async throws -> some IntentResult {
        if let id = Int64(cardID), id != 0 {
            await WidgetSnapshotPublisher.grade(cardID: id, rating: rating)
        }
        return .result()
    }
}

struct StudyAgainWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Revisar estudados"
    static let openAppWhenRun = false
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .background

    @available(iOS 27.0, macOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .widgetKitExtension }

    func perform() async throws -> some IntentResult {
        await WidgetSnapshotPublisher.studyAgain()
        return .result()
    }
}
