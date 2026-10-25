import SwiftUI
import GameController
import PencilKit
import UIKit

struct StudyView: View {
    private enum StudyToolsDestination: String, Identifiable, Hashable {
        case browser
        case addNote
        case noteTypes
        case cardTemplate
        case customStudy
        case deckOptions
        case deckStatistics

        var id: String { rawValue }
    }

    private enum StudyToolsPresentation: Identifiable, Equatable {
        case actions
        case destination(StudyToolsDestination)

        var id: String {
            switch self {
            case .actions: "actions"
            case .destination(let destination): "destination.\(destination.id)"
            }
        }
    }

    let deck: AnkiDeck
    var onReturnToDecks: (() -> Void)? = nil
    @EnvironmentObject private var store: CollectionStore
    @ObservedObject private var mediaStore = CollectionStore.shared.mediaStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("ankios.themeMode", store: SharedProfiles.defaults) private var themeMode = 0

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
    @State private var questionPlayback: [CardHTMLRenderer.PlaybackItem] = []
    @State private var answerPlayback: [CardHTMLRenderer.PlaybackItem] = []
    @State private var interactiveVideoFrames: [CGRect] = []
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
    @State private var copyNoteID: Int64?
    @State private var showCopyAfterToolsDismiss = false
    @State private var typedAnswer = ""
    @State private var countdownNow = Date()
    @State private var hasTypeAnswer = false
    @State private var answerFeedback: Rating?
    @State private var answerFeedbackGeneration = 0
    @State private var lastStudyTapAt: Date?
    @State private var cardPinchZoom: CGFloat = 1
    @GestureState private var liveCardPinchZoom: CGFloat = 1
    @State private var cardPinchGestureActive = false
    @State private var cardPinchGestureStarted = false
    @State private var cardPinchSwipeSuppressionGeneration = 0
    @State private var showEdit = false
    @State private var previousCard: AnkiCard?
    @State private var previousNote: AnkiNote?
    @State private var isRecordingVoice = false
    @State private var isStartingVoiceRecording = false
    @State private var voiceRecordingTask: Task<Void, Never>?
    @State private var showAutoAdvance = false
    @State private var autoAdvanceActive = false
    @State private var autoAdvanceReminder: String?
    @State private var studySceneIsActive = true
    @State private var studyToolsPresentation: StudyToolsPresentation?
    @State private var studyNoteCopyRequest: AddNoteCopyRequest?
    @State private var scratchpadEnabled = false
    @State private var scratchpadSize = 1
    @State private var scratchpadStrokes: [StudyScratchpadStroke] = []
    @State private var scratchpadDrawing = PKDrawing()
    @State private var cardScrollRequest = 0
    @StateObject private var gamepadManager = StudyGamepadManager()
    @State private var cardScrollDirection = 0
    @State private var activeUserActionNumber: Int?
    @State private var activeUserActionScript = ""
    @State private var userActionRequest = 0
    @State private var cardZoom = 1.0
    @State private var frequentStudyActions = StudyToolAction.defaultFrequent
    @State private var editingFrequentStudyActions = false
    @State private var studyTopBarVisible = true
    @State private var studyBottomBarVisible = true
    @State private var scratchpadPreferences = ReviewScratchpadPreferences()

    var body: some View {
        NavigationStack { studyNavigationContent }
        .overlay(alignment: .topLeading) {
            StudyShakeReceiver {
                guard current != nil,
                      studyToolsPresentation == nil,
                      !showAutoAdvance,
                      !isRecordingVoice else { return }
                performStudyGestureAction(store.reviewGesturePreferences.shakeAction)
            }
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .task { await setup() }
        .onAppear { studySceneIsActive = scenePhase == .active }
        .onChange(of: scenePhase) { _, phase in studySceneIsActive = phase == .active }
        .onChange(of: showingAnswer) { _, answerIsShown in
            if answerIsShown, !(store.conf["answerKeepsZoom"] as? Bool ?? false) {
                cardPinchZoom = 1
            }
            render()
        }
        .onChange(of: current?.id) { _, _ in cardPinchZoom = 1 }
        .onChange(of: colorScheme) { _, _ in render() }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { now in
            countdownNow = now
        }
    }

    private var studyNavigationContent: AnyView {
        var view = AnyView(
            ZStack {
                AppBackground()
                VStack(spacing: 0) {
                    if studyTopBarVisible { progressBar }
                    cardArea.overlay(alignment: .topTrailing) {
                        if let answerFeedback {
                            Image(systemName: answerFeedback == .again ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .font(.system(size: 36, weight: .semibold))
                                .foregroundStyle(answerFeedback == .again ? AppTheme.danger : AppTheme.good)
                                .accessibilityLabel(answerFeedback == .again ? "Resposta marcada como novamente" : "Resposta registrada")
                                .accessibilityIdentifier("study.answerFeedback")
                                .padding(18)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    if studyBottomBarVisible {
                        controls
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("study.bottomBar")
                    }
                }
            }
            .navigationTitle(deck.displayName)
        )
        view = AnyView(view.navigationBarTitleDisplayMode(.inline))
        view = AnyView(view.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                let action = store.reviewGesturePreferences.topBarAction
                Button {
                    performStudyGestureAction(action)
                } label: {
                    Image(systemName: action.systemImage)
                }
                .accessibilityLabel(action.title)
                .accessibilityIdentifier("study.topBar.action")
            }
        })
        view = AnyView(view.toolbar(studyTopBarVisible ? .visible : .hidden, for: .navigationBar))
        view = AnyView(view.task(id: autoAdvanceToken) { await runAutoAdvance() })
        view = AnyView(view.sheet(isPresented: $showAutoAdvance) {
            AutoAdvanceSheet(deck: autoAdvanceDeck)
                .environmentObject(store)
        })
        view = AnyView(view.sheet(item: $studyToolsPresentation, onDismiss: studyToolsDidDismiss) { presentation in
            switch presentation {
            case .actions:
                studyToolsSheet
            case .destination(let destination):
                studyToolsDestinationView(destination)
            }
        })
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
            if !open {
                copyNoteID = nil
                reloadQueue(keepCurrent: true)
            }
        })
        view = AnyView(view.onAppear(perform: configureGamepad))
        view = AnyView(view.onChange(of: store.reviewGamepadRevision) { _, _ in configureGamepad() })
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
            gamepadManager.stop()
        })
        return view
    }

    @ViewBuilder
    private var studyKeyboardShortcuts: some View {
        Group {
            Button("") {
                undoAnswer()
            }
            .keyboardShortcut("z", modifiers: [.command])
            Button("") { redoAnswer() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            ForEach(StudyKeyboardShortcutResolver.standard) { shortcut in
                if let keyboardShortcut = keyboardShortcut(for: shortcut) {
                    Button("") { performStudyShortcut(shortcut.action) }
                        .keyboardShortcut(keyboardShortcut)
                }
            }
            ForEach(StudyKeyboardShortcutResolver.korean) { shortcut in
                if let keyboardShortcut = keyboardShortcut(for: shortcut) {
                    Button("") { performStudyShortcut(shortcut.action) }
                        .keyboardShortcut(keyboardShortcut)
                }
            }
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
    }

    private var studyToolsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    GlassFormSection(title: "Ações frequentes") {
                        if frequentStudyActions.isEmpty {
                            Text("Adicione ações da lista abaixo para acessá-las rapidamente.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                        }
                        ForEach(Array(frequentStudyActions.enumerated()), id: \.offset) { index, action in
                            studyToolRow(action, frequent: true, index: index)
                        }
                    }
                    GlassFormSection(title: "Todas as ações") {
                        ForEach(StudyToolAction.allCases.filter { $0 != .deckOptions }) { action in
                            studyToolRow(action, frequent: false, index: nil)
                        }
                    }
                }
                .padding(16)
            }
            .accessibilityIdentifier("study.tools.scroll")
            .background(AppBackground())
            .navigationTitle("Ferramentas")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        adjustCardZoom(by: -0.05)
                    } label: {
                        Image(systemName: "textformat.size.smaller")
                    }
                    .accessibilityLabel("Diminuir tamanho do texto")
                    .accessibilityIdentifier("study.tools.cardZoom.down")
                    .disabled(cardZoom <= 0.7)

                    Text("\(Int((cardZoom * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .accessibilityLabel("Tamanho do texto do cartão")
                        .accessibilityValue("\(Int((cardZoom * 100).rounded()))%")
                        .accessibilityIdentifier("study.tools.cardZoom.value")

                    Button {
                        adjustCardZoom(by: 0.05)
                    } label: {
                        Image(systemName: "textformat.size.larger")
                    }
                    .accessibilityLabel("Aumentar tamanho do texto")
                    .accessibilityIdentifier("study.tools.cardZoom.up")
                    .disabled(cardZoom >= 1.6)
                }
                ToolbarItem(placement: .automatic) {
                    Button(editingFrequentStudyActions ? "Concluído" : "Editar") {
                        editingFrequentStudyActions.toggle()
                    }
                    .accessibilityIdentifier("study.tools.frequent.edit")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fechar", action: closeStudyTools)
                        .accessibilityIdentifier("study.tools.close")
                }
            }
        }
        .onAppear {
            cardZoom = store.conf["cardZoom"] as? Double ?? 1.0
            frequentStudyActions = store.frequentStudyActions
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func studyToolsDestinationView(_ destination: StudyToolsDestination) -> some View {
        switch destination {
        case .browser:
            BrowserView(
                onCreateCopy: {
                    studyNoteCopyRequest = $0
                    studyToolsPresentation = .destination(.addNote)
                },
                onAddNote: {
                    studyNoteCopyRequest = nil
                    studyToolsPresentation = .destination(.addNote)
                },
                onManageNoteTypes: { studyToolsPresentation = .destination(.noteTypes) },
                onClose: closeStudyToolsDestination
            )
            .environmentObject(store)
        case .addNote:
            AddNoteHomeView(copyRequest: $studyNoteCopyRequest, onClose: closeStudyToolsDestination)
                .environmentObject(store)
        case .noteTypes:
            NavigationStack {
                NoteTypesView()
                    .environmentObject(store)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar", action: closeStudyToolsDestination)
                }
            }
        case .cardTemplate:
            if let notetype {
                TemplateEditorView(notetype: notetype)
                    .environmentObject(store)
            }
        case .customStudy:
            CustomStudyView(deck: liveDeck) { pendingSession = $0 }
                .environmentObject(store)
        case .deckOptions:
            DeckOptionsView(deck: liveDeck)
                .environmentObject(store)
        case .deckStatistics:
            StatsHomeView(onClose: closeStudyToolsDestination)
                .environmentObject(store)
        }
    }

    @ViewBuilder
    private func studyToolRow(_ action: StudyToolAction, frequent: Bool, index: Int?) -> some View {
        HStack(spacing: 8) {
            if frequent, editingFrequentStudyActions, let index {
                Button {
                    moveFrequentStudyAction(at: index, by: -1)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .accessibilityLabel("Mover \(action.title) para cima")
                .accessibilityIdentifier("study.tools.frequent.moveUp.\(action.rawValue)")
                .disabled(index == 0)
            }

            Button {
                performStudyToolAction(action)
            } label: {
                Label(action.title, systemImage: action.systemImage)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.12, expands: true))
            .accessibilityIdentifier(frequent ? "study.tools.frequent.\(action.rawValue)" : "study.tools.action.\(action.rawValue)")
            .accessibilityValue(studyToolActionValue(action))
            .disabled(studyToolActionIsDisabled(action))
            .contextMenu {
                if frequent {
                    Button("Remover das ações frequentes", systemImage: "minus.circle") {
                        removeFrequentStudyAction(action)
                    }
                    if let index {
                        Button("Mover para cima", systemImage: "arrow.up") {
                            moveFrequentStudyAction(at: index, by: -1)
                        }
                        .disabled(index == 0)
                        Button("Mover para baixo", systemImage: "arrow.down") {
                            moveFrequentStudyAction(at: index, by: 1)
                        }
                        .disabled(index == frequentStudyActions.count - 1)
                    }
                } else if !frequentStudyActions.contains(action) {
                    Button("Adicionar às ações frequentes", systemImage: "plus.circle") {
                        addFrequentStudyAction(action)
                    }
                }
            }

            if !frequent {
                if frequentStudyActions.contains(action) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.good)
                        .accessibilityLabel("Ação frequente")
                } else {
                    Button {
                        addFrequentStudyAction(action)
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(GlassIconButtonStyle(tint: AppTheme.accent))
                    .accessibilityLabel("Adicionar \(action.title) às ações frequentes")
                    .accessibilityIdentifier("study.tools.add.\(action.rawValue)")
                }
            }

            if frequent, editingFrequentStudyActions, let index {
                Button {
                    moveFrequentStudyAction(at: index, by: 1)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .accessibilityLabel("Mover \(action.title) para baixo")
                .accessibilityIdentifier("study.tools.frequent.moveDown.\(action.rawValue)")
                .disabled(index == frequentStudyActions.count - 1)
                Button(role: .destructive) {
                    removeFrequentStudyAction(action)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .accessibilityLabel("Remover \(action.title) das ações frequentes")
                .accessibilityIdentifier("study.tools.remove.\(action.rawValue)")
            }
        }
        .padding(.vertical, 2)
    }

    private func addFrequentStudyAction(_ action: StudyToolAction) {
        guard !frequentStudyActions.contains(action) else { return }
        frequentStudyActions.append(action)
        store.saveFrequentStudyActions(frequentStudyActions)
    }

    private func removeFrequentStudyAction(_ action: StudyToolAction) {
        frequentStudyActions.removeAll { $0 == action }
        store.saveFrequentStudyActions(frequentStudyActions)
    }

    private func moveFrequentStudyAction(at index: Int, by offset: Int) {
        let destination = index + offset
        guard frequentStudyActions.indices.contains(index), frequentStudyActions.indices.contains(destination) else { return }
        frequentStudyActions.swapAt(index, destination)
        store.saveFrequentStudyActions(frequentStudyActions)
    }

    private func performStudyToolAction(_ action: StudyToolAction) {
        switch action {
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
        case .contextMenu:
            studyToolsPresentation = studyToolsPresentation == .actions ? nil : .actions
        case .add:
            presentStudyAddNote()
        case .browse:
            presentStudyToolsDestination(.browser)
        case .cardTemplate:
            presentStudyToolsDestination(.cardTemplate)
        case .customStudy, .filterCram:
            presentStudyToolsDestination(.customStudy)
        case .deckStatistics:
            presentStudyToolsDestination(.deckStatistics)
        case .decks:
            closeStudyTools()
            if let onReturnToDecks {
                onReturnToDecks()
            } else {
                dismiss()
            }
        case .deckOptions, .studyOptions:
            presentStudyToolsDestination(.deckOptions)
        case .emptyFilteredDeck:
            emptyFilteredStudyDeck()
        case .markAndBury:
            mark()
            buryCard()
        case .markAndSuspend:
            mark()
            suspendCard()
        case .rebuildFilteredDeck:
            rebuildFilteredStudyDeck()
        case .unburyDeck:
            requestUnbury()
        case .scratchpad:
            toggleScratchpad()
        case .scratchpadSize:
            cycleScratchpadSize()
        case .scrollUp:
            scrollStudyCard(direction: -1)
        case .scrollDown:
            scrollStudyCard(direction: 1)
        case .userAction1:
            runUserAction(1)
        case .userAction2:
            runUserAction(2)
        case .userAction3:
            runUserAction(3)
        case .userAction4:
            runUserAction(4)
        case .userAction5:
            runUserAction(5)
        case .userAction6:
            runUserAction(6)
        case .userAction7:
            runUserAction(7)
        case .userAction8:
            runUserAction(8)
        case .redo:
            redoAnswer()
        case .configureAutoAdvance:
            showAutoAdvance = true
        case .toggleTopBar:
            studyTopBarVisible.toggle()
        case .toggleBottomBar:
            studyBottomBarVisible.toggle()
            var conf = store.conf
            conf["showBottomBar"] = studyBottomBarVisible
            do {
                try store.saveConf(conf)
            } catch {
                store.lastError = error.localizedDescription
            }
        case .toggleNightMode:
            let currentlyDark = themeMode == 2 || (themeMode == 0 && colorScheme == .dark)
            themeMode = currentlyDark ? 1 : 2
        default:
            guard let shortcut = StudyKeyboardShortcutAction(rawValue: action.rawValue) else { return }
            performStudyShortcut(shortcut)
        }
    }

    private func studyToolActionValue(_ action: StudyToolAction) -> String {
        switch action {
        case .toggleTopBar:
            studyTopBarVisible ? "Visível" : "Oculta"
        case .toggleBottomBar:
            studyBottomBarVisible ? "Visível" : "Oculta"
        case .toggleNightMode:
            themeMode == 2 || (themeMode == 0 && colorScheme == .dark) ? "Ativado" : "Desativado"
        case .scratchpad:
            scratchpadEnabled ? "Ativado" : "Desativado"
        case .scratchpadSize:
            ["Pequeno", "Médio", "Grande"][min(max(scratchpadSize, 0), 2)]
        case .scrollUp, .scrollDown:
            "Comando \(cardScrollRequest)"
        case .browse:
            studyToolsPresentation == .destination(.browser) ? "Aberto" : ""
        case .add:
            studyToolsPresentation == .destination(.addNote) ? "Aberto" : ""
        default:
            ""
        }
    }

    private func studyToolActionIsDisabled(_ action: StudyToolAction) -> Bool {
        switch action {
        case .showAnswer:
            current == nil || showingAnswer
        case .again, .hard, .good, .easy:
            current == nil || !showingAnswer
        case .edit, .buryNote, .buryCard, .suspendNote, .suspendCard, .mark, .markAndBury,
             .markAndSuspend, .deleteNote, .createCopy, .setDueDate, .forgetCard, .replayOwnVoice,
             .recordOwnVoice, .cardInfo, .scratchpad, .scrollUp, .scrollDown,
             .userAction1, .userAction2, .userAction3, .userAction4,
             .userAction5, .userAction6, .userAction7, .userAction8:
            current == nil
        case .scratchpadSize:
            current == nil
        case .cardTemplate:
            notetype == nil
        case .previousCardInfo:
            previousCard == nil
        case .emptyFilteredDeck, .rebuildFilteredDeck:
            !liveDeck.isFiltered
        default:
            false
        }
    }

    private func presentStudyAddNote(copyRequest: AddNoteCopyRequest? = nil) {
        studyNoteCopyRequest = copyRequest
        presentStudyToolsDestination(.addNote)
    }

    private func presentStudyToolsDestination(_ destination: StudyToolsDestination) {
        studyToolsPresentation = .destination(destination)
    }

    private func closeStudyToolsDestination() {
        studyToolsPresentation = nil
        studyNoteCopyRequest = nil
    }

    private func rebuildFilteredStudyDeck() {
        guard liveDeck.isFiltered else { return }
        do {
            try FilteredDeckSupport.rebuild(liveDeck, store: store)
            reloadQueue(keepCurrent: false)
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func emptyFilteredStudyDeck() {
        guard liveDeck.isFiltered else { return }
        do {
            try FilteredDeckSupport.empty(liveDeck, store: store)
            reloadQueue(keepCurrent: false)
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func toggleScratchpad() {
        guard let notetype else { return }
        scratchpadEnabled.toggle()
        SharedProfiles.defaults.set(scratchpadEnabled, forKey: scratchpadPreferenceKey(notetypeID: notetype.id))
        if !scratchpadEnabled { scratchpadStrokes.removeAll() }
        if !scratchpadEnabled { scratchpadDrawing = PKDrawing() }
    }

    private func cycleScratchpadSize() {
        scratchpadSize = (scratchpadSize + 1) % 3
        SharedProfiles.defaults.set(scratchpadSize, forKey: scratchpadSizePreferenceKey)
    }

    private func scratchpadPreferenceKey(notetypeID: Int64) -> String {
        "ankios.study.scratchpad.\(store.activeProfile).\(notetypeID)"
    }

    private var scratchpadSizePreferenceKey: String {
        "ankios.study.scratchpadSize.\(store.activeProfile)"
    }

    private func scrollStudyCard(direction: Int) {
        guard current != nil else { return }
        cardScrollDirection = direction
        cardScrollRequest += 1
    }

    private func runUserAction(_ number: Int) {
        guard current != nil,
              store.studyUserActionScripts.indices.contains(number - 1) else { return }
        let script = store.studyUserActionScripts[number - 1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return }
        activeUserActionNumber = number
        activeUserActionScript = script
        userActionRequest += 1
    }

    private func closeStudyTools() {
        studyToolsPresentation = nil
        studyNoteCopyRequest = nil
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
        }
    }

    @ViewBuilder
    private var copyNoteSheet: some View {
        if let copyNoteID {
            NavigationStack {
                NoteEditorView(mode: .copy(copyNoteID))
                    .environmentObject(store)
            }
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

    private func studyToolsDidDismiss() {
        customStudyDidDismiss()
        guard showCopyAfterToolsDismiss else { return }
        showCopyAfterToolsDismiss = false
        showCopy = true
    }

    private func requestStudyCopy() {
        guard let note else { return }
        copyNoteID = note.id
        if studyToolsPresentation == .actions {
            showCopyAfterToolsDismiss = true
            closeStudyTools()
        } else {
            showCopy = true
        }
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
                .accessibilityIdentifier("study.close")
                .buttonStyle(GlassChipButtonStyle())
            Text("\(answeredCount) feitos · \(elapsedLabel)")
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(AppTheme.primaryText.opacity(0.75))
                .accessibilityIdentifier("study.progress")
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

    private var showStudyAnswerButtons: Bool {
        store.conf["showAnswerButtons"] as? Bool ?? true
    }

    private var showAudioPlayButtons: Bool {
        !(store.conf["hideAudioPlayButtons"] as? Bool ?? false)
    }

    private var scratchpadBelowButtons: Bool {
        scratchpadPreferences.belowButtons
    }

    private var showToolsOverlayButton: Bool {
        let isEnabled = store.conf["showToolsOverlayButton"] as? Bool ?? true
        let topBarAlreadyOpensTools = studyTopBarVisible && store.reviewGesturePreferences.topBarAction == .openTools
        return isEnabled && !topBarAlreadyOpensTools
    }

    private var toolsOverlayButtonOnLeft: Bool {
        store.conf["toolsOverlayButtonOnLeft"] as? Bool ?? false
    }

    private var dueCountChips: some View {
        let c = queueCounts.map { DeckCounts(new: $0.new, learn: $0.learning, review: $0.review) }
            ?? store.deckCounts[deck.id] ?? .init(new: 0, learn: 0, review: 0)
        return HStack(spacing: 8) {
            CountChip(label: "stats.new-cards", count: c.new, color: AppTheme.easy)
            CountChip(label: "decks.learn-count", count: c.learn, color: AppTheme.danger)
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
        do {
            let currentCongrats = try store.congratsState(for: deck.id)
            if let queues = currentCongrats.unburyQueues {
                guard !queues.isEmpty else { return }
                performUnbury(queues)
            } else {
                showUnburyChoice = true
            }
        } catch {
            store.lastError = error.localizedDescription
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
        GeometryReader { proxy in
            cardAreaContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(displayedCardPinchZoom)
                .clipped()
                .contentShape(Rectangle())
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { value in
                        performStudyTap(
                            at: value.location,
                            globalOrigin: proxy.frame(in: .global).origin,
                            size: proxy.size
                        )
                    }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 30).onEnded { value in
                        performStudySwipe(value, size: proxy.size)
                    }
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .updating($liveCardPinchZoom) { value, state, _ in
                            state = scratchpadEnabled ? 1 : value.magnification
                        }
                        .onChanged { value in
                            guard !scratchpadEnabled, abs(value.magnification - 1) > 0.01 else { return }
                            if !cardPinchGestureStarted {
                                cardPinchSwipeSuppressionGeneration &+= 1
                                cardPinchGestureStarted = true
                            }
                            cardPinchGestureActive = true
                        }
                        .onEnded { value in
                            guard !scratchpadEnabled else { return }
                            cardPinchZoom = min(max(cardPinchZoom * value.magnification, 1), 4)
                            cardPinchGestureStarted = false
                            let generation = cardPinchSwipeSuppressionGeneration
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(250))
                                guard generation == cardPinchSwipeSuppressionGeneration else { return }
                                cardPinchGestureActive = false
                            }
                        }
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("study.cardArea")
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
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                Color.clear.frame(height: 1).id("study.nativeFace.top")
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
                                Color.clear.frame(height: 1).id("study.nativeFace.bottom")
                            }
                        }
                        .scrollIndicators(.hidden)
                        .onChange(of: cardScrollRequest) { _, _ in
                            let atTop = cardScrollDirection < 0
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(atTop ? "study.nativeFace.top" : "study.nativeFace.bottom", anchor: atTop ? .top : .bottom)
                            }
                        }
                    }
                } else {
                    CardWebView(
                        html: html.isEmpty ? placeholderHTML : html,
                        baseURL: store.mediaRoot,
                        onSoundTap: { file in store.mediaStore.play(file) },
                        onSpeechTap: { request in store.mediaStore.speak(request) },
                        onVideoFramesChanged: { interactiveVideoFrames = $0 },
                        scrollRequest: cardScrollRequest,
                        scrollDirection: cardScrollDirection,
                        userActionRequest: userActionRequest,
                        userActionNumber: activeUserActionNumber,
                        userActionScript: activeUserActionScript
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) { studyCardTopControls }
            .overlay(alignment: .top) {
                if scratchpadEnabled && !scratchpadBelowButtons {
                    scratchpadPanel
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(16)
            .ankiGlass(tint: .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 28))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var studyCardTopControls: some View {
        HStack(alignment: .top, spacing: 8) {
            if showToolsOverlayButton && toolsOverlayButtonOnLeft {
                studyToolsOverlayButton
            }
            Spacer(minLength: 0)
            studyCardBadges
            if showToolsOverlayButton && !toolsOverlayButtonOnLeft {
                studyToolsOverlayButton
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    private var studyToolsOverlayButton: some View {
        Button {
            studyToolsPresentation = .actions
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(GlassIconButtonStyle(tint: AppTheme.accent))
        .accessibilityLabel("Ferramentas")
        .accessibilityIdentifier("study.tools.overlay")
    }

    private func performStudyTap(at point: CGPoint, globalOrigin: CGPoint, size: CGSize) {
        guard current != nil, !scratchpadEnabled, size.width > 0, size.height > 0 else { return }
        let globalPoint = CGPoint(x: point.x + globalOrigin.x, y: point.y + globalOrigin.y)
        guard !interactiveVideoFrames.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(globalPoint) }) else { return }
        if store.conf["doubleTapPrevention"] as? Bool ?? false,
           let lastStudyTapAt,
           Date().timeIntervalSince(lastStudyTapAt) < (store.conf["doubleTapPreventionDelay"] as? Double ?? 0.3) {
            self.lastStudyTapAt = Date()
            return
        }
        lastStudyTapAt = Date()
        let column = min(max(Int(point.x / (size.width / 3)), 0), 2)
        let row = min(max(Int(point.y / (size.height / 3)), 0), 2)
        let zone = ReviewGesturePreferences.zones[row * 3 + column]
        performStudyGestureAction(store.reviewGesturePreferences.action(isAnswerShown: showingAnswer, zone: zone))
    }

    private func performStudySwipe(_ value: DragGesture.Value, size: CGSize) {
        guard !scratchpadEnabled, !cardPinchGestureActive else { return }
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

    private var scratchpadPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Label("mobile.scratchpad.name", systemImage: "pencil.and.outline")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                Spacer(minLength: 0)
                Button {} label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.caption.weight(.semibold))
                        .frame(width: 30, height: 30)
                }
                .accessibilityLabel("Desfazer traço")
                .accessibilityIdentifier("study.scratchpad.undo")
                .highPriorityGesture(
                    LongPressGesture(minimumDuration: 1)
                        .exclusively(before: TapGesture())
                        .onEnded { result in
                            switch result {
                            case .first(true):
                                if scratchpadPreferences.undoClearsAll {
                                    undoScratchpadStroke()
                                } else {
                                    clearScratchpad()
                                }
                            case .second:
                                if scratchpadPreferences.undoClearsAll {
                                    clearScratchpad()
                                } else {
                                    undoScratchpadStroke()
                                }
                            default:
                                break
                            }
                        }
                )
            }
            scratchpadCanvas
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .frame(height: [130.0, 200.0, 270.0][min(max(scratchpadSize, 0), 2)])
        .ankiGlass(tint: AppTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("study.scratchpad")
    }

    @ViewBuilder
    private var scratchpadCanvas: some View {
        StudyPencilScratchpadCanvas(drawing: $scratchpadDrawing, ignoreFingers: scratchpadPreferences.ignoreFingers)
            .accessibilityIdentifier("study.scratchpad.canvas")
            .accessibilityLabel(scratchpadPreferences.ignoreFingers ? "Área do bloco de escrita, somente Apple Pencil" : "Área do bloco de escrita, toque ou Apple Pencil")
            .accessibilityValue("\(scratchpadDrawing.strokes.count) traços")
    }

    private func undoScratchpadStroke() {
        guard !scratchpadDrawing.strokes.isEmpty else { return }
        scratchpadDrawing = PKDrawing(strokes: Array(scratchpadDrawing.strokes.dropLast()))
    }

    private func clearScratchpad() {
        scratchpadDrawing = PKDrawing()
    }

    private func performStudyGestureAction(_ action: ReviewGestureAction) {
        switch action {
        case .none:
            break
        case .openTools:
            studyToolsPresentation = .actions
        case .backToDecks:
            dismiss()
        default:
            guard let toolAction = StudyToolAction(rawValue: action.rawValue) else { return }
            performStudyToolAction(toolAction)
        }
    }

    private func configureGamepad() {
        gamepadManager.configure(
            preferences: store.reviewGamepadPreferences,
            onAction: { action in performStudyGestureAction(action) },
            onScroll: { direction in scrollStudyCard(direction: direction) }
        )
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
        let base: CGFloat
        if text.count <= 2 { base = 56 }
        else if text.count <= 16 { base = 34 }
        else { base = 22 }
        return base * cardZoom
    }

    private func nativeFaceSize(for text: String) -> CGFloat {
        let base: CGFloat
        if text.count <= 2 { base = 72 }
        else if text.count <= 12 { base = 48 }
        else { base = 32 }
        return base * cardZoom
    }

    private func adjustCardZoom(by delta: Double) {
        let updatedZoom = min(max(cardZoom + delta, 0.7), 1.6)
        var config = store.conf
        config["cardZoom"] = updatedZoom
        do {
            try store.saveConf(config)
            cardZoom = updatedZoom
            render()
        } catch {
            store.lastError = error.localizedDescription
        }
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
                if showDueCounts && !showingAnswer {
                    dueCountChips
                }
                if !showingAnswer {
                    // Only when the note template has {{type:…}} (this Hiragana deck does not).
                    if typeAnswerInputEnabled {
                        TextField("Digite a resposta", text: $typedAnswer)
                            .textFieldStyle(.plain)
                            .font(.title3)
                            .multilineTextAlignment(.center)
                            .padding(14)
                            .ankiGlass(tint: .white.opacity(0.10), interactive: true, in: RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal, 4)
                            .onSubmit { revealAnswer() }
                    }

                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 10) {
                            studyBarButton(typeAnswerInputEnabled ? "Verificar" : "Mostrar resposta", tint: AppTheme.accent, tintStrength: 0.38, identifier: "study.revealAnswer") {
                                revealAnswer()
                            }
                            moreMenuLabel(tintStrength: 0.16)
                        }
                    }
                } else {
                    if typeAnswerInputEnabled, let expected = typeAnswerExpected {
                        let ok = TemplateEngine.typeAnswerMatches(
                            typed: typedAnswer,
                            expected: expected,
                            config: typeAnswerConfig
                        )
                        Text(ok ? "Resposta correta" : "Resposta diferente do esperado")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ok ? AppTheme.good : AppTheme.warn)
                    }
                    if showStudyAnswerButtons {
                        GlassEffectContainer(spacing: 10) {
                            HStack(spacing: 10) {
                                answerButton(.again, AppTheme.danger)
                                answerButton(.hard, AppTheme.warn)
                                answerButton(.good, AppTheme.good)
                                answerButton(.easy, AppTheme.easy)
                            }
                        }
                    }
                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 10) {
                            moreMenuLabel(tintStrength: 0.16)
                        }
                    }
                }
            }
            if current != nil && scratchpadEnabled && scratchpadBelowButtons {
                scratchpadPanel
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
        .padding(.top, 8)
    }

    private func studyBarButton(_ title: String, tint: Color, tintStrength: Double, identifier: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 22)
        }
        .buttonStyle(GlassButtonStyle(tint: tint, prominent: false, tintStrength: tintStrength, expands: true))
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier(identifier ?? "study.action.\(title)")
    }

    private func moreMenuLabel(tintStrength: Double) -> some View {
        // Anki label is “Mais ▾” — chevron is part of the text; hide system indicator.
        Menu {
            moreMenuContent
        } label: {
            VStack(spacing: 2) {
                HStack(spacing: 0) {
                    Text("study.more")
                    Text(verbatim: " ▾")
                }
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
        .accessibilityIdentifier("study.moreMenu")
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

        Button("study.edit", systemImage: "pencil") { showEdit = true }
            .accessibilityIdentifier("study.edit")
        Button("Opções…", systemImage: "gearshape") { showDeckOptions = true }
        Button("Info do cartão", systemImage: "info.circle") { showInfo() }
        Button("Info do cartão anterior", systemImage: "info.circle.fill") { showPreviousInfo() }
            .disabled(previousCard == nil || previousNote == nil)

        Button(note?.tagList.contains("marked") == true ? "Desmarcar nota" : "Marcar nota", systemImage: "star") {
            mark()
        }
        Button("study.create-copy", systemImage: "plus.square.on.square") { requestStudyCopy() }
            .disabled(note == nil)
        Button("Apagar nota", systemImage: "trash", role: .destructive) { showDeleteConfirm = true }
            .disabled(note == nil)

        Divider()

        Button("Replay áudio", systemImage: "speaker.wave.2.fill") {
            replayCurrentAudio()
        }
        .disabled(sounds.isEmpty && speech.isEmpty)
        Button(mediaStore.isPlaying ? "Pausar áudio" : "Continuar áudio", systemImage: "pause.fill") {
            store.mediaStore.pauseOrResume()
        }
        .accessibilityIdentifier("study.audio.toggle")
        .disabled(sounds.isEmpty && speech.isEmpty && !mediaStore.isPlaying)
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
        .accessibilityIdentifier("study.audio.ownVoice.replay")
        .disabled(!store.mediaStore.hasOwnVoice)

        Divider()

        Button(autoAdvanceActive ? "Parar avanço automático" : "Iniciar avanço automático", systemImage: autoAdvanceActive ? "pause.fill" : "forward.end") {
            autoAdvanceActive.toggle()
        }
        .accessibilityIdentifier("study.autoAdvance.toggle")
        .disabled(
            currentConfig.secondsToShowQuestion == 0 &&
            currentConfig.secondsToShowAnswer == 0
        )
        Button("Configurar avanço automático…", systemImage: "gearshape") { showAutoAdvance = true }
            .accessibilityIdentifier("study.autoAdvance.configure")

        Button("Desfazer", systemImage: "arrow.uturn.backward") {
            undoAnswer()
        }
        .accessibilityIdentifier("study.undo")
        .disabled(!store.canUndoCollectionAction)
        Button("Refazer", systemImage: "arrow.uturn.forward") {
            redoAnswer()
        }
        .disabled(!store.canRedoCollectionAction)

    }

    private func flagButton(_ n: Int, _ title: LocalizedStringKey, _ color: Color) -> some View {
        Button {
            // Anki toggles: same flag again clears it.
            if current?.flags == n { setFlag(0) } else { setFlag(n) }
        } label: {
            Label {
                if current?.flags == n {
                    HStack(spacing: 4) {
                        Text("✓")
                        Text(title)
                    }
                } else {
                    Text(title)
                }
            } icon: {
                Image(systemName: "flag.fill").foregroundStyle(color)
            }
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier("study.flag.option.\(n)")
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
        guard let delayMilliseconds = AutoAdvanceActionResolver.delayMilliseconds(seconds) else { return }
        try? await Task.sleep(nanoseconds: UInt64(delayMilliseconds) * 1_000_000)
        guard !Task.isCancelled, current?.id == cardID else { return }
        while AutoAdvanceActionResolver.shouldSkipAutoAdvanceForAudio(
            waitForAudio: config.waitForAudio,
            hasUnfinishedPlayback: store.mediaStore.hasUnfinishedPlayback
        ) {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, current?.id == cardID else { return }
        }
        guard current?.id == cardID else { return }
        guard AutoAdvanceActionResolver.shouldAdvance(
            autoAdvanceEnabled: autoAdvanceActive,
            isWindowFocused: studySceneIsActive
        ) else {
            autoAdvanceActive = false
            return
        }
        if showingAnswer {
            switch AutoAdvanceActionResolver.answer(config.answerAction) {
            case .buryCard: buryCard()
            case .answerAgain: answer(.again)
            case .answerGood: answer(.good)
            case .answerHard: answer(.hard)
            case .showReminder: showAutoAdvanceReminder("Tempo da resposta esgotado")
            }
        } else {
            switch AutoAdvanceActionResolver.question(config.questionAction) {
            case .showAnswer:
                revealAnswer()
            case .showReminder:
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
        guard let note, let notetype, let current else { return nil }
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

    private var typeAnswerInputEnabled: Bool {
        hasTypeAnswer && !(store.conf["neverTypeAnswer"] as? Bool ?? false)
    }

    private var displayedCardPinchZoom: CGFloat {
        min(max(cardPinchZoom * liveCardPinchZoom, 1), 4)
    }

    @ViewBuilder
    private func answerButton(_ rating: Rating, _ color: Color) -> some View {
        let button = Button {
            answer(rating)
        } label: {
            VStack(spacing: 4) {
                if store.conf["estTimes"] as? Bool ?? true {
                    Text(labels[rating] ?? "")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(AppTheme.primaryText.opacity(0.8))
                }
                Text(rating.localizedTitle)
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
        if let shortcut = reviewKeyboardShortcut(for: rating) {
            button.keyboardShortcut(shortcut)
        } else {
            button
        }
    }

    private func setup() async {
        scheduler = store.schedulerForStudySession()
        store.setCurrentDeck(deck.id)
        scratchpadPreferences = store.reviewScratchpadPreferences
        studyBottomBarVisible = store.conf["showBottomBar"] as? Bool ?? true
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
        scratchpadStrokes.removeAll()
        scratchpadDrawing = PKDrawing()
        current = queue.first
        guard let card = current else {
            note = nil
            notetype = nil
            scratchpadEnabled = false
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
        if let notetype {
            scratchpadEnabled = SharedProfiles.defaults.bool(forKey: scratchpadPreferenceKey(notetypeID: notetype.id))
            scratchpadSize = (SharedProfiles.defaults.object(forKey: scratchpadSizePreferenceKey) as? Int).map { min(max($0, 0), 2) } ?? 1
        } else {
            scratchpadEnabled = false
        }
        if let scheduler, let current {
            labels = scheduler.intervalLabels(for: current, deck: liveDeck)
        }
        render()
        if currentConfig.autoplay, !sounds.isEmpty || !speech.isEmpty {
            playAutomaticAudio()
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
            questionPlayback = []
            answerPlayback = []
            return
        }
        let side: CardHTMLRenderer.Side = showingAnswer ? .answer : .question
        let renderedTypedAnswer: String?
        if showingAnswer {
            renderedTypedAnswer = (store.conf["neverTypeAnswer"] as? Bool ?? false)
                ? typeAnswerExpected
                : typedAnswer
        } else {
            renderedTypedAnswer = nil
        }
        let result = CardHTMLRenderer.renderCard(
            note: note, card: current, notetype: notetype,
            side: side, mediaBase: store.mediaRoot,
            typedAnswer: renderedTypedAnswer,
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
        questionPlayback = result.questionPlayback
        answerPlayback = result.answerPlayback
        hasTypeAnswer = result.hasTypeAnswer
        let cfg = currentConfig
        if showingAnswer, cfg.autoplay {
            playAutomaticAudio()
        }
    }

    private func playAutomaticAudio() {
        store.mediaStore.play(showingAnswer ? answerPlayback : questionPlayback)
    }

    private func replayCurrentAudio() {
        let cfg = currentConfig
        let items: [CardHTMLRenderer.PlaybackItem]
        if showingAnswer && cfg.replayq {
            items = questionPlayback + answerPlayback
        } else if showingAnswer {
            items = answerPlayback
        } else {
            items = questionPlayback
        }
        store.mediaStore.play(items)
    }

    private func answer(_ rating: Rating) {
        guard let current, let scheduler else { return }
        previousCard = current
        previousNote = note
        store.mediaStore.clearOwnVoice()
        isRecordingVoice = false
        if store.conf["interruptAudioWhenAnswering"] as? Bool
            ?? store.conf["interruptAudio"] as? Bool ?? true {
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
            showAnswerFeedback(for: rating)
        } catch {
            self.current = nil
            note = nil
            store.lastError = error.localizedDescription
        }
    }

    private func showAnswerFeedback(for rating: Rating) {
        guard store.conf["reviewFeedbackTicks"] as? Bool ?? true else {
            answerFeedback = nil
            return
        }
        answerFeedback = rating
        answerFeedbackGeneration += 1
        let generation = answerFeedbackGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard answerFeedbackGeneration == generation else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                answerFeedback = nil
            }
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
        guard let key = keyEquivalent(for: keyText) else { return nil }
        return KeyboardShortcut(key, modifiers: modifiers)
    }

    private func keyboardShortcut(for binding: StudyKeyboardShortcutBinding) -> KeyboardShortcut? {
        guard let key = keyEquivalent(for: binding.key) else { return nil }
        return KeyboardShortcut(key, modifiers: keyboardModifiers(binding.modifiers))
    }

    private func keyEquivalent(for value: String) -> KeyEquivalent? {
        switch value.lowercased() {
        case "space": return .space
        case "return": return .return
        case "enter":
            return .return
        case "tab": return .tab
        case "delete": return .deleteForward
        case "backspace": return .delete
        case "escape", "esc": return .escape
        case "f5":
            return nil
        default:
            guard value.count == 1, let character = value.first else { return nil }
            return KeyEquivalent(character)
        }
    }

    private func keyboardModifiers(_ modifiers: StudyKeyboardShortcutModifiers) -> EventModifiers {
        switch modifiers {
        case .none: []
        case .shift: [.shift]
        case .control: [.control]
        case .controlShift: [.control, .shift]
        case .controlOption: [.control, .option]
        }
    }

    private func performStudyShortcut(_ action: StudyKeyboardShortcutAction) {
        switch action {
        case .showAnswer: studyPrimaryKeyAction()
        case .edit: showEdit = true
        case .contextMenu: studyToolsPresentation = .actions
        case .replayAudio: replayCurrentAudio()
        case .buryNote: buryNote()
        case .buryCard: buryCard()
        case .suspendNote: suspendNote()
        case .suspendCard: suspendCard()
        case .mark: mark()
        case .setFlag1: toggleFlag(1)
        case .setFlag2: toggleFlag(2)
        case .setFlag3: toggleFlag(3)
        case .setFlag4: toggleFlag(4)
        case .setFlag5: toggleFlag(5)
        case .setFlag6: toggleFlag(6)
        case .setFlag7: toggleFlag(7)
        case .deleteNote: showDeleteConfirm = true
        case .createCopy: requestStudyCopy()
        case .setDueDate:
            dueDateText = "1"
            showSetDue = true
        case .forgetCard: forgetCurrentCard()
        case .replayOwnVoice: store.mediaStore.replayOwnVoice()
        case .recordOwnVoice: toggleOwnVoiceRecording()
        case .deckOptions:
            if current != nil { showDeckOptions = true }
        case .cardInfo: showInfo()
        case .previousCardInfo: showPreviousInfo()
        case .undo: undoAnswer()
        case .pauseAudio: store.mediaStore.pauseOrResume()
        case .seekBackward: store.mediaStore.seek(by: -5)
        case .seekForward: store.mediaStore.seek(by: 5)
        case .toggleAutoAdvance: autoAdvanceActive.toggle()
        }
    }

    private func undoAnswer() {
        do {
            try store.undoMostRecentCollectionAction()
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func redoAnswer() {
        do {
            try store.redoMostRecentCollectionAction()
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

private struct StudyShakeReceiver: UIViewRepresentable {
    let onShake: () -> Void

    func makeUIView(context: Context) -> StudyShakeView {
        let view = StudyShakeView()
        view.onShake = onShake
        return view
    }

    func updateUIView(_ view: StudyShakeView, context: Context) {
        view.onShake = onShake
    }
}

private final class StudyShakeView: UIView {
    var onShake: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.becomeFirstResponder()
        }
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            onShake?()
        } else {
            super.motionEnded(motion, with: event)
        }
    }
}

@MainActor
private struct StudyPencilScratchpadCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let ignoreFingers: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(drawing: $drawing)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView(frame: .zero)
        canvas.delegate = context.coordinator
        canvas.drawingPolicy = ignoreFingers ? .pencilOnly : .anyInput
        canvas.tool = PKInkingTool(.pen, color: UIColor(AppTheme.accent), width: 3)
        canvas.drawing = drawing
        canvas.isOpaque = false
        canvas.backgroundColor = .clear
        canvas.isScrollEnabled = false
        canvas.accessibilityIdentifier = "study.scratchpad.canvas"
        canvas.accessibilityLabel = "Área do bloco de escrita"
        canvas.accessibilityValue = "\(drawing.strokes.count) traços"
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        canvas.drawingPolicy = ignoreFingers ? .pencilOnly : .anyInput
        if canvas.drawing != drawing { canvas.drawing = drawing }
        canvas.accessibilityValue = "\(drawing.strokes.count) traços"
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        @Binding var drawing: PKDrawing

        init(drawing: Binding<PKDrawing>) {
            _drawing = drawing
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            if drawing != canvasView.drawing { drawing = canvasView.drawing }
        }
    }
}

private struct StudyScratchpadStroke: Identifiable {
    let id: UUID
    var points: [CGPoint]

    init(points: [CGPoint]) {
        id = UUID()
        self.points = points
    }
}

private struct StudyScratchpadCanvas: View {
    @Binding var strokes: [StudyScratchpadStroke]
    @State private var activeStrokeID: UUID?

    var body: some View {
        Canvas { context, _ in
            for stroke in strokes {
                guard let first = stroke.points.first else { continue }
                if stroke.points.count == 1 {
                    let dot = CGRect(x: first.x - 2, y: first.y - 2, width: 4, height: 4)
                    context.fill(Path(ellipseIn: dot), with: .color(AppTheme.accent))
                } else {
                    var path = Path()
                    path.move(to: first)
                    for point in stroke.points.dropFirst() {
                        path.addLine(to: point)
                    }
                    context.stroke(path, with: .color(AppTheme.accent), lineWidth: 3)
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if let activeStrokeID,
                       let index = strokes.firstIndex(where: { $0.id == activeStrokeID }) {
                        strokes[index].points.append(value.location)
                    } else {
                        let stroke = StudyScratchpadStroke(points: [value.location])
                        activeStrokeID = stroke.id
                        strokes.append(stroke)
                    }
                }
                .onEnded { _ in activeStrokeID = nil }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Área do bloco de escrita")
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
