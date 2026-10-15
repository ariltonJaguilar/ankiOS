import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject private var store: CollectionStore
    @State private var rollday: Double = 4
    @State private var useFSRS = false
    @State private var showDueCounts = true
    @State private var estTimes = true
    @State private var dayLearnFirst = false
    @State private var collapseTime = 1200
    @State private var newSpread = 0
    @State private var addToCur = true
    @State private var timeLim = 0
    @State private var sortType = 0
    @State private var schedVer = 2
    @State private var cardZoom: Double = 1.0
    @State private var applyParents = true
    @State private var interruptAudio = true
    @State private var fsrsShortTerm = false
    @State private var showAutoAdvance = false

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
                                    .foregroundStyle(.white)
                                Slider(value: $rollday, in: 0...23, step: 1)
                            }
                        }
                        glassToggle("Aprendizagem interdiária primeiro", isOn: $dayLearnFirst)
                        glassToggle("Aplicar limites dos baralhos pai", isOn: $applyParents)
                        glassPicker("Distribuição de novos", selection: $newSpread) {
                            Text("Misturar com revisões").tag(0)
                            Text("Novos depois das revisões").tag(1)
                            Text("Novos antes das revisões").tag(2)
                        }
                        glassStepper("Limite por cartão (s)", value: $timeLim, range: 0...120, step: 5, display: timeLim == 0 ? "off" : "\(timeLim)")
                    }
                    GlassFormSection(title: "Avanço automático") {
                        Text("O mesmo controle do menu Mais, na tela de estudo.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(.horizontal, 4)
                        Button("Ajustar avanço automático") { showAutoAdvance = true }
                            .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.16, expands: true))
                    }
                    GlassFormSection(title: "Interface") {
                        glassToggle("Mostrar contagens due", isOn: $showDueCounts)
                        glassToggle("Interromper áudio ao responder", isOn: $interruptAudio)
                        glassToggle("Mostrar tempos estimados", isOn: $estTimes)
                        glassToggle("Adicionar ao baralho atual", isOn: $addToCur)
                        glassStepper("Janela de aprendizagem (s)", value: $collapseTime, range: 0...7200, step: 60, display: "\(collapseTime)")
                        GlassInset {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Zoom dos cartões: \(String(format: "%.0f%%", cardZoom * 100))")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.white)
                                Slider(value: $cardZoom, in: 0.7...1.6, step: 0.05)
                            }
                        }
                        glassPicker("Ordem da fila", selection: $sortType) {
                            Text("Ordem de adição").tag(0)
                            Text("Ordem relativa").tag(1)
                        }
                    }
                    GlassFormSection(title: "Avançado") {
                        GlassOptionRow(title: "Versão do agendador") {
                            Text("v\(schedVer)")
                                .font(.body.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        Text("AnkiOS usa o modelo de filas do Anki 2.1. Contas e AnkiWeb ficam de fora.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(.horizontal, 4)
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
        .sheet(isPresented: $showAutoAdvance) {
            AutoAdvanceSheet()
                .environmentObject(store)
        }
    }

    private func glassToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        GlassOptionRow(title: title) {
            Toggle("", isOn: isOn).labelsHidden().tint(AppTheme.accent)
        }
    }

    private func glassStepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int, display: String) -> some View {
        GlassOptionRow(title: title) {
            HStack(spacing: 8) {
                Text(display)
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 44, alignment: .trailing)
                Stepper("", value: value, in: range, step: step)
                    .labelsHidden()
                    .frame(width: 100)
            }
        }
    }

    private func glassPicker<Content: View>(_ title: String, selection: Binding<Int>, @ViewBuilder content: () -> Content) -> some View {
        GlassOptionRow(title: title) {
            Picker("", selection: selection, content: content)
                .labelsHidden()
                .pickerStyle(.menu)
        }
    }

    private func load() {
        rollday = Double(store.conf["rollday"] as? Int ?? 4)
        useFSRS = (store.conf["scheduler"] as? String)?.lowercased() == "fsrs"
        showDueCounts = store.conf["dueCounts"] as? Bool ?? true
        estTimes = store.conf["estTimes"] as? Bool ?? true
        dayLearnFirst = store.conf["dayLearnFirst"] as? Bool ?? false
        collapseTime = store.conf["collapseTime"] as? Int ?? 1200
        newSpread = store.conf["newSpread"] as? Int ?? 0
        addToCur = store.conf["addToCur"] as? Bool ?? true
        timeLim = store.conf["timeLim"] as? Int ?? 0
        sortType = store.conf["sortType"] as? Int ?? 0
        schedVer = store.conf["schedVer"] as? Int ?? 2
        cardZoom = store.conf["cardZoom"] as? Double ?? 1.0
        applyParents = store.conf["applyAllParentLimits"] as? Bool ?? true
        interruptAudio = store.conf["interruptAudio"] as? Bool ?? true
        fsrsShortTerm = store.conf["fsrsShortTermWithSteps"] as? Bool ?? false
    }

    private func save() {
        var conf = store.conf
        conf["rollday"] = Int(rollday)
        conf["scheduler"] = useFSRS ? "fsrs" : "sm2"
        conf["dueCounts"] = showDueCounts
        conf["estTimes"] = estTimes
        conf["dayLearnFirst"] = dayLearnFirst
        conf["collapseTime"] = collapseTime
        conf["newSpread"] = newSpread
        conf["addToCur"] = addToCur
        conf["timeLim"] = timeLim
        conf["sortType"] = sortType
        conf["schedVer"] = schedVer
        conf["cardZoom"] = cardZoom
        conf["applyAllParentLimits"] = applyParents
        conf["interruptAudio"] = interruptAudio
        conf["fsrsShortTermWithSteps"] = fsrsShortTerm
        try? store.saveConf(conf)
        store.lastError = "Preferências salvas."
    }
}

/// Anki reviewer auto advance: wait on the question, then on the answer.
struct AutoAdvanceSheet: View {
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.dismiss) private var dismiss
    @State private var questionSeconds = 0
    @State private var answerSeconds = 0
    @State private var waitForAudio = true
    @State private var questionAction = "show"
    @State private var answerAction = "good"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        GlassFormSection(title: "Tempo") {
                            GlassOptionRow(title: "Pergunta (s)") {
                                Stepper("\(questionSeconds)", value: $questionSeconds, in: 0...120)
                            }
                            GlassOptionRow(title: "Resposta (s)") {
                                Stepper("\(answerSeconds)", value: $answerSeconds, in: 0...120)
                            }
                            GlassOptionRow(title: "Esperar o áudio") {
                                Toggle("", isOn: $waitForAudio)
                                    .labelsHidden()
                                    .tint(AppTheme.accent)
                            }
                        }
                        GlassFormSection(title: "Ação") {
                            actionMenu("Na pergunta", selection: $questionAction, includeShow: true)
                            actionMenu("Na resposta", selection: $answerAction, includeShow: false)
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

    private func actionMenu(_ title: String, selection: Binding<String>, includeShow: Bool) -> some View {
        GlassOptionRow(title: title) {
            Picker("", selection: selection) {
                if includeShow { Text("Mostrar resposta").tag("show") }
                Text("De novo").tag("again")
                Text("Difícil").tag("hard")
                Text("Bom").tag("good")
                Text("Fácil").tag("easy")
                Text("Ocultar").tag("bury")
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private func load() {
        questionSeconds = Self.confInt(store.conf["autoAdvanceQuestion"])
        answerSeconds = Self.confInt(store.conf["autoAdvanceAnswer"])
        waitForAudio = store.conf["autoAdvanceWaitAudio"] as? Bool ?? true
        questionAction = store.conf["autoAdvanceQuestionAction"] as? String ?? "show"
        answerAction = store.conf["autoAdvanceAnswerAction"] as? String ?? "good"
    }

    private func save() {
        var conf = store.conf
        conf["autoAdvanceQuestion"] = questionSeconds
        conf["autoAdvanceAnswer"] = answerSeconds
        conf["autoAdvanceWaitAudio"] = waitForAudio
        conf["autoAdvanceQuestionAction"] = questionAction
        conf["autoAdvanceAnswerAction"] = answerAction
        try? store.saveConf(conf)
        dismiss()
    }

    static func confInt(_ value: Any?) -> Int {
        if let n = value as? Int { return n }
        if let n = value as? Double { return Int(n) }
        if let n = value as? NSNumber { return n.intValue }
        return 0
    }
}
