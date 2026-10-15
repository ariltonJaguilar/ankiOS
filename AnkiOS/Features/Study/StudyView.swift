import SwiftUI

struct StudyView: View {
    let deck: AnkiDeck
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.dismiss) private var dismiss

    @State private var scheduler: Scheduler?
    @State private var queue: [AnkiCard] = []
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
    @State private var labels: [Rating: String] = [:]
    @State private var startedAt = Date()
    @State private var answeredCount = 0
    @State private var sessionStarted = Date()
    @State private var showCardInfo = false
    @State private var cardInfoText = ""
    @State private var showSetDue = false
    @State private var dueDateText = "1"
    @State private var showReset = false
    @State private var resetRestorePosition = false
    @State private var resetClearCounts = true
    @State private var showDeleteConfirm = false
    @State private var showDeckOptions = false
    @State private var showCustomStudy = false
    @State private var showDescEditor = false
    @State private var showUnburyChoice = false
    @State private var pendingSession: AnkiDeck?
    @State private var sessionDeck: AnkiDeck?
    @State private var congrats = DeckCongrats.empty
    @State private var showCopy = false
    @State private var timeboxMinutes = 0
    @State private var typedAnswer = ""
    @State private var cardDeadline: Date?
    @State private var countdownNow = Date()
    @State private var hasTypeAnswer = false
    @State private var showEdit = false
    @State private var previousCard: AnkiCard?
    @State private var previousNote: AnkiNote?
    @State private var isRecordingVoice = false
    @State private var showAutoAdvance = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                VStack(spacing: 0) {
                    progressBar
                    cardArea
                    controls
                }
            }
            .navigationTitle(deck.displayName)
            .task(id: autoAdvanceToken) { await runAutoAdvance() }
            .sheet(isPresented: $showAutoAdvance) {
                AutoAdvanceSheet()
                    .environmentObject(store)
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheet(isPresented: $showCardInfo) {
                CardInfoView(text: cardInfoText)
            }
            .sheet(isPresented: $showEdit) {
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
            .sheet(isPresented: $showCopy) {
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
            .sheet(isPresented: $showDeckOptions) {
                DeckOptionsView(deck: deck).environmentObject(store)
            }
            .sheet(isPresented: $showCustomStudy, onDismiss: {
                if let pending = pendingSession {
                    pendingSession = nil
                    sessionDeck = pending
                }
                reloadQueue(keepCurrent: false)
            }) {
                CustomStudyView(deck: liveDeck) { pendingSession = $0 }
                    .environmentObject(store)
            }
            .sheet(item: $sessionDeck) { created in
                DeckOverviewView(deck: created).environmentObject(store)
            }
            .sheet(isPresented: $showDescEditor) {
                DeckDescriptionEditor(deck: liveDeck).environmentObject(store)
            }
            .unburyChoice(isPresented: $showUnburyChoice) { queues in
                performUnbury(queues)
            }
            .onChange(of: store.deckConfigs) { _, _ in
                guard scheduler != nil else { return }
                reloadQueue(keepCurrent: true)
            }
            .onChange(of: store.widgetRevision) { _, _ in
                reloadQueue(keepCurrent: false)
            }
            .onChange(of: showEdit) { _, open in
                if !open { refreshCurrentAfterEdit() }
            }
            .onChange(of: showCopy) { _, open in
                if !open { reloadQueue(keepCurrent: true) }
            }
            .alert("Definir data due", isPresented: $showSetDue) {
                TextField("Ex.: 1  ·  0-2  ·  60-90!", text: $dueDateText)
                Button("OK") {
                    guard let id = current?.id,
                          let parsed = CollectionStore.parseDueDateInput(dueDateText) else { return }
                    try? store.setDueDate(
                        cardIDs: [id],
                        minDays: parsed.min,
                        maxDays: parsed.max,
                        updateInterval: parsed.updateInterval
                    )
                    reloadQueue(keepCurrent: false)
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Dias a partir de hoje. Intervalo com hífen. ! no fim também redefine o intervalo das revisões.")
            }
            .sheet(isPresented: $showReset) {
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
                            Button("Repor") {
                                guard let card = current else { return }
                                scheduler?.captureForUndo(card)
                                try? store.resetCards(
                                    [card.id],
                                    restoreOriginalPosition: resetRestorePosition,
                                    clearCounts: resetClearCounts
                                )
                                showReset = false
                                reloadQueue(keepCurrent: false)
                            }
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
            .confirmationDialog("Apagar nota?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Apagar nota", role: .destructive) { deleteNote() }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Apaga a nota e todos os cartões dela. Não dá para desfazer.")
            }
            .background { studyKeyboardShortcuts }
            .onDisappear { store.mediaStore.clearOwnVoice() }
        }
        .task { await setup() }
        .onChange(of: showingAnswer) { _, _ in render() }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { now in
            countdownNow = now
            guard let cardDeadline, !showingAnswer, current != nil else { return }
            if now >= cardDeadline {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    showingAnswer = true
                }
            }
        }
    }

    /// Hidden controls so Space / Enter / 1–4 / R / B / S match desktop Anki.
    @ViewBuilder
    private var studyKeyboardShortcuts: some View {
        Group {
            Button("") { studyPrimaryKeyAction() }
            .keyboardShortcut(.space, modifiers: [])
            Button("") { studyPrimaryKeyAction() }
            .keyboardShortcut(.return, modifiers: [])

            Button("") { if showingAnswer { answer(.again) } }
                .keyboardShortcut("1", modifiers: [])
            Button("") { if showingAnswer { answer(.hard) } }
                .keyboardShortcut("2", modifiers: [])
            Button("") { if showingAnswer { answer(.good) } }
                .keyboardShortcut("3", modifiers: [])
            Button("") { if showingAnswer { answer(.easy) } }
                .keyboardShortcut("4", modifiers: [])

            Button("") {
                if let s = sounds.first { store.mediaStore.play(s) }
            }
            .keyboardShortcut("r", modifiers: [])

            Button("") { buryCard() }
                .keyboardShortcut("b", modifiers: [])
            Button("") { suspendCard() }
                .keyboardShortcut("s", modifiers: [])
            Button("") {
                try? scheduler?.undo(); reloadQueue(keepCurrent: false)
            }
            .keyboardShortcut("z", modifiers: [.command])

            Button("") { showEdit = true }
                .keyboardShortcut("e", modifiers: [])
            Button("") { mark() }
                .keyboardShortcut("*", modifiers: [])
            Button("") { cycleFlag() }
                .keyboardShortcut("@", modifiers: [])
        }
        .opacity(0.001)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }

    private var progressBar: some View {
        HStack(spacing: 10) {
            Button("Fechar") { dismiss() }
                .buttonStyle(GlassChipButtonStyle())
            Text("\(answeredCount) feitos · \(elapsedLabel)")
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
            Button {
                if let s = sounds.first { store.mediaStore.play(s) }
            } label: {
                Image(systemName: "speaker.wave.2.fill")
            }
            .buttonStyle(GlassChipButtonStyle())
            .disabled(sounds.isEmpty)
            .opacity(sounds.isEmpty ? 0.35 : 1)
            if let cardDeadline, !showingAnswer, current != nil {
                let left = max(0, Int(ceil(cardDeadline.timeIntervalSince(countdownNow))))
                Text("\(left)s")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(left <= 3 ? AppTheme.danger : .white.opacity(0.65))
                    .accessibilityLabel("\(left) segundos até revelar")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var showDueCounts: Bool {
        store.conf["dueCounts"] as? Bool ?? true
    }

    private var dueCountChips: some View {
        let c = store.deckCounts[deck.id] ?? .init(new: 0, learn: 0, review: 0)
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
        let s = max(0, Int(countdownNow.timeIntervalSince(startedAt)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var showCardTimer: Bool {
        store.config(for: deck).timer != 0 && current != nil
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
        try? store.unburyDeckTree(deckID: deck.id, queues: queues)
        reloadQueue(keepCurrent: false)
    }

    @ViewBuilder
    private var cardArea: some View {
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
                                if !sounds.isEmpty {
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
                                    .foregroundStyle(Color(red: 0.95, green: 0.98, blue: 0.98))
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
                        onSoundTap: { file in store.mediaStore.play(file) }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) { studyCardBadges }
            .padding(16)
            .glassEffect(.regular.tint(.white.opacity(0.06)), in: .rect(cornerRadius: 28))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
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
        let regions = (questionText.isEmpty ? 0 : 1) + (sounds.isEmpty ? 0 : 1) + (showingAnswer && !answerText.isEmpty ? 1 : 0)
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
                .foregroundStyle(Color(red: 0.95, green: 0.98, blue: 0.98))
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
                if let first = sounds.first { store.mediaStore.play(first) }
            } label: {
                Image(systemName: "play.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .glassEffect(.regular.tint(.white.opacity(0.14)), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reproduzir áudio")
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
        """
        <html><body style="background:transparent;color:#f2fafb;font:22px -apple-system;text-align:center;padding:40px;">
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
                        try? FilteredDeckSupport.rebuild(liveDeck, store: store)
                        reloadQueue(keepCurrent: false)
                    },
                    onEmpty: {
                        try? FilteredDeckSupport.empty(liveDeck, store: store)
                        reloadQueue(keepCurrent: false)
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
                            .glassEffect(.regular.tint(.white.opacity(0.10)), in: .rect(cornerRadius: 14))
                            .padding(.horizontal, 4)
                            .onSubmit { revealAnswer() }
                    }

                    // Anki study bar: Editar · Mostrar resposta · Mais ▾ — same width and height.
                    HStack(spacing: 10) {
                        studyBarButton("Editar", tint: .white, tintStrength: 0.16) { showEdit = true }
                        studyBarButton(hasTypeAnswer ? "Verificar" : "Mostrar resposta", tint: AppTheme.accent, tintStrength: 0.38) {
                            revealAnswer()
                        }
                        moreMenuLabel(tintStrength: 0.16)
                    }
                } else {
                    if hasTypeAnswer, let expected = typeAnswerExpected {
                        let ok = TemplateEngine.typeAnswerMatches(typed: typedAnswer, expected: expected)
                        Text(ok ? "Resposta correta" : "Resposta diferente do esperado")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ok ? AppTheme.good : AppTheme.warn)
                    }
                    HStack(spacing: 10) {
                        answerButton(.again, AppTheme.danger)
                        answerButton(.hard, AppTheme.warn)
                        answerButton(.good, AppTheme.good)
                        answerButton(.easy, AppTheme.easy)
                    }
                    HStack(spacing: 10) {
                        studyBarButton("Editar", tint: .white, tintStrength: 0.16) { showEdit = true }
                        moreMenuLabel(tintStrength: 0.16)
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
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 22)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular.tint(.white.opacity(tintStrength)).interactive(), in: .capsule)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
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
            resetRestorePosition = false
            resetClearCounts = true
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
            if let s = sounds.first { store.mediaStore.play(s) }
        }
        .disabled(sounds.isEmpty)
        Button(store.mediaStore.isPlaying ? "Pausar áudio" : "Continuar áudio", systemImage: "pause.fill") {
            store.mediaStore.pauseOrResume()
        }
        .disabled(sounds.isEmpty && !store.mediaStore.isPlaying)
        Button("Áudio −5s", systemImage: "gobackward.5") { store.mediaStore.seek(by: -5) }
            .disabled(sounds.isEmpty)
        Button("Áudio +5s", systemImage: "goforward.5") { store.mediaStore.seek(by: 5) }
            .disabled(sounds.isEmpty)

        if isRecordingVoice {
            Button("Parar gravação", systemImage: "stop.circle.fill") {
                store.mediaStore.stopRecordingOwnVoice()
                isRecordingVoice = false
            }
        } else {
            Button("Gravar própria voz", systemImage: "mic.fill") {
                store.mediaStore.startRecordingOwnVoice()
                isRecordingVoice = true
            }
        }
        Button("Replay voz própria", systemImage: "waveform") {
            store.mediaStore.replayOwnVoice()
        }
        .disabled(!store.mediaStore.hasOwnVoice)

        Divider()

        Button("Avanço automático…", systemImage: "forward.end") { showAutoAdvance = true }

        Button("Desfazer", systemImage: "arrow.uturn.backward") {
            try? scheduler?.undo(); reloadQueue(keepCurrent: false)
        }
        .disabled(!(scheduler?.canUndo ?? false))

        Menu("Timebox") {
            Button(timeboxMinutes == 0 ? "✓ Desligado" : "Desligado") { timeboxMinutes = 0 }
            Button(timeboxMinutes == 5 ? "✓ 5 min" : "5 min") { timeboxMinutes = 5 }
            Button(timeboxMinutes == 10 ? "✓ 10 min" : "10 min") { timeboxMinutes = 10 }
            Button(timeboxMinutes == 15 ? "✓ 15 min" : "15 min") { timeboxMinutes = 15 }
            Button(timeboxMinutes == 30 ? "✓ 30 min" : "30 min") { timeboxMinutes = 30 }
        }
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
        "\(current?.id ?? 0)-\(showingAnswer)-\(store.conf["autoAdvanceQuestion"] as? Int ?? 0)-\(store.conf["autoAdvanceAnswer"] as? Int ?? 0)"
    }

    private func runAutoAdvance() async {
        guard current != nil else { return }
        let cardID = current?.id
        let questionSeconds = AutoAdvanceSheet.confInt(store.conf["autoAdvanceQuestion"])
        let answerSeconds = AutoAdvanceSheet.confInt(store.conf["autoAdvanceAnswer"])
        let seconds = showingAnswer ? answerSeconds : questionSeconds
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        guard !Task.isCancelled, current?.id == cardID else { return }
        if store.conf["autoAdvanceWaitAudio"] as? Bool ?? true {
            while store.mediaStore.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled, current?.id == cardID else { return }
            }
        }
        guard current?.id == cardID else { return }
        let action = showingAnswer
            ? (store.conf["autoAdvanceAnswerAction"] as? String ?? "good")
            : (store.conf["autoAdvanceQuestionAction"] as? String ?? "show")
        if action == "bury" {
            buryCard()
            return
        }
        if !showingAnswer, action == "show" {
            revealAnswer()
            return
        }
        switch action {
        case "again": answer(.again)
        case "hard": answer(.hard)
        case "easy": answer(.easy)
        case "good": answer(.good)
        default:
            if !showingAnswer { revealAnswer() } else { answer(.good) }
        }
    }

    private func revealAnswer() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            showingAnswer = true
        }
    }

    /// Expected type-answer field value for the current card (when template has {{type:…}}).
    private var typeAnswerExpected: String? {
        guard hasTypeAnswer, let note, let notetype, let current else { return nil }
        let tmpl = notetype.tmpls.first(where: { $0.ord == current.ord }) ?? notetype.tmpls.first
        let fieldName = TemplateEngine.typeAnswerFieldName(in: (tmpl?.qfmt ?? "") + (tmpl?.afmt ?? ""))
        guard let fieldName,
              let idx = notetype.flds.firstIndex(where: { $0.name == fieldName }),
              idx < note.fields.count else { return nil }
        return note.fields[idx]
    }

    private func answerButton(_ rating: Rating, _ color: Color) -> some View {
        Button {
            answer(rating)
        } label: {
            VStack(spacing: 4) {
                if store.conf["estTimes"] as? Bool ?? true {
                    Text(labels[rating] ?? "")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                }
                Text(rating.title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .glassEffect(.regular.tint(color.opacity(0.4)).interactive(), in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private func setup() async {
        scheduler = Scheduler(store: store)
        store.setCurrentDeck(deck.id)
        sessionStarted = Date()
        reloadQueue(keepCurrent: false)
    }

    private func reloadQueue(keepCurrent: Bool) {
        if timeboxMinutes > 0 {
            let elapsed = Date().timeIntervalSince(sessionStarted) / 60
            if elapsed >= Double(timeboxMinutes) {
                current = nil
                note = nil
                return
            }
        }
        let cfg = store.config(for: deck)
        do {
            queue = try store.dueCards(for: deck.id, newLimit: cfg.new.perDay, revLimit: cfg.rev.perDay)
            congrats = queue.isEmpty ? ((try? store.congratsState(for: deck.id)) ?? .empty) : .empty
            if !keepCurrent || current == nil { loadNext() }
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func loadNext() {
        showingAnswer = false
        typedAnswer = ""
        startedAt = Date()
        let timeLim = store.conf["timeLim"] as? Int ?? 0
        cardDeadline = timeLim > 0 ? Date().addingTimeInterval(Double(timeLim)) : nil
        current = queue.first
        guard let card = current else {
            note = nil
            notetype = nil
            html = ""
            faceText = ""
            questionText = ""
            answerText = ""
            prefersNativeFace = false
            cardDeadline = nil
            return
        }
        note = try? store.fetchNote(id: card.nid)
        notetype = note.flatMap { store.notetype(id: $0.mid) }
        if let scheduler, let current {
            labels = scheduler.intervalLabels(for: current, deck: liveDeck)
        }
        render()
        if store.config(for: deck).autoplay, let first = sounds.first {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                store.mediaStore.play(first)
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
            return
        }
        let side: CardHTMLRenderer.Side = showingAnswer ? .answer : .question
        let result = CardHTMLRenderer.renderCard(
            note: note, card: current, notetype: notetype,
            side: side, mediaBase: store.mediaRoot,
            typedAnswer: showingAnswer ? typedAnswer : nil,
            deckName: deck.name,
            omitTypeInput: true
        )
        html = result.html
        faceText = result.plainText
        questionText = result.questionText
        answerText = result.answerText
        prefersNativeFace = result.prefersNativeFace
        sounds = result.sounds
        hasTypeAnswer = result.hasTypeAnswer
        let cfg = store.config(for: deck)
        if showingAnswer, cfg.autoplay {
            if cfg.replayq, let first = sounds.first {
                store.mediaStore.play(first)
            } else if let s = sounds.last {
                store.mediaStore.play(s)
            }
        }
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
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                reloadQueue(keepCurrent: false)
            }
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func refreshCurrentAfterEdit() {
        guard let id = current?.id else { return }
        current = try? store.fetchCard(id: id)
        if let nid = current?.nid {
            note = try? store.fetchNote(id: nid)
            notetype = note.flatMap { store.notetype(id: $0.mid) }
        }
        render()
    }

    private func studyPrimaryKeyAction() {
        if current == nil { return }
        if showingAnswer {
            answer(.good)
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                showingAnswer = true
            }
        }
    }

    private func buryCard() {
        guard let current else { return }
        scheduler?.captureForUndo(current)
        try? store.buryCard(current.id)
        reloadQueue(keepCurrent: false)
    }

    private func buryNote() {
        guard let current else { return }
        try? store.buryNote(nid: current.nid)
        try? store.buryCard(current.id)
        reloadQueue(keepCurrent: false)
    }

    private func suspendCard() {
        guard let current else { return }
        scheduler?.captureForUndo(current)
        try? store.setCardsQueue([current.id], queue: -1)
        reloadQueue(keepCurrent: false)
    }

    private func suspendNote() {
        guard let current else { return }
        try? store.suspendNote(nid: current.nid)
        reloadQueue(keepCurrent: false)
    }

    private func mark() {
        guard let note else { return }
        try? store.toggleMark(note: note)
        self.note = try? store.fetchNote(id: note.id)
    }

    private func setFlag(_ flag: Int) {
        guard let current else { return }
        scheduler?.captureForUndo(current)
        try? store.setCardsFlag([current.id], flag: flag)
        self.current = try? store.fetchCard(id: current.id)
    }

    private func cycleFlag() {
        guard let current else { return }
        let next = (current.flags + 1) % 8
        setFlag(next)
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
        try? store.deleteNotes(ids: [note.id])
        store.mediaStore.clearOwnVoice()
        isRecordingVoice = false
        reloadQueue(keepCurrent: false)
    }
}
