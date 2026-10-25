import SwiftUI
#if os(iOS)
import UserNotifications
#endif

struct PreferencesView: View {
    enum Category: String, Equatable {
        case appearance
        case study
        case notifications
        case editing
        case sync

        var title: LocalizedStringKey {
            switch self {
            case .appearance: return "Aparência"
            case .study: return "Opções de estudo"
            case .notifications: return "Notificações"
            case .editing: return "Edição e navegação"
            case .sync: return "Opções de sincronização"
            }
        }

        var description: LocalizedStringKey {
            switch self {
            case .appearance: return "Personalize o visual do AnkiOS e a forma como os cartões são exibidos."
            case .study: return "Configure os controles, gestos e informações disponíveis durante o estudo."
            case .notifications: return "Escolha quando receber lembretes dos cartões pendentes."
            case .editing: return "Defina opções para adicionar notas, navegar pela coleção e colar imagens."
            case .sync: return "Configure a sincronização automática da coleção e da mídia com o AnkiWeb."
            }
        }
    }

    @EnvironmentObject private var store: CollectionStore
    let category: Category

    init(category: Category = .study) {
        self.category = category
    }

    @State private var showDueCounts = true
    @State private var estTimes = true
    @State private var showAudioPlayButtons = true
    @State private var showStudyBottomBar = true
    @State private var showStudyAnswerButtons = true
    @State private var reviewFeedbackTicks = true
    @State private var alwaysDuckAndIgnoreMute = false
    @State private var neverTypeAnswer = false
    @State private var answerKeepsZoom = false
    @State private var doubleTapPrevention = false
    @State private var doubleTapPreventionDelay = 0.3
    @State private var reduceMotion = true
    @State private var minimalistMode = false
    @State private var spacebarRatesCard = true
    @State private var answerKeyTexts = ["1", "2", "3", "4"]
    @State private var gesturePreferences = ReviewGesturePreferences()
    @State private var showToolsOverlayButton = true
    @State private var toolsOverlayButtonOnLeft = false
    @State private var studyReminderEnabled = false
    @State private var studyReminderTime = Calendar.current.date(from: DateComponents(hour: 19, minute: 0)) ?? Date()
    @State private var studyReminderPermissionDenied = false
    @State private var studyReminderScheduled = false
    @State private var gamepadPreferences = ReviewGamepadPreferences()
    @State private var scratchpadIgnoresFingers = false
    @State private var scratchpadUndoClearsAll = false
    @State private var scratchpadBelowButtons = false
    @State private var studyUserActionScripts = Array(repeating: "", count: 8)
    @State private var addToCur = true
    @State private var cardZoom: Double = 1.0
    @State private var interruptAudio = true
    @State private var deckPerNoteType = false
    @State private var browserDefaultSearch = ""
    @State private var ignoreAccentsInSearch = false
    @State private var pasteImagesAsPNG = false
    @State private var imageMaxDimension = 1024
    @State private var resizePastedImages = false
    @State private var pasteStripsFormatting = false
    @State private var syncAnkiWebMedia = true
    @State private var autoSyncAnkiWeb = true
    @State private var forceOneWaySyncNext = false
    @State private var periodicAnkiWebMediaSync = true
    @State private var renderLatex = false
    @AppStorage("ankios.themeMode", store: SharedProfiles.defaults) private var themeMode = 0
    @State private var languageCode = AnkiLanguageCatalog.defaultLanguageCode
    #if os(macOS)
    @State private var showLanguageRestartAlert = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    GlassCard(interactive: false) {
                        Text(category.description)
                            .font(.callout)
                            .foregroundStyle(AppTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if category == .appearance {
                        GlassFormSection(title: "Interface") {
                            glassPicker("Tema", selection: $themeMode) {
                                Text("Seguir sistema").tag(0)
                                Text("Claro").tag(1)
                                Text("Escuro").tag(2)
                            }
                            Text("O tema muda assim que você seleciona uma opção.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .padding(.horizontal, 4)
                            #if os(macOS)
                            GlassOptionRow(title: "Idioma") {
                                Picker("", selection: languageSelection) {
                                    ForEach(AnkiLanguageCatalog.languages) { language in
                                        Text(language.name).tag(language.code)
                                    }
                                }
                                .labelsHidden()
                                .accessibilityLabel("Idioma")
                                .accessibilityValue(AnkiLanguageCatalog.language(for: languageCode).name)
                                .accessibilityIdentifier("preferences.language")
                                .pickerStyle(.menu)
                                .menuIndicator(.hidden)
                                .buttonStyle(GlassChipButtonStyle())
                            }
                            #endif
    #if os(macOS)
                            glassToggle("Mostrar contagem de cartões restantes", isOn: $showDueCounts)
    #endif
                            glassToggle("Reduzir movimento", isOn: $reduceMotion)
                            glassToggle("Modo minimalista", isOn: $minimalistMode)
    #if os(macOS)
                            glassToggle("Mostrar próxima revisão nos botões", isOn: $estTimes)
    #endif
                            #if os(macOS)
                            glassToggle("Gerar imagens LaTeX ao exibir cartões", isOn: $renderLatex)
                            #endif
                            GlassInset {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Zoom dos cartões: \(String(format: "%.0f%%", cardZoom * 100))")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(AppTheme.primaryText)
                                    Slider(value: $cardZoom, in: 0.7...1.6, step: 0.05)
                                }
                            }
                        }
                    }
                    if category == .study {
                        GlassFormSection(title: "Teclas de resposta") {
                            ForEach(0..<4, id: \.self) { index in
                                GlassOptionRow(title: ["De novo", "Difícil", "Bom", "Fácil"][index]) {
                                    TextField("Desativado", text: $answerKeyTexts[index])
                                        .textFieldStyle(.plain)
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 140)
                                        .autocorrectionDisabled()
                                }
                            }
                            Text("Use uma tecla ou uma combinação, como Ctrl+1. Deixe vazio para desativar.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .padding(.horizontal, 4)
                        }
                        GlassFormSection(title: "Reprodução e avaliação") {
                            glassToggle("Mostrar botões de áudio nos cartões", isOn: $showAudioPlayButtons)
                            glassToggle("Interromper áudio ao responder", isOn: $interruptAudio)
                            glassToggle("Barra de espaço avalia cartão", isOn: $spacebarRatesCard)
                        }
                        #if os(iOS)
                        GlassFormSection(title: "preferences.review.section") {
                            glassToggle("Mostrar confirmação da avaliação", isOn: $reviewFeedbackTicks, identifier: "preferences.review.feedbackTicks")
                            glassToggle("Reduzir música e ignorar modo silencioso", isOn: $alwaysDuckAndIgnoreMute, identifier: "preferences.review.duckIgnoreMute")
                            glassToggle("Manter zoom ao mostrar resposta", isOn: $answerKeepsZoom, identifier: "preferences.review.answerKeepsZoom")
                            glassToggle("Nunca digitar resposta", isOn: $neverTypeAnswer, identifier: "preferences.review.neverTypeAnswer")
                            glassToggle("Ignorar toque duplo", isOn: $doubleTapPrevention, identifier: "preferences.review.doubleTapPrevention")
                            GlassInset {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Intervalo: \(String(format: "%.2f", doubleTapPreventionDelay)) s")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(AppTheme.primaryText)
                                    Slider(value: $doubleTapPreventionDelay, in: 0.1...1.0, step: 0.05)
                                        .accessibilityIdentifier("preferences.review.doubleTapDelay")
                                        .disabled(!doubleTapPrevention)
                                }
                            }
                        }
                        #endif
                    }
                    if category == .notifications {
                        #if os(iOS)
                        GlassFormSection(title: "Notificações") {
                            glassToggle("preferences.notifications.alertWhenDue", isOn: $studyReminderEnabled, identifier: "preferences.notifications.enabled")
                            GlassOptionRow(title: "Horário de alerta") {
                                DatePicker("Horário de alerta", selection: $studyReminderTime, displayedComponents: .hourAndMinute)
                                    .labelsHidden()
                                    .datePickerStyle(.compact)
                                    .accessibilityIdentifier("preferences.notifications.time")
                                    .disabled(!studyReminderEnabled)
                            }
                            Text("Receba um lembrete diário com a quantidade de cartões pendentes.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .padding(.horizontal, 4)
                            if studyReminderPermissionDenied && studyReminderEnabled {
                                Text("Permita notificações do AnkiOS nos Ajustes do sistema para receber lembretes.")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.danger)
                                    .padding(.horizontal, 4)
                            }
                            if studyReminderScheduled && studyReminderEnabled {
                                Text("Lembrete agendado")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(AppTheme.good)
                                    .padding(.horizontal, 4)
                                    .accessibilityIdentifier("preferences.notifications.status")
                            }
                        }
                        #endif
                    }
                    if category == .study {
                        #if os(iOS)
                        GlassFormSection(title: "Toques no cartão") {
                            Text("Configure ações para as nove áreas do cartão. Na pergunta, todas mostram a resposta. Na resposta, as laterais avaliam De novo ou Bom.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .padding(.horizontal, 4)
                            tapActionGrid(isAnswerShown: false)
                            tapActionGrid(isAnswerShown: true)
                        }
                        GlassFormSection(title: "Deslizes no cartão") {
                            Text("Atribua uma ação a cada direção do gesto. Por padrão, deslizar à esquerda abre as ferramentas e à direita volta aos baralhos.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .padding(.horizontal, 4)
                            ForEach(0..<ReviewGesturePreferences.swipeDirections.count, id: \.self) { index in
                                let direction = ReviewGesturePreferences.swipeDirections[index]
                                GlassOptionRow(title: "Deslizar \(ReviewGesturePreferences.swipeTitles[index])") {
                                    Picker(selection: Binding<String>(
                                        get: { gesturePreferences.swipeAction(for: direction).rawValue },
                                        set: { rawValue in
                                            guard let action = ReviewGestureAction(rawValue: rawValue) else { return }
                                            gesturePreferences.setSwipe(action, direction: direction)
                                        }
                                    ), label: Text(gesturePreferences.swipeAction(for: direction).title)) {
                                        ForEach(ReviewGestureAction.allCases) { action in
                                            Text(action.title).tag(action.rawValue)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .accessibilityIdentifier("preferences.swipe.\(direction)")
                                }
                            }
                        }
                        GlassFormSection(title: "mobile.scratchpad.name") {
                            glassToggle("mobile.scratchpad.ignoresFingers", isOn: $scratchpadIgnoresFingers, identifier: "preferences.scratchpad.ignoreFingers")
                            glassToggle("mobile.scratchpad.undoClearsAll", isOn: $scratchpadUndoClearsAll, identifier: "preferences.scratchpad.undoClearsAll")
                            glassToggle("mobile.scratchpad.belowButtons", isOn: $scratchpadBelowButtons, identifier: "preferences.scratchpad.belowButtons")
                            Text("Configure quais entradas desenham, o que o botão Desfazer faz e a posição do bloco durante o estudo.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .padding(.horizontal, 4)
                        }
                        GlassFormSection(title: "Barra superior do estudo") {
                            GlassOptionRow(title: "Ação do botão") {
                                Picker(selection: Binding<String>(
                                    get: { gesturePreferences.topBarAction.rawValue },
                                    set: { rawValue in
                                        guard let action = ReviewGestureAction(rawValue: rawValue) else { return }
                                        gesturePreferences.topBarAction = action
                                    }
                                ), label: Text(gesturePreferences.topBarAction.title)) {
                                    ForEach(ReviewGestureAction.allCases) { action in
                                        Text(action.title).tag(action.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .accessibilityIdentifier("preferences.topBar.action")
                            }
                            Text("Escolha a ação do botão no canto superior da tela de estudo.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .padding(.horizontal, 4)
                        }
                        #if os(iOS)
                        GlassFormSection(title: "mobile.preferences.toolsOverlayButton") {
                            Text("Mostre o ícone de ferramentas sobre o cartão ou use a ação Ferramentas na barra superior.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .padding(.horizontal, 4)
                            glassToggle("Mostrar botão sobre o cartão", isOn: $showToolsOverlayButton, identifier: "preferences.topBar.showTools")
                            glassToggle("Posicionar à esquerda", isOn: $toolsOverlayButtonOnLeft, identifier: "preferences.topBar.positionLeft")
                                .disabled(!showToolsOverlayButton)
                        }
                        GlassFormSection(title: "Barra inferior") {
                            glassToggle("Mostrar barra inferior", isOn: $showStudyBottomBar, identifier: "preferences.bottomBar.show")
                            glassToggle("Mostrar contagem restante", isOn: $showDueCounts, identifier: "preferences.bottomBar.remainingCount")
                            glassToggle("Mostrar botões de resposta", isOn: $showStudyAnswerButtons, identifier: "preferences.bottomBar.answerButtons")
                            glassToggle("Mostrar próximos horários", isOn: $estTimes, identifier: "preferences.bottomBar.nextTimes")
                        }
                        #endif
                        GlassFormSection(title: "Ação ao sacudir") {
                            GlassOptionRow(title: "Ação") {
                                Picker(selection: Binding<String>(
                                    get: { gesturePreferences.shakeAction.rawValue },
                                    set: { rawValue in
                                        guard let action = ReviewGestureAction(rawValue: rawValue) else { return }
                                        gesturePreferences.shakeAction = action
                                    }
                                ), label: Text(gesturePreferences.shakeAction.title)) {
                                    ForEach(ReviewGestureAction.allCases) { action in
                                        Text(action.title).tag(action.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .accessibilityIdentifier("preferences.shake.action")
                            }
                            Text("Escolha a ação executada ao sacudir o iPhone durante o estudo. O padrão é Desfazer.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .padding(.horizontal, 4)
                        }
                        GlassFormSection(title: "Ações do usuário") {
                            ForEach(0..<8, id: \.self) { index in
                                GlassOptionRow(title: "Ação \(index + 1)") {
                                    TextField("var userJs\(index + 1) = minhaFunção;", text: $studyUserActionScripts[index], axis: .vertical)
                                        .textFieldStyle(.plain)
                                        .lineLimit(1...3)
                                        .autocorrectionDisabled()
                                        .accessibilityIdentifier("preferences.userAction.\(index + 1)")
                                }
                            }
                            Text("Defina uma ação JavaScript fornecida pelo template do cartão, como var userJs1 = revealNext;. Deixe vazio para desativar.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .padding(.horizontal, 4)
                        }
                        gamepadPreferencesSection
                        #endif
                    }
                    if category == .editing {
                        GlassFormSection(title: "Edição e navegação") {
                            glassPicker("Baralho padrão", selection: Binding(
                                get: { deckPerNoteType ? 1 : 0 },
                                set: { deckPerNoteType = $0 == 1 }
                            )) {
                                Text("Baralho atual").tag(0)
                                Text("Último por tipo de nota").tag(1)
                            }
                            GlassInset {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Busca inicial do navegador")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(AppTheme.primaryText)
                                    TextField("Ex.: deck:current", text: $browserDefaultSearch)
                                        .textFieldStyle(.plain)
                                        .foregroundStyle(AppTheme.primaryText)
                                        .autocorrectionDisabled()
                                }
                            }
                            #if os(iOS)
                            GlassInset {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("Max Image Size (Long Edge)")
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(AppTheme.primaryText)
                                        Spacer(minLength: 12)
                                        Text("\(imageMaxDimension) px")
                                            .font(.subheadline.monospacedDigit())
                                            .foregroundStyle(AppTheme.secondaryText)
                                    }
                                    Stepper("", value: $imageMaxDimension, in: 256...4096, step: 128)
                                        .labelsHidden()
                                        .accessibilityLabel("Max Image Size (Long Edge)")
                                        .accessibilityValue("\(imageMaxDimension) px")
                                        .accessibilityIdentifier("preferences.imageMaxDimension")
                                }
                            }
                            glassToggle("Resize When Pasting", isOn: $resizePastedImages, identifier: "preferences.resizePastedImages")
                            #endif
                            glassToggle("Colar imagens da área de transferência como PNG", isOn: $pasteImagesAsPNG)
                            glassToggle("Colar sem Shift remove a formatação", isOn: $pasteStripsFormatting)
                            glassToggle("Ignorar acentos nas buscas simples", isOn: $ignoreAccentsInSearch)
                            glassToggle("Adicionar ao baralho atual", isOn: $addToCur)
                        }
                    }
                    if category == .sync {
                        GlassFormSection(title: "Sincronização com AnkiWeb") {
                            glassToggle("Sincronizar áudio e imagens", isOn: $syncAnkiWebMedia)
                            glassToggle("Sincronizar ao abrir e fechar o perfil", isOn: $autoSyncAnkiWeb)
                            glassToggle("Sincronizar mídia a cada 15 minutos", isOn: $periodicAnkiWebMediaSync)
                            glassToggle("Na próxima sincronização, escolher enviar ou baixar", isOn: $forceOneWaySyncNext)
                            Text("A sincronização automática só funciona quando uma conta AnkiWeb está conectada.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .padding(.horizontal, 4)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            Button("Salvar preferências") { save() }
                .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.42, expands: true))
                .accessibilityIdentifier("preferences.save")
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .background(AppBackground())
        .navigationTitle(category.title)
        .onAppear(perform: load)
        #if os(macOS)
        .alert("Idioma alterado", isPresented: $showLanguageRestartAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Reinicie o AnkiOS para concluir a alteração do idioma.")
        }
        #endif
    }

    private var gamepadPreferencesSection: some View {
        GlassFormSection(title: "Controles de jogo") {
            Text("Controles compatíveis com o perfil estendido do iOS podem acionar ações de estudo. As direções do direcional são configuráveis; os analógicos rolam o cartão.")
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
                .padding(.horizontal, 4)
            ForEach(ReviewGamepadControl.all) { control in
                gamepadActionPicker(for: control)
            }
            GlassInset {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Zona neutra do analógico: \(Int((gamepadPreferences.thumbpadDeadZone * 100).rounded()))%")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppTheme.primaryText)
                    Slider(value: $gamepadPreferences.thumbpadDeadZone, in: 0.1...0.9, step: 0.05)
                        .accessibilityIdentifier("preferences.gamepad.deadZone")
                }
            }
        }
    }

    private func gamepadActionPicker(for control: ReviewGamepadControl) -> some View {
        let selection = Binding<String>(
            get: { gamepadPreferences.action(for: control.id).rawValue },
            set: { rawValue in
                guard let action = ReviewGestureAction(rawValue: rawValue) else { return }
                gamepadPreferences.set(action, for: control.id)
            }
        )
        let selectedTitle = gamepadPreferences.action(for: control.id).title
        return GlassOptionRow(title: LocalizedStringKey(control.title)) {
            Picker(selection: selection, label: Text(selectedTitle)) {
                ForEach(ReviewGestureAction.allCases) { action in
                    Text(action.title).tag(action.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityIdentifier("preferences.gamepad.\(control.id)")
        }
    }

    #if os(macOS)
    private var languageSelection: Binding<String> {
        Binding(
            get: { languageCode },
            set: { newValue in
                guard newValue != languageCode else { return }
                languageCode = newValue
                SharedProfiles.defaults.set(newValue, forKey: AnkiLanguageCatalog.preferenceKey)
                showLanguageRestartAlert = true
            }
        )
    }
    #endif

    private var selectedLanguageCode: String {
        #if os(iOS)
        AnkiLanguageCatalog.appLanguageCode
        #else
        languageCode
        #endif
    }

    private func glassToggle(_ title: String, isOn: Binding<Bool>, identifier: String? = nil) -> some View {
        GlassOptionRow(title: LocalizedStringKey(title), interactive: false) {
            Toggle("", isOn: isOn).labelsHidden().tint(AppTheme.accent)
                .accessibilityLabel(LocalizedStringKey(title))
                .accessibilityIdentifier(identifier ?? "preferences.\(title)")
        }
    }

    private func glassPicker<Content: View>(_ title: String, selection: Binding<Int>, @ViewBuilder content: () -> Content) -> some View {
        GlassOptionRow(title: LocalizedStringKey(title)) {
            Picker("", selection: selection, content: content)
                .labelsHidden()
                .accessibilityLabel(LocalizedStringKey(title))
                .accessibilityIdentifier("preferences.\(title)")
                .pickerStyle(.menu)
        }
    }

    private func tapActionGrid(isAnswerShown: Bool) -> some View {
        let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 6), count: 3)
        return GlassInset {
            VStack(alignment: .leading, spacing: 8) {
                Text(isAnswerShown ? "Resposta exibida" : "Pergunta exibida")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.primaryText)
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(0..<ReviewGesturePreferences.zones.count, id: \.self) { index in
                        let zone = ReviewGesturePreferences.zones[index]
                        Picker(selection: Binding<String>(
                            get: { gesturePreferences.action(isAnswerShown: isAnswerShown, zone: zone).rawValue },
                            set: { rawValue in
                                guard let action = ReviewGestureAction(rawValue: rawValue) else { return }
                                gesturePreferences.set(action, isAnswerShown: isAnswerShown, zone: zone)
                            }
                        ), label: Text("\(ReviewGesturePreferences.zoneSymbols[index]) \(gesturePreferences.action(isAnswerShown: isAnswerShown, zone: zone).title)")) {
                            ForEach(ReviewGestureAction.allCases) { action in
                                Text(action.title).tag(action.rawValue)
                            }
                        }
                        .accessibilityIdentifier("preferences.tap.\(isAnswerShown ? "answer" : "question").\(zone)")
                        .pickerStyle(.menu)
                        .font(.caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 30)
                    }
                }
            }
        }
    }

    private func load() {
        showDueCounts = store.conf["dueCounts"] as? Bool ?? true
        estTimes = store.conf["estTimes"] as? Bool ?? true
        showAudioPlayButtons = !(store.conf["hideAudioPlayButtons"] as? Bool ?? false)
        reviewFeedbackTicks = store.conf["reviewFeedbackTicks"] as? Bool ?? true
        alwaysDuckAndIgnoreMute = store.conf["alwaysDuckAndIgnoreMute"] as? Bool ?? false
        answerKeepsZoom = store.conf["answerKeepsZoom"] as? Bool ?? false
        neverTypeAnswer = store.conf["neverTypeAnswer"] as? Bool ?? false
        doubleTapPrevention = store.conf["doubleTapPrevention"] as? Bool ?? false
        doubleTapPreventionDelay = store.conf["doubleTapPreventionDelay"] as? Double ?? 0.3
        reduceMotion = SharedProfiles.defaults.object(forKey: "ankios.reduceMotion") as? Bool ?? true
        minimalistMode = SharedProfiles.defaults.bool(forKey: "ankios.minimalistMode")
        addToCur = store.conf["addToCur"] as? Bool ?? true
        cardZoom = store.conf["cardZoom"] as? Double ?? 1.0
        interruptAudio = store.conf["interruptAudioWhenAnswering"] as? Bool
            ?? store.conf["interruptAudio"] as? Bool ?? true
        deckPerNoteType = store.conf["deckSelectionBehavior"] as? String == "noteType"
        browserDefaultSearch = store.conf["defaultSearchText"] as? String
            ?? store.conf["browserDefaultSearch"] as? String ?? ""
        ignoreAccentsInSearch = store.conf["ignoreAccentsInSearch"] as? Bool ?? false
        pasteImagesAsPNG = store.conf["pasteImagesAsPng"] as? Bool ?? false
        imageMaxDimension = store.conf["imageMaxDimension"] as? Int ?? 1024
        resizePastedImages = store.conf["resizePastedImages"] as? Bool ?? false
        pasteStripsFormatting = store.conf["pasteStripsFormatting"] as? Bool ?? false
        syncAnkiWebMedia = store.ankiWebMediaSyncEnabled
        autoSyncAnkiWeb = store.ankiWebAutoSyncEnabled
        forceOneWaySyncNext = store.ankiWebForceOneWaySyncNext
        periodicAnkiWebMediaSync = store.ankiWebPeriodicMediaSyncMinutes != 0
        renderLatex = store.conf["renderLatex"] as? Bool ?? false
        #if os(macOS)
        languageCode = SharedProfiles.defaults.string(forKey: AnkiLanguageCatalog.preferenceKey)
            .flatMap(AnkiLanguageCatalog.normalizedCode) ?? AnkiLanguageCatalog.defaultLanguageCode
        #else
        languageCode = AnkiLanguageCatalog.appLanguageCode
        #endif
        let keyboard = store.reviewKeyboardPreferences
        spacebarRatesCard = keyboard.spacebarRatesCard
        answerKeyTexts = (1...4).map { keyboard.answerKeys[$0] ?? "" }
        gesturePreferences = store.reviewGesturePreferences
        showToolsOverlayButton = store.conf["showToolsOverlayButton"] as? Bool ?? true
        toolsOverlayButtonOnLeft = store.conf["toolsOverlayButtonOnLeft"] as? Bool ?? false
        #if os(iOS)
        showStudyBottomBar = store.conf["showBottomBar"] as? Bool ?? true
        showStudyAnswerButtons = store.conf["showAnswerButtons"] as? Bool ?? true
        let defaults = SharedProfiles.defaults
        let reminderPrefix = StudyReminderScheduler.storagePrefix(for: store.activeProfile)
        studyReminderEnabled = defaults.bool(forKey: reminderPrefix + ".enabled")
        let reminderHour = defaults.object(forKey: reminderPrefix + ".hour") as? Int ?? 19
        let reminderMinute = defaults.object(forKey: reminderPrefix + ".minute") as? Int ?? 0
        studyReminderTime = Calendar.current.date(from: DateComponents(hour: reminderHour, minute: reminderMinute)) ?? Date()
        studyReminderPermissionDenied = false
        studyReminderScheduled = false
        Task { @MainActor in
            studyReminderScheduled = await StudyReminderScheduler.hasPendingRequest()
        }
        #endif
        gamepadPreferences = store.reviewGamepadPreferences
        let scratchpad = store.reviewScratchpadPreferences
        scratchpadIgnoresFingers = scratchpad.ignoreFingers
        scratchpadUndoClearsAll = scratchpad.undoClearsAll
        scratchpadBelowButtons = scratchpad.belowButtons
        studyUserActionScripts = store.studyUserActionScripts
    }

    private func save() {
        var conf = store.conf
        conf["dueCounts"] = showDueCounts
        conf["estTimes"] = estTimes
        conf["addToCur"] = addToCur
        conf["hideAudioPlayButtons"] = !showAudioPlayButtons
        #if os(iOS)
        conf["reviewFeedbackTicks"] = reviewFeedbackTicks
        conf["alwaysDuckAndIgnoreMute"] = alwaysDuckAndIgnoreMute
        conf["answerKeepsZoom"] = answerKeepsZoom
        conf["neverTypeAnswer"] = neverTypeAnswer
        conf["doubleTapPrevention"] = doubleTapPrevention
        conf["doubleTapPreventionDelay"] = doubleTapPreventionDelay
        conf["showToolsOverlayButton"] = showToolsOverlayButton
        conf["toolsOverlayButtonOnLeft"] = toolsOverlayButtonOnLeft
        conf["showBottomBar"] = showStudyBottomBar
        conf["showAnswerButtons"] = showStudyAnswerButtons
        #endif
        conf["cardZoom"] = cardZoom
        conf["interruptAudioWhenAnswering"] = interruptAudio
        conf.removeValue(forKey: "interruptAudio")
        conf["deckSelectionBehavior"] = deckPerNoteType ? "noteType" : "current"
        conf["defaultSearchText"] = browserDefaultSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        conf.removeValue(forKey: "browserDefaultSearch")
        conf["ignoreAccentsInSearch"] = ignoreAccentsInSearch
        conf["pasteImagesAsPng"] = pasteImagesAsPNG
        #if os(iOS)
        conf["imageMaxDimension"] = imageMaxDimension
        conf["resizePastedImages"] = resizePastedImages
        #endif
        conf["pasteStripsFormatting"] = pasteStripsFormatting
        #if os(macOS)
        conf["renderLatex"] = renderLatex
        #endif
        do {
            try store.saveConf(conf)
            SharedProfiles.defaults.set(reduceMotion, forKey: "ankios.reduceMotion")
            SharedProfiles.defaults.set(minimalistMode, forKey: "ankios.minimalistMode")
            #if os(macOS)
            SharedProfiles.defaults.set(languageCode, forKey: AnkiLanguageCatalog.preferenceKey)
            #endif
            #if os(iOS)
            let reminderPrefix = StudyReminderScheduler.storagePrefix(for: store.activeProfile)
            let reminderComponents = Calendar.current.dateComponents([.hour, .minute], from: studyReminderTime)
            let reminderHour = reminderComponents.hour ?? 19
            let reminderMinute = reminderComponents.minute ?? 0
            SharedProfiles.defaults.set(studyReminderEnabled, forKey: reminderPrefix + ".enabled")
            SharedProfiles.defaults.set(reminderHour, forKey: reminderPrefix + ".hour")
            SharedProfiles.defaults.set(reminderMinute, forKey: reminderPrefix + ".minute")
            let reminderEnabled = studyReminderEnabled
            let reminderTime = studyReminderTime
            let reminderCount = store.totalDueCardCount
            let reminderLanguage = selectedLanguageCode
            let reminderProfile = store.activeProfile
            Task { @MainActor in
                let permitted = await StudyReminderScheduler.configure(
                    profile: reminderProfile,
                    enabled: reminderEnabled,
                    time: reminderTime,
                    pendingCount: reminderCount,
                    languageCode: reminderLanguage,
                    requestsPermission: true
                )
                studyReminderPermissionDenied = reminderEnabled && !permitted
                studyReminderScheduled = reminderEnabled && permitted
            }
            #endif
            var keyboard = store.reviewKeyboardPreferences
            keyboard.spacebarRatesCard = spacebarRatesCard
            keyboard.answerKeys = Dictionary(uniqueKeysWithValues: (1...4).map { rating in
                (rating, answerKeyTexts[rating - 1].trimmingCharacters(in: .whitespacesAndNewlines))
            })
            store.saveReviewKeyboardPreferences(keyboard)
            store.saveReviewGesturePreferences(gesturePreferences)
            store.saveReviewGamepadPreferences(gamepadPreferences)
#if os(iOS)
            store.saveReviewScratchpadPreferences(ReviewScratchpadPreferences(
                ignoreFingers: scratchpadIgnoresFingers,
                undoClearsAll: scratchpadUndoClearsAll,
                belowButtons: scratchpadBelowButtons
            ))
#endif
            store.saveStudyUserActionScripts(studyUserActionScripts)
            store.saveAnkiWebSyncSettings(
                autoSync: autoSyncAnkiWeb,
                syncMedia: syncAnkiWebMedia,
                forceOneWay: forceOneWaySyncNext,
                periodicMediaMinutes: periodicAnkiWebMediaSync ? 15 : 0
            )
            store.lastError = nil
        } catch {
            store.lastError = error.localizedDescription
        }
    }
}

struct AutoAdvanceSheet: View {
    let deck: AnkiDeck?
    @Binding var deckConfig: AnkiDeckConfig
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.dismiss) private var dismiss
    @State private var config: AnkiDeckConfig = .default()

    init(deck: AnkiDeck) {
        self.deck = deck
        _deckConfig = .constant(.default())
    }

    init(deckConfig: Binding<AnkiDeckConfig>) {
        deck = nil
        _deckConfig = deckConfig
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        GlassFormSection(title: "Tempo") {
                            GlassOptionRow(title: "Pergunta (s)") {
                                Stepper("\(Int(config.secondsToShowQuestion))", value: $config.secondsToShowQuestion, in: 0...120, step: 1)
                                    .accessibilityIdentifier("autoAdvance.questionSeconds")
                            }
                            GlassOptionRow(title: "Resposta (s)") {
                                Stepper("\(Int(config.secondsToShowAnswer))", value: $config.secondsToShowAnswer, in: 0...120, step: 1)
                                    .accessibilityIdentifier("autoAdvance.answerSeconds")
                            }
                            GlassOptionRow(title: "Esperar o áudio") {
                                Toggle("", isOn: $config.waitForAudio)
                                    .labelsHidden()
                                    .tint(AppTheme.accent)
                                    .accessibilityIdentifier("autoAdvance.waitForAudio")
                            }
                        }
                        GlassFormSection(title: "Ação") {
                            actionMenu("Na pergunta", selection: $config.questionAction, answer: false)
                            actionMenu("Na resposta", selection: $config.answerAction, answer: true)
                            Text("0 segundos desliga aquele lado. Na pergunta, a ação padrão é mostrar a resposta.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .padding(.horizontal, 4)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                HStack(spacing: 12) {
                    Button("Fechar") { dismiss() }
                        .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.18, expands: true))
                    Button("Salvar") { save() }
                        .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.42, expands: true))
                        .accessibilityIdentifier("autoAdvance.save")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .background(AppBackground())
            .navigationTitle("Avanço automático")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .onAppear(perform: load)
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 460)
            #endif
        }
    }

    private func actionMenu(_ title: String, selection: Binding<Int>, answer: Bool) -> some View {
        GlassOptionRow(title: LocalizedStringKey(title)) {
            Picker("", selection: selection) {
                if answer {
                    Text("Ocultar cartão").tag(0)
                    Text("De novo").tag(1)
                    Text("Bom").tag(2)
                    Text("Difícil").tag(3)
                    Text("Mostrar lembrete").tag(4)
                } else {
                    Text("Mostrar resposta").tag(0)
                    Text("Mostrar lembrete").tag(1)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private func load() {
        if let deck {
            config = store.config(for: deck)
        } else {
            config = deckConfig
        }
    }

    private func save() {
        guard deck != nil else {
            deckConfig = config
            dismiss()
            return
        }
        config.mod = Int64(Date().timeIntervalSince1970)
        var configs = store.deckConfigs
        if let index = configs.firstIndex(where: { $0.id == config.id }) {
            configs[index] = config
        }
        do {
            try store.saveDeckConfigs(configs)
            dismiss()
        } catch {
            store.lastError = error.localizedDescription
        }
    }
}

#if os(iOS)
enum StudyReminderScheduler {
    private static let notificationID = "ankios.daily-study-reminder"

    static func storagePrefix(for profile: String) -> String {
        "ankios.studyReminder.\(profile)"
    }

    @MainActor
    static func hasPendingRequest() async -> Bool {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return requests.contains { $0.identifier == notificationID }
    }

    @MainActor
    static func refresh(store: CollectionStore) {
        let defaults = SharedProfiles.defaults
        let prefix = storagePrefix(for: store.activeProfile)
        let enabled = defaults.bool(forKey: prefix + ".enabled")
        let hour = defaults.object(forKey: prefix + ".hour") as? Int ?? 19
        let minute = defaults.object(forKey: prefix + ".minute") as? Int ?? 0
        let time = Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? Date()
        let languageCode = AnkiLanguageCatalog.appLanguageCode
        Task {
            _ = await configure(
                profile: store.activeProfile,
                enabled: enabled,
                time: time,
                pendingCount: store.totalDueCardCount,
                languageCode: languageCode,
                requestsPermission: false
            )
        }
    }

    @MainActor
    static func configure(
        profile: String,
        enabled: Bool,
        time: Date,
        pendingCount: Int,
        languageCode: String,
        requestsPermission: Bool
    ) async -> Bool {
        let center = UNUserNotificationCenter.current()
        guard enabled else {
            center.removePendingNotificationRequests(withIdentifiers: [notificationID])
            return true
        }

        let settings = await center.notificationSettings()
        var authorized = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
            || settings.authorizationStatus == .ephemeral
        if settings.authorizationStatus == .notDetermined, requestsPermission {
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        guard authorized else {
            center.removePendingNotificationRequests(withIdentifiers: [notificationID])
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = AnkiLanguageCatalog.localizedString("Hora de estudar", for: languageCode)
        content.threadIdentifier = profile
        let key = pendingCount == 1
            ? "Há 1 cartão aguardando revisão."
            : "Há %d cartões aguardando revisão."
        let localizedBody = AnkiLanguageCatalog.localizedString(key, for: languageCode)
        content.body = localizedBody.replacingOccurrences(of: "%d", with: "\(max(0, pendingCount))")
        content.sound = .default

        var components = Calendar.current.dateComponents([.hour, .minute], from: time)
        components.calendar = Calendar.current
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: notificationID, content: content, trigger: trigger)
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }
}
#endif
