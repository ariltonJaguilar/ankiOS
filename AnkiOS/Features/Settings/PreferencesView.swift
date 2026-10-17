import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject private var store: CollectionStore
    @State private var rollday: Double = 4
    @State private var useFSRS = false
    @State private var showDueCounts = true
    @State private var estTimes = true
    @State private var showAudioPlayButtons = true
    @State private var reduceMotion = true
    @State private var minimalistMode = false
    @State private var spacebarRatesCard = true
    @State private var answerKeyTexts = ["1", "2", "3", "4"]
    @State private var gesturePreferences = ReviewGesturePreferences()
    @State private var learnAheadMinutes = 20
    @State private var newSpread = 0
    @State private var addToCur = true
    @State private var timeboxMinutes = 0
    @State private var sortType = 0
    @State private var schedVer = 2
    @State private var cardZoom: Double = 1.0
    @State private var applyParents = true
    @State private var interruptAudio = true
    @State private var fsrsShortTerm = false
    @State private var cardStateCustomizer = ""
    @State private var deckPerNoteType = false
    @State private var browserDefaultSearch = ""
    @State private var ignoreAccentsInSearch = false
    @State private var pasteImagesAsPNG = false
    @State private var pasteStripsFormatting = false
    @State private var syncAnkiWebMedia = true
    @State private var autoSyncAnkiWeb = true
    @State private var forceOneWaySyncNext = false
    @State private var periodicAnkiWebMediaSync = true
    @State private var renderLatex = false
    @State private var backupInterval = 30
    @State private var backupDaily = 12
    @State private var backupWeekly = 10
    @State private var backupMonthly = 9
    @State private var themeMode = 0

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    GlassFormSection(title: "Agendamento") {
                        glassToggle("Usar FSRS", isOn: $useFSRS)
                        glassToggle("FSRS com passos de curto prazo", isOn: $fsrsShortTerm)
                        GlassInset {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Próximo dia começa às \(Int(rollday)):00")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(AppTheme.primaryText)
                                Slider(value: $rollday, in: 0...23, step: 1)
                            }
                        }
                        glassStepper("Limite para antecipar aprendizagem (min)", value: $learnAheadMinutes, range: 0...999, step: 1, display: "\(learnAheadMinutes)")
                        glassStepper("Limite de tempo da sessão (min)", value: $timeboxMinutes, range: 0...9999, step: 1, display: timeboxMinutes == 0 ? "off" : "\(timeboxMinutes)")
                        glassToggle("Aplicar limites dos baralhos pai", isOn: $applyParents)
                        glassPicker("Distribuição de novos", selection: $newSpread) {
                            Text("Misturar com revisões").tag(0)
                            Text("Novos depois das revisões").tag(1)
                            Text("Novos antes das revisões").tag(2)
                        }
                    }
                    GlassFormSection(title: "Interface") {
                        glassPicker("Tema", selection: $themeMode) {
                            Text("Seguir sistema").tag(0)
                            Text("Claro").tag(1)
                            Text("Escuro").tag(2)
                        }
                        glassToggle("Mostrar contagem de cartões restantes", isOn: $showDueCounts)
                        glassToggle("Mostrar botões de áudio nos cartões", isOn: $showAudioPlayButtons)
                        glassToggle("Reduzir movimento", isOn: $reduceMotion)
                        glassToggle("Modo minimalista", isOn: $minimalistMode)
                        glassToggle("Interromper áudio ao responder", isOn: $interruptAudio)
                        glassToggle("Mostrar próxima revisão nos botões", isOn: $estTimes)
                        glassToggle("Barra de espaço avalia cartão", isOn: $spacebarRatesCard)
                        glassToggle("Adicionar ao baralho atual", isOn: $addToCur)
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
                        glassPicker("Ordem da fila", selection: $sortType) {
                            Text("Ordem de adição").tag(0)
                            Text("Ordem relativa").tag(1)
                        }
                    }
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
                            }
                        }
                    }
                    #endif
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
                        glassToggle("Colar imagens da área de transferência como PNG", isOn: $pasteImagesAsPNG)
                        glassToggle("Colar sem Shift remove a formatação", isOn: $pasteStripsFormatting)
                        glassToggle("Ignorar acentos nas buscas simples", isOn: $ignoreAccentsInSearch)
                    }
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
                    GlassFormSection(title: "Avançado") {
                        GlassOptionRow(title: "Versão do agendador") {
                            Text("v\(schedVer)")
                                .font(.body.monospacedDigit().weight(.semibold))
                                .foregroundStyle(AppTheme.primaryText)
                        }
                        Text("O agendador segue o modelo de filas do Anki 2.1. A sincronização com AnkiWeb fica em Ferramentas.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(.horizontal, 4)
                    }
                    GlassFormSection(title: "Backups automáticos") {
                        glassStepper("Intervalo mínimo (min)", value: $backupInterval, range: 5...9999, step: 5, display: "\(backupInterval)")
                        glassStepper("Diários", value: $backupDaily, range: 0...9999, step: 1, display: "\(backupDaily)")
                        glassStepper("Semanais", value: $backupWeekly, range: 0...9999, step: 1, display: "\(backupWeekly)")
                        glassStepper("Mensais", value: $backupMonthly, range: 0...9999, step: 1, display: "\(backupMonthly)")
                        Text("O Anki guarda todos os backups recentes e depois mantém versões diárias, semanais e mensais. Eles não incluem mídia.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(.horizontal, 4)
                    }
                    GlassFormSection(title: "Agendamento personalizado") {
                        Text("JavaScript global que pode ajustar os estados previstos dos botões de resposta. O código recebe states, customData e ctx.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(.horizontal, 4)
                        TextEditor(text: $cardStateCustomizer)
                            .font(.system(.body, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .foregroundStyle(AppTheme.primaryText)
                            .padding(8)
                            .frame(minHeight: 180)
                            .ankiGlass(tint: .white.opacity(0.06), interactive: true, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(20)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            Button("Salvar preferências") { save() }
                .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.42, expands: true))
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .background(AppBackground())
        .navigationTitle("Preferências")
        .onAppear(perform: load)
    }

    private func glassToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        GlassOptionRow(title: title) {
            Toggle("", isOn: isOn).labelsHidden().tint(AppTheme.accent)
                .accessibilityLabel(title)
        }
    }

    private func glassStepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int, display: String) -> some View {
        GlassOptionRow(title: title) {
            HStack(spacing: 8) {
                Text(display)
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(minWidth: 44, alignment: .trailing)
                Stepper("", value: value, in: range, step: step)
                    .labelsHidden()
                    .accessibilityLabel(title)
                    .frame(width: 100)
            }
        }
    }

    private func glassPicker<Content: View>(_ title: String, selection: Binding<Int>, @ViewBuilder content: () -> Content) -> some View {
        GlassOptionRow(title: title) {
            Picker("", selection: selection, content: content)
                .labelsHidden()
                .accessibilityLabel(title)
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
        rollday = Double(store.rolloverHour)
        useFSRS = store.fsrsEnabled
        showDueCounts = store.conf["dueCounts"] as? Bool ?? true
        estTimes = store.conf["estTimes"] as? Bool ?? true
        showAudioPlayButtons = !(store.conf["hideAudioPlayButtons"] as? Bool ?? false)
        reduceMotion = SharedProfiles.defaults.object(forKey: "ankios.reduceMotion") as? Bool ?? true
        minimalistMode = SharedProfiles.defaults.bool(forKey: "ankios.minimalistMode")
        learnAheadMinutes = (store.conf["collapseTime"] as? Int ?? 1200) / 60
        newSpread = store.conf["newSpread"] as? Int ?? 0
        addToCur = store.conf["addToCur"] as? Bool ?? true
        timeboxMinutes = (store.conf["timeLim"] as? Int ?? 0) / 60
        sortType = store.conf["sortType"] as? Int ?? 0
        schedVer = store.conf["schedVer"] as? Int ?? 2
        cardZoom = store.conf["cardZoom"] as? Double ?? 1.0
        applyParents = store.conf["applyAllParentLimits"] as? Bool ?? false
        interruptAudio = store.conf["interruptAudio"] as? Bool ?? true
        fsrsShortTerm = store.conf["fsrsShortTermWithSteps"] as? Bool ?? false
        cardStateCustomizer = store.conf["cardStateCustomizer"] as? String ?? ""
        deckPerNoteType = store.conf["deckSelectionBehavior"] as? String == "noteType"
        browserDefaultSearch = store.conf["browserDefaultSearch"] as? String ?? ""
        ignoreAccentsInSearch = store.conf["ignoreAccentsInSearch"] as? Bool ?? false
        pasteImagesAsPNG = store.conf["pasteImagesAsPng"] as? Bool ?? false
        pasteStripsFormatting = store.conf["pasteStripsFormatting"] as? Bool ?? false
        syncAnkiWebMedia = store.ankiWebMediaSyncEnabled
        autoSyncAnkiWeb = store.ankiWebAutoSyncEnabled
        forceOneWaySyncNext = store.ankiWebForceOneWaySyncNext
        periodicAnkiWebMediaSync = store.ankiWebPeriodicMediaSyncMinutes != 0
        renderLatex = store.conf["renderLatex"] as? Bool ?? false
        let backups = store.conf["backups"] as? [String: Any] ?? [:]
        backupInterval = CollectionStore.int(backups["minimum_interval_mins"]) ?? 30
        backupDaily = CollectionStore.int(backups["daily"]) ?? 12
        backupWeekly = CollectionStore.int(backups["weekly"]) ?? 10
        backupMonthly = CollectionStore.int(backups["monthly"]) ?? 9
        themeMode = SharedProfiles.defaults.object(forKey: "ankios.themeMode") as? Int ?? 0
        let keyboard = store.reviewKeyboardPreferences
        spacebarRatesCard = keyboard.spacebarRatesCard
        answerKeyTexts = (1...4).map { keyboard.answerKeys[$0] ?? "" }
        gesturePreferences = store.reviewGesturePreferences
    }

    private func save() {
        let previousFSRS = store.fsrsEnabled
        var conf = store.conf
        conf["rollover"] = Int(rollday)
        conf.removeValue(forKey: "rollday")
        conf["fsrs"] = useFSRS
        conf["dueCounts"] = showDueCounts
        conf["estTimes"] = estTimes
        conf["collapseTime"] = learnAheadMinutes * 60
        conf["newSpread"] = newSpread
        conf["addToCur"] = addToCur
        conf["timeLim"] = timeboxMinutes * 60
        conf["hideAudioPlayButtons"] = !showAudioPlayButtons
        conf["sortType"] = sortType
        conf["schedVer"] = schedVer
        conf["cardZoom"] = cardZoom
        conf["applyAllParentLimits"] = applyParents
        conf["interruptAudio"] = interruptAudio
        conf["fsrsShortTermWithSteps"] = fsrsShortTerm
        conf["cardStateCustomizer"] = cardStateCustomizer
        conf["deckSelectionBehavior"] = deckPerNoteType ? "noteType" : "current"
        conf["browserDefaultSearch"] = browserDefaultSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        conf["ignoreAccentsInSearch"] = ignoreAccentsInSearch
        conf["pasteImagesAsPng"] = pasteImagesAsPNG
        conf["pasteStripsFormatting"] = pasteStripsFormatting
        #if os(macOS)
        conf["renderLatex"] = renderLatex
        #endif
        conf["backups"] = [
            "minimum_interval_mins": max(5, backupInterval),
            "daily": max(0, backupDaily),
            "weekly": max(0, backupWeekly),
            "monthly": max(0, backupMonthly)
        ]
        do {
            try store.saveConf(conf)
            SharedProfiles.defaults.set(reduceMotion, forKey: "ankios.reduceMotion")
            SharedProfiles.defaults.set(minimalistMode, forKey: "ankios.minimalistMode")
            SharedProfiles.defaults.set(themeMode, forKey: "ankios.themeMode")
            var keyboard = store.reviewKeyboardPreferences
            keyboard.spacebarRatesCard = spacebarRatesCard
            keyboard.answerKeys = Dictionary(uniqueKeysWithValues: (1...4).map { rating in
                (rating, answerKeyTexts[rating - 1].trimmingCharacters(in: .whitespacesAndNewlines))
            })
            store.saveReviewKeyboardPreferences(keyboard)
            store.saveReviewGesturePreferences(gesturePreferences)
            store.saveAnkiWebSyncSettings(
                autoSync: autoSyncAnkiWeb,
                syncMedia: syncAnkiWebMedia,
                forceOneWay: forceOneWaySyncNext,
                periodicMediaMinutes: periodicAnkiWebMediaSync ? 15 : 0
            )
            if previousFSRS != useFSRS {
                try store.rebuildFSRSMemoryStates(enabled: useFSRS)
            }
            store.lastError = "Preferências salvas."
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
                            }
                            GlassOptionRow(title: "Resposta (s)") {
                                Stepper("\(Int(config.secondsToShowAnswer))", value: $config.secondsToShowAnswer, in: 0...120, step: 1)
                            }
                            GlassOptionRow(title: "Esperar o áudio") {
                                Toggle("", isOn: $config.waitForAudio)
                                    .labelsHidden()
                                    .tint(AppTheme.accent)
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
        GlassOptionRow(title: title) {
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
