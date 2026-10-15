import SwiftUI
import Charts

struct StatsHomeView: View {
    @EnvironmentObject private var store: CollectionStore
    @State private var todayCount = 0
    @State private var todayTimeMS = 0
    @State private var future: [Int: Int] = [:]
    @State private var recent: [AnkiRevlog] = []
    @State private var againCount = 0
    @State private var hardCount = 0
    @State private var goodCount = 0
    @State private var easyCount = 0
    @State private var buttonCounts: [Int: Int] = [:]
    @State private var calendar: [Int: Int] = [:]
    @State private var heatmap: [Int: Int] = [:]
    @State private var intervals: [(label: String, count: Int)] = []
    @State private var states: (new: Int, learn: Int, review: Int, suspended: Int, buried: Int) = (0, 0, 0, 0, 0)
    @State private var byHour: [Int: Int] = [:]
    @State private var added: [Int: Int] = [:]
    @State private var filterDeckID: Int64?
    @State private var rangeDays = 31
    @State private var reviewDays: [CollectionStore.ReviewDayPoint] = []
    @State private var retention = CollectionStore.TrueRetention()
    @State private var easeBars: [(label: String, count: Int)] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    GlassCard {
                        Picker("Baralho", selection: $filterDeckID) {
                            Text("Toda a coleção").tag(Int64?.none)
                            ForEach(store.decks.filter { !$0.isFiltered }) { deck in
                                Text(deck.name).tag(Optional(deck.id))
                            }
                        }
                        .onChange(of: filterDeckID) { _, _ in reload() }
                        Picker("Período", selection: $rangeDays) {
                            Text("1 mês").tag(31)
                            Text("3 meses").tag(90)
                            Text("1 ano").tag(365)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: rangeDays) { _, _ in reload() }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Hoje")
                                .font(AppTheme.deckFont)
                                .foregroundStyle(AppTheme.primaryText)
                            Text("\(todayCount)")
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .foregroundStyle(AppTheme.accent)
                                .shadow(color: AppTheme.accent.opacity(0.4), radius: 8)
                            Text("cartões estudados · \(formattedTime)")
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Adicionados (30 dias)")
                                .font(AppTheme.deckFont)
                            Chart {
                                ForEach(0..<30, id: \.self) { day in
                                    BarMark(
                                        x: .value("Dia", 29 - day),
                                        y: .value("N", added[day] ?? 0)
                                    )
                                    .foregroundStyle(AppTheme.easy.gradient)
                                }
                            }
                            .frame(height: 140)
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Por hora (24h)")
                                .font(AppTheme.deckFont)
                            Chart {
                                ForEach(0..<24, id: \.self) { hour in
                                    BarMark(
                                        x: .value("Hora", hour),
                                        y: .value("N", byHour[hour] ?? 0)
                                    )
                                    .foregroundStyle(AppTheme.warn.gradient)
                                }
                            }
                            .frame(height: 140)
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Botões de resposta")
                                .font(AppTheme.deckFont)
                            Chart {
                                BarMark(x: .value("Botão", "De novo"), y: .value("N", buttonCounts[1] ?? 0))
                                    .foregroundStyle(AppTheme.danger)
                                BarMark(x: .value("Botão", "Difícil"), y: .value("N", buttonCounts[2] ?? 0))
                                    .foregroundStyle(AppTheme.warn)
                                BarMark(x: .value("Botão", "Bom"), y: .value("N", buttonCounts[3] ?? 0))
                                    .foregroundStyle(AppTheme.good)
                                BarMark(x: .value("Botão", "Fácil"), y: .value("N", buttonCounts[4] ?? 0))
                                    .foregroundStyle(AppTheme.easy)
                            }
                            .frame(height: 160)
                            Text("De novo \(buttonCounts[1] ?? 0) · Difícil \(buttonCounts[2] ?? 0) · Bom \(buttonCounts[3] ?? 0) · Fácil \(buttonCounts[4] ?? 0)")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Próximas revisões (30 dias)")
                                .font(AppTheme.deckFont)
                            Chart {
                                ForEach(0..<30, id: \.self) { day in
                                    BarMark(
                                        x: .value("Dia", day),
                                        y: .value("Cartões", future[day] ?? 0)
                                    )
                                    .foregroundStyle(AppTheme.accent.gradient)
                                }
                            }
                            .frame(height: 180)
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Revisões")
                                .font(AppTheme.deckFont)
                            Chart {
                                ForEach(reviewSeries, id: \.name) { series in
                                    ForEach(reviewDays) { day in
                                        BarMark(
                                            x: .value("Dia", rangeDays - 1 - day.offset),
                                            y: .value("N", series.value(day))
                                        )
                                        .foregroundStyle(by: .value("Tipo", series.name))
                                    }
                                }
                            }
                            .chartForegroundStyleScale([
                                "Aprender": AppTheme.easy,
                                "Jovem": AppTheme.accent,
                                "Maduro": AppTheme.good,
                                "Reaprender": AppTheme.danger,
                                "Filtrado": AppTheme.warn
                            ])
                            .frame(height: 180)
                            Text("Aprender, jovem (<21d), maduro, reaprender e filtrado.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Retenção verdadeira")
                                .font(AppTheme.deckFont)
                            LabeledContent("Jovem", value: retentionLabel(retention.youngPercent, pass: retention.youngPass, fail: retention.youngFail))
                            LabeledContent("Maduro", value: retentionLabel(retention.maturePercent, pass: retention.maturePass, fail: retention.matureFail))
                            Text("Respostas de revisão. Acertar é qualquer botão menos De novo. Jovem é intervalo menor que 21 dias.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Facilidade")
                                .font(AppTheme.deckFont)
                            Chart {
                                ForEach(Array(easeBars.enumerated()), id: \.offset) { _, item in
                                    BarMark(
                                        x: .value("Fator", item.label),
                                        y: .value("Cartões", item.count)
                                    )
                                    .foregroundStyle(AppTheme.mist.gradient)
                                }
                            }
                            .frame(height: 160)
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Retenção recente")
                                .font(AppTheme.deckFont)
                            let total = max(againCount + hardCount + goodCount + easyCount, 1)
                            let pct = Double(goodCount + easyCount) / Double(total) * 100
                            Text(String(format: "%.0f%%", pct))
                                .font(.system(size: 36, weight: .bold, design: .rounded))
                                .foregroundStyle(AppTheme.good)
                            Text("Bom+Fácil / total (últimas \(recent.count) revisões)")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Intervalos")
                                .font(AppTheme.deckFont)
                            Chart {
                                ForEach(Array(intervals.enumerated()), id: \.offset) { _, item in
                                    BarMark(
                                        x: .value("Faixa", item.label),
                                        y: .value("Cartões", item.count)
                                    )
                                    .foregroundStyle(AppTheme.mist.gradient)
                                }
                            }
                            .frame(height: 160)
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Calendário (14 dias)")
                                .font(AppTheme.deckFont)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 8) {
                                ForEach(0..<14, id: \.self) { day in
                                    let count = calendar[day] ?? 0
                                    VStack(spacing: 4) {
                                        Text(day == 0 ? "hoje" : "-\(day)")
                                            .font(.caption2)
                                            .foregroundStyle(AppTheme.secondaryText)
                                        Text("\(count)")
                                            .font(.caption.monospacedDigit().weight(.bold))
                                            .foregroundStyle(count > 0 ? AppTheme.accent : .secondary)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(8)
                                    .glassEffect(.regular.tint(AppTheme.accent.opacity(count > 0 ? 0.25 : 0.05)), in: .rect(cornerRadius: 10))
                                }
                            }
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Heatmap (últimos ~3 meses)")
                                .font(AppTheme.deckFont)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 13), spacing: 2) {
                                ForEach(0..<91, id: \.self) { day in
                                    let count = heatmap[day] ?? 0
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(heatColor(count))
                                        .aspectRatio(1, contentMode: .fit)
                                        .help("-\(day)d: \(count)")
                                }
                            }
                            Text("Últimos ~3 meses · intensidade = revisões/dia")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Estados dos cartões")
                                .font(AppTheme.deckFont)
                            LabeledContent("Novos", value: "\(states.new)")
                            LabeledContent("Aprendizagem", value: "\(states.learn)")
                            LabeledContent("Revisão", value: "\(states.review)")
                            LabeledContent("Suspensos", value: "\(states.suspended)")
                            LabeledContent("Ocultos", value: "\(states.buried)")
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Coleção")
                                .font(AppTheme.deckFont)
                            let notes = (try? store.db.scalarInt("SELECT COUNT(*) FROM notes")) ?? 0
                            let cards = (try? store.db.scalarInt("SELECT COUNT(*) FROM cards")) ?? 0
                            LabeledContent("Notas", value: "\(notes)")
                            LabeledContent("Cartões", value: "\(cards)")
                            LabeledContent("Baralhos", value: "\(store.decks.count)")
                            LabeledContent("Tipos de nota", value: "\(store.notetypes.count)")
                        }
                    }
                }
                .padding()
            }
            .background(AppBackground())
            .navigationTitle("Estatísticas")
            .task { reload() }
            .refreshable { reload() }
        }
    }

    private var formattedTime: String {
        let seconds = todayTimeMS / 1000
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private struct ReviewSeries {
        var name: String
        var value: (CollectionStore.ReviewDayPoint) -> Int
    }

    private var reviewSeries: [ReviewSeries] {
        [
            ReviewSeries(name: "Aprender", value: { $0.learn }),
            ReviewSeries(name: "Jovem", value: { $0.young }),
            ReviewSeries(name: "Maduro", value: { $0.mature }),
            ReviewSeries(name: "Reaprender", value: { $0.relearn }),
            ReviewSeries(name: "Filtrado", value: { $0.filtered })
        ]
    }

    private func retentionLabel(_ percent: Double, pass: Int, fail: Int) -> String {
        let total = pass + fail
        guard total > 0 else { return "—" }
        return String(format: "%.0f%% · %d/%d", percent, pass, total)
    }

    private func heatColor(_ count: Int) -> Color {
        if count == 0 { return Color.white.opacity(0.06) }
        if count < 10 { return AppTheme.accent.opacity(0.25) }
        if count < 30 { return AppTheme.accent.opacity(0.45) }
        if count < 80 { return AppTheme.accent.opacity(0.7) }
        return AppTheme.accent
    }

    private func reload() {
        let did = filterDeckID
        todayCount = (try? store.todayReviewCount(deckID: did)) ?? 0
        todayTimeMS = (try? store.todayReviewTimeMS(deckID: did)) ?? 0
        future = (try? store.futureDue(deckID: did)) ?? [:]
        recent = (try? store.revlogRecent(limit: 300, deckID: did)) ?? []
        againCount = recent.filter { $0.ease == 1 }.count
        hardCount = recent.filter { $0.ease == 2 }.count
        goodCount = recent.filter { $0.ease == 3 }.count
        easyCount = recent.filter { $0.ease >= 4 }.count
        buttonCounts = (try? store.answerButtonCounts(deckID: did)) ?? [:]
        calendar = (try? store.reviewsLastDays(14, deckID: did)) ?? [:]
        heatmap = (try? store.reviewsLastDays(91, deckID: did)) ?? [:]
        intervals = (try? store.intervalHistogram(deckID: did)) ?? []
        states = (try? store.cardStateCounts(deckID: did)) ?? (0, 0, 0, 0, 0)
        reviewDays = (try? store.reviewsByType(days: rangeDays, deckID: did)) ?? []
        retention = (try? store.trueRetention(days: rangeDays, deckID: did)) ?? CollectionStore.TrueRetention()
        easeBars = (try? store.easeHistogram(deckID: did)) ?? []
        byHour = (try? store.reviewsByHour(deckID: did)) ?? [:]
        added = (try? store.cardsAddedLastDays(30, deckID: did)) ?? [:]
    }
}
