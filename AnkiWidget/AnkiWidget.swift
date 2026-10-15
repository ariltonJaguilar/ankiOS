import AppIntents
import SwiftUI
import WidgetKit

@main
struct AnkiWidgetBundle: WidgetBundle {
    var body: some Widget {
        StudyCardWidget()
    }
}

struct StudyCardWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.bigbear.AnkiOS.study-card", provider: StudyCardProvider()) { entry in
            StudyCardWidgetView(entry: entry)
        }
        .configurationDisplayName("Cartão")
        .description("O próximo cartão da fila, como na tela de estudos.")
        .supportedFamilies(StudyCardWidget.families)
        .contentMarginsDisabled()
    }

    private static var families: [WidgetFamily] {
        #if os(iOS)
        [.systemMedium, .systemLarge, .systemExtraLarge]
        #else
        [.systemMedium, .systemLarge]
        #endif
    }
}

struct StudyCardEntry: TimelineEntry {
    var date: Date
    var file: WidgetStudyFile?
    var showingAnswer: Bool
    var isPlaceholder: Bool
}

struct StudyCardProvider: TimelineProvider {
    func placeholder(in context: Context) -> StudyCardEntry {
        StudyCardEntry(
            date: .now,
            file: WidgetStudyFile(snapshot: .gallery, revealedCardID: nil),
            showingAnswer: false,
            isPlaceholder: true
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (StudyCardEntry) -> Void) {
        completion(entry(placeholder: context.isPreview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StudyCardEntry>) -> Void) {
        let current = entry(placeholder: false)
        let refresh = Calendar.current.date(byAdding: .minute, value: 20, to: .now) ?? .now.addingTimeInterval(1200)
        completion(Timeline(entries: [current], policy: .after(refresh)))
    }

    private func entry(placeholder: Bool) -> StudyCardEntry {
        if placeholder, WidgetStudyStore.load() == nil {
            return StudyCardEntry(date: .now, file: WidgetStudyFile(snapshot: .gallery, revealedCardID: nil), showingAnswer: false, isPlaceholder: true)
        }
        let file = WidgetStudyStore.load()
        let showing = file.map { $0.revealedCardID == $0.snapshot.cardID && $0.snapshot.hasCard } ?? false
        return StudyCardEntry(date: .now, file: file, showingAnswer: showing, isPlaceholder: false)
    }
}

struct StudyCardWidgetView: View {
    var entry: StudyCardEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: WidgetStudySnapshot {
        entry.file?.snapshot ?? .empty
    }

    var body: some View {
        card
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .containerBackground(for: .widget) {
                WidgetAtmosphere()
            }
            .widgetURL(URL(string: "ankios://study"))
    }

    @ViewBuilder
    private var card: some View {
        if snapshot.hasCard {
            switch family {
            case .systemLarge:
                largeCard
            #if os(iOS)
            case .systemExtraLarge:
                largeCard
            #endif
            default:
                mediumCard
            }
        } else if entry.file == nil {
            emptyState(
                title: "Abra o AnkiOS",
                message: "O próximo cartão aparece aqui depois que a coleção carregar."
            )
        } else {
            finishedState
        }
    }

    private var mediumCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Spacer(minLength: 0)
            if entry.showingAnswer {
                Text(snapshot.question)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                Text(answerText)
                    .font(faceFont(answerText, compact: true))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.45)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(snapshot.question)
                    .font(faceFont(snapshot.question, compact: true))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.4)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            Spacer(minLength: 0)
            if entry.showingAnswer {
                ratingRow(compact: true)
            } else {
                revealButton
            }
        }
        .padding(16)
    }

    private var largeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 10) {
                caption(entry.showingAnswer ? "Resposta" : "Pergunta")
                Text(entry.showingAnswer ? answerText : snapshot.question)
                    .font(faceFont(entry.showingAnswer ? answerText : snapshot.question, compact: false))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.35)
                    .lineLimit(isExtraLarge ? 6 : 4)
                    .frame(maxWidth: .infinity, alignment: snapshot.question.count <= 3 && !entry.showingAnswer ? .center : .leading)
                if entry.showingAnswer, !snapshot.question.isEmpty, snapshot.question != answerText {
                    Text(snapshot.question)
                        .font(.system(size: isExtraLarge ? 28 : 20, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(isExtraLarge ? 28 : 18)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                    }
            }
            Spacer(minLength: 0)
            if entry.showingAnswer {
                ratingRow(compact: false)
            } else {
                revealButton
            }
        }
        .padding(18)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(snapshot.deckName)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
            Spacer(minLength: 4)
            countPill("Novo", snapshot.newCount, Color(red: 0.55, green: 0.78, blue: 1))
            countPill("Aprender", snapshot.learnCount, Color(red: 1, green: 0.55, blue: 0.58))
            countPill("Revisar", snapshot.reviewCount, Color(red: 0.45, green: 0.92, blue: 0.62))
        }
    }

    private var revealButton: some View {
        Button(intent: RevealWidgetCardIntent(cardID: snapshot.cardID)) {
            Text("Mostrar resposta")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.05, green: 0.16, blue: 0.18))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background {
                    Capsule()
                        .fill(Color(red: 0.55, green: 0.96, blue: 0.90))
                }
        }
        .buttonStyle(.plain)
    }

    private func ratingRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 8) {
            gradeButton("De novo", snapshot.again, 1, Color(red: 1, green: 0.48, blue: 0.52), compact: compact)
            gradeButton("Difícil", snapshot.hard, 2, Color(red: 1, green: 0.74, blue: 0.38), compact: compact)
            gradeButton("Bom", snapshot.good, 3, Color(red: 0.42, green: 0.88, blue: 0.58), compact: compact)
            gradeButton("Fácil", snapshot.easy, 4, Color(red: 0.48, green: 0.74, blue: 1), compact: compact)
        }
    }

    private func gradeButton(_ title: String, _ interval: String, _ rating: Int, _ color: Color, compact: Bool) -> some View {
        Button(intent: GradeWidgetCardIntent(cardID: snapshot.cardID, rating: rating)) {
            VStack(spacing: 2) {
                Text(interval.isEmpty ? " " : interval)
                    .font(.system(size: compact ? 9 : 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(title)
                    .font(.system(size: compact ? 11 : 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, compact ? 7 : 10)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(color.opacity(0.92))
            }
        }
        .buttonStyle(.plain)
    }

    private func countPill(_ title: String, _ count: Int, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text("\(count)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
            if family != .systemMedium {
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.16), in: Capsule())
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .tracking(1.1)
            .foregroundStyle(Color(red: 0.55, green: 0.96, blue: 0.90).opacity(0.85))
    }

    private var finishedState: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !snapshot.deckName.isEmpty {
                Text(snapshot.deckName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            Text(snapshot.statusTitle.isEmpty ? "Nada para estudar agora" : snapshot.statusTitle)
                .font(.system(size: family == .systemMedium ? 22 : 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text(snapshot.statusDetail.isEmpty ? "Você terminou por enquanto." : snapshot.statusDetail)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(family == .systemMedium ? 2 : 3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if snapshot.canStudyAgain {
                actionButton("Revisar estudados", filled: true) { StudyAgainWidgetIntent() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(16)
    }

    private func actionButton<I: AppIntent>(_ title: String, filled: Bool, intent: () -> I) -> some View {
        Button(intent: intent()) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(filled ? Color(red: 0.05, green: 0.16, blue: 0.18) : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, family == .systemMedium ? 8 : 11)
                .background {
                    Capsule()
                        .fill(filled ? Color(red: 0.55, green: 0.96, blue: 0.90) : .white.opacity(0.1))
                        .overlay {
                            if !filled {
                                Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 1)
                            }
                        }
                }
        }
        .buttonStyle(.plain)
    }

    private func emptyState(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: family == .systemMedium ? 20 : 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(18)
    }

    private var isExtraLarge: Bool {
        #if os(iOS)
        family == .systemExtraLarge
        #else
        false
        #endif
    }

    private var answerText: String {
        let answer = snapshot.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.isEmpty || answer == snapshot.question { return snapshot.question }
        return answer
    }

    private func faceFont(_ text: String, compact: Bool) -> Font {
        let size: CGFloat
        if text.count <= 2 {
            size = compact ? 64 : (isExtraLarge ? 120 : 88)
        } else if text.count <= 16 {
            size = compact ? 28 : (isExtraLarge ? 48 : 36)
        } else {
            size = compact ? 18 : 22
        }
        return .system(size: size, weight: .regular, design: .rounded)
    }
}

private struct WidgetAtmosphere: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.16, blue: 0.20),
                    Color(red: 0.03, green: 0.06, blue: 0.08),
                    Color(red: 0.01, green: 0.02, blue: 0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color(red: 0.40, green: 0.94, blue: 0.88).opacity(0.28), .clear],
                center: .topTrailing,
                startRadius: 8,
                endRadius: 220
            )
            RadialGradient(
                colors: [Color(red: 0.45, green: 0.70, blue: 0.98).opacity(0.16), .clear],
                center: .bottomLeading,
                startRadius: 4,
                endRadius: 180
            )
        }
    }
}
