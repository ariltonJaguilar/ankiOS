import SwiftUI

struct DeckOptionsView: View {
    let deck: AnkiDeck
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.dismiss) private var dismiss
    @State private var config: AnkiDeckConfig = .default()
    @State private var selectedConfID: Int64 = 1

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
                        lapsesSection
                        fsrsSection
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
            .navigationTitle("Opções do baralho")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .onAppear {
                config = store.config(for: deck)
                selectedConfID = deck.conf
            }
            .onChange(of: config.new.perDay) { _, newValue in
                guard store.config(for: deck).new.perDay != newValue else { return }
                persistConfig()
            }
            .onChange(of: config.rev.perDay) { _, newValue in
                guard store.config(for: deck).rev.perDay != newValue else { return }
                persistConfig()
            }
            #if os(macOS)
            .frame(minWidth: 560, minHeight: 640)
            #endif
        }
    }

    // MARK: - Sections

    private var easyDaysSection: some View {
        let names = ["Seg", "Ter", "Qua", "Qui", "Sex", "Sáb", "Dom"]
        return VStack(alignment: .leading, spacing: 8) {
            Text("Dias fáceis")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
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
            }
            optionsLabeled("Usar preset") {
                Picker("", selection: $selectedConfID) {
                    ForEach(store.deckConfigs) { cfg in
                        Text(cfg.name).tag(cfg.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onChange(of: selectedConfID) { _, newID in
                    var decks = store.decks
                    if let idx = decks.firstIndex(where: { $0.id == deck.id }) {
                        decks[idx].conf = newID
                        try? store.saveDecks(decks)
                    }
                    if let cfg = store.deckConfigs.first(where: { $0.id == newID }) {
                        config = cfg
                    }
                }
            }
            Button("Duplicar preset") {
                var copy = config
                copy.id = store.timestampID()
                copy.name = "\(config.name) cópia"
                copy.mod = Int64(Date().timeIntervalSince1970)
                var configs = store.deckConfigs
                configs.append(copy)
                try? store.saveDeckConfigs(configs)
                selectedConfID = copy.id
                config = copy
            }
            .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.16, expands: true))
            Button("Apagar preset") { deletePreset() }
                .buttonStyle(GlassButtonStyle(tint: AppTheme.danger, tintStrength: 0.28, expands: true))
                .disabled(store.deckConfigs.count < 2)
            Button("Aplicar aos sub-baralhos") {
                persistConfig()
                try? store.applyPresetToSubdecks(of: deck)
            }
            .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.16, expands: true))
        }
    }

    private var newCardsSection: some View {
        optionsCard("Cartões novos") {
            optionsStepper("Por dia", value: $config.new.perDay, range: 0...999)
            optionsLabeled("Passos de aprendizagem (min)") {
                TextField("1 10", text: Binding(
                    get: { config.new.delays.map { String(Int($0)) }.joined(separator: " ") },
                    set: { config.new.delays = $0.split(separator: " ").compactMap { Double($0) } }
                ))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 100)
            }
            optionsStepper(
                "Intervalo de graduação (d)",
                value: Binding(
                    get: { config.new.ints.first ?? 1 },
                    set: {
                        if config.new.ints.isEmpty { config.new.ints = [$0, 4] }
                        else { config.new.ints[0] = $0 }
                    }
                ),
                range: 1...365
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
                range: 1...365
            )
            optionsStepper("Fator inicial", value: $config.new.initialFactor, range: 1300...5000, step: 50)
            optionsPicker("Ordem dos novos", selection: $config.new.order) {
                Text("Baralho").tag(0)
                Text("Aleatória").tag(1)
            }
            optionsPicker("Novos vs revisões", selection: $config.newMix) {
                Text("Misturar").tag(0)
                Text("Depois das revisões").tag(1)
                Text("Antes das revisões").tag(2)
            }
            optionsStepper("Mínimo de novos/dia", value: $config.newPerDayMinimum, range: 0...999)
            optionsPicker("Aprend. interdiária vs revisões", selection: $config.interdayLearningMix) {
                Text("Misturar").tag(0)
                Text("Depois das revisões").tag(1)
                Text("Antes das revisões").tag(2)
            }
            optionsPicker("Prioridade ao reunir novos", selection: $config.newGatherPriority) {
                Text("Baralho / posição ↑").tag(0)
                Text("Baralho invertido").tag(1)
                Text("Posição ↑").tag(2)
                Text("Posição ↓").tag(3)
                Text("Notas aleatórias").tag(4)
                Text("Cartões aleatórios").tag(5)
            }
            optionsToggle("Ocultar irmãos (novos)", isOn: $config.new.bury)
            optionsToggle("Novos ignoram o limite de revisão", isOn: $config.newIgnoreRevLimit)
            optionsStepper("Tempo máx. por resposta (s)", value: $config.maxTaken, range: 1...300)
        }
    }

    private var reviewsSection: some View {
        optionsCard("Revisões") {
            optionsStepper("Por dia", value: $config.rev.perDay, range: 0...9999)
            optionsPicker("Ordem das revisões", selection: $config.reviewOrder) {
                Text("Data due").tag(0)
                Text("Aleatória").tag(1)
                Text("Intervalo ↑").tag(2)
                Text("Intervalo ↓").tag(3)
                Text("Facilidade ↑").tag(4)
                Text("Facilidade ↓").tag(5)
            }
            optionsStepper("Intervalo máx. (d)", value: $config.rev.maxIvl, range: 1...36500)
            optionsNumber("Modificador de intervalo", value: $config.rev.ivlFct)
            optionsNumber("Fator de difícil", value: $config.rev.hardFactor)
            optionsNumber("Multiplicador de fácil", value: $config.rev.ease4)
            optionsNumber("Fuzz", value: $config.rev.fuzz)
            optionsToggle("Ocultar irmãos (revisões)", isOn: $config.rev.bury)
        }
    }

    private var lapsesSection: some View {
        optionsCard("Lapsos") {
            optionsLabeled("Passos de reaprendizagem") {
                TextField("10", text: Binding(
                    get: { config.lapse.delays.map { String(Int($0)) }.joined(separator: " ") },
                    set: { config.lapse.delays = $0.split(separator: " ").compactMap { Double($0) } }
                ))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 100)
            }
            optionsNumber("Multiplicador de lapso", value: $config.lapse.mult)
            optionsStepper("Intervalo mínimo (d)", value: $config.lapse.minInt, range: 1...100)
            optionsStepper("Limite de leech", value: $config.lapse.leechFails, range: 1...50)
            optionsPicker("Ação de leech", selection: $config.lapse.leechAction) {
                Text("Suspender").tag(0)
                Text("Apenas marcar tag").tag(1)
            }
        }
    }

    private var fsrsSection: some View {
        optionsCard("FSRS / Áudio") {
            optionsNumber(
                "Retenção desejada",
                value: Binding(
                    get: { config.desiredRetention ?? 0.9 },
                    set: { config.desiredRetention = $0 }
                )
            )
            VStack(alignment: .leading, spacing: 8) {
                Text("Pesos FSRS (separados por espaço)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                TextField("pesos…", text: Binding(
                    get: { (config.fsrsWeights ?? []).map { String($0) }.joined(separator: " ") },
                    set: {
                        let vals = $0.split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) }
                        config.fsrsWeights = vals.isEmpty ? nil : vals
                    }
                ), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...5)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(.white.opacity(0.08)), in: .rect(cornerRadius: 14))
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
            optionsToggle("Ocultar aprendizagem interdiária", isOn: $config.buryInterdayLearning)
            easyDaysSection
            optionsToggle("Áudio automático", isOn: $config.autoplay)
            optionsToggle("Repetir áudio da pergunta", isOn: $config.replayq)
            optionsToggle("Mostrar cronômetro no estudo", isOn: Binding(
                get: { config.timer != 0 },
                set: { config.timer = $0 ? 1 : 0 }
            ))
        }
    }

    // MARK: - Row helpers

    private func optionsCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GlassFormSection(title: title, content: content)
    }

    private func optionsLabeled<Content: View>(_ title: String, @ViewBuilder trailing: () -> Content) -> some View {
        GlassOptionRow(title: title, trailing: trailing)
    }

    private func optionsToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        optionsLabeled(title) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(AppTheme.accent)
        }
    }

    private func optionsStepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1) -> some View {
        optionsLabeled(title) {
            HStack(spacing: 8) {
                Text("\(value.wrappedValue)")
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 44, alignment: .trailing)
                Stepper("", value: value, in: range, step: step)
                    .labelsHidden()
                    .frame(width: 100)
            }
        }
    }

    private func optionsNumber(_ title: String, value: Binding<Double>) -> some View {
        optionsLabeled(title) {
            TextField("0", value: value, format: .number)
                .textFieldStyle(.plain)
                .ankiKeyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 96)
        }
    }

    private func optionsPicker<SelectionValue: Hashable, Content: View>(
        _ title: String,
        selection: Binding<SelectionValue>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        optionsLabeled(title) {
            Picker("", selection: selection, content: content)
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 140, alignment: .trailing)
        }
    }

    /// Writes the preset immediately. Every deck that uses it picks up the new
    /// daily limits in the same moment, which is what Anki does.
    private func persistConfig() {
        config.mod = Int64(Date().timeIntervalSince1970)
        var configs = store.deckConfigs
        if let idx = configs.firstIndex(where: { $0.id == config.id }) {
            configs[idx] = config
        } else {
            configs.append(config)
        }
        try? store.saveDeckConfigs(configs)
    }

    private func deletePreset() {
        guard store.deckConfigs.count > 1 else { return }
        let fallback = store.deckConfigs.first { $0.id != config.id }?.id ?? 1
        var decks = store.decks
        var moved = false
        for index in decks.indices where decks[index].conf == config.id && !decks[index].isFiltered {
            decks[index].conf = fallback
            moved = true
        }
        if moved { try? store.saveDecks(decks) }
        var configs = store.deckConfigs
        configs.removeAll { $0.id == config.id }
        try? store.saveDeckConfigs(configs)
        if let next = store.deckConfigs.first(where: { $0.id == fallback }) ?? store.deckConfigs.first {
            selectedConfID = next.id
            config = next
        }
    }

    private func save() {
        persistConfig()
        dismiss()
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
    @State private var limit2 = 100
    @State private var order2 = "due"
    @State private var reschedule = true
    @State private var again = FilteredDeckSupport.previewAgainSeconds
    @State private var hard = FilteredDeckSupport.previewHardSeconds
    @State private var good = FilteredDeckSupport.previewGoodSeconds
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        GlassFormSection(title: "Busca") {
                            TextField("is:due", text: $search, axis: .vertical)
                                .textFieldStyle(.plain)
                                .foregroundStyle(.white)
                                .lineLimit(2...6)
                                .padding(14)
                                .glassEffect(.regular.tint(.white.opacity(0.08)), in: .rect(cornerRadius: 14))
                            GlassOptionRow(title: "Limite") {
                                Stepper("\(limit)", value: $limit, in: 1...99999)
                            }
                            orderMenu(selection: $order)
                            GlassOptionRow(title: "Reagendar as respostas") {
                                Toggle("", isOn: $reschedule)
                                    .labelsHidden()
                                    .tint(AppTheme.accent)
                            }
                        }
                        GlassFormSection(title: "Segunda busca") {
                            TextField("opcional", text: $search2, axis: .vertical)
                                .textFieldStyle(.plain)
                                .foregroundStyle(.white)
                                .lineLimit(2...4)
                                .padding(14)
                                .glassEffect(.regular.tint(.white.opacity(0.08)), in: .rect(cornerRadius: 14))
                            GlassOptionRow(title: "Limite") {
                                Stepper("\(limit2)", value: $limit2, in: 1...99999)
                            }
                            orderMenu(selection: $order2)
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
                        .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.18, expands: true))
                    Button("Reconstruir") { save() }
                        .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, tintStrength: 0.42, expands: true))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .background(AppBackground())
            .navigationTitle("Opções do baralho")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .onAppear(perform: load)
            .alert("Baralho filtrado", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
            #if os(macOS)
            .frame(minWidth: 560, minHeight: 520)
            #endif
        }
    }

    private func orderMenu(selection: Binding<String>) -> some View {
        GlassOptionRow(title: "Ordem") {
            Picker("", selection: selection) {
                Text("Ordem de vencimento").tag("due")
                Text("Aleatória").tag("random")
                Text("Ordem de adição").tag("added")
                Text("Intervalos crescentes").tag("ivl")
                Text("Intervalos decrescentes").tag("ivlDesc")
                Text("Mais falhas").tag("lapses")
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private func delayRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        GlassOptionRow(title: title) {
            Stepper("\(value.wrappedValue)", value: value, in: range)
        }
    }

    private func load() {
        let live = store.decks.first { $0.id == deck.id } ?? deck
        search = live.searchTerms ?? "is:due"
        limit = live.termLimit ?? 100
        order = live.searchOrder ?? "due"
        search2 = live.searchTerms2 ?? ""
        limit2 = live.termLimit2 ?? 100
        order2 = live.searchOrder2 ?? "due"
        reschedule = live.resched ?? true
        again = live.previewAgain ?? FilteredDeckSupport.previewAgainSeconds
        hard = live.previewHard ?? FilteredDeckSupport.previewHardSeconds
        good = live.previewGood ?? FilteredDeckSupport.previewGoodSeconds
    }

    private func save() {
        do {
            try store.saveFilteredDeck(
                deck,
                search: search.trimmingCharacters(in: .whitespacesAndNewlines),
                limit: limit,
                order: order,
                reschedule: reschedule,
                again: again,
                hard: hard,
                good: good,
                search2: search2,
                limit2: limit2,
                order2: order2
            )
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}
