import SwiftUI

/// Anki-style deck overview before starting study.
struct DeckOverviewView: View {
    let deck: AnkiDeck
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.dismiss) private var dismiss

    @State private var showStudy = false
    @State private var returnToDeckListAfterStudy = false
    @State private var showCustom = false
    @State private var showOptions = false
    @State private var showDescEditor = false
    @State private var showUnburyChoice = false
    @State private var pendingSession: AnkiDeck?
    @State private var sessionDeck: AnkiDeck?
    @State private var congrats = DeckCongrats.empty
    @State private var queuedCounts: StudyQueues.Counts?

    private var counts: DeckCounts {
        store.deckCounts[deck.id] ?? .init(new: 0, learn: 0, review: 0)
    }

    private var studyCounts: DeckCounts {
        guard let queuedCounts else { return counts }
        return DeckCounts(new: queuedCounts.new, learn: queuedCounts.learning, review: queuedCounts.review)
    }

    private var liveDeck: AnkiDeck {
        store.decks.first { $0.id == deck.id } ?? deck
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if studyCounts.total == 0 {
                            DeckFinishedMessage(
                                deck: liveDeck,
                                info: congrats,
                                onCustomStudy: { showCustom = true },
                                onUnbury: requestUnbury
                            )
                        } else {
                            GlassCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(liveDeck.displayName)
                                        .font(AppTheme.titleFont)
                                        .foregroundStyle(AppTheme.primaryText)
                                    if liveDeck.pathComponents.count > 1 {
                                        Text(liveDeck.name)
                                            .font(.caption)
                                            .foregroundStyle(AppTheme.secondaryText)
                                    }
                                    if liveDeck.isFiltered {
                                        Text("Este é um baralho especial para estudar fora da agenda normal. Os cartões voltarão automaticamente aos seus baralhos originais depois da revisão. Ao excluir esse baralho da lista, todos os cartões restantes voltarão ao baralho original.")
                                            .font(.subheadline)
                                            .foregroundStyle(AppTheme.secondaryText)
                                    } else if !liveDeck.desc.isEmpty {
                                        Text(liveDeck.desc)
                                            .font(.subheadline)
                                            .foregroundStyle(AppTheme.secondaryText)
                                    }
                                }
                            }

                            GlassCard {
                                VStack(spacing: 12) {
                                    countRow("stats.new-cards", studyCounts.new, counts.new - studyCounts.new, AppTheme.easy)
                                    countRow("decks.learn-count", studyCounts.learn, counts.learn - studyCounts.learn, AppTheme.danger)
                                    countRow("Revisar", studyCounts.review, counts.review - studyCounts.review, AppTheme.good)
                                }
                            }

                            Button {
                                showStudy = true
                            } label: {
                                Text("Estudar agora")
                            }
                            .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, expands: true))
                        }

                        DeckFinishedButtons(
                            info: congrats,
                            onOptions: { showOptions = true },
                            onCustomStudy: { showCustom = true },
                            onDescription: { showDescEditor = true },
                            onUnbury: requestUnbury,
                            onRebuild: {
                                do {
                                    try FilteredDeckSupport.rebuild(liveDeck, store: store)
                                    reloadOverviewCounts()
                                }
                                catch { store.lastError = error.localizedDescription }
                            },
                            onEmpty: {
                                do {
                                    try FilteredDeckSupport.empty(liveDeck, store: store)
                                    reloadOverviewCounts()
                                }
                                catch { store.lastError = error.localizedDescription }
                            }
                        )
                    }
                    .padding()
                }
            }
            .navigationTitle(liveDeck.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button("Fechar") { dismiss() }
                    .accessibilityIdentifier("deck.overview.close")
                    .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.18, expands: true))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
            }
            .sheet(isPresented: $showStudy, onDismiss: {
                reloadOverviewCounts()
                reloadCongrats()
                if returnToDeckListAfterStudy {
                    returnToDeckListAfterStudy = false
                    dismiss()
                }
            }) {
                StudyView(deck: deck, onReturnToDecks: {
                    returnToDeckListAfterStudy = true
                    showStudy = false
                }).environmentObject(store)
            }
            .sheet(isPresented: $showCustom, onDismiss: {
                if let pending = pendingSession {
                    pendingSession = nil
                    sessionDeck = pending
                }
                reloadOverviewCounts()
                reloadCongrats()
            }) {
                CustomStudyView(deck: liveDeck) { pendingSession = $0 }
                    .environmentObject(store)
            }
            .sheet(item: $sessionDeck) { created in
                DeckOverviewView(deck: created).environmentObject(store)
            }
            .sheet(isPresented: $showOptions, onDismiss: reloadOverviewCounts) {
                DeckOptionsView(deck: deck).environmentObject(store)
            }
            .onAppear {
                store.setCurrentDeck(deck.id)
                reloadOverviewCounts()
                reloadCongrats()
            }
            .onChange(of: store.deckCounts) { _, _ in
                reloadOverviewCounts()
                reloadCongrats()
            }
            .onChange(of: store.decks) { _, _ in reloadOverviewCounts() }
            .onChange(of: store.deckConfigs) { _, _ in reloadOverviewCounts() }
            .sheet(isPresented: $showDescEditor) {
                DeckDescriptionEditor(deck: liveDeck).environmentObject(store)
            }
            .unburyChoice(isPresented: $showUnburyChoice) { queues in
                performUnbury(queues)
            }
        }
    }

    private func reloadOverviewCounts() {
        if let counts = try? store.queuedStudyCards(for: deck.id, limit: 0).counts {
            queuedCounts = counts
        }
    }

    private func requestUnbury() {
        if let queues = congrats.unburyQueues {
            guard !queues.isEmpty else { return }
            performUnbury(queues)
        } else {
            showUnburyChoice = true
        }
    }

    private func performUnbury(_ queues: Set<Int>) {
        do { try store.unburyDeckTree(deckID: deck.id, queues: queues) }
        catch { store.lastError = error.localizedDescription }
        reloadOverviewCounts()
        reloadCongrats()
    }

    private func reloadCongrats() {
        congrats = (try? store.congratsState(for: deck.id)) ?? .empty
    }

    private func countRow(_ title: LocalizedStringKey, _ value: Int, _ difference: Int, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .ankiShadow(color: color.opacity(0.7), radius: 4)
            Text(title)
                .foregroundStyle(AppTheme.primaryText.opacity(0.92))
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(value)")
                    .font(.title3.monospacedDigit().weight(.bold))
                    .foregroundStyle(color)
                    .ankiShadow(color: color.opacity(0.45), radius: 6)
                if difference != 0 {
                    Text(difference > 0 ? "+\(difference)" : "\(difference)")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(AppTheme.secondaryText)
                        .help("Diferença entre os cartões agendados e os disponíveis para estudo.")
                }
            }
        }
    }
}

/// Anki's finished-deck page: the Portuguese congrats copy and the same actions.
struct DeckFinishedMessage: View {
    let deck: AnkiDeck
    let info: DeckCongrats
    var onCustomStudy: () -> Void
    var onUnbury: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Parabéns! Você terminou este baralho por enquanto.")
                .font(.system(.largeTitle, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            if info.showsLearnMessage {
                Text("\(learnDueSentence) \(learnRemainingSentence)")
                    .font(.body)
                    .foregroundStyle(AppTheme.primaryText.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if info.reviewRemaining {
                Text("O limite de revisão de hoje foi alcançado, porém ainda existem cartões a serem revisados. Para melhorar sua memória, considere aumentar o limite diário nas opções.")
                    .font(.body)
                    .foregroundStyle(AppTheme.primaryText.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if info.newRemaining {
                Text("Há mais novos cartões disponíveis, mas o limite diário foi atingido. Você pode aumentar o limite nas opções, porém, tenha em mente que quanto mais novos cartões você estudar, maior será sua carga de revisão a curto prazo.")
                    .font(.body)
                    .foregroundStyle(AppTheme.primaryText.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if info.buried {
                Text("Um ou mais cartões foram ocultados, e serão mostrados amanhã. Você pode [mostrá-las](anki://unbury) caso queira vê-los imediatamente.")
                    .font(.body)
                    .foregroundStyle(AppTheme.primaryText.opacity(0.92))
                    .tint(Self.link)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !info.isFiltered {
                Text("Se você deseja estudar fora do horário regular, você pode usar o recurso de [estudo personalizado](anki://custom-study).")
                    .font(.body)
                    .foregroundStyle(AppTheme.primaryText.opacity(0.92))
                    .tint(Self.link)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !deck.desc.isEmpty {
                Text(deck.desc)
                    .font(.body)
                    .foregroundStyle(AppTheme.primaryText.opacity(0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(AppTheme.primaryText.opacity(0.18), lineWidth: 1)
                    }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            switch url.host {
            case "custom-study":
                onCustomStudy()
                return .handled
            case "unbury":
                onUnbury()
                return .handled
            default:
                return .discarded
            }
        })
    }

    private var learnDueSentence: String {
        "O próximo cartão de aprendizagem estará pronto em \(Self.span(seconds: info.secsUntilNextLearn))."
    }

    private var learnRemainingSentence: String {
        info.learnCount == 1
            ? "Há um cartão de aprendizagem restante para ser entregue mais tarde hoje."
            : "Há \(info.learnCount) cartões de aprendizagem restantes para serem entregues mais tarde hoje."
    }

    /// Anki `naturalUnit` + the pt-BR time span used in the congrats sentence.
    static func span(seconds: Int) -> String {
        let secs = max(0, seconds)
        if secs < 60 {
            return secs == 1 ? "1 segundo" : "\(secs) segundos"
        }
        if secs < 3_600 {
            let minutes = max(Int((Double(secs) / 60.0).rounded()), 1)
            return minutes == 1 ? "1 minuto" : "\(minutes) minutos"
        }
        let hours = max(Int((Double(secs) / 3_600.0).rounded()), 1)
        return hours == 1 ? "1 hora" : "\(hours) horas"
    }

    static let link = Color(red: 0.45, green: 0.70, blue: 0.98)
}

/// Bottom bar of Anki's deck screen: Opções, Estudo Personalizado, Descrição.
/// Filtered decks use Opções, Recriar and Devolver cartões. Desocultar appears when cards are buried.
struct DeckFinishedButtons: View {
    let info: DeckCongrats
    var onOptions: () -> Void
    var onCustomStudy: () -> Void
    var onDescription: () -> Void
    var onUnbury: () -> Void
    var onRebuild: () -> Void
    var onEmpty: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { buttons(expands: false) }
            VStack(spacing: 10) { buttons(expands: true) }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func buttons(expands: Bool) -> some View {
        barButton("Opções", identifier: "deck.overview.options", expands: expands, action: onOptions)
        if info.isFiltered {
            barButton("Recriar", identifier: "filteredDeck.rebuild", expands: expands, action: onRebuild)
            barButton("Devolver cartões", identifier: "filteredDeck.empty", expands: expands, action: onEmpty)
        } else {
            barButton("Estudo Personalizado", identifier: "deck.overview.customStudy", expands: expands, action: onCustomStudy)
            if info.buried {
                barButton("Desocultar", identifier: "deck.overview.unbury", expands: expands, action: onUnbury)
            }
            barButton("Descrição", identifier: "deck.overview.description", expands: expands, action: onDescription)
        }
    }

    private func barButton(_ title: LocalizedStringKey, identifier: String, expands: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .buttonStyle(GlassButtonStyle(tint: .white, prominent: false, tintStrength: 0.18, expands: expands))
        .accessibilityIdentifier(identifier)
    }
}

extension View {
    /// Anki's unbury prompt, shown only when both bury types are present.
    func unburyChoice(isPresented: Binding<Bool>, apply: @escaping (Set<Int>) -> Void) -> some View {
        confirmationDialog("O que você gostaria de desocultar?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Cartões Ocultados Manualmente") { apply([AnkiCard.Queue.manuallyBuried.rawValue]) }
            Button("Irmãos Ocultados Automaticamente") { apply([AnkiCard.Queue.siblingBuried.rawValue]) }
            Button("Todos os Cartões Ocultos") { apply([-2, -3]) }
            Button("Cancelar", role: .cancel) {}
        }
    }
}

/// Anki's deck description editor.
struct DeckDescriptionEditor: View {
    let deckID: Int64
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(deck: AnkiDeck) {
        deckID = deck.id
        _text = State(initialValue: deck.desc)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(AppTheme.primaryText)
                    .padding(16)
                    .ankiGlass(tint: .white.opacity(0.08), interactive: true, in: RoundedRectangle(cornerRadius: 16))
                    .padding(20)
            }
            .navigationTitle("Descrição")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") { save() }
                }
            }
        }
    }

    private func save() {
        var next = store.decks
        guard let idx = next.firstIndex(where: { $0.id == deckID }) else {
            dismiss()
            return
        }
        next[idx].desc = text
        next[idx].mod = Int64(Date().timeIntervalSince1970)
        do {
            try store.saveDecks(next)
            dismiss()
        } catch {
            store.lastError = error.localizedDescription
        }
    }
}
