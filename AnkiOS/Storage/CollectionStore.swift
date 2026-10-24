import Foundation
import Combine
import SQLite3
import CommonCrypto
import Darwin

/// App Group shared by the app and the study widget. The collection lives here so a
/// widget can grade a card without launching the app.
enum SharedProfiles {
    static let groupID = "group.com.bigbear.AnkiOS"
    private static let profileKey = "ankios.activeProfile"
    nonisolated(unsafe) private static var didMigrate = false

    static var uiTestSession: String? {
        #if DEBUG
        guard let value = ProcessInfo.processInfo.environment["ANKIOS_UI_TEST_SESSION"],
              UUID(uuidString: value) != nil else { return nil }
        return value
        #else
        return nil
        #endif
    }

    static var defaults: UserDefaults {
        if let uiTestSession {
            return UserDefaults(suiteName: "com.bigbear.AnkiOS.uitests.\(uiTestSession)") ?? .standard
        }
        #if ANKIOS_PARITY_HARNESS
        return UserDefaults(suiteName: "com.bigbear.AnkiOS.parity-harness") ?? .standard
        #else
        return UserDefaults(suiteName: groupID) ?? .standard
        #endif
    }

    static var profilesRoot: URL {
        if let uiTestSession {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("AnkiOS-UITests", isDirectory: true)
                .appendingPathComponent(uiTestSession, isDirectory: true)
                .appendingPathComponent("Profiles", isDirectory: true)
        }
        #if ANKIOS_PARITY_HARNESS
        let root = ProcessInfo.processInfo.environment["ANKIOS_PROFILES_ROOT"] ?? "/tmp/ankios-parity/default"
        return URL(fileURLWithPath: root, isDirectory: true)
        #else
        return groupProfiles ?? documentsProfiles
        #endif
    }

    static func migrateLegacyIfNeeded() {
        guard uiTestSession == nil else { return }
        #if !ANKIOS_PARITY_HARNESS
        guard let group = groupProfiles else { return }
        guard !didMigrate else { return }
        didMigrate = true
        if defaults.string(forKey: profileKey) == nil,
           let legacyName = UserDefaults.standard.string(forKey: profileKey) {
            defaults.set(legacyName, forKey: profileKey)
        }
        let fm = FileManager.default
        let legacy = documentsProfiles
        guard fm.fileExists(atPath: legacy.path) else { return }
        let names = (try? fm.contentsOfDirectory(atPath: legacy.path))?.filter { !$0.hasPrefix(".") } ?? []
        guard !names.isEmpty else { return }
        if !fm.fileExists(atPath: group.path) {
            try? fm.createDirectory(at: group.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: legacy, to: group)
            return
        }
        for name in names {
            let src = legacy.appendingPathComponent(name, isDirectory: true)
            let dst = group.appendingPathComponent(name, isDirectory: true)
            let srcNotes = noteCount(src.appendingPathComponent("collection.anki2"))
            let dstNotes = noteCount(dst.appendingPathComponent("collection.anki2"))
            if !fm.fileExists(atPath: dst.path) {
                try? fm.moveItem(at: src, to: dst)
            } else if srcNotes > 0, dstNotes == 0 {
                let aside = fm.temporaryDirectory.appendingPathComponent("ankios-empty-\(UUID().uuidString)")
                try? fm.moveItem(at: dst, to: aside)
                if (try? fm.moveItem(at: src, to: dst)) == nil {
                    try? fm.moveItem(at: aside, to: dst)
                } else {
                    try? fm.removeItem(at: aside)
                }
            }
        }
        #endif
    }

    private static var groupProfiles: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("Profiles", isDirectory: true)
    }

    private static var documentsProfiles: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Profiles", isDirectory: true)
    }

    private static func noteCount(_ database: URL) -> Int {
        guard FileManager.default.fileExists(atPath: database.path) else { return 0 }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            return 0
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM notes", -1, &statement, nil) == SQLITE_OK,
              let statement else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }
}

enum SharedCollectionFileLock {
    final class Token: @unchecked Sendable {
        private var descriptor: Int32

        fileprivate init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        func release() {
            guard descriptor >= 0 else { return }
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            descriptor = -1
        }

        deinit {
            release()
        }
    }

    static func acquire(profilesRoot: URL) throws -> Token {
        let parent = profilesRoot.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let lockURL = parent.appendingPathComponent("collection.sync.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            let code = errno
            Darwin.close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return Token(descriptor: descriptor)
    }
}

/// Why Anki's "you finished this deck for now" screen shows each paragraph.
struct DeckCongrats: Equatable, Sendable {
    var learnCount: Int
    var secsUntilNextLearn: Int
    var reviewRemaining: Bool
    var newRemaining: Bool
    var schedBuried: Bool
    var userBuried: Bool
    var isFiltered: Bool

    var showsLearnMessage: Bool { learnCount > 0 && secsUntilNextLearn < 86_400 }
    var buried: Bool { schedBuried || userBuried }

    /// Anki asks only when both sibling (`-2`) and manual (`-3`) cards are buried.
    var unburyQueues: Set<Int>? {
        if schedBuried && userBuried { return nil }
        if userBuried { return [-3] }
        if schedBuried { return [-2] }
        return []
    }

    static let empty = DeckCongrats(
        learnCount: 0,
        secsUntilNextLearn: 86_400,
        reviewRemaining: false,
        newRemaining: false,
        schedBuried: false,
        userBuried: false,
        isFiltered: false
    )
}

struct CustomStudyAvailability: Equatable, Sendable {
    var newOwn: Int
    var newChildren: Int
    var reviewOwn: Int
    var reviewChildren: Int
    var totalCards: Int
    var tags: [String]

    static let empty = CustomStudyAvailability(
        newOwn: 0, newChildren: 0, reviewOwn: 0, reviewChildren: 0, totalCards: 0, tags: []
    )
}

struct NoteDeletionSnapshot: Sendable {
    let notes: [AnkiNote]
    let cards: [AnkiCard]
    let graves: [AnkiGrave]

    var noteCount: Int { notes.count }
}

struct CollectionActionUndoSnapshot: Sendable {
    let notes: [AnkiNote]
    let cards: [AnkiCard]
    let decks: [AnkiDeck]
    let notetypes: [AnkiNotetype]
    var revlogs: [AnkiRevlog]
    let graves: [AnkiGrave]
    let noteIDs: Set<Int64>
    let trackedCardIDs: Set<Int64>
    let trackedNotetypeIDs: Set<Int64>
    let trackedConfigKeys: Set<String>
    let configValues: [String: AnyCodable]
    let deleteNoteIDs: Set<Int64>
    let deleteDeckIDs: Set<Int64>
    let message: String
    let manualRevlogHighWater: Int64?
    let preserveModificationFields: Bool
    let preserveRevlogWhenRemovingCards: Bool
}

struct AnkiGrave: Hashable, Sendable {
    let usn: Int
    let oid: Int64
    let type: Int
}

enum CustomStudyFailure: LocalizedError {
    case renameExisting
    case noCards

    var errorDescription: String? {
        switch self {
        case .renameExisting:
            "Por favor, primeiro renomeie o já existente Baralho de Estudo Personalizado."
        case .noCards:
            "Nenhum cartão atende aos seus critérios."
        }
    }
}

struct FSRSCardStatistics {
    var cardCount = 0
    var averageStability: Double?
    var averageDifficulty: Double?
    var averageRetrievability: Double?
    var stability: [(label: String, count: Int)] = []
    var difficulty: [(label: String, count: Int)] = []
    var retrievability: [(label: String, count: Int)] = []
}

struct StatsAnswerButtonBreakdown: Identifiable, Sendable {
    var id: String { category }
    var category: String
    var again = 0
    var hard = 0
    var good = 0
    var easy = 0

    var total: Int { again + hard + good + easy }
    var correct: Int { hard + good + easy }
    var correctPercent: Double { total == 0 ? 0 : Double(correct) / Double(total) * 100 }

    mutating func add(_ ease: Int) {
        switch ease {
        case 1: again += 1
        case 2: hard += 1
        case 3: good += 1
        case 4: easy += 1
        default: break
        }
    }
}

struct StatsHourlyBreakdown: Identifiable, Sendable {
    var id: Int { hour }
    var hour: Int
    var count: Int
    var correctPercent: Double
}

struct StatsFutureDuePoint: Identifiable, Sendable {
    var id: Int { offset }
    var offset: Int
    var young: Int
    var mature: Int
    var cumulative: Int
}

struct StatsFutureDueForecast: Sendable {
    var points: [StatsFutureDuePoint] = []
    var dailyLoad = 0
    var hasBacklog = false
    var dueByDay: [Int: Int] = [:]
}

struct StatsIntervalBucket: Identifiable, Sendable {
    var id: Int { bucket }
    var bucket: Int
    var dayValue: Int
    var label: String
    var count: Int
    var cumulativePercent: Double
}

struct StatsIntervalStatistics: Sendable {
    var chunkDays: Int
    var points: [StatsIntervalBucket]
    var averageDays: Double?
    var longestDays: Int?
    var totalCards: Int
}

struct StatsCardDistribution: Sendable {
    var mature = 0
    var youngAndLearning = 0
    var unseen = 0
    var suspendedAndBuried = 0
    var total: Int { mature + youngAndLearning + unseen + suspendedAndBuried }
}

struct StatsCollectionCounts: Sendable {
    var notes = 0
    var cards = 0
}

struct StatsTodaySummary: Sendable {
    var reviews = 0
    var timeMS = 0
    var failed = 0
    var learning = 0
    var review = 0
    var relearning = 0
    var filtered = 0
    var matureCorrect = 0
    var matureTotal = 0

    var correctPercent: Double {
        reviews == 0 ? 0 : Double(reviews - failed) / Double(reviews) * 100
    }
}

@MainActor
struct ReviewKeyboardPreferences {
    var spacebarRatesCard = true
    var answerKeys: [Int: String] = [1: "1", 2: "2", 3: "3", 4: "4"]
}

enum ReviewGestureAction: String, CaseIterable, Identifiable, Sendable {
    case none
    case showAnswer
    case again
    case hard
    case good
    case easy
    case replayAudio
    case undo
    case openTools
    case backToDecks
    case add
    case edit
    case browse
    case cardTemplate
    case customStudy
    case deckStatistics
    case decks
    case emptyFilteredDeck
    case filterCram
    case markAndBury
    case markAndSuspend
    case rebuildFilteredDeck
    case studyOptions
    case unburyDeck
    case scratchpad
    case scratchpadSize
    case scrollUp
    case scrollDown
    case userAction1
    case userAction2
    case userAction3
    case userAction4
    case userAction5
    case userAction6
    case userAction7
    case userAction8
    case buryNote
    case buryCard
    case suspendNote
    case suspendCard
    case mark
    case setFlag1
    case setFlag2
    case setFlag3
    case setFlag4
    case setFlag5
    case setFlag6
    case setFlag7
    case deleteNote
    case createCopy
    case setDueDate
    case forgetCard
    case replayOwnVoice
    case recordOwnVoice
    case deckOptions
    case cardInfo
    case previousCardInfo
    case redo
    case configureAutoAdvance
    case pauseAudio
    case seekBackward
    case seekForward
    case toggleAutoAdvance
    case toggleTopBar
    case toggleBottomBar
    case toggleNightMode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Nenhuma ação"
        case .showAnswer: "Mostrar resposta"
        case .again: "De novo"
        case .hard: "Difícil"
        case .good: "Bom"
        case .easy: "Fácil"
        case .replayAudio: "Reproduzir áudio"
        case .undo: "Desfazer"
        case .openTools: "Abrir ferramentas"
        case .backToDecks: "Voltar aos baralhos"
        default: StudyToolAction(rawValue: rawValue)?.title ?? rawValue
        }
    }

    var systemImage: String {
        switch self {
        case .none: "circle.slash"
        case .openTools: "gearshape"
        case .backToDecks: "rectangle.stack"
        default: StudyToolAction(rawValue: rawValue)?.systemImage ?? "ellipsis.circle"
        }
    }
}

struct ReviewGesturePreferences: Sendable {
    static let zones = [
        "topLeft", "topCenter", "topRight",
        "middleLeft", "middleCenter", "middleRight",
        "bottomLeft", "bottomCenter", "bottomRight"
    ]

    static let zoneSymbols = ["↖", "↑", "↗", "←", "•", "→", "↙", "↓", "↘"]
    static let swipeDirections = ["left", "right", "up", "down"]
    static let swipeTitles = ["Esquerda", "Direita", "Para cima", "Para baixo"]

    var questionActions: [String: String] = [:]
    var answerActions: [String: String] = [:]
    var swipeActions: [String: String] = [:]
    var topBarAction: ReviewGestureAction = .openTools
    var shakeAction: ReviewGestureAction = .undo

    func action(isAnswerShown: Bool, zone: String) -> ReviewGestureAction {
        let actions = isAnswerShown ? answerActions : questionActions
        let fallback: ReviewGestureAction = isAnswerShown
            ? (zone.hasSuffix("Left") ? .again : zone.hasSuffix("Right") ? .good : .none)
            : .showAnswer
        return actions[zone].flatMap(ReviewGestureAction.init(rawValue:)) ?? fallback
    }

    mutating func set(_ action: ReviewGestureAction, isAnswerShown: Bool, zone: String) {
        if isAnswerShown {
            answerActions[zone] = action.rawValue
        } else {
            questionActions[zone] = action.rawValue
        }
    }

    func swipeAction(for direction: String) -> ReviewGestureAction {
        let fallback: ReviewGestureAction
        switch direction {
        case "left": fallback = .openTools
        case "right": fallback = .backToDecks
        default: fallback = .none
        }
        return swipeActions[direction].flatMap(ReviewGestureAction.init(rawValue:)) ?? fallback
    }

    mutating func setSwipe(_ action: ReviewGestureAction, direction: String) {
        swipeActions[direction] = action.rawValue
    }
}

struct ReviewGamepadControl: Identifiable, Sendable {
    let id: String
    let title: String

    static let all: [ReviewGamepadControl] = [
        .init(id: "buttonA", title: "A"),
        .init(id: "buttonB", title: "B"),
        .init(id: "buttonX", title: "X"),
        .init(id: "buttonY", title: "Y"),
        .init(id: "leftShoulder", title: "L1"),
        .init(id: "rightShoulder", title: "R1"),
        .init(id: "leftTrigger", title: "L2"),
        .init(id: "rightTrigger", title: "R2"),
        .init(id: "leftThumbstickButton", title: "L3"),
        .init(id: "rightThumbstickButton", title: "R3"),
        .init(id: "dpadUp", title: "Direcional ↑"),
        .init(id: "dpadDown", title: "Direcional ↓"),
        .init(id: "dpadLeft", title: "Direcional ←"),
        .init(id: "dpadRight", title: "Direcional →"),
        .init(id: "menu", title: "Menu"),
        .init(id: "options", title: "Opções")
    ]
}

struct ReviewGamepadPreferences: Sendable {
    var actions: [String: String] = [:]
    var thumbpadDeadZone = 0.25

    func action(for controlID: String) -> ReviewGestureAction {
        actions[controlID].flatMap(ReviewGestureAction.init(rawValue:)) ?? .none
    }

    mutating func set(_ action: ReviewGestureAction, for controlID: String) {
        actions[controlID] = action.rawValue
    }
}

struct ReviewScratchpadPreferences: Sendable {
    var ignoreFingers = false
    var undoClearsAll = false
    var belowButtons = false
}

struct BrowserSearchRequest: Equatable, Sendable {
    let id = UUID()
    let query: String
}

struct PendingPackageImport: Equatable {
    let url: URL
    let securityScopedAccess: Bool
}

@MainActor
final class CollectionStore: ObservableObject {
    static let shared = CollectionStore()

    @Published var decks: [AnkiDeck] = []
    @Published var notetypes: [AnkiNotetype] = []
    @Published var deckConfigs: [AnkiDeckConfig] = []
    @Published var deckCounts: [Int64: DeckCounts] = [:]
    @Published var isBootstrapping = false
    @Published var lastError: String?
    @Published var conf: [String: Any] = [:]
    @Published var tags: [String: Int] = [:]
    /// Set after the first deck/import lands, until the tutorial is dismissed.
    @Published var shouldShowTutorial = false
    @Published var collectionSyncing = false
    @Published var collectionSyncMessage: String?
    #if !WIDGET_EXTENSION && !ANKIOS_PARITY_HARNESS
    @Published var collectionSyncCanCancel = false
    @Published var pendingAnkiWebFullSync: AnkiWebFullSyncPrompt?
    @Published var ankiWebStatus: String?
    @Published var pendingAnkiWebLoginPanel = false
    private var activeAnkiWebSyncControl: AnkiWebSyncControl?
    #endif
    private var widgetReloadPendingDuringSync = false
    @Published var pendingPackageImport: PendingPackageImport?
    @Published private(set) var browserSearchRequest: BrowserSearchRequest?
    @Published private(set) var undoMessage: String?
    @Published private(set) var undoRevision = 0
    @Published private(set) var browserUndoMessage: String?
    @Published private(set) var browserRedoMessage: String?
    @Published private(set) var collectionUndoMessage: String?
    @Published private(set) var collectionRedoMessage: String?
    @Published private(set) var automaticBackupRevision = 0
    @Published private(set) var reviewKeyboardRevision = 0
    @Published private(set) var reviewGamepadRevision = 0
    @Published private(set) var ankiWebSyncSettingsRevision = 0
    /// Called after due counts change so the study widget can refresh.
    var onWidgetRefresh: (() -> Void)?
    /// Bumps when the widget writes the collection, so an open study screen reloads.
    @Published private(set) var widgetRevision = 0
    private var isPublishingWidget = false

    func requestBrowserSearch(_ query: String) {
        browserSearchRequest = BrowserSearchRequest(query: query)
        NotificationCenter.default.post(name: Notification.Name("ankiOpenBrowser"), object: nil)
    }

    func consumeBrowserSearchRequest(id: UUID) {
        guard browserSearchRequest?.id == id else { return }
        browserSearchRequest = nil
    }

    private(set) var db: SQLiteDatabase! {
        didSet { studyQueueCache = nil }
    }
    /// rslib `CardQueues` for the deck being studied. Answers update it in place; any other
    /// study-relevant change discards it.
    var studyQueueCache: StudyQueues?
    let mediaStore = MediaStore()
    private let fileManager = FileManager.default
    private var lastGeneratedID: Int64 = 0
    private var lastAutomaticBackup: (profile: String, collectionMod: Int64)?
    private var noteDeletionUndoStack: [NoteDeletionSnapshot] = []
    private enum BrowserUndoEntry {
        case action(CollectionActionUndoSnapshot, CollectionActionUndoSnapshot?)
        case deletion
    }
    private enum BrowserRedoEntry {
        case action(forward: CollectionActionUndoSnapshot, backward: CollectionActionUndoSnapshot)
        case deleteNotes([Int64])
    }
    private var browserUndoStack: [BrowserUndoEntry] = []
    private var browserRedoStack: [BrowserRedoEntry] = []
    private enum CollectionUndoSource {
        case study
        case browser
    }
    private var collectionUndoStack: [CollectionUndoSource] = []
    private var collectionRedoStack: [CollectionUndoSource] = []
    private var studySchedulerInstance: Scheduler?

    var canUndoCollectionAction: Bool { !collectionUndoStack.isEmpty }
    var canRedoCollectionAction: Bool { !collectionRedoStack.isEmpty }
    var canUndoNoteDeletion: Bool {
        guard case .browser? = collectionUndoStack.last,
              case .deletion? = browserUndoStack.last else { return false }
        return !noteDeletionUndoStack.isEmpty
    }

    func schedulerForStudySession() -> Scheduler {
        let scheduler: Scheduler
        if let existing = studySchedulerInstance {
            scheduler = existing
        } else {
            scheduler = Scheduler(store: self, tracksCollectionUndo: true)
            studySchedulerInstance = scheduler
        }
        return scheduler
    }

    func registerStudyUndoOperation(_ scheduler: Scheduler) {
        guard studySchedulerInstance === scheduler else { return }
        browserRedoStack.removeAll()
        recordCollectionUndo(.study)
    }

    private func registerBrowserUndoOperation() {
        studySchedulerInstance?.clearRedoHistory()
        recordCollectionUndo(.browser)
    }

    private func recordCollectionUndo(_ source: CollectionUndoSource) {
        collectionRedoStack.removeAll()
        collectionUndoStack.append(source)
        if collectionUndoStack.count > 30 { collectionUndoStack.removeFirst() }
        refreshCollectionUndoMessages()
    }

    func undoMostRecentCollectionAction() throws {
        guard !collectionSyncing else { throw SQLiteError.exec("A coleção está sendo sincronizada.") }
        guard let source = collectionUndoStack.last else { return }
        switch source {
        case .study:
            guard let scheduler = studySchedulerInstance, scheduler.canUndo else {
                throw SQLiteError.exec("A ação de estudo não está mais disponível para desfazer.")
            }
            try scheduler.undo()
        case .browser:
            try undoBrowserActionLocally()
        }
        collectionUndoStack.removeLast()
        collectionRedoStack.append(source)
        if collectionRedoStack.count > 30 { collectionRedoStack.removeFirst() }
        refreshCollectionUndoMessages()
        undoRevision &+= 1
    }

    func redoMostRecentCollectionAction() throws {
        guard !collectionSyncing else { throw SQLiteError.exec("A coleção está sendo sincronizada.") }
        guard let source = collectionRedoStack.last else { return }
        switch source {
        case .study:
            guard let scheduler = studySchedulerInstance, scheduler.canRedo else {
                throw SQLiteError.exec("A ação de estudo não está mais disponível para refazer.")
            }
            try scheduler.redo()
        case .browser:
            try redoBrowserActionLocally()
        }
        collectionRedoStack.removeLast()
        collectionUndoStack.append(source)
        if collectionUndoStack.count > 30 { collectionUndoStack.removeFirst() }
        refreshCollectionUndoMessages()
        undoRevision &+= 1
    }

    private func refreshCollectionUndoMessages() {
        switch collectionUndoStack.last {
        case .study: collectionUndoMessage = "Estudo"
        case .browser: collectionUndoMessage = browserUndoMessage ?? "Ação do navegador"
        case nil: collectionUndoMessage = nil
        }
        switch collectionRedoStack.last {
        case .study: collectionRedoMessage = "Estudo"
        case .browser: collectionRedoMessage = browserRedoMessage ?? "Ação do navegador"
        case nil: collectionRedoMessage = nil
        }
    }

    private func clearCollectionUndoHistory() {
        collectionUndoStack.removeAll()
        collectionRedoStack.removeAll()
        studySchedulerInstance?.clearUndoHistory()
        browserUndoStack.removeAll()
        browserRedoStack.removeAll()
        noteDeletionUndoStack.removeAll()
        undoMessage = nil
        refreshBrowserUndoMessage()
        refreshCollectionUndoMessages()
        undoRevision &+= 1
    }

    /// Collection has something worth studying (notes or a non-Default deck).
    var hasStudyContent: Bool {
        if decks.contains(where: { $0.name != "Default" }) { return true }
        let notes = (try? db?.scalarInt("SELECT COUNT(*) FROM notes")) ?? 0
        return notes > 0
    }

    /// Best deck to study first: top-level non-Default with the most due cards.
    var recommendedStudyDeck: AnkiDeck? {
        let roots = decks.filter { $0.parentName == nil && $0.name != "Default" }
        if let best = roots.max(by: { (deckCounts[$0.id]?.total ?? 0) < (deckCounts[$1.id]?.total ?? 0) }),
           (deckCounts[best.id]?.total ?? 0) > 0 {
            return best
        }
        return roots.first ?? decks.first(where: { $0.name != "Default" })
    }

    private static let profileKey = "ankios.activeProfile"
    private static func ankiWebAutoSyncKey(for profile: String) -> String {
        "ankios.ankiWeb.autoSync.\(profile)"
    }

    private static func ankiWebMediaSyncKey(for profile: String) -> String {
        "ankios.ankiWeb.syncMedia.\(profile)"
    }

    private static func ankiWebForceOneWayKey(for profile: String) -> String {
        "ankios.ankiWeb.forceOneWay.\(profile)"
    }

    private static func ankiWebPeriodicMediaKey(for profile: String) -> String {
        "ankios.ankiWeb.autoSyncMediaMinutes.\(profile)"
    }

    /// Filtered decks keep study order in `due`. A unix timestamp means the card
    /// was already answered in a session that does not reschedule.
    static let filteredOrderCutoff = 100_000_000

    var activeProfile: String {
        get { SharedProfiles.defaults.string(forKey: Self.profileKey) ?? "User 1" }
        set { SharedProfiles.defaults.set(newValue, forKey: Self.profileKey) }
    }

    var reviewKeyboardPreferences: ReviewKeyboardPreferences {
        let defaults = SharedProfiles.defaults
        let stored: [String: Any]
        if let global = defaults.dictionary(forKey: Self.reviewKeyboardPreferencesKey) {
            stored = global
        } else {
            let legacyPrefix = "ankios.reviewKeyboardPreferences."
            let legacyKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(legacyPrefix) }
            let legacy = defaults.dictionary(forKey: Self.legacyReviewKeyboardPreferencesKey(for: activeProfile))
            if let legacy { defaults.set(legacy, forKey: Self.reviewKeyboardPreferencesKey) }
            for key in legacyKeys { defaults.removeObject(forKey: key) }
            stored = legacy ?? [:]
        }
        var preferences = ReviewKeyboardPreferences()
        preferences.spacebarRatesCard = stored["spacebarRatesCard"] as? Bool ?? true
        if let answerKeys = stored["answerKeys"] as? [String: String] {
            for rating in 1...4 {
                preferences.answerKeys[rating] = answerKeys[String(rating)] ?? ""
            }
        }
        return preferences
    }

    func saveReviewKeyboardPreferences(_ preferences: ReviewKeyboardPreferences) {
        let defaults = SharedProfiles.defaults
        let answerKeys = Dictionary(uniqueKeysWithValues: (1...4).map { rating in
            (String(rating), preferences.answerKeys[rating] ?? "")
        })
        defaults.set([
            "spacebarRatesCard": preferences.spacebarRatesCard,
            "answerKeys": answerKeys
        ], forKey: Self.reviewKeyboardPreferencesKey)
        let legacyPrefix = "ankios.reviewKeyboardPreferences."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(legacyPrefix) {
            defaults.removeObject(forKey: key)
        }
        reviewKeyboardRevision += 1
    }

    var reviewGesturePreferences: ReviewGesturePreferences {
        let stored = SharedProfiles.defaults.dictionary(forKey: reviewGesturePreferencesKey) ?? [:]
        return ReviewGesturePreferences(
            questionActions: stored["questionActions"] as? [String: String] ?? [:],
            answerActions: stored["answerActions"] as? [String: String] ?? [:],
            swipeActions: stored["swipeActions"] as? [String: String] ?? [:],
            topBarAction: (stored["topBarAction"] as? String)
                .flatMap(ReviewGestureAction.init(rawValue:)) ?? .openTools,
            shakeAction: (stored["shakeAction"] as? String)
                .flatMap(ReviewGestureAction.init(rawValue:)) ?? .undo
        )
    }

    func saveReviewGesturePreferences(_ preferences: ReviewGesturePreferences) {
        SharedProfiles.defaults.set([
            "questionActions": preferences.questionActions,
            "answerActions": preferences.answerActions,
            "swipeActions": preferences.swipeActions,
            "topBarAction": preferences.topBarAction.rawValue,
            "shakeAction": preferences.shakeAction.rawValue
        ], forKey: reviewGesturePreferencesKey)
    }

    var reviewGamepadPreferences: ReviewGamepadPreferences {
        let stored = SharedProfiles.defaults.dictionary(forKey: reviewGamepadPreferencesKey) ?? [:]
        return ReviewGamepadPreferences(
            actions: stored["actions"] as? [String: String] ?? [:],
            thumbpadDeadZone: stored["thumbpadDeadZone"] as? Double ?? 0.25
        )
    }

    func saveReviewGamepadPreferences(_ preferences: ReviewGamepadPreferences) {
        SharedProfiles.defaults.set([
            "actions": preferences.actions,
            "thumbpadDeadZone": min(max(preferences.thumbpadDeadZone, 0.1), 0.9)
        ], forKey: reviewGamepadPreferencesKey)
        reviewGamepadRevision += 1
    }

    var reviewScratchpadPreferences: ReviewScratchpadPreferences {
        let stored = SharedProfiles.defaults.dictionary(forKey: reviewScratchpadPreferencesKey) ?? [:]
        return ReviewScratchpadPreferences(
            ignoreFingers: stored["ignoreFingers"] as? Bool ?? false,
            undoClearsAll: stored["undoClearsAll"] as? Bool ?? false,
            belowButtons: stored["belowButtons"] as? Bool ?? false
        )
    }

    func saveReviewScratchpadPreferences(_ preferences: ReviewScratchpadPreferences) {
        SharedProfiles.defaults.set([
            "ignoreFingers": preferences.ignoreFingers,
            "undoClearsAll": preferences.undoClearsAll,
            "belowButtons": preferences.belowButtons
        ], forKey: reviewScratchpadPreferencesKey)
    }

    var frequentStudyActions: [StudyToolAction] {
        guard let rawActions = SharedProfiles.defaults.array(forKey: frequentStudyActionsKey) as? [String] else {
            return StudyToolAction.defaultFrequent
        }
        var seen = Set<StudyToolAction>()
        return rawActions.compactMap(StudyToolAction.init(rawValue:)).filter { seen.insert($0).inserted }
    }

    func saveFrequentStudyActions(_ actions: [StudyToolAction]) {
        var seen = Set<StudyToolAction>()
        let uniqueActions = actions.filter { seen.insert($0).inserted }
        SharedProfiles.defaults.set(uniqueActions.map(\.rawValue), forKey: frequentStudyActionsKey)
    }

    var studyUserActionScripts: [String] {
        let stored = SharedProfiles.defaults.stringArray(forKey: studyUserActionScriptsKey) ?? []
        return (0..<8).map { stored.indices.contains($0) ? stored[$0] : "" }
    }

    func saveStudyUserActionScripts(_ scripts: [String]) {
        SharedProfiles.defaults.set((0..<8).map { scripts.indices.contains($0) ? scripts[$0] : "" }, forKey: studyUserActionScriptsKey)
    }

    private static let reviewKeyboardPreferencesKey = "ankios.reviewKeyboardPreferences"

    private static func legacyReviewKeyboardPreferencesKey(for profile: String) -> String {
        "ankios.reviewKeyboardPreferences.\(profile)"
    }

    private var reviewGesturePreferencesKey: String {
        Self.reviewGesturePreferencesKey(for: activeProfile)
    }

    private var frequentStudyActionsKey: String {
        Self.frequentStudyActionsKey(for: activeProfile)
    }

    private var studyUserActionScriptsKey: String {
        Self.studyUserActionScriptsKey(for: activeProfile)
    }

    private var reviewGamepadPreferencesKey: String {
        Self.reviewGamepadPreferencesKey(for: activeProfile)
    }

    private var reviewScratchpadPreferencesKey: String {
        Self.reviewScratchpadPreferencesKey(for: activeProfile)
    }

    private static func reviewGesturePreferencesKey(for profile: String) -> String {
        "ankios.reviewGesturePreferences.\(profile)"
    }

    private static func frequentStudyActionsKey(for profile: String) -> String {
        "ankios.frequentStudyActions.\(profile)"
    }

    private static func studyUserActionScriptsKey(for profile: String) -> String {
        "ankios.studyUserActionScripts.\(profile)"
    }

    private static func reviewGamepadPreferencesKey(for profile: String) -> String {
        "ankios.reviewGamepadPreferences.\(profile)"
    }

    private static func reviewScratchpadPreferencesKey(for profile: String) -> String {
        "ankios.study.scratchpad.\(profile).preferences"
    }

    private func migrateReviewGesturePreferences(from oldName: String, to newName: String) {
        let defaults = SharedProfiles.defaults
        let oldGestureKey = Self.reviewGesturePreferencesKey(for: oldName)
        if let stored = defaults.dictionary(forKey: oldGestureKey) {
            defaults.set(stored, forKey: Self.reviewGesturePreferencesKey(for: newName))
            defaults.removeObject(forKey: oldGestureKey)
        }
    }

    private func migrateFrequentStudyActions(from oldName: String, to newName: String) {
        let defaults = SharedProfiles.defaults
        let oldKey = Self.frequentStudyActionsKey(for: oldName)
        if let stored = defaults.array(forKey: oldKey) {
            defaults.set(stored, forKey: Self.frequentStudyActionsKey(for: newName))
            defaults.removeObject(forKey: oldKey)
        }
    }

    private func migrateStudyUserActionScripts(from oldName: String, to newName: String) {
        let defaults = SharedProfiles.defaults
        let oldKey = Self.studyUserActionScriptsKey(for: oldName)
        if let stored = defaults.stringArray(forKey: oldKey) {
            defaults.set(stored, forKey: Self.studyUserActionScriptsKey(for: newName))
            defaults.removeObject(forKey: oldKey)
        }
    }

    private func migrateReviewGamepadPreferences(from oldName: String, to newName: String) {
        let defaults = SharedProfiles.defaults
        let oldKey = Self.reviewGamepadPreferencesKey(for: oldName)
        if let stored = defaults.dictionary(forKey: oldKey) {
            defaults.set(stored, forKey: Self.reviewGamepadPreferencesKey(for: newName))
            defaults.removeObject(forKey: oldKey)
        }
    }

    private func migrateStudyScratchpadPreferences(from oldName: String, to newName: String) {
        let defaults = SharedProfiles.defaults
        let enabledPrefix = "ankios.study.scratchpad.\(oldName)."
        let oldSizeKey = "ankios.study.scratchpadSize.\(oldName)"
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(enabledPrefix) || key == oldSizeKey {
            guard let value = defaults.object(forKey: key) else { continue }
            let newKey = key == oldSizeKey
                ? "ankios.study.scratchpadSize.\(newName)"
                : key.replacingOccurrences(of: enabledPrefix, with: "ankios.study.scratchpad.\(newName).")
            defaults.set(value, forKey: newKey)
            defaults.removeObject(forKey: key)
        }
    }

    private func migrateAnkiWebSyncSettings(from oldName: String, to newName: String) {
        let defaults = SharedProfiles.defaults
        let keys = [Self.ankiWebAutoSyncKey, Self.ankiWebMediaSyncKey, Self.ankiWebForceOneWayKey, Self.ankiWebPeriodicMediaKey]
        for key in keys {
            let oldKey = key(oldName)
            guard let value = defaults.object(forKey: oldKey) else { continue }
            defaults.set(value, forKey: key(newName))
            defaults.removeObject(forKey: oldKey)
        }
    }

    var profilesRoot: URL {
        SharedProfiles.migrateLegacyIfNeeded()
        return SharedProfiles.profilesRoot
    }

    var profileDirectory: URL {
        profilesRoot.appendingPathComponent(activeProfile, isDirectory: true)
    }

    var collectionPath: URL {
        #if ANKIOS_PARITY_HARNESS
        return profileDirectory.appendingPathComponent("collection.anki2")
        #else
        // Migrate legacy single-collection layout into the active profile once.
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let legacy = docs.appendingPathComponent("collection.anki2")
        let modern = profileDirectory.appendingPathComponent("collection.anki2")
        if fileManager.fileExists(atPath: legacy.path), !fileManager.fileExists(atPath: modern.path) {
            try? fileManager.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
            try? fileManager.moveItem(at: legacy, to: modern)
            let legacyMedia = docs.appendingPathComponent("collection.media")
            let modernMedia = profileDirectory.appendingPathComponent("collection.media")
            if fileManager.fileExists(atPath: legacyMedia.path), !fileManager.fileExists(atPath: modernMedia.path) {
                try? fileManager.moveItem(at: legacyMedia, to: modernMedia)
            }
        }
        return modern
        #endif
    }

    var mediaRoot: URL {
        profileDirectory.appendingPathComponent("collection.media", isDirectory: true)
    }

    func listProfiles() -> [String] {
        try? fileManager.createDirectory(at: profilesRoot, withIntermediateDirectories: true)
        let names = (try? fileManager.contentsOfDirectory(atPath: profilesRoot.path)) ?? []
        var profiles = names.filter { !$0.hasPrefix(".") }.sorted()
        if profiles.isEmpty { profiles = ["User 1"] }
        if !profiles.contains(activeProfile) { profiles.append(activeProfile); profiles.sort() }
        return profiles
    }

    func createProfile(_ name: String) throws {
        let trimmed = try validatedProfileName(name)
        let dir = profilesRoot.appendingPathComponent(trimmed, isDirectory: true)
        guard !listProfiles().contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }),
              !fileManager.fileExists(atPath: dir.path) else {
            throw SQLiteError.exec("Já existe um perfil com esse nome.")
        }
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func renameProfile(_ oldName: String, to newName: String) async throws {
        let trimmed = try validatedProfileName(newName)
        guard oldName != trimmed else { return }
        let source = profilesRoot.appendingPathComponent(oldName, isDirectory: true)
        let destination = profilesRoot.appendingPathComponent(trimmed, isDirectory: true)
        let caseOnlyRename = oldName.caseInsensitiveCompare(trimmed) == .orderedSame
        guard fileManager.fileExists(atPath: source.path) else {
            throw SQLiteError.exec("Perfil não encontrado.")
        }
        let duplicateProfile = listProfiles().contains {
            $0 != oldName && $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        guard !duplicateProfile, caseOnlyRename || !fileManager.fileExists(atPath: destination.path) else {
            throw SQLiteError.exec("Já existe um perfil com esse nome.")
        }
        let isActive = oldName == activeProfile
        if isActive {
            clearCollectionUndoHistory()
            db?.closeConnection()
            db = nil
        }
        do {
            if caseOnlyRename {
                let temporary = profilesRoot.appendingPathComponent(".profile-rename-\(UUID().uuidString)", isDirectory: true)
                try fileManager.moveItem(at: source, to: temporary)
                do {
                    try fileManager.moveItem(at: temporary, to: destination)
                } catch {
                    try? fileManager.moveItem(at: temporary, to: source)
                    throw error
                }
            } else {
                try fileManager.moveItem(at: source, to: destination)
            }
            migrateReviewGesturePreferences(from: oldName, to: trimmed)
            migrateFrequentStudyActions(from: oldName, to: trimmed)
            migrateStudyUserActionScripts(from: oldName, to: trimmed)
            migrateReviewGamepadPreferences(from: oldName, to: trimmed)
            migrateStudyScratchpadPreferences(from: oldName, to: trimmed)
            migrateAnkiWebSyncSettings(from: oldName, to: trimmed)
            #if !WIDGET_EXTENSION && !ANKIOS_PARITY_HARNESS
            if let auth = AnkiWebCredentialStore.load(profile: oldName) {
                do {
                    try AnkiWebCredentialStore.save(auth, profile: trimmed)
                    AnkiWebCredentialStore.remove(profile: oldName)
                } catch {
                    lastError = error.localizedDescription
                }
            }
            #endif
            if isActive {
                activeProfile = trimmed
                await bootstrapIfNeeded()
                #if !WIDGET_EXTENSION && !ANKIOS_PARITY_HARNESS
                await syncWithAnkiWebIfAutomaticEnabled()
                #endif
            }
        } catch {
            if isActive { await bootstrapIfNeeded() }
            throw error
        }
    }

    func deleteProfile(_ name: String) throws {
        guard name != activeProfile else {
            throw SQLiteError.exec("Troque para outro perfil antes de excluir este.")
        }
        guard listProfiles().count > 1 else {
            throw SQLiteError.exec("O último perfil não pode ser excluído.")
        }
        let directory = profilesRoot.appendingPathComponent(name, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw SQLiteError.exec("Perfil não encontrado.")
        }
        #if os(macOS) && !ANKIOS_PARITY_HARNESS
        try fileManager.trashItem(at: directory, resultingItemURL: nil)
        #else
        try fileManager.removeItem(at: directory)
        #endif
        SharedProfiles.defaults.removeObject(forKey: Self.legacyReviewKeyboardPreferencesKey(for: name))
        SharedProfiles.defaults.removeObject(forKey: Self.reviewGesturePreferencesKey(for: name))
        SharedProfiles.defaults.removeObject(forKey: Self.reviewGamepadPreferencesKey(for: name))
        SharedProfiles.defaults.removeObject(forKey: Self.frequentStudyActionsKey(for: name))
        SharedProfiles.defaults.removeObject(forKey: Self.studyUserActionScriptsKey(for: name))
        let scratchpadPrefix = "ankios.study.scratchpad.\(name)."
        let scratchpadSizeKey = "ankios.study.scratchpadSize.\(name)"
        for key in SharedProfiles.defaults.dictionaryRepresentation().keys where key.hasPrefix(scratchpadPrefix) || key == scratchpadSizeKey {
            SharedProfiles.defaults.removeObject(forKey: key)
        }
        SharedProfiles.defaults.removeObject(forKey: Self.ankiWebAutoSyncKey(for: name))
        SharedProfiles.defaults.removeObject(forKey: Self.ankiWebMediaSyncKey(for: name))
        SharedProfiles.defaults.removeObject(forKey: Self.ankiWebForceOneWayKey(for: name))
        SharedProfiles.defaults.removeObject(forKey: Self.ankiWebPeriodicMediaKey(for: name))
        #if !WIDGET_EXTENSION && !ANKIOS_PARITY_HARNESS
        AnkiWebCredentialStore.remove(profile: name)
        #endif
    }

    private func validatedProfileName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              trimmed.caseInsensitiveCompare("addons21") != .orderedSame,
              !trimmed.contains("/"),
              !trimmed.contains(":"),
              !trimmed.contains("\\") else {
            throw SQLiteError.exec("Nome de perfil inválido.")
        }
        return trimmed
    }

    func switchProfile(to name: String) async {
        clearCollectionUndoHistory()
        #if !WIDGET_EXTENSION && !ANKIOS_PARITY_HARNESS
        pendingAnkiWebFullSync = nil
        #endif
        lastAutomaticBackup = nil
        db?.closeConnection()
        activeProfile = name
        ankiWebSyncSettingsRevision += 1
        db = nil
        decks = []
        notetypes = []
        deckConfigs = []
        deckCounts = [:]
        conf = [:]
        await bootstrapIfNeeded()
        #if !WIDGET_EXTENSION && !ANKIOS_PARITY_HARNESS
        await syncWithAnkiWebIfAutomaticEnabled()
        #endif
    }

    private init() {}

    func closeCollectionConnection() {
        db?.closeConnection()
        db = nil
    }

    var ankiWebAutoSyncEnabled: Bool {
        SharedProfiles.defaults.object(forKey: Self.ankiWebAutoSyncKey(for: activeProfile)) as? Bool ?? true
    }

    var ankiWebMediaSyncEnabled: Bool {
        SharedProfiles.defaults.object(forKey: Self.ankiWebMediaSyncKey(for: activeProfile)) as? Bool ?? true
    }

    var ankiWebForceOneWaySyncNext: Bool {
        SharedProfiles.defaults.object(forKey: Self.ankiWebForceOneWayKey(for: activeProfile)) as? Bool ?? false
    }

    var ankiWebPeriodicMediaSyncMinutes: Int {
        SharedProfiles.defaults.object(forKey: Self.ankiWebPeriodicMediaKey(for: activeProfile)) as? Int ?? 15
    }

    func saveAnkiWebSyncSettings(autoSync: Bool, syncMedia: Bool, forceOneWay: Bool, periodicMediaMinutes: Int) {
        SharedProfiles.defaults.set(autoSync, forKey: Self.ankiWebAutoSyncKey(for: activeProfile))
        SharedProfiles.defaults.set(syncMedia, forKey: Self.ankiWebMediaSyncKey(for: activeProfile))
        SharedProfiles.defaults.set(forceOneWay, forKey: Self.ankiWebForceOneWayKey(for: activeProfile))
        SharedProfiles.defaults.set(max(0, periodicMediaMinutes), forKey: Self.ankiWebPeriodicMediaKey(for: activeProfile))
        ankiWebSyncSettingsRevision += 1
    }

    #if !WIDGET_EXTENSION && !ANKIOS_PARITY_HARNESS
    var ankiWebConfigured: Bool {
        AnkiWebCredentialStore.load(profile: activeProfile) != nil
    }

    var ankiWebUsername: String {
        AnkiWebCredentialStore.username(profile: activeProfile) ?? ""
    }

    func loginAnkiWeb(username: String, password: String) async {
        guard !collectionSyncing else { return }
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty else {
            lastError = "Informe o usuário e a senha do AnkiWeb."
            return
        }
        collectionSyncing = true
        collectionSyncMessage = "Entrando no AnkiWeb…"
        let control = AnkiWebSyncControl()
        activeAnkiWebSyncControl = control
        collectionSyncCanCancel = true
        var syncLock: SharedCollectionFileLock.Token?
        do {
            syncLock = try SharedCollectionFileLock.acquire(profilesRoot: profilesRoot)
            try closeCollectionForBackend()
            let profile = profileDirectory
            let collection = collectionPath
            let media = mediaRoot
            let mediaDatabase = profile.appendingPathComponent("collection.media.db")
            let auth = try await Task.detached(priority: .userInitiated) {
                let backend = try AnkiBackendSession(
                    collectionPath: collection,
                    mediaPath: media,
                    mediaDatabasePath: mediaDatabase
                )
                control.attach(backend)
                defer {
                    try? backend.close()
                    control.finish()
                }
                #if DEBUG
                let testEndpoint = ProcessInfo.processInfo.environment["ANKIOS_UI_SYNC_ENDPOINT"]
                #else
                let testEndpoint: String? = nil
                #endif
                let auth = try backend.login(
                    username: username,
                    password: password,
                    endpoint: testEndpoint
                )
                control.finish()
                try backend.close()
                return auth
            }.value
            if control.isCancelled { throw CancellationError() }
            try AnkiWebCredentialStore.save(auth, profile: activeProfile)
            ankiWebStatus = "Conectado como \(auth.username)."
            ankiWebSyncSettingsRevision += 1
            lastError = nil
        } catch {
            if control.isCancelled {
                ankiWebStatus = "Conexão cancelada."
                lastError = nil
            } else {
                lastError = error.localizedDescription
            }
        }
        control.finish()
        activeAnkiWebSyncControl = nil
        collectionSyncCanCancel = false
        finishBackendCollectionOperation()
        collectionSyncMessage = nil
        collectionSyncing = false
        syncLock?.release()
    }

    func disconnectAnkiWeb() {
        AnkiWebCredentialStore.remove(profile: activeProfile)
        ankiWebStatus = "Conta AnkiWeb desconectada."
        ankiWebSyncSettingsRevision += 1
    }

    func syncWithAnkiWeb() async {
        guard !collectionSyncing else { return }
        guard let auth = AnkiWebCredentialStore.load(profile: activeProfile) else {
            pendingAnkiWebLoginPanel = true
            lastError = nil
            return
        }
        if ankiWebForceOneWaySyncNext {
            pendingAnkiWebFullSync = AnkiWebFullSyncPrompt(
                direction: .either,
                serverUSN: nil,
                message: "A próxima sincronização está configurada para enviar ou baixar a coleção inteira."
            )
            return
        }
        collectionSyncing = true
        collectionSyncMessage = "Sincronizando com AnkiWeb…"
        let control = AnkiWebSyncControl()
        activeAnkiWebSyncControl = control
        collectionSyncCanCancel = true
        var syncLock: SharedCollectionFileLock.Token?
        do {
            syncLock = try SharedCollectionFileLock.acquire(profilesRoot: profilesRoot)
            try closeCollectionForBackend()
            let result = try await runAnkiWebSync(auth: auth, control: control)
            if control.isCancelled { throw CancellationError() }
            var updatedAuth = auth
            if let endpoint = result.newEndpoint {
                updatedAuth.endpoint = endpoint
                try AnkiWebCredentialStore.save(updatedAuth, profile: activeProfile)
            }
            if let prompt = fullSyncPrompt(for: result) {
                pendingAnkiWebFullSync = prompt
                ankiWebStatus = nil
            } else {
                ankiWebStatus = result.serverMessage.isEmpty
                    ? "Sincronização com AnkiWeb concluída."
                    : result.serverMessage
            }
            lastError = nil
        } catch {
            if control.isCancelled {
                ankiWebStatus = "Sincronização cancelada."
                lastError = nil
            } else {
                lastError = error.localizedDescription
            }
        }
        control.finish()
        activeAnkiWebSyncControl = nil
        collectionSyncCanCancel = false
        finishBackendCollectionOperation()
        collectionSyncMessage = nil
        collectionSyncing = false
        syncLock?.release()
    }

    func syncWithAnkiWebIfAutomaticEnabled() async {
        guard ankiWebConfigured, ankiWebAutoSyncEnabled else { return }
        await syncWithAnkiWeb()
    }

    func syncAnkiWebMediaOnly() async {
        guard !collectionSyncing, ankiWebMediaSyncEnabled,
              let auth = AnkiWebCredentialStore.load(profile: activeProfile) else { return }
        collectionSyncing = true
        collectionSyncMessage = "Sincronizando mídia com AnkiWeb…"
        let control = AnkiWebSyncControl()
        activeAnkiWebSyncControl = control
        collectionSyncCanCancel = true
        var syncLock: SharedCollectionFileLock.Token?
        do {
            syncLock = try SharedCollectionFileLock.acquire(profilesRoot: profilesRoot)
            try closeCollectionForBackend()
            try await runAnkiWebMediaSync(auth: auth, control: control)
            if control.isCancelled { throw CancellationError() }
            ankiWebStatus = "Mídia sincronizada com AnkiWeb."
            lastError = nil
        } catch {
            if control.isCancelled {
                ankiWebStatus = "Sincronização de mídia cancelada."
                lastError = nil
            } else {
                lastError = error.localizedDescription
            }
        }
        control.finish()
        activeAnkiWebSyncControl = nil
        collectionSyncCanCancel = false
        finishBackendCollectionOperation()
        collectionSyncMessage = nil
        collectionSyncing = false
        syncLock?.release()
    }

    func completeAnkiWebFullSync(upload: Bool, prompt requestedPrompt: AnkiWebFullSyncPrompt? = nil) async {
        guard !collectionSyncing, let prompt = requestedPrompt ?? pendingAnkiWebFullSync else { return }
        guard let auth = AnkiWebCredentialStore.load(profile: activeProfile) else {
            pendingAnkiWebFullSync = nil
            pendingAnkiWebLoginPanel = true
            lastError = nil
            return
        }
        pendingAnkiWebFullSync = nil
        if ankiWebForceOneWaySyncNext {
            saveAnkiWebSyncSettings(
                autoSync: ankiWebAutoSyncEnabled,
                syncMedia: ankiWebMediaSyncEnabled,
                forceOneWay: false,
                periodicMediaMinutes: ankiWebPeriodicMediaSyncMinutes
            )
        }
        collectionSyncing = true
        collectionSyncMessage = upload ? "Enviando coleção ao AnkiWeb…" : "Baixando coleção do AnkiWeb…"
        let control = AnkiWebSyncControl()
        activeAnkiWebSyncControl = control
        collectionSyncCanCancel = true
        var syncLock: SharedCollectionFileLock.Token?
        do {
            syncLock = try SharedCollectionFileLock.acquire(profilesRoot: profilesRoot)
            _ = try createCollectionBackup()
            lastAutomaticBackup = nil
            try closeCollectionForBackend()
            try await runAnkiWebFullSync(auth: auth, upload: upload, serverUSN: prompt.serverUSN, control: control)
            if control.isCancelled { throw CancellationError() }
            ankiWebStatus = upload
                ? "Coleção enviada ao AnkiWeb."
                : "Coleção baixada do AnkiWeb."
            lastError = nil
        } catch {
            if control.isCancelled {
                ankiWebStatus = "Sincronização cancelada."
                lastError = nil
            } else {
                lastError = error.localizedDescription
            }
        }
        control.finish()
        activeAnkiWebSyncControl = nil
        collectionSyncCanCancel = false
        finishBackendCollectionOperation()
        collectionSyncMessage = nil
        collectionSyncing = false
        syncLock?.release()
    }

    func cancelAnkiWebSync() {
        guard collectionSyncCanCancel else { return }
        guard activeAnkiWebSyncControl?.cancel() == true else {
            collectionSyncCanCancel = false
            return
        }
        collectionSyncCanCancel = false
        collectionSyncMessage = "Cancelando sincronização…"
    }

    private func runAnkiWebSync(auth: AnkiWebAuth, control: AnkiWebSyncControl) async throws -> AnkiWebSyncResponse {
        let collection = collectionPath
        let media = mediaRoot
        let mediaDatabase = profileDirectory.appendingPathComponent("collection.media.db")
        let syncMedia = ankiWebMediaSyncEnabled
        return try await Task.detached(priority: .userInitiated) { [weak self] in
            let backend = try AnkiBackendSession(
                collectionPath: collection,
                mediaPath: media,
                mediaDatabasePath: mediaDatabase
            )
            control.attach(backend)
            defer {
                try? backend.close()
                control.finish()
            }
            let response = try backend.sync(auth: auth, syncMedia: syncMedia) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.collectionSyncing else { return }
                    if let checked = progress?.checked, !checked.isEmpty {
                        self.collectionSyncMessage = "Sincronizando mídia: \(checked)"
                    } else {
                        self.collectionSyncMessage = "Sincronizando mídia com AnkiWeb…"
                    }
                }
            }
            control.finish()
            try backend.close()
            return response
        }.value
    }

    private func runAnkiWebMediaSync(auth: AnkiWebAuth, control: AnkiWebSyncControl) async throws {
        let collection = collectionPath
        let media = mediaRoot
        let mediaDatabase = profileDirectory.appendingPathComponent("collection.media.db")
        try await Task.detached(priority: .userInitiated) { [weak self] in
            let backend = try AnkiBackendSession(
                collectionPath: collection,
                mediaPath: media,
                mediaDatabasePath: mediaDatabase
            )
            control.attach(backend)
            defer {
                try? backend.close()
                control.finish()
            }
            try backend.syncMedia(auth: auth) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.collectionSyncing else { return }
                    if let checked = progress?.checked, !checked.isEmpty {
                        self.collectionSyncMessage = "Sincronizando mídia: \(checked)"
                    }
                }
            }
            control.finish()
            try backend.close()
        }.value
    }

    private func runAnkiWebFullSync(auth: AnkiWebAuth, upload: Bool, serverUSN: Int?, control: AnkiWebSyncControl) async throws {
        let collection = collectionPath
        let media = mediaRoot
        let mediaDatabase = profileDirectory.appendingPathComponent("collection.media.db")
        try await Task.detached(priority: .userInitiated) { [weak self] in
            let backend = try AnkiBackendSession(
                collectionPath: collection,
                mediaPath: media,
                mediaDatabasePath: mediaDatabase
            )
            control.attach(backend)
            defer {
                try? backend.close()
                control.finish()
            }
            try backend.fullSync(auth: auth, upload: upload, serverUSN: serverUSN) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.collectionSyncing else { return }
                    if let checked = progress?.checked, !checked.isEmpty {
                        self.collectionSyncMessage = "Sincronizando mídia: \(checked)"
                    }
                }
            }
            control.finish()
            try backend.close()
        }.value
    }

    private func fullSyncPrompt(for result: AnkiWebSyncResponse) -> AnkiWebFullSyncPrompt? {
        let direction: AnkiWebFullSyncPrompt.Direction
        switch result.required {
        case 2: direction = .either
        case 3: direction = .download
        case 4: direction = .upload
        default: return nil
        }
        let message = result.serverMessage.isEmpty
            ? "A coleção local e a coleção do AnkiWeb precisam ser alinhadas."
            : result.serverMessage
        return AnkiWebFullSyncPrompt(direction: direction, serverUSN: result.serverMediaUsn, message: message)
    }

    private func closeCollectionForBackend() throws {
        guard db != nil else { return }
        try db.exec("PRAGMA wal_checkpoint(TRUNCATE);")
        db.closeConnection()
        db = nil
    }

    private func finishBackendCollectionOperation() {
        if db == nil {
            do {
                try openOrCreate()
                try reloadMeta()
                try refreshCounts()
                clearCollectionUndoHistory()
                clearNoteDeletionUndoHistory()
            } catch {
                lastError = error.localizedDescription
            }
        }
        if widgetReloadPendingDuringSync {
            widgetReloadPendingDuringSync = false
            Task { await reloadAfterExternalEdit() }
        }
    }
    #endif

    func bootstrapIfNeeded() async {
        guard !isBootstrapping else { return }
        isBootstrapping = true
        defer { isBootstrapping = false }
        do {
            try openOrCreate()
            try reloadMeta()
            offerTutorialIfNeeded()
            try reloadMeta()
            try unburySiblingCardsIfNewDay()
            try refreshCounts()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Anki `unbury_if_day_rolled_over`: buried cards (-2 sibling, -3 manual) return at the
    /// start of a new day. The last day is kept in the collection config (`lastUnburied`).
    func unburySiblingCardsIfNewDay() throws {
        let today = schedDay()
        let last = Self.int(conf["lastUnburied"]) ?? 0
        guard last < today || today + 7 < last else { return }
        var ids: [Int64] = []
        try db.query("SELECT id FROM cards WHERE queue IN (-2, -3)") { stmt in
            ids.append(sqlite3_column_int64(stmt, 0))
        }
        if !ids.isEmpty {
            try restoreCardsToActiveQueue(ids, markModified: false, refresh: false)
        }
        var updated = conf
        updated["lastUnburied"] = today
        try saveConf(updated)
    }

    func offerTutorialIfNeeded() {
        #if !WIDGET_EXTENSION
        shouldShowTutorial = TutorialGate.shouldPresent(store: self)
        #endif
    }

    func notifyDeckContentAdded() {
        offerTutorialIfNeeded()
    }

    func openOrCreate() throws {
        try fileManager.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
        let path = collectionPath.path
        let exists = fileManager.fileExists(atPath: path)
        db = try SQLiteDatabase(path: path)
        if !exists {
            try db.exec(CollectionSchema.createSQL)
            let empty = CollectionSchema.emptyColJSON()
            let now = Int64(Date().timeIntervalSince1970)
            try db.run("""
                INSERT INTO col (id, crt, mod, scm, ver, dty, usn, ls, conf, models, decks, dconf, tags)
                VALUES (1, ?, ?, ?, 11, 0, 0, 0, ?, ?, ?, ?, ?)
            """) { stmt in
                SQLiteDatabase.bindInt64(stmt, 1, now)
                SQLiteDatabase.bindInt64(stmt, 2, now * 1000)
                SQLiteDatabase.bindInt64(stmt, 3, now * 1000)
                try SQLiteDatabase.bindText(stmt, 4, empty.conf)
                try SQLiteDatabase.bindText(stmt, 5, empty.models)
                try SQLiteDatabase.bindText(stmt, 6, empty.decks)
                try SQLiteDatabase.bindText(stmt, 7, empty.dconf)
                try SQLiteDatabase.bindText(stmt, 8, empty.tags)
            }
        }
        try CollectionSchema.migrateSortFieldAffinity(in: db)
        try db.exec(CollectionSchema.createSQL)
        try reloadMeta()
        if Self.int(conf["schedVer"]) == 2,
           conf["sched2021"] as? Bool == true,
           !Self.newTimezoneEnabled(in: conf) {
            var updated = conf
            Self.setNewTimezone(
                true,
                collectionCreatedAt: collectionCreation(),
                configuration: &updated
            )
            try saveConf(updated)
        }
        try migrateNoteTextMetadataIfNeeded()
    }

    private func migrateNoteTextMetadataIfNeeded() throws {
        guard (conf["ankiosNoteTextMetadataVersion"] as? Int ?? 0) < 1 else { return }
        var rows: [(id: Int64, mid: Int64, fields: [String])] = []
        try db.query("SELECT id, mid, flds FROM notes") { statement in
            rows.append((
                sqlite3_column_int64(statement, 0),
                sqlite3_column_int64(statement, 1),
                SQLiteDatabase.text(statement, 2).components(separatedBy: "\u{1f}")
            ))
        }
        for row in rows {
            let model = notetype(id: row.mid)
            let configuredSortIndex = model?.sortf ?? 0
            let sortFieldIndex = model?.flds.first(where: { $0.ord == configuredSortIndex })?.ord ?? 0
            let sortField = stripHTMLPreservingMediaFilenames(row.fields.indices.contains(sortFieldIndex) ? row.fields[sortFieldIndex] : "")
            let checksum = fieldChecksum(row.fields.first ?? "")
            try db.run("UPDATE notes SET sfld = ?, csum = ? WHERE id = ?") { statement in
                try SQLiteDatabase.bindText(statement, 1, sortField)
                SQLiteDatabase.bindInt64(statement, 2, checksum)
                SQLiteDatabase.bindInt64(statement, 3, row.id)
            }
        }
        var updated = conf
        updated["ankiosNoteTextMetadataVersion"] = 1
        try saveConf(updated)
    }

    func prepareCollectionReplacement() throws -> URL {
        clearCollectionUndoHistory()
        lastAutomaticBackup = nil
        let destination = collectionPath
        let backup = try createCollectionBackup()
        db.closeConnection()
        db = nil
        try? fileManager.removeItem(atPath: destination.path + "-wal")
        try? fileManager.removeItem(atPath: destination.path + "-shm")
        do {
            try fileManager.removeItem(at: destination)
            try openOrCreate()
            try reloadMeta()
            try refreshCounts()
        } catch {
            try? restoreCollectionBackup(from: backup)
            throw error
        }
        return backup
    }

    func createCollectionBackup() throws -> URL {
        let backupDirectory = profileDirectory.appendingPathComponent("Backups", isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let stamp = Int64(Date().timeIntervalSince1970 * 1000)
        let backup = backupDirectory.appendingPathComponent("collection-\(stamp).anki2")
        try db.exec("PRAGMA wal_checkpoint(TRUNCATE);")
        try db.backup(to: backup)
        return backup
    }

    func collectionBackupPackages() throws -> [URL] {
        let directory = profileDirectory.appendingPathComponent("Backups", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.lastPathComponent.hasPrefix("backup-") && $0.pathExtension == "colpkg" }
        .sorted { lhs, rhs in
            (backupDate(for: lhs) ?? .distantPast) > (backupDate(for: rhs) ?? .distantPast)
        }
    }

    #if WIDGET_EXTENSION
    @discardableResult
    func createAutomaticBackupIfNeeded(force: Bool = false, now: Date = Date()) throws -> URL? { nil }
    #else
    @discardableResult
    func createAutomaticBackupIfNeeded(force: Bool = false, now: Date = Date()) throws -> URL? {
        guard db != nil, !isBootstrapping, !collectionSyncing else { return nil }
        let collectionMod = try db.scalarInt64("SELECT mod FROM col WHERE id = 1")
        if !force,
           lastAutomaticBackup?.profile == activeProfile,
           lastAutomaticBackup?.collectionMod == collectionMod {
            return nil
        }

        let backupSettings = conf["backups"] as? [String: Any] ?? [:]
        let minimumInterval = Self.int(backupSettings["minimum_interval_mins"]) ?? 30
        let backups = try collectionBackupPackages()
        if !force, minimumInterval > 0,
           let latest = backups.compactMap(backupDate(for:)).max(),
           now.timeIntervalSince(latest) < Double(minimumInterval * 60) {
            return nil
        }

        let directory = profileDirectory.appendingPathComponent("Backups", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var backupDate = now
        var destination = directory.appendingPathComponent(backupFileName(for: backupDate))
        while fileManager.fileExists(atPath: destination.path) {
            backupDate = backupDate.addingTimeInterval(1)
            destination = directory.appendingPathComponent(backupFileName(for: backupDate))
        }
        var options = ApkgExportOptions(configuration: conf)
        options.includeScheduling = true
        options.includeDeckPresets = true
        options.includeMedia = false
        try ApkgExporter(store: self).exportCollectionPackage(to: destination, options: options)
        lastAutomaticBackup = (activeProfile, collectionMod)
        let limits = (
            daily: max(0, Self.int(backupSettings["daily"]) ?? 12),
            weekly: max(0, Self.int(backupSettings["weekly"]) ?? 10),
            monthly: max(0, Self.int(backupSettings["monthly"]) ?? 9)
        )
        try thinCollectionBackups(in: directory, limits: limits, now: now)
        automaticBackupRevision += 1
        return destination
    }
    #endif

    private func backupFileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "'backup-'yyyy-MM-dd-HH.mm.ss'.colpkg'"
        return formatter.string(from: date)
    }

    private func backupDate(for url: URL) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.isLenient = false
        formatter.dateFormat = "'backup-'yyyy-MM-dd-HH.mm.ss'.colpkg'"
        return formatter.date(from: url.lastPathComponent)
    }

    private func thinCollectionBackups(
        in directory: URL,
        limits: (daily: Int, weekly: Int, monthly: Int),
        now: Date
    ) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
        let backups = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).compactMap { url -> (url: URL, date: Date)? in
            guard url.lastPathComponent.hasPrefix("backup-"), url.pathExtension == "colpkg",
                  let date = backupDate(for: url) else { return nil }
            return (url, date)
        }.sorted { $0.date > $1.date }

        var dailyRemaining = limits.daily
        var weeklyRemaining = limits.weekly
        var monthlyRemaining = limits.monthly
        var lastKeptDay: Int64?
        var lastKeptWeek: Int?
        var lastKeptMonth: Int?

        for backup in backups {
            let components = calendar.dateComponents([.year, .month, .day, .yearForWeekOfYear, .weekOfYear], from: backup.date)
            let day = Int64(calendar.startOfDay(for: backup.date).timeIntervalSince1970)
            let week = (components.yearForWeekOfYear ?? 0) * 100 + (components.weekOfYear ?? 0)
            let month = (components.year ?? 0) * 12 + (components.month ?? 0)
            var keep = backup.date >= yesterday
            if keep {
                lastKeptDay = day
                lastKeptWeek = week
                lastKeptMonth = month
            } else if dailyRemaining > 0 {
                keep = lastKeptDay.map { day < $0 } ?? true
                if keep {
                    dailyRemaining -= 1
                    lastKeptDay = day
                    lastKeptWeek = week
                    lastKeptMonth = month
                }
            } else if weeklyRemaining > 0 {
                keep = lastKeptWeek.map { week < $0 } ?? true
                if keep {
                    weeklyRemaining -= 1
                    lastKeptDay = day
                    lastKeptWeek = week
                    lastKeptMonth = month
                }
            } else if monthlyRemaining > 0 {
                keep = lastKeptMonth.map { month < $0 } ?? true
                if keep {
                    monthlyRemaining -= 1
                    lastKeptDay = day
                    lastKeptWeek = week
                    lastKeptMonth = month
                }
            }
            if !keep { try fileManager.removeItem(at: backup.url) }
        }
    }

    func restoreCollectionBackup(from backup: URL) throws {
        clearCollectionUndoHistory()
        lastAutomaticBackup = nil
        db?.closeConnection()
        db = nil
        try? fileManager.removeItem(at: collectionPath)
        try? fileManager.removeItem(atPath: collectionPath.path + "-wal")
        try? fileManager.removeItem(atPath: collectionPath.path + "-shm")
        try fileManager.copyItem(at: backup, to: collectionPath)
        try openOrCreate()
        try reloadMeta()
        try refreshCounts()
    }

    // MARK: - Meta reload

    func reloadMeta() throws {
        guard let decksJSON = try db.scalarText("SELECT decks FROM col"),
              let modelsJSON = try db.scalarText("SELECT models FROM col"),
              let dconfJSON = try db.scalarText("SELECT dconf FROM col"),
              let tagsJSON = try db.scalarText("SELECT tags FROM col") else {
            throw SQLiteError.exec("Missing col row")
        }

        conf = try CollectionSchema.collectionConfig(from: db)
        tags = (try JSONSerialization.jsonObject(with: Data(tagsJSON.utf8)) as? [String: Int]) ?? [:]

        let decksObj = try JSONSerialization.jsonObject(with: Data(decksJSON.utf8)) as? [String: [String: Any]] ?? [:]
        decks = decksObj.values.compactMap(Self.parseDeck).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        let modelsData = Data(modelsJSON.utf8)
        let modelsObj = try JSONSerialization.jsonObject(with: modelsData) as? [String: Any] ?? [:]
        var parsedTypes: [AnkiNotetype] = []
        let decoder = JSONDecoder()
        for (key, value) in modelsObj {
            let data = try JSONSerialization.data(withJSONObject: value)
            do {
                parsedTypes.append(try decoder.decode(AnkiNotetype.self, from: data))
            } catch {
                // Last resort: keep a minimal stub so study never blanks on a decode quirk.
                if let dict = value as? [String: Any],
                   let name = dict["name"] as? String,
                   let id = Self.int64(dict["id"]) ?? Int64(key) {
                    let flds = (dict["flds"] as? [[String: Any]] ?? []).enumerated().map { i, f in
                        AnkiField(name: (f["name"] as? String) ?? "Field \(i + 1)", ord: Self.int(f["ord"]) ?? i)
                    }
                    let tmpls = (dict["tmpls"] as? [[String: Any]] ?? []).enumerated().map { i, t in
                        AnkiTemplate(
                            name: (t["name"] as? String) ?? "Card \(i + 1)",
                            ord: Self.int(t["ord"]) ?? i,
                            qfmt: (t["qfmt"] as? String) ?? "",
                            afmt: (t["afmt"] as? String) ?? ""
                        )
                    }
                    parsedTypes.append(AnkiNotetype(
                        id: id, name: name, tmpls: tmpls, flds: flds,
                        css: (dict["css"] as? String) ?? AnkiNotetype.defaultCSS
                    ))
                    lastError = "Notetype “\(name)” loaded with fallback (\(error.localizedDescription))"
                }
            }
        }
        notetypes = parsedTypes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let dconfObj = try JSONSerialization.jsonObject(with: Data(dconfJSON.utf8)) as? [String: Any] ?? [:]
        var configs: [AnkiDeckConfig] = []
        for (_, value) in dconfObj {
            let data = try JSONSerialization.data(withJSONObject: value)
            if let cfg = try? decoder.decode(AnkiDeckConfig.self, from: data) {
                configs.append(cfg)
            }
        }
        if configs.isEmpty { configs = [.default()] }
        deckConfigs = configs.sorted { $0.id < $1.id }
    }

    static func parseDeck(_ dict: [String: Any]) -> AnkiDeck? {
        guard let id = int64(dict["id"]),
              let name = dict["name"] as? String else { return nil }
        let storedRetention = (dict["desiredRetention"] as? NSNumber)?.doubleValue
        let desiredRetention = storedRetention.map { $0 > 1 ? $0 / 100 : $0 }
        return AnkiDeck(
            id: id,
            name: name,
            mod: int64(dict["mod"]) ?? 0,
            usn: int(dict["usn"]) ?? -1,
            collapsed: dict["collapsed"] as? Bool ?? false,
            browserCollapsed: dict["browserCollapsed"] as? Bool ?? false,
            desc: dict["desc"] as? String ?? "",
            markdownDescription: dict["md"] as? Bool ?? false,
            dyn: int(dict["dyn"]) ?? 0,
            conf: int64(dict["conf"]) ?? 1,
            desiredRetention: desiredRetention,
            newLimit: int(dict["newLimit"]),
            reviewLimit: int(dict["reviewLimit"]),
            newLimitToday: parseDayLimit(dict["newLimitToday"]),
            reviewLimitToday: parseDayLimit(dict["reviewLimitToday"]),
            extendNew: int(dict["extendNew"]) ?? 0,
            extendRev: int(dict["extendRev"]) ?? 0,
            newToday: (dict["newToday"] as? [Any])?.compactMap { int($0) } ?? [0, 0],
            revToday: (dict["revToday"] as? [Any])?.compactMap { int($0) } ?? [0, 0],
            lrnToday: (dict["lrnToday"] as? [Any])?.compactMap { int($0) } ?? [0, 0],
            timeToday: (dict["timeToday"] as? [Any])?.compactMap { int($0) } ?? [0, 0],
            searchTerms: (dict["terms"] as? [[Any]])?.first.flatMap { $0.first as? String },
            termLimit: (dict["terms"] as? [[Any]])?.first.flatMap { CollectionStore.int($0.dropFirst().first) },
            resched: dict["resched"] as? Bool,
            previewDelay: int(dict["previewDelay"]),
            searchOrder: (dict["ankiosSearchOrder"] as? String)
                ?? (dict["terms"] as? [[Any]])?.first.flatMap { Self.filteredDeckOrder(int($0.dropFirst(2).first)) },
            includeTags: dict["ankiosIncludeTags"] as? String,
            excludeTags: dict["ankiosExcludeTags"] as? String,
            previewAgain: int(dict["previewAgainSecs"]) ?? int(dict["previewAgain"]),
            previewHard: int(dict["previewHardSecs"]) ?? int(dict["previewHard"]),
            previewGood: int(dict["previewGoodSecs"]) ?? int(dict["previewGood"]),
            searchTerms2: (dict["terms"] as? [[Any]])?.dropFirst().first.flatMap { $0.first as? String },
            termLimit2: (dict["terms"] as? [[Any]])?.dropFirst().first.flatMap { CollectionStore.int($0.dropFirst().first) },
            searchOrder2: (dict["ankiosSearchOrder2"] as? String)
                ?? (dict["terms"] as? [[Any]])?.dropFirst().first.flatMap { Self.filteredDeckOrder(int($0.dropFirst(2).first)) },
            other: Dictionary(uniqueKeysWithValues: dict.filter {
                !["id", "name", "mod", "usn", "collapsed", "browserCollapsed", "desc", "md", "dyn", "conf", "desiredRetention", "newLimit", "reviewLimit", "newLimitToday", "reviewLimitToday", "extendNew", "extendRev", "newToday", "revToday", "lrnToday", "timeToday", "terms", "resched", "previewDelay", "ankiosSearchOrder", "ankiosIncludeTags", "ankiosExcludeTags", "previewAgain", "previewHard", "previewGood", "previewAgainSecs", "previewHardSecs", "previewGoodSecs", "ankiosSearchOrder2"].contains($0.key)
            }.map { ($0.key, AnyCodable($0.value)) })
        )
    }

    private static func parseDayLimit(_ value: Any?) -> AnkiDayLimit? {
        guard let value = value as? [String: Any],
              let limit = int(value["limit"]),
              let today = int(value["today"]) else { return nil }
        return AnkiDayLimit(limit: limit, today: today)
    }

    private static func filteredDeckOrder(_ raw: Int?) -> String? {
        switch raw {
        case 0: "oldest"
        case 1: "random"
        case 2: "ivl"
        case 3: "ivlDesc"
        case 4: "lapses"
        case 5: "added"
        case 6: "due"
        case 7: "latest"
        case 8: "retrievability"
        case 9: "retrievabilityDesc"
        case 10: "relative"
        default: nil
        }
    }

    private static func filteredDeckOrderID(_ raw: String?) -> Int {
        switch raw {
        case "oldest": 0
        case "random": 1
        case "ivl": 2
        case "ivlDesc": 3
        case "lapses": 4
        case "added": 5
        case "due": 6
        case "latest": 7
        case "retrievability": 8
        case "retrievabilityDesc": 9
        case "relative": 10
        default: 6
        }
    }

    // MARK: - Counts

    /// Deck list counts, as rslib `deck_tree(Some(now))`, which unburies on a new day first.
    func refreshCounts() throws {
        try unburySiblingCardsIfNewDay()
        deckCounts = try deckTreeCounts()
        guard !isPublishingWidget else { return }
        isPublishingWidget = true
        defer { isPublishingWidget = false }
        onWidgetRefresh?()
    }

    var totalDueCardCount: Int {
        decks.filter { $0.parentName == nil }.reduce(0) { total, deck in
            total + (deckCounts[deck.id]?.total ?? 0)
        }
    }

    func deckTreeIDs(including rootID: Int64) -> [Int64] {
        guard let root = decks.first(where: { $0.id == rootID }) else { return [rootID] }
        let prefix = root.name + "::"
        let children = decks.filter { $0.id == rootID || $0.name == root.name || $0.name.hasPrefix(prefix) }
        return children.map(\.id)
    }

    func schedDay(at now: Date = Date()) -> Int {
        let creation = (try? db.scalarInt64("SELECT crt FROM col")) ?? Int64(now.timeIntervalSince1970)
        return schedDay(creation: creation, configuration: conf, at: now)
    }

    func schedDay(creation: Int64, configuration: [String: Any], at now: Date) -> Int {
        Self.schedTiming(creation: creation, configuration: configuration, at: now).daysElapsed
    }

    /// Anki `get_v2_rollover`: config key `rollover`, capped to 23; missing or invalid
    /// values become 4. Collections written by older AnkiOS builds used `rollday`.
    static func rolloverHour(in configuration: [String: Any]) -> Int {
        let raw = int(configuration["rollover"]) ?? int(configuration["rollday"])
        guard let raw, (0...255).contains(raw) else { return 4 }
        return min(raw, 23)
    }

    var rolloverHour: Int { Self.rolloverHour(in: conf) }

    func setRolloverHour(_ hour: Int) throws {
        var updated = conf
        updated["rollover"] = min(max(hour, 0), 23)
        updated.removeValue(forKey: "rollday")
        try saveConf(updated)
    }

    static func newTimezoneEnabled(in configuration: [String: Any]) -> Bool {
        int(configuration["creationOffset"]) != nil
    }

    static func setNewTimezone(
        _ enabled: Bool,
        collectionCreatedAt: Int64,
        timeZone: TimeZone = .current,
        configuration: inout [String: Any]
    ) {
        guard enabled else {
            configuration.removeValue(forKey: "creationOffset")
            return
        }
        guard int(configuration["creationOffset"]) == nil else { return }
        let createdAt = Date(timeIntervalSince1970: TimeInterval(collectionCreatedAt))
        configuration["creationOffset"] = -timeZone.secondsFromGMT(for: createdAt) / 60
    }

    /// Anki `timing_for_timestamp` / `sched_timing_today`.
    static func schedTiming(creation: Int64, configuration: [String: Any], at now: Date) -> (daysElapsed: Int, nextDayAt: Int64) {
        let currentOffset = -TimeZone.current.secondsFromGMT(for: now) / 60
        if int(configuration["schedVer"]) == 1 {
            let elapsed = (Int64(now.timeIntervalSince1970) - creation) / 86_400
            return (Int(elapsed), creation + (elapsed + 1) * 86_400)
        }
        let rollover = rolloverHour(in: configuration)
        if let creationOffset = int(configuration["creationOffset"]) {
            return schedulerTiming(
                creation: Date(timeIntervalSince1970: TimeInterval(creation)),
                creationOffsetMinutesWest: min(max(creationOffset, -23 * 60), 23 * 60),
                now: now,
                currentOffsetMinutesWest: currentOffset,
                rollover: rollover
            )
        }
        return legacySchedulerTiming(
            creation: Date(timeIntervalSince1970: TimeInterval(creation)),
            now: now,
            currentOffsetMinutesWest: currentOffset,
            rollover: rollover
        )
    }

    /// Start of the window Anki uses for `added:N` and `rated:N`. Day 1 is today.
    func searchDayStart(days: Int) -> Int64 {
        let n = max(days, 1)
        return schedDayStartTimestamp() - Int64(n - 1) * 86_400
    }

    /// Unix timestamp (seconds) when the current scheduling day started (`next_day_at - 1 day`).
    func schedDayStartTimestamp(at now: Date = Date()) -> Int64 {
        Self.schedTiming(creation: collectionCreation(), configuration: conf, at: now).nextDayAt - 86_400
    }

    private static func legacySchedulerTiming(
        creation: Date,
        now: Date,
        currentOffsetMinutesWest: Int,
        rollover: Int
    ) -> (daysElapsed: Int, nextDayAt: Int64) {
        let timeZone = TimeZone(secondsFromGMT: -currentOffsetMinutesWest * 60) ?? TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let hour = ((rollover % 24) + 24) % 24

        var creationParts = calendar.dateComponents([.year, .month, .day], from: creation)
        creationParts.hour = hour
        creationParts.minute = 0
        creationParts.second = 0
        let creationRollover = calendar.date(from: creationParts) ?? creation

        var nowParts = calendar.dateComponents([.year, .month, .day], from: now)
        nowParts.hour = hour
        nowParts.minute = 0
        nowParts.second = 0
        let rolloverToday = calendar.date(from: nowParts) ?? now
        let nextDay = rolloverToday < now ? rolloverToday.addingTimeInterval(86_400) : rolloverToday
        let daysElapsed = (Int64(now.timeIntervalSince1970) - Int64(creationRollover.timeIntervalSince1970)) / 86_400
        return (max(0, Int(daysElapsed)), Int64(nextDay.timeIntervalSince1970))
    }

    private static func schedulerTiming(
        creation: Date,
        creationOffsetMinutesWest: Int,
        now: Date,
        currentOffsetMinutesWest: Int,
        rollover: Int
    ) -> (daysElapsed: Int, nextDayAt: Int64) {
        let creationZone = TimeZone(secondsFromGMT: -creationOffsetMinutesWest * 60) ?? TimeZone(secondsFromGMT: 0)!
        let currentZone = TimeZone(secondsFromGMT: -currentOffsetMinutesWest * 60) ?? TimeZone(secondsFromGMT: 0)!
        var creationCalendar = Calendar(identifier: .gregorian)
        creationCalendar.timeZone = creationZone
        var currentCalendar = Calendar(identifier: .gregorian)
        currentCalendar.timeZone = currentZone

        let creationParts = creationCalendar.dateComponents([.year, .month, .day], from: creation)
        let nowParts = currentCalendar.dateComponents([.year, .month, .day], from: now)
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let creationUTC = utcCalendar.date(from: creationParts) ?? creation
        let nowUTC = utcCalendar.date(from: nowParts) ?? now
        let calendarDays = utcCalendar.dateComponents([.day], from: creationUTC, to: nowUTC).day ?? 0

        var rolloverParts = nowParts
        rolloverParts.hour = ((rollover % 24) + 24) % 24
        rolloverParts.minute = 0
        rolloverParts.second = 0
        rolloverParts.timeZone = currentZone
        let rolloverToday = currentCalendar.date(from: rolloverParts) ?? now
        let rolloverPassed = rolloverToday <= now
        let elapsed = max(0, calendarDays - (rolloverPassed ? 0 : 1))
        let nextDay = rolloverPassed ? rolloverToday.addingTimeInterval(86_400) : rolloverToday
        return (elapsed, Int64(nextDay.timeIntervalSince1970))
    }

    func collectionCreation() -> Int64 {
        (try? db.scalarInt64("SELECT crt FROM col")) ?? Int64(Date().timeIntervalSince1970)
    }

    // MARK: - Cards / Notes

    func fetchCard(id: Int64) throws -> AnkiCard? {
        var card: AnkiCard?
        try db.query("SELECT * FROM cards WHERE id = ?", bind: { SQLiteDatabase.bindInt64($0, 1, id) }) { stmt in
            card = Self.mapCard(stmt)
        }
        return card
    }

    @discardableResult
    func updateFSRSMemoryStates(configID: Int64, reschedule: Bool, enabled: Bool = true, refresh: Bool = true) throws -> Int {
        guard let config = deckConfigs.first(where: { $0.id == configID }) else { return 0 }
        let assignedDecks = decks.filter { $0.conf == configID && !$0.isFiltered }
        let deckIDs = assignedDecks.map(\.id)
        guard !deckIDs.isEmpty else { return 0 }

        let placeholders = deckIDs.map { _ in "?" }.joined(separator: ",")
        var cards: [AnkiCard] = []
        try db.query(
            "SELECT * FROM cards WHERE did IN (\(placeholders)) OR odid IN (\(placeholders)) ORDER BY id",
            bind: { stmt in
                for (index, id) in deckIDs.enumerated() {
                    SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id)
                    SQLiteDatabase.bindInt64(stmt, Int32(index + deckIDs.count + 1), id)
                }
            }
        ) { stmt in
            cards.append(Self.mapCard(stmt))
        }
        guard !cards.isEmpty else { return 0 }

        let cardIDs = cards.map(\.id)
        var revlogsByCard: [Int64: [AnkiRevlog]] = [:]
        for start in stride(from: 0, to: cardIDs.count, by: 500) {
            let batch = Array(cardIDs[start..<min(start + 500, cardIDs.count)])
            let cardPlaceholders = batch.map { _ in "?" }.joined(separator: ",")
            try db.query(
                "SELECT * FROM revlog WHERE cid IN (\(cardPlaceholders)) ORDER BY cid, id",
                bind: { stmt in
                    for (index, id) in batch.enumerated() {
                        SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id)
                    }
                }
            ) { stmt in
                let review = AnkiRevlog(
                    id: sqlite3_column_int64(stmt, 0),
                    cid: sqlite3_column_int64(stmt, 1),
                    usn: Int(sqlite3_column_int(stmt, 2)),
                    ease: Int(sqlite3_column_int(stmt, 3)),
                    ivl: Int(sqlite3_column_int(stmt, 4)),
                    lastIvl: Int(sqlite3_column_int(stmt, 5)),
                    factor: Int(sqlite3_column_int(stmt, 6)),
                    time: Int(sqlite3_column_int(stmt, 7)),
                    type: Int(sqlite3_column_int(stmt, 8))
                )
                revlogsByCard[review.cid, default: []].append(review)
            }
        }

        let parameters = FSRS6.filledParameters(config.activeFSRSWeights)
        let decay = parameters[20]
        let defaultRetention = Float(min(max(config.desiredRetention ?? 0.9, 0.7), 0.99))
        let historicalRetention = Float(min(max(config.historicalRetention, 0.7), 0.99))
        let cutoff = Self.fsrsIgnoreBeforeTimestamp(config.ignoreRevlogsBeforeDate)
        let nextDayAt = schedDayStartTimestamp() + 86_400
        let today = schedDay()
        let now = Int64(Date().timeIntervalSince1970)
        let decksByID = Dictionary(uniqueKeysWithValues: assignedDecks.map { ($0.id, $0) })
        var changed = 0

        try db.exec("BEGIN IMMEDIATE")
        do {
            for original in cards {
                let history = revlogsByCard[original.id] ?? []
                let retention = Float(min(max(
                    decksByID[original.odid != 0 ? original.odid : original.did]?.desiredRetention ?? Double(defaultRetention),
                    0.7
                ), 0.99))
                var card = original
                let memory: FSRS6.Memory?
                if enabled {
                    memory = FSRS6.memoryState(
                        reviews: history,
                        weights: config.activeFSRSWeights,
                        nextDayAt: nextDayAt,
                        historicalRetention: historicalRetention,
                        ignoreBefore: cutoff
                    )
                    card.data = FSRSCardData.replacingMemory(
                        in: card.data,
                        with: memory,
                        retention: retention,
                        decay: decay
                    )
                } else {
                    memory = nil
                    card.data = FSRSCardData.clearingMemory(in: card.data)
                }
                card.mod = now
                card.usn = -1

                if enabled,
                   reschedule,
                   card.type == AnkiCard.CardType.review.rawValue,
                   card.queue != AnkiCard.Queue.suspended.rawValue,
                   let memory,
                   let lastReview = FSRS6.reviewsAfterLastReset(history).last(where: { $0.ease >= 1 && $0.ease <= 4 && $0.type != 4 }) {
                    let daysElapsed = max(0, Int((nextDayAt - lastReview.id / 1000) / 86_400))
                    let interval = FSRS6.nextInterval(
                        stability: memory.stability,
                        desiredRetention: retention,
                        parameters: parameters
                    )
                    let previousInterval = lastReview.ease > 1 && lastReview.lastIvl >= 0 ? lastReview.lastIvl : 0
                    let minimum = AnkiFuzz.preservedMinimum(
                        interval: Double(interval),
                        previous: previousInterval,
                        maximum: config.rev.maxIvl
                    )
                    let newInterval = AnkiFuzz.apply(
                        factor: AnkiFuzz.factor(cardID: card.id, reps: max(card.reps - 1, 0)),
                        interval: Double(interval),
                        minimum: max(minimum, 1),
                        maximum: config.rev.maxIvl
                    )
                    let newDue = today - daysElapsed + newInterval
                    let oldInterval = card.ivl
                    card.ivl = newInterval
                    if card.odid != 0 {
                        card.odue = newDue
                    } else {
                        card.due = newDue
                    }
                    try insertRevlog(AnkiRevlog(
                        id: timestampID(),
                        cid: card.id,
                        usn: -1,
                        ease: 0,
                        ivl: newInterval,
                        lastIvl: oldInterval,
                        factor: card.factor,
                        time: 0,
                        type: 4
                    ))
                }

                try updateCard(card)
                changed += 1
            }
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
        if refresh { try refreshCounts() }
        return changed
    }

    func rebuildFSRSMemoryStates(enabled: Bool) throws {
        for config in deckConfigs {
            _ = try updateFSRSMemoryStates(configID: config.id, reschedule: false, enabled: enabled, refresh: false)
        }
        try refreshCounts()
    }

    func fsrsTrainingItems(configID: Int64) throws -> [FSRSTrainingItem] {
        guard let config = deckConfigs.first(where: { $0.id == configID }) else { return [] }
        let deckIDs = decks.filter { $0.conf == configID && !$0.isFiltered }.map(\.id)
        guard !deckIDs.isEmpty else { return [] }

        let deckPlaceholders = deckIDs.map { _ in "?" }.joined(separator: ",")
        var eligibleCardIDs = Set<Int64>()
        try db.query(
            "SELECT id FROM cards WHERE did IN (\(deckPlaceholders)) OR odid IN (\(deckPlaceholders))",
            bind: { statement in
                for (index, id) in deckIDs.enumerated() {
                    SQLiteDatabase.bindInt64(statement, Int32(index + 1), id)
                    SQLiteDatabase.bindInt64(statement, Int32(index + deckIDs.count + 1), id)
                }
            }
        ) { statement in
            eligibleCardIDs.insert(sqlite3_column_int64(statement, 0))
        }

        if let query = config.paramSearch?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            var matchingCardIDs = Set<Int64>()
            var offset = 0
            while true {
                let rows = try search(query: query, limit: 500, offset: offset)
                matchingCardIDs.formUnion(rows.map(\.card.id))
                if rows.count < 500 { break }
                offset += rows.count
            }
            eligibleCardIDs.formIntersection(matchingCardIDs)
        }
        guard !eligibleCardIDs.isEmpty else { return [] }

        let cardIDs = eligibleCardIDs.sorted()
        var reviewsByCard: [Int64: [AnkiRevlog]] = [:]
        for start in stride(from: 0, to: cardIDs.count, by: 500) {
            let batch = Array(cardIDs[start..<min(start + 500, cardIDs.count)])
            let placeholders = batch.map { _ in "?" }.joined(separator: ",")
            try db.query(
                "SELECT * FROM revlog WHERE cid IN (\(placeholders)) ORDER BY cid, id",
                bind: { statement in
                    for (index, id) in batch.enumerated() {
                        SQLiteDatabase.bindInt64(statement, Int32(index + 1), id)
                    }
                }
            ) { statement in
                let review = AnkiRevlog(
                    id: sqlite3_column_int64(statement, 0),
                    cid: sqlite3_column_int64(statement, 1),
                    usn: Int(sqlite3_column_int(statement, 2)),
                    ease: Int(sqlite3_column_int(statement, 3)),
                    ivl: Int(sqlite3_column_int(statement, 4)),
                    lastIvl: Int(sqlite3_column_int(statement, 5)),
                    factor: Int(sqlite3_column_int(statement, 6)),
                    time: Int(sqlite3_column_int(statement, 7)),
                    type: Int(sqlite3_column_int(statement, 8))
                )
                reviewsByCard[review.cid, default: []].append(review)
            }
        }

        let cutoff = Self.fsrsIgnoreBeforeTimestamp(config.ignoreRevlogsBeforeDate).map { $0 * 1000 }
        let nextDayAt = schedDayStartTimestamp() + 86_400
        var trainingItems: [FSRSTrainingItem] = []
        for cardID in cardIDs {
            let history = FSRS6.reviewsAfterLastReset(reviewsByCard[cardID] ?? [])
                .filter { $0.ease >= 1 && $0.ease <= 4 && $0.type != 4 && $0.id >= (cutoff ?? 0) }
            guard history.contains(where: { $0.type == 0 }) else { continue }

            var accumulated: [FSRSTrainingReview] = []
            var previousDaysElapsed: Int?
            for review in history {
                let daysElapsed = max(0, Int((nextDayAt - review.id / 1000) / 86_400))
                let delta = previousDaysElapsed.map { max(0, $0 - daysElapsed) } ?? 0
                accumulated.append(FSRSTrainingReview(rating: review.ease, deltaT: delta))
                if accumulated.contains(where: { $0.deltaT > 0 }) {
                    trainingItems.append(FSRSTrainingItem(cardID: cardID, reviews: accumulated))
                }
                previousDaysElapsed = daysElapsed
            }
        }
        return trainingItems
    }

    func fsrsSimulationRequest(configID: Int64, deckID: Int64, additionalNewCards: Int, days: Int) throws -> FSRSSimulationRequest? {
        guard let config = deckConfigs.first(where: { $0.id == configID }) else { return nil }
        let assignedDecks = decks.filter { $0.conf == configID && !$0.isFiltered }
        let deckIDs = assignedDecks.map(\.id)
        guard !deckIDs.isEmpty else { return nil }

        let placeholders = deckIDs.map { _ in "?" }.joined(separator: ",")
        var cards: [AnkiCard] = []
        try db.query(
            "SELECT * FROM cards WHERE (did IN (\(placeholders)) OR odid IN (\(placeholders))) AND queue != -1 ORDER BY id",
            bind: { statement in
                for (index, id) in deckIDs.enumerated() {
                    SQLiteDatabase.bindInt64(statement, Int32(index + 1), id)
                    SQLiteDatabase.bindInt64(statement, Int32(index + deckIDs.count + 1), id)
                }
            }
        ) { statement in
            cards.append(Self.mapCard(statement))
        }
        guard !cards.isEmpty else { return nil }

        let cardIDs = cards.map(\.id)
        var revlogsByCard: [Int64: [AnkiRevlog]] = [:]
        for start in stride(from: 0, to: cardIDs.count, by: 500) {
            let batch = Array(cardIDs[start..<min(start + 500, cardIDs.count)])
            let cardPlaceholders = batch.map { _ in "?" }.joined(separator: ",")
            try db.query(
                "SELECT * FROM revlog WHERE cid IN (\(cardPlaceholders)) ORDER BY cid, id",
                bind: { statement in
                    for (index, id) in batch.enumerated() {
                        SQLiteDatabase.bindInt64(statement, Int32(index + 1), id)
                    }
                }
            ) { statement in
                let review = AnkiRevlog(
                    id: sqlite3_column_int64(statement, 0),
                    cid: sqlite3_column_int64(statement, 1),
                    usn: Int(sqlite3_column_int(statement, 2)),
                    ease: Int(sqlite3_column_int(statement, 3)),
                    ivl: Int(sqlite3_column_int(statement, 4)),
                    lastIvl: Int(sqlite3_column_int(statement, 5)),
                    factor: Int(sqlite3_column_int(statement, 6)),
                    time: Int(sqlite3_column_int(statement, 7)),
                    type: Int(sqlite3_column_int(statement, 8))
                )
                revlogsByCard[review.cid, default: []].append(review)
            }
        }

        let dayCutoff = schedDayStartTimestamp()
        let currentDay = schedDay()
        let nextDayAt = dayCutoff + 86_400
        let parameters = FSRS6.filledParameters(config.activeFSRSWeights)
        let selectedDeck = decks.first { $0.id == deckID }
        let defaultRetention = Float(min(max(selectedDeck?.desiredRetention ?? config.desiredRetention ?? 0.9, 0.7), 0.99))
        let historicalRetention = Float(min(max(config.historicalRetention, 0.7), 0.99))
        let ignoreBefore = Self.fsrsIgnoreBeforeTimestamp(config.ignoreRevlogsBeforeDate)
        let decksByID = Dictionary(uniqueKeysWithValues: assignedDecks.map { ($0.id, $0) })
        let simulationCards = cards.map { card -> FSRSSimulationCard in
            let history = revlogsByCard[card.id] ?? []
            let retention = Float(min(max(
                decksByID[card.odid != 0 ? card.odid : card.did]?.desiredRetention ?? Double(defaultRetention),
                0.7
            ), 0.99))
            let memory = FSRS6.memoryState(
                reviews: history,
                weights: config.activeFSRSWeights,
                nextDayAt: nextDayAt,
                historicalRetention: historicalRetention,
                ignoreBefore: ignoreBefore
            )
            let lastReview = FSRS6.reviewsAfterLastReset(history).last {
                $0.ease >= 1 && $0.ease <= 4 && $0.type != 4 && $0.id / 1000 >= (ignoreBefore ?? 0)
            }
            let lastDate = lastReview.map { Float(Double($0.id / 1000 - dayCutoff) / 86_400) }
            let memoryState = memory ?? FSRS6.Memory(stability: 0, difficulty: 0)
            let schedulingDue = card.odid != 0 ? card.odue : card.due
            let dueOffset = max(schedulingDue - currentDay, 0)
            return FSRSSimulationCard(
                id: card.id,
                difficulty: memoryState.difficulty,
                stability: memoryState.stability,
                lastDate: lastDate,
                due: Float(card.queue == AnkiCard.Queue.siblingBuried.rawValue || card.queue == AnkiCard.Queue.manuallyBuried.rawValue ? max(dueOffset, 1) : dueOffset),
                interval: Float(max(card.ivl, 0)),
                lapses: UInt32(max(card.lapses, 0)),
                desiredRetention: retention
            )
        }
        let reviews = cards.flatMap { revlogsByCard[$0.id] ?? [] }.map { review in
            FSRSSimulationReview(
                id: review.id,
                cid: review.cid,
                usn: Int32(clamping: review.usn),
                buttonChosen: UInt8(clamping: max(review.ease, 1)),
                interval: Int32(clamping: review.ivl),
                lastInterval: Int32(clamping: review.lastIvl),
                easeFactor: UInt32(clamping: max(review.factor, 0)),
                takenMillis: UInt32(clamping: max(review.time, 0)),
                reviewKind: UInt8(clamping: min(max(review.type, 0), 4))
            )
        }
        let today = schedDay()
        let dailyNewLimit = selectedDeck?.newLimitToday?.today == today ? selectedDeck?.newLimitToday?.limit ?? config.new.perDay : (selectedDeck?.newLimit ?? config.new.perDay)
        let dailyReviewLimit = selectedDeck?.reviewLimitToday?.today == today ? selectedDeck?.reviewLimitToday?.limit ?? config.rev.perDay : (selectedDeck?.reviewLimit ?? config.rev.perDay)
        let requestedDays = min(max(days, 1), 3650)
        let totalDeckSize = cards.count + max(additionalNewCards, 0)
        return FSRSSimulationRequest(
            parameters: parameters,
            retention: defaultRetention,
            dayCutoff: dayCutoff,
            deckSize: totalDeckSize,
            days: requestedDays,
            newPerDay: max(dailyNewLimit, 0),
            maxReviewsPerDay: max(dailyReviewLimit, 0),
            newCardsIgnoreReviewLimit: conf["newCardsIgnoreReviewLimit"] as? Bool ?? false,
            maxInterval: Float(max(config.rev.maxIvl, 1)),
            learningStepCount: config.new.delays.count,
            relearningStepCount: config.lapse.delays.count,
            cards: simulationCards,
            revlogs: reviews
        )
    }

    private static func fsrsIgnoreBeforeTimestamp(_ raw: String?) -> Int64? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw).map { Int64($0.timeIntervalSince1970) }
    }

    func fetchNote(id: Int64) throws -> AnkiNote? {
        var note: AnkiNote?
        try db.query("SELECT * FROM notes WHERE id = ?", bind: { SQLiteDatabase.bindInt64($0, 1, id) }) { stmt in
            note = Self.mapNote(stmt)
        }
        return note
    }

    func notetype(id: Int64) -> AnkiNotetype? {
        notetypes.first { $0.id == id }
    }

    func deck(id: Int64) -> AnkiDeck? {
        decks.first { $0.id == id }
    }

    func config(for deck: AnkiDeck) -> AnkiDeckConfig {
        deckConfigs.first { $0.id == deck.conf } ?? .default()
    }

    private static func parseProp(_ token: String, key: String) -> (op: String, value: Int)? {
        let prefix = "prop:\(key)"
        guard token.hasPrefix(prefix) else { return nil }
        let rest = String(token.dropFirst(prefix.count))
        for op in ["<=", ">=", "==", "=", "<", ">"] {
            if rest.hasPrefix(op), let n = Int(rest.dropFirst(op.count)) {
                let sqlOp = op == "==" || op == "=" ? "=" : op
                return (sqlOp, n)
            }
        }
        return nil
    }

    /// `prop:ease>2.5` compares the stored factor (2500), the same scale Anki shows as 250%.
    private static func parsePropScaled(_ token: String, key: String, scale: Double) -> (op: String, value: Int)? {
        let prefix = "prop:\(key)"
        guard token.hasPrefix(prefix) else { return nil }
        let rest = String(token.dropFirst(prefix.count))
        for op in ["<=", ">=", "==", "=", "<", ">"] {
            if rest.hasPrefix(op), let n = Double(rest.dropFirst(op.count)) {
                let sqlOp = op == "==" || op == "=" ? "=" : op
                return (sqlOp, Int((n * scale).rounded()))
            }
        }
        return nil
    }

    /// The deck and all of its parents: the decks rslib `update_deck_stats` touches.
    func deckWithParents(_ deckID: Int64) -> [AnkiDeck] {
        guard let deck = deck(id: deckID) else { return [] }
        return [deck] + parentDecks(of: deck)
    }

    /// Put back decks captured with `deckWithParents` (undo/redo of an answer).
    func restoreDecks(_ snapshot: [AnkiDeck]) throws {
        guard !snapshot.isEmpty else { return }
        var next = decks
        for deck in snapshot {
            if let idx = next.firstIndex(where: { $0.id == deck.id }) { next[idx] = deck }
        }
        try saveDecks(next)
    }

    /// rslib `update_deck_stats`: applied to the deck and all of its parents.
    func updateDeckStats(deckID: Int64, newDelta: Int, reviewDelta: Int, millisecondDelta: Int) throws {
        let today = schedDay()
        let ids = Set(deckWithParents(deckID).map(\.id))
        try mutateStudiedToday(ids: ids, today: today) { studied in
            studied.new += newDelta
            studied.review += reviewDelta
            studied.milliseconds += millisecondDelta
        }
    }

    private func mutateStudiedToday(ids: Set<Int64>, today: Int, _ mutate: (inout DeckStudiedToday) -> Void) throws {
        guard !ids.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970)
        var next = decks
        for idx in next.indices where ids.contains(next[idx].id) {
            var studied = next[idx].studiedToday
            if studied.day != today {
                studied = DeckStudiedToday(day: today, new: 0, review: 0, learning: 0, milliseconds: 0)
            }
            mutate(&studied)
            next[idx].setStudiedToday(studied)
            next[idx].mod = now
            next[idx].usn = -1
        }
        try saveDecks(next)
    }

    private static func reviewRetrievability(_ card: AnkiCard, today: Int, now: Int) -> Float? {
        guard card.type != AnkiCard.CardType.new.rawValue,
              let memory = FSRSCardData.memory(in: card.data) else { return nil }
        let due = card.odue != 0 ? card.odue : card.due
        let elapsed = fsrsElapsedDays(card: card, due: due, today: today, now: now)
        return FSRS6.retrievability(
            daysElapsed: elapsed,
            stability: memory.stability,
            decay: FSRSCardData.decay(in: card.data) ?? FSRS6.defaultDecay
        )
    }

    func browserRetrievability(for card: AnkiCard) -> Float? {
        Self.reviewRetrievability(card, today: schedDay(), now: Int(Date().timeIntervalSince1970))
    }

    private static func fsrsElapsedDays(card: AnkiCard, due: Int, today: Int, now: Int) -> Float {
        fsrsElapsedDays(data: card.data, due: due, interval: card.ivl, today: today, now: now)
    }

    private static func fsrsElapsedDays(data: String, due: Int, interval: Int, today: Int, now: Int) -> Float {
        let now32 = UInt32(truncatingIfNeeded: now)
        let elapsedSeconds: UInt64
        if let lastReview = FSRSCardData.lastReview(in: data) {
            let review32 = UInt32(truncatingIfNeeded: lastReview)
            elapsedSeconds = UInt64(now32 >= review32 ? now32 - review32 : 0)
        } else if due > 365_000 {
            let review32 = UInt32(truncatingIfNeeded: due) &- UInt32(truncatingIfNeeded: interval)
            elapsedSeconds = UInt64(now32 >= review32 ? now32 - review32 : 0)
        } else {
            let reviewDay = UInt32(truncatingIfNeeded: due) &- UInt32(truncatingIfNeeded: interval)
            let today32 = UInt32(truncatingIfNeeded: today)
            elapsedSeconds = UInt64(today32 >= reviewDay ? today32 - reviewDay : 0) * 86_400
        }
        return Float(elapsedSeconds) / 86_400
    }

    /// Persist Anki `curDeck` so Add / `deck:current` follow the last studied deck.
    func setCurrentDeck(_ deckID: Int64) {
        var next = conf
        next["curDeck"] = deckID
        try? saveConf(next)
    }

    func currentDeckID() -> Int64? {
        if let n = conf["curDeck"] as? Int64 { return n }
        if let n = conf["curDeck"] as? Int { return Int64(n) }
        if let n = conf["curDeck"] as? NSNumber { return n.int64Value }
        return nil
    }

    /// Anki `congrats_info`: which paragraphs the finished-deck screen shows.
    /// Cards in this deck tree that have already been seen. Used by the widget's "Estudar de novo".
    func seenCardCount(in deckID: Int64) throws -> Int {
        let ids = deckTreeIDs(including: deckID)
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        return try db.scalarInt("""
            SELECT COUNT(*) FROM cards WHERE did IN (\(placeholders)) AND type != 0 AND queue != -1
        """) { stmt in
            for (i, id) in ids.enumerated() {
                SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id)
            }
        }
    }

    /// Reload after the widget wrote the shared collection. Does not bring the app forward.
    func reloadAfterExternalEdit() async {
        guard !collectionSyncing else {
            widgetReloadPendingDuringSync = true
            return
        }
        guard fileManager.fileExists(atPath: collectionPath.path) else { return }
        if db == nil {
            await bootstrapIfNeeded()
        } else {
            try? reloadMeta()
            try? refreshCounts()
        }
        widgetRevision += 1
    }

    func congratsState(for deckID: Int64) throws -> DeckCongrats {
        let ids = deckTreeIDs(including: deckID)
        guard !ids.isEmpty else { return .empty }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        func bindIDs(_ stmt: OpaquePointer) {
            for (i, id) in ids.enumerated() {
                SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id)
            }
        }
        func count(_ sql: String, extra: ((OpaquePointer) -> Void)? = nil) throws -> Int {
            try db.scalarInt("SELECT COUNT(*) FROM cards WHERE did IN (\(placeholders)) AND \(sql)") { stmt in
                bindIDs(stmt)
                extra?(stmt)
            }
        }
        let day = schedDay()
        let newCount = try count("queue = 0")
        let reviewCount = try count("queue IN (2, 3) AND due <= ?") { stmt in
            SQLiteDatabase.bindInt(stmt, Int32(ids.count + 1), day)
        }
        let schedBuried = try count("queue = -2")
        let userBuried = try count("queue = -3")
        let learnCount = try count("queue = 1")
        var nextDue = 0
        try db.query("SELECT MIN(due) FROM cards WHERE did IN (\(placeholders)) AND queue = 1", bind: { bindIDs($0) }) { stmt in
            if sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                nextDue = Int(sqlite3_column_int(stmt, 0))
            }
        }
        let now = Int(Date().timeIntervalSince1970)
        let collapse = conf["collapseTime"] as? Int ?? 1200
        let secsUntilNextLearn = nextDue == 0 ? 86_400 : max(60, nextDue - collapse - now)
        return DeckCongrats(
            learnCount: learnCount,
            secsUntilNextLearn: secsUntilNextLearn,
            reviewRemaining: reviewCount > 0,
            newRemaining: newCount > 0,
            schedBuried: schedBuried > 0,
            userBuried: userBuried > 0,
            isFiltered: decks.first { $0.id == deckID }?.isFiltered == true
        )
    }

    /// Counts shown in Anki's Custom Study dialog (own cards vs subdecks).
    func customStudyAvailability(for deckID: Int64) throws -> CustomStudyAvailability {
        let ids = deckTreeIDs(including: deckID)
        guard !ids.isEmpty else { return .empty }
        let day = schedDay()
        func count(ownOnly: Bool, sql: String, extra: ((OpaquePointer) -> Void)? = nil) throws -> Int {
            let scope = ownOnly ? "did = ?" : "did IN (\(ids.map { _ in "?" }.joined(separator: ",")))"
            return try db.scalarInt("SELECT COUNT(*) FROM cards WHERE \(scope) AND \(sql)") { stmt in
                if ownOnly {
                    SQLiteDatabase.bindInt64(stmt, 1, deckID)
                    extra?(stmt)
                } else {
                    for (i, id) in ids.enumerated() {
                        SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id)
                    }
                    extra?(stmt)
                }
            }
        }
        let reviewSQL = "queue = 2 AND due <= ?"
        let bindDay: (OpaquePointer) -> Void = { SQLiteDatabase.bindInt($0, 2, day) }
        let bindDayTree: (OpaquePointer) -> Void = { SQLiteDatabase.bindInt($0, Int32(ids.count + 1), day) }
        let newOwn = try count(ownOnly: true, sql: "queue = 0")
        let newTree = try count(ownOnly: false, sql: "queue = 0")
        let revOwn = try count(ownOnly: true, sql: reviewSQL, extra: bindDay)
        let revTree = try count(ownOnly: false, sql: reviewSQL, extra: bindDayTree)
        let ph = ids.map { _ in "?" }.joined(separator: ",")
        let total = try db.scalarInt("SELECT COUNT(*) FROM cards WHERE did IN (\(ph)) OR odid IN (\(ph))") { stmt in
            for (i, id) in ids.enumerated() {
                SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id)
                SQLiteDatabase.bindInt64(stmt, Int32(ids.count + i + 1), id)
            }
        }
        var tags = Set<String>()
        try db.query("""
            SELECT n.tags FROM notes n
            JOIN cards c ON c.nid = n.id
            WHERE c.did IN (\(ph)) OR c.odid IN (\(ph))
        """, bind: { stmt in
            for (i, id) in ids.enumerated() {
                SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id)
                SQLiteDatabase.bindInt64(stmt, Int32(ids.count + i + 1), id)
            }
        }) { stmt in
            let raw = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            for tag in AnkiTag.split(raw) {
                tags.insert(tag)
            }
        }
        return CustomStudyAvailability(
            newOwn: newOwn,
            newChildren: max(0, newTree - newOwn),
            reviewOwn: revOwn,
            reviewChildren: max(0, revTree - revOwn),
            totalCards: total,
            tags: tags.sorted()
        )
    }

    /// rslib custom study `extend_limits`: lowers today's studied counts (possibly below zero),
    /// on the parents too when Apply All Parent Limits is on. `extendNew`/`extendRev` only
    /// remember the last amount for the custom study dialog.
    func extendTodayLimit(deckID: Int64, newDelta: Int, reviewDelta: Int) throws {
        guard let deck = deck(id: deckID) else { return }
        let today = schedDay()
        var ids: Set<Int64> = [deck.id]
        if applyAllParentLimits {
            ids.formUnion(parentDecks(of: deck).map(\.id))
        }
        try mutateStudiedToday(ids: ids, today: today) { studied in
            studied.new -= newDelta
            studied.review -= reviewDelta
        }
        guard newDelta > 0 || reviewDelta > 0 else { return }
        var next = decks
        guard let idx = next.firstIndex(where: { $0.id == deckID }) else { return }
        if newDelta > 0 { next[idx].extendNew = newDelta }
        if reviewDelta > 0 { next[idx].extendRev = reviewDelta }
        try saveDecks(next)
    }

    /// Reuse or create Anki's single "Sessão de Estudo Personalizado" filtered deck.
    /// Cards are gathered only after any previous session is restored, and an empty
    /// search puts that session back (Anki rolls the rebuild back).
    @MainActor
    func buildCustomStudySession(
        query: String,
        limit: Int,
        reschedule: Bool,
        order: String,
        includeTags: String? = nil,
        excludeTags: String? = nil
    ) throws -> AnkiDeck {
        #if WIDGET_EXTENSION
        let sessionName = "Sessão de Estudo Personalizado"
        #else
        #if os(iOS)
        let languageCode = AnkiLanguageCatalog.appLanguageCode
        #else
        let languageCode = SharedProfiles.defaults.string(forKey: "ankios.language")
            ?? AnkiLanguageCatalog.defaultLanguageCode
        #endif
        let sessionName = AnkiLanguageCatalog.localizedString(
            "Sessão de Estudo Personalizado",
            for: languageCode
        )
        #endif
        if let existing = decks.first(where: { $0.name == sessionName }), !existing.isFiltered {
            throw CustomStudyFailure.renameExisting
        }

        let previous = decks.first { $0.name == sessionName && $0.isFiltered }
        var snapshot: [AnkiCard] = []
        if let previous {
            var ids: [Int64] = []
            try db.query("SELECT id FROM cards WHERE did = ?", bind: {
                SQLiteDatabase.bindInt64($0, 1, previous.id)
            }) { stmt in
                ids.append(sqlite3_column_int64(stmt, 0))
            }
            snapshot = try ids.compactMap { try fetchCard(id: $0) }
            try FilteredDeckSupport.empty(previous, store: self)
        }

        let fetchCap = max(limit, 500_000)
        var rows = try self.search(query: FilteredDeckSupport.gatherSearch(query), limit: fetchCap)
        rows = FilteredDeckSupport.applyTagFilter(rows, include: includeTags, exclude: excludeTags)
        FilteredDeckSupport.sortForGather(
            &rows,
            order: order,
            today: schedDay(),
            now: Int(Date().timeIntervalSince1970),
            shuffle: order == "random"
        )
        let chosen = Array(rows.prefix(max(limit, 0)))
        guard !chosen.isEmpty else {
            for card in snapshot {
                try updateCard(card)
            }
            try refreshCounts()
            throw CustomStudyFailure.noCards
        }

        var working = decks
        let deckID: Int64
        if let idx = working.firstIndex(where: { $0.name == sessionName && $0.isFiltered }) {
            deckID = working[idx].id
            working[idx].searchTerms = query
            working[idx].termLimit = limit
            working[idx].resched = reschedule
            working[idx].searchOrder = order
            working[idx].includeTags = includeTags
            working[idx].excludeTags = excludeTags
            working[idx].mod = Int64(Date().timeIntervalSince1970)
        } else {
            deckID = timestampID()
            var created = AnkiDeck(
                id: deckID,
                name: sessionName,
                mod: Int64(Date().timeIntervalSince1970),
                usn: -1,
                collapsed: false,
                browserCollapsed: false,
                desc: "",
                dyn: 1,
                conf: 1,
                extendNew: 0,
                extendRev: 0,
                newToday: [0, 0],
                revToday: [0, 0],
                lrnToday: [0, 0],
                timeToday: [0, 0],
                searchTerms: query,
                termLimit: limit,
                resched: reschedule,
                previewDelay: 10,
                searchOrder: order
            )
            created.includeTags = includeTags
            created.excludeTags = excludeTags
            working.append(created)
        }
        try saveDecks(working)

        try FilteredDeckSupport.install(
            cardIDs: chosen.map(\.card.id),
            deckID: deckID,
            reschedule: reschedule,
            store: self
        )
        try refreshCounts()
        setCurrentDeck(deckID)
        return deck(id: deckID) ?? working.first { $0.id == deckID }!
    }

    func findReplaceFields(
        noteIDs: [Int64],
        find: String,
        replace: String,
        fieldName: String? = nil,
        regularExpression: Bool = false,
        matchCase: Bool = false
    ) throws -> Int {
        guard !find.isEmpty else { return 0 }
        let pattern = regularExpression ? find : NSRegularExpression.escapedPattern(for: find)
        let options: NSRegularExpression.Options = matchCase ? [] : [.caseInsensitive]
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            throw SQLiteError.exec("A expressão de busca não é válida.")
        }
        var changed = 0
        for nid in noteIDs {
            guard let note = try fetchNote(id: nid) else { continue }
            var fields = note.fields
            var any = false
            let selectedOrd = fieldName.flatMap { name in
                notetype(id: note.mid)?.flds.first {
                    $0.name.compare(name, options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) == .orderedSame
                }?.ord
            }
            if fieldName != nil && selectedOrd == nil { continue }
            for i in fields.indices where selectedOrd == nil || selectedOrd == i {
                let range = NSRange(fields[i].startIndex..., in: fields[i])
                let replacement = regex.stringByReplacingMatches(
                    in: fields[i],
                    range: range,
                    withTemplate: replace
                )
                if replacement != fields[i] {
                    fields[i] = replacement
                    any = true
                }
            }
            if any {
                try updateNote(note, fields: fields, tags: note.tagList.joined(separator: " "))
                changed += 1
            }
        }
        return changed
    }

    func findReplaceTags(
        noteIDs: [Int64],
        find: String,
        replace: String,
        regularExpression: Bool = false,
        matchCase: Bool = false
    ) throws -> Int {
        guard !find.isEmpty else { return 0 }
        let pattern = regularExpression ? find : NSRegularExpression.escapedPattern(for: find)
        let options: NSRegularExpression.Options = matchCase ? [] : [.caseInsensitive]
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            throw SQLiteError.exec("A expressão de busca não é válida.")
        }
        var changed = 0
        for nid in noteIDs {
            guard let note = try fetchNote(id: nid) else { continue }
            var tags: [String] = []
            var replaced = false
            for tag in note.tagList {
                let replacement = regex.stringByReplacingMatches(
                    in: tag,
                    range: NSRange(tag.startIndex..., in: tag),
                    withTemplate: replace
                )
                if replacement != tag {
                    tags.append(contentsOf: AnkiTag.split(replacement))
                    replaced = true
                } else {
                    tags.append(tag)
                }
            }
            guard replaced else { continue }
            try updateNote(note, fields: note.fields, tags: tags.joined(separator: " "))
            changed += 1
        }
        return changed
    }

    func updateCard(_ card: AnkiCard) throws {
        try db.run("""
            UPDATE cards SET nid=?, did=?, ord=?, mod=?, usn=?, type=?, queue=?, due=?, ivl=?, factor=?,
            reps=?, lapses=?, left=?, odue=?, odid=?, flags=?, data=? WHERE id=?
        """) { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, card.nid)
            SQLiteDatabase.bindInt64(stmt, 2, card.did)
            SQLiteDatabase.bindInt(stmt, 3, card.ord)
            SQLiteDatabase.bindInt64(stmt, 4, card.mod)
            SQLiteDatabase.bindInt(stmt, 5, card.usn)
            SQLiteDatabase.bindInt(stmt, 6, card.type)
            SQLiteDatabase.bindInt(stmt, 7, card.queue)
            SQLiteDatabase.bindInt(stmt, 8, card.due)
            SQLiteDatabase.bindInt(stmt, 9, card.ivl)
            SQLiteDatabase.bindInt(stmt, 10, card.factor)
            SQLiteDatabase.bindInt(stmt, 11, card.reps)
            SQLiteDatabase.bindInt(stmt, 12, card.lapses)
            SQLiteDatabase.bindInt(stmt, 13, card.left)
            SQLiteDatabase.bindInt(stmt, 14, card.odue)
            SQLiteDatabase.bindInt64(stmt, 15, card.odid)
            SQLiteDatabase.bindInt(stmt, 16, card.flags)
            try SQLiteDatabase.bindText(stmt, 17, card.data)
            SQLiteDatabase.bindInt64(stmt, 18, card.id)
        }
        try touchCol()
    }

    func insertRevlog(_ r: AnkiRevlog) throws {
        try db.run("""
            INSERT INTO revlog (id, cid, usn, ease, ivl, lastIvl, factor, time, type)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """) { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, r.id)
            SQLiteDatabase.bindInt64(stmt, 2, r.cid)
            SQLiteDatabase.bindInt(stmt, 3, r.usn)
            SQLiteDatabase.bindInt(stmt, 4, r.ease)
            SQLiteDatabase.bindInt(stmt, 5, r.ivl)
            SQLiteDatabase.bindInt(stmt, 6, r.lastIvl)
            SQLiteDatabase.bindInt(stmt, 7, r.factor)
            SQLiteDatabase.bindInt(stmt, 8, r.time)
            SQLiteDatabase.bindInt(stmt, 9, r.type)
        }
    }

    func touchCol() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try db.run("UPDATE col SET mod = ?", bind: { SQLiteDatabase.bindInt64($0, 1, now) })
    }

    // MARK: - Deck meta persistence

    func saveDecks(_ decks: [AnkiDeck]) throws {
        var dict: [String: Any] = [:]
        for d in decks {
            dict[String(d.id)] = deckToDict(d)
        }
        let json = CollectionSchema.encodeJSON(dict)
        try db.run("UPDATE col SET decks = ?", bind: { try SQLiteDatabase.bindText($0, 1, json) })
        try touchCol()
        try reloadMeta()
        try refreshCounts()
    }

    func saveNotetypes(_ types: [AnkiNotetype]) throws {
        var dict: [String: Any] = [:]
        let encoder = JSONEncoder()
        for t in types {
            let data = try encoder.encode(t)
            let obj = try JSONSerialization.jsonObject(with: data)
            dict[String(t.id)] = obj
        }
        let json = CollectionSchema.encodeJSON(dict)
        try db.run("UPDATE col SET models = ?", bind: { try SQLiteDatabase.bindText($0, 1, json) })
        try touchCol()
        try reloadMeta()
    }

    func saveEditedNotetype(_ notetype: AnkiNotetype, replacing original: AnkiNotetype) throws {
        var notetype = notetype
        for index in notetype.flds.indices {
            guard let name = AnkiField.normalizedName(notetype.flds[index].name) else {
                throw SQLiteError.exec("O nome de cada campo precisa conter pelo menos um caractere válido.")
            }
            notetype.flds[index].name = name
        }
        let fieldNameKeys = notetype.flds.map { $0.name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) }
        guard Set(fieldNameKeys).count == fieldNameKeys.count else {
            throw SQLiteError.exec("Cada campo precisa ter um nome único.")
        }
        let oldFields = original.flds.sorted { $0.ord < $1.ord }
        let newFields = notetype.flds.sorted { $0.ord < $1.ord }
        let sourceByNewOrd = NotetypeEditMapping.fields(from: original, to: notetype)
        let retainedFields = Set(sourceByNewOrd.values)
        guard oldFields.filter(\.preventDeletion).allSatisfy({ retainedFields.contains($0.ord) }) else {
            throw SQLiteError.exec("Este tipo de nota contém um campo obrigatório que não pode ser removido.")
        }
        let templateSources = NotetypeEditMapping.templates(from: original, to: notetype)
        let newTemplateOrdByOld = Dictionary(uniqueKeysWithValues: templateSources.map { ($0.value, $0.key) })
        let removedFields = Set(oldFields.filter { !retainedFields.contains($0.ord) }.map(\.name))
        var renamedFields: [String: String] = [:]
        for field in newFields {
            if let sourceOrd = sourceByNewOrd[field.ord],
               let old = oldFields.first(where: { $0.ord == sourceOrd }), old.name != field.name {
                renamedFields[old.name] = field.name
            }
        }
        for index in notetype.tmpls.indices {
            notetype.tmpls[index].qfmt = NotetypeEditMapping.renamingFields(in: notetype.tmpls[index].qfmt, names: renamedFields, removed: removedFields)
            notetype.tmpls[index].afmt = NotetypeEditMapping.renamingFields(in: notetype.tmpls[index].afmt, names: renamedFields, removed: removedFields)
            notetype.tmpls[index].bqfmt = NotetypeEditMapping.renamingFields(in: notetype.tmpls[index].bqfmt, names: renamedFields, removed: removedFields)
            notetype.tmpls[index].bafmt = NotetypeEditMapping.renamingFields(in: notetype.tmpls[index].bafmt, names: renamedFields, removed: removedFields)
        }
        var templateCards: [(id: Int64, ord: Int)] = []
        if !original.isCloze {
            try db.query("SELECT c.id, c.ord FROM cards c JOIN notes n ON n.id=c.nid WHERE n.mid=?", bind: {
                SQLiteDatabase.bindInt64($0, 1, original.id)
            }) { stmt in
                templateCards.append((sqlite3_column_int64(stmt, 0), Int(sqlite3_column_int(stmt, 1))))
            }
        }

        var notes: [(id: Int64, fields: [String])] = []
        try db.query("SELECT id, flds FROM notes WHERE mid = ?", bind: {
            SQLiteDatabase.bindInt64($0, 1, original.id)
        }) { stmt in
            notes.append((sqlite3_column_int64(stmt, 0), SQLiteDatabase.text(stmt, 1).components(separatedBy: "\u{1f}")))
        }

        try db.exec("BEGIN IMMEDIATE")
        do {
            let types = notetypes.map { $0.id == original.id ? notetype : $0 }
            try saveNotetypes(types)
            for row in notes {
                var fields = Array(repeating: "", count: newFields.count)
                for field in newFields where fields.indices.contains(field.ord) {
                    guard let sourceIndex = sourceByNewOrd[field.ord], row.fields.indices.contains(sourceIndex) else { continue }
                    fields[field.ord] = row.fields[sourceIndex]
                }
                let first = fields.first ?? ""
                let sortIndex = fields.indices.contains(notetype.sortf) ? notetype.sortf : 0
                let sortField = stripHTMLPreservingMediaFilenames(fields.indices.contains(sortIndex) ? fields[sortIndex] : first)
                try db.run("UPDATE notes SET flds=?, sfld=?, csum=?, mod=?, usn=-1 WHERE id=?") { stmt in
                    try SQLiteDatabase.bindText(stmt, 1, fields.joined(separator: "\u{1f}"))
                    try SQLiteDatabase.bindText(stmt, 2, sortField)
                    SQLiteDatabase.bindInt64(stmt, 3, self.fieldChecksum(first))
                    SQLiteDatabase.bindInt64(stmt, 4, Int64(Date().timeIntervalSince1970))
                    SQLiteDatabase.bindInt64(stmt, 5, row.id)
                }
            }
            let removedCards = templateCards.filter { newTemplateOrdByOld[$0.ord] == nil }.map(\.id)
            try recordGraves(ids: removedCards, type: 0)
            for card in templateCards {
                if let ordinal = newTemplateOrdByOld[card.ord] {
                    guard ordinal != card.ord else { continue }
                    try db.run("UPDATE cards SET ord=?, mod=?, usn=-1 WHERE id=?") { stmt in
                        SQLiteDatabase.bindInt(stmt, 1, ordinal)
                        SQLiteDatabase.bindInt64(stmt, 2, Int64(Date().timeIntervalSince1970))
                        SQLiteDatabase.bindInt64(stmt, 3, card.id)
                    }
                } else {
                    try db.run("DELETE FROM cards WHERE id=?") { SQLiteDatabase.bindInt64($0, 1, card.id) }
                }
            }
            try syncCardsForNotetype(mid: notetype.id)
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            try? reloadMeta()
            try? refreshCounts()
            throw error
        }
    }

    func saveDeckConfigs(_ configs: [AnkiDeckConfig], updatedDecks: [AnkiDeck]? = nil) throws {
        let savedConfigIDs = Set(configs.map(\.id))
        let removedConfigIDs = Set(deckConfigs.map(\.id)).subtracting(savedConfigIDs)
        let currentTime = Int64(Date().timeIntervalSince1970)
        var nextDecks = updatedDecks ?? decks
        for index in nextDecks.indices where removedConfigIDs.contains(nextDecks[index].conf) {
            nextDecks[index].conf = configs.first(where: { $0.id == 1 })?.id ?? 1
        }
        if updatedDecks != nil {
            let oldDecksByID = Dictionary(uniqueKeysWithValues: decks.map { ($0.id, $0) })
            for index in nextDecks.indices {
                guard let previous = oldDecksByID[nextDecks[index].id],
                      previous != nextDecks[index] else { continue }
                nextDecks[index].mod = max(nextDecks[index].mod, currentTime)
            }
        }
        var dict: [String: Any] = [:]
        let encoder = JSONEncoder()
        for c in configs {
            let data = try encoder.encode(c)
            let obj = try JSONSerialization.jsonObject(with: data)
            dict[String(c.id)] = obj
        }
        let json = CollectionSchema.encodeJSON(dict)
        try db.exec("BEGIN IMMEDIATE")
        do {
            try db.run("UPDATE col SET dconf = ?", bind: { try SQLiteDatabase.bindText($0, 1, json) })
            if !removedConfigIDs.isEmpty {
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                try db.run("UPDATE col SET scm = ?", bind: { SQLiteDatabase.bindInt64($0, 1, now) })
            }
            if updatedDecks != nil || !removedConfigIDs.isEmpty {
                var deckDict: [String: Any] = [:]
                for deck in nextDecks {
                    deckDict[String(deck.id)] = deckToDict(deck)
                }
                let decksJSON = CollectionSchema.encodeJSON(deckDict)
                try db.run("UPDATE col SET decks = ?", bind: { try SQLiteDatabase.bindText($0, 1, decksJSON) })
            }
            let configsByID = Dictionary(uniqueKeysWithValues: configs.map { ($0.id, $0) })
            let previousConfigsByID = Dictionary(uniqueKeysWithValues: deckConfigs.map { ($0.id, $0) })
            let nextDecksByID = Dictionary(uniqueKeysWithValues: nextDecks.map { ($0.id, $0) })
            for previousDeck in decks where !previousDeck.isFiltered {
                guard let currentDeck = nextDecksByID[previousDeck.id], !currentDeck.isFiltered else { continue }
                let previousConfig = previousConfigsByID[previousDeck.conf] ?? .default()
                let currentConfig = configsByID[currentDeck.conf] ?? configsByID[1] ?? .default()
                if previousConfig.new.order != currentConfig.new.order {
                    try sortNewCards(inDeck: currentDeck.id, randomized: currentConfig.new.order == 0)
                }
                if previousConfig.new.delays != currentConfig.new.delays {
                    try adjustRemainingLearningSteps(
                        inDeck: currentDeck.id,
                        cardType: AnkiCard.CardType.learning.rawValue,
                        oldSteps: previousConfig.new.delays,
                        newSteps: currentConfig.new.delays
                    )
                }
                if previousConfig.lapse.delays != currentConfig.lapse.delays {
                    try adjustRemainingLearningSteps(
                        inDeck: currentDeck.id,
                        cardType: AnkiCard.CardType.relearning.rawValue,
                        oldSteps: previousConfig.lapse.delays,
                        newSteps: currentConfig.lapse.delays
                    )
                }
            }
            try touchCol()
            try reloadMeta()
            try refreshCounts()
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            try? reloadMeta()
            throw error
        }
    }

    private func adjustRemainingLearningSteps(
        inDeck deckID: Int64,
        cardType: Int,
        oldSteps: [Double],
        newSteps: [Double]
    ) throws {
        var updates: [(id: Int64, remaining: Int)] = []
        try db.query(
            "SELECT id, left FROM cards WHERE (did = ? OR (odid != 0 AND odid = ?)) AND type = ?",
            bind: { statement in
                SQLiteDatabase.bindInt64(statement, 1, deckID)
                SQLiteDatabase.bindInt64(statement, 2, deckID)
                SQLiteDatabase.bindInt(statement, 3, cardType)
            }
        ) { statement in
            let cardID = sqlite3_column_int64(statement, 0)
            let remaining = Int(sqlite3_column_int(statement, 1)) % 1000
            guard !oldSteps.isEmpty else { return }
            let lastPassedStep = oldSteps.count > remaining ? oldSteps.count - remaining - 1 : nil
            let newRemaining = lastPassedStep.flatMap { passedIndex in
                newSteps.indices.reversed().first(where: { newSteps[$0] <= oldSteps[passedIndex] })
                    .map { newSteps.count - $0 - 1 }
            } ?? newSteps.count
            let boundedRemaining = max(newRemaining, 1)
            if remaining != boundedRemaining {
                updates.append((cardID, boundedRemaining))
            }
        }
        guard !updates.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970)
        for update in updates {
            try db.run("UPDATE cards SET left = ?, mod = ?, usn = -1 WHERE id = ?") { statement in
                SQLiteDatabase.bindInt(statement, 1, update.remaining)
                SQLiteDatabase.bindInt64(statement, 2, now)
                SQLiteDatabase.bindInt64(statement, 3, update.id)
            }
        }
    }

    func saveConf(_ conf: [String: Any]) throws {
        let json = CollectionSchema.encodeJSON(conf)
        try db.run("UPDATE col SET conf = ?", bind: { try SQLiteDatabase.bindText($0, 1, json) })
        try CollectionSchema.saveCollectionConfig(conf, to: db)
        try touchCol()
        if Self.studyConfigKeys.contains(where: { !Self.confValuesEqual(self.conf[$0], conf[$0]) }) {
            studyQueueCache = nil
        }
        self.conf = conf
    }

    private static let studyConfigKeys = [
        "curDeck", "rollover", "collapseTime", "newCardsIgnoreReviewLimit", "applyAllParentLimits",
        "fsrs", "schedVer", "creationOffset", "localOffset", "fsrsShortTermWithStepsEnabled", "loadBalancerEnabled"
    ]

    private static func confValuesEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (x?, y?): (x as AnyObject).isEqual(y as AnyObject)
        default: false
        }
    }

    /// Painel: named searches persisted in col conf (`savedSearches` as [[name, query]]).
    var savedSearches: [(name: String, query: String)] {
        guard let raw = conf["savedSearches"] as? [[Any]] else { return [] }
        return raw.compactMap { pair in
            guard pair.count >= 2,
                  let name = pair[0] as? String,
                  let query = pair[1] as? String,
                  !name.isEmpty else { return nil }
            return (name, query)
        }
    }

    func setSavedSearches(_ items: [(name: String, query: String)]) throws {
        var c = conf
        c["savedSearches"] = items.map { [$0.name, $0.query] as [Any] }
        try saveConf(c)
    }

    func addSavedSearch(name: String, query: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedQuery.isEmpty else { return }
        var items = savedSearches.filter { $0.name != trimmedName }
        items.append((trimmedName, trimmedQuery))
        items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        try setSavedSearches(items)
    }

    func removeSavedSearch(named name: String) throws {
        try setSavedSearches(savedSearches.filter { $0.name != name })
    }

    func renameSavedSearch(from oldName: String, to newName: String) throws {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let search = savedSearches.first(where: { $0.name == oldName }) else {
            throw SQLiteError.exec("Informe um nome para a busca salva.")
        }
        let remaining = savedSearches.filter { $0.name != oldName && $0.name != name }
        let renamed = remaining + [(name, search.query)]
        try setSavedSearches(renamed.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        })
    }

    func deckToDict(_ d: AnkiDeck) -> [String: Any] {
        var dict: [String: Any] = d.other.mapValues(\.value)
        dict.merge([
            "id": d.id,
            "name": d.name,
            "mod": d.mod,
            "usn": d.usn,
            "collapsed": d.collapsed,
            "browserCollapsed": d.browserCollapsed,
            "desc": d.desc,
            "md": d.markdownDescription,
            "dyn": d.dyn,
            "conf": d.conf,
            "extendNew": d.extendNew,
            "extendRev": d.extendRev,
            "newToday": d.newToday,
            "revToday": d.revToday,
            "lrnToday": d.lrnToday,
            "timeToday": d.timeToday
        ]) { _, newValue in newValue }
        if let desiredRetention = d.desiredRetention { dict["desiredRetention"] = desiredRetention }
        if let newLimit = d.newLimit { dict["newLimit"] = newLimit }
        if let reviewLimit = d.reviewLimit { dict["reviewLimit"] = reviewLimit }
        if let newLimitToday = d.newLimitToday {
            dict["newLimitToday"] = ["limit": newLimitToday.limit, "today": newLimitToday.today]
        }
        if let reviewLimitToday = d.reviewLimitToday {
            dict["reviewLimitToday"] = ["limit": reviewLimitToday.limit, "today": reviewLimitToday.today]
        }
        var terms: [[Any]] = []
        if let search = d.searchTerms {
            terms.append([search, d.termLimit ?? 50, Self.filteredDeckOrderID(d.searchOrder)])
        }
        if let search2 = d.searchTerms2 {
            terms.append([search2, d.termLimit2 ?? 50, Self.filteredDeckOrderID(d.searchOrder2 ?? d.searchOrder)])
        }
        if !terms.isEmpty { dict["terms"] = terms }
        if let resched = d.resched { dict["resched"] = resched }
        if let desiredRetention = d.desiredRetention { dict["desiredRetention"] = desiredRetention }
        if let previewDelay = d.previewDelay { dict["previewDelay"] = previewDelay }
        if let searchOrder = d.searchOrder { dict["ankiosSearchOrder"] = searchOrder }
        if let includeTags = d.includeTags { dict["ankiosIncludeTags"] = includeTags }
        if let excludeTags = d.excludeTags { dict["ankiosExcludeTags"] = excludeTags }
        if let previewAgain = d.previewAgain { dict["previewAgainSecs"] = previewAgain }
        if let previewHard = d.previewHard { dict["previewHardSecs"] = previewHard }
        if let previewGood = d.previewGood { dict["previewGoodSecs"] = previewGood }
        if let searchOrder2 = d.searchOrder2 { dict["ankiosSearchOrder2"] = searchOrder2 }
        return dict
    }

    // MARK: - Mutations

    @discardableResult
    func createDeck(name: String, parent: AnkiDeck? = nil) throws -> AnkiDeck {
        guard parent?.isFiltered != true else {
            throw SQLiteError.exec("Um baralho filtrado não pode ser pai de outro baralho.")
        }
        func normalizeComponent(_ component: String) -> String {
            let nfc = component.precomposedStringWithCanonicalMapping
            let withoutControls = String(nfc.unicodeScalars.filter { $0.value > 0x1F && $0.value != 0x7F })
            let trimCharacters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":"))
            let trimmed = withoutControls.trimmingCharacters(in: trimCharacters)
            return trimmed.isEmpty ? "blank" : trimmed
        }
        func nameKey(_ candidate: String) -> String {
            let normalized = candidate.components(separatedBy: "::").map(normalizeComponent).joined(separator: "::")
            return normalized.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }

        let fullName = parent.map { $0.name + "::" + name } ?? name
        let requestedParts = fullName.components(separatedBy: "::").map(normalizeComponent)
        let requestedName = requestedParts.joined(separator: "::")
        if let existing = decks.first(where: { nameKey($0.name) == nameKey(requestedName) }) { return existing }

        var next = decks
        var parentParts: [String] = []
        var missingParents: [String] = []
        if requestedParts.count > 1 {
            for component in requestedParts.dropLast() {
                let candidateName = (parentParts + [component]).joined(separator: "::")
                if let existing = next.first(where: { nameKey($0.name) == nameKey(candidateName) }) {
                    guard !existing.isFiltered else {
                        throw SQLiteError.exec("Um baralho filtrado não pode ser pai de outro baralho.")
                    }
                    parentParts = existing.pathComponents
                } else {
                    parentParts.append(component)
                    missingParents.append(parentParts.joined(separator: "::"))
                }
            }
        }

        let resolvedName = (parentParts + [requestedParts.last ?? "blank"]).joined(separator: "::")
        if let existing = decks.first(where: { nameKey($0.name) == nameKey(resolvedName) }) { return existing }
        let now = Int64(Date().timeIntervalSince1970)
        var createdDeckIDs: [Int64] = []
        for parentName in missingParents.reversed() {
            let parentDeck = AnkiDeck(
                id: timestampID(), name: parentName, mod: now, usn: -1,
                collapsed: false, browserCollapsed: false, desc: "", dyn: 0, conf: 1,
                extendNew: 0, extendRev: 0, newToday: [0, 0], revToday: [0, 0],
                lrnToday: [0, 0], timeToday: [0, 0]
            )
            next.append(parentDeck)
            createdDeckIDs.append(parentDeck.id)
        }
        let newDeck = AnkiDeck(
            id: timestampID(), name: resolvedName, mod: now, usn: -1,
            collapsed: false, browserCollapsed: false, desc: "", dyn: 0, conf: 1,
            extendNew: 0, extendRev: 0, newToday: [0, 0], revToday: [0, 0], lrnToday: [0, 0], timeToday: [0, 0]
        )
        next.append(newDeck)
        createdDeckIDs.append(newDeck.id)
        let ownsTransaction = !db.isInTransaction
        let undoSnapshot: CollectionActionUndoSnapshot?
        if ownsTransaction {
            undoSnapshot = try makeBrowserUndoSnapshot(
                message: "Baralho criado",
                deleteDeckIDs: createdDeckIDs,
                deckIDs: createdDeckIDs,
                preserveModificationFields: true
            )
        } else {
            undoSnapshot = nil
        }
        if ownsTransaction { try db.exec("BEGIN IMMEDIATE") }
        do {
            try saveDecks(next)
            if ownsTransaction { try db.exec("COMMIT") }
        } catch {
            if ownsTransaction {
                try? db.exec("ROLLBACK")
                try? reloadMeta()
                try? refreshCounts()
            }
            throw error
        }
        if let undoSnapshot { registerBrowserUndo(undoSnapshot) }
        if ownsTransaction { notifyDeckContentAdded() }
        return newDeck
    }

    /// Anki's Create Filtered Deck: an empty dynamic deck the user fills from its options.
    @discardableResult
    func createFilteredDeck() throws -> AnkiDeck {
        let current = currentDeckID().flatMap { id in decks.first { $0.id == id && !$0.isFiltered } }
        let deckSearch = current.map { deck in
            let escaped = deck.name
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "*", with: "\\*")
                .replacingOccurrences(of: "_", with: "\\_")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let needsQuotes = deck.name.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
                || deck.name.contains("\"")
            return needsQuotes ? "deck:\"\(escaped)\"" : "deck:\(escaped)"
        }
        let deck = AnkiDeck(
            id: 0, name: nextFilteredDeckName(), mod: 0, usn: -1,
            collapsed: false, browserCollapsed: false, desc: "", dyn: 1, conf: 1,
            extendNew: 0, extendRev: 0, newToday: [0, 0], revToday: [0, 0], lrnToday: [0, 0], timeToday: [0, 0],
            searchTerms: deckSearch.map { "\($0) is:due" } ?? "", termLimit: 100, resched: true, previewDelay: 0, searchOrder: "random",
            previewAgain: FilteredDeckSupport.previewAgainSeconds,
            previewHard: FilteredDeckSupport.previewHardSeconds,
            previewGood: FilteredDeckSupport.previewGoodSeconds,
            searchTerms2: deckSearch.map { "\($0) is:new" },
            termLimit2: 20,
            searchOrder2: "due"
        )
        return deck
    }

    private func nextFilteredDeckName() -> String {
        let names = Set(decks.map { $0.name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) })
        var name = "Baralho Filtrado"
        var suffix = 2
        while names.contains(name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))) {
            name = "Baralho Filtrado \(suffix)"
            suffix += 1
        }
        return name
    }

    /// Saves a filtered deck's search and rebuilds it, the way Anki's filtered options do.
    @discardableResult
    func saveFilteredDeck(
        _ deck: AnkiDeck,
        name: String? = nil,
        search: String,
        limit: Int,
        order: String,
        reschedule: Bool,
        again: Int,
        hard: Int,
        good: Int,
        allowEmpty: Bool = false,
        search2: String? = nil,
        limit2: Int = 20,
        order2: String = "due"
    ) throws -> AnkiDeck {
        var updated = deck
        let isNew = updated.id == 0
        if isNew {
            updated.id = timestampID()
            updated.name = nextFilteredDeckName()
        } else if !decks.contains(where: { $0.id == updated.id }) {
            throw SQLiteError.exec("O baralho filtrado não existe mais.")
        }
        updated.name = normalizedFilteredDeckName(name ?? updated.name)
        let nameKey = updated.name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        guard !decks.contains(where: {
            $0.id != updated.id
                && normalizedFilteredDeckName($0.name).folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) == nameKey
        }) else {
            throw SQLiteError.exec("Já existe um baralho com esse nome.")
        }
        updated.searchTerms = search
        updated.termLimit = max(1, limit)
        updated.searchOrder = order
        updated.resched = reschedule
        updated.previewAgain = again
        updated.previewHard = hard
        updated.previewGood = good
        updated.searchTerms2 = search2.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        updated.termLimit2 = max(1, limit2)
        updated.searchOrder2 = order2
        updated.mod = Int64(Date().timeIntervalSince1970)
        var next = decks
        if let index = next.firstIndex(where: { $0.id == updated.id }) {
            next[index] = updated
        } else {
            next.append(updated)
        }

        let ownsTransaction = !db.isInTransaction
        if ownsTransaction { try db.exec("BEGIN IMMEDIATE") }
        do {
            try saveDecks(next)
            guard let saved = self.deck(id: updated.id) else {
                throw SQLiteError.exec("Não foi possível salvar o baralho filtrado.")
            }
            let matched = try FilteredDeckSupport.rebuild(saved, store: self)
            if matched == 0 && !allowEmpty {
                throw SQLiteError.exec("A busca não encontrou cartões correspondentes.")
            }
            setCurrentDeck(updated.id)
            if ownsTransaction { try db.exec("COMMIT") }
        } catch {
            if ownsTransaction {
                try? db.exec("ROLLBACK")
                try? reloadMeta()
                try? refreshCounts()
            }
            throw error
        }
        return self.deck(id: updated.id) ?? updated
    }

    private func normalizedFilteredDeckName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
            .components(separatedBy: "::")
            .map { component in
                let withoutControls = String(component.unicodeScalars.filter { $0.value > 0x1F && $0.value != 0x7F })
                let trimmed = withoutControls.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":")))
                return trimmed.isEmpty ? "blank" : trimmed
            }
            .joined(separator: "::")
    }

    /// Points every non-filtered child at this deck's preset.
    func applyPresetToSubdecks(of deck: AnkiDeck) throws {
        let live = decks.first { $0.id == deck.id } ?? deck
        let prefix = live.name + "::"
        var next = decks
        var changed = false
        for i in next.indices where next[i].name.hasPrefix(prefix) && !next[i].isFiltered {
            next[i].conf = live.conf
            next[i].mod = Int64(Date().timeIntervalSince1970)
            changed = true
        }
        if changed { try saveDecks(next) }
    }

    func renameDeck(_ deck: AnkiDeck, to newName: String, undoMessage: String = "Baralho renomeado") throws {
        guard let liveDeck = decks.first(where: { $0.id == deck.id }) else { return }
        func normalizeComponent(_ component: String) -> String {
            let nfc = component.precomposedStringWithCanonicalMapping
            let withoutControls = String(nfc.unicodeScalars.filter { $0.value > 0x1F && $0.value != 0x7F })
            let trimCharacters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":"))
            let trimmed = withoutControls.trimmingCharacters(in: trimCharacters)
            return trimmed.isEmpty ? "blank" : trimmed
        }
        func nameKey(_ name: String) -> String {
            name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }

        var requestedParts = newName.components(separatedBy: "::").map(normalizeComponent)
        if requestedParts.isEmpty { requestedParts = ["blank"] }
        var requestedName = requestedParts.joined(separator: "::")
        let oldName = liveDeck.name
        let oldPrefix = oldName + "::"
        let movingDecks = decks.filter { $0.id == liveDeck.id || $0.name.hasPrefix(oldPrefix) }
        let movingDeckIDs = Set(movingDecks.map(\.id))
        while decks.contains(where: { $0.id != liveDeck.id && nameKey($0.name) == nameKey(requestedName) }) {
            requestedParts[requestedParts.count - 1] += "+"
            requestedName = requestedParts.joined(separator: "::")
        }
        guard requestedName != oldName else { return }

        var next = decks
        var createdParentIDs: [Int64] = []
        var parentParts: [String] = []
        var missingParents: [String] = []
        if requestedParts.count > 1 {
            for component in requestedParts.dropLast() {
                let candidateName = (parentParts + [component]).joined(separator: "::")
                if let existing = next.first(where: {
                    !movingDeckIDs.contains($0.id) && nameKey($0.name) == nameKey(candidateName)
                }) {
                    guard !existing.isFiltered else {
                        throw SQLiteError.exec("Um baralho filtrado não pode ser pai de outro baralho.")
                    }
                    parentParts = existing.pathComponents
                } else {
                    parentParts.append(component)
                    missingParents.append(parentParts.joined(separator: "::"))
                }
            }
        }
        for parentName in missingParents.reversed() {
            let parent = AnkiDeck(
                id: timestampID(), name: parentName,
                mod: Int64(Date().timeIntervalSince1970), usn: -1,
                collapsed: false, browserCollapsed: false, desc: "", dyn: 0, conf: 1,
                extendNew: 0, extendRev: 0, newToday: [0, 0], revToday: [0, 0],
                lrnToday: [0, 0], timeToday: [0, 0]
            )
            next.append(parent)
            createdParentIDs.append(parent.id)
        }
        let resolvedName = (parentParts + [requestedParts.last ?? "blank"]).joined(separator: "::")
        let now = Int64(Date().timeIntervalSince1970)
        next = next.map { existing in
            guard movingDeckIDs.contains(existing.id) else { return existing }
            var updated = existing
            if existing.id == liveDeck.id {
                updated.name = resolvedName
            } else {
                updated.name = resolvedName + String(existing.name.dropFirst(oldName.count))
            }
            updated.mod = now
            updated.usn = -1
            return updated
        }
        let affectedDeckIDs = Array(movingDeckIDs) + createdParentIDs
        let undoSnapshot = try makeBrowserUndoSnapshot(
            message: undoMessage,
            deleteDeckIDs: affectedDeckIDs,
            deckIDs: affectedDeckIDs,
            preserveModificationFields: true
        )
        try db.exec("BEGIN IMMEDIATE")
        do {
            try saveDecks(next)
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            try? reloadMeta()
            try? refreshCounts()
            throw error
        }
        registerBrowserUndo(undoSnapshot)
    }

    func reparentDeck(_ deck: AnkiDeck, to newParent: AnkiDeck?) throws {
        guard let liveDeck = decks.first(where: { $0.id == deck.id }) else { return }
        let parent = newParent.flatMap { candidate in decks.first(where: { $0.id == candidate.id }) }
        if newParent != nil && parent == nil { return }
        if let parent, parent.isFiltered {
            throw SQLiteError.exec("Um baralho filtrado não pode conter outros baralhos.")
        }
        if let parent, Set(deckTreeIDs(including: liveDeck.id)).contains(parent.id) { return }
        let leaf = liveDeck.pathComponents.last ?? liveDeck.name
        let newName = parent.map { $0.name + "::" + leaf } ?? leaf
        try renameDeck(liveDeck, to: newName, undoMessage: "Baralho movido")
    }

    func deleteDeck(_ deck: AnkiDeck, cardsToo: Bool = true) throws {
        guard deck.id != 1 else {
            throw SQLiteError.exec("O baralho Default não pode ser apagado.")
        }
        let liveDeck = decks.first(where: { $0.id == deck.id }) ?? deck
        let ids = liveDeck.isFiltered ? [liveDeck.id] : deckTreeIDs(including: liveDeck.id)
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        var affectedCardIDs: [Int64] = []
        try db.query("""
            SELECT DISTINCT c.id FROM cards c
            WHERE c.did IN (\(placeholders)) OR c.odid IN (\(placeholders))
            ORDER BY c.id
            """, bind: { stmt in
            for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
            for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(ids.count + i + 1), id) }
        }) { stmt in
            affectedCardIDs.append(sqlite3_column_int64(stmt, 0))
        }
        var undoNoteIDs: [Int64] = []
        if cardsToo && !liveDeck.isFiltered {
            try db.query("""
                SELECT DISTINCT c.nid FROM cards c
                WHERE (c.did IN (\(placeholders)) OR c.odid IN (\(placeholders)))
                AND NOT EXISTS (
                    SELECT 1 FROM cards other
                    WHERE other.nid = c.nid
                    AND other.did NOT IN (\(placeholders))
                    AND other.odid NOT IN (\(placeholders))
                )
                ORDER BY c.nid
                """, bind: { stmt in
                for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
                for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(ids.count + i + 1), id) }
                for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(ids.count * 2 + i + 1), id) }
                for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(ids.count * 3 + i + 1), id) }
            }) { stmt in
                undoNoteIDs.append(sqlite3_column_int64(stmt, 0))
            }
        }
        let undoSnapshot = try makeBrowserUndoSnapshot(
            noteIDs: undoNoteIDs,
            cardIDs: affectedCardIDs,
            message: "Baralho apagado",
            deleteDeckIDs: ids,
            deckIDs: ids,
            preserveModificationFields: true
        )
        try db.exec("BEGIN IMMEDIATE")
        do {
            if liveDeck.isFiltered {
                try FilteredDeckSupport.returnHome(deckID: liveDeck.id, store: self)
                let remaining = decks.filter { $0.id != liveDeck.id }
                try recordGraves(ids: [liveDeck.id], type: 2)
                try saveDecks(remaining.isEmpty ? [Self.fallbackDeck()] : remaining)
            } else {
                if cardsToo {
                    // Collect notes that have cards in this tree, then delete cards, then
                    // drop only notes that no longer have any cards left (Anki-safe).
                    var noteIDs: [Int64] = []
                    var cardIDs: [Int64] = []
                    try db.query(
                        "SELECT id FROM cards WHERE did IN (\(placeholders)) OR odid IN (\(placeholders))",
                        bind: { stmt in
                            for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
                            for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(ids.count + i + 1), id) }
                        }
                    ) { stmt in
                        cardIDs.append(sqlite3_column_int64(stmt, 0))
                    }
                    try db.query(
                        "SELECT DISTINCT nid FROM cards WHERE did IN (\(placeholders)) OR odid IN (\(placeholders))",
                        bind: { stmt in
                            for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
                            for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(ids.count + i + 1), id) }
                        }
                    ) { stmt in
                        noteIDs.append(sqlite3_column_int64(stmt, 0))
                    }
                    try recordGraves(ids: cardIDs, type: 0)
                    try db.run("DELETE FROM cards WHERE did IN (\(placeholders)) OR odid IN (\(placeholders))") { stmt in
                        for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
                        for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(ids.count + i + 1), id) }
                    }
                    if !noteIDs.isEmpty {
                        let nph = noteIDs.map { _ in "?" }.joined(separator: ",")
                        var deletedNoteIDs: [Int64] = []
                        try db.query("SELECT id FROM notes WHERE id IN (\(nph)) AND id NOT IN (SELECT nid FROM cards)", bind: { stmt in
                            for (i, id) in noteIDs.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
                        }) { stmt in
                            deletedNoteIDs.append(sqlite3_column_int64(stmt, 0))
                        }
                        try recordGraves(ids: deletedNoteIDs, type: 1)
                        try db.run("""
                            DELETE FROM notes WHERE id IN (\(nph))
                            AND id NOT IN (SELECT nid FROM cards)
                        """) { stmt in
                            for (i, id) in noteIDs.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
                        }
                    }
                } else {
                    let filteredIDs = decks.filter { $0.isFiltered && ids.contains($0.id) }.map(\.id)
                    for filteredID in filteredIDs {
                        try FilteredDeckSupport.returnHome(deckID: filteredID, store: self)
                    }
                    try db.run("UPDATE cards SET did = 1, mod = ?, usn = -1 WHERE did IN (\(placeholders))") { stmt in
                        SQLiteDatabase.bindInt64(stmt, 1, Int64(Date().timeIntervalSince1970))
                        for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 2), id) }
                    }
                    try db.run("""
                        UPDATE cards
                        SET did = 1,
                            due = CASE WHEN odue != 0 THEN odue ELSE due END,
                            odue = 0,
                            odid = 0,
                            queue = CASE
                                WHEN queue < 0 THEN queue
                                WHEN type = 0 THEN 0
                                WHEN type = 2 THEN 2
                                WHEN type IN (1, 3) THEN CASE WHEN due > 100000000 THEN 1 ELSE 3 END
                                ELSE MAX(queue, 0)
                            END,
                            mod = ?,
                            usn = -1
                        WHERE odid IN (\(placeholders))
                    """) { stmt in
                        SQLiteDatabase.bindInt64(stmt, 1, Int64(Date().timeIntervalSince1970))
                        for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 2), id) }
                    }
                }
                let remaining = decks.filter { !ids.contains($0.id) }
                try recordGraves(ids: ids, type: 2)
                try saveDecks(remaining.isEmpty ? [Self.fallbackDeck()] : remaining)
            }
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            try? reloadMeta()
            try? refreshCounts()
            throw error
        }
        registerBrowserUndo(undoSnapshot)
    }

    private static func fallbackDeck() -> AnkiDeck {
        AnkiDeck(
            id: 1, name: "Default", mod: Int64(Date().timeIntervalSince1970), usn: -1,
            collapsed: false, browserCollapsed: false, desc: "", dyn: 0, conf: 1,
            extendNew: 0, extendRev: 0, newToday: [0, 0], revToday: [0, 0], lrnToday: [0, 0], timeToday: [0, 0]
        )
    }

    func addNote(mid: Int64, did: Int64, fields: [String], tags: String) throws {
        try addNote(mid: mid, did: did, fields: fields, tags: tags, guid: nil)
    }

    func addNote(mid: Int64, did: Int64, fields: [String], tags: String, guid: String?) throws {
        guard let model = notetype(id: mid) else { throw SQLiteError.exec("Missing notetype") }
        let fields = normalizeNoteFields(fields)
        let tags = AnkiTag.join(AnkiTag.canonicalized(tags, existing: Array(self.tags.keys)))
        let nid = timestampID()
        let now = Int64(Date().timeIntervalSince1970)
        let flds = fields.joined(separator: "\u{1f}")
        let firstField = fields.first ?? ""
        let sortFieldIndex = model.flds.first(where: { $0.ord == model.sortf })?.ord ?? 0
        let sfld = stripHTMLPreservingMediaFilenames(fields.indices.contains(sortFieldIndex) ? fields[sortFieldIndex] : "")
        let noteGUID = guid ?? randomGUID()
        let csum = fieldChecksum(firstField)
        try db.run("""
            INSERT INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data)
            VALUES (?, ?, ?, ?, -1, ?, ?, ?, ?, 0, '')
        """) { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, nid)
            try SQLiteDatabase.bindText(stmt, 2, noteGUID)
            SQLiteDatabase.bindInt64(stmt, 3, mid)
            SQLiteDatabase.bindInt64(stmt, 4, now)
            try SQLiteDatabase.bindText(stmt, 5, tags)
            try SQLiteDatabase.bindText(stmt, 6, flds)
            try SQLiteDatabase.bindText(stmt, 7, sfld)
            SQLiteDatabase.bindInt64(stmt, 8, csum)
        }

        let generatedOrds: [Int]
        if model.isCloze {
            generatedOrds = ClozeHelper.ords(in: fields)
        } else {
            generatedOrds = activeTemplateOrds(
                model: model,
                fields: fields,
                tags: AnkiTag.split(tags)
            )
        }
        let ords = generatedOrds.isEmpty ? [0] : generatedOrds
        let due = try nextNewCardPosition(for: did)
        for ord in ords {
            let cid = timestampID()
            try db.run("""
                INSERT INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data)
                VALUES (?, ?, ?, ?, ?, -1, 0, 0, ?, 0, 0, 0, 0, 0, 0, 0, 0, '')
            """) { stmt in
                SQLiteDatabase.bindInt64(stmt, 1, cid)
                SQLiteDatabase.bindInt64(stmt, 2, nid)
                SQLiteDatabase.bindInt64(stmt, 3, did)
                SQLiteDatabase.bindInt(stmt, 4, ord)
                SQLiteDatabase.bindInt64(stmt, 5, now)
                SQLiteDatabase.bindInt(stmt, 6, due)
            }
        }
        try registerTags(from: tags)
        try touchCol()
        try refreshCounts()
    }

    func fetchNote(guid: String) throws -> AnkiNote? {
        var noteID: Int64?
        try db.query("SELECT id FROM notes WHERE guid = ? LIMIT 1", bind: {
            try SQLiteDatabase.bindText($0, 1, guid)
        }) { stmt in
            noteID = sqlite3_column_int64(stmt, 0)
        }
        guard let noteID else { return nil }
        return try fetchNote(id: noteID)
    }

    func duplicateNoteIDs(mid: Int64, fields: [String]) throws -> [Int64] {
        guard notetype(id: mid) != nil else { return [] }
        let value = stripHTMLPreservingMediaFilenames(normalizeNoteText(fields.first ?? ""))
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var ids: [Int64] = []
        try db.query("SELECT id, flds FROM notes WHERE mid = ?", bind: { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, mid)
        }) { stmt in
            let existingFields = SQLiteDatabase.text(stmt, 1).components(separatedBy: "\u{1f}")
            if stripHTMLPreservingMediaFilenames(existingFields.first ?? "") == value {
                ids.append(sqlite3_column_int64(stmt, 0))
            }
        }
        return ids
    }

    func updateNote(_ note: AnkiNote, fields: [String], tags: String) throws {
        let fields = normalizeNoteFields(fields)
        let tags = AnkiTag.join(AnkiTag.canonicalized(tags, existing: Array(self.tags.keys)))
        let flds = fields.joined(separator: "\u{1f}")
        let model = notetype(id: note.mid)
        let firstField = fields.first ?? ""
        let sortFieldIndex = model?.flds.first(where: { $0.ord == (model?.sortf ?? 0) })?.ord ?? 0
        let sfld = stripHTMLPreservingMediaFilenames(fields.indices.contains(sortFieldIndex) ? fields[sortFieldIndex] : "")
        let now = Int64(Date().timeIntervalSince1970)
        try db.run("""
            UPDATE notes SET mod=?, usn=-1, tags=?, flds=?, sfld=?, csum=? WHERE id=?
        """) { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, now)
            try SQLiteDatabase.bindText(stmt, 2, tags)
            try SQLiteDatabase.bindText(stmt, 3, flds)
            try SQLiteDatabase.bindText(stmt, 4, sfld)
            SQLiteDatabase.bindInt64(stmt, 5, self.fieldChecksum(firstField))
            SQLiteDatabase.bindInt64(stmt, 6, note.id)
        }
        if let model = notetype(id: note.mid) {
            if model.isCloze {
                try syncClozeCards(noteID: note.id, fields: fields)
            } else {
                // Re-evaluate optional/conditional templates (e.g. Add Reverse).
                try regenerateCards(forNoteID: note.id)
            }
        }
        try registerTags(from: tags)
        try touchCol()
    }

    /// Keep col.tags in sync for browser sidebar (Anki tag registry).
    func registerTags(from tagsString: String) throws {
        let parts = AnkiTag.canonicalized(tagsString, existing: Array(tags.keys))
        guard !parts.isEmpty else { return }
        var next = tags
        var changed = false
        for t in parts where next[t] == nil {
            next[t] = -1
            changed = true
        }
        guard changed else { return }
        tags = next
        let json = CollectionSchema.encodeJSON(next)
        try db.run("UPDATE col SET tags = ?", bind: { try SQLiteDatabase.bindText($0, 1, json) })
    }

    func rebuildTagRegistry() throws {
        var next: [String: Int] = [:]
        try db.query("SELECT tags FROM notes") { stmt in
            let raw = SQLiteDatabase.text(stmt, 0)
            for t in AnkiTag.split(raw) {
                next[t] = tags[t] ?? -1
            }
        }
        tags = next
        let json = CollectionSchema.encodeJSON(next)
        try db.run("UPDATE col SET tags = ?", bind: { try SQLiteDatabase.bindText($0, 1, json) })
    }

    func noteIDs(matchingTag tag: String) throws -> [Int64] {
        let prefixes = AnkiTag.split(tag)
        guard !prefixes.isEmpty else { return [] }
        var matchingIDs: [Int64] = []
        try db.query("SELECT id, tags FROM notes") { stmt in
            let noteTags = AnkiTag.split(SQLiteDatabase.text(stmt, 1))
            guard noteTags.contains(where: { current in
                prefixes.contains { AnkiTag.replacingPrefix(current, from: $0, to: "") != nil }
            }) else { return }
            matchingIDs.append(sqlite3_column_int64(stmt, 0))
        }
        return matchingIDs
    }

    func allNoteIDs() throws -> [Int64] {
        var noteIDs: [Int64] = []
        try db.query("SELECT id FROM notes ORDER BY id") { stmt in
            noteIDs.append(sqlite3_column_int64(stmt, 0))
        }
        return noteIDs
    }

    func fieldNames(forNoteIDs noteIDs: [Int64]) throws -> [String] {
        var notetypeIDs = Set<Int64>()
        let uniqueIDs = Array(Set(noteIDs)).sorted()
        for start in stride(from: 0, to: uniqueIDs.count, by: 400) {
            let batch = Array(uniqueIDs.dropFirst(start).prefix(400))
            guard !batch.isEmpty else { continue }
            let placeholders = batch.map { _ in "?" }.joined(separator: ",")
            try db.query("SELECT DISTINCT mid FROM notes WHERE id IN (\(placeholders))", bind: { stmt in
                for (index, id) in batch.enumerated() {
                    SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id)
                }
            }) { stmt in
                notetypeIDs.insert(sqlite3_column_int64(stmt, 0))
            }
        }
        return Array(Set(notetypes.filter { notetypeIDs.contains($0.id) }.flatMap { $0.flds.map(\.name) }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func syncNoteCards(
        noteID: Int64,
        wanted: Set<Int>
    ) throws {
        var existing: [(id: Int64, ord: Int, did: Int64, type: Int, queue: Int, due: Int, odue: Int, odid: Int64)] = []
        try db.query("SELECT id, ord, did, type, queue, due, odue, odid FROM cards WHERE nid = ?", bind: {
            SQLiteDatabase.bindInt64($0, 1, noteID)
        }) { stmt in
            existing.append((
                sqlite3_column_int64(stmt, 0),
                Int(sqlite3_column_int(stmt, 1)),
                sqlite3_column_int64(stmt, 2),
                Int(sqlite3_column_int(stmt, 3)),
                Int(sqlite3_column_int(stmt, 4)),
                Int(sqlite3_column_int(stmt, 5)),
                Int(sqlite3_column_int(stmt, 6)),
                sqlite3_column_int64(stmt, 7)
            ))
        }

        let existingOrds = Set(existing.map(\.ord))
        var toAdd = wanted.subtracting(existingOrds)
        if existingOrds.isEmpty && toAdd.isEmpty { toAdd = [0] }
        let homeDid = existing.first.map { $0.odid != 0 ? $0.odid : $0.did } ?? decks.first?.id ?? 1
        let due: Int?
        if let existingNew = existing.first(where: { $0.type == AnkiCard.CardType.new.rawValue || $0.queue == AnkiCard.Queue.new.rawValue }) {
            due = existingNew.odid != 0 ? existingNew.odue : existingNew.due
        } else if !toAdd.isEmpty {
            due = try nextNewCardPosition(for: homeDid)
        } else {
            due = nil
        }
        let now = Int64(Date().timeIntervalSince1970)

        for ord in toAdd.sorted() {
            guard let due else { continue }
            let cid = timestampID()
            try db.run("""
                INSERT INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data)
                VALUES (?, ?, ?, ?, ?, -1, 0, 0, ?, 0, 0, 0, 0, 0, 0, 0, 0, '')
            """) { stmt in
                SQLiteDatabase.bindInt64(stmt, 1, cid)
                SQLiteDatabase.bindInt64(stmt, 2, noteID)
                SQLiteDatabase.bindInt64(stmt, 3, homeDid)
                SQLiteDatabase.bindInt(stmt, 4, ord)
                SQLiteDatabase.bindInt64(stmt, 5, now)
                SQLiteDatabase.bindInt(stmt, 6, due)
            }
        }
    }

    func sortNewCards(inDeck deckID: Int64, randomized: Bool) throws {
        let ordering = randomized ? "random()" : "nid ASC"
        let now = Int64(Date().timeIntervalSince1970)
        try db.run("""
            WITH unique_notes AS MATERIALIZED (
                SELECT c.nid
                FROM cards c
                WHERE (c.did = ? OR (c.odid != 0 AND c.odid = ?)) AND c.type = 0
                GROUP BY c.nid
            ), ordered_notes AS MATERIALIZED (
                SELECT nid, ROW_NUMBER() OVER (ORDER BY \(ordering)) AS position
                FROM unique_notes
            )
            UPDATE cards
            SET due = CASE WHEN odid = 0 THEN (SELECT position FROM ordered_notes WHERE ordered_notes.nid = cards.nid) ELSE due END,
                odue = CASE WHEN odid != 0 THEN (SELECT position FROM ordered_notes WHERE ordered_notes.nid = cards.nid) ELSE odue END,
                mod = ?, usn = -1
            WHERE (did = ? OR (odid != 0 AND odid = ?)) AND type = 0
        """) { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, deckID)
            SQLiteDatabase.bindInt64(stmt, 2, deckID)
            SQLiteDatabase.bindInt64(stmt, 3, now)
            SQLiteDatabase.bindInt64(stmt, 4, deckID)
            SQLiteDatabase.bindInt64(stmt, 5, deckID)
        }
    }

    func nextNewCardPosition(for deckID: Int64, randomize: Bool = true) throws -> Int {
        let configuredNext = (conf["nextPos"] as? Int) ?? 1
        let databaseNext = try db.scalarInt("SELECT COALESCE(MAX(due), 0) + 1 FROM cards WHERE queue = 0")
        let next = max(configuredNext, max(databaseNext, 1))
        let randomized = deck(id: deckID).map { config(for: $0).new.order == 0 } ?? false
        let position = randomize && randomized ? Int.random(in: 1...next) : next
        var updated = conf
        updated["nextPos"] = next + 1
        try saveConf(updated)
        return position
    }

    private func syncClozeCards(noteID: Int64, fields: [String]) throws {
        let wanted = Set(ClozeHelper.ords(in: fields))
        try syncNoteCards(
            noteID: noteID,
            wanted: wanted
        )
        try refreshCounts()
    }

    func deleteNotes(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try db.exec("BEGIN IMMEDIATE")
        do {
            try deleteNotesInTransaction(ids)
            try touchCol()
            try refreshCounts()
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    func deleteNotetypeUndoably(id: Int64) throws {
        guard notetypes.count > 1 else {
            throw SQLiteError.exec("Adicione outro tipo de nota antes de apagar este.")
        }
        guard notetype(id: id) != nil else { return }

        var noteIDs: [Int64] = []
        try db.query("SELECT id FROM notes WHERE mid = ?", bind: {
            SQLiteDatabase.bindInt64($0, 1, id)
        }) { stmt in
            noteIDs.append(sqlite3_column_int64(stmt, 0))
        }
        let auxiliaryConfigKeys = conf.keys.filter { $0.hasPrefix("_nt_\(id)_") }
        let trackedConfigKeys = Set(["curModel", "lastDeckByNoteType"]).union(auxiliaryConfigKeys)
        let snapshot = try makeBrowserUndoSnapshot(
            noteIDs: noteIDs,
            notetypeIDs: [id],
            configKeys: Array(trackedConfigKeys),
            message: "Tipo de nota apagado",
            preserveRevlogWhenRemovingCards: true
        )

        try db.exec("BEGIN IMMEDIATE")
        do {
            try deleteNotesInTransaction(noteIDs)
            let remainingTypes = notetypes.filter { $0.id != id }
            try saveNotetypes(remainingTypes)

            var updatedConf = conf
            updatedConf["curModel"] = remainingTypes[0].id
            if var remembered = updatedConf["lastDeckByNoteType"] as? [String: Any] {
                remembered.removeValue(forKey: String(id))
                updatedConf["lastDeckByNoteType"] = remembered
            }
            for key in updatedConf.keys.filter({ $0.hasPrefix("_nt_\(id)_") }) {
                updatedConf.removeValue(forKey: key)
            }
            try saveConf(updatedConf)
            try refreshCounts()
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            try? reloadMeta()
            try? refreshCounts()
            throw error
        }

        registerBrowserUndo(snapshot)
    }

    private func deleteNotesInTransaction(_ ids: [Int64]) throws {
        let uniqueIDs = Array(Set(ids))
        for start in stride(from: 0, to: uniqueIDs.count, by: 500) {
            let batch = Array(uniqueIDs[start..<min(start + 500, uniqueIDs.count)])
            let placeholders = batch.map { _ in "?" }.joined(separator: ",")
            var cardIDs: [Int64] = []
            try db.query("SELECT id FROM cards WHERE nid IN (\(placeholders))", bind: { stmt in
                for (i, id) in batch.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
            }) { stmt in
                cardIDs.append(sqlite3_column_int64(stmt, 0))
            }
            var noteIDs: [Int64] = []
            try db.query("SELECT id FROM notes WHERE id IN (\(placeholders))", bind: { stmt in
                for (i, id) in batch.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
            }) { stmt in
                noteIDs.append(sqlite3_column_int64(stmt, 0))
            }
            try recordGraves(ids: cardIDs, type: 0)
            try recordGraves(ids: noteIDs, type: 1)
            try db.run("DELETE FROM cards WHERE nid IN (\(placeholders))") { stmt in
                for (i, id) in batch.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
            }
            try db.run("DELETE FROM notes WHERE id IN (\(placeholders))") { stmt in
                for (i, id) in batch.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
            }
        }
    }

    func deleteNotesUndoably(ids: [Int64]) throws {
        let snapshot = try snapshotNotesForDeletion(ids: ids)
        guard !snapshot.notes.isEmpty else { return }
        try deleteNotes(ids: snapshot.notes.map(\.id))
        noteDeletionUndoStack.append(snapshot)
        if noteDeletionUndoStack.count > 30 { noteDeletionUndoStack.removeFirst() }
        browserRedoStack.removeAll()
        undoMessage = snapshot.noteCount == 1 ? "1 nota apagada" : "\(snapshot.noteCount) notas apagadas"
        browserUndoStack.append(.deletion)
        if browserUndoStack.count > 30 { browserUndoStack.removeFirst() }
        refreshBrowserUndoMessage()
        registerBrowserUndoOperation()
        undoRevision &+= 1
    }

    func makeBrowserUndoSnapshot(
        noteIDs: [Int64] = [],
        cardIDs: [Int64] = [],
        notetypeIDs: [Int64] = [],
        configKeys: [String] = [],
        message: String,
        removeManualRevlog: Bool = false,
        deleteNoteIDs: [Int64] = [],
        deleteDeckIDs: [Int64] = [],
        deckIDs: [Int64] = [],
        preserveModificationFields: Bool = false,
        preserveRevlogWhenRemovingCards: Bool = false
    ) throws -> CollectionActionUndoSnapshot {
        let requestedNoteIDs = Set(noteIDs)
        let idsToDelete = Set(deleteNoteIDs)
        let noteSnapshot = try snapshotNotesForDeletion(ids: Array(requestedNoteIDs))
        let notesByID = Dictionary(uniqueKeysWithValues: noteSnapshot.notes.map { ($0.id, $0) })
        var cardsByID = Dictionary(uniqueKeysWithValues: noteSnapshot.cards.map { ($0.id, $0) })
        let missingCardIDs = Set(cardIDs).subtracting(Set(cardsByID.keys))
        for start in stride(from: 0, to: missingCardIDs.count, by: 400) {
            let batch = Array(missingCardIDs.sorted().dropFirst(start).prefix(400))
            guard !batch.isEmpty else { continue }
            let placeholders = batch.map { _ in "?" }.joined(separator: ",")
            try db.query("SELECT * FROM cards WHERE id IN (\(placeholders))", bind: { stmt in
                for (index, id) in batch.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id) }
            }) { stmt in
                let card = Self.mapCard(stmt)
                cardsByID[card.id] = card
            }
        }
        let cards = Array(cardsByID.values)
        let trackedCardIDs = Set(cardIDs)
        let trackedNotetypeIDs = Set(notetypeIDs)
        let notetypeSnapshots = notetypes.filter { trackedNotetypeIDs.contains($0.id) }
        let trackedConfigKeys = Set(configKeys)
        let configValues = Dictionary(uniqueKeysWithValues: trackedConfigKeys.compactMap { key in
            conf[key].map { (key, AnyCodable($0)) }
        })
        let requestedDeckIDs = Set(deckIDs)
        let deckSnapshots = decks.filter { requestedDeckIDs.contains($0.id) }
        var graves = Set(noteSnapshot.graves)
        for start in stride(from: 0, to: trackedCardIDs.count, by: 400) {
            let batch = Array(trackedCardIDs.sorted().dropFirst(start).prefix(400))
            guard !batch.isEmpty else { continue }
            let placeholders = batch.map { _ in "?" }.joined(separator: ",")
            try db.query("SELECT usn, oid, type FROM graves WHERE type=0 AND oid IN (\(placeholders))", bind: { stmt in
                for (index, id) in batch.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id) }
            }) { stmt in
                graves.insert(AnkiGrave(usn: Int(sqlite3_column_int(stmt, 0)), oid: sqlite3_column_int64(stmt, 1), type: Int(sqlite3_column_int(stmt, 2))))
            }
        }
        for start in stride(from: 0, to: requestedDeckIDs.count, by: 400) {
            let batch = Array(requestedDeckIDs.sorted().dropFirst(start).prefix(400))
            guard !batch.isEmpty else { continue }
            let placeholders = batch.map { _ in "?" }.joined(separator: ",")
            try db.query("SELECT usn, oid, type FROM graves WHERE type=2 AND oid IN (\(placeholders))", bind: { stmt in
                for (index, id) in batch.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id) }
            }) { stmt in
                graves.insert(AnkiGrave(usn: Int(sqlite3_column_int(stmt, 0)), oid: sqlite3_column_int64(stmt, 1), type: Int(sqlite3_column_int(stmt, 2))))
            }
        }
        let trackedNoteIDs = requestedNoteIDs.union(idsToDelete)
        for start in stride(from: 0, to: trackedNoteIDs.count, by: 400) {
            let batch = Array(trackedNoteIDs.sorted().dropFirst(start).prefix(400))
            guard !batch.isEmpty else { continue }
            let placeholders = batch.map { _ in "?" }.joined(separator: ",")
            try db.query("SELECT usn, oid, type FROM graves WHERE type=1 AND oid IN (\(placeholders))", bind: { stmt in
                for (index, id) in batch.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id) }
            }) { stmt in
                graves.insert(AnkiGrave(usn: Int(sqlite3_column_int(stmt, 0)), oid: sqlite3_column_int64(stmt, 1), type: Int(sqlite3_column_int(stmt, 2))))
            }
        }
        return CollectionActionUndoSnapshot(
            notes: Array(notesByID.values),
            cards: cards,
            decks: deckSnapshots,
            notetypes: notetypeSnapshots,
            revlogs: [],
            graves: Array(graves),
            noteIDs: requestedNoteIDs.union(idsToDelete),
            trackedCardIDs: trackedCardIDs,
            trackedNotetypeIDs: trackedNotetypeIDs,
            trackedConfigKeys: trackedConfigKeys,
            configValues: configValues,
            deleteNoteIDs: idsToDelete,
            deleteDeckIDs: Set(deleteDeckIDs),
            message: message,
            manualRevlogHighWater: removeManualRevlog ? try db.scalarInt64("SELECT COALESCE(MAX(id), 0) FROM revlog") : nil,
            preserveModificationFields: preserveModificationFields,
            preserveRevlogWhenRemovingCards: preserveRevlogWhenRemovingCards
        )
    }

    func registerBrowserUndo(_ snapshot: CollectionActionUndoSnapshot) {
        guard !snapshot.notes.isEmpty || !snapshot.cards.isEmpty || !snapshot.deleteNoteIDs.isEmpty || !snapshot.deleteDeckIDs.isEmpty || !snapshot.trackedNotetypeIDs.isEmpty else { return }
        do {
            var currentNoteIDs = Set<Int64>()
            let noteIDs = Array(snapshot.noteIDs)
            for start in stride(from: 0, to: noteIDs.count, by: 400) {
                let batch = Array(noteIDs[start..<min(start + 400, noteIDs.count)])
                guard !batch.isEmpty else { continue }
                let placeholders = batch.map { _ in "?" }.joined(separator: ",")
                try db.query("SELECT id FROM notes WHERE id IN (\(placeholders))", bind: { stmt in
                    for (index, id) in batch.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id) }
                }) { stmt in
                    currentNoteIDs.insert(sqlite3_column_int64(stmt, 0))
                }
            }
            let deletedNoteIDs = Set(snapshot.notes.map(\.id)).subtracting(currentNoteIDs)
            var after = try makeBrowserUndoSnapshot(
                noteIDs: noteIDs,
                cardIDs: Array(snapshot.trackedCardIDs),
                notetypeIDs: Array(snapshot.trackedNotetypeIDs),
                configKeys: Array(snapshot.trackedConfigKeys),
                message: snapshot.message,
                deleteNoteIDs: Array(deletedNoteIDs),
                deleteDeckIDs: Array(snapshot.deleteDeckIDs),
                deckIDs: Array(snapshot.deleteDeckIDs),
                preserveModificationFields: snapshot.preserveModificationFields,
                preserveRevlogWhenRemovingCards: snapshot.preserveRevlogWhenRemovingCards
            )
            if let highWater = snapshot.manualRevlogHighWater {
                after.revlogs = try manualRevlogs(after: highWater, cardIDs: after.cards.map(\.id))
            }
            browserRedoStack.removeAll()
            browserUndoStack.append(.action(snapshot, after))
            if browserUndoStack.count > 30 { browserUndoStack.removeFirst() }
            refreshBrowserUndoMessage()
            registerBrowserUndoOperation()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func undoBrowserActionLocally() throws {
        guard let entry = browserUndoStack.last else { return }
        switch entry {
        case .deletion:
            try undoNoteDeletion()
        case .action(let snapshot, let after):
            try restoreBrowserUndoSnapshot(snapshot)
            browserUndoStack.removeLast()
            if let after {
                browserRedoStack.append(.action(forward: after, backward: snapshot))
                if browserRedoStack.count > 30 { browserRedoStack.removeFirst() }
            }
            refreshBrowserUndoMessage()
        }
    }

    private func redoBrowserActionLocally() throws {
        guard let entry = browserRedoStack.last else { return }
        switch entry {
        case .action(let forward, let backward):
            try restoreBrowserUndoSnapshot(forward)
            browserRedoStack.removeLast()
            browserUndoStack.append(.action(backward, forward))
            if browserUndoStack.count > 30 { browserUndoStack.removeFirst() }
            undoRevision &+= 1
            refreshBrowserUndoMessage()
        case .deleteNotes(let ids):
            let snapshot = try snapshotNotesForDeletion(ids: ids)
            guard !snapshot.notes.isEmpty else {
                browserRedoStack.removeLast()
                refreshBrowserUndoMessage()
                return
            }
            try deleteNotes(ids: snapshot.notes.map(\.id))
            browserRedoStack.removeLast()
            noteDeletionUndoStack.append(snapshot)
            if noteDeletionUndoStack.count > 30 { noteDeletionUndoStack.removeFirst() }
            undoMessage = snapshot.noteCount == 1 ? "1 nota apagada" : "\(snapshot.noteCount) notas apagadas"
            browserUndoStack.append(.deletion)
            if browserUndoStack.count > 30 { browserUndoStack.removeFirst() }
            undoRevision &+= 1
            refreshBrowserUndoMessage()
        }
    }

    var canRedoBrowserAction: Bool { !browserRedoStack.isEmpty }

    private func manualRevlogs(after highWater: Int64, cardIDs: [Int64]) throws -> [AnkiRevlog] {
        guard !cardIDs.isEmpty else { return [] }
        var result: [AnkiRevlog] = []
        for start in stride(from: 0, to: cardIDs.count, by: 400) {
            let batch = Array(cardIDs.sorted().dropFirst(start).prefix(400))
            let placeholders = batch.map { _ in "?" }.joined(separator: ",")
            try db.query("SELECT id, cid, usn, ease, ivl, lastIvl, factor, time, type FROM revlog WHERE cid IN (\(placeholders)) AND id > ? AND ease = 0 AND type = 4", bind: { stmt in
                for (index, id) in batch.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id) }
                SQLiteDatabase.bindInt64(stmt, Int32(batch.count + 1), highWater)
            }) { stmt in
                result.append(AnkiRevlog(
                    id: sqlite3_column_int64(stmt, 0),
                    cid: sqlite3_column_int64(stmt, 1),
                    usn: Int(sqlite3_column_int(stmt, 2)),
                    ease: Int(sqlite3_column_int(stmt, 3)),
                    ivl: Int(sqlite3_column_int(stmt, 4)),
                    lastIvl: Int(sqlite3_column_int(stmt, 5)),
                    factor: Int(sqlite3_column_int(stmt, 6)),
                    time: Int(sqlite3_column_int(stmt, 7)),
                    type: Int(sqlite3_column_int(stmt, 8))
                ))
            }
        }
        return result
    }

    func undoNoteDeletion() throws {
        guard let snapshot = noteDeletionUndoStack.last else { return }
        guard db != nil else { throw SQLiteError.exec("A coleção está sendo sincronizada.") }
        try db.exec("BEGIN IMMEDIATE")
        do {
            for note in snapshot.notes {
                try db.run("""
                    INSERT INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """) { stmt in
                    SQLiteDatabase.bindInt64(stmt, 1, note.id)
                    try SQLiteDatabase.bindText(stmt, 2, note.guid)
                    SQLiteDatabase.bindInt64(stmt, 3, note.mid)
                    SQLiteDatabase.bindInt64(stmt, 4, note.mod)
                    SQLiteDatabase.bindInt(stmt, 5, note.usn)
                    try SQLiteDatabase.bindText(stmt, 6, note.tags)
                    try SQLiteDatabase.bindText(stmt, 7, note.flds)
                    try SQLiteDatabase.bindText(stmt, 8, note.sfld)
                    SQLiteDatabase.bindInt64(stmt, 9, note.csum)
                    SQLiteDatabase.bindInt(stmt, 10, note.flags)
                    try SQLiteDatabase.bindText(stmt, 11, note.data)
                }
            }
            for card in snapshot.cards {
                try db.run("""
                    INSERT INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """) { stmt in
                    SQLiteDatabase.bindInt64(stmt, 1, card.id)
                    SQLiteDatabase.bindInt64(stmt, 2, card.nid)
                    SQLiteDatabase.bindInt64(stmt, 3, card.did)
                    SQLiteDatabase.bindInt(stmt, 4, card.ord)
                    SQLiteDatabase.bindInt64(stmt, 5, card.mod)
                    SQLiteDatabase.bindInt(stmt, 6, card.usn)
                    SQLiteDatabase.bindInt(stmt, 7, card.type)
                    SQLiteDatabase.bindInt(stmt, 8, card.queue)
                    SQLiteDatabase.bindInt(stmt, 9, card.due)
                    SQLiteDatabase.bindInt(stmt, 10, card.ivl)
                    SQLiteDatabase.bindInt(stmt, 11, card.factor)
                    SQLiteDatabase.bindInt(stmt, 12, card.reps)
                    SQLiteDatabase.bindInt(stmt, 13, card.lapses)
                    SQLiteDatabase.bindInt(stmt, 14, card.left)
                    SQLiteDatabase.bindInt(stmt, 15, card.odue)
                    SQLiteDatabase.bindInt64(stmt, 16, card.odid)
                    SQLiteDatabase.bindInt(stmt, 17, card.flags)
                    try SQLiteDatabase.bindText(stmt, 18, card.data)
                }
            }
            try removeDeletionGraves(for: snapshot)
            for grave in snapshot.graves {
                try db.run("INSERT INTO graves (usn, oid, type) VALUES (?, ?, ?)") { stmt in
                    SQLiteDatabase.bindInt(stmt, 1, grave.usn)
                    SQLiteDatabase.bindInt64(stmt, 2, grave.oid)
                    SQLiteDatabase.bindInt(stmt, 3, grave.type)
                }
            }
            for note in snapshot.notes { try registerTags(from: note.tags) }
            try touchCol()
            try refreshCounts()
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
        noteDeletionUndoStack.removeLast()
        browserRedoStack.append(.deleteNotes(snapshot.notes.map(\.id)))
        if browserRedoStack.count > 30 { browserRedoStack.removeFirst() }
        undoMessage = noteDeletionUndoStack.last.map { $0.noteCount == 1 ? "1 nota apagada" : "\($0.noteCount) notas apagadas" }
        if let deletionIndex = browserUndoStack.lastIndex(where: { entry in
            if case .deletion = entry { return true }
            return false
        }) {
            browserUndoStack.remove(at: deletionIndex)
        }
        refreshBrowserUndoMessage()
        undoRevision &+= 1
    }

    private func restoreBrowserUndoSnapshot(_ snapshot: CollectionActionUndoSnapshot) throws {
        guard db != nil else { throw SQLiteError.exec("A coleção está sendo sincronizada.") }
        try db.exec("BEGIN IMMEDIATE")
        do {
            if !snapshot.trackedNotetypeIDs.isEmpty {
                var restoredTypes = notetypes.filter { !snapshot.trackedNotetypeIDs.contains($0.id) }
                restoredTypes.append(contentsOf: snapshot.notetypes)
                try saveNotetypes(restoredTypes)
            }
            if !snapshot.trackedConfigKeys.isEmpty {
                var restoredConf = conf
                for key in snapshot.trackedConfigKeys {
                    if let value = snapshot.configValues[key] {
                        restoredConf[key] = value.value
                    } else {
                        restoredConf.removeValue(forKey: key)
                    }
                }
                try saveConf(restoredConf)
            }
            let restoredAt = Int64(Date().timeIntervalSince1970)
            let originalCardIDs = Set(snapshot.cards.map(\.id))
            var currentCardIDs = Set<Int64>()
            let noteIDs = Array(snapshot.noteIDs)
            for start in stride(from: 0, to: noteIDs.count, by: 400) {
                let batch = Array(noteIDs[start..<min(start + 400, noteIDs.count)])
                guard !batch.isEmpty else { continue }
                let placeholders = batch.map { _ in "?" }.joined(separator: ",")
                try db.query("SELECT id FROM cards WHERE nid IN (\(placeholders))", bind: { stmt in
                    for (index, id) in batch.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id) }
                }) { stmt in currentCardIDs.insert(sqlite3_column_int64(stmt, 0)) }
            }
            currentCardIDs.formUnion(snapshot.trackedCardIDs)
            let generatedCardIDs = currentCardIDs.subtracting(originalCardIDs)
            for start in stride(from: 0, to: generatedCardIDs.count, by: 400) {
                let batch = Array(generatedCardIDs.sorted().dropFirst(start).prefix(400))
                guard !batch.isEmpty else { continue }
                let placeholders = batch.map { _ in "?" }.joined(separator: ",")
                if !snapshot.preserveRevlogWhenRemovingCards {
                    try db.run("DELETE FROM revlog WHERE cid IN (\(placeholders))") { stmt in
                        for (index, id) in batch.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id) }
                    }
                }
                try db.run("DELETE FROM cards WHERE id IN (\(placeholders))") { stmt in
                    for (index, id) in batch.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id) }
                }
            }

            if let highWater = snapshot.manualRevlogHighWater {
                let cardIDs = Array(originalCardIDs)
                for start in stride(from: 0, to: cardIDs.count, by: 400) {
                    let batch = Array(cardIDs[start..<min(start + 400, cardIDs.count)])
                    guard !batch.isEmpty else { continue }
                    let placeholders = batch.map { _ in "?" }.joined(separator: ",")
                    try db.run("DELETE FROM revlog WHERE cid IN (\(placeholders)) AND id > ? AND ease = 0 AND type = 4") { stmt in
                        for (index, id) in batch.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id) }
                        SQLiteDatabase.bindInt64(stmt, Int32(batch.count + 1), highWater)
                    }
                }
            }

            for note in snapshot.notes {
                try db.run("""
                    INSERT OR REPLACE INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """) { stmt in
                    SQLiteDatabase.bindInt64(stmt, 1, note.id)
                    try SQLiteDatabase.bindText(stmt, 2, note.guid)
                    SQLiteDatabase.bindInt64(stmt, 3, note.mid)
                    SQLiteDatabase.bindInt64(stmt, 4, snapshot.preserveModificationFields ? note.mod : restoredAt)
                    SQLiteDatabase.bindInt(stmt, 5, snapshot.preserveModificationFields ? note.usn : -1)
                    try SQLiteDatabase.bindText(stmt, 6, note.tags)
                    try SQLiteDatabase.bindText(stmt, 7, note.flds)
                    try SQLiteDatabase.bindText(stmt, 8, note.sfld)
                    SQLiteDatabase.bindInt64(stmt, 9, note.csum)
                    SQLiteDatabase.bindInt(stmt, 10, note.flags)
                    try SQLiteDatabase.bindText(stmt, 11, note.data)
                }
            }
            for card in snapshot.cards {
                try db.run("""
                    INSERT OR REPLACE INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """) { stmt in
                    SQLiteDatabase.bindInt64(stmt, 1, card.id)
                    SQLiteDatabase.bindInt64(stmt, 2, card.nid)
                    SQLiteDatabase.bindInt64(stmt, 3, card.did)
                    SQLiteDatabase.bindInt(stmt, 4, card.ord)
                    SQLiteDatabase.bindInt64(stmt, 5, snapshot.preserveModificationFields ? card.mod : restoredAt)
                    SQLiteDatabase.bindInt(stmt, 6, snapshot.preserveModificationFields ? card.usn : -1)
                    SQLiteDatabase.bindInt(stmt, 7, card.type)
                    SQLiteDatabase.bindInt(stmt, 8, card.queue)
                    SQLiteDatabase.bindInt(stmt, 9, card.due)
                    SQLiteDatabase.bindInt(stmt, 10, card.ivl)
                    SQLiteDatabase.bindInt(stmt, 11, card.factor)
                    SQLiteDatabase.bindInt(stmt, 12, card.reps)
                    SQLiteDatabase.bindInt(stmt, 13, card.lapses)
                    SQLiteDatabase.bindInt(stmt, 14, card.left)
                    SQLiteDatabase.bindInt(stmt, 15, card.odue)
                    SQLiteDatabase.bindInt64(stmt, 16, card.odid)
                    SQLiteDatabase.bindInt(stmt, 17, card.flags)
                    try SQLiteDatabase.bindText(stmt, 18, card.data)
                }
            }
            if !snapshot.deleteNoteIDs.isEmpty {
                let deletedNoteIDs = Array(snapshot.deleteNoteIDs)
                for start in stride(from: 0, to: deletedNoteIDs.count, by: 400) {
                    let batch = Array(deletedNoteIDs[start..<min(start + 400, deletedNoteIDs.count)])
                    let placeholders = batch.map { _ in "?" }.joined(separator: ",")
                    try db.run("DELETE FROM notes WHERE id IN (\(placeholders))") { stmt in
                        for (index, id) in batch.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id) }
                    }
                }
            }
            let restoredDeckIDs = Set(snapshot.decks.map(\.id)).union(snapshot.deleteDeckIDs)
            if !restoredDeckIDs.isEmpty {
                let ids = Array(restoredDeckIDs)
                for start in stride(from: 0, to: ids.count, by: 400) {
                    let batch = Array(ids[start..<min(start + 400, ids.count)])
                    let placeholders = batch.map { _ in "?" }.joined(separator: ",")
                    try db.run("DELETE FROM graves WHERE type=2 AND oid IN (\(placeholders))") { stmt in
                        for (index, id) in batch.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id) }
                    }
                }
            }
            if !snapshot.decks.isEmpty || !snapshot.deleteDeckIDs.isEmpty {
                var restoredDecks = decks.filter { !snapshot.deleteDeckIDs.contains($0.id) }
                for deck in snapshot.decks {
                    if let index = restoredDecks.firstIndex(where: { $0.id == deck.id }) {
                        restoredDecks[index] = deck
                    } else {
                        restoredDecks.append(deck)
                    }
                }
                try saveDecks(restoredDecks)
            }

            let graveCardIDs = currentCardIDs.union(originalCardIDs)
            try deleteGraves(cardIDs: Array(graveCardIDs), noteIDs: noteIDs)
            for grave in snapshot.graves {
                try db.run("INSERT INTO graves (usn, oid, type) VALUES (?, ?, ?)") { stmt in
                    SQLiteDatabase.bindInt(stmt, 1, grave.usn)
                    SQLiteDatabase.bindInt64(stmt, 2, grave.oid)
                    SQLiteDatabase.bindInt(stmt, 3, grave.type)
                }
            }
            for revlog in snapshot.revlogs {
                try db.run("INSERT OR REPLACE INTO revlog (id, cid, usn, ease, ivl, lastIvl, factor, time, type) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)") { stmt in
                    SQLiteDatabase.bindInt64(stmt, 1, revlog.id)
                    SQLiteDatabase.bindInt64(stmt, 2, revlog.cid)
                    SQLiteDatabase.bindInt(stmt, 3, revlog.usn)
                    SQLiteDatabase.bindInt(stmt, 4, revlog.ease)
                    SQLiteDatabase.bindInt(stmt, 5, revlog.ivl)
                    SQLiteDatabase.bindInt(stmt, 6, revlog.lastIvl)
                    SQLiteDatabase.bindInt(stmt, 7, revlog.factor)
                    SQLiteDatabase.bindInt(stmt, 8, revlog.time)
                    SQLiteDatabase.bindInt(stmt, 9, revlog.type)
                }
            }
            try recordGraves(ids: Array(generatedCardIDs), type: 0)
            if !snapshot.deleteNoteIDs.isEmpty {
                try recordGraves(ids: Array(snapshot.deleteNoteIDs), type: 1)
            }
            for note in snapshot.notes { try registerTags(from: note.tags) }
            try touchCol()
            try refreshCounts()
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            try? reloadMeta()
            throw error
        }
    }

    private func deleteGraves(cardIDs: [Int64], noteIDs: [Int64]) throws {
        for (ids, type) in [(cardIDs, 0), (noteIDs, 1)] {
            for start in stride(from: 0, to: ids.count, by: 400) {
                let batch = Array(ids[start..<min(start + 400, ids.count)])
                guard !batch.isEmpty else { continue }
                let placeholders = batch.map { _ in "?" }.joined(separator: ",")
                try db.run("DELETE FROM graves WHERE type=? AND oid IN (\(placeholders))") { stmt in
                    SQLiteDatabase.bindInt(stmt, 1, type)
                    for (index, id) in batch.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 2), id) }
                }
            }
        }
    }

    private func refreshBrowserUndoMessage() {
        switch browserUndoStack.last {
        case .action(let snapshot, _): browserUndoMessage = snapshot.message
        case .deletion: browserUndoMessage = undoMessage
        case nil: browserUndoMessage = nil
        }
        switch browserRedoStack.last {
        case .action(let forward, _): browserRedoMessage = forward.message
        case .deleteNotes(let ids): browserRedoMessage = ids.count == 1 ? "1 nota apagada" : "\(ids.count) notas apagadas"
        case nil: browserRedoMessage = nil
        }
        refreshCollectionUndoMessages()
    }

    private func clearNoteDeletionUndoHistory() {
        clearCollectionUndoHistory()
    }

    private func snapshotNotesForDeletion(ids: [Int64]) throws -> NoteDeletionSnapshot {
        var notes: [AnkiNote] = []
        var cards: [AnkiCard] = []
        for start in stride(from: 0, to: ids.count, by: 500) {
            let batch = Array(ids[start..<min(start + 500, ids.count)])
            guard !batch.isEmpty else { continue }
            let placeholders = batch.map { _ in "?" }.joined(separator: ",")
            try db.query("SELECT * FROM notes WHERE id IN (\(placeholders))", bind: { stmt in
                for (index, id) in batch.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id) }
            }) { stmt in notes.append(Self.mapNote(stmt)) }
            try db.query("SELECT * FROM cards WHERE nid IN (\(placeholders))", bind: { stmt in
                for (index, id) in batch.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 1), id) }
            }) { stmt in cards.append(Self.mapCard(stmt)) }
        }
        let cardIDs = cards.map(\.id)
        let noteIDs = notes.map(\.id)
        var graves: [AnkiGrave] = []
        for start in stride(from: 0, to: max(cardIDs.count, noteIDs.count), by: 400) {
            let cardBatch = Array(cardIDs.dropFirst(start).prefix(400))
            let noteBatch = Array(noteIDs.dropFirst(start).prefix(400))
            var conditions: [String] = []
            if !cardBatch.isEmpty { conditions.append("(type = 0 AND oid IN (\(cardBatch.map { _ in "?" }.joined(separator: ","))))") }
            if !noteBatch.isEmpty { conditions.append("(type = 1 AND oid IN (\(noteBatch.map { _ in "?" }.joined(separator: ","))))") }
            guard !conditions.isEmpty else { continue }
            try db.query("SELECT usn, oid, type FROM graves WHERE \(conditions.joined(separator: " OR "))", bind: { stmt in
                var index: Int32 = 1
                for id in cardBatch { SQLiteDatabase.bindInt64(stmt, index, id); index += 1 }
                for id in noteBatch { SQLiteDatabase.bindInt64(stmt, index, id); index += 1 }
            }) { stmt in
                graves.append(AnkiGrave(
                    usn: Int(sqlite3_column_int(stmt, 0)),
                    oid: sqlite3_column_int64(stmt, 1),
                    type: Int(sqlite3_column_int(stmt, 2))
                ))
            }
        }
        return NoteDeletionSnapshot(notes: notes, cards: cards, graves: graves)
    }

    private func removeDeletionGraves(for snapshot: NoteDeletionSnapshot) throws {
        for (ids, type) in [(snapshot.cards.map(\.id), 0), (snapshot.notes.map(\.id), 1)] {
            for start in stride(from: 0, to: ids.count, by: 500) {
                let batch = Array(ids[start..<min(start + 500, ids.count)])
                let placeholders = batch.map { _ in "?" }.joined(separator: ",")
                try db.run("DELETE FROM graves WHERE type = ? AND oid IN (\(placeholders))") { stmt in
                    SQLiteDatabase.bindInt(stmt, 1, type)
                    for (index, id) in batch.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(index + 2), id) }
                }
            }
        }
    }

    func recordGraves(ids: [Int64], type: Int) throws {
        for id in Set(ids) {
            try db.run("""
                INSERT INTO graves (usn, oid, type)
                SELECT -1, ?, ?
                WHERE NOT EXISTS (SELECT 1 FROM graves WHERE oid = ? AND type = ?)
            """) { stmt in
                SQLiteDatabase.bindInt64(stmt, 1, id)
                SQLiteDatabase.bindInt(stmt, 2, type)
                SQLiteDatabase.bindInt64(stmt, 3, id)
                SQLiteDatabase.bindInt(stmt, 4, type)
            }
        }
    }

    func setCardsFlag(_ ids: [Int64], flag: Int) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let normalizedFlag = min(max(flag, 0), 7)
        try db.run("UPDATE cards SET flags = (flags & ~7) | ?, mod = ?, usn = -1 WHERE id IN (\(placeholders)) AND (flags & 7) != ?") { stmt in
            SQLiteDatabase.bindInt(stmt, 1, normalizedFlag)
            SQLiteDatabase.bindInt64(stmt, 2, Int64(Date().timeIntervalSince1970))
            for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 3), id) }
            SQLiteDatabase.bindInt(stmt, Int32(ids.count + 3), normalizedFlag)
        }
        try touchCol()
    }

    func setCardsQueue(_ ids: [Int64], queue: Int) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        try db.run("UPDATE cards SET queue = ?, mod = ?, usn = -1 WHERE id IN (\(placeholders)) AND queue != ?") { stmt in
            SQLiteDatabase.bindInt(stmt, 1, queue)
            SQLiteDatabase.bindInt64(stmt, 2, Int64(Date().timeIntervalSince1970))
            for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 3), id) }
            SQLiteDatabase.bindInt(stmt, Int32(ids.count + 3), queue)
        }
        try touchCol()
        try refreshCounts()
    }

    func buryCards(_ ids: [Int64]) throws {
        let candidates = try ids.filter { id in
            guard let card = try fetchCard(id: id) else { return false }
            return card.queue != -1 && card.queue != -3
        }
        try setCardsQueue(candidates, queue: -3)
    }

    /// Anki `restore_queue_after_bury_or_suspend`. The automatic day-rollover unbury
    /// does not mark cards as modified; user actions do (mtime + usn -1).
    func restoreCardsToActiveQueue(_ ids: [Int64], markModified: Bool = true, refresh: Bool = true) throws {
        guard !ids.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970)
        for id in ids {
            guard var card = try fetchCard(id: id), [-1, -2, -3].contains(card.queue) else { continue }
            switch card.type {
            case 1, 3: card.queue = card.due > 1_000_000_000 ? 1 : 3
            case 2: card.queue = 2
            default: card.queue = 0
            }
            if markModified {
                card.mod = now
                card.usn = -1
            }
            try updateCard(card)
        }
        if refresh { try refreshCounts() }
    }

    func unburyCards(_ ids: [Int64]) throws {
        let buried = try ids.filter { id in
            guard let c = try fetchCard(id: id) else { return false }
            return c.queue < 0
        }
        try restoreCardsToActiveQueue(buried)
    }

    func unsuspendCards(_ ids: [Int64]) throws {
        let suspended = try ids.filter { id in
            guard let c = try fetchCard(id: id) else { return false }
            return c.queue < 0
        }
        try restoreCardsToActiveQueue(suspended)
    }

    func unburyAll() throws {
        var ids: [Int64] = []
        try db.query("SELECT id FROM cards WHERE queue IN (-2,-3)") { stmt in
            ids.append(sqlite3_column_int64(stmt, 0))
        }
        try unburyCards(ids)
    }

    /// Unbury cards in a deck and its subdecks (Anki overview “Unbury”).
    /// `-2` is sibling bury, `-3` is manual bury.
    func unburyDeckTree(deckID: Int64, queues: Set<Int> = [-2, -3]) throws {
        let cardIDs = try cardsToUnbury(deckID: deckID, queues: queues).map(\.id)
        try unburyCards(cardIDs)
        try refreshCounts()
    }

    func cardsToUnbury(deckID: Int64, queues: Set<Int> = [-2, -3]) throws -> [AnkiCard] {
        let deckIDs = deckTreeIDs(including: deckID)
        let wanted = queues.isEmpty ? [-2, -3] : queues.sorted()
        let deckPlaceholders = deckIDs.map { _ in "?" }.joined(separator: ",")
        let queuePlaceholders = wanted.map { _ in "?" }.joined(separator: ",")
        var cards: [AnkiCard] = []
        try db.query(
            "SELECT * FROM cards WHERE did IN (\(deckPlaceholders)) AND queue IN (\(queuePlaceholders))",
            bind: { stmt in
                for (i, id) in deckIDs.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 1), id) }
                for (i, queue) in wanted.enumerated() {
                    SQLiteDatabase.bindInt(stmt, Int32(deckIDs.count + 1 + i), queue)
                }
            }
        ) { cards.append(Self.mapCard($0)) }
        return cards
    }

    func cards(inQueue queue: Int) throws -> [AnkiCard] {
        var cards: [AnkiCard] = []
        try db.query("SELECT * FROM cards WHERE queue = ?") { stmt in
            SQLiteDatabase.bindInt(stmt, 1, queue)
        } map: { stmt in
            cards.append(Self.mapCard(stmt))
        }
        return cards
    }

    /// Anki “Forget” / reset: card becomes new again (queue 0), progress cleared.
    // resetCards(_:restoreOriginalPosition:clearCounts:) lives in CardOperations.swift (Anki Forget/Reset).

    func moveCards(_ ids: [Int64], toDeck did: Int64) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        try db.run("UPDATE cards SET did = ?, mod = ?, usn = -1 WHERE id IN (\(placeholders))") { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, did)
            SQLiteDatabase.bindInt64(stmt, 2, Int64(Date().timeIntervalSince1970))
            for (i, id) in ids.enumerated() { SQLiteDatabase.bindInt64(stmt, Int32(i + 3), id) }
        }
        try touchCol()
        try refreshCounts()
    }

    // MARK: - Search / Browser

    struct BrowserRow: Identifiable, Hashable {
        var id: Int64 { card.id }
        var card: AnkiCard
        var note: AnkiNote
        var deckName: String
        var originalDeckName: String? = nil
        var templateDeckName: String { originalDeckName ?? deckName }
        var notetypeName: String
        var cardCount = 1
        var latestCardMod: Int64 = 0
        var deckCount = 1
        var averageEase: Double?
        var averageInterval: Double?
        var totalReps = 0
        var totalLapses = 0
        var nextDueTimestamp: Int64?
    }

    struct DuplicateNoteGroup: Identifiable, Hashable {
        var value: String
        var noteIDs: [Int64]
        var id: String { value }
    }

    func duplicateNoteGroups(
        fieldName: String,
        searchQuery: String = "",
        selectedNoteIDs: Set<Int64>? = nil
    ) throws -> [DuplicateNoteGroup] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingNoteIDs: Set<Int64>?
        if query.isEmpty {
            matchingNoteIDs = nil
        } else {
            matchingNoteIDs = Set(try search(query: query, limit: 1_000_000).map { $0.note.id })
        }

        var values: [String: [Int64]] = [:]
        try db.query("SELECT id, mid, flds FROM notes") { stmt in
            let noteID = sqlite3_column_int64(stmt, 0)
            guard selectedNoteIDs?.contains(noteID) ?? true,
                  matchingNoteIDs?.contains(noteID) ?? true,
                  let notetype = self.notetype(id: sqlite3_column_int64(stmt, 1)),
                  let field = notetype.flds.first(where: {
                      $0.name.compare(fieldName, options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) == .orderedSame
                  }) else { return }
            let fields = SQLiteDatabase.text(stmt, 2).components(separatedBy: "\u{1f}")
            guard fields.indices.contains(field.ord) else { return }
            let value = self.stripHTMLPreservingMediaFilenames(fields[field.ord])
            guard !value.isEmpty else { return }
            values[value, default: []].append(noteID)
        }

        return values.compactMap { value, noteIDs in
            noteIDs.count > 1 ? DuplicateNoteGroup(value: value, noteIDs: noteIDs.sorted()) : nil
        }.sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
    }

    private func sortFieldComesBefore(_ lhs: String, _ rhs: String, tieBreak: Bool) -> Bool {
        let order = lhs.localizedCaseInsensitiveCompare(rhs)
        return order == .orderedSame ? tieBreak : order == .orderedAscending
    }

    private indirect enum SearchExpression {
        case term(String)
        case and(SearchExpression, SearchExpression)
        case or(SearchExpression, SearchExpression)
        case not(SearchExpression)
    }

    private func validateSearchOperators(_ tokens: [String]) throws {
        let validStates: Set<String> = [
            "is:new", "is:learn", "is:review", "is:due", "is:suspended",
            "is:buried", "is:buried-sibling", "is:buried-manually"
        ]
        for rawToken in tokens {
            let token = stripSearchQuotes(rawToken.hasPrefix("-") ? String(rawToken.dropFirst()) : rawToken)
                .lowercased()
            if token.hasPrefix("is:"), !validStates.contains(token) {
                throw SQLiteError.exec("Estado de cartão desconhecido: \(token)")
            }
            if token.hasPrefix("flag:") {
                let flag = String(token.dropFirst("flag:".count))
                let numericFlag = Int(flag)
                guard numericFlag.map({ (0...7).contains($0) }) == true else {
                    throw SQLiteError.exec("Bandeira de cartão inválida: \(flag)")
                }
            }
            if token.hasPrefix("did:") || token.hasPrefix("mid:") || token.hasPrefix("nid:") || token.hasPrefix("cid:") {
                let values = String(token.dropFirst(4)).split(separator: ",", omittingEmptySubsequences: false)
                guard !values.isEmpty, values.allSatisfy({ Int64($0) != nil }) else {
                    throw SQLiteError.exec("ID inválido no operador de busca: \(token)")
                }
            }
            for prefix in ["added:", "edited:", "introduced:"] where token.hasPrefix(prefix) {
                guard UInt32(token.dropFirst(prefix.count)) != nil else {
                    throw SQLiteError.exec("Período inválido no operador de busca: \(token)")
                }
            }
            if token.hasPrefix("rated:") {
                let parts = String(token.dropFirst("rated:".count))
                    .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count <= 2,
                      !parts.isEmpty,
                      UInt32(parts[0]) != nil,
                      parts.count == 1 || Int(parts[1]).map({ (1...4).contains($0) }) == true else {
                    throw SQLiteError.exec("Busca de avaliação inválida: \(token)")
                }
            }
            if token.hasPrefix("resched:") {
                guard UInt32(token.dropFirst("resched:".count)) != nil else {
                    throw SQLiteError.exec("Período inválido no operador de busca: \(token)")
                }
            }
            if token.hasPrefix("prop:rated") {
                guard Self.parseRatingProperty(token, key: "rated") != nil else {
                    throw SQLiteError.exec("Propriedade de avaliação inválida: \(token)")
                }
            }
            if token.hasPrefix("prop:resched") {
                guard Self.parseRatingProperty(token, key: "resched") != nil else {
                    throw SQLiteError.exec("Propriedade de reagendamento inválida: \(token)")
                }
            }
            if token.hasPrefix("dupe:"), Self.parseDuplicateSearch(token) == nil {
                throw SQLiteError.exec("Busca de duplicados inválida: \(token)")
            }
            if token.hasPrefix("prop:") {
                let valid = Self.parseProp(token, key: "ivl") != nil
                    || Self.parseProp(token, key: "due") != nil
                    || Self.parseProp(token, key: "reps") != nil
                    || Self.parseProp(token, key: "lapses") != nil
                    || Self.parseProp(token, key: "pos") != nil
                    || Self.parseProp(token, key: "factor") != nil
                    || Self.parsePropScaled(token, key: "ease", scale: 1000) != nil
                    || Self.parseRatingProperty(token, key: "rated") != nil
                    || Self.parseRatingProperty(token, key: "resched") != nil
                    || Self.parseDecimalProp(token, key: "s") != nil
                    || Self.parseDecimalProp(token, key: "d") != nil
                    || Self.parseDecimalProp(token, key: "r") != nil
                    || Self.validCustomDataProperty(token)
                guard valid else { throw SQLiteError.exec("Propriedade de busca inválida: \(token)") }
            }
        }
    }

    func search(query: String, limit: Int = 500, offset: Int = 0, sortType: Int = 0, sortDescending: Bool = false, notesMode: Bool = false) throws -> [BrowserRow] {
        let clauses = try searchExpressionClauses(query)
        let ignoreAccents = conf["ignoreAccentsInSearch"] as? Bool ?? false
        if clauses.count > 1 {
            var seen = Set<Int64>()
            var rows: [BrowserRow] = []
            for clause in clauses {
                let part = clause.joined(separator: " ")
                for row in try search(query: part, limit: limit + offset, sortType: sortType, sortDescending: sortDescending, notesMode: notesMode) where seen.insert(row.id).inserted {
                    rows.append(row)
                }
            }
            let today = schedDay()
            let now = Int(Date().timeIntervalSince1970)
            rows.sort { left, right in
                switch sortType {
                case 1:
                    func dueOrder(_ card: AnkiCard) -> Int64 {
                        if card.due > 1_000_000_000 || card.type == AnkiCard.CardType.new.rawValue {
                            return Int64(card.due)
                        }
                        return Int64(card.due - today) * 86_400 + Int64(now)
                    }
                    let leftDue = dueOrder(left.card)
                    let rightDue = dueOrder(right.card)
                    return leftDue == rightDue ? left.id < right.id : leftDue < rightDue
                case 2:
                    if left.note.id != right.note.id { return left.note.id < right.note.id }
                    return left.card.ord == right.card.ord ? left.id < right.id : left.card.ord < right.card.ord
                case 3:
                    if left.note.mod != right.note.mod { return left.note.mod < right.note.mod }
                    return left.card.ord == right.card.ord ? left.id < right.id : left.card.ord < right.card.ord
                case 4: return left.card.ivl == right.card.ivl ? left.id < right.id : left.card.ivl < right.card.ivl
                case 5:
                    let order = left.deckName.localizedCaseInsensitiveCompare(right.deckName)
                    return order == .orderedSame ? left.id < right.id : order == .orderedAscending
                case 6:
                    let leftIsNew = left.card.type == AnkiCard.CardType.new.rawValue
                    let rightIsNew = right.card.type == AnkiCard.CardType.new.rawValue
                    if leftIsNew != rightIsNew { return !leftIsNew }
                    return left.card.factor == right.card.factor ? left.id < right.id : left.card.factor < right.card.factor
                case 7: return left.card.reps == right.card.reps ? left.id < right.id : left.card.reps < right.card.reps
                case 8: return left.card.lapses == right.card.lapses ? left.id < right.id : left.card.lapses < right.card.lapses
                case 9: return left.card.mod == right.card.mod ? left.id < right.id : left.card.mod < right.card.mod
                case 10:
                    return left.card.ord == right.card.ord ? left.id < right.id : left.card.ord < right.card.ord
                case 14:
                    let leftValue = left.cardCount
                    let rightValue = right.cardCount
                    return leftValue == rightValue ? left.id < right.id : leftValue < rightValue
                case 11:
                    let order = left.notetypeName.localizedCaseInsensitiveCompare(right.notetypeName)
                    return order == .orderedSame ? left.id < right.id : order == .orderedAscending
                case 12:
                    let leftTags = left.note.tagList.joined(separator: " ")
                    let rightTags = right.note.tagList.joined(separator: " ")
                    let order = leftTags.localizedCaseInsensitiveCompare(rightTags)
                    return order == .orderedSame ? left.id < right.id : order == .orderedAscending
                case 13:
                    let leftPosition = FSRSCardData.originalPosition(in: left.card.data) ?? (left.card.type == 0 ? left.card.due : Int.min)
                    let rightPosition = FSRSCardData.originalPosition(in: right.card.data) ?? (right.card.type == 0 ? right.card.due : Int.min)
                    return leftPosition == rightPosition ? left.id < right.id : leftPosition < rightPosition
                case 15:
                    return (left.nextDueTimestamp ?? .min) == (right.nextDueTimestamp ?? .min)
                        ? left.id < right.id
                        : (left.nextDueTimestamp ?? .min) < (right.nextDueTimestamp ?? .min)
                case 16:
                    let leftValue = left.averageInterval ?? -.infinity
                    let rightValue = right.averageInterval ?? -.infinity
                    return leftValue == rightValue ? left.id < right.id : leftValue < rightValue
                case 17:
                    let leftValue = left.averageEase ?? -.infinity
                    let rightValue = right.averageEase ?? -.infinity
                    return leftValue == rightValue ? left.id < right.id : leftValue < rightValue
                case 18:
                    return left.totalReps == right.totalReps ? left.id < right.id : left.totalReps < right.totalReps
                case 19:
                    return left.totalLapses == right.totalLapses ? left.id < right.id : left.totalLapses < right.totalLapses
                case 20:
                    let leftValue = FSRSCardData.memory(in: left.card.data)?.stability ?? -.infinity
                    let rightValue = FSRSCardData.memory(in: right.card.data)?.stability ?? -.infinity
                    return leftValue == rightValue ? left.id < right.id : leftValue < rightValue
                case 21:
                    let leftValue = FSRSCardData.memory(in: left.card.data)?.difficulty ?? -.infinity
                    let rightValue = FSRSCardData.memory(in: right.card.data)?.difficulty ?? -.infinity
                    return leftValue == rightValue ? left.id < right.id : leftValue < rightValue
                case 22:
                    let leftValue = Self.reviewRetrievability(left.card, today: today, now: now) ?? -.infinity
                    let rightValue = Self.reviewRetrievability(right.card, today: today, now: now) ?? -.infinity
                    return leftValue == rightValue ? left.id < right.id : leftValue < rightValue
                default:
                    let tieBreak = left.card.ord == right.card.ord ? left.id < right.id : left.card.ord < right.card.ord
                    return sortFieldComesBefore(left.note.sfld, right.note.sfld, tieBreak: tieBreak)
                }
            }
            if sortDescending { rows.reverse() }
            return Array(rows.dropFirst(offset).prefix(limit))
        }

        // Simplified Anki-like search
        var sql = "SELECT c.id FROM cards c JOIN notes n ON n.id = c.nid WHERE 1=1"
        let binds: [(OpaquePointer) -> Void] = []
        let tokens = clauses.first ?? []
        try validateSearchOperators(tokens)
        let hasExcludedSearchFields = notetypes.contains { $0.flds.contains(where: \.excludeFromSearch) }
        let hasUnqualifiedTextSearch = tokens.contains(where: isUnqualifiedTextSearchToken)

        for rawToken in tokens {
            if rawToken.caseInsensitiveCompare("AND") == .orderedSame { continue }
            let negated = rawToken.hasPrefix("-")
            let token = stripSearchQuotes(negated ? String(rawToken.dropFirst()) : rawToken)
            if regexSearchFilter(rawToken) != nil { continue }
            let notSQL = negated ? " NOT" : ""
            let andNot = negated ? " AND NOT" : " AND"

            if token.hasPrefix("deck:") {
                if token == "deck:filtered" {
                    sql += negated ? " AND c.odid = 0" : " AND c.odid != 0"
                } else {
                    let parsed = parseDeckSearchToken(token)
                    if parsed.name == "current" {
                        let currentID = currentDeckID()
                            ?? recommendedStudyDeck?.id
                            ?? decks.first(where: { $0.name != "Default" })?.id
                            ?? decks.first?.id
                        if let currentID {
                            let tree = deckTreeIDs(including: currentID)
                            let list = tree.map(String.init).joined(separator: ",")
                            sql += "\(andNot) (c.did IN (\(list)) OR (c.odid != 0 AND c.odid IN (\(list))))"
                        } else {
                            sql += negated ? "" : " AND 0"
                        }
                    } else {
                        let matching = deckIDs(matchingSearchName: parsed.name, exact: parsed.exact)
                        if matching.isEmpty {
                            sql += negated ? "" : " AND 0"
                        } else {
                            let ph = matching.map { _ in "?" }.joined(separator: ",")
                            sql += "\(andNot) (c.did IN (\(ph)) OR (c.odid != 0 AND c.odid IN (\(ph))))"
                        }
                    }
                }
            } else if token == "is:new" {
                sql += "\(andNot) (c.type = 0)"
            } else if token == "is:learn" {
                sql += "\(andNot) (c.type IN (1, 3))"
            } else if token == "is:review" {
                sql += "\(andNot) (c.type IN (2, 3))"
            } else if token == "is:suspended" {
                sql += "\(andNot) (c.queue = -1)"
            } else if token == "is:buried" {
                sql += "\(andNot) (c.queue IN (-2,-3))"
            } else if token == "is:due" {
                let day = schedDay()
                let learnCutoff = Int(Date().timeIntervalSince1970) + (conf["collapseTime"] as? Int ?? 1200)
                sql += "\(andNot) ((c.queue IN (2, 3) AND c.due <= \(day)) OR (c.queue IN (1, 4) AND c.due <= \(learnCutoff)))"
            } else if token == "is:buried-sibling" {
                sql += "\(andNot) (c.queue = -2)"
            } else if token == "is:buried-manually" {
                sql += "\(andNot) (c.queue = -3)"
            } else if token.hasPrefix("prop:pos") {
                if let (op, n) = Self.parseProp(token, key: "pos") {
                    sql += "\(andNot) (c.type = 0 AND (CASE WHEN c.odue != 0 THEN c.odue ELSE c.due END) \(op) \(n))"
                }
            } else if token.hasPrefix("flag:") {
                let raw = String(token.dropFirst(5)).lowercased()
                let f: Int?
                switch raw {
                case "red", "1": f = 1
                case "orange", "2": f = 2
                case "green", "3": f = 3
                case "blue", "4": f = 4
                case "pink", "5": f = 5
                case "turquoise", "teal", "6": f = 6
                case "purple", "7": f = 7
                case "none", "0": f = 0
                default: f = Int(raw)
                }
                if let f {
                    sql += "\(andNot) ((c.flags & 7) = \(f))"
                }
            } else if token.hasPrefix("added:") {
                let days = max(Int(token.dropFirst(6)) ?? 1, 1)
                let since = searchDayStart(days: days) * 1000
                sql += "\(andNot) (c.id > \(since))"
            } else if token.hasPrefix("rated:") {
                // rated:1  or  rated:1:1 (days:ease). Day 1 is the current scheduling day.
                let bits = token.split(separator: ":").map(String.init)
                let days = max(Int(bits.count > 1 ? bits[1] : "1") ?? 1, 1)
                let ease = bits.count > 2 ? Int(bits[2]) : nil
                let cutoff = searchDayStart(days: days) * 1000
                if let ease {
                    sql += "\(andNot) (c.id IN (SELECT cid FROM revlog WHERE id >= \(cutoff) AND ease = \(ease)))"
                } else {
                    sql += "\(andNot) (c.id IN (SELECT cid FROM revlog WHERE id >= \(cutoff) AND ease > 0))"
                }
            } else if token.hasPrefix("note:") {
                let name = String(token.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                let mids = notetypes.filter { Self.matchesSearchName($0.name, pattern: name) }.map(\.id)
                if mids.isEmpty {
                    sql += negated ? "" : " AND 0"
                } else {
                    let ph = mids.map { _ in "?" }.joined(separator: ",")
                    sql += "\(andNot) (n.mid IN (\(ph)))"
                }
            } else if token.hasPrefix("preset:") {
                let name = stripSearchQuotes(String(token.dropFirst("preset:".count)))
                let configIDs = deckConfigs.filter { Self.matchesSearchName($0.name, pattern: name) }.map(\.id)
                let deckIDs = decks.filter { configIDs.contains($0.conf) && !$0.isFiltered }.map(\.id)
                if deckIDs.isEmpty {
                    sql += negated ? "" : " AND 0"
                } else {
                    let ph = deckIDs.map { _ in "?" }.joined(separator: ",")
                    sql += "\(andNot) (c.did IN (\(ph)) OR (c.odid != 0 AND c.odid IN (\(ph))))"
                }
            } else if token.hasPrefix("did:") {
                let ids = token.dropFirst(4).split(separator: ",").compactMap { Int64($0) }
                if !ids.isEmpty {
                    let list = ids.map(String.init).joined(separator: ",")
                    sql += "\(andNot) (c.did IN (\(list)) OR c.odid IN (\(list)))"
                }
            } else if token.hasPrefix("mid:") {
                let ids = token.dropFirst(4).split(separator: ",").compactMap { Int64($0) }
                if !ids.isEmpty {
                    sql += "\(andNot) (n.mid IN (\(ids.map(String.init).joined(separator: ","))))"
                }
            } else if token.hasPrefix("nid:") {
                let ids = token.dropFirst(4).split(separator: ",").compactMap { Int64($0) }
                if !ids.isEmpty { sql += "\(andNot) (n.id IN (\(ids.map(String.init).joined(separator: ","))))" }
            } else if token.hasPrefix("cid:") {
                let ids = token.dropFirst(4).split(separator: ",").compactMap { Int64($0) }
                if !ids.isEmpty {
                    sql += "\(andNot) (c.id IN (\(ids.map(String.init).joined(separator: ","))))"
                }
            } else if token.hasPrefix("prop:due") {
                if let (op, n) = Self.parseProp(token, key: "due") {
                    let day = schedDay() + n
                    let cutoff = schedDayStartTimestamp() + 86_400
                    let dueExpr = "(CASE WHEN c.odue != 0 THEN c.odue ELSE c.due END)"
                    sql += "\(andNot) ((c.queue IN (2, 3) AND \(dueExpr) \(op) \(day)) OR (c.queue IN (1, 4) AND ((\(dueExpr) - \(cutoff)) / 86400) \(op) \(n)))"
                }
            } else if token.hasPrefix("card:") {
                let rawName = stripSearchQuotes(String(token.dropFirst(5)))
                let conditions: [String]
                if let number = Int(rawName), number >= 0 {
                    conditions = ["c.ord = \(max(number - 1, 0))"]
                } else {
                    conditions = notetypes.compactMap { notetype in
                        let ords = notetype.tmpls
                            .filter { Self.matchesSearchName($0.name, pattern: rawName) }
                            .map(\.ord)
                        guard !ords.isEmpty else { return nil }
                        return "(n.mid = \(notetype.id) AND c.ord IN (\(Array(Set(ords)).map(String.init).joined(separator: ","))))"
                    }
                }
                if conditions.isEmpty {
                    sql += negated ? "" : " AND 0"
                } else {
                    sql += "\(andNot) (\(conditions.joined(separator: " OR ")))"
                }
            } else if token.hasPrefix("prop:ivl") {
                if let (op, n) = Self.parseProp(token, key: "ivl") {
                    sql += "\(andNot) (c.ivl \(op) \(n))"
                }
            } else if token.hasPrefix("prop:reps") {
                if let (op, n) = Self.parseProp(token, key: "reps") {
                    sql += "\(andNot) (c.reps \(op) \(n))"
                }
            } else if token.hasPrefix("prop:lapses") {
                if let (op, n) = Self.parseProp(token, key: "lapses") {
                    sql += "\(andNot) (c.lapses \(op) \(n))"
                }
            } else if token.hasPrefix("prop:ease") {
                if let (op, n) = Self.parsePropScaled(token, key: "ease", scale: 1000) {
                    sql += "\(andNot) (c.factor \(op) \(n))"
                }
            } else if token.hasPrefix("prop:factor") {
                if let (op, n) = Self.parseProp(token, key: "factor") {
                    sql += "\(andNot) (c.factor \(op) \(n))"
                }
            } else if token.hasPrefix("prop:") {
                continue
            } else if token.hasPrefix("has-cd:") {
                continue
            } else if token.hasPrefix("resched:") {
                let days = Int(token.dropFirst("resched:".count)) ?? 0
                let cutoff = (schedDayStartTimestamp() + 86_400 - Int64(days) * 86_400) * 1000
                sql += "\(andNot) (c.id IN (SELECT cid FROM revlog WHERE id >= \(cutoff) AND ease = 0))"
            } else if token.hasPrefix("introduced:") {
                let days = max(Int(token.dropFirst("introduced:".count)) ?? 1, 1)
                let cutoff = searchDayStart(days: days) * 1000
                sql += "\(andNot) ((SELECT COALESCE(MIN(id) > \(cutoff), 0) FROM revlog WHERE cid = c.id AND ease != 0) AND c.id IN (SELECT cid FROM revlog WHERE id > \(cutoff)))"
            } else if token.hasPrefix("edited:") {
                let days = max(Int(token.dropFirst("edited:".count)) ?? 1, 1)
                let since = searchDayStart(days: days)
                sql += "\(andNot) (n.mod > \(since))"
            } else if token == "dupe:" || token.hasPrefix("dupe:") {
                continue
            } else if token.hasPrefix("tag:") {
                let tag = String(token.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if tag == "*" {
                    if negated { sql += " AND 0" }
                } else if tag == "none" {
                    sql += "\(andNot) (trim(n.tags) = '')"
                } else {
                    sql += "\(andNot) (n.tags LIKE ? ESCAPE '\\' OR n.tags LIKE ? ESCAPE '\\')"
                }
            } else if isNamedFieldSearchToken(token) {
                // Anki `Front:texto` shorthand — LIKE then narrow in applyNamedFieldFilters.
                if !negated {
                    sql += ignoreAccents
                        ? " AND (fold_search_text(n.flds) LIKE fold_search_text(?) ESCAPE '\\')"
                        : " AND (n.flds LIKE ? ESCAPE '\\')"
                }
            } else if !token.isEmpty {
                let term = stripSearchQuotes(token)
                if !term.isEmpty {
                    if !(hasExcludedSearchFields && negated) {
                        if ignoreAccents {
                            sql += "\(andNot) (fold_search_text(n.sfld) LIKE fold_search_text(?) ESCAPE '\\' OR fold_search_text(n.flds) LIKE fold_search_text(?) ESCAPE '\\')"
                        } else {
                            sql += "\(andNot) (n.sfld LIKE ? ESCAPE '\\' OR n.flds LIKE ? ESCAPE '\\')"
                        }
                    }
                }
            }
            _ = notSQL
            _ = binds
        }
        let hasFieldFilter = tokens.contains { token in
            let raw = token.hasPrefix("-") ? String(token.dropFirst()) : token
            let normalized = stripSearchQuotes(raw)
            return normalized.hasPrefix("has-cd:") || normalized.hasPrefix("dupe:")
                || ["prop:s", "prop:d", "prop:r", "prop:rated", "prop:resched", "prop:cdn:", "prop:cds:"].contains(where: normalized.hasPrefix)
                || isNamedFieldSearchToken(normalized) || regexSearchFilter(token) != nil
                || (hasExcludedSearchFields && hasUnqualifiedTextSearch)
        }
        let distinctNotesQuery = notesMode && !hasFieldFilter
        let usesNoteSortOrder = distinctNotesQuery && [13, 14, 15, 16, 17, 18, 19, 23].contains(sortType)
        if distinctNotesQuery {
            sql = sql.replacingOccurrences(
                of: "SELECT c.id FROM cards c JOIN notes n ON n.id = c.nid WHERE 1=1",
                with: "SELECT DISTINCT n.id FROM cards c, notes n WHERE c.nid = n.id"
            )
        }
        if usesNoteSortOrder {
            try db.exec("DROP TABLE IF EXISTS temp.ankios_browser_sort_order; CREATE TEMP TABLE ankios_browser_sort_order(pos INTEGER PRIMARY KEY, key_id INTEGER NOT NULL UNIQUE)")
            if sortType == 23 {
                try db.exec("DROP TABLE IF EXISTS temp.ankios_browser_deck_order; CREATE TEMP TABLE ankios_browser_deck_order(id INTEGER PRIMARY KEY, pos INTEGER NOT NULL)")
                let values = decks.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
                    .enumerated()
                    .map { "(\($0.element.id), \($0.offset + 1))" }
                    .joined(separator: ", ")
                if !values.isEmpty {
                    try db.exec("INSERT INTO ankios_browser_deck_order(id, pos) VALUES \(values)")
                }
            }
            let insertSQL: String
            let today = schedDay()
            let now = Int(Date().timeIntervalSince1970)
            switch sortType {
            case 13:
                insertSQL = "INSERT INTO ankios_browser_sort_order(key_id) SELECT nid FROM cards GROUP BY nid ORDER BY COALESCE(CAST(json_extract(data, '$.pos') AS INTEGER), CASE WHEN type = 0 THEN due ELSE 0 END)"
            case 14:
                insertSQL = "INSERT INTO ankios_browser_sort_order(key_id) SELECT nid FROM cards GROUP BY nid ORDER BY COUNT(*)"
            case 15:
                insertSQL = "INSERT INTO ankios_browser_sort_order(key_id) SELECT nid FROM cards WHERE odid = 0 AND type != 0 AND queue > 0 GROUP BY nid ORDER BY MIN(CASE WHEN due > 1000000000 OR type = 0 THEN due ELSE (due - \(today)) * 86400 + \(now) END)"
            case 16:
                insertSQL = "INSERT INTO ankios_browser_sort_order(key_id) SELECT nid FROM cards WHERE type IN (2, 3) GROUP BY nid ORDER BY AVG(ivl)"
            case 17:
                insertSQL = "INSERT INTO ankios_browser_sort_order(key_id) SELECT nid FROM cards WHERE type != 0 GROUP BY nid ORDER BY AVG(factor)"
            case 18:
                insertSQL = "INSERT INTO ankios_browser_sort_order(key_id) SELECT nid FROM cards GROUP BY nid ORDER BY SUM(reps)"
            case 19:
                insertSQL = "INSERT INTO ankios_browser_sort_order(key_id) SELECT nid FROM cards GROUP BY nid ORDER BY SUM(lapses)"
            default:
                insertSQL = "INSERT INTO ankios_browser_sort_order(key_id) SELECT cards.nid FROM cards JOIN ankios_browser_deck_order decks ON cards.did = decks.id GROUP BY cards.nid ORDER BY COUNT(DISTINCT cards.did), decks.pos"
            }
            try db.exec(insertSQL)
        }
        defer {
            if usesNoteSortOrder {
                try? db.exec("DROP TABLE IF EXISTS temp.ankios_browser_sort_order")
                try? db.exec("DROP TABLE IF EXISTS temp.ankios_browser_deck_order")
            }
        }
        let direction = sortDescending ? "DESC" : "ASC"
        let orderBy: String
        switch sortType {
        case 0: orderBy = notesMode ? "n.sfld COLLATE NOCASE \(direction)" : "n.sfld COLLATE NOCASE \(direction), c.ord \(direction)"
        case 1:
            let today = schedDay()
            let now = Int64(Date().timeIntervalSince1970)
            orderBy = "CASE WHEN c.due > 1000000000 OR c.type = 0 THEN c.due ELSE (c.due - \(today)) * 86400 + \(now) END"
        case 2: orderBy = notesMode ? "n.id \(direction)" : "n.id \(direction), c.ord \(direction)"
        case 3: orderBy = notesMode ? "n.mod \(direction)" : "n.mod \(direction), c.ord \(direction)"
        case 4: orderBy = "c.ivl"
        case 5:
            let cases = decks.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
                .enumerated()
                .map { "WHEN \($0.element.id) THEN \($0.offset + 1)" }
                .joined(separator: " ")
            orderBy = "CASE c.did \(cases) ELSE 0 END \(direction), c.queue ASC, c.due ASC"
        case 6: orderBy = "(c.type = 0) \(direction), c.factor \(direction)"
        case 7: orderBy = "c.reps"
        case 8: orderBy = "c.lapses"
        case 9: orderBy = "c.mod"
        case 10:
            let templates = notetypes.flatMap { notetype in
                notetype.tmpls.map { (notetypeID: notetype.id, order: $0.ord, name: $0.name) }
            }.sorted {
                if $0.name != $1.name { return $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
                if $0.notetypeID != $1.notetypeID { return $0.notetypeID < $1.notetypeID }
                return $0.order < $1.order
            }
            let templatePositions = templates.enumerated()
                .map { "WHEN n.mid = \($0.element.notetypeID) AND c.ord = \($0.element.order) THEN \($0.offset + 1)" }
                .joined(separator: " ")
            let firstTemplatePositions = templates.enumerated().filter { $0.element.order == 0 }
                .map { "WHEN n.mid = \($0.element.notetypeID) THEN \($0.offset + 1)" }
                .joined(separator: " ")
            orderBy = "COALESCE((CASE \(templatePositions) END), (CASE \(firstTemplatePositions) END)) \(direction), c.ord \(direction)"
        case 11:
            let cases = notetypes.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
                .enumerated()
                .map { "WHEN \($0.element.id) THEN \($0.offset + 1)" }
                .joined(separator: " ")
            orderBy = "CASE n.mid \(cases) ELSE 0 END"
        case 12: orderBy = "n.tags"
        case 13:
            orderBy = usesNoteSortOrder
                ? "(SELECT pos FROM ankios_browser_sort_order WHERE key_id = n.id)"
                : "(SELECT COALESCE(CAST(json_extract(oc.data, '$.pos') AS INTEGER), CASE WHEN oc.type = 0 THEN oc.due ELSE 0 END) FROM cards oc WHERE oc.nid = c.nid ORDER BY oc.id LIMIT 1)"
        case 14: orderBy = usesNoteSortOrder ? "(SELECT pos FROM ankios_browser_sort_order WHERE key_id = n.id)" : "(SELECT COUNT(*) FROM cards cc WHERE cc.nid = n.id)"
        case 15:
            if usesNoteSortOrder { orderBy = "(SELECT pos FROM ankios_browser_sort_order WHERE key_id = n.id)" }
            else {
                let today = schedDay()
                let now = Int(Date().timeIntervalSince1970)
                orderBy = "(SELECT MIN(CASE WHEN cc.due > 1000000000 OR cc.type = 0 THEN cc.due ELSE (cc.due - \(today)) * 86400 + \(now) END) FROM cards cc WHERE cc.nid = n.id AND cc.odid = 0 AND cc.type != 0 AND cc.queue > 0)"
            }
        case 16, 17, 18, 19:
            if usesNoteSortOrder {
                orderBy = "(SELECT pos FROM ankios_browser_sort_order WHERE key_id = n.id)"
            } else if sortType == 16 {
                orderBy = "(SELECT AVG(CASE WHEN cc.type IN (2, 3) THEN cc.ivl END) FROM cards cc WHERE cc.nid = n.id)"
            } else if sortType == 17 {
                orderBy = "(SELECT AVG(CASE WHEN cc.type != 0 THEN cc.factor END) FROM cards cc WHERE cc.nid = n.id)"
            } else if sortType == 18 {
                orderBy = "(SELECT SUM(cc.reps) FROM cards cc WHERE cc.nid = n.id)"
            } else {
                orderBy = "(SELECT SUM(cc.lapses) FROM cards cc WHERE cc.nid = n.id)"
            }
        case 20: orderBy = "anki_fsrs_stability(c.data)"
        case 21: orderBy = "anki_fsrs_difficulty(c.data)"
        case 22:
            let today = schedDay()
            let now = Int(Date().timeIntervalSince1970)
            orderBy = "anki_fsrs_retrievability(c.data, CASE WHEN c.odue != 0 THEN c.odue ELSE c.due END, c.ivl, \(today), \(now))"
        case 23:
            if usesNoteSortOrder {
                orderBy = "(SELECT pos FROM ankios_browser_sort_order WHERE key_id = n.id)"
            } else {
                let deckRanks = decks.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
                    .enumerated()
                    .map { "WHEN cc.did = \($0.element.id) THEN \($0.offset + 1)" }
                    .joined(separator: " ")
                orderBy = "(SELECT COUNT(DISTINCT cc.did) FROM cards cc WHERE cc.nid = n.id) \(direction), (SELECT CASE \(deckRanks) ELSE 0 END FROM cards cc WHERE cc.nid = n.id ORDER BY cc.id LIMIT 1) \(direction)"
            }
        default: orderBy = "n.sfld COLLATE NOCASE \(direction), c.ord \(direction)"
        }
        let directionAlreadyApplied = [0, 2, 3, 5, 6, 10].contains(sortType)
        let tieOrder: String
        if distinctNotesQuery && [15, 16].contains(sortType) {
            tieOrder = "CASE WHEN \(orderBy) IS NULL THEN (SELECT COUNT(*) FROM cards cc WHERE cc.nid = n.id) END ASC, CASE WHEN \(orderBy) IS NULL THEN n.id END ASC"
        } else if distinctNotesQuery {
            tieOrder = ""
        } else if sortType == 13 {
            tieOrder = "n.id \(direction), c.id ASC"
        } else if notesMode && [15, 16, 17].contains(sortType) {
            tieOrder = "CASE WHEN \(orderBy) IS NULL THEN n.id END ASC, CASE WHEN \(orderBy) IS NOT NULL THEN n.id END \(direction), c.id ASC"
        } else if notesMode && [14, 18, 19, 23].contains(sortType) {
            tieOrder = "n.id \(direction), c.id ASC"
        } else if notesMode {
            tieOrder = "n.id ASC, c.id ASC"
        } else {
            tieOrder = "c.id ASC"
        }
        sql += " ORDER BY \(orderBy)\(directionAlreadyApplied ? "" : " \(direction)")\(tieOrder.isEmpty ? "" : ", \(tieOrder)")"
        if !hasFieldFilter {
            sql += " LIMIT \(max(limit, 1)) OFFSET \(max(offset, 0))"
        }
        // Rebuild with proper binding
        var cardIDs: [Int64] = []
        try db.query(sql, bind: { stmt in
            var idx: Int32 = 1
            for rawToken in tokens {
                if rawToken.caseInsensitiveCompare("AND") == .orderedSame { continue }
                if self.regexSearchFilter(rawToken) != nil { continue }
                let negated = rawToken.hasPrefix("-")
                let token = self.stripSearchQuotes(negated ? String(rawToken.dropFirst()) : rawToken)
                if token.hasPrefix("deck:") {
                    if token == "deck:filtered" { continue }
                    let parsed = self.parseDeckSearchToken(token)
                    if parsed.name != "current" {
                        let matching = self.deckIDs(matchingSearchName: parsed.name, exact: parsed.exact)
                        for _ in 0..<2 {
                            for id in matching {
                                SQLiteDatabase.bindInt64(stmt, idx, id)
                                idx += 1
                            }
                        }
                    }
                } else if token.hasPrefix("tag:") {
                    let tag = String(token.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if tag != "*" && tag != "none" {
                        let wildcard = Self.sqlSearchPattern(tag, contains: false)
                        try SQLiteDatabase.bindText(stmt, idx, "% \(wildcard) %")
                        idx += 1
                        try SQLiteDatabase.bindText(stmt, idx, "% \(wildcard)::%")
                        idx += 1
                    }
                } else if token.hasPrefix("note:") {
                    let name = String(token.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    let mids = self.notetypes.filter { Self.matchesSearchName($0.name, pattern: name) }.map(\.id)
                    for mid in mids {
                        SQLiteDatabase.bindInt64(stmt, idx, mid)
                        idx += 1
                    }
                } else if token.hasPrefix("preset:") {
                    let name = self.stripSearchQuotes(String(token.dropFirst("preset:".count)))
                    let configIDs = self.deckConfigs.filter { Self.matchesSearchName($0.name, pattern: name) }.map(\.id)
                    let deckIDs = self.decks.filter { configIDs.contains($0.conf) && !$0.isFiltered }.map(\.id)
                    for _ in 0..<2 {
                        for id in deckIDs {
                            SQLiteDatabase.bindInt64(stmt, idx, id)
                            idx += 1
                        }
                    }
                } else if self.isNamedFieldSearchToken(token) {
                    if negated { continue }
                    let value = self.namedFieldSearchValue(token)
                    let pattern = Self.sqlSearchPattern(value, contains: false)
                    try SQLiteDatabase.bindText(stmt, idx, "%\(pattern)%")
                    idx += 1
                } else if token.hasPrefix("flag:") || token.hasPrefix("is:") || token.hasPrefix("added:") || token.hasPrefix("rated:") || token.hasPrefix("resched:") || token.hasPrefix("introduced:") || token.hasPrefix("edited:") || token.hasPrefix("dupe:") || token.hasPrefix("did:") || token.hasPrefix("mid:") || token.hasPrefix("nid:") || token.hasPrefix("cid:") || token.hasPrefix("prop:") || token.hasPrefix("has-cd:") || token.hasPrefix("card:") || token.hasPrefix("preset:") || token == "deck:filtered" || token.isEmpty {
                    continue
                } else {
                    if hasExcludedSearchFields && negated { continue }
                    let term = self.stripSearchQuotes(token)
                    guard !term.isEmpty else { continue }
                    let q = Self.sqlSearchPattern(term, contains: true)
                    try SQLiteDatabase.bindText(stmt, idx, q); idx += 1
                    try SQLiteDatabase.bindText(stmt, idx, q); idx += 1
                }
            }
        }) { stmt in
            cardIDs.append(sqlite3_column_int64(stmt, 0))
        }

        if distinctNotesQuery {
            let noteIDs = cardIDs
            var representativeCards: [Int64: Int64] = [:]
            for batchStart in stride(from: 0, to: noteIDs.count, by: 900) {
                let batch = Array(noteIDs[batchStart..<min(batchStart + 900, noteIDs.count)])
                let placeholders = batch.map { _ in "?" }.joined(separator: ",")
                try db.query("SELECT nid, MIN(id) FROM cards WHERE nid IN (\(placeholders)) GROUP BY nid", bind: { stmt in
                    for (index, noteID) in batch.enumerated() {
                        SQLiteDatabase.bindInt64(stmt, Int32(index + 1), noteID)
                    }
                }) { stmt in
                    representativeCards[sqlite3_column_int64(stmt, 0)] = sqlite3_column_int64(stmt, 1)
                }
            }
            cardIDs = noteIDs.compactMap { representativeCards[$0] }
        }

        var rows: [BrowserRow] = []
        for cid in cardIDs {
            guard let card = try fetchCard(id: cid),
                  let note = try fetchNote(id: card.nid) else { continue }
            let deckName = deck(id: card.did)?.name ?? "?"
            let originalDeckName = card.odid == 0 ? nil : deck(id: card.odid)?.name
            let ntName = notetype(id: note.mid)?.name ?? "?"
            rows.append(BrowserRow(card: card, note: note, deckName: deckName, originalDeckName: originalDeckName, notetypeName: ntName))
        }
        let noteIDs = Array(Set(rows.map { $0.note.id }))
        var cardCounts: [Int64: Int] = [:]
        var latestCardMods: [Int64: Int64] = [:]
        var deckCounts: [Int64: Int] = [:]
        var averageEases: [Int64: Double] = [:]
        var averageIntervals: [Int64: Double] = [:]
        var totalReps: [Int64: Int] = [:]
        var totalLapses: [Int64: Int] = [:]
        var nextDueTimestamps: [Int64: Int64] = [:]
        let dueEpochBase = schedDayStartTimestamp() - Int64(schedDay()) * 86_400
        for batchStart in stride(from: 0, to: noteIDs.count, by: 900) {
            let batch = Array(noteIDs[batchStart..<min(batchStart + 900, noteIDs.count)])
            let placeholders = batch.map { _ in "?" }.joined(separator: ",")
            try db.query("""
            SELECT nid, COUNT(*), MAX(mod), COUNT(DISTINCT did),
                   AVG(CASE WHEN type != 0 THEN factor END),
                   AVG(CASE WHEN type IN (2, 3) THEN ivl END), SUM(reps), SUM(lapses)
                   , MIN(CASE WHEN odid = 0 AND type != 0 AND queue IN (1, 4) THEN due WHEN odid = 0 AND type != 0 AND queue IN (2, 3) THEN due * 86400 + \(dueEpochBase) END)
            FROM cards WHERE nid IN (\(placeholders)) GROUP BY nid
            """, bind: { stmt in
                for (index, nid) in batch.enumerated() {
                    SQLiteDatabase.bindInt64(stmt, Int32(index + 1), nid)
                }
            }) { stmt in
                let nid = sqlite3_column_int64(stmt, 0)
                cardCounts[nid] = Int(sqlite3_column_int(stmt, 1))
                latestCardMods[nid] = sqlite3_column_int64(stmt, 2)
                deckCounts[nid] = Int(sqlite3_column_int(stmt, 3))
                if sqlite3_column_type(stmt, 4) != SQLITE_NULL { averageEases[nid] = sqlite3_column_double(stmt, 4) }
                if sqlite3_column_type(stmt, 5) != SQLITE_NULL { averageIntervals[nid] = sqlite3_column_double(stmt, 5) }
                totalReps[nid] = Int(sqlite3_column_int(stmt, 6))
                totalLapses[nid] = Int(sqlite3_column_int(stmt, 7))
                if sqlite3_column_type(stmt, 8) != SQLITE_NULL { nextDueTimestamps[nid] = sqlite3_column_int64(stmt, 8) }
            }
        }
        for index in rows.indices {
            rows[index].cardCount = cardCounts[rows[index].note.id] ?? 0
            rows[index].latestCardMod = latestCardMods[rows[index].note.id] ?? 0
            rows[index].deckCount = deckCounts[rows[index].note.id] ?? 0
            rows[index].averageEase = averageEases[rows[index].note.id]
            rows[index].averageInterval = averageIntervals[rows[index].note.id]
            rows[index].totalReps = totalReps[rows[index].note.id] ?? 0
            rows[index].totalLapses = totalLapses[rows[index].note.id] ?? 0
            rows[index].nextDueTimestamp = nextDueTimestamps[rows[index].note.id]
        }
        let fieldFiltered = applyNamedFieldFilters(rows, tokens: tokens)
        let regexFiltered = try applyRegexSearchFilters(fieldFiltered, tokens: tokens)
        let textFiltered = applyExcludedFieldFilters(regexFiltered, tokens: tokens, enabled: hasExcludedSearchFields)
        let advancedFiltered = try applyAdvancedSearchFilters(textFiltered, tokens: tokens)
        return hasFieldFilter ? Array(advancedFiltered.dropFirst(max(offset, 0)).prefix(max(limit, 1))) : advancedFiltered
    }

    private static let reservedSearchPrefixes: Set<String> = [
        "deck", "preset", "tag", "note", "card", "flag", "is", "prop", "added", "edited", "rated", "resched", "introduced", "did", "mid", "nid", "cid", "re", "w", "nc", "sc", "dupe", "has-cd"
    ]

    private func isNamedFieldSearchToken(_ token: String) -> Bool {
        guard let parts = Self.searchFieldParts(token) else { return false }
        let name = parts.name
        guard !name.isEmpty, !Self.reservedSearchPrefixes.contains(name.lowercased()) else { return false }
        return true
    }

    private static func searchFieldParts(_ token: String) -> (name: String, value: String)? {
        var escaped = false
        for index in token.indices {
            let character = token[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == ":" {
                return (String(token[..<index]), String(token[token.index(after: index)...]))
            }
        }
        return nil
    }

    private func isUnqualifiedTextSearchToken(_ rawToken: String) -> Bool {
        let negated = rawToken.hasPrefix("-")
        let token = stripSearchQuotes(negated ? String(rawToken.dropFirst()) : rawToken)
        guard !token.isEmpty, token.caseInsensitiveCompare("AND") != .orderedSame,
              regexSearchFilter(rawToken) == nil, !isNamedFieldSearchToken(token) else { return false }
        let prefixes = [
            "deck:", "note:", "preset:", "card:", "flag:", "is:", "prop:", "added:", "rated:",
            "introduced:", "edited:", "resched:", "dupe:", "did:", "mid:", "nid:", "cid:", "tag:", "has-cd:"
        ]
        return !prefixes.contains(where: token.hasPrefix)
    }

    private func searchableFieldIndexes(in notetype: AnkiNotetype, fieldCount: Int) -> [Int] {
        notetype.flds.indices.filter { index in
            index < fieldCount && !notetype.flds[index].excludeFromSearch
        }
    }

    private func applyExcludedFieldFilters(_ rows: [BrowserRow], tokens: [String], enabled: Bool) -> [BrowserRow] {
        guard enabled else { return rows }
        let ignoreAccents = conf["ignoreAccentsInSearch"] as? Bool ?? false
        var result = rows
        for rawToken in tokens where isUnqualifiedTextSearchToken(rawToken) {
            let negated = rawToken.hasPrefix("-")
            let term = stripSearchQuotes(negated ? String(rawToken.dropFirst()) : rawToken)
            guard !term.isEmpty else { continue }
            let searchText = ignoreAccents ? Self.foldSearchText(term) : term
            let wildcard = Self.searchWildcardPattern(searchText)
            let expression = ".*\(wildcard.regex).*"
            result = result.filter { row in
                guard let notetype = notetype(id: row.note.mid) else { return negated }
                let indexes = searchableFieldIndexes(in: notetype, fieldCount: row.note.fields.count)
                let hit = indexes.contains { index in
                    let fieldValue = row.note.fields[index]
                        .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                        .replacingOccurrences(of: "&nbsp;", with: " ")
                        .replacingOccurrences(of: "&amp;", with: "&")
                        .replacingOccurrences(of: "&lt;", with: "<")
                        .replacingOccurrences(of: "&gt;", with: ">")
                    let value = ignoreAccents ? Self.foldSearchText(fieldValue) : fieldValue
                    return value.range(of: expression, options: [.regularExpression, .caseInsensitive]) != nil
                }
                return negated ? !hit : hit
            }
        }
        return result
    }

    private func fieldIndexes(matching name: String, in notetype: AnkiNotetype) -> [Int] {
        let pattern = Self.searchWildcardPattern(name)
        return notetype.flds.indices.filter { index in
            let fieldName = notetype.flds[index].name
            if pattern.hasWildcard {
                return fieldName.range(
                    of: "^\(pattern.regex)$",
                    options: [.regularExpression, .caseInsensitive]
                ) != nil
            }
            return fieldName.compare(pattern.literal, options: .caseInsensitive) == .orderedSame
        }
    }

    private func namedFieldSearchValue(_ token: String) -> String {
        guard let parts = Self.searchFieldParts(token) else { return token }
        return stripSearchQuotes(parts.value)
    }

    private static func searchWildcardPattern(_ value: String) -> (literal: String, regex: String, hasWildcard: Bool) {
        var literal = ""
        var regex = ""
        var escaped = false
        var hasWildcard = false
        for character in value {
            if escaped {
                literal.append(character)
                regex += NSRegularExpression.escapedPattern(for: String(character))
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "*" {
                literal.append(character)
                regex += ".*"
                hasWildcard = true
            } else if character == "_" {
                literal.append(character)
                regex += "."
                hasWildcard = true
            } else {
                literal.append(character)
                regex += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        if escaped {
            literal.append("\\")
            regex += NSRegularExpression.escapedPattern(for: "\\")
        }
        return (literal, regex, hasWildcard)
    }

    private static func sqlSearchPattern(_ value: String, contains: Bool) -> String {
        var pattern = contains ? "%" : ""
        var escaped = false
        for character in value {
            if escaped {
                if character == "%" || character == "_" || character == "\\" { pattern.append("\\") }
                pattern.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "*" {
                pattern.append("%")
            } else if character == "_" {
                pattern.append("_")
            } else {
                if character == "%" || character == "\\" { pattern.append("\\") }
                pattern.append(character)
            }
        }
        if escaped { pattern += "\\\\" }
        if contains { pattern.append("%") }
        return pattern
    }

    private func applyNamedFieldFilters(_ rows: [BrowserRow], tokens: [String]) -> [BrowserRow] {
        var result = rows
        for rawToken in tokens {
            let negated = rawToken.hasPrefix("-")
            let token = stripSearchQuotes(negated ? String(rawToken.dropFirst()) : rawToken)
            let fieldName: String
            let value: String
            guard isNamedFieldSearchToken(token), let parts = Self.searchFieldParts(token) else { continue }
            fieldName = parts.name
            value = stripSearchQuotes(parts.value)
            guard !fieldName.isEmpty else { continue }
            if value.hasPrefix("re:") { continue }
            result = result.filter { row in
                guard let nt = notetype(id: row.note.mid) else {
                    return negated
                }
                let indexes = self.fieldIndexes(matching: fieldName, in: nt).filter(row.note.fields.indices.contains)
                guard !indexes.isEmpty else { return negated }
                let searchPattern = Self.searchWildcardPattern(value)
                let pattern = Self.searchASCIILowercased(searchPattern.regex)
                let normalizedSearchValue = Self.searchASCIILowercased(searchPattern.literal)
                let hit = indexes.contains { index in
                    let normalizedFieldValue = Self.searchASCIILowercased(row.note.fields[index])
                    if normalizedSearchValue.isEmpty { return normalizedFieldValue.isEmpty }
                    if searchPattern.hasWildcard {
                        return normalizedFieldValue.range(of: "^\(pattern)$", options: [.regularExpression]) != nil
                    }
                    return normalizedFieldValue.utf8.elementsEqual(normalizedSearchValue.utf8)
                }
                return negated ? !hit : hit
            }
        }
        return result
    }

    private static func searchASCIILowercased(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.map { scalar in
            (65...90).contains(scalar.value) ? UnicodeScalar(scalar.value + 32)! : scalar
        }))
    }

    private func regexSearchFilter(_ rawToken: String) -> (negated: Bool, kind: String, field: String?, pattern: String)? {
        let negated = rawToken.hasPrefix("-")
        let token = negated ? String(rawToken.dropFirst()) : rawToken
        let unquoted = stripSearchQuotes(token)
        if unquoted.hasPrefix("tag:nc:") {
            return (negated, "tagNoCombining", nil, String(unquoted.dropFirst("tag:nc:".count)))
        }
        if unquoted.hasPrefix("w:") {
            let raw = String(unquoted.dropFirst(2))
            let hasLeadingWildcard = raw.hasPrefix("*")
            let hasTrailingWildcard = raw.hasSuffix("*")
            let body = raw.drop(while: { $0 == "*" }).reversed().drop(while: { $0 == "*" }).reversed()
            let pattern = body.map { character -> String in
                if character == "*" { return ".*" }
                if character == "_" { return "." }
                return NSRegularExpression.escapedPattern(for: String(character))
            }.joined()
            let left = hasLeadingWildcard ? "" : "(?:^|[^\\p{L}\\p{N}_])"
            let right = hasTrailingWildcard ? "" : "(?:$|[^\\p{L}\\p{N}_])"
            return (negated, "word", nil, left + pattern + right)
        }
        if unquoted.hasPrefix("nc:") {
            return (negated, "noCombining", nil, String(unquoted.dropFirst(3)))
        }
        if unquoted.hasPrefix("sc:") {
            return (negated, "stripClozes", nil, String(unquoted.dropFirst(3)))
        }
        if unquoted.hasPrefix("re:") {
            return (negated, "note", nil, String(unquoted.dropFirst(3)))
        }
        if unquoted.hasPrefix("tag:re:") {
            return (negated, "tag", nil, String(unquoted.dropFirst(7)))
        }
        if isNamedFieldSearchToken(unquoted) {
            let value = namedFieldSearchValue(unquoted)
            guard value.hasPrefix("re:") else { return nil }
            guard let parts = Self.searchFieldParts(unquoted) else { return nil }
            return (negated, "field", parts.name, String(value.dropFirst(3)))
        }
        return nil
    }

    private func applyRegexSearchFilters(_ rows: [BrowserRow], tokens: [String]) throws -> [BrowserRow] {
        var result = rows
        for rawToken in tokens {
            guard let filter = regexSearchFilter(rawToken) else { continue }
            let regex = filter.kind == "noCombining" || filter.kind == "stripClozes" || filter.kind == "tagNoCombining"
                ? nil
                : try NSRegularExpression(pattern: filter.pattern, options: [.caseInsensitive])
            result = result.filter { row in
                if filter.kind == "stripClozes", notetype(id: row.note.mid)?.isCloze != true {
                    return filter.negated
                }
                let values: [String]
                switch filter.kind {
                case "tag", "tagNoCombining": values = row.note.tagList
                case "field":
                    guard let field = filter.field,
                          let noteType = notetype(id: row.note.mid) else { return filter.negated }
                    let indexes = fieldIndexes(matching: field, in: noteType).filter(row.note.fields.indices.contains)
                    guard !indexes.isEmpty else { return filter.negated }
                    values = indexes.map { row.note.fields[$0] }
                default:
                    guard let noteType = notetype(id: row.note.mid) else { return filter.negated }
                    let indexes = searchableFieldIndexes(in: noteType, fieldCount: row.note.fields.count)
                    values = indexes.map { row.note.fields[$0].replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression) }
                }
                let hit = values.contains { value in
                    if filter.kind == "tagNoCombining" {
                        let normalizedValue = Self.stripCombiningMarks(value).lowercased()
                            .replacingOccurrences(of: "ß", with: "s")
                        let rawPattern = Self.stripCombiningMarks(filter.pattern).lowercased()
                            .replacingOccurrences(of: "ß", with: "s")
                        let searchPattern = Self.searchWildcardPattern(rawPattern)
                        if searchPattern.hasWildcard {
                            return normalizedValue.range(
                                of: "^\(searchPattern.regex)(?:::.*)?$",
                                options: .regularExpression
                            ) != nil
                        }
                        return normalizedValue == searchPattern.literal
                            || normalizedValue.hasPrefix(searchPattern.literal + "::")
                    }
                    if filter.kind == "noCombining" {
                        let folded = Self.stripCombiningMarks(value).lowercased()
                            .replacingOccurrences(of: "ß", with: "s")
                        let pattern = Self.stripCombiningMarks(filter.pattern).lowercased()
                            .replacingOccurrences(of: "ß", with: "s")
                            .map { character -> String in
                            if character == "*" { return ".*" }
                            if character == "_" { return "." }
                            return NSRegularExpression.escapedPattern(for: String(character))
                            }.joined()
                        return folded.range(of: pattern, options: .regularExpression) != nil
                    }
                    if filter.kind == "stripClozes" {
                        let text = Self.stripClozes(value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression))
                        let pattern = filter.pattern.map { character -> String in
                            if character == "*" { return ".*" }
                            if character == "_" { return "." }
                            return NSRegularExpression.escapedPattern(for: String(character))
                        }.joined()
                        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
                    }
                    return regex?.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
                }
                return filter.negated ? !hit : hit
            }
        }
        return result
    }

    private static func stripCombiningMarks(_ value: String) -> String {
        String(value.decomposedStringWithCanonicalMapping.unicodeScalars.filter {
            !CharacterSet.nonBaseCharacters.contains($0)
        })
    }

    private static func foldSearchText(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func stripClozes(_ value: String) -> String {
        let characters = Array(value)
        func matches(_ pattern: String, at index: Int) -> Bool {
            let expected = Array(pattern)
            guard index + expected.count <= characters.count else { return false }
            return expected.indices.allSatisfy { characters[index + $0] == expected[$0] }
        }
        func clozeEnd(from index: Int) -> Int? {
            guard matches("{{c", at: index) else { return nil }
            var cursor = index + 3
            let digitStart = cursor
            while cursor < characters.count, characters[cursor].isNumber { cursor += 1 }
            guard cursor > digitStart, matches("::", at: cursor) else { return nil }
            return cursor + 2
        }
        func parse(_ start: Int, inCloze: Bool) -> (text: String, next: Int) {
            var output = ""
            var cursor = start
            var skippingHint = false
            while cursor < characters.count {
                if inCloze, matches("}}", at: cursor) {
                    return (output, cursor + 2)
                }
                if let contentStart = clozeEnd(from: cursor) {
                    let nested = parse(contentStart, inCloze: true)
                    if !skippingHint { output += nested.text }
                    cursor = nested.next
                    continue
                }
                if inCloze, !skippingHint, matches("::", at: cursor) {
                    skippingHint = true
                    cursor += 2
                    continue
                }
                if !skippingHint { output.append(characters[cursor]) }
                cursor += 1
            }
            return (output, cursor)
        }
        return parse(0, inCloze: false).text
    }

    private func applyAdvancedSearchFilters(_ rows: [BrowserRow], tokens: [String]) throws -> [BrowserRow] {
        var result = rows
        for rawToken in tokens {
            let negated = rawToken.hasPrefix("-")
            let token = stripSearchQuotes(negated ? String(rawToken.dropFirst()) : rawToken)
            if token.hasPrefix("prop:s"), let (operation, value) = Self.parseDecimalProp(token, key: "s") {
                result = result.filter { row in
                    let actual = FSRSCardData.memory(in: row.card.data).map { Double($0.stability) }
                    return Self.matchesNumeric(actual, operation: operation, value: value, negated: negated)
                }
            } else if token.hasPrefix("prop:d"), let (operation, value) = Self.parseDecimalProp(token, key: "d") {
                result = result.filter { row in
                    let actual = FSRSCardData.memory(in: row.card.data).map { Double($0.difficulty) }
                    return Self.matchesNumeric(actual, operation: operation, value: value * 9 + 1, negated: negated)
                }
            } else if token.hasPrefix("prop:r"), !token.hasPrefix("prop:rated"),
                      let (operation, value) = Self.parseDecimalProp(token, key: "r") {
                let now = Int(Date().timeIntervalSince1970)
                let today = schedDay()
                result = result.filter { row in
                    guard let actual = Self.reviewRetrievability(row.card, today: today, now: now) else { return false }
                    return Self.matchesNumeric(Double(actual), operation: operation, value: value, negated: negated)
                }
            } else if token.hasPrefix("has-cd:") {
                let key = String(token.dropFirst("has-cd:".count))
                result = result.filter { row in
                    let custom = Self.cardCustomDataObject(row.card.data)
                    return negated ? custom[key] == nil : custom[key] != nil
                }
            } else if token.hasPrefix("dupe:"), let duplicate = Self.parseDuplicateSearch(token) {
                let expectedValue = stripHTMLPreservingMediaFilenames(normalizeNoteText(duplicate.text))
                let duplicateNoteIDs = try noteIDsWithDuplicateField(
                    notetypeID: duplicate.notetypeID,
                    value: expectedValue
                )
                result = result.filter { duplicateNoteIDs.contains($0.note.id) != negated }
            } else if token.hasPrefix("prop:cdn:") {
                let raw = String(token.dropFirst("prop:cdn:".count))
                guard let comparison = Self.parseDecimalComparison(raw) else { continue }
                result = result.filter { row in
                    let custom = Self.cardCustomDataObject(row.card.data)
                    let actual = Self.numericValue(custom[comparison.key])
                    return Self.matchesNumeric(actual, operation: comparison.operation, value: comparison.value, negated: negated)
                }
            } else if token.hasPrefix("prop:cds:") {
                let raw = String(token.dropFirst("prop:cds:".count))
                guard let comparison = Self.parseStringComparison(raw) else { continue }
                result = result.filter { row in
                    let custom = Self.cardCustomDataObject(row.card.data)
                    guard let actual = custom[comparison.key] as? String else { return false }
                    let matches: Bool
                    switch comparison.operation {
                    case "=": matches = actual == comparison.value
                    case "!=": matches = actual != comparison.value
                    case "<": matches = actual.utf8.lexicographicallyPrecedes(comparison.value.utf8)
                    case ">": matches = comparison.value.utf8.lexicographicallyPrecedes(actual.utf8)
                    case "<=": matches = actual == comparison.value || actual.utf8.lexicographicallyPrecedes(comparison.value.utf8)
                    case ">=": matches = actual == comparison.value || comparison.value.utf8.lexicographicallyPrecedes(actual.utf8)
                    default: return false
                    }
                    return negated ? !matches : matches
                }
            } else if token.hasPrefix("prop:rated"),
                      let rating = Self.parseRatingProperty(token, key: "rated") {
                result = result.filter { row in
                    let found = cardHasMatchingRating(
                        cardID: row.id,
                        daysOffset: rating.days,
                        operation: rating.operation,
                        ease: rating.ease
                    )
                    return negated ? !found : found
                }
            } else if token.hasPrefix("prop:resched"),
                      let reschedule = Self.parseRatingProperty(token, key: "resched") {
                result = result.filter { row in
                    let found = cardHasMatchingRating(
                        cardID: row.id,
                        daysOffset: reschedule.days,
                        operation: reschedule.operation,
                        ease: 0
                    )
                    return negated ? !found : found
                }
            }
        }
        return result
    }

    private static func parseRatingProperty(
        _ token: String,
        key: String
    ) -> (operation: String, days: Int, ease: Int?)? {
        let prefix = "prop:\(key)"
        guard token.hasPrefix(prefix) else { return nil }
        let remainder = String(token.dropFirst(prefix.count))
        let operatorText = ["<=", ">=", "!=", "=", "<", ">"].first { remainder.hasPrefix($0) }
        guard let operatorText else { return nil }
        let value = String(remainder.dropFirst(operatorText.count))
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let days = Int(parts[0]), days <= 0, Int32(exactly: days) != nil else { return nil }
        if key == "resched" {
            guard parts.count == 1 else { return nil }
            return (operatorText, days, 0)
        }
        guard parts.count == 1 || parts.count == 2 else { return nil }
        if parts.count == 1 { return (operatorText, days, nil) }
        guard let ease = Int(parts[1]), (1...4).contains(ease) else { return nil }
        return (operatorText, days, ease)
    }

    private static func parseDuplicateSearch(_ token: String) -> (notetypeID: Int64, text: String)? {
        guard token.hasPrefix("dupe:"),
              let comma = token.firstIndex(of: ","),
              let notetypeID = Int64(token[token.index(token.startIndex, offsetBy: 5)..<comma]) else { return nil }
        var text = stripSearchTokenQuotes(String(token[token.index(after: comma)...]))
        text = text.replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
        return (notetypeID, text)
    }

    private static func stripSearchTokenQuotes(_ token: String) -> String {
        guard token.hasPrefix("\""), token.hasSuffix("\""), token.count >= 2 else { return token }
        return String(token.dropFirst().dropLast())
    }

    private static func validCustomDataProperty(_ token: String) -> Bool {
        if token.hasPrefix("prop:cdn:") {
            let raw = String(token.dropFirst("prop:cdn:".count))
            return parseDecimalComparison(raw).map { !$0.key.isEmpty } ?? false
        }
        if token.hasPrefix("prop:cds:") {
            return parseStringComparison(String(token.dropFirst("prop:cds:".count))) != nil
        }
        return false
    }

    private static func parseStringComparison(_ raw: String) -> (key: String, operation: String, value: String)? {
        for operation in [">=", "<=", "!=", "=", ">", "<"] {
            guard let range = raw.range(of: operation) else { continue }
            let key = String(raw[..<range.lowerBound])
            guard !key.isEmpty else { return nil }
            return (key, operation, String(raw[range.upperBound...]))
        }
        return nil
    }

    private func cardHasMatchingRating(
        cardID: Int64,
        daysOffset: Int,
        operation: String,
        ease: Int?
    ) -> Bool {
        let nextDay = schedDayStartTimestamp() + 86_400
        let start = (nextDay + Int64(daysOffset - 1) * 86_400) * 1000
        let end = (nextDay + Int64(daysOffset) * 86_400) * 1000
        let timeCondition: String
        switch operation {
        case ">": timeCondition = "id >= ?"
        case ">=": timeCondition = "id >= ?"
        case "<": timeCondition = "id < ?"
        case "<=": timeCondition = "id < ?"
        case "=": timeCondition = "id >= ? AND id < ?"
        case "!=": timeCondition = "(id < ? OR id >= ?)"
        default: return false
        }
        let easeCondition = ease == nil ? "ease > 0" : "ease = ?"
        let sql = "SELECT EXISTS(SELECT 1 FROM revlog WHERE cid = ? AND \(easeCondition) AND \(timeCondition))"
        return (try? db.scalarInt(sql, bind: { statement in
            SQLiteDatabase.bindInt64(statement, 1, cardID)
            var index: Int32 = 2
            if let ease {
                SQLiteDatabase.bindInt(statement, index, ease)
                index += 1
            }
            switch operation {
            case ">": SQLiteDatabase.bindInt64(statement, index, end)
            case ">=", "<": SQLiteDatabase.bindInt64(statement, index, start)
            case "<=": SQLiteDatabase.bindInt64(statement, index, end)
            case "=", "!=":
                SQLiteDatabase.bindInt64(statement, index, start)
                SQLiteDatabase.bindInt64(statement, index + 1, end)
            default: break
            }
        })) == 1
    }

    private static func parseDecimalProp(_ token: String, key: String) -> (operation: String, value: Double)? {
        guard token.hasPrefix("prop:\(key)"), token.count > "prop:\(key)".count else { return nil }
        guard let comparison = parseDecimalComparison(String(token.dropFirst("prop:\(key)".count))) else { return nil }
        guard comparison.key.isEmpty else { return nil }
        return (comparison.operation, comparison.value)
    }

    private func noteIDsWithDuplicateField(notetypeID: Int64, value: String) throws -> Set<Int64> {
        var noteIDs = Set<Int64>()
        try db.query(
            "SELECT id, flds FROM notes WHERE mid = ?",
            bind: { SQLiteDatabase.bindInt64($0, 1, notetypeID) }
        ) { stmt in
            let fields = SQLiteDatabase.text(stmt, 1).components(separatedBy: "\u{1f}")
            guard fields.contains(where: {
                stripHTMLPreservingMediaFilenames(normalizeNoteText($0)) == value
            }) else { return }
            noteIDs.insert(sqlite3_column_int64(stmt, 0))
        }
        return noteIDs.count > 1 ? noteIDs : []
    }

    private static func parseDecimalComparison(_ raw: String) -> (key: String, operation: String, value: Double)? {
        for operation in [">=", "<=", "!=", "==", ">", "<", "="] {
            guard let range = raw.range(of: operation) else { continue }
            let key = String(raw[..<range.lowerBound])
            let valueText = String(raw[range.upperBound...])
            guard let value = Double(valueText) else { return nil }
            return (key, operation == "==" ? "=" : operation, value)
        }
        return nil
    }

    private static func matchesNumeric(_ actual: Double?, operation: String, value: Double, negated: Bool) -> Bool {
        guard let actual else { return false }
        let matches: Bool
        switch operation {
        case ">": matches = actual > value
        case "<": matches = actual < value
        case ">=": matches = actual >= value
        case "<=": matches = actual <= value
        case "!=": matches = abs(actual - value) > 0.000_001
        default: matches = abs(actual - value) <= 0.000_001
        }
        return negated ? !matches : matches
    }

    private static func cardDataObject(_ raw: String) -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private static func cardCustomDataObject(_ raw: String) -> [String: Any] {
        let cardData = cardDataObject(raw)
        if let object = cardData["cd"] as? [String: Any] { return object }
        guard let customData = cardData["cd"] as? String,
              let data = customData.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private static func numericValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let string as String: Double(string)
        default: nil
        }
    }

    private func searchExpressionClauses(_ query: String) throws -> [[String]] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        func flush() {
            if !current.isEmpty { tokens.append(current); current = "" }
        }
        for character in query {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                current.append(character)
                escaped = true
            } else if character == "\"" {
                current.append(character)
                quoted.toggle()
            } else if !quoted && character.isWhitespace {
                flush()
            } else if !quoted && character == "(" && (current.isEmpty || current == "-") {
                if current == "-" {
                    tokens.append(current)
                    current = ""
                }
                tokens.append("(")
            } else if !quoted && character == ")" && !current.isEmpty
                        && !current.lowercased().hasPrefix("re:")
                        && !current.lowercased().hasPrefix("tag:re:")
                        && !current.lowercased().contains(":re:") {
                flush()
                tokens.append(")")
            } else {
                current.append(character)
            }
        }
        guard !escaped, !quoted else {
            throw SQLiteError.exec("Expressão de busca inválida.")
        }
        flush()
        guard !tokens.isEmpty else { return [] }

        var index = 0
        func parsePrimary() throws -> SearchExpression? {
            guard index < tokens.count else { return nil }
            let token = tokens[index]
            if token == "-" {
                index += 1
                guard let expression = try parsePrimary() else {
                    throw SQLiteError.exec("Expressão de busca inválida.")
                }
                return .not(expression)
            }
            if (token.hasPrefix("-") ? String(token.dropFirst()) : token).hasPrefix(":") {
                throw SQLiteError.exec("Expressão de busca inválida.")
            }
            if token == "(" {
                index += 1
                guard index < tokens.count, tokens[index] != ")",
                      let expression = try parseOr(), index < tokens.count, tokens[index] == ")" else {
                    throw SQLiteError.exec("Expressão de busca inválida.")
                }
                index += 1
                return expression
            }
            if token == ")" || token.uppercased() == "OR" || token.uppercased() == "AND" { return nil }
            if token == "\"\"" || token.hasSuffix(":\"\"") {
                throw SQLiteError.exec("Expressão de busca inválida.")
            }
            index += 1
            return .term(token)
        }
        func parseAnd() throws -> SearchExpression? {
            guard var expression = try parsePrimary() else { return nil }
            while index < tokens.count && tokens[index] != ")" && tokens[index].uppercased() != "OR" {
                if tokens[index].uppercased() == "AND" {
                    index += 1
                    guard let next = try parsePrimary() else {
                        throw SQLiteError.exec("Expressão de busca inválida.")
                    }
                    expression = .and(expression, next)
                } else if let next = try parsePrimary() {
                    expression = .and(expression, next)
                } else {
                    break
                }
            }
            return expression
        }
        func parseOr() throws -> SearchExpression? {
            guard var expression = try parseAnd() else { return nil }
            while index < tokens.count && tokens[index].uppercased() == "OR" {
                index += 1
                guard let next = try parseAnd() else {
                    throw SQLiteError.exec("Expressão de busca inválida.")
                }
                expression = .or(expression, next)
            }
            return expression
        }
        guard let expression = try parseOr(), index == tokens.count else {
            throw SQLiteError.exec("Expressão de busca inválida.")
        }

        func invert(_ term: String) -> String {
            term.hasPrefix("-") ? String(term.dropFirst()) : "-" + term
        }
        func expand(_ expression: SearchExpression, negated: Bool = false) -> [[String]] {
            switch expression {
            case .term(let value): return [[negated ? invert(value) : value]]
            case .not(let nested): return expand(nested, negated: !negated)
            case .or(let left, let right):
                if negated {
                    return expand(left, negated: true).flatMap { lhs in
                        expand(right, negated: true).map { rhs in lhs + rhs }
                    }
                }
                return expand(left) + expand(right)
            case .and(let left, let right):
                if negated {
                    return expand(left, negated: true) + expand(right, negated: true)
                }
                let leftClauses = expand(left)
                let rightClauses = expand(right)
                return leftClauses.flatMap { lhs in rightClauses.map { lhs + $0 } }
            }
        }
        return expand(expression)
    }

    private struct DeckSearchToken {
        var name: String
        var exact: Bool
    }

    private func parseDeckSearchToken(_ token: String) -> DeckSearchToken {
        let raw = String(token.dropFirst(5))
        let exact = raw.hasPrefix("\"") && raw.hasSuffix("\"")
        let name = stripSearchQuotes(raw)
        return DeckSearchToken(name: name, exact: exact)
    }

    private static func matchesSearchName(_ candidate: String, pattern: String) -> Bool {
        guard pattern.contains("*") else { return candidate.caseInsensitiveCompare(pattern) == .orderedSame }
        let expression = "^" + pattern
            .split(separator: "*", omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: ".*") + "$"
        return candidate.range(of: expression, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func stripSearchQuotes(_ token: String) -> String {
        guard token.hasPrefix("\""), token.hasSuffix("\""), token.count >= 2 else { return token }
        return String(token.dropFirst().dropLast())
    }

    private func deckIDs(matchingSearchName name: String, exact: Bool) -> [Int64] {
        if name.hasSuffix("::*") {
            let prefix = String(name.dropLast(3)) + "::"
            return decks.filter { deck in
                guard deck.name.count >= prefix.count else { return false }
                return String(deck.name.prefix(prefix.count)).caseInsensitiveCompare(prefix) == .orderedSame
            }.map(\.id)
        }
        let roots: [AnkiDeck]
        let isUnqualifiedExactName = !name.contains("::") && !name.contains("*")
        if exact {
            roots = decks.filter {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
                    && (!isUnqualifiedExactName || !$0.name.contains("::"))
            }
        } else {
            roots = decks.filter {
                Self.matchesSearchName($0.name, pattern: name)
                    && (!isUnqualifiedExactName || !$0.name.contains("::"))
            }
        }
        // Anki `deck:Foo` includes the whole subdeck tree under each match.
        var ids = Set<Int64>()
        for root in roots {
            for id in deckTreeIDs(including: root.id) { ids.insert(id) }
        }
        return Array(ids)
    }

    // MARK: - Stats helpers

    private func deckFilterSQL(deckID: Int64?, alias: String = "c") -> (clause: String, ids: [Int64]) {
        guard let deckID else { return ("", []) }
        let ids = deckTreeIDs(including: deckID)
        let ph = ids.map { _ in "?" }.joined(separator: ",")
        return (" AND \(alias).did IN (\(ph))", ids)
    }

    private func bindDeckIDs(_ stmt: OpaquePointer, ids: [Int64], startingAt: Int32) {
        for (i, id) in ids.enumerated() {
            SQLiteDatabase.bindInt64(stmt, startingAt + Int32(i), id)
        }
    }

    func todayReviewCount(deckID: Int64? = nil) throws -> Int {
        let start = schedDayStartTimestamp() * 1000
        let filter = deckFilterSQL(deckID: deckID)
        if filter.ids.isEmpty {
            return try db.scalarInt("SELECT COUNT(*) FROM revlog WHERE id > ? AND type != 4", bind: {
                SQLiteDatabase.bindInt64($0, 1, start)
            })
        }
        return try db.scalarInt("""
            SELECT COUNT(*) FROM revlog r JOIN cards c ON c.id = r.cid
            WHERE r.id > ? AND r.type != 4 \(filter.clause)
        """) { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, start)
            self.bindDeckIDs(stmt, ids: filter.ids, startingAt: 2)
        }
    }

    func todayReviewTimeMS(deckID: Int64? = nil) throws -> Int {
        let start = schedDayStartTimestamp() * 1000
        let filter = deckFilterSQL(deckID: deckID)
        if filter.ids.isEmpty {
            return try db.scalarInt("SELECT COALESCE(SUM(time),0) FROM revlog WHERE id > ? AND type != 4", bind: {
                SQLiteDatabase.bindInt64($0, 1, start)
            })
        }
        return try db.scalarInt("""
            SELECT COALESCE(SUM(r.time),0) FROM revlog r JOIN cards c ON c.id = r.cid
            WHERE r.id > ? AND r.type != 4 \(filter.clause)
        """) { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, start)
            self.bindDeckIDs(stmt, ids: filter.ids, startingAt: 2)
        }
    }

    func statsCollectionCounts(deckID: Int64? = nil) throws -> StatsCollectionCounts {
        let filter = deckFilterSQL(deckID: deckID)
        var counts = StatsCollectionCounts()
        try db.query("""
            SELECT COUNT(DISTINCT c.nid), COUNT(c.id)
            FROM cards c
            WHERE 1 = 1 \(filter.clause)
        """, bind: { stmt in
            self.bindDeckIDs(stmt, ids: filter.ids, startingAt: 1)
        }) { stmt in
            counts.notes = Int(sqlite3_column_int(stmt, 0))
            counts.cards = Int(sqlite3_column_int(stmt, 1))
        }
        return counts
    }

    func statsTodaySummary(deckID: Int64? = nil) throws -> StatsTodaySummary {
        let start = schedDayStartTimestamp() * 1000
        let filter = deckFilterSQL(deckID: deckID, alias: "c")
        let sql: String
        if filter.ids.isEmpty {
            sql = """
            SELECT COUNT(*), COALESCE(SUM(time), 0),
                COALESCE(SUM(CASE WHEN ease = 1 THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN type = 0 THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN type = 1 THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN type = 2 THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN type = 3 THEN 1 ELSE 0 END), 0)
            FROM revlog WHERE id > ? AND type != 4
            """
        } else {
            sql = """
            SELECT COUNT(*), COALESCE(SUM(r.time), 0),
                COALESCE(SUM(CASE WHEN r.ease = 1 THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN r.type = 0 THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN r.type = 1 THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN r.type = 2 THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN r.type = 3 THEN 1 ELSE 0 END), 0)
            FROM revlog r JOIN cards c ON c.id = r.cid
            WHERE r.id > ? AND r.type != 4 \(filter.clause)
            """
        }
        var summary = StatsTodaySummary()
        try db.query(sql, bind: { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, start)
            self.bindDeckIDs(stmt, ids: filter.ids, startingAt: 2)
        }) { stmt in
            summary.reviews = Int(sqlite3_column_int(stmt, 0))
            summary.timeMS = Int(sqlite3_column_int(stmt, 1))
            summary.failed = Int(sqlite3_column_int(stmt, 2))
            summary.learning = Int(sqlite3_column_int(stmt, 3))
            summary.review = Int(sqlite3_column_int(stmt, 4))
            summary.relearning = Int(sqlite3_column_int(stmt, 5))
            summary.filtered = Int(sqlite3_column_int(stmt, 6))
        }
        let matureSQL: String
        if filter.ids.isEmpty {
            matureSQL = """
            SELECT COALESCE(SUM(CASE WHEN ease != 1 THEN 1 ELSE 0 END), 0), COUNT(*)
            FROM revlog WHERE id > ? AND lastIvl >= 21
            """
        } else {
            matureSQL = """
            SELECT COALESCE(SUM(CASE WHEN r.ease != 1 THEN 1 ELSE 0 END), 0), COUNT(*)
            FROM revlog r JOIN cards c ON c.id = r.cid
            WHERE r.id > ? AND r.lastIvl >= 21 \(filter.clause)
            """
        }
        try db.query(matureSQL, bind: { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, start)
            self.bindDeckIDs(stmt, ids: filter.ids, startingAt: 2)
        }) { stmt in
            summary.matureCorrect = Int(sqlite3_column_int(stmt, 0))
            summary.matureTotal = Int(sqlite3_column_int(stmt, 1))
        }
        return summary
    }

    func statsCardDistribution(deckID: Int64? = nil) throws -> StatsCardDistribution {
        let filter = deckFilterSQL(deckID: deckID)
        var distribution = StatsCardDistribution()
        try db.query("""
            SELECT
                COALESCE(SUM(CASE WHEN queue = 2 AND ivl >= 21 THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN queue IN (1, 3) OR (queue = 2 AND ivl < 21) THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN queue = 0 THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN queue < 0 THEN 1 ELSE 0 END), 0)
            FROM cards c WHERE 1 = 1 \(filter.clause)
        """, bind: { stmt in
            self.bindDeckIDs(stmt, ids: filter.ids, startingAt: 1)
        }) { stmt in
            distribution.mature = Int(sqlite3_column_int(stmt, 0))
            distribution.youngAndLearning = Int(sqlite3_column_int(stmt, 1))
            distribution.unseen = Int(sqlite3_column_int(stmt, 2))
            distribution.suspendedAndBuried = Int(sqlite3_column_int(stmt, 3))
        }
        return distribution
    }

    func answerButtonBreakdown(days: Int?, deckID: Int64? = nil) throws -> [StatsAnswerButtonBreakdown] {
        var result = [
            StatsAnswerButtonBreakdown(category: "Aprender"),
            StatsAnswerButtonBreakdown(category: "Jovem"),
            StatsAnswerButtonBreakdown(category: "Maduro")
        ]
        let filter = deckFilterSQL(deckID: deckID)
        let start = days.flatMap { $0 > 0 ? (schedDayStartTimestamp() - Int64($0 - 1) * 86_400) * 1000 : nil }
        let sql: String
        if filter.ids.isEmpty {
            sql = "SELECT ease, type, lastIvl FROM revlog WHERE type != 4 AND ease BETWEEN 1 AND 4" + (start == nil ? "" : " AND id > ?") + " ORDER BY id"
        } else {
            sql = """
            SELECT r.ease, r.type, r.lastIvl FROM revlog r JOIN cards c ON c.id = r.cid
            WHERE r.type != 4 AND r.ease BETWEEN 1 AND 4 \(start == nil ? "" : "AND r.id > ?") \(filter.clause)
            ORDER BY r.id
            """
        }
        try db.query(sql, bind: { stmt in
            var index: Int32 = 1
            if let start {
                SQLiteDatabase.bindInt64(stmt, index, start)
                index += 1
            }
            self.bindDeckIDs(stmt, ids: filter.ids, startingAt: index)
        }) { stmt in
            let ease = Int(sqlite3_column_int(stmt, 0))
            let type = Int(sqlite3_column_int(stmt, 1))
            let lastInterval = Int(sqlite3_column_int(stmt, 2))
            let category = type == 0 || type == 2 ? 0 : (lastInterval < 21 ? 1 : 2)
            result[category].add(ease)
        }
        return result
    }

    func hourlyReviewBreakdown(days: Int?, deckID: Int64? = nil) throws -> [StatsHourlyBreakdown] {
        var totals: [Int: (count: Int, correct: Int)] = [:]
        let filter = deckFilterSQL(deckID: deckID)
        let start = days.flatMap { $0 > 0 ? (schedDayStartTimestamp() - Int64($0 - 1) * 86_400) * 1000 : nil }
        let sql: String
        if filter.ids.isEmpty {
            sql = "SELECT id, ease FROM revlog WHERE type IN (0, 1, 2)" + (start == nil ? "" : " AND id > ?") + " ORDER BY id"
        } else {
            sql = """
            SELECT r.id, r.ease FROM revlog r JOIN cards c ON c.id = r.cid
            WHERE r.type IN (0, 1, 2) \(start == nil ? "" : "AND r.id > ?") \(filter.clause)
            ORDER BY r.id
            """
        }
        try db.query(sql, bind: { stmt in
            var index: Int32 = 1
            if let start {
                SQLiteDatabase.bindInt64(stmt, index, start)
                index += 1
            }
            self.bindDeckIDs(stmt, ids: filter.ids, startingAt: index)
        }) { stmt in
            let timestamp = sqlite3_column_int64(stmt, 0)
            let ease = Int(sqlite3_column_int(stmt, 1))
            let clockHour = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(timestamp / 1000)))
            let hour = (clockHour - rolloverHour + 24) % 24
            totals[hour, default: (0, 0)].count += 1
            if ease != 1 { totals[hour, default: (0, 0)].correct += 1 }
        }
        return (0..<24).compactMap { hour in
            guard let total = totals[hour], total.count > 30 else { return nil }
            return StatsHourlyBreakdown(
                hour: hour,
                count: total.count,
                correctPercent: Double(total.correct) / Double(total.count) * 100
            )
        }
    }

    /// day offset (0=today) -> review count
    func reviewsLastDays(_ days: Int, deckID: Int64? = nil) throws -> [Int: Int] {
        let dayCount = max(days, 0)
        let nextDayAt = schedDayStartTimestamp() + 86_400
        let start = (nextDayAt - Int64(dayCount) * 86_400) * 1000
        let end = nextDayAt * 1000
        let filter = deckFilterSQL(deckID: deckID, alias: "c")
        let sql: String
        if filter.ids.isEmpty {
            sql = """
            SELECT CAST((? - id) / 86400000.0 AS INTEGER), COUNT(*)
            FROM revlog WHERE id >= ? AND id < ? AND type != 4 GROUP BY 1
            """
        } else {
            sql = """
            SELECT CAST((? - r.id) / 86400000.0 AS INTEGER), COUNT(*)
            FROM revlog r JOIN cards c ON c.id = r.cid
            WHERE r.id >= ? AND r.id < ? AND r.type != 4 \(filter.clause)
            GROUP BY 1
            """
        }
        var map = Dictionary(uniqueKeysWithValues: (0..<dayCount).map { ($0, 0) })
        if dayCount > 0 {
            try db.query(sql, bind: { stmt in
                SQLiteDatabase.bindInt64(stmt, 1, end)
                SQLiteDatabase.bindInt64(stmt, 2, start)
                SQLiteDatabase.bindInt64(stmt, 3, end)
                self.bindDeckIDs(stmt, ids: filter.ids, startingAt: 4)
            }) { stmt in
                let day = Int(sqlite3_column_int(stmt, 0))
                if day >= 0 && day < dayCount {
                    map[day] = Int(sqlite3_column_int(stmt, 1))
                }
            }
        }
        return map
    }

    func revlogRecent(limit: Int = 200, deckID: Int64? = nil) throws -> [AnkiRevlog] {
        var rows: [AnkiRevlog] = []
        let filter = deckFilterSQL(deckID: deckID)
        let sql: String
        if filter.ids.isEmpty {
            sql = "SELECT * FROM revlog WHERE type != 4 AND ease BETWEEN 1 AND 4 ORDER BY id DESC LIMIT ?"
        } else {
            sql = """
            SELECT r.* FROM revlog r JOIN cards c ON c.id = r.cid
            WHERE r.type != 4 AND r.ease BETWEEN 1 AND 4 \(filter.clause) ORDER BY r.id DESC LIMIT ?
            """
        }
        try db.query(sql, bind: { stmt in
            var idx: Int32 = 1
            if !filter.ids.isEmpty {
                self.bindDeckIDs(stmt, ids: filter.ids, startingAt: idx)
                idx += Int32(filter.ids.count)
            }
            SQLiteDatabase.bindInt(stmt, idx, limit)
        }) { stmt in
            rows.append(AnkiRevlog(
                id: sqlite3_column_int64(stmt, 0),
                cid: sqlite3_column_int64(stmt, 1),
                usn: Int(sqlite3_column_int(stmt, 2)),
                ease: Int(sqlite3_column_int(stmt, 3)),
                ivl: Int(sqlite3_column_int(stmt, 4)),
                lastIvl: Int(sqlite3_column_int(stmt, 5)),
                factor: Int(sqlite3_column_int(stmt, 6)),
                time: Int(sqlite3_column_int(stmt, 7)),
                type: Int(sqlite3_column_int(stmt, 8))
            ))
        }
        return rows
    }

    func futureDue(buckets: Int?, chunkDays: Int, deckID: Int64? = nil) throws -> [Int: Int] {
        let day = schedDay()
        let bucketSize = max(chunkDays, 1)
        var map: [Int: Int] = [:]
        let filter = deckFilterSQL(deckID: deckID)
        let endClause = buckets.map { _ in "AND due < ?" } ?? ""
        try db.query("""
            SELECT due, COUNT(*) FROM cards c
            WHERE queue IN (2, 3) AND due >= ? \(endClause) \(filter.clause)
            GROUP BY due
        """, bind: { stmt in
            SQLiteDatabase.bindInt(stmt, 1, day)
            var index: Int32 = 2
            if let buckets {
                SQLiteDatabase.bindInt(stmt, index, day + buckets * bucketSize)
                index += 1
            }
            self.bindDeckIDs(stmt, ids: filter.ids, startingAt: index)
        }, map: { stmt in
            let due = Int(sqlite3_column_int(stmt, 0))
            let offset = (due - day) / bucketSize
            let count = Int(sqlite3_column_int(stmt, 1))
            map[offset, default: 0] += count
        })
        return map
    }

    func futureDueForecast(buckets: Int?, chunkDays: Int, deckID: Int64? = nil) throws -> StatsFutureDueForecast {
        let today = schedDay()
        let nextDayAt = schedDayStartTimestamp() + 86_400
        let bucketSize = max(chunkDays, 1)
        let filter = deckFilterSQL(deckID: deckID)
        var dueByBucket: [Int: (young: Int, mature: Int)] = [:]
        var forecast = StatsFutureDueForecast()
        var dailyLoad = Float.zero
        let horizonDays = buckets.map { $0 * bucketSize }
        let sql = """
        SELECT type, queue, due, odue, ivl FROM cards c
        WHERE 1 = 1 \(filter.clause)
        """
        try db.query(sql, bind: { stmt in
            self.bindDeckIDs(stmt, ids: filter.ids, startingAt: 1)
        }) { stmt in
            let type = Int(sqlite3_column_int(stmt, 0))
            let queue = Int(sqlite3_column_int(stmt, 1))
            let due = Int(sqlite3_column_int(stmt, 2))
            let originalDue = Int(sqlite3_column_int(stmt, 3))
            let interval = max(Int(sqlite3_column_int(stmt, 4)), 1)

            guard type != AnkiCard.CardType.new.rawValue,
                  queue != AnkiCard.Queue.suspended.rawValue else { return }

            dailyLoad += 1.0 / Float(interval)
            let selectedDue = originalDue != 0 ? originalDue : due
            let offset: Int
            if selectedDue > 1_000_000_000 {
                offset = (selectedDue - Int(nextDayAt)) / 86_400
            } else {
                offset = selectedDue - today
            }

            let isBuried = queue == AnkiCard.Queue.siblingBuried.rawValue || queue == AnkiCard.Queue.manuallyBuried.rawValue
            if isBuried && offset <= 0 {
                return
            }
            if offset < 0 { forecast.hasBacklog = true }
            forecast.dueByDay[offset, default: 0] += 1
            if offset < 0 { return }
            if let horizonDays, offset >= horizonDays { return }

            let bucket = offset / bucketSize
            if interval >= 21 {
                dueByBucket[bucket, default: (0, 0)].mature += 1
            } else {
                dueByBucket[bucket, default: (0, 0)].young += 1
            }
        }

        let lastBucket = buckets.map { $0 - 1 } ?? (dueByBucket.keys.max() ?? -1)
        var cumulative = 0
        if lastBucket >= 0 {
            for offset in 0...lastBucket {
                let due = dueByBucket[offset, default: (0, 0)]
                cumulative += due.young + due.mature
                forecast.points.append(StatsFutureDuePoint(
                    offset: offset,
                    young: due.young,
                    mature: due.mature,
                    cumulative: cumulative
                ))
            }
        }
        forecast.dailyLoad = Int(dailyLoad)
        return forecast
    }

    /// Answer button counts from revlog (ease 1…4).
    func answerButtonCounts(limit: Int = 2000, deckID: Int64? = nil) throws -> [Int: Int] {
        var map: [Int: Int] = [1: 0, 2: 0, 3: 0, 4: 0]
        let filter = deckFilterSQL(deckID: deckID)
        let sql: String
        if filter.ids.isEmpty {
            sql = "SELECT ease, COUNT(*) FROM revlog WHERE ease BETWEEN 1 AND 4 GROUP BY ease ORDER BY ease"
        } else {
            sql = """
            SELECT r.ease, COUNT(*) FROM revlog r JOIN cards c ON c.id = r.cid
            WHERE r.ease BETWEEN 1 AND 4 \(filter.clause) GROUP BY r.ease ORDER BY r.ease
            """
        }
        try db.query(sql, bind: { stmt in
            self.bindDeckIDs(stmt, ids: filter.ids, startingAt: 1)
        }) { stmt in
            let ease = Int(sqlite3_column_int(stmt, 0))
            map[ease] = Int(sqlite3_column_int(stmt, 1))
        }
        _ = limit
        return map
    }

    func intervalStatistics(days: Int, historyDays: Int, deckID: Int64? = nil) throws -> StatsIntervalStatistics {
        let chunkDays: Int
        let maximumBucket: Int?
        if days == 31 {
            chunkDays = 1
            maximumBucket = 31
        } else if days == 365 {
            chunkDays = 7
            maximumBucket = 52
        } else if days > 0 {
            chunkDays = 7
            maximumBucket = (days + 6) / 7
        } else {
            let age = max(historyDays, 1)
            chunkDays = age <= 100 ? 1 : (age <= 700 ? 7 : 31)
            maximumBucket = nil
        }
        let filter = deckFilterSQL(deckID: deckID)
        var countsByBucket: [Int: Int] = [:]
        try db.query("""
            SELECT ivl / ? AS bucket, COUNT(*) FROM cards c
            WHERE queue = 2 \(filter.clause)
            GROUP BY bucket ORDER BY bucket
        """, bind: { stmt in
            SQLiteDatabase.bindInt(stmt, 1, chunkDays)
            self.bindDeckIDs(stmt, ids: filter.ids, startingAt: 2)
        }) { stmt in
            let bucket = Int(sqlite3_column_int(stmt, 0))
            if maximumBucket == nil || bucket <= maximumBucket! {
                countsByBucket[bucket] = Int(sqlite3_column_int(stmt, 1))
            }
        }
        var totalCards = 0
        var averageDays: Double?
        var longestDays: Int?
        try db.query("""
            SELECT COUNT(*), AVG(ivl), MAX(ivl) FROM cards c
            WHERE queue = 2 \(filter.clause)
        """, bind: { stmt in
            self.bindDeckIDs(stmt, ids: filter.ids, startingAt: 1)
        }) { stmt in
            totalCards = Int(sqlite3_column_int(stmt, 0))
            if sqlite3_column_type(stmt, 1) != SQLITE_NULL { averageDays = sqlite3_column_double(stmt, 1) }
            if sqlite3_column_type(stmt, 2) != SQLITE_NULL { longestDays = Int(sqlite3_column_int(stmt, 2)) }
        }
        var cumulative = 0
        let points = countsByBucket.keys.sorted().map { bucket in
            let count = countsByBucket[bucket, default: 0]
            cumulative += count
            let lowerDay = bucket * chunkDays
            let upperDay = lowerDay + chunkDays - 1
            return StatsIntervalBucket(
                bucket: bucket,
                dayValue: lowerDay,
                label: chunkDays == 1 ? "\(lowerDay)d" : "\(lowerDay)–\(upperDay)d",
                count: count,
                cumulativePercent: totalCards == 0 ? 0 : Double(cumulative) / Double(totalCards) * 100
            )
        }
        return StatsIntervalStatistics(
            chunkDays: chunkDays,
            points: points,
            averageDays: averageDays,
            longestDays: longestDays,
            totalCards: totalCards
        )
    }

    /// Review cards due on each day offset, for the easy-day load balancer of one preset.
    func dueCountsForPreset(_ configID: Int64, today: Int, days: Int = 100) -> [Int] {
        let ids = decks.filter { $0.conf == configID && !$0.isFiltered }.map(\.id)
        var counts = Array(repeating: 0, count: max(days, 1))
        guard !ids.isEmpty else { return counts }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT due - ?, COUNT(*) FROM cards
        WHERE queue = 2 AND due >= ? AND due < ? AND did IN (\(placeholders))
        GROUP BY due
        """
        try? db.query(sql, bind: { stmt in
            SQLiteDatabase.bindInt(stmt, 1, today)
            SQLiteDatabase.bindInt(stmt, 2, today)
            SQLiteDatabase.bindInt(stmt, 3, today + days)
            for (i, id) in ids.enumerated() {
                SQLiteDatabase.bindInt64(stmt, Int32(i + 4), id)
            }
        }) { stmt in
            let offset = Int(sqlite3_column_int(stmt, 0))
            let count = Int(sqlite3_column_int(stmt, 1))
            if offset >= 0 && offset < counts.count { counts[offset] = count }
        }
        return counts
    }

    func loadBalancerDueCards(today: Int, days: Int = 99) -> [LoadBalancerDueCard] {
        let configByDeck = Dictionary(uniqueKeysWithValues: decks.filter { !$0.isFiltered }.map { ($0.id, $0.conf) })
        guard !configByDeck.isEmpty else { return [] }
        var cards: [LoadBalancerDueCard] = []
        try? db.query("SELECT id, nid, did, due FROM cards WHERE due >= ? AND due < ?", bind: { stmt in
            SQLiteDatabase.bindInt(stmt, 1, today)
            SQLiteDatabase.bindInt(stmt, 2, today + days)
        }) { stmt in
            let deckID = sqlite3_column_int64(stmt, 2)
            guard let configID = configByDeck[deckID] else { return }
            cards.append(LoadBalancerDueCard(
                noteID: sqlite3_column_int64(stmt, 1),
                deckConfigID: configID,
                dayOffset: Int(sqlite3_column_int(stmt, 3)) - today
            ))
        }
        return cards
    }

    struct ReviewDayPoint: Identifiable, Sendable {
        var id: Int { offset }
        var offset: Int
        var learn: Int
        var young: Int
        var mature: Int
        var relearn: Int
        var filtered: Int
        var timeMS: Int
    }

    struct TrueRetention: Identifiable, Sendable {
        var id: String { label }
        var label: String
        var youngPass = 0
        var youngFail = 0
        var maturePass = 0
        var matureFail = 0

        var youngPercent: Double { percent(youngPass, youngFail) }
        var maturePercent: Double { percent(maturePass, matureFail) }

        private func percent(_ pass: Int, _ fail: Int) -> Double {
            let total = pass + fail
            guard total > 0 else { return 0 }
            return Double(pass) / Double(total) * 100
        }
    }

    func reviewHistoryDays(deckID: Int64? = nil) throws -> Int {
        let filter = deckFilterSQL(deckID: deckID)
        var oldest: Int64?
        let sql: String
        if filter.ids.isEmpty {
            sql = "SELECT MIN(id) FROM revlog"
        } else {
            sql = "SELECT MIN(r.id) FROM revlog r JOIN cards c ON c.id = r.cid WHERE 1 = 1 \(filter.clause)"
        }
        try db.query(sql, bind: { stmt in
            self.bindDeckIDs(stmt, ids: filter.ids, startingAt: 1)
        }) { stmt in
            let value = sqlite3_column_int64(stmt, 0)
            if value > 0 { oldest = value }
        }
        guard let oldest else { return 1 }
        let nextDayAt = schedDayStartTimestamp() + 86_400
        let elapsedMS = max(nextDayAt * 1000 - oldest, 0)
        return max(1, min(Int(elapsedMS / 86_400_000) + 1, 100_000))
    }

    func reviewsByType(buckets: Int, chunkDays: Int, deckID: Int64? = nil) throws -> [ReviewDayPoint] {
        let bucketCount = max(buckets, 1)
        let bucketSize = max(chunkDays, 1)
        var points = (0..<bucketCount).map { ReviewDayPoint(offset: $0, learn: 0, young: 0, mature: 0, relearn: 0, filtered: 0, timeMS: 0) }
        let nextDayAt = schedDayStartTimestamp() + 86_400
        let start = (nextDayAt - Int64(bucketCount * bucketSize) * 86_400) * 1000
        let filter = deckFilterSQL(deckID: deckID)
        let sql: String
        if filter.ids.isEmpty {
            sql = "SELECT id, type, lastIvl, time FROM revlog WHERE id > ? AND type != 4"
        } else {
            sql = """
            SELECT r.id, r.type, r.lastIvl, r.time FROM revlog r JOIN cards c ON c.id = r.cid
            WHERE r.id > ? AND r.type != 4 \(filter.clause)
            """
        }
        try db.query(sql, bind: { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, start)
            self.bindDeckIDs(stmt, ids: filter.ids, startingAt: 2)
        }) { stmt in
            let stamp = Double(sqlite3_column_int64(stmt, 0)) / 1000
            let type = Int(sqlite3_column_int(stmt, 1))
            let lastIvl = Int(sqlite3_column_int(stmt, 2))
            let timeMS = Int(sqlite3_column_int(stmt, 3))
            guard type != 4 else { return }
            let relativeDay = Int((stamp - Double(nextDayAt)) / 86_400)
            let offset = -(relativeDay / bucketSize)
            guard offset >= 0, offset < points.count else { return }
            points[offset].timeMS += timeMS
            switch type {
            case 0: points[offset].learn += 1
            case 1:
                if lastIvl < 21 { points[offset].young += 1 } else { points[offset].mature += 1 }
            case 2: points[offset].relearn += 1
            default: points[offset].filtered += 1
            }
        }
        return points
    }

    func trueRetention(deckID: Int64? = nil) throws -> [TrueRetention] {
        let day: Int64 = 86_400
        let nextDayStart = schedDayStartTimestamp() + day
        let periods: [(label: String, start: Int64, end: Int64)] = [
            ("Hoje", nextDayStart - day, nextDayStart),
            ("Ontem", nextDayStart - day * 2, nextDayStart - day),
            ("Últimos 7 dias", nextDayStart - day * 7, nextDayStart),
            ("Últimos 30 dias", nextDayStart - day * 30, nextDayStart),
            ("Último ano", nextDayStart - day * 365, nextDayStart),
            ("Todo o histórico", 0, nextDayStart)
        ]
        var results = periods.map { period in
            TrueRetention(label: period.label)
        }
        let filter = deckFilterSQL(deckID: deckID)
        let sql: String
        if filter.ids.isEmpty {
            sql = """
            SELECT id, ease, lastIvl FROM revlog
            WHERE id < ? AND ease > 0 AND NOT (type = 3 AND factor = 0)
                AND (type = 1 OR lastIvl <= -86400 OR lastIvl >= 1)
            ORDER BY id
            """
        } else {
            sql = """
            SELECT r.id, r.ease, r.lastIvl FROM revlog r JOIN cards c ON c.id = r.cid
            WHERE r.id < ? AND r.ease > 0 AND NOT (r.type = 3 AND r.factor = 0)
                AND (r.type = 1 OR r.lastIvl <= -86400 OR r.lastIvl >= 1) \(filter.clause)
            ORDER BY r.id
            """
        }
        try db.query(sql, bind: { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, nextDayStart * 1000)
            self.bindDeckIDs(stmt, ids: filter.ids, startingAt: 2)
        }) { stmt in
            let timestamp = sqlite3_column_int64(stmt, 0) / 1000
            let lastIvl = Int(sqlite3_column_int(stmt, 2))
            for (index, period) in periods.enumerated() where timestamp >= period.start && timestamp < period.end {
                let passed = sqlite3_column_int(stmt, 1) > 1
                if lastIvl < 21 {
                    if passed { results[index].youngPass += 1 } else { results[index].youngFail += 1 }
                } else if passed {
                    results[index].maturePass += 1
                } else {
                    results[index].matureFail += 1
                }
            }
        }
        return results
    }

    /// Ease factor histogram for review cards. Factor 2500 is 250%.
    func easeHistogram(deckID: Int64? = nil) throws -> [(label: String, count: Int)] {
        let labels = ["<130%"] + (13...25).map { "\($0 * 10)%" } + [">250%"]
        var counts = Array(repeating: 0, count: labels.count)
        let filter = deckFilterSQL(deckID: deckID)
        try db.query("SELECT factor FROM cards c WHERE type = 2 \(filter.clause)", bind: {
            self.bindDeckIDs($0, ids: filter.ids, startingAt: 1)
        }) { stmt in
            let factor = Int(sqlite3_column_int(stmt, 0))
            let percent = factor / 10
            let index: Int
            if percent < 130 {
                index = 0
            } else if percent > 250 {
                index = counts.count - 1
            } else {
                index = 1 + (percent - 130) / 10
            }
            if counts.indices.contains(index) { counts[index] += 1 }
        }
        return Array(zip(labels, counts))
    }

    func cardStateCounts(deckID: Int64? = nil) throws -> (new: Int, learn: Int, review: Int, suspended: Int, buried: Int) {
        let filter = deckFilterSQL(deckID: deckID)
        func count(_ whereSQL: String) throws -> Int {
            try db.scalarInt("SELECT COUNT(*) FROM cards c WHERE \(whereSQL) \(filter.clause)", bind: {
                self.bindDeckIDs($0, ids: filter.ids, startingAt: 1)
            })
        }
        return (
            try count("queue = 0"),
            try count("queue IN (1,3)"),
            try count("queue = 2"),
            try count("queue = -1"),
            try count("queue IN (-2,-3)")
        )
    }

    func fsrsCardStatistics(deckID: Int64? = nil) throws -> FSRSCardStatistics {
        let filter = deckFilterSQL(deckID: deckID)
        let now = Int(Date().timeIntervalSince1970)
        let today = schedDay()
        var stabilityValues: [Double] = []
        var difficultyValues: [Double] = []
        var retrievabilityValues: [Double] = []
        try db.query(
            "SELECT c.data, c.ivl, c.due FROM cards c WHERE c.type = 2 AND c.queue >= 0 \(filter.clause)",
            bind: { stmt in self.bindDeckIDs(stmt, ids: filter.ids, startingAt: 1) }
        ) { stmt in
            let raw = SQLiteDatabase.text(stmt, 0)
            guard let memory = FSRSCardData.memory(in: raw) else { return }
            stabilityValues.append(Double(memory.stability))
            difficultyValues.append(Double(memory.difficulty))
            let interval = Int(sqlite3_column_int(stmt, 1))
            let due = Int(sqlite3_column_int(stmt, 2))
            let elapsed = Self.fsrsElapsedDays(data: raw, due: due, interval: interval, today: today, now: now)
            retrievabilityValues.append(Double(FSRS6.retrievability(
                daysElapsed: elapsed,
                stability: memory.stability,
                decay: FSRSCardData.decay(in: raw) ?? FSRS6.defaultDecay
            )))
        }

        func distribution(_ values: [Double], ranges: [(String, Double, Double)]) -> [(label: String, count: Int)] {
            ranges.map { label, lower, upper in
                (label, values.filter { $0 >= lower && $0 < upper }.count)
            }
        }
        func average(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }

        return FSRSCardStatistics(
            cardCount: stabilityValues.count,
            averageStability: average(stabilityValues),
            averageDifficulty: average(difficultyValues),
            averageRetrievability: average(retrievabilityValues),
            stability: distribution(stabilityValues, ranges: [
                ("≤1d", 0, 1.000_001), ("1–7d", 1.000_001, 7.000_001),
                ("7–30d", 7.000_001, 30.000_001), ("30–90d", 30.000_001, 90.000_001),
                ("90–365d", 90.000_001, 365.000_001), (">365d", 365.000_001, 36_500.001)
            ]),
            difficulty: distribution(difficultyValues, ranges: [
                ("1–2", 1, 2.000_001), ("2–4", 2.000_001, 4.000_001),
                ("4–6", 4.000_001, 6.000_001), ("6–8", 6.000_001, 8.000_001),
                ("8–10", 8.000_001, 10.001)
            ]),
            retrievability: distribution(retrievabilityValues.map { $0 * 100 }, ranges: [
                ("<50%", 0, 50), ("50–60%", 50, 60), ("60–70%", 60, 70),
                ("70–80%", 70, 80), ("80–90%", 80, 90), ("90–100%", 90, 100.001)
            ])
        )
    }

    func addedHistoryDays(deckID: Int64? = nil) throws -> Int {
        let filter = deckFilterSQL(deckID: deckID)
        var oldest: Int64?
        try db.query("SELECT MIN(id) FROM cards c WHERE 1 = 1 \(filter.clause)", bind: { stmt in
            self.bindDeckIDs(stmt, ids: filter.ids, startingAt: 1)
        }) { stmt in
            let value = sqlite3_column_int64(stmt, 0)
            if value > 0 { oldest = value }
        }
        guard let oldest else { return 1 }
        let nextDayAt = schedDayStartTimestamp() + 86_400
        let elapsedMS = max(nextDayAt * 1000 - oldest, 0)
        return max(1, min(Int(elapsedMS / 86_400_000) + 1, 100_000))
    }

    func cardsAdded(buckets: Int, chunkDays: Int, deckID: Int64? = nil) throws -> [Int: Int] {
        let bucketCount = max(buckets, 1)
        let bucketSize = max(chunkDays, 1)
        var map = Dictionary(uniqueKeysWithValues: (0..<bucketCount).map { ($0, 0) })
        let nextDayAt = schedDayStartTimestamp() + 86_400
        let start = (nextDayAt - Int64(bucketCount * bucketSize) * 86_400) * 1000
        let filter = deckFilterSQL(deckID: deckID)
        try db.query("SELECT id FROM cards c WHERE id > ? \(filter.clause)", bind: { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, start)
            self.bindDeckIDs(stmt, ids: filter.ids, startingAt: 2)
        }) { stmt in
            let stamp = Double(sqlite3_column_int64(stmt, 0)) / 1000
            let relativeDay = Int((stamp - Double(nextDayAt)) / 86_400)
            let offset = -(relativeDay / bucketSize)
            guard offset >= 0, offset < bucketCount else { return }
            map[offset, default: 0] += 1
        }
        return map
    }

    /// Reviews in the last 24h bucketed by hour of day (0…23).
    func reviewsByHour(deckID: Int64? = nil) throws -> [Int: Int] {
        var map: [Int: Int] = [:]
        for h in 0..<24 { map[h] = 0 }
        let start = Int64(Date().timeIntervalSince1970) - 86400
        let filter = deckFilterSQL(deckID: deckID)
        let sql: String
        if filter.ids.isEmpty {
            sql = "SELECT id FROM revlog WHERE id >= ? AND type != 4"
        } else {
            sql = "SELECT r.id FROM revlog r JOIN cards c ON c.id = r.cid WHERE r.id >= ? AND r.type != 4 \(filter.clause)"
        }
        try db.query(sql, bind: { stmt in
            SQLiteDatabase.bindInt64(stmt, 1, start * 1000)
            self.bindDeckIDs(stmt, ids: filter.ids, startingAt: 2)
        }) { stmt in
            let ms = sqlite3_column_int64(stmt, 0)
            let date = Date(timeIntervalSince1970: TimeInterval(ms / 1000))
            let hour = Calendar.current.component(.hour, from: date)
            map[hour, default: 0] += 1
        }
        return map
    }

    // MARK: - Mapping

    static func mapCard(_ stmt: OpaquePointer) -> AnkiCard {
        AnkiCard(
            id: sqlite3_column_int64(stmt, 0),
            nid: sqlite3_column_int64(stmt, 1),
            did: sqlite3_column_int64(stmt, 2),
            ord: Int(sqlite3_column_int(stmt, 3)),
            mod: sqlite3_column_int64(stmt, 4),
            usn: Int(sqlite3_column_int(stmt, 5)),
            type: Int(sqlite3_column_int(stmt, 6)),
            queue: Int(sqlite3_column_int(stmt, 7)),
            due: Int(sqlite3_column_int(stmt, 8)),
            ivl: Int(sqlite3_column_int(stmt, 9)),
            factor: Int(sqlite3_column_int(stmt, 10)),
            reps: Int(sqlite3_column_int(stmt, 11)),
            lapses: Int(sqlite3_column_int(stmt, 12)),
            left: Int(sqlite3_column_int(stmt, 13)),
            odue: Int(sqlite3_column_int(stmt, 14)),
            odid: sqlite3_column_int64(stmt, 15),
            flags: Int(sqlite3_column_int(stmt, 16)),
            data: SQLiteDatabase.text(stmt, 17)
        )
    }

    static func mapNote(_ stmt: OpaquePointer) -> AnkiNote {
        AnkiNote(
            id: sqlite3_column_int64(stmt, 0),
            guid: SQLiteDatabase.text(stmt, 1),
            mid: sqlite3_column_int64(stmt, 2),
            mod: sqlite3_column_int64(stmt, 3),
            usn: Int(sqlite3_column_int(stmt, 4)),
            tags: SQLiteDatabase.text(stmt, 5),
            flds: SQLiteDatabase.text(stmt, 6),
            sfld: SQLiteDatabase.text(stmt, 7),
            csum: sqlite3_column_int64(stmt, 8),
            flags: Int(sqlite3_column_int(stmt, 9)),
            data: SQLiteDatabase.text(stmt, 10)
        )
    }

    // MARK: - IDs / helpers

    func recentNoteSummaries(limit: Int = 20) -> [(id: Int64, title: String)] {
        var rows: [(id: Int64, title: String)] = []
        try? db.query("SELECT id, sfld FROM notes ORDER BY id DESC LIMIT \(max(limit, 1))") { stmt in
            let title = SQLiteDatabase.text(stmt, 1)
            rows.append((sqlite3_column_int64(stmt, 0), title.isEmpty ? "Nota sem texto" : title))
        }
        return rows
    }

    func timestampID() -> Int64 {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let databaseMaximum: Int64
        if let db {
            databaseMaximum = (try? db.scalarInt64("""
                SELECT COALESCE(MAX(value), 0) FROM (
                    SELECT MAX(id) AS value FROM notes
                    UNION ALL SELECT MAX(id) FROM cards
                    UNION ALL SELECT MAX(id) FROM revlog
                    UNION ALL SELECT MAX(oid) FROM graves
                )
                """)) ?? 0
        } else {
            databaseMaximum = 0
        }
        lastGeneratedID = max(now, lastGeneratedID + 1, databaseMaximum + 1)
        return lastGeneratedID
    }

    func randomGUID() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&()*+,-./:;<=>?@[]^_`{|}~")
        return String((0..<10).map { _ in chars.randomElement()! })
    }

    func fieldChecksum(_ text: String) -> Int64 {
        let stripped = stripHTMLPreservingMediaFilenames(text)
        let digest = SHA1.hash(stripped)
        let hex = digest.prefix(8)
        return Int64(hex, radix: 16) ?? 0
    }

    func normalizeNoteText(_ text: String) -> String {
        guard conf["normalizeNoteText"] as? Bool ?? true else { return text }
        return text.precomposedStringWithCanonicalMapping
    }

    private func normalizeNoteFields(_ fields: [String]) -> [String] {
        guard conf["normalizeNoteText"] as? Bool ?? true else { return fields }
        return fields.map(\.precomposedStringWithCanonicalMapping)
    }

    func stripHTMLPreservingMediaFilenames(_ text: String) -> String {
        AnkiFieldText.stripHTMLPreservingMediaFilenames(text)
    }

    static func int64(_ any: Any?) -> Int64? {
        switch any {
        case let i as Int64: return i
        case let i as Int: return Int64(i)
        case let n as NSNumber: return n.int64Value
        case let s as String: return Int64(s)
        default: return nil
        }
    }

    static func int(_ any: Any?) -> Int? {
        if let i = int64(any) { return Int(i) }
        return nil
    }
}

private enum AnkiFieldText {
    private static let mediaReference = try! NSRegularExpression(
        pattern: #"(?is)<\b(?:img|audio|video|object|source)\b(?:[^>]|"[^"]+?"|'[^']+?')+?\b(?:src|data)=(?:"([^"]+?)"[^>]*>|'([^']+?)'[^>]*>|([^ >]+?)(?:\x20[^>]*>|>))"#
    )
    private static let html = try! NSRegularExpression(
        pattern: #"(?is)(<!--.*?-->)|(<style.*?>.*?</style>)|(<script.*?>.*?</script>)|(<.*?>)"#
    )

    static func stripHTMLPreservingMediaFilenames(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let withMediaNames = mediaReference.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: " $1$2$3 "
        )
        let stripped = html.stringByReplacingMatches(
            in: withMediaNames,
            range: NSRange(withMediaNames.startIndex..., in: withMediaNames),
            withTemplate: ""
        )
        return TemplateEngine.decodeHTMLEntities(stripped) ?? stripped
    }
}

enum ClozeHelper {
    enum FieldIssue: Equatable {
        case normal
        case missingCloze
        case clozeOutsideClozeNotetype
        case clozeInNonClozeField
    }

    static func ords(in fields: [String]) -> [Int] {
        var set = Set<Int>()
        let pattern = try! NSRegularExpression(pattern: #"\{\{c(\d+(?:,\d+)*)::"#)
        for field in fields {
            let range = NSRange(field.startIndex..., in: field)
            pattern.enumerateMatches(in: field, range: range) { match, _, _ in
                guard let match, let r = Range(match.range(at: 1), in: field) else { return }
                for part in field[r].split(separator: ",") {
                    if let n = Int(part), n > 0 { set.insert(min(n - 1, 499)) }
                }
            }
        }
        return set.sorted()
    }

    static func fieldIssue(fields: [String], notetype: AnkiNotetype) -> FieldIssue {
        var clozeFieldOrds = Set<Int>()
        if notetype.isCloze,
           let template = notetype.tmpls.sorted(by: { $0.ord < $1.ord }).first?.qfmt,
           let pattern = try? NSRegularExpression(pattern: #"\{\{([^{}]+)\}\}"#) {
            let source = TemplateEngine.removingHTMLComments(from: TemplateEngine.normalizedTemplateSyntax(template))
            for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                guard let range = Range(match.range(at: 1), in: source) else { continue }
                let parts = source[range].split(separator: ":", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard parts.dropLast().contains("cloze"), let name = parts.last,
                      let field = notetype.flds.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
                clozeFieldOrds.insert(field.ord)
            }
        }

        var containsCloze = false
        for (ord, field) in fields.enumerated() where !ords(in: [field]).isEmpty {
            guard notetype.isCloze else { return .clozeOutsideClozeNotetype }
            guard clozeFieldOrds.contains(ord) else { return .clozeInNonClozeField }
            containsCloze = true
        }
        return notetype.isCloze && !containsCloze ? .missingCloze : .normal
    }
}

enum SHA1 {
    static func hash(_ string: String) -> String {
        let data = Data(string.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA1(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
