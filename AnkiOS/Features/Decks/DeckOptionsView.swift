import SwiftUI

struct DeckOptionsView: View {
    let deck: AnkiDeck
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.dismiss) private var dismiss
    @State private var config: AnkiDeckConfig = .default()
    @State private var workingConfigs: [AnkiDeckConfig] = []
    @State private var originalConfigs: [AnkiDeckConfig] = []
    @State private var removedConfigIDs = Set<Int64>()
    @State private var newStepsText = ""
    @State private var lapseStepsText = ""
    @State private var baselineNewCardsIgnoreReviewLimit = false
    @State private var newCardsIgnoreReviewLimit = false
    @State private var selectedConfID: Int64 = 1
    @State private var baselineSelectedConfID: Int64 = 1
    @State private var useDeckRetentionOverride = false
    @State private var deckRetentionOverride = 0.9
    @State private var baselineUseDeckRetentionOverride = false
    @State private var baselineDeckRetentionOverride = 0.9
    @State private var newLimitMode = "preset"
    @State private var reviewLimitMode = "preset"
    @State private var deckNewLimit = 20
    @State private var deckReviewLimit = 200
    @State private var todayNewLimit = 20
    @State private var todayReviewLimit = 200
    @State private var baselineNewLimitMode = "preset"
    @State private var baselineReviewLimitMode = "preset"
    @State private var baselineDeckNewLimit = 20
    @State private var baselineDeckReviewLimit = 200
    @State private var baselineTodayNewLimit = 20
    @State private var baselineTodayReviewLimit = 200
    @State private var showAutoAdvance = false
    @State private var showDiscardChangesConfirmation = false
    @State private var showDefaultPresetAlert = false
    @State private var rescheduleCardsOnChange = false
    @State private var baselineRescheduleCardsOnChange = false
    @State private var baselineDeckRetention: Double?
    @State private var isOptimizingFSRS = false
    @State private var fsrsOptimizationStatus: String?
    @State private var checkFSRSHealth = true
    @State private var baselineCheckFSRSHealth = true

    private var fsrsEnabled: Bool {
        store.fsrsEnabled
    }

    private var hasUnsavedChanges: Bool {
        var configs = workingConfigs
        var current = config
        if let steps = parseSteps(newStepsText), !steps.isEmpty || fsrsEnabled {
            current.new.delays = steps
        }
        if let steps = parseSteps(lapseStepsText) {
            current.lapse.delays = steps
        }
        if let index = configs.firstIndex(where: { $0.id == selectedConfID }) {
            configs[index] = current
        } else {
            configs.append(current)
        }
        return configs != originalConfigs
            || !removedConfigIDs.isEmpty
            || selectedConfID != baselineSelectedConfID
            || newCardsIgnoreReviewLimit != baselineNewCardsIgnoreReviewLimit
            || useDeckRetentionOverride != baselineUseDeckRetentionOverride
            || deckRetentionOverride != baselineDeckRetentionOverride
            || newLimitMode != baselineNewLimitMode
            || reviewLimitMode != baselineReviewLimitMode
            || deckNewLimit != baselineDeckNewLimit
            || deckReviewLimit != baselineDeckReviewLimit
            || todayNewLimit != baselineTodayNewLimit
            || todayReviewLimit != baselineTodayReviewLimit
            || rescheduleCardsOnChange != baselineRescheduleCardsOnChange
            || checkFSRSHealth != baselineCheckFSRSHealth
            || newStepsText != config.new.delays.map(stepText).joined(separator: " ")
            || lapseStepsText != config.lapse.delays.map(stepText).joined(separator: " ")
    }

    var body: some View {
        if deck.isFiltered {
            FilteredDeckOptionsView(deck: deck)
        } else {
            presetOptions
        }
    }

    private var presetOptions: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        presetSection
                        newCardsSection
                        reviewsSection
                        easyDaysSection
                        lapsesSection
                        autoAdvanceSection
                        fsrsSection
                    }
                    .padding(20)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                HStack(spacing: 12) {
                    Button("Fechar") {
                        if hasUnsavedChanges {
                            showDiscardChangesConfirmation = true
                        } else {
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("deck.options.close")
                        .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.18, expands: true))
                    Button("deck-options.save") { save() }
                        .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.42, expands: true))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .background(AppBackground())
            .navigationTitle("deck-options.title")
            .interactiveDismissDisabled(hasUnsavedChanges)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                originalConfigs = store.deckConfigs
                workingConfigs = originalConfigs
                removedConfigIDs.removeAll()
                config = store.config(for: deck)
                loadStepInputs()
                newCardsIgnoreReviewLimit = store.conf["newCardsIgnoreReviewLimit"] as? Bool ?? false
                baselineNewCardsIgnoreReviewLimit = newCardsIgnoreReviewLimit
                selectedConfID = deck.conf
                baselineSelectedConfID = deck.conf
                useDeckRetentionOverride = deck.desiredRetention != nil
                deckRetentionOverride = deck.desiredRetention ?? config.desiredRetention ?? 0.9
                baselineDeckRetention = deck.desiredRetention
                let day = store.schedDay()
                newLimitMode = deck.newLimitToday?.today == day ? "today" : (deck.newLimit == nil ? "preset" : "deck")
                reviewLimitMode = deck.reviewLimitToday?.today == day ? "today" : (deck.reviewLimit == nil ? "preset" : "deck")
                deckNewLimit = deck.newLimit ?? config.new.perDay
                deckReviewLimit = deck.reviewLimit ?? config.rev.perDay
                todayNewLimit = deck.newLimitToday?.today == day ? deck.newLimitToday?.limit ?? config.new.perDay : (deck.newLimit ?? config.new.perDay)
                todayReviewLimit = deck.reviewLimitToday?.today == day ? deck.reviewLimitToday?.limit ?? config.rev.perDay : (deck.reviewLimit ?? config.rev.perDay)
                baselineNewLimitMode = newLimitMode
                baselineReviewLimitMode = reviewLimitMode
                baselineDeckNewLimit = deckNewLimit
                baselineDeckReviewLimit = deckReviewLimit
                baselineTodayNewLimit = todayNewLimit
                baselineTodayReviewLimit = todayReviewLimit
                baselineUseDeckRetentionOverride = useDeckRetentionOverride
                baselineDeckRetentionOverride = deckRetentionOverride
                baselineRescheduleCardsOnChange = rescheduleCardsOnChange
                checkFSRSHealth = store.conf["fsrsHealthCheck"] as? Bool ?? true
                baselineCheckFSRSHealth = checkFSRSHealth
            }
            .alert("Descartar alterações?", isPresented: $showDiscardChangesConfirmation) {
                Button("Descartar", role: .destructive) { dismiss() }
                Button("Continuar editando", role: .cancel) {}
            } message: {
                Text("As alterações não salvas serão descartadas.")
            }
            .alert("Preset padrão", isPresented: $showDefaultPresetAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("O preset padrão não pode ser apagado.")
            }
            .sheet(isPresented: $showAutoAdvance) {
                AutoAdvanceSheet(deckConfig: $config)
            }
        }
    }

    // MARK: - Sections

    private var easyDaysSection: some View {
        let names = ["Seg", "Ter", "Qua", "Qui", "Sex", "Sáb", "Dom"]
        return VStack(alignment: .leading, spacing: 8) {
            Text("Dias fáceis")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.primaryText)
            Text("Mínimo quase não recebe mais cartões depois da primeira leva. Reduzido segura o dia quando ele já está mais cheio que os outros.")
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
            ForEach(0..<7, id: \.self) { index in
                optionsPicker(names[index], selection: easyDayBinding(index)) {
                    Text("Normal").tag(1.0)
                    Text("Reduzido").tag(0.5)
                    Text("Mínimo").tag(0.0)
                }
            }
        }
    }

    private func easyDayBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: {
                guard config.easyDayPercents.count == 7 else { return 1 }
                let value = config.easyDayPercents[index]
                if value <= 0 { return 0 }
                if value < 0.99 { return 0.5 }
                return 1
            },
            set: { newValue in
                if config.easyDayPercents.count != 7 {
                    config.easyDayPercents = Array(repeating: 1, count: 7)
                }
                config.easyDayPercents[index] = newValue
            }
        )
    }

    private var presetSection: some View {
        optionsCard("Preset") {
            optionsLabeled("Nome") {
                TextField("Nome do preset", text: $config.name)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 140)
                    .accessibilityIdentifier("deck.options.preset.name")
            }
            optionsLabeled("Usar preset") {
                Picker("", selection: Binding(get: { selectedConfID }, set: selectConfig)) {
                    ForEach(workingConfigs) { cfg in
                        Text(cfg.name).tag(cfg.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("deck.options.preset")
            }
            Button("Duplicar preset") {
                guard applyStepInputs() else { return }
                updateWorkingConfig(config)
                var copy = config
                copy.id = store.timestampID()
                copy.name = "\(config.name) cópia"
                copy.mod = Int64(Date().timeIntervalSince1970)
                workingConfigs.append(copy)
                selectedConfID = copy.id
                config = copy
                loadStepInputs()
            }
            .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.16, expands: true))
            Button("Apagar preset") { deletePreset() }
                .buttonStyle(GlassButtonStyle(tint: AppTheme.danger, tintStrength: 0.28, expands: true))
                .disabled(workingConfigs.count < 2)
            Button("Aplicar aos sub-baralhos") {
                save(applyToSubdecks: true, dismissAfterSave: false)
            }
            .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.16, expands: true))
        }
    }

    private var newCardsSection: some View {
        optionsCard("Cartões novos") {
            dailyLimitOptions(mode: $newLimitMode, presetValue: $config.new.perDay, deckValue: $deckNewLimit, todayValue: $todayNewLimit, maximum: 9999, identifier: "new")
            optionsLabeled("Passos de aprendizagem (min)") {
                TextField("1 10", text: $newStepsText)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 100)
            }
            if fsrsEnabled {
                Text("Deixe vazio para usar o agendamento de curto prazo do FSRS.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            if !fsrsEnabled {
                optionsStepper(
                    "Intervalo de graduação (d)",
                    value: Binding(
                        get: { config.new.ints.first ?? 1 },
                        set: {
                            if config.new.ints.isEmpty { config.new.ints = [$0, 4] }
                            else { config.new.ints[0] = $0 }
                        }
                    ),
                    range: 1...99
                )
                optionsStepper(
                    "Intervalo fácil (d)",
                    value: Binding(
                        get: { config.new.ints.count > 1 ? config.new.ints[1] : 4 },
                        set: {
                            if config.new.ints.isEmpty { config.new.ints = [1, $0] }
                            else if config.new.ints.count == 1 { config.new.ints.append($0) }
                            else { config.new.ints[1] = $0 }
                        }
                    ),
                    range: 1...99
                )
                optionsStepper(
                    "Fator inicial (%)",
                    value: Binding(
                        get: { config.new.initialFactor / 10 },
                        set: { config.new.initialFactor = $0 * 10 }
                    ),
                    range: 131...999
                )
            }
            optionsPicker("Ordem de inserção", selection: $config.new.order) {
                Text("deck-options.new-order.random").tag(0)
                Text("Data de adição").tag(1)
            }
            optionsPicker("Novos vs revisões", selection: $config.newMix) {
                Text("Misturar").tag(0)
                Text("Depois das revisões").tag(1)
                Text("Antes das revisões").tag(2)
            }
            optionsPicker("Aprend. interdiária vs revisões", selection: $config.interdayLearningMix) {
                Text("Misturar").tag(0)
                Text("Depois das revisões").tag(1)
                Text("Antes das revisões").tag(2)
            }
            optionsPicker("Prioridade ao reunir novos", selection: $config.newGatherPriority) {
                Text("deck-options.gather-priority.deck").tag(0)
                Text("Posição crescente").tag(1)
                Text("Posição decrescente").tag(2)
                Text("Notas aleatórias").tag(3)
                Text("Cartões aleatórios").tag(4)
                Text("Baralho, depois notas aleatórias").tag(5)
            }
            optionsPicker("Ordenação dos novos", selection: $config.newSortOrder) {
                Text("Tipo de cartão, depois ordem reunida").tag(0)
                Text("Ordem reunida").tag(1)
                Text("Tipo de cartão, depois aleatório").tag(2)
                Text("Nota aleatória, depois tipo").tag(3)
                Text("Cartões aleatórios").tag(4)
            }
            optionsToggle("Ocultar irmãos (novos)", isOn: $config.new.bury)
            optionsToggle("Novos ignoram o limite de revisão", isOn: $newCardsIgnoreReviewLimit)
            optionsStepper("Tempo máx. por resposta (s)", value: $config.maxTaken, range: 30...3600, step: 10)
        }
    }

    private var reviewsSection: some View {
        optionsCard("deck-options.reviews.section") {
            dailyLimitOptions(mode: $reviewLimitMode, presetValue: $config.rev.perDay, deckValue: $deckReviewLimit, todayValue: $todayReviewLimit, maximum: 9999, identifier: "review")
            optionsPicker("Ordem das revisões", selection: $config.reviewOrder) {
                Text("Vencimento, depois aleatória").tag(0)
                Text("Vencimento, depois baralho").tag(1)
                Text("Baralho, depois vencimento").tag(2)
                Text("Intervalo crescente").tag(3)
                Text("Intervalo decrescente").tag(4)
                Text("Facilidade crescente").tag(5)
                Text("Facilidade decrescente").tag(6)
                Text("Recuperabilidade crescente").tag(7)
                Text("deck-options.sort-order.random").tag(8)
                Text("Adicionadas primeiro").tag(9)
                Text("Adicionadas por último").tag(10)
                Text("Recuperabilidade decrescente").tag(11)
                Text("Atraso relativo").tag(12)
            }
            optionsStepper("Intervalo máx. (d)", value: $config.rev.maxIvl, range: 1...99999)
            if !fsrsEnabled {
                optionsStepper("Modificador de intervalo (%)", value: percentageBinding($config.rev.ivlFct, rounding: true), range: 0...999)
                optionsStepper("Fator de difícil (%)", value: percentageBinding($config.rev.hardFactor), range: 5...120)
                optionsStepper("Multiplicador de fácil (%)", value: percentageBinding($config.rev.ease4), range: 100...1000, step: 5)
            }
            optionsToggle("Ocultar irmãos (revisões)", isOn: $config.rev.bury)
        }
    }

    private var lapsesSection: some View {
        optionsCard("Lapsos") {
            optionsLabeled("Passos de reaprendizagem") {
                TextField("10", text: $lapseStepsText)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 100)
            }
            if fsrsEnabled {
                Text("Deixe vazio para usar o agendamento de curto prazo do FSRS.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            if !fsrsEnabled {
                optionsStepper("Multiplicador de lapso (%)", value: percentageBinding($config.lapse.mult), range: 0...100, step: 5)
            }
            optionsStepper("Intervalo mínimo (d)", value: $config.lapse.minInt, range: 1...99)
            optionsStepper("Limite de leech", value: $config.lapse.leechFails, range: 0...99)
            optionsPicker("Ação de leech", selection: $config.lapse.leechAction) {
                Text("Suspender").tag(0)
                Text("Apenas marcar tag").tag(1)
            }
        }
    }

    private var fsrsSection: some View {
        optionsCard("FSRS / Áudio") {
            if fsrsEnabled {
                optionsToggle("Retenção específica deste baralho", isOn: $useDeckRetentionOverride)
                if useDeckRetentionOverride {
                    optionsNumber("Retenção desejada", value: $deckRetentionOverride)
                }
                optionsNumber(
                    "Retenção padrão do preset",
                    value: Binding(
                        get: { config.desiredRetention ?? 0.9 },
                        set: { config.desiredRetention = $0 }
                    )
                )
                optionsToggle("Reagendar cartões ao alterar", isOn: $rescheduleCardsOnChange)
                Text("Afeta os cartões deste preset e adiciona uma entrada Manual ao histórico de cada cartão reagendado.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Busca para otimização FSRS")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppTheme.primaryText)
                    TextField("vazio usa todos os baralhos deste preset", text: Binding(
                        get: { config.paramSearch ?? "" },
                        set: { config.paramSearch = $0.isEmpty ? nil : $0 }
                    ), axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .foregroundStyle(AppTheme.primaryText)
                    .padding(12)
                    .ankiGlass(tint: .white.opacity(0.08), interactive: true, in: RoundedRectangle(cornerRadius: 12))
                }
                Button(action: optimizeFSRSParameters) {
                    HStack(spacing: 8) {
                        if isOptimizingFSRS { ProgressView().tint(AppTheme.primaryText) }
                        Text(isOptimizingFSRS ? "Otimizando…" : "Otimizar parâmetros FSRS")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.42, expands: true))
                .disabled(isOptimizingFSRS)
                .accessibilityIdentifier("deck.options.fsrs.optimize")
                Button("Otimizar todos os presets", action: optimizeAllFSRSParameters)
                    .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.16, expands: true))
                    .disabled(isOptimizingFSRS)
                    .accessibilityIdentifier("deck.options.fsrs.optimizeAll")
                optionsToggle("Verificar qualidade ao otimizar (lento)", isOn: $checkFSRSHealth)
                if let fsrsOptimizationStatus {
                    Text(fsrsOptimizationStatus)
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .accessibilityIdentifier("deck.options.fsrs.optimizationStatus")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pesos FSRS (separados por espaço)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppTheme.primaryText)
                    TextField("pesos…", text: Binding(
                        get: { (config.activeFSRSWeights ?? []).map { String($0) }.joined(separator: " ") },
                        set: {
                            let vals = $0.split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) }
                            config.fsrsParams6 = vals
                        }
                    ), axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...5)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(AppTheme.primaryText)
                    .accessibilityIdentifier("deck.options.fsrs.weights")
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .ankiGlass(tint: .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                optionsLabeled("Ignorar revisões antes de") {
                    TextField("AAAA-MM-DD", text: Binding(
                        get: { config.ignoreRevlogsBeforeDate ?? "" },
                        set: { raw in
                            let trimmed = raw.trimmingCharacters(in: .whitespaces)
                            config.ignoreRevlogsBeforeDate = trimmed.isEmpty ? nil : trimmed
                        }
                    ))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospacedDigit())
                    .frame(minWidth: 120)
                }
                optionsNumber(
                    "Retenção histórica",
                    value: Binding(
                        get: { config.historicalRetention },
                        set: { config.historicalRetention = $0 }
                    )
                )
                Text("Usada para estimar estados FSRS quando o histórico de revisão está incompleto.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            optionsToggle("Ocultar aprendizagem interdiária", isOn: $config.buryInterdayLearning)
            optionsToggle("Áudio automático", isOn: $config.autoplay)
            optionsToggle("Repetir áudio da pergunta", isOn: $config.replayq)
            optionsToggle("Mostrar cronômetro no estudo", isOn: Binding(
                get: { config.timer != 0 },
                set: { config.timer = $0 ? 1 : 0 }
            ))
            if config.timer != 0 {
                optionsToggle("Parar cronômetro ao mostrar resposta", isOn: $config.stopTimerOnAnswer)
            }
        }
    }


    private var autoAdvanceSection: some View {
        optionsCard("Avanço automático") {
            optionsLabeled("Pergunta (s)") {
                Text("\(Int(config.secondsToShowQuestion))")
                    .foregroundStyle(AppTheme.primaryText)
            }
            optionsLabeled("Resposta (s)") {
                Text("\(Int(config.secondsToShowAnswer))")
                    .foregroundStyle(AppTheme.primaryText)
            }
            Button("Configurar avanço automático…") { showAutoAdvance = true }
                .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.16, expands: true))
        }
    }

    // MARK: - Row helpers

    private func optionsCard<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        GlassFormSection(title: title, content: content)
    }

    private func optionsLabeled<Content: View>(_ title: LocalizedStringKey, @ViewBuilder trailing: () -> Content) -> some View {
        GlassOptionRow(title: title, trailing: trailing)
    }

    private func optionsToggle(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        GlassOptionRow(title: title) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .accessibilityLabel(title)
                .tint(AppTheme.accent)
        }
    }

    private func optionsStepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1, identifier: String? = nil) -> some View {
        optionsLabeled(LocalizedStringKey(title)) {
            HStack(spacing: 8) {
                Text("\(value.wrappedValue)")
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(minWidth: 44, alignment: .trailing)
                Stepper("", value: value, in: range, step: step)
                    .labelsHidden()
                .frame(width: 100)
                    .accessibilityIdentifier(identifier ?? "deck.options.stepper.\(title)")
            }
        }
    }

    private func optionsNumber(_ title: String, value: Binding<Double>) -> some View {
        optionsLabeled(LocalizedStringKey(title)) {
            TextField("0", value: value, format: .number)
                .textFieldStyle(.plain)
                .ankiKeyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .foregroundStyle(AppTheme.primaryText)
                .frame(width: 96)
                .accessibilityLabel(LocalizedStringKey(title))
                .accessibilityIdentifier("deck.options.number.\(title)")
        }
    }

    private func percentageBinding(_ value: Binding<Double>, rounding: Bool = false) -> Binding<Int> {
        Binding(
            get: {
                let percent = value.wrappedValue * 100
                return rounding ? Int(percent.rounded()) : Int(percent)
            },
            set: { value.wrappedValue = Double($0) / 100 }
        )
    }

    private func loadStepInputs() {
        newStepsText = config.new.delays.map(stepText).joined(separator: " ")
        lapseStepsText = config.lapse.delays.map(stepText).joined(separator: " ")
    }

    private func stepText(_ value: Double) -> String {
        value.rounded() == value && value >= Double(Int.min) && value < Double(Int.max) ? String(Int(value)) : String(value)
    }

    private func applyStepInputs() -> Bool {
        var valid = true
        let newSteps = parseSteps(newStepsText)
        if let newSteps, !newSteps.isEmpty || fsrsEnabled {
            config.new.delays = newSteps
        } else {
            store.lastError = newSteps == nil ? "Os passos devem conter apenas números positivos." : "É necessário informar pelo menos um passo de aprendizagem."
            valid = false
        }

        if let lapseSteps = parseSteps(lapseStepsText) {
            config.lapse.delays = lapseSteps
        } else {
            store.lastError = "Os passos de reaprendizagem devem conter apenas números positivos."
            valid = false
        }
        return valid
    }

    private func parseSteps(_ text: String) -> [Double]? {
        let values = text.components(separatedBy: " ").filter { !$0.isEmpty }
        var steps: [Double] = []
        for token in values {
            guard let value = Double(token), value.isFinite, value > 0 else { return nil }
            steps.append(value)
        }
        return steps
    }

    private func dailyLimitOptions(mode: Binding<String>, presetValue: Binding<Int>, deckValue: Binding<Int>, todayValue: Binding<Int>, maximum: Int, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            optionsPicker("Aplicar limite", selection: mode, identifier: "deck.options.limitMode.\(identifier)") {
                Text("Preset").tag("preset")
                Text("Este baralho").tag("deck")
                Text("Somente hoje").tag("today")
            }
            switch mode.wrappedValue {
            case "deck": optionsStepper("Limite deste baralho", value: deckValue, range: 0...maximum, identifier: "deck.options.limit.\(identifier).deck")
            case "today": optionsStepper("Limite de hoje", value: todayValue, range: 0...maximum, identifier: "deck.options.limit.\(identifier).today")
            default: optionsStepper("Limite do preset", value: presetValue, range: 0...maximum, identifier: "deck.options.limit.\(identifier).preset")
            }
        }
    }

    private func optionsPicker<SelectionValue: Hashable, Content: View>(
        _ title: String,
        selection: Binding<SelectionValue>,
        identifier: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        optionsLabeled(LocalizedStringKey(title)) {
            Picker("", selection: selection, content: content)
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 140, alignment: .trailing)
                .accessibilityIdentifier(identifier ?? "deck.options.picker.\(title)")
        }
    }

    private func selectConfig(_ newID: Int64) {
        guard newID != selectedConfID,
              applyStepInputs() else { return }
        updateWorkingConfig(config)
        guard let next = workingConfigs.first(where: { $0.id == newID }) else { return }
        selectedConfID = newID
        config = next
        loadStepInputs()
    }

    private func updateWorkingConfig(_ updated: AnkiDeckConfig) {
        if let index = workingConfigs.firstIndex(where: { $0.id == updated.id }) {
            workingConfigs[index] = updated
        } else {
            workingConfigs.append(updated)
        }
    }

    @discardableResult
    private func persistConfig() -> Bool {
        guard applyStepInputs() else { return false }
        config.mod = Int64(Date().timeIntervalSince1970)
        updateWorkingConfig(config)
        return true
    }

    private func deletePreset() {
        guard workingConfigs.count > 1 else { return }
        guard selectedConfID != 1 else {
            showDefaultPresetAlert = true
            return
        }
        guard persistConfig() else { return }
        let removedID = selectedConfID
        guard let next = workingConfigs.first(where: { $0.id != removedID }) else { return }
        if originalConfigs.contains(where: { $0.id == removedID }) {
            removedConfigIDs.insert(removedID)
        }
        workingConfigs.removeAll { $0.id == removedID }
        selectedConfID = next.id
        config = next
        loadStepInputs()
    }

    private func optimizeFSRSParameters() {
        guard !isOptimizingFSRS else { return }
        guard selectedConfID == baselineSelectedConfID else {
            fsrsOptimizationStatus = "Salve a troca de preset antes de otimizar os parâmetros."
            return
        }
        guard applyStepInputs() else { return }
        updateWorkingConfig(config)
        do {
            let trainingItems = try store.fsrsTrainingItems(configID: selectedConfID)
            let enableShortTerm = store.conf["fsrsShortTermWithStepsEnabled"] as? Bool
                ?? store.conf["fsrsShortTermWithSteps"] as? Bool ?? false
            let relearningSteps = max(config.lapse.delays.count, 1)
            let performHealthCheck = checkFSRSHealth
            let cardCount = Set(trainingItems.map(\.cardID)).count
            isOptimizingFSRS = true
            fsrsOptimizationStatus = "Treinando com o histórico de \(cardCount) cartões…"
            Task {
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        try FSRSParameterOptimizer.compute(
                            items: trainingItems,
                            enableShortTerm: enableShortTerm,
                            numRelearningSteps: relearningSteps,
                            healthCheck: performHealthCheck
                        )
                    }.value
                    config.fsrsParams6 = result.parameters
                    updateWorkingConfig(config)
                    if let health = result.health {
                        fsrsOptimizationStatus = "Parâmetros calculados para \(cardCount) cartões. Perda: \(health.logLoss.formatted(.number.precision(.fractionLength(3)))); RMSE: \(health.rmseBins.formatted(.number.precision(.fractionLength(3)))). Salve para aplicar."
                    } else if performHealthCheck {
                        fsrsOptimizationStatus = "Parâmetros calculados; o histórico não permitiu concluir a verificação de qualidade. Salve para aplicar."
                    } else {
                        fsrsOptimizationStatus = "Parâmetros calculados para \(cardCount) cartões. Salve para aplicar."
                    }
                } catch {
                    fsrsOptimizationStatus = error.localizedDescription
                }
                isOptimizingFSRS = false
            }
        } catch {
            fsrsOptimizationStatus = error.localizedDescription
        }
    }

    private func optimizeAllFSRSParameters() {
        guard !isOptimizingFSRS else { return }
        guard applyStepInputs() else { return }
        updateWorkingConfig(config)
        do {
            let presets = try workingConfigs.map { preset in
                (id: preset.id, items: try store.fsrsTrainingItems(configID: preset.id), steps: max(preset.lapse.delays.count, 1))
            }
            let usablePresets = presets.filter { $0.items.count >= 8 }
            guard !usablePresets.isEmpty else {
                fsrsOptimizationStatus = FSRSParameterOptimizer.OptimizerError.insufficientHistory.localizedDescription
                return
            }
            let enableShortTerm = store.conf["fsrsShortTermWithStepsEnabled"] as? Bool
                ?? store.conf["fsrsShortTermWithSteps"] as? Bool ?? false
            let performHealthCheck = checkFSRSHealth
            isOptimizingFSRS = true
            fsrsOptimizationStatus = "Otimizando \(usablePresets.count) presets…"
            Task {
                do {
                    let optimized = try await Task.detached(priority: .userInitiated) {
                        var results: [Int64: FSRSParameterOptimizer.Result] = [:]
                        for preset in usablePresets {
                            results[preset.id] = try FSRSParameterOptimizer.compute(
                                items: preset.items,
                                enableShortTerm: enableShortTerm,
                                numRelearningSteps: preset.steps,
                                healthCheck: performHealthCheck
                            )
                        }
                        return results
                    }.value
                    var updatedConfigs = workingConfigs
                    for index in updatedConfigs.indices {
                        if let weights = optimized[updatedConfigs[index].id] {
                            updatedConfigs[index].fsrsParams6 = weights.parameters
                        }
                    }
                    workingConfigs = updatedConfigs
                    if let selected = updatedConfigs.first(where: { $0.id == selectedConfID }) {
                        config = selected
                    }
                    if performHealthCheck {
                        let evaluated = optimized.values.compactMap(\.health)
                        if !evaluated.isEmpty {
                            let loss = evaluated.map(\.logLoss).reduce(0, +) / Double(evaluated.count)
                            let rmse = evaluated.map(\.rmseBins).reduce(0, +) / Double(evaluated.count)
                            fsrsOptimizationStatus = "Parâmetros calculados para \(optimized.count) presets. Médias de perda: \(loss.formatted(.number.precision(.fractionLength(3)))); RMSE: \(rmse.formatted(.number.precision(.fractionLength(3)))). Salve para aplicar."
                        } else {
                            fsrsOptimizationStatus = "Parâmetros calculados para \(optimized.count) presets; não foi possível verificar a qualidade do histórico. Salve para aplicar."
                        }
                    } else {
                        fsrsOptimizationStatus = "Parâmetros calculados para \(optimized.count) presets. Salve para aplicar."
                    }
                } catch {
                    fsrsOptimizationStatus = error.localizedDescription
                }
                isOptimizingFSRS = false
            }
        } catch {
            fsrsOptimizationStatus = error.localizedDescription
        }
    }

    private func save(applyToSubdecks: Bool = false, dismissAfterSave: Bool = true) {
        if fsrsEnabled {
            let presetRetention = config.desiredRetention ?? 0.9
            guard (0.7...0.99).contains(presetRetention),
                  (0.7...0.99).contains(config.historicalRetention),
                  !useDeckRetentionOverride || (0.7...0.99).contains(deckRetentionOverride) else {
                store.lastError = "As retenções devem ficar entre 70% e 99%."
                return
            }
        }
        guard persistConfig() else { return }
        let changedFSRSConfigIDs = workingConfigs.compactMap { updated -> Int64? in
            guard let original = originalConfigs.first(where: { $0.id == updated.id }) else {
                return updated.id
            }
            return fsrsSettingsChanged(from: original, to: updated) ? updated.id : nil
        }
        do {
            var decks = store.decks
            for index in decks.indices where removedConfigIDs.contains(decks[index].conf) {
                decks[index].conf = selectedConfID
            }
            if let index = decks.firstIndex(where: { $0.id == deck.id }) {
                decks[index].conf = selectedConfID
                let newLimits = applyLimit(mode: newLimitMode, value: deckNewLimit, todayValue: todayNewLimit)
                decks[index].newLimit = newLimits.permanent
                decks[index].newLimitToday = newLimits.todayLimit
                let reviewLimits = applyLimit(mode: reviewLimitMode, value: deckReviewLimit, todayValue: todayReviewLimit)
                decks[index].reviewLimit = reviewLimits.permanent
                decks[index].reviewLimitToday = reviewLimits.todayLimit
                if fsrsEnabled {
                    decks[index].desiredRetention = useDeckRetentionOverride ? deckRetentionOverride : nil
                }
            }
            if applyToSubdecks, let savedDeck = decks.first(where: { $0.id == deck.id }) {
                let prefix = savedDeck.name + "::"
                for index in decks.indices where decks[index].name.hasPrefix(prefix) && !decks[index].isFiltered {
                    decks[index].conf = selectedConfID
                }
            }
            try store.saveDeckConfigs(workingConfigs, updatedDecks: decks)
            var collectionConf = store.conf
            collectionConf["newCardsIgnoreReviewLimit"] = newCardsIgnoreReviewLimit
            collectionConf["fsrsHealthCheck"] = checkFSRSHealth
            try store.saveConf(collectionConf)

            if fsrsEnabled {
                var configsToRefresh = Set(changedFSRSConfigIDs)
                if selectedConfID != baselineSelectedConfID
                    || !removedConfigIDs.isEmpty
                    || (useDeckRetentionOverride ? deckRetentionOverride : nil) != baselineDeckRetention {
                    configsToRefresh.insert(selectedConfID)
                }
                for configID in configsToRefresh.sorted() {
                    _ = try store.updateFSRSMemoryStates(configID: configID, reschedule: rescheduleCardsOnChange)
                }
            }

            originalConfigs = workingConfigs
            removedConfigIDs.removeAll()
            baselineSelectedConfID = selectedConfID
            baselineDeckRetention = useDeckRetentionOverride ? deckRetentionOverride : nil
            baselineUseDeckRetentionOverride = useDeckRetentionOverride
            baselineDeckRetentionOverride = deckRetentionOverride
            baselineNewCardsIgnoreReviewLimit = newCardsIgnoreReviewLimit
            baselineNewLimitMode = newLimitMode
            baselineReviewLimitMode = reviewLimitMode
            baselineDeckNewLimit = deckNewLimit
            baselineDeckReviewLimit = deckReviewLimit
            baselineTodayNewLimit = todayNewLimit
            baselineTodayReviewLimit = todayReviewLimit
            baselineRescheduleCardsOnChange = rescheduleCardsOnChange
            baselineCheckFSRSHealth = checkFSRSHealth
            if dismissAfterSave {
                dismiss()
            }
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func fsrsSettingsChanged(from original: AnkiDeckConfig, to updated: AnkiDeckConfig) -> Bool {
        original.activeFSRSWeights != updated.activeFSRSWeights
            || original.desiredRetention != updated.desiredRetention
            || original.historicalRetention != updated.historicalRetention
            || original.ignoreRevlogsBeforeDate != updated.ignoreRevlogsBeforeDate
            || (rescheduleCardsOnChange && original.easyDayPercents != updated.easyDayPercents)
    }

    private func applyLimit(mode: String, value: Int, todayValue: Int) -> (permanent: Int?, todayLimit: AnkiDayLimit?) {
        switch mode {
        case "deck":
            return (value, nil)
        case "today":
            return (nil, AnkiDayLimit(limit: todayValue, today: store.schedDay()))
        default:
            return (nil, nil)
        }
    }
}

/// Anki's filtered-deck options: search, limit, order, reschedule, and preview delays.
struct FilteredDeckOptionsView: View {
    let deck: AnkiDeck
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = "is:due"
    @State private var limit = 100
    @State private var order = "due"
    @State private var search2 = ""
    @State private var useSecondSearch = false
    @State private var limit2 = 20
    @State private var order2 = "due"
    @State private var name = ""
    @State private var reschedule = true
    @State private var allowEmpty = false
    @State private var again = FilteredDeckSupport.previewAgainSeconds
    @State private var hard = FilteredDeckSupport.previewHardSeconds
    @State private var good = FilteredDeckSupport.previewGoodSeconds
    @State private var message: String?

    private var fsrsEnabled: Bool {
        store.fsrsEnabled
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        GlassFormSection(title: "decks.deck.label") {
                            TextField("Nome do baralho", text: $name)
                                .textFieldStyle(.plain)
                                .foregroundStyle(AppTheme.primaryText)
                                .padding(14)
                                .ankiGlass(tint: .white.opacity(0.08), interactive: true, in: RoundedRectangle(cornerRadius: 14))
                        }
                        GlassFormSection(title: "Busca") {
                            searchField("is:due", text: $search, lineLimit: 2...6)
                            GlassOptionRow(title: "Limite") {
                                Stepper("\(limit)", value: $limit, in: 1...99999)
                            }
                            orderMenu(selection: $order)
                            GlassOptionRow(title: "Reagendar as respostas") {
                                Toggle("", isOn: $reschedule)
                                    .labelsHidden()
                                    .tint(AppTheme.accent)
                            }
                            GlassOptionRow(title: "Criar mesmo sem cartões") {
                                Toggle("", isOn: $allowEmpty)
                                    .labelsHidden()
                                    .tint(AppTheme.accent)
                            }
                        }
                        GlassFormSection(title: "Segunda busca") {
                            GlassOptionRow(title: "Usar segunda busca") {
                                Toggle("", isOn: $useSecondSearch)
                                    .labelsHidden()
                                    .tint(AppTheme.accent)
                            }
                            if useSecondSearch {
                                searchField("opcional", text: $search2, lineLimit: 2...4)
                                GlassOptionRow(title: "Limite") {
                                    Stepper("\(limit2)", value: $limit2, in: 1...99999)
                                }
                                orderMenu(selection: $order2)
                            }
                        }
                        GlassFormSection(title: "Cartões ignorados") {
                            Text("Veja no Painel cartões que correspondem às buscas, mas estão suspensos, ocultos ou em outro baralho filtrado.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                            Button("Ver no Painel", systemImage: "magnifyingglass") {
                                store.requestBrowserSearch(hintSearchQuery)
                                dismiss()
                            }
                            .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.36, expands: true))
                        }
                        if !reschedule {
                            GlassFormSection(title: "Atrasos da pré-visualização") {
                                delayRow("De novo (s)", value: $again, range: 0...86400)
                                delayRow("Difícil (s)", value: $hard, range: 0...86400)
                                delayRow("Bom (s)", value: $good, range: 0...86400)
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                HStack(spacing: 12) {
                    Button("Fechar") { dismiss() }
                        .accessibilityIdentifier("deck.options.close")
                        .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.18, expands: true))
                    Button("Reconstruir") { save() }
                        .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.42, expands: true))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .background(AppBackground())
            .navigationTitle("deck-options.title")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: load)
            .alert("Baralho filtrado", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }

    private func orderMenu(selection: Binding<String>) -> some View {
        GlassOptionRow(title: "Ordem") {
            Picker("", selection: selection) {
                Text("Ordem de vencimento").tag("due")
                Text("Vistos há mais tempo").tag("oldest")
                Text("deck-options.filtered-order.random").tag("random")
                Text("Ordem de adição").tag("added")
                Text("Adicionados mais recentemente").tag("latest")
                Text("Intervalos crescentes").tag("ivl")
                Text("Intervalos decrescentes").tag("ivlDesc")
                Text("Mais falhas").tag("lapses")
                if fsrsEnabled {
                    Text("Menor recuperabilidade primeiro").tag("retrievability")
                    Text("Maior recuperabilidade primeiro").tag("retrievabilityDesc")
                }
                Text("Atraso relativo").tag("relative")
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private func searchField(_ placeholder: String, text: Binding<String>, lineLimit: ClosedRange<Int>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            TextField(placeholder, text: text, axis: .vertical)
                .textFieldStyle(.plain)
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(lineLimit)
                .padding(14)
                .ankiGlass(tint: .white.opacity(0.08), interactive: true, in: RoundedRectangle(cornerRadius: 14))
            Button {
                store.requestBrowserSearch(text.wrappedValue)
                dismiss()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(GlassChipButtonStyle())
            .accessibilityLabel("Buscar no Painel")
            .help("Buscar no Painel")
        }
    }

    private var hintSearchQuery: String {
        let manualTerms = [search] + (useSecondSearch ? [search2] : [])
        let manual = manualTerms.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ? nil
            : "(" + manualTerms.map { "(\($0))" }.joined(separator: " OR ") + ")"
        let filteredDecks = deck.isFiltered && deck.id != 0
            ? "(deck:filtered -did:\(deck.id))"
            : "deck:filtered"
        let implicit = "(is:suspended OR is:buried OR \(filteredDecks))"
        return [manual, implicit].compactMap { $0 }.joined(separator: " ")
    }

    private func delayRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        GlassOptionRow(title: LocalizedStringKey(title)) {
            Stepper("\(value.wrappedValue)", value: value, in: range)
        }
    }

    private func load() {
        let live = store.decks.first { $0.id == deck.id } ?? deck
        name = live.name
        search = live.searchTerms ?? "is:due"
        limit = live.termLimit ?? 100
        order = normalizedOrder(live.searchOrder ?? "due")
        search2 = live.searchTerms2 ?? ""
        useSecondSearch = live.id != 0 && live.searchTerms2 != nil
        limit2 = live.termLimit2 ?? 20
        order2 = normalizedOrder(live.searchOrder2 ?? "due")
        reschedule = live.resched ?? true
        again = live.previewAgain ?? FilteredDeckSupport.previewAgainSeconds
        hard = live.previewHard ?? FilteredDeckSupport.previewHardSeconds
        good = live.previewGood ?? FilteredDeckSupport.previewGoodSeconds
    }

    private func normalizedOrder(_ value: String) -> String {
        guard !fsrsEnabled, (value == "retrievability" || value == "retrievabilityDesc") else { return value }
        return "random"
    }

    private func save() {
        do {
            try store.saveFilteredDeck(
                deck,
                name: name,
                search: search.trimmingCharacters(in: .whitespacesAndNewlines),
                limit: limit,
                order: order,
                reschedule: reschedule,
                again: again,
                hard: hard,
                good: good,
                allowEmpty: allowEmpty,
                search2: useSecondSearch ? search2 : nil,
                limit2: limit2,
                order2: order2
            )
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}
