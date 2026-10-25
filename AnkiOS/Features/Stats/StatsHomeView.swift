import SwiftUI
import Charts
import CoreGraphics
import CoreText
import UniformTypeIdentifiers

struct StatsHomeView: View {
    var onClose: (() -> Void)? = nil
    @EnvironmentObject private var store: CollectionStore
    @State private var todayCount = 0
    @State private var todayTimeMS = 0
    @State private var todaySummary = StatsTodaySummary()
    @State private var futureForecast = StatsFutureDueForecast()
    @State private var recent: [AnkiRevlog] = []
    @State private var againCount = 0
    @State private var hardCount = 0
    @State private var goodCount = 0
    @State private var easyCount = 0
    @State private var answerBreakdown: [StatsAnswerButtonBreakdown] = []
    @State private var calendar: [Int: Int] = [:]
    @AppStorage("statsCalendarFirstWeekday") private var firstWeekday = Calendar.current.firstWeekday
    @State private var intervalStats = StatsIntervalStatistics(chunkDays: 1, points: [], averageDays: nil, longestDays: nil, totalCards: 0)
    @State private var states: (new: Int, learn: Int, review: Int, suspended: Int, buried: Int) = (0, 0, 0, 0, 0)
    @State private var cardDistribution = StatsCardDistribution()
    @State private var hourlyBreakdown: [StatsHourlyBreakdown] = []
    @State private var added: [Int: Int] = [:]
    @State private var filterDeckID: Int64?
    @State private var showStatsDeckPicker = false
    @State private var didSetInitialDeckSelection = false
    @State private var rangeDays = 365
    @State private var reviewDays: [CollectionStore.ReviewDayPoint] = []
    @State private var retention: [CollectionStore.TrueRetention] = []
    @State private var easeBars: [(label: String, count: Int)] = []
    @State private var collectionNoteCount = 0
    @State private var collectionCardCount = 0
    @State private var historyDaysValue = 365
    @State private var reviewChunkDaysValue = 1
    @State private var addedBucketCountValue = 30
    @State private var fsrsMetrics = FSRSCardStatistics()
    @State private var showPDFExporter = false
    @State private var pdfDocument = StatsPDFDocument(data: Data())

    private var fsrsEnabled: Bool {
        store.fsrsEnabled
    }

    private var selectedStatsDeckName: String {
        guard let filterDeckID,
              let deck = store.decks.first(where: { $0.id == filterDeckID }) else {
            return String(localized: "Toda a coleção")
        }
        return deck.name
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    GlassCard(interactive: false) {
                        VStack(spacing: 12) {
                            Button {
                                showStatsDeckPicker = true
                            } label: {
                                GlassInset {
                                    HStack(spacing: 10) {
                                        Text(selectedStatsDeckName)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(AppTheme.primaryText)
                                            .multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .layoutPriority(1)
                                        Spacer(minLength: 8)
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(AppTheme.accent)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(verbatim: selectedStatsDeckName))
                            .accessibilityIdentifier("stats.deckFilter")

                            HStack(spacing: 4) {
                                statsPeriodButton("1 mês", days: 31)
                                statsPeriodButton("3 meses", days: 90)
                                statsPeriodButton("1 ano", days: 365)
                                statsPeriodButton("Todo o histórico", days: 0)
                            }
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Hoje")
                                .font(AppTheme.deckFont)
                                .foregroundStyle(AppTheme.primaryText)
                            Text("\(todayCount)")
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .foregroundStyle(AppTheme.accent)
                                .ankiShadow(color: AppTheme.accent.opacity(0.4), radius: 8)
                                .accessibilityIdentifier("stats.today.count")
                            Text("cartões estudados · \(formattedTime)")
                                .foregroundStyle(AppTheme.secondaryText)
                            LabeledContent(
                                "De novo",
                                value: "\(todaySummary.failed) · \(String(format: "%.1f", todaySummary.correctPercent))% corretas"
                            )
                            LabeledContent(
                                "Aprender · Revisão · Reaprender · Filtradas",
                                value: "\(todaySummary.learning) · \(todaySummary.review) · \(todaySummary.relearning) · \(todaySummary.filtered)"
                            )
                            if todaySummary.matureTotal > 0 {
                                LabeledContent(
                                    "Maduros corretos",
                                    value: "\(todaySummary.matureCorrect)/\(todaySummary.matureTotal) · \(String(format: "%.1f", Double(todaySummary.matureCorrect) / Double(todaySummary.matureTotal) * 100))%"
                                )
                            }
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Adicionados · \(selectedRangeTitle)")
                                .font(AppTheme.deckFont)
                            Chart {
                                ForEach(0..<addedBucketCountValue, id: \.self) { day in
                                    BarMark(
                                        x: .value("Período", addedBucketCountValue - 1 - day),
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
                            Text("Distribuição por hora")
                                .font(AppTheme.deckFont)
                            Chart {
                                ForEach(hourlyBreakdown) { point in
                                    BarMark(
                                        x: .value("Hora", point.hour),
                                        y: .value("Respostas", point.count)
                                    )
                                    .foregroundStyle(AppTheme.mist.gradient)
                                }
                            }
                            .chartXAxis {
                                AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                                    AxisValueLabel {
                                        if let hour = value.as(Int.self) {
                                            Text(String(format: "%02d:00", (hour + store.rolloverHour) % 24))
                                        }
                                    }
                                }
                            }
                            .frame(height: 140)
                            Chart {
                                ForEach(hourlyBreakdown) { point in
                                    LineMark(
                                        x: .value("Hora", point.hour),
                                        y: .value("Corretas", point.correctPercent)
                                    )
                                    .foregroundStyle(AppTheme.accent)
                                    .symbol(.circle)
                                }
                            }
                            .chartYScale(domain: 0...100)
                            .chartXAxis {
                                AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                                    AxisValueLabel {
                                        if let hour = value.as(Int.self) {
                                            Text(String(format: "%02d:00", (hour + store.rolloverHour) % 24))
                                        }
                                    }
                                }
                            }
                            .frame(height: 100)
                            Text("Respostas e percentual sem De novo no período selecionado. Horários com até 30 respostas não aparecem.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Botões de resposta")
                                .font(AppTheme.deckFont)
                            Chart {
                                ForEach(answerButtonPoints) { point in
                                    BarMark(
                                        x: .value("Botão", point.button),
                                        y: .value("Respostas", point.count)
                                    )
                                    .position(by: .value("Tipo de cartão", point.category))
                                    .foregroundStyle(by: .value("Tipo de cartão", point.category))
                                }
                            }
                            .chartForegroundStyleScale([
                                "Aprender": AppTheme.easy,
                                "Jovem": AppTheme.accent,
                                "Maduro": AppTheme.good
                            ])
                            .frame(height: 160)
                            Text("De novo · Difícil · Bom · Fácil · percentual correto")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.secondaryText)
                            ForEach(answerBreakdown) { category in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(category.category)
                                    Spacer()
                                    Text("\(category.again) · \(category.hard) · \(category.good) · \(category.easy) · \(String(format: "%.1f", category.correctPercent))% corretas")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(AppTheme.secondaryText)
                                        .accessibilityIdentifier("stats.answerBreakdown.value.\(category.category)")
                                }
                            }
                            Text("Respostas no período selecionado.")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Próximas revisões · \(selectedRangeTitle)")
                                .font(AppTheme.deckFont)
                            Chart {
                                ForEach(futureForecast.points) { point in
                                    BarMark(
                                        x: .value("Período", point.offset),
                                        y: .value(String(localized: "stats.cards.label"), point.young)
                                    )
                                    .position(by: .value("Tipo", "Jovens"))
                                    .foregroundStyle(AppTheme.accent.gradient)
                                    BarMark(
                                        x: .value("Período", point.offset),
                                        y: .value(String(localized: "stats.cards.label"), point.mature)
                                    )
                                    .position(by: .value("Tipo", "Maduros"))
                                    .foregroundStyle(AppTheme.good.gradient)
                                }
                            }
                            .frame(height: 180)
                            HStack(spacing: 16) {
                                Label("Jovens", systemImage: "circle.fill")
                                    .foregroundStyle(AppTheme.accent)
                                Label("Maduros", systemImage: "circle.fill")
                                    .foregroundStyle(AppTheme.good)
                            }
                            .font(.caption)
                            Chart {
                                ForEach(futureForecast.points) { point in
                                    AreaMark(
                                        x: .value("Período", point.offset),
                                        y: .value(String(localized: "stats.cards.label"), point.cumulative)
                                    )
                                    .foregroundStyle(AppTheme.mist.opacity(0.18))
                                    LineMark(
                                        x: .value("Período", point.offset),
                                        y: .value(String(localized: "stats.cards.label"), point.cumulative)
                                    )
                                    .foregroundStyle(AppTheme.secondaryText)
                                }
                            }
                            .frame(height: 120)
                            LabeledContent("Carga diária estimada", value: "\(futureForecast.dailyLoad) cartões")
                            if futureForecast.hasBacklog {
                                Text("A projeção não inclui cartões atrasados.")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.secondaryText)
                            }
                            Text("Barras: revisões do dia se estudar diariamente. Área: total acumulado se não estudar até cada período.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("stats.reviews.title")
                                .font(AppTheme.deckFont)
                            Chart {
                                ForEach(reviewSeries, id: \.name) { series in
                                    ForEach(reviewDays) { day in
                                        reviewMark(series, day: day)
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
                                .accessibilityIdentifier("stats.reviews.summary")
                                .accessibilityLabel(reviewChartSummary)
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Tempo de revisão")
                                .font(AppTheme.deckFont)
                            Chart {
                                ForEach(reviewDays) { day in
                                    BarMark(
                                        x: .value("Dia", historyDays - 1 - day.offset),
                                            y: .value(reviewTimeUnit, reviewTimeValue(day))
                                    )
                                    .foregroundStyle(AppTheme.mist.gradient)
                                }
                            }
                            .frame(height: 160)
                            Text("\(reviewTimeUnit) por \(bucketUnit(reviewChunkDaysValue)) no período selecionado.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Retenção verdadeira")
                                .font(AppTheme.deckFont)
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                                GridRow {
                                    Text("Período")
                                    Text("Jovem")
                                    Text("Maduro")
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.secondaryText)
                                ForEach(retention) { period in
                                    GridRow {
                                        Text(period.label)
                                            .foregroundStyle(AppTheme.primaryText)
                                        Text(retentionLabel(period.youngPercent, pass: period.youngPass, fail: period.youngFail))
                                        Text(retentionLabel(period.maturePercent, pass: period.maturePass, fail: period.matureFail))
                                    }
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(AppTheme.secondaryText)
                                }
                            }
                            Text("De novo conta como falha; Difícil, Bom e Fácil contam como acerto. Jovem: intervalo anterior menor que 21 dias.")
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
                                        y: .value(String(localized: "stats.cards.label"), item.count)
                                    )
                                    .foregroundStyle(AppTheme.mist.gradient)
                                }
                            }
                            .frame(height: 160)
                        }
                    }

                    if fsrsEnabled {
                        fsrsMetricCard(
                            "Estabilidade FSRS",
                            average: fsrsMetrics.averageStability,
                            unit: " d",
                            values: fsrsMetrics.stability,
                            color: AppTheme.accent
                        )
                        fsrsMetricCard(
                            "Dificuldade FSRS",
                            average: fsrsMetrics.averageDifficulty,
                            unit: "",
                            values: fsrsMetrics.difficulty,
                            color: AppTheme.warn
                        )
                        fsrsMetricCard(
                            "Recuperabilidade FSRS",
                            average: fsrsMetrics.averageRetrievability.map { $0 * 100 },
                            unit: "%",
                            values: fsrsMetrics.retrievability,
                            color: AppTheme.good
                        )
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Retenção recente")
                                .font(AppTheme.deckFont)
                            let total = max(againCount + hardCount + goodCount + easyCount, 1)
                            let pct = Double(hardCount + goodCount + easyCount) / Double(total) * 100
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
                            Text("Intervalos de revisão")
                                .font(AppTheme.deckFont)
                            Chart {
                                ForEach(intervalStats.points) { item in
                                    BarMark(
                                        x: .value("Faixa", item.label),
                                        y: .value(String(localized: "stats.cards.label"), item.count)
                                    )
                                    .foregroundStyle(AppTheme.mist.gradient)
                                }
                            }
                            .frame(height: 160)
                            Chart {
                                ForEach(intervalStats.points) { item in
                                    LineMark(
                                        x: .value("Faixa", item.label),
                                        y: .value("Percentual cumulativo", item.cumulativePercent)
                                    )
                                    .foregroundStyle(AppTheme.accent)
                                    .symbol(.circle)
                                }
                            }
                            .chartYScale(domain: 0...100)
                            .frame(height: 110)
                            LabeledContent("Intervalo médio", value: intervalStats.averageDays.map { String(format: "%.1f dias", $0) } ?? "—")
                            LabeledContent("Maior intervalo", value: intervalStats.longestDays.map { "\($0) dias" } ?? "—")
                            Text("Cartões por intervalo e percentual cumulativo da coleção. \(intervalStats.totalCards) cartões de revisão.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Calendário")
                                .font(AppTheme.deckFont)
                            HStack(alignment: .top, spacing: 8) {
                                VStack(spacing: 3) {
                                    Color.clear.frame(width: 12, height: 12)
                                    ForEach(calendarWeekdays) { weekday in
                                        Button {
                                            firstWeekday = weekday.weekday
                                        } label: {
                                            Text(String(weekday.name.prefix(1)))
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(weekday.weekday == firstWeekday ? AppTheme.accent : AppTheme.secondaryText)
                                                .frame(width: 12, height: 12)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Começar a semana em \(weekday.name)")
                                        .accessibilityLabel("Começar a semana em \(weekday.name)")
                                    }
                                }

                                ScrollViewReader { proxy in
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(alignment: .top, spacing: 3) {
                                            ForEach(Array(calendarWeeks.enumerated()), id: \.offset) { weekIndex, week in
                                                VStack(spacing: 3) {
                                                    Color.clear
                                                        .frame(width: 11, height: 12)
                                                        .overlay(alignment: .leading) {
                                                            if let month = calendarMonthLabel(for: week) {
                                                                Text(month)
                                                                    .font(.caption2)
                                                                    .foregroundStyle(AppTheme.secondaryText)
                                                                    .fixedSize()
                                                            }
                                                        }
                                                    ForEach(Array(week.enumerated()), id: \.offset) { _, dayOffset in
                                                        if let dayOffset {
                                                            let count = calendar[dayOffset] ?? 0
                                                            RoundedRectangle(cornerRadius: 3)
                                                                .fill(heatColor(count))
                                                                .frame(width: 11, height: 11)
                                                                .help("\(calendarDateLabel(dayOffset)): \(count) revisões")
                                                                .accessibilityLabel("\(calendarDateLabel(dayOffset)): \(count) revisões")
                                                                .accessibilityIdentifier("stats.calendar.day.\(dayOffset)")
                                                        } else {
                                                            Color.clear
                                                                .frame(width: 11, height: 11)
                                                        }
                                                    }
                                                }
                                                .id(weekIndex)
                                            }
                                        }
                                        .padding(.vertical, 1)
                                    }
                                    .onAppear {
                                        proxy.scrollTo(calendarWeeks.count - 1, anchor: .trailing)
                                    }
                                }
                            }
                            Text("Últimos 12 meses · intensidade = revisões por dia. Deslize para ver as semanas. Toque no dia da semana para mudar o início da semana.")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Tipos de cartão")
                                .font(AppTheme.deckFont)
                            Chart {
                                ForEach(cardDistributionItems.filter { $0.count > 0 }) { item in
                                    SectorMark(
                                        angle: .value(String(localized: "stats.cards.label"), item.count),
                                        innerRadius: .ratio(0.55),
                                        angularInset: 2
                                    )
                                    .foregroundStyle(by: .value("Tipo", item.label))
                                }
                            }
                            .chartForegroundStyleScale([
                                "Maduros": AppTheme.good,
                                "Jovens e aprendizagem": AppTheme.accent,
                                "Não vistos": AppTheme.mist,
                                "Suspensos e ocultos": AppTheme.warn
                            ])
                            .chartLegend(position: .bottom, alignment: .leading)
                            .frame(height: 210)
                            ForEach(cardDistributionItems) { item in
                                LabeledContent(
                                    item.label,
                                    value: "\(item.count) · \(cardDistribution.total == 0 ? 0 : Int(Double(item.count) / Double(cardDistribution.total) * 100))%"
                                )
                                .accessibilityIdentifier("stats.distribution.\(item.key)")
                            }
                            LabeledContent("Total de cartões", value: "\(cardDistribution.total)")
                                .accessibilityIdentifier("stats.distribution.total")
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Estados dos cartões")
                                .font(AppTheme.deckFont)
                            LabeledContent("Novos", value: "\(states.new)")
                                .accessibilityIdentifier("stats.states.new")
                            LabeledContent("Aprendizagem", value: "\(states.learn)")
                                .accessibilityIdentifier("stats.states.learning")
                            LabeledContent("Revisão", value: "\(states.review)")
                                .accessibilityIdentifier("stats.states.review")
                            LabeledContent("Suspensos", value: "\(states.suspended)")
                                .accessibilityIdentifier("stats.states.suspended")
                            LabeledContent("Ocultos", value: "\(states.buried)")
                                .accessibilityIdentifier("stats.states.buried")
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("stats.collection.range")
                                .font(AppTheme.deckFont)
                            LabeledContent("Notas", value: "\(collectionNoteCount)")
                                .accessibilityIdentifier("stats.collection.notes")
                            LabeledContent("stats.cards.label", value: "\(collectionCardCount)")
                                .accessibilityIdentifier("stats.collection.cards")
                            LabeledContent("stats.decks.count", value: "\(store.decks.count)")
                            LabeledContent("Tipos de nota", value: "\(store.notetypes.count)")
                        }
                    }
                }
                .padding()
            }
            .background(AppBackground())
            .navigationTitle("Estatísticas")
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Fechar", action: onClose)
                            .accessibilityIdentifier("stats.close")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        do {
                            pdfDocument = StatsPDFDocument(data: try makePDF())
                            showPDFExporter = true
                        } catch {
                            store.lastError = error.localizedDescription
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(GlassIconButtonStyle(tint: AppTheme.accent))
                    .help("Exportar estatísticas em PDF")
                    .accessibilityLabel("Exportar estatísticas em PDF")
                }
            }
            .fileExporter(
                isPresented: $showPDFExporter,
                document: pdfDocument,
                contentType: .pdf,
                defaultFilename: "Anki-Estatisticas"
            ) { result in
                if case .failure(let error) = result { store.lastError = error.localizedDescription }
            }
            .sheet(isPresented: $showStatsDeckPicker) {
                NavigationStack {
                    List {
                        Button {
                            selectStatsDeck(nil)
                        } label: {
                            statsDeckPickerLabel("Toda a coleção", selected: filterDeckID == nil)
                        }
                        .foregroundStyle(AppTheme.primaryText)
                        .accessibilityLabel(Text("Toda a coleção"))
                        .glassListRow(selected: filterDeckID == nil, tint: AppTheme.accent)

                        ForEach(store.decks) { deck in
                            Button {
                                selectStatsDeck(deck.id)
                            } label: {
                                statsDeckPickerLabel(deck.name, selected: filterDeckID == deck.id)
                            }
                            .foregroundStyle(AppTheme.primaryText)
                            .accessibilityLabel(Text(verbatim: deck.name))
                            .glassListRow(selected: filterDeckID == deck.id, tint: AppTheme.accent)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .background(AppBackground())
                    .navigationTitle("stats.deck.filter")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Fechar") { showStatsDeckPicker = false }
                        }
                    }
                }
                #if os(iOS)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                #endif
            }
            .task {
                if !didSetInitialDeckSelection {
                    didSetInitialDeckSelection = true
                    if let deckID = store.currentDeckID(), store.deck(id: deckID) != nil {
                        filterDeckID = deckID
                    }
                }
                reload()
            }
            .refreshable { reload() }
        }
    }

    private var formattedTime: String {
        let seconds = todayTimeMS / 1000
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private func fsrsMetricCard(
        _ title: String,
        average: Double?,
        unit: String,
        values: [(label: String, count: Int)],
        color: Color
    ) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(AppTheme.deckFont)
                    Spacer()
                    Text(average.map { String(format: "%.1f", $0) + unit } ?? "—")
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(color)
                }
                Chart {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, item in
                        BarMark(
                            x: .value("Faixa", item.label),
                            y: .value(String(localized: "stats.cards.label"), item.count)
                        )
                        .foregroundStyle(color.gradient)
                    }
                }
                .frame(height: 150)
                Text("Média de \(fsrsMetrics.cardCount) cartões com memória FSRS.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
    }

    private var historyDays: Int {
        historyDaysValue
    }

    private var normalizedFirstWeekday: Int {
        (1...7).contains(firstWeekday) ? firstWeekday : Calendar.current.firstWeekday
    }

    private var calendarWeekdays: [StatsCalendarWeekday] {
        let symbols = Calendar.current.weekdaySymbols
        return (0..<7).map { index in
            let weekday = (normalizedFirstWeekday - 1 + index) % 7 + 1
            return StatsCalendarWeekday(weekday: weekday, name: symbols[weekday - 1])
        }
    }

    private var calendarWeeks: [[Int?]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let oldest = calendar.date(byAdding: .day, value: -364, to: today) ?? today
        let weekday = calendar.component(.weekday, from: oldest)
        let leading = (weekday - normalizedFirstWeekday + 7) % 7
        let trailing = (7 - (leading + 365) % 7) % 7
        let dayOffsets = [Int?](repeating: nil, count: leading)
            + (0..<365).reversed().map { Optional($0) }
            + [Int?](repeating: nil, count: trailing)
        return stride(from: 0, to: dayOffsets.count, by: 7).map { start in
            Array(dayOffsets[start..<(start + 7)])
        }
    }

    private func calendarMonthLabel(for week: [Int?]) -> String? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        for offset in week.compactMap({ $0 }) {
            let date = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            if calendar.component(.day, from: date) == 1 {
                let month = calendar.component(.month, from: date)
                return calendar.shortMonthSymbols[month - 1]
            }
        }
        return nil
    }

    private func calendarDateLabel(_ offset: Int) -> String {
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: Date())) ?? Date()
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private var selectedRangeTitle: String {
        switch rangeDays {
        case 31: "último mês"
        case 90: "últimos 3 meses"
        case 365: "último ano"
        default: "todo o histórico"
        }
    }

    private var selectedPeriodDays: Int? {
        switch rangeDays {
        case 31: 31
        case 90: 91
        case 365: 365
        default: nil
        }
    }

    private func bucketUnit(_ days: Int) -> String {
        switch days {
        case 1: "dia"
        case 7: "semana"
        default: "mês"
        }
    }

    private var reviewTimeUnit: String {
        rangeDays == 31 ? "Minutos" : "Horas"
    }

    private func reviewTimeValue(_ point: CollectionStore.ReviewDayPoint) -> Double {
        Double(point.timeMS) / (rangeDays == 31 ? 60_000 : 3_600_000)
    }

    private func bucketConfiguration(periodDays: Int, historyDays: Int) -> (count: Int, chunkDays: Int) {
        switch periodDays {
        case 31: return (31, 1)
        case 90: return (13, 7)
        case 365: return (52, 7)
        default:
            let chunkDays = historyDays <= 100 ? 1 : (historyDays <= 700 ? 7 : 31)
            return (max(1, (historyDays + chunkDays - 1) / chunkDays), chunkDays)
        }
    }

    private struct AnswerButtonPoint: Identifiable {
        var id: String { "\(category).\(button)" }
        var category: String
        var button: String
        var count: Int
    }

    private struct DistributionItem: Identifiable {
        var id: String { key }
        var key: String
        var label: String
        var count: Int
    }

    private var answerButtonPoints: [AnswerButtonPoint] {
        answerBreakdown.flatMap { category in
            [
                AnswerButtonPoint(category: category.category, button: "De novo", count: category.again),
                AnswerButtonPoint(category: category.category, button: "Difícil", count: category.hard),
                AnswerButtonPoint(category: category.category, button: "Bom", count: category.good),
                AnswerButtonPoint(category: category.category, button: "Fácil", count: category.easy)
            ]
        }
    }

    private var cardDistributionItems: [DistributionItem] {
        [
            DistributionItem(key: "mature", label: "Maduros", count: cardDistribution.mature),
            DistributionItem(key: "youngAndLearning", label: "Jovens e aprendizagem", count: cardDistribution.youngAndLearning),
            DistributionItem(key: "unseen", label: "Não vistos", count: cardDistribution.unseen),
            DistributionItem(key: "suspendedAndBuried", label: "Suspensos e ocultos", count: cardDistribution.suspendedAndBuried)
        ]
    }

    private struct ReviewSeries {
        var key: String
        var name: String
        var value: (CollectionStore.ReviewDayPoint) -> Int
    }

    private var reviewSeries: [ReviewSeries] {
        [
            ReviewSeries(key: "learn", name: "Aprender", value: { $0.learn }),
            ReviewSeries(key: "young", name: "Jovem", value: { $0.young }),
            ReviewSeries(key: "mature", name: "Maduro", value: { $0.mature }),
            ReviewSeries(key: "relearn", name: "Reaprender", value: { $0.relearn }),
            ReviewSeries(key: "filtered", name: "Filtrado", value: { $0.filtered })
        ]
    }

    private var reviewChartSummary: String {
        reviewSeries.map { series in
            "\(series.name): \(reviewDays.reduce(0) { $0 + series.value($1) })"
        }.joined(separator: ", ")
    }

    private func reviewMark(_ series: ReviewSeries, day: CollectionStore.ReviewDayPoint) -> some ChartContent {
        let count = series.value(day)
        return BarMark(
            x: .value("Dia", historyDays - 1 - day.offset),
            y: .value("N", count)
        )
        .foregroundStyle(by: .value("Tipo", series.name))
        .accessibilityHidden(count == 0)
        .accessibilityLabel("\(series.name), \(calendarDateLabel(day.offset))")
        .accessibilityValue("\(count) revisões")
        .accessibilityIdentifier("stats.reviews.\(series.key).\(day.offset)")
    }

    private func retentionLabel(_ percent: Double, pass: Int, fail: Int) -> String {
        let total = pass + fail
        guard total > 0 else { return "—" }
        return String(format: "%.1f%% · %d/%d", percent, pass, total)
    }

    private func heatColor(_ count: Int) -> Color {
        if count == 0 { return Color.white.opacity(0.06) }
        if count < 10 { return AppTheme.accent.opacity(0.25) }
        if count < 30 { return AppTheme.accent.opacity(0.45) }
        if count < 80 { return AppTheme.accent.opacity(0.7) }
        return AppTheme.accent
    }

    private func makePDF() throws -> Data {
        var lines = [
            "Estatísticas do AnkiOS",
            "Baralho: \(filterDeckID.flatMap { store.deck(id: $0)?.name } ?? "Toda a coleção")",
            "Período: \(rangeDays == 0 ? "Todo o histórico" : "Últimos \(rangeDays) dias")",
            "",
            "Hoje",
            "Cartões estudados: \(todayCount)",
            "Tempo de revisão: \(formattedTime)",
            "De novo: \(todaySummary.failed) · corretas: \(String(format: "%.1f", todaySummary.correctPercent))%",
            "Aprender: \(todaySummary.learning) · revisão: \(todaySummary.review) · reaprender: \(todaySummary.relearning) · filtradas: \(todaySummary.filtered)",
            "",
            String(localized: "stats.collection.range"),
            "Notas: \(collectionNoteCount)",
            "Cartões: \(collectionCardCount)",
            "Baralhos: \(store.decks.count)",
            "Tipos de nota: \(store.notetypes.count)",
            "",
            "Estados dos cartões",
            "Novos: \(states.new) · Aprendizagem: \(states.learn) · Revisão: \(states.review)",
            "Suspensos: \(states.suspended) · Ocultos: \(states.buried)",
            "Tipos de cartão",
            "Maduros: \(cardDistribution.mature) · Jovens e aprendizagem: \(cardDistribution.youngAndLearning) · Não vistos: \(cardDistribution.unseen) · Suspensos e ocultos: \(cardDistribution.suspendedAndBuried)",
            "",
            "Botões de resposta",
            answerBreakdown.map { "\($0.category): De novo \($0.again), Difícil \($0.hard), Bom \($0.good), Fácil \($0.easy), corretas \(String(format: "%.1f", $0.correctPercent))%" }.joined(separator: "\n")
        ]
        let recentTotal = max(againCount + hardCount + goodCount + easyCount, 1)
        let recentRetention = Double(hardCount + goodCount + easyCount) / Double(recentTotal) * 100
        lines += ["", String(format: "Retenção recente: %.0f%% · %d revisões", recentRetention, recent.count), "", "Próximas revisões · \(selectedRangeTitle)"]
        lines.append(contentsOf: futureForecast.points.map { "Período +\($0.offset): jovens \($0.young), maduros \($0.mature), acumulado \($0.cumulative)" })
        lines += ["", "Adicionados · \(selectedRangeTitle)"]
        lines.append(contentsOf: (0..<addedBucketCountValue).reversed().map { "Período -\($0): \(added[$0] ?? 0) cartões" })
        lines += ["", "Revisões por hora"]
        lines.append(contentsOf: hourlyBreakdown.map { String(format: "%02d:00: %d respostas, %.1f%% corretas", $0.hour, $0.count, $0.correctPercent) })
        lines += ["", "Revisões por \(bucketUnit(reviewChunkDaysValue)) (\(historyDays) períodos)"]
        for point in reviewDays.sorted(by: { $0.offset < $1.offset }) {
            lines.append("Período -\(point.offset): aprender \(point.learn), jovem \(point.young), maduro \(point.mature), reaprender \(point.relearn), filtrado \(point.filtered), tempo \(point.timeMS) ms")
        }
        lines += ["", "Retenção verdadeira"]
        lines.append(contentsOf: retention.map {
            "\($0.label): jovem \(retentionLabel($0.youngPercent, pass: $0.youngPass, fail: $0.youngFail)), maduro \(retentionLabel($0.maturePercent, pass: $0.maturePass, fail: $0.matureFail))"
        })
        lines += ["", "Intervalos"]
        lines.append(contentsOf: intervalStats.points.map { "\($0.label): \($0.count) cartões, \(String(format: "%.1f", $0.cumulativePercent))% cumulativo" })
        lines += ["", "Facilidade"]
        lines.append(contentsOf: easeBars.map { "\($0.label): \($0.count) cartões" })
        lines += ["", "Calendário (365 dias)"]
        lines.append(contentsOf: (0..<365).map { "Dia -\($0): \(calendar[$0] ?? 0) revisões" })
        if fsrsEnabled {
            lines += ["", "FSRS", "Estabilidade média: \(fsrsMetrics.averageStability.map { String(format: "%.1f dias", $0) } ?? "—")", "Dificuldade média: \(fsrsMetrics.averageDifficulty.map { String(format: "%.1f", $0) } ?? "—")", "Recuperabilidade média: \(fsrsMetrics.averageRetrievability.map { String(format: "%.1f%%", $0 * 100) } ?? "—")"]
        }
        return try StatsPDFRenderer.render(lines.joined(separator: "\n"))
    }

    private func reload() {
        let did = filterDeckID
        do {
            todaySummary = try store.statsTodaySummary(deckID: did)
            todayCount = todaySummary.reviews
            todayTimeMS = todaySummary.timeMS
            let collectionCounts = try store.statsCollectionCounts(deckID: did)
            collectionNoteCount = collectionCounts.notes
            collectionCardCount = collectionCounts.cards
            recent = try store.revlogRecent(limit: 300, deckID: did)
            againCount = recent.filter { $0.ease == 1 }.count
            hardCount = recent.filter { $0.ease == 2 }.count
            goodCount = recent.filter { $0.ease == 3 }.count
            easyCount = recent.filter { $0.ease >= 4 }.count
            answerBreakdown = try store.answerButtonBreakdown(days: selectedPeriodDays, deckID: did)
            calendar = try store.reviewsLastDays(365, deckID: did)
            cardDistribution = try store.statsCardDistribution(deckID: did)
            states = try store.cardStateCounts(deckID: did)
            let reviewAgeDays = try store.reviewHistoryDays(deckID: did)
            let reviewBuckets = bucketConfiguration(periodDays: rangeDays, historyDays: reviewAgeDays)
            futureForecast = try store.futureDueForecast(buckets: rangeDays == 0 ? nil : reviewBuckets.count, chunkDays: reviewBuckets.chunkDays, deckID: did)
            historyDaysValue = reviewBuckets.count
            reviewChunkDaysValue = reviewBuckets.chunkDays
            reviewDays = try store.reviewsByType(buckets: reviewBuckets.count, chunkDays: reviewBuckets.chunkDays, deckID: did)
            retention = try store.trueRetention(deckID: did)
            easeBars = try store.easeHistogram(deckID: did)
            fsrsMetrics = fsrsEnabled ? try store.fsrsCardStatistics(deckID: did) : FSRSCardStatistics()
            hourlyBreakdown = try store.hourlyReviewBreakdown(days: selectedPeriodDays, deckID: did)
            intervalStats = try store.intervalStatistics(days: rangeDays, historyDays: reviewAgeDays, deckID: did)
            let addedAgeDays = try store.addedHistoryDays(deckID: did)
            let addedBuckets = bucketConfiguration(periodDays: rangeDays, historyDays: addedAgeDays)
            addedBucketCountValue = addedBuckets.count
            added = try store.cardsAdded(buckets: addedBuckets.count, chunkDays: addedBuckets.chunkDays, deckID: did)
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func selectStatsDeck(_ deckID: Int64?) {
        filterDeckID = deckID
        showStatsDeckPicker = false
        reload()
    }

    private func statsDeckPickerLabel(_ title: String, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(AppTheme.accent)
            }
        }
    }

    private func statsPeriodButton(_ title: LocalizedStringKey, days: Int) -> some View {
        Button {
            guard rangeDays != days else { return }
            rangeDays = days
            reload()
        } label: {
            Text(title)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .minimumScaleFactor(0.72)
        }
        .buttonStyle(GlassChipButtonStyle(tint: rangeDays == days ? AppTheme.accent.opacity(0.32) : .white.opacity(0.045)))
        .accessibilityIdentifier("stats.period.\(days)")
        .accessibilityAddTraits(rangeDays == days ? .isSelected : [])
    }
}

private struct StatsCalendarWeekday: Identifiable {
    var weekday: Int
    var name: String
    var id: Int { weekday }
}

private struct StatsPDFDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private enum StatsPDFRenderer {
    static func render(_ text: String) throws -> Data {
        let output = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: CGColor(gray: 0.08, alpha: 1)]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var location = 0
        while location < attributed.length {
            context.beginPDFPage(nil)
            let pageRect = CGRect(x: 48, y: 48, width: 499, height: 746)
            let path = CGPath(rect: pageRect, transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: location, length: 0),
                path,
                nil
            )
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else {
                context.endPDFPage()
                throw CocoaError(.fileWriteUnknown)
            }
            location += visible.length
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }
}
