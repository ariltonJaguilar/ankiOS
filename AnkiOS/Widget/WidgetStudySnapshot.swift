import Foundation

/// The next study card, written by the app and read by the widget.
struct WidgetStudySnapshot: Codable, Equatable, Sendable {
    var studyDeckID: Int64
    var deckName: String
    var cardID: Int64
    var question: String
    var answer: String
    var newCount: Int
    var learnCount: Int
    var reviewCount: Int
    var again: String
    var hard: String
    var good: String
    var easy: String
    var hasCard: Bool
    /// More new cards exist beyond today's limit.
    var moreNew: Bool
    /// More review cards exist beyond today's limit.
    var moreReview: Bool
    /// The deck has cards that were already seen, so they can be practiced again.
    var canStudyAgain: Bool
    var statusTitle: String
    var statusDetail: String

    var canStudyMore: Bool { moreNew || moreReview }

    init(
        studyDeckID: Int64,
        deckName: String,
        cardID: Int64,
        question: String,
        answer: String,
        newCount: Int,
        learnCount: Int,
        reviewCount: Int,
        again: String,
        hard: String,
        good: String,
        easy: String,
        hasCard: Bool,
        moreNew: Bool = false,
        moreReview: Bool = false,
        canStudyAgain: Bool = false,
        statusTitle: String = "",
        statusDetail: String = ""
    ) {
        self.studyDeckID = studyDeckID
        self.deckName = deckName
        self.cardID = cardID
        self.question = question
        self.answer = answer
        self.newCount = newCount
        self.learnCount = learnCount
        self.reviewCount = reviewCount
        self.again = again
        self.hard = hard
        self.good = good
        self.easy = easy
        self.hasCard = hasCard
        self.moreNew = moreNew
        self.moreReview = moreReview
        self.canStudyAgain = canStudyAgain
        self.statusTitle = statusTitle
        self.statusDetail = statusDetail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        studyDeckID = try container.decodeIfPresent(Int64.self, forKey: .studyDeckID) ?? 0
        deckName = try container.decodeIfPresent(String.self, forKey: .deckName) ?? ""
        cardID = try container.decodeIfPresent(Int64.self, forKey: .cardID) ?? 0
        question = try container.decodeIfPresent(String.self, forKey: .question) ?? ""
        answer = try container.decodeIfPresent(String.self, forKey: .answer) ?? ""
        newCount = try container.decodeIfPresent(Int.self, forKey: .newCount) ?? 0
        learnCount = try container.decodeIfPresent(Int.self, forKey: .learnCount) ?? 0
        reviewCount = try container.decodeIfPresent(Int.self, forKey: .reviewCount) ?? 0
        again = try container.decodeIfPresent(String.self, forKey: .again) ?? ""
        hard = try container.decodeIfPresent(String.self, forKey: .hard) ?? ""
        good = try container.decodeIfPresent(String.self, forKey: .good) ?? ""
        easy = try container.decodeIfPresent(String.self, forKey: .easy) ?? ""
        hasCard = try container.decodeIfPresent(Bool.self, forKey: .hasCard) ?? false
        moreNew = try container.decodeIfPresent(Bool.self, forKey: .moreNew) ?? false
        moreReview = try container.decodeIfPresent(Bool.self, forKey: .moreReview) ?? false
        canStudyAgain = try container.decodeIfPresent(Bool.self, forKey: .canStudyAgain) ?? false
        statusTitle = try container.decodeIfPresent(String.self, forKey: .statusTitle) ?? ""
        statusDetail = try container.decodeIfPresent(String.self, forKey: .statusDetail) ?? ""
    }

    static let empty = WidgetStudySnapshot(
        studyDeckID: 0,
        deckName: "",
        cardID: 0,
        question: "",
        answer: "",
        newCount: 0,
        learnCount: 0,
        reviewCount: 0,
        again: "",
        hard: "",
        good: "",
        easy: "",
        hasCard: false
    )

    static let gallery = WidgetStudySnapshot(
        studyDeckID: 1,
        deckName: "Hiragana",
        cardID: 1,
        question: "あ",
        answer: "a",
        newCount: 5,
        learnCount: 0,
        reviewCount: 12,
        again: "<1 min",
        hard: "6 min",
        good: "10 min",
        easy: "4d",
        hasCard: true
    )
}

struct WidgetStudyFile: Codable, Equatable, Sendable {
    var snapshot: WidgetStudySnapshot
    /// Card currently flipped to the answer. Cleared when the queue moves on.
    var revealedCardID: Int64?
}

enum WidgetStudyStore {
    static let groupID = "group.com.bigbear.AnkiOS"
    private static let fileName = "widget-study.json"

    static func load() -> WidgetStudyFile? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetStudyFile.self, from: data)
    }

    static func save(_ file: WidgetStudyFile) {
        guard let url = fileURL else { return }
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func reveal(cardID: Int64) {
        var file = load() ?? WidgetStudyFile(snapshot: .empty, revealedCardID: nil)
        file.revealedCardID = cardID
        save(file)
    }

    static func conceal() {
        guard var file = load() else { return }
        file.revealedCardID = nil
        save(file)
    }

    static func isRevealed(_ snapshot: WidgetStudySnapshot) -> Bool {
        guard snapshot.hasCard else { return false }
        return load()?.revealedCardID == snapshot.cardID
    }

    private static var fileURL: URL? {
        if SharedProfiles.uiTestSession != nil {
            return SharedProfiles.profilesRoot.deletingLastPathComponent().appendingPathComponent("widget-study.json")
        }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID
        ) else { return nil }
        return container.appendingPathComponent(fileName)
    }
}
