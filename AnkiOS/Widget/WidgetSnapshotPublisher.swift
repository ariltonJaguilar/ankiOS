import Foundation
import WidgetKit

extension WidgetStudyBridge {
    /// Wire widget refreshes and pick up grades the widget wrote into the shared collection.
    @MainActor
    static func install() {
        let store = CollectionStore.shared
        store.onWidgetRefresh = {
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                WidgetSnapshotPublisher.publish(store)
            }
        }
        if SharedProfiles.uiTestSession == nil { WidgetCollectionPing.start() }
    }
}

/// Cross-process signal. The widget posts it; the app reloads without coming forward.
enum WidgetCollectionPing {
    private static let note = "com.bigbear.AnkiOS.widgetChanged"
    nonisolated(unsafe) private static var observing = false

    static func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(note as CFString),
            nil,
            nil,
            true
        )
    }

    static func start() {
        guard !observing else { return }
        observing = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                Task { @MainActor in
                    await CollectionStore.shared.reloadAfterExternalEdit()
                }
            },
            note as CFString,
            nil,
            .deliverImmediately
        )
    }
}

enum WidgetSnapshotPublisher {
    @MainActor
    static func publish(_ store: CollectionStore) {
        guard store.db != nil else { return }
        let file = WidgetStudyFile(snapshot: makeSnapshot(store), revealedCardID: nil)
        let previous = WidgetStudyStore.load()
        var next = file
        if let previous, previous.snapshot.cardID == file.snapshot.cardID, file.snapshot.hasCard {
            next.revealedCardID = previous.revealedCardID
        }
        WidgetStudyStore.save(next)
        #if !ANKIOS_PARITY_HARNESS
        if SharedProfiles.uiTestSession == nil { WidgetCenter.shared.reloadAllTimelines() }
        #endif
    }

    @MainActor
    static func grade(cardID: Int64, rating raw: Int) async {
        guard let rating = Rating(rawValue: raw),
              let lock = try? SharedCollectionFileLock.acquire(profilesRoot: SharedProfiles.profilesRoot) else { return }
        defer { lock.release() }
        guard let store = await readyStore() else { return }
        defer {
            store.closeCollectionConnection()
        }
        guard let card = try? store.fetchCard(id: cardID) else {
            publish(store)
            return
        }
        let studyID = WidgetStudyStore.load()?.snapshot.studyDeckID ?? card.did
        guard let deck = store.deck(id: studyID) ?? store.deck(id: card.did) else { return }
        WidgetStudyStore.conceal()
        let scheduler = Scheduler(store: store)
        try? scheduler.answer(card: card, deck: deck, rating: rating, timeTakenMS: 1_500)
        publish(store)
        WidgetCollectionPing.post()
    }

    /// Practice cards already seen. Does not raise today's limit or include new cards.
    @MainActor
    static func studyAgain() async {
        guard let lock = try? SharedCollectionFileLock.acquire(profilesRoot: SharedProfiles.profilesRoot) else { return }
        defer { lock.release() }
        guard let store = await readyStore() else { return }
        defer {
            store.closeCollectionConnection()
        }
        guard let deck = idleDeck(in: store) else { return }
        let quoted = quotedDeck(deck.name)
        _ = try? store.buildCustomStudySession(
            query: "is:old -is:suspended \(quoted)",
            limit: 100,
            reschedule: false,
            order: "random"
        )
        publish(store)
        WidgetCollectionPing.post()
    }

    @MainActor
    private static func readyStore() async -> CollectionStore? {
        let store = CollectionStore.shared
        guard FileManager.default.fileExists(atPath: store.collectionPath.path) else { return nil }
        if store.db == nil {
            await store.bootstrapIfNeeded()
        } else {
            try? store.reloadMeta()
            try? store.refreshCounts()
        }
        return store.db == nil ? nil : store
    }

    @MainActor
    private static func makeSnapshot(_ store: CollectionStore) -> WidgetStudySnapshot {
        guard let deck = studyDeck(in: store) else { return .empty }
        let counts = store.deckCounts[deck.id] ?? DeckCounts(new: 0, learn: 0, review: 0)
        guard let card = try? store.peekStudyCard(for: deck.id),
              let note = try? store.fetchNote(id: card.nid),
              let notetype = store.notetype(id: note.mid) else {
            return idleSnapshot(store: store, deck: deck, counts: counts)
        }
        let homeID = card.odid != 0 ? card.odid : card.did
        let home = store.deck(id: homeID) ?? deck
        let question = face(note: note, card: card, notetype: notetype, side: .question, store: store)
        let answer = face(note: note, card: card, notetype: notetype, side: .answer, store: store)
        let labels = Scheduler(store: store).intervalLabels(for: card, deck: deck)
        return WidgetStudySnapshot(
            studyDeckID: deck.id,
            deckName: home.displayName,
            cardID: card.id,
            question: question.isEmpty ? note.sfld : question,
            answer: answer,
            newCount: counts.new,
            learnCount: counts.learn,
            reviewCount: counts.review,
            again: labels[.again] ?? "",
            hard: labels[.hard] ?? "",
            good: labels[.good] ?? "",
            easy: labels[.easy] ?? "",
            hasCard: true
        )
    }

    @MainActor
    private static func idleSnapshot(store: CollectionStore, deck: AnkiDeck, counts: DeckCounts) -> WidgetStudySnapshot {
        let congrats = (try? store.congratsState(for: deck.id)) ?? .empty
        let seen = (try? store.seenCardCount(in: deck.id)) ?? 0
        let moreNew = congrats.newRemaining
        let moreReview = congrats.reviewRemaining
        let again = seen > 0
        let title: String
        let detail: String
        if again {
            title = "Por enquanto, é isso"
            detail = "Revise só os cartões que você já estudou."
        } else if moreNew || moreReview {
            title = "Limite de hoje"
            detail = "Ainda há cartões novos, mas o limite diário foi atingido."
        } else if congrats.showsLearnMessage {
            title = "Por enquanto, é isso"
            detail = "O próximo cartão de aprendizagem chega mais tarde hoje."
        } else {
            title = "Nada para estudar agora"
            detail = deck.displayName.isEmpty ? "Você terminou por enquanto." : "\(deck.displayName) está em dia."
        }
        return WidgetStudySnapshot(
            studyDeckID: deck.id,
            deckName: deck.displayName,
            cardID: 0,
            question: "",
            answer: "",
            newCount: counts.new,
            learnCount: counts.learn,
            reviewCount: counts.review,
            again: "",
            hard: "",
            good: "",
            easy: "",
            hasCard: false,
            moreNew: moreNew,
            moreReview: moreReview,
            canStudyAgain: again,
            statusTitle: title,
            statusDetail: detail
        )
    }

    @MainActor
    private static func studyDeck(in store: CollectionStore) -> AnkiDeck? {
        if let id = store.currentDeckID(),
           let deck = store.deck(id: id),
           (store.deckCounts[id]?.total ?? 0) > 0 {
            return deck
        }
        if let recommended = store.recommendedStudyDeck,
           (store.deckCounts[recommended.id]?.total ?? 0) > 0 {
            return recommended
        }
        return idleDeck(in: store)
    }

    @MainActor
    private static func idleDeck(in store: CollectionStore) -> AnkiDeck? {
        if let id = WidgetStudyStore.load()?.snapshot.studyDeckID, let deck = store.deck(id: id) {
            return deck
        }
        if let id = store.currentDeckID(), let deck = store.deck(id: id) {
            return deck
        }
        return store.recommendedStudyDeck ?? store.decks.first { !$0.isFiltered && $0.name != "Default" && $0.name != "Padrão" }
    }

    private static func quotedDeck(_ name: String) -> String {
        let escaped = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "deck:\"\(escaped)\""
    }

    @MainActor
    private static func face(
        note: AnkiNote,
        card: AnkiCard,
        notetype: AnkiNotetype,
        side: CardHTMLRenderer.Side,
        store: CollectionStore
    ) -> String {
        let rendered = CardHTMLRenderer.renderCard(
            note: note,
            card: card,
            notetype: notetype,
            side: side,
            mediaBase: store.mediaRoot,
            deckName: store.deck(id: card.odid != 0 ? card.odid : card.did)?.name ?? ""
        )
        let text = side == .question ? rendered.questionText : rendered.answerText
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= 280 { return collapsed }
        return String(collapsed.prefix(280)) + "…"
    }
}
