import SwiftUI

struct DeckRowView: View {
    let deck: AnkiDeck
    let counts: DeckCounts
    let depth: Int
    var onStudy: (AnkiDeck) -> Void
    var onRename: (AnkiDeck) -> Void
    var onOptions: (AnkiDeck) -> Void
    var onCustomStudy: (AnkiDeck) -> Void
    var onExport: (AnkiDeck) -> Void
    var onDelete: (AnkiDeck) -> Void
    var onAddSubdeck: (AnkiDeck) -> Void

    @EnvironmentObject private var store: CollectionStore

    private var liveDeck: AnkiDeck {
        store.decks.first(where: { $0.id == deck.id }) ?? deck
    }

    private var hasChildren: Bool {
        store.decks.contains { $0.parentName == liveDeck.name }
    }

    var body: some View {
        HStack(spacing: 12) {
            if hasChildren {
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        try? store.setDeckCollapsed(liveDeck, collapsed: !liveDeck.collapsed)
                    }
                } label: {
                    Image(systemName: liveDeck.collapsed ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.mist)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(liveDeck.collapsed ? "Expand deck" : "Collapse deck")
            } else {
                Image(systemName: liveDeck.isFiltered ? "line.3.horizontal.decrease.circle" : "rectangle.stack")
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 28, height: 28)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(liveDeck.displayName)
                        .font(AppTheme.deckFont)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if store.recommendedStudyDeck?.id == liveDeck.id {
                        Text("PRINCIPAL")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .glassEffect(.regular.tint(AppTheme.accent.opacity(0.45)).interactive(), in: .capsule)
                    }
                }
                if !liveDeck.desc.isEmpty {
                    Text(liveDeck.desc)
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                CountDigit(value: counts.new, color: AppTheme.easy)
                CountDigit(value: counts.learn, color: AppTheme.danger)
                CountDigit(value: counts.review, color: AppTheme.good)
            }

            // Anki gear affordance (options) — also available in context menu.
            Button {
                onOptions(liveDeck)
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Opções do baralho")
        }
        .padding(.leading, CGFloat(depth) * 14 + 14)
        .padding(.trailing, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // macOS plain buttons only hit-test glyphs; the whole glass row must be tappable.
        .contentShape(Rectangle())
        .onTapGesture { onStudy(liveDeck) }
        .glassEffect(.regular.tint(.white.opacity(0.06)).interactive(), in: .rect(cornerRadius: 18))
        .contextMenu {
            Button("Estudar", systemImage: "play.fill") { onStudy(liveDeck) }
            if liveDeck.isFiltered {
                Button("Recriar", systemImage: "arrow.clockwise") {
                    try? FilteredDeckSupport.rebuild(liveDeck, store: store)
                }
                Button("Devolver cartões", systemImage: "arrow.uturn.backward") {
                    try? FilteredDeckSupport.empty(liveDeck, store: store)
                }
            } else {
                Button("Estudo personalizado", systemImage: "slider.horizontal.3") { onCustomStudy(liveDeck) }
            }
            Button("Opções", systemImage: "gearshape") { onOptions(liveDeck) }
            Button("Renomear", systemImage: "pencil") { onRename(liveDeck) }
            if !liveDeck.isFiltered {
                Button("Adicionar subbaralho", systemImage: "folder.badge.plus") { onAddSubdeck(liveDeck) }
            }
            Button("Exportar .apkg", systemImage: "square.and.arrow.up") { onExport(liveDeck) }
            Divider()
            Button("Apagar", systemImage: "trash", role: .destructive) { onDelete(liveDeck) }
        }
    }
}
