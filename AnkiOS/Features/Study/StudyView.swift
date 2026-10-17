import SwiftUI

struct StudyView: View {
    let deck: AnkiDeck
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var scheduler: Scheduler?
    @State private var queue: [AnkiCard] = []
    @State private var queueCounts: StudyQueues.Counts?
    @State private var current: AnkiCard?
    @State private var note: AnkiNote?
    @State private var notetype: AnkiNotetype?
    @State private var showingAnswer = false
    @State private var html = ""
    @State private var faceText = ""
    @State private var questionText = ""
    @State private var answerText = ""
    @State private var prefersNativeFace = false
    @State private var sounds: [String] = []
    @State private var speech: [CardHTMLRenderer.SpeechRequest] = []
    @State private var questionSounds: [String] = []
    @State private var answerSounds: [String] = []
    @State private var questionSpeech: [CardHTMLRenderer.SpeechRequest] = []
    @State private var answerSpeech: [CardHTMLRenderer.SpeechRequest] = []
    @State private var labels: [Rating: String] = [:]
    @State private var startedAt = Date()
    @State private var timerStoppedAt: Date?
    @State private var answeredCount = 0
    @State private var sessionStarted = Date()
    @State private var timeboxStartedAt = Date()
    @State private var timeboxAnsweredCount = 0
    @State private var timeboxMessage: String?
    @State private var showCardInfo = false
    @State private var cardInfoText = ""
    @State private var showSetDue = false
    @State private var dueDateText = "1"
    @State private var showReset = false
    @State private var resetRestorePosition = false
    @State private var resetClearCounts = false
    @State private var showDeleteConfirm = false
    @State private var showDeckOptions = false
    @State private var showCustomStudy = false
    @State private var showDescEditor = false
    @State private var showUnburyChoice = false
    @State private var pendingSession: AnkiDeck?
    @State private var sessionDeck: AnkiDeck?
    @State private var congrats = DeckCongrats.empty
    @State private var showCopy = false
    @State private var typedAnswer = ""
    @State private var countdownNow = Date()
    @State private var hasTypeAnswer = false
    @State private var showEdit = false
    @State private var previousCard: AnkiCard?
    @State private var previousNote: AnkiNote?
    @State private var isRecordingVoice = false
    @State private var isStartingVoiceRecording = false
    @State private var voiceRecordingTask: Task<Void, Never>?
    @State private var showAutoAdvance = false
    @State private var autoAdvanceActive = false
    @State private var autoAdvanceReminder: String?
    @State private var showTools = false

    var body: some View {
        NavigationStack { studyNavigationContent }
        .task { await setup() }
        .onChange(of: showingAnswer) { _, _ in render() }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { now in
            countdownNow = now
        }
    }

    private var studyNavigationContent: AnyView {
        var view = AnyView(
            ZStack {
                AppBackground()
                VStack(spacing: 0) {
                    progressBar
                    cardArea
                    controls
                }
            }
            .navigationTitle(deck.displayName)
        )
        #if os(iOS)
        view = AnyView(view.navigationBarTitleDisplayMode(.inline))
        #endif
        view = AnyView(view.task(id: autoAdvanceToken) { await runAutoAdvance() })
        view = AnyView(view.sheet(isPresented: $showAutoAdvance) {
            AutoAdvanceSheet(deck: autoAdvanceDeck)
                .environmentObject(store)
        })
        view = AnyView(view.sheet(isPresented: $showTools) { studyToolsSheet })
        view = AnyView(view.overlay(alignment: .top) { autoAdvanceReminderOverlay })
        view = AnyView(view.sheet(isPresented: $showCardInfo) { CardInfoView(text: cardInfoText) })
        view = AnyView(view.sheet(isPresented: $showEdit) { editNoteSheet })
        view = AnyView(view.sheet(isPresented: $showCopy) { copyNoteSheet })
        view = AnyView(view.sheet(isPresented: $showDeckOptions) { deckOptionsSheet })
        view = AnyView(view.sheet(isPresented: $showCustomStudy, onDismiss: customStudyDidDismiss) { customStudySheet })
        view = AnyView(view.sheet(item: $sessionDeck) { created in sessionOverviewSheet(created) })
        view = AnyView(view.sheet(isPresented: $showDescEditor) { descriptionEditorSheet })
        view = AnyView(view.unburyChoice(isPresented: $showUnburyChoice) { queues in
            performUnbury(queues)
        })
        view = AnyView(view.onChange(of: store.deckConfigs) { _, _ in
            guard scheduler != nil else { return }
            reloadQueue(keepCurrent: true)
        })
        view = AnyView(view.onChange(of: store.widgetRevision) { _, _ in
            reloadQueue(keepCurrent: false)
        })
        view = AnyView(view.onChange(of: store.undoRevision) { _, _ in
            reloadQueue(keepCurrent: false)
        })
        view = AnyView(view.onChange(of: showEdit) { _, open in
            if !open { refreshCurrentAfterEdit() }
        })
        view = AnyView(view.onChange(of: showCopy) { _, open in
            if !open { reloadQueue(keepCurrent: true) }
        })
        view = AnyView(view.modifier(StudyTimeboxAlert(
            showSetDue: $showSetDue,
            dueDateText: $dueDateText,
            timeboxMessage: $timeboxMessage,
            onSetDue: setDueDate,
            onContinue: resumeAfterTimebox,
            onEndStudy: {
                timeboxMessage = nil
                dismiss()
            }
        )))
        view = AnyView(view.sheet(isPresented: $showReset) { resetCardSheet })
        view = AnyView(view.modifier(StudyDeleteConfirmation(isPresented: $showDeleteConfirm, onDelete: deleteNote)))
        view = AnyView(view.background { studyKeyboardShortcuts })
        view = AnyView(view.onDisappear {
            voiceRecordingTask?.cancel()
            voiceRecordingTask = nil
            store.mediaStore.clearOwnVoice()
        })
        return view
    }

    @ViewBuilder
    private var studyKeyboardShortcuts: some View {
        Group {
            Button("") { studyPrimaryKeyAction() }
            .keyboardShortcut(.space, modifiers: [])
            Button("") { studyPrimaryKeyAction() }
            .keyboardShortcut(.return, modifiers: [])

            ForEach(Rating.allCases, id: \.rawValue) { rating in
                if let shortcut = reviewKeyboardShortcut(for: rating) {
                    Button("") { if showingAnswer { answer(rating) } }
                        .keyboardShortcut(shortcut)
                }
            }

            Button("") {
                replayCurrentAudio()
            }
            .keyboardShortcut("r", modifiers: [])

            Button("") { buryNote() }
                .keyboardShortcut("=", modifiers: [])
            Button("") { buryCard() }
                .keyboardShortcut("-", modifiers: [])
            Button("") { suspendNote() }
                .keyboardShortcut("!", modifiers: [])
            Button("") { suspendCard() }
                .keyboardShortcut("@", modifiers: [])
            Button("") {
                undoAnswer()
            }
            .keyboardShortcut("z", modifiers: [.command])
            Button("") { redoAnswer() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Button("") { undoAnswer() }
                .keyboardShortcut("u", modifiers: [])

            Button("") { showEdit = true }
                .keyboardShortcut("e", modifiers: [])
            Button("") { showCopy = true }
                .keyboardShortcut("e", modifiers: [.control, .option])
            Button("") { showDeleteConfirm = true }
                .keyboardShortcut(.delete, modifiers: [.control])
            Button("") { forgetCurrentCard() }
                .keyboardShortcut("n", modifiers: [.control, .option])
            Button("") {
                dueDateText = "1"
                showSetDue = true
            }
            .keyboardShortcut("d", modifiers: [.control, .shift])
            Button("") { if current != nil { showDeckOptions = true } }
                .keyboardShortcut("o", modifiers: [])
            Button("") { showInfo() }
                .keyboardShortcut("i", modifiers: [])
            Button("") { showPreviousInfo() }
                .keyboardShortcut("i", modifiers: [.control, .option])
            Button("") { mark() }
                .keyboardShortcut("*", modifiers: [])
            ForEach(1...7, id: \.self) { flag in
                Button("") { toggleFlag(flag) }
                    .keyboardShortcut(KeyEquivalent(Character(String(flag))), modifiers: [.control])
            }
            Button("") { toggleOwnVoiceRecording() }
                .keyboardShortcut("v", modifiers: [.shift])
            Button("") { store.mediaStore.replayOwnVoice() }
                .keyboardShortcut("v", modifiers: [])
            Button("") { store.mediaStore.pauseOrResume() }
                .keyboardShortcut("5", modifiers: [])
            Button("") { store.mediaStore.seek(by: -5) }
                .keyboardShortcut("6", modifiers: [])
            Button("") { store.mediaStore.seek(by: 5) }
                .keyboardShortcut("7", modifiers: [])
            Button("") { autoAdvanceActive.toggle() }
                .keyboardShortcut("a", modifiers: [.shift])
        }
        .opacity(0.001)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }

    private var resetCardSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    GlassOptionRow(title: "Restaurar posição original") {
                        Toggle("", isOn: $resetRestorePosition).labelsHidden().tint(AppTheme.accent)
                    }
                    GlassOptionRow(title: "Zerar reps e lapsos") {
                        Toggle("", isOn: $resetClearCounts).labelsHidden().tint(AppTheme.accent)
                    }
                    Text("Move o cartão para a fila de novos (Esquecer / Repor do Anki).")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .padding(20)
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    Button("Cancelar") { showReset = false }
                        .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.18, expands: true))
                    Button("Repor") { resetCurrentCard() }
                        .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.42, expands: true))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .background(AppBackground())
            .navigationTitle("Repor cartão")
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 280)
        #endif
    }

    private var studyToolsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    moreMenuContent
                }
                .padding(16)
            }
            .background(AppBackground())
            .navigationTitle("Ferramentas")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fechar") { showTools = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var autoAdvanceReminderOverlay: some View {
        if let autoAdvanceReminder {
            Text(verbatim: autoAdvanceReminder)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.primaryText)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .ankiGlass(tint: .white.opacity(0.10), in: Capsule())
                .padding(.top, 12)
        }
    }

    @ViewBuilder
    private var editNoteSheet: some View {
        if let note {
            NavigationStack {
                NoteEditorView(mode: .edit(note.id))
                    .environmentObject(store)
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 480)
            #endif
        }
    }

    @ViewBuilder
    private var copyNoteSheet: some View {
        if let note {
            NavigationStack {
                NoteEditorView(mode: .copy(note.id))
                    .environmentObject(store)
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 480)
            #endif
        }
    }

    private var deckOptionsSheet: some View {
        DeckOptionsView(deck: autoAdvanceDeck)
            .environmentObject(store)
    }

    private func sessionOverviewSheet(_ created: AnkiDeck) -> some View {
        DeckOverviewView(deck: created)
            .environmentObject(store)
    }

    private var descriptionEditorSheet: some View {
        DeckDescriptionEditor(deck: liveDeck)
            .environmentObject(store)
    }

    private var customStudySheet: some View {
        CustomStudyView(deck: liveDeck) { pendingSession = $0 }
            .environmentObject(store)
    }

    private func customStudyDidDismiss() {
        if let pending = pendingSession {
            pendingSession = nil
            sessionDeck = pending
        }
        reloadQueue(keepCurrent: false)
    }

    private func resetCurrentCard() {
        guard let card = current else { return }
        scheduler?.captureForUndo(card)
        do {
            var conf = store.conf
            conf["reviewerForgetRestorePosition"] = resetRestorePosition
            conf["reviewerForgetResetCounts"] = resetClearCounts
            try store.saveConf(conf)
            try store.resetCards(
                [card.id],
                restoreOriginalPosition: resetRestorePosition,
                clearCounts: resetClearCounts
            )
            showReset = false
            reloadQueue(keepCurrent: false)
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func setDueDate() {
        guard let id = current?.id,
              let parsed = CollectionStore.parseDueDateInput(dueDateText) else { return }
        do {
            if let card = try store.fetchCard(id: id) { scheduler?.captureForUndo(card) }
            try store.setDueDate(
                cardIDs: [id],
                minDays: parsed.min,
                maxDays: parsed.max,
                updateInterval: parsed.updateInterval
            )
            reloadQueue(keepCurrent: false)
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private var progressBar: some View {
        HStack(spacing: 10) {
            Button("Fechar") { dismiss() }
                .buttonStyle(GlassChipButtonStyle())
            Text("\(answeredCount) feitos · \(elapsedLabel)")
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(AppTheme.primaryText.opacity(0.75))
            Spacer()
            if showAudioPlayButtons {
                Button {
                    replayCurrentAudio()
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                }
                .buttonStyle(GlassChipButtonStyle())
                .disabled(sounds.isEmpty && speech.isEmpty)
                .opacity(sounds.isEmpty && speech.isEmpty ? 0.35 : 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var showDueCounts: Bool {
        store.conf["dueCounts"] as? Bool ?? true
    }

    private var showAudioPlayButtons: Bool {
        !(store.conf["hideAudioPlayButtons"] as? Bool ?? false)
    }

    private var dueCountChips: some View {
        let c = queueCounts.map { DeckCounts(new: $0.new, learn: $0.learning, review: $0.review) }
            ?? store.deckCounts[deck.id] ?? .init(new: 0, learn: 0, review: 0)
        return HStack(spacing: 8) {
            CountChip(label: "Novo", count: c.new, color: AppTheme.easy)
            CountChip(label: "Aprender", count: c.learn, color: AppTheme.danger)
            CountChip(label: "Revisar", count: c.review, color: AppTheme.good)
        }
    }

    private var elapsedLabel: String {
        let s = Int(Date().timeIntervalSince(sessionStarted))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Anki deck option `timer`: elapsed time on the current card.
    private var cardTimerLabel: String {
        let elapsed = max(0, Int((timerStoppedAt ?? countdownNow).timeIntervalSince(startedAt)))
        let s = min(elapsed, max(currentConfig.maxTaken, 1))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var showCardTimer: Bool {
        currentConfig.timer != 0 && current != nil
    }

    private var currentConfig: AnkiDeckConfig {
        store.config(for: autoAdvanceDeck)
    }

    private var autoAdvanceDeck: AnkiDeck {
        store.deck(id: current?.did ?? deck.id) ?? deck
    }

    private var liveDeck: AnkiDeck {
        store.decks.first { $0.id == deck.id } ?? deck
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
        do {
            scheduler?.captureForUndo(try store.cardsToUnbury(deckID: deck.id, queues: queues))
            try store.unburyDeckTree(deckID: deck.id, queues: queues)
            reloadQueue(keepCurrent: false)
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var cardArea: some View {
        #if os(iOS)
        GeometryReader { proxy in
            cardAreaContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { value in
                        performStudyTap(at: value.location, size: proxy.size)
                    }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 30).onEnded { value in
                        performStudySwipe(value, size: proxy.size)
                    }
                )
        }
        #else
        cardAreaContent
        #endif
    }

    @ViewBuilder
    private var cardAreaContent: some View {
        if current == nil {
            ScrollView {
                DeckFinishedMessage(
                    deck: liveDeck,
                    info: congrats,
                    onCustomStudy: { showCustomStudy = true },
                    onUnbury: requestUnbury
                )
                .padding(.horizontal, 8)
                .padding(.top, 12)
            }
        } else {
            // Question/answer face — same role as Anki's central canvas (e.g. 「あ」 above the bar).
            ZStack {
                if prefersNativeFace && (!questionText.isEmpty || !answerText.isEmpty || !sounds.isEmpty) {
                    ScrollView {
                        VStack(spacing: 0) {
                            if usesFaceSections {
                                if !questionText.isEmpty {
                                    faceSection("Pergunta", text: questionText)
                                }
                                if !sounds.isEmpty && showAudioPlayButtons {
                                    if !questionText.isEmpty { faceDivider }
                                    audioSection
                                }
                                if showingAnswer, !answerText.isEmpty {
                                    if !questionText.isEmpty || !sounds.isEmpty { faceDivider }
                                    faceSection("Resposta", text: answerText)
                                }
                            } else if !questionText.isEmpty {
                                Text(questionText)
                                    .font(.system(size: nativeFaceSize(for: questionText), weight: .regular))
                                    .foregroundStyle(AppTheme.primaryText)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 36)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 8)
                        .padding(.top, 12)
                        .padding(.bottom, 12)
                    }
                    .scrollIndicators(.hidden)
                } else {
                    CardWebView(
                        html: html.isEmpty ? placeholderHTML : html,
                        baseURL: store.mediaRoot,
                        onSoundTap: { file in store.mediaStore.play(file) },
                        onSpeechTap: { request in store.mediaStore.speak(request) }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) { studyCardBadges }
            .padding(16)
            .ankiGlass(tint: .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 28))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func performStudyTap(at point: CGPoint, size: CGSize) {
        guard current != nil, size.width > 0, size.height > 0 else { return }
        let column = min(max(Int(point.x / (size.width / 3)), 0), 2)
        let row = min(max(Int(point.y / (size.height / 3)), 0), 2)
        let zone = ReviewGesturePreferences.zones[row * 3 + column]
        performStudyGestureAction(store.reviewGesturePreferences.action(isAnswerShown: showingAnswer, zone: zone))
    }

    private func performStudySwipe(_ value: DragGesture.Value, size: CGSize) {
        let horizontal = value.translation.width
        let vertical = value.translation.height
        let direction: String
        if abs(horizontal) > abs(vertical) {
            guard abs(horizontal) >= 40 else { return }
            direction = horizontal < 0 ? "left" : "right"
        } else {
            guard abs(vertical) >= 40,
                  (value.startLocation.x <= size.width * 0.1 || value.startLocation.x >= size.width * 0.9) else { return }
            direction = vertical < 0 ? "up" : "down"
        }
        let action = store.reviewGesturePreferences.swipeAction(for: direction)
        performStudyGestureAction(action)
    }

    private func performStudyGestureAction(_ action: ReviewGestureAction) {
        switch action {
        case .none:
            break
        case .showAnswer:
            if !showingAnswer { revealAnswer() }
        case .again:
            if showingAnswer { answer(.again) }
        case .hard:
            if showingAnswer { answer(.hard) }
        case .good:
            if showingAnswer { answer(.good) }
        case .easy:
            if showingAnswer { answer(.easy) }
        case .replayAudio:
            replayCurrentAudio()
        case .undo:
            undoAnswer()
        case .openTools:
            showTools = true
        case .backToDecks:
            dismiss()
        }
    }

    @ViewBuilder
    private var studyCardBadges: some View {
        HStack(spacing: 10) {
            if note?.tagList.contains("marked") == true {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Nota marcada")
            }
            if let flag = current?.flags, flag > 0 {
                Image(systemName: "flag.fill")
                    .foregroundStyle(studyFlagColor(flag))
                    .accessibilityLabel("Bandeira \(flag)")
            }
        }
        .font(.title3)
        .padding(14)
    }

    private func studyFlagColor(_ flag: Int) -> Color {
        switch flag {
        case 1: .red
        case 2: .orange
        case 3: .green
        case 4: .blue
        case 5: .pink
        case 6: .teal
        case 7: .purple
        default: .secondary
        }
    }

    /// Captions appear once the card has more than the question alone.
    private var usesFaceSections: Bool {
        let regions = (questionText.isEmpty ? 0 : 1) + (sounds.isEmpty || !showAudioPlayButtons ? 0 : 1) + (showingAnswer && !answerText.isEmpty ? 1 : 0)
        return regions > 1
    }

    private func faceSection(_ caption: String, text: String) -> some View {
        VStack(spacing: 10) {
            Text(caption)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(text)
                .font(.system(size: sectionFaceSize(for: text), weight: .regular))
                .foregroundStyle(AppTheme.primaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 16)
    }

    private var audioSection: some View {
        VStack(spacing: 10) {
            Text("Áudio")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                replayCurrentAudio()
            } label: {
                Image(systemName: "play.fill")
                    .font(.title3)
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(width: 54, height: 54)
                    .ankiGlass(tint: .white.opacity(0.14), interactive: true, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reproduzir áudio")
            .disabled(sounds.isEmpty && speech.isEmpty)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 16)
    }

    private var faceDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(height: 1)
            .padding(.horizontal, 8)
    }

    private func sectionFaceSize(for text: String) -> CGFloat {
        if text.count <= 2 { return 56 }
        if text.count <= 16 { return 34 }
        return 22
    }

    private func nativeFaceSize(for text: String) -> CGFloat {
        if text.count <= 2 { return 72 }
        if text.count <= 12 { return 48 }
        return 32
    }

    private var placeholderHTML: String {
        let textColor = colorScheme == .dark ? "#f2fafb" : "#182127"
        return """
        <html><body style="background:transparent;color:\(textColor);font:22px -apple-system;text-align:center;padding:40px;">
        Carregando cartão…
        </body></html>
        """
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if current == nil {
                DeckFinishedButtons(
                    info: congrats,
                    onOptions: { showDeckOptions = true },
                    onCustomStudy: { showCustomStudy = true },
                    onDescription: { showDescEditor = true },
                    onUnbury: requestUnbury,
                    onRebuild: {
                        do {
                            try FilteredDeckSupport.rebuild(liveDeck, store: store)
                            reloadQueue(keepCurrent: false)
                        } catch {
                            store.lastError = error.localizedDescription
                        }
                    },
                    onEmpty: {
                        do {
                            try FilteredDeckSupport.empty(liveDeck, store: store)
                            reloadQueue(keepCurrent: false)
                        } catch {
                            store.lastError = error.localizedDescription
                        }
                    }
                )
            } else {
                if showDueCounts {
                    dueCountChips
                }
                if !showingAnswer {
                    // Only when the note template has {{type:…}} (this Hiragana deck does not).
                    if hasTypeAnswer {
                        TextField("Digite a resposta", text: $typedAnswer)
                            .textFieldStyle(.plain)
                            .font(.title3)
                            .multilineTextAlignment(.center)
                            .padding(14)
                            .ankiGlass(tint: .white.opacity(0.10), interactive: true, in: RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal, 4)
                            .onSubmit { revealAnswer() }
                    }

                    // Anki study bar: Editar · Mostrar resposta · Mais ▾ — same width and height.
                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 10) {
                            studyBarButton("Editar", tint: .white, tintStrength: 0.16) { showEdit = true }
                            studyBarButton(hasTypeAnswer ? "Verificar" : "Mostrar resposta", tint: AppTheme.accent, tintStrength: 0.38) {
                                revealAnswer()
                            }
                            moreMenuLabel(tintStrength: 0.16)
                        }
                    }
                } else {
                    if hasTypeAnswer, let expected = typeAnswerExpected {
                        let ok = TemplateEngine.typeAnswerMatches(
                            typed: typedAnswer,
                            expected: expected,
                            config: typeAnswerConfig
                        )
                        Text(ok ? "Resposta correta" : "Resposta diferente do esperado")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ok ? AppTheme.good : AppTheme.warn)
                    }
                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 10) {
                            answerButton(.again, AppTheme.danger)
                            answerButton(.hard, AppTheme.warn)
                            answerButton(.good, AppTheme.good)
                            answerButton(.easy, AppTheme.easy)
                        }
                    }
                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 10) {
                            studyBarButton("Editar", tint: .white, tintStrength: 0.16) { showEdit = true }
                            moreMenuLabel(tintStrength: 0.16)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
        .padding(.top, 8)
    }

    private func studyBarButton(_ title: String, tint: Color, tintStrength: Double, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 22)
        }
        .buttonStyle(GlassButtonStyle(tint: tint, prominent: false, tintStrength: tintStrength, expands: true))
        .frame(maxWidth: .infinity)
    }

    private func moreMenuLabel(tintStrength: Double) -> some View {
        // Anki label is “Mais ▾” — chevron is part of the text; hide system indicator.
        Menu {
            moreMenuContent
        } label: {
            VStack(spacing: 2) {
                Text("Mais ▾")
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if showCardTimer {
                    Text(cardTimerLabel)
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(AppTheme.primaryText.opacity(0.75))
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.primaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 22)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .ankiGlass(tint: .white.opacity(tintStrength), interactive: true, in: Capsule())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .keyboardShortcut("m", modifiers: [])
    }

    /// Mirrors Anki desktop study → More (docs.ankiweb.net/studying.html).
    @ViewBuilder
    private var moreMenuContent: some View {
        Menu("Bandeira do cartão", systemImage: "flag") {
            Button("Sem bandeira", systemImage: current?.flags == 0 ? "checkmark" : "flag") { setFlag(0) }
            flagButton(1, "Vermelho", .red)
            flagButton(2, "Laranja", .orange)
            flagButton(3, "Verde", .green)
            flagButton(4, "Azul", .blue)
            flagButton(5, "Rosa", .pink)
            flagButton(6, "Turquesa", .teal)
            flagButton(7, "Roxo", .purple)
        }

        Button("Ocultar cartão", systemImage: "eye.slash") { buryCard() }
        Button("Ocultar nota", systemImage: "eye.slash.circle") { buryNote() }

        Button("Repor cartão…", systemImage: "arrow.counterclockwise") {
            resetRestorePosition = store.conf["reviewerForgetRestorePosition"] as? Bool ?? false
            resetClearCounts = store.conf["reviewerForgetResetCounts"] as? Bool ?? false
            showReset = true
        }
        Button("Definir data due…", systemImage: "calendar") {
            dueDateText = "1"
            showSetDue = true
        }

        Button("Suspender cartão", systemImage: "pause.circle") { suspendCard() }
        Button("Suspender nota", systemImage: "pause.circle.fill") { suspendNote() }

        Divider()

        Button("Opções…", systemImage: "gearshape") { showDeckOptions = true }
        Button("Info do cartão", systemImage: "info.circle") { showInfo() }
        Button("Info do cartão anterior", systemImage: "info.circle.fill") { showPreviousInfo() }
            .disabled(previousCard == nil || previousNote == nil)

        Button(note?.tagList.contains("marked") == true ? "Desmarcar nota" : "Marcar nota", systemImage: "star") {
            mark()
        }
        Button("Criar cópia…", systemImage: "plus.square.on.square") { showCopy = true }
            .disabled(note == nil)
        Button("Apagar nota", systemImage: "trash", role: .destructive) { showDeleteConfirm = true }
            .disabled(note == nil)

        Divider()

        Button("Replay áudio", systemImage: "speaker.wave.2.fill") {
            replayCurrentAudio()
        }
        .disabled(sounds.isEmpty && speech.isEmpty)
        Button(store.mediaStore.isPlaying ? "Pausar áudio" : "Continuar áudio", systemImage: "pause.fill") {
            store.mediaStore.pauseOrResume()
        }
        .disabled(sounds.isEmpty && speech.isEmpty && !store.mediaStore.isPlaying)
        Button("Áudio −5s", systemImage: "gobackward.5") { store.mediaStore.seek(by: -5) }
        .disabled(sounds.isEmpty)
        Button("Áudio +5s", systemImage: "goforward.5") { store.mediaStore.seek(by: 5) }
        .disabled(sounds.isEmpty)

        if isRecordingVoice {
            Button("Parar gravação", systemImage: "stop.circle.fill") {
                toggleOwnVoiceRecording()
            }
        } else {
            Button("Gravar própria voz", systemImage: "mic.fill") {
                toggleOwnVoiceRecording()
            }
            .disabled(isStartingVoiceRecording)
        }
        Button("Replay voz própria", systemImage: "waveform") {
            store.mediaStore.replayOwnVoice()
        }
        .disabled(!store.mediaStore.hasOwnVoice)

        Divider()

        Button(autoAdvanceActive ? "Parar avanço automático" : "Iniciar avanço automático", systemImage: autoAdvanceActive ? "pause.fill" : "forward.end") {
            autoAdvanceActive.toggle()
        }
        .disabled(
            currentConfig.secondsToShowQuestion == 0 &&
            currentConfig.secondsToShowAnswer == 0
        )
        Button("Configurar avanço automático…", systemImage: "gearshape") { showAutoAdvance = true }

        Button("Desfazer", systemImage: "arrow.uturn.backward") {
            undoAnswer()
        }
        .disabled(!store.canUndoCollectionAction)
        Button("Refazer", systemImage: "arrow.uturn.forward") {
            redoAnswer()
        }
        .disabled(!store.canRedoCollectionAction)

    }

    private func flagButton(_ n: Int, _ title: String, _ color: Color) -> some View {
        Button {
            // Anki toggles: same flag again clears it.
            if current?.flags == n { setFlag(0) } else { setFlag(n) }
        } label: {
            Label {
                Text(current?.flags == n ? "✓ \(title)" : title)
            } icon: {
                Image(systemName: "flag.fill").foregroundStyle(color)
            }
        }
    }

    private var autoAdvanceToken: String {
        let config = currentConfig
        return "\(current?.id ?? 0)-\(showingAnswer)-\(autoAdvanceActive)-\(config.secondsToShowQuestion)-\(config.secondsToShowAnswer)-\(config.questionAction)-\(config.answerAction)-\(config.waitForAudio)"
    }

    private func runAutoAdvance() async {
        guard autoAdvanceActive, current != nil else { return }
        let cardID = current?.id
        let config = currentConfig
        let questionSeconds = config.secondsToShowQuestion
        let answerSeconds = config.secondsToShowAnswer
        let seconds = showingAnswer ? answerSeconds : questionSeconds
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        guard !Task.isCancelled, current?.id == cardID else { return }
        if config.waitForAudio {
            while store.mediaStore.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled, current?.id == cardID else { return }
            }
        }
        guard current?.id == cardID else { return }
        if showingAnswer {
            switch config.answerAction {
            case 0: buryCard()
            case 1: answer(.again)
            case 2: answer(.good)
            case 3: answer(.hard)
            case 4: showAutoAdvanceReminder("Tempo da resposta esgotado")
            default: answer(.good)
            }
        } else {
            if config.questionAction == 0 {
                revealAnswer()
            } else {
                showAutoAdvanceReminder("Tempo da pergunta esgotado")
            }
        }
    }

    private func showAutoAdvanceReminder(_ message: String) {
        autoAdvanceReminder = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            autoAdvanceReminder = nil
        }
    }

    private func revealAnswer() {
        if currentConfig.timer != 0 && currentConfig.stopTimerOnAnswer && timerStoppedAt == nil {
            timerStoppedAt = Date()
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            showingAnswer = true
        }
    }

    /// Expected type-answer field value for the current card (when template has {{type:…}}).
    private var typeAnswerExpected: String? {
        guard hasTypeAnswer, let note, let notetype, let current else { return nil }
        let tmpl = notetype.tmpls.first(where: { $0.ord == current.ord }) ?? notetype.tmpls.first
        guard let config = TemplateEngine.typeAnswerConfig(in: (tmpl?.qfmt ?? "") + (tmpl?.afmt ?? "")),
              let idx = notetype.flds.firstIndex(where: { $0.name == config.fieldName }),
              idx < note.fields.count else { return nil }
        return TemplateEngine.typeAnswerText(note.fields[idx], config: config, clozeOrd: current.ord)
    }

    private var typeAnswerConfig: TemplateEngine.TypeAnswerConfig? {
        guard let notetype, let current else { return nil }
        let tmpl = notetype.tmpls.first(where: { $0.ord == current.ord }) ?? notetype.tmpls.first
        return TemplateEngine.typeAnswerConfig(in: (tmpl?.qfmt ?? "") + (tmpl?.afmt ?? ""))
    }

    private func answerButton(_ rating: Rating, _ color: Color) -> some View {
        Button {
            answer(rating)
        } label: {
            VStack(spacing: 4) {
                if store.conf["estTimes"] as? Bool ?? true {
                    Text(labels[rating] ?? "")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(AppTheme.primaryText.opacity(0.8))
                }
                Text(rating.title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .ankiGlass(tint: color.opacity(0.4), interactive: true, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("study.rating.\(rating.rawValue)")
    }

    private func setup() async {
        scheduler = store.schedulerForStudySession()
        store.setCurrentDeck(deck.id)
        sessionStarted = Date()
        timeboxStartedAt = sessionStarted
        timeboxAnsweredCount = 0
        reloadQueue(keepCurrent: false)
    }

    private func reloadQueue(keepCurrent: Bool) {
        do {
            let queued = try store.queuedStudyCards(for: deck.id)
            queue = queued.cards
            queueCounts = queued.counts
            if queue.isEmpty {
                do { congrats = try store.congratsState(for: deck.id) }
                catch { store.lastError = error.localizedDescription; congrats = .empty }
            } else {
                congrats = .empty
            }
            if !keepCurrent || current == nil { loadNext() }
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func loadNext() {
        showingAnswer = false
        typedAnswer = ""
        startedAt = Date()
        timerStoppedAt = nil
        current = queue.first
        guard let card = current else {
            note = nil
            notetype = nil
            html = ""
            faceText = ""
            questionText = ""
            answerText = ""
            prefersNativeFace = false
            return
        }
        do { note = try store.fetchNote(id: card.nid) }
        catch {
            current = nil
            note = nil
            store.lastError = error.localizedDescription
        }
        notetype = note.flatMap { store.notetype(id: $0.mid) }
        if let scheduler, let current {
            labels = scheduler.intervalLabels(for: current, deck: liveDeck)
        }
        render()
        if currentConfig.autoplay, !sounds.isEmpty || !speech.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                playAutomaticAudio()
            }
        }
    }

    private func render() {
        guard let note, let notetype, let current else {
            html = ""
            faceText = ""
            questionText = ""
            answerText = ""
            prefersNativeFace = false
            hasTypeAnswer = false
            speech = []
            sounds = []
            questionSounds = []
            answerSounds = []
            questionSpeech = []
            answerSpeech = []
            return
        }
        let side: CardHTMLRenderer.Side = showingAnswer ? .answer : .question
        let result = CardHTMLRenderer.renderCard(
            note: note, card: current, notetype: notetype,
            side: side, mediaBase: store.mediaRoot,
            typedAnswer: showingAnswer ? typedAnswer : nil,
            deckName: store.deck(id: current.odid != 0 ? current.odid : current.did)?.name ?? deck.name,
            omitTypeInput: true,
            nightMode: colorScheme == .dark
        )
        html = result.html
        faceText = result.plainText
        questionText = result.questionText
        answerText = result.answerText
        prefersNativeFace = result.prefersNativeFace
        sounds = result.sounds
        speech = result.speech
        questionSounds = result.questionSounds
        answerSounds = result.answerSounds
        questionSpeech = result.questionSpeech
        answerSpeech = result.answerSpeech
        hasTypeAnswer = result.hasTypeAnswer
        let cfg = currentConfig
        if showingAnswer, cfg.autoplay {
            playAutomaticAudio()
        }
    }

    private func playAutomaticAudio() {
        let files = showingAnswer ? answerSounds : questionSounds
        let requests = showingAnswer ? answerSpeech : questionSpeech
        store.mediaStore.play(files, then: requests)
    }

    private func replayCurrentAudio() {
        let cfg = currentConfig
        let files: [String]
        let requests: [CardHTMLRenderer.SpeechRequest]
        if showingAnswer && cfg.replayq {
            files = questionSounds + answerSounds
            requests = questionSpeech + answerSpeech
        } else if showingAnswer {
            files = answerSounds
            requests = answerSpeech
        } else {
            files = questionSounds
            requests = questionSpeech
        }
        store.mediaStore.stop()
        store.mediaStore.play(files, then: requests)
    }

    private func answer(_ rating: Rating) {
        guard let current, let scheduler else { return }
        previousCard = current
        previousNote = note
        store.mediaStore.clearOwnVoice()
        isRecordingVoice = false
        if store.conf["interruptAudio"] as? Bool ?? true {
            store.mediaStore.stop()
        }
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        do {
            try scheduler.answer(card: current, deck: liveDeck, rating: rating, timeTakenMS: ms)
            answeredCount += 1
            timeboxAnsweredCount += 1
            if let message = reachedTimeboxMessage() {
                timeboxMessage = message
            } else {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                    reloadQueue(keepCurrent: false)
                }
            }
        } catch {
            self.current = nil
            note = nil
            store.lastError = error.localizedDescription
        }
    }

    private func reachedTimeboxMessage() -> String? {
        let limit = max(store.conf["timeLim"] as? Int ?? 0, 0)
        guard limit > 0, Date().timeIntervalSince(timeboxStartedAt) > Double(limit) else { return nil }
        let minutes = Int((Double(limit) / 60).rounded())
        return "\(timeboxAnsweredCount) cartões estudados em \(minutes) min."
    }

    private func resumeAfterTimebox() {
        timeboxMessage = nil
        timeboxStartedAt = Date()
        timeboxAnsweredCount = 0
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            reloadQueue(keepCurrent: false)
        }
    }

    private func refreshCurrentAfterEdit() {
        guard let id = current?.id else { return }
        do {
            current = try store.fetchCard(id: id)
            if let nid = current?.nid {
                note = try store.fetchNote(id: nid)
                notetype = note.flatMap { store.notetype(id: $0.mid) }
            }
        } catch {
            store.lastError = error.localizedDescription
        }
        render()
    }

    private func studyPrimaryKeyAction() {
        if current == nil { return }
        if showingAnswer {
            guard store.reviewKeyboardPreferences.spacebarRatesCard else { return }
            answer(.good)
        } else {
            revealAnswer()
        }
    }

    private func reviewKeyboardShortcut(for rating: Rating) -> KeyboardShortcut? {
        let preferences = store.reviewKeyboardPreferences
        guard let value = preferences.answerKeys[rating.rawValue] else { return nil }
        return parseKeyboardShortcut(value)
    }

    private func parseKeyboardShortcut(_ value: String) -> KeyboardShortcut? {
        let parts = value.split(separator: "+").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let keyText = parts.last, !keyText.isEmpty else { return nil }
        var modifiers: EventModifiers = []
        for part in parts.dropLast() {
            switch part.lowercased() {
            case "ctrl", "control": modifiers.insert(.control)
            case "alt", "option": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            case "cmd", "command", "meta": modifiers.insert(.command)
            default: return nil
            }
        }
        let key: KeyEquivalent
        switch keyText.lowercased() {
        case "space": key = .space
        case "return", "enter": key = .return
        case "tab": key = .tab
        case "delete", "backspace": key = .delete
        case "escape", "esc": key = .escape
        default:
            guard keyText.count == 1, let character = keyText.first else { return nil }
            key = KeyEquivalent(character)
        }
        return KeyboardShortcut(key, modifiers: modifiers)
    }

    private func undoAnswer() {
        do {
            try store.undoMostRecentCollectionAction()
            reloadQueue(keepCurrent: false)
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func redoAnswer() {
        do {
            try store.redoMostRecentCollectionAction()
            reloadQueue(keepCurrent: false)
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func buryCard() {
        guard let current else { return }
        scheduler?.captureForUndo(current)
        do {
            try store.buryCard(current.id)
            reloadQueue(keepCurrent: false)
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func buryNote() {
        guard let current else { return }
        do {
            let affected = try store.siblingCardIDs(of: current)
                .compactMap { try store.fetchCard(id: $0) }
                .filter { $0.queue >= 0 }
            scheduler?.captureForUndo(affected)
            try store.buryNote(nid: current.nid)
            reloadQueue(keepCurrent: false)
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func suspendCard() {
        guard let current else { return }
        scheduler?.captureForUndo(current)
        do {
            try store.setCardsQueue([current.id], queue: -1)
            reloadQueue(keepCurrent: false)
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func suspendNote() {
        guard let current else { return }
        do {
            let affected = try store.siblingCardIDs(of: current).compactMap { try store.fetchCard(id: $0) }
            scheduler?.captureForUndo(affected)
            try store.suspendNote(nid: current.nid)
            reloadQueue(keepCurrent: false)
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func mark() {
        guard let note else { return }
        do {
            scheduler?.captureForUndo(note)
            try store.toggleMark(note: note)
            self.note = try store.fetchNote(id: note.id)
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func setFlag(_ flag: Int) {
        guard let current else { return }
        scheduler?.captureForUndo(current)
        do {
            try store.setCardsFlag([current.id], flag: flag)
            self.current = try store.fetchCard(id: current.id)
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func toggleFlag(_ flag: Int) {
        guard let current else { return }
        setFlag(current.flags == flag ? 0 : flag)
    }

    private func toggleOwnVoiceRecording() {
        if isRecordingVoice {
            store.mediaStore.stopRecordingOwnVoice()
            isRecordingVoice = false
            store.mediaStore.replayOwnVoice()
        } else {
            guard !isStartingVoiceRecording else { return }
            isStartingVoiceRecording = true
            voiceRecordingTask = Task {
                defer {
                    isStartingVoiceRecording = false
                    voiceRecordingTask = nil
                }
                do {
                    try await store.mediaStore.startRecordingOwnVoice()
                    guard !Task.isCancelled else {
                        store.mediaStore.clearOwnVoice()
                        return
                    }
                    isRecordingVoice = store.mediaStore.isRecordingOwnVoice
                } catch is CancellationError {
                } catch {
                    store.lastError = error.localizedDescription
                }
            }
        }
    }

    private func forgetCurrentCard() {
        guard let card = current else { return }
        scheduler?.captureForUndo(card)
        do {
            try store.resetCards(
                [card.id],
                restoreOriginalPosition: store.conf["reviewerForgetRestorePosition"] as? Bool ?? false,
                clearCounts: store.conf["reviewerForgetResetCounts"] as? Bool ?? false
            )
            reloadQueue(keepCurrent: false)
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func showInfo() {
        guard let current, let note else { return }
        cardInfoText = store.cardInfoText(current, note: note)
        showCardInfo = true
    }

    private func showPreviousInfo() {
        guard let previousCard, let previousNote else { return }
        cardInfoText = store.cardInfoText(previousCard, note: previousNote)
        showCardInfo = true
    }

    private func deleteNote() {
        guard let note else { return }
        do {
            try store.deleteNotesUndoably(ids: [note.id])
            store.mediaStore.clearOwnVoice()
            isRecordingVoice = false
            reloadQueue(keepCurrent: false)
        } catch {
            store.lastError = error.localizedDescription
        }
    }
}

private struct StudyTimeboxAlert: ViewModifier {
    @Binding var showSetDue: Bool
    @Binding var dueDateText: String
    @Binding var timeboxMessage: String?
    let onSetDue: () -> Void
    let onContinue: () -> Void
    let onEndStudy: () -> Void

    func body(content: Content) -> some View {
        content.alert(title, isPresented: isPresented) {
            alertActions
        } message: {
            Text(verbatim: timeboxMessage ?? "Dias a partir de hoje. Intervalo com hífen. ! no fim também redefine o intervalo das revisões.")
        }
    }

    private var title: String {
        timeboxMessage == nil ? "Definir data due" : "Timebox concluído"
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { showSetDue || timeboxMessage != nil },
            set: { presented in
                guard !presented else { return }
                if timeboxMessage != nil {
                    onContinue()
                } else {
                    showSetDue = false
                }
            }
        )
    }

    @ViewBuilder
    private var alertActions: some View {
        if timeboxMessage != nil {
            Button("Continuar", action: onContinue)
            Button("Encerrar estudo", role: .destructive, action: onEndStudy)
        } else {
            TextField("Ex.: 1  ·  0-2  ·  60-90!", text: $dueDateText)
            Button("OK", action: onSetDue)
            Button("Cancelar", role: .cancel) {}
        }
    }
}

private struct StudyDeleteConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    let onDelete: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog("Apagar nota?", isPresented: $isPresented, titleVisibility: .visible) {
            Button("Apagar nota", role: .destructive, action: onDelete)
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(verbatim: "Apaga a nota e todos os cartões dela. Você poderá desfazer esta ação logo depois.")
        }
    }
}
