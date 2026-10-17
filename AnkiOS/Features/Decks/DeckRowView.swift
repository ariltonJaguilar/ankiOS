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

    private var moveTargets: [AnkiDeck] {
        let movingIDs = Set(store.deckTreeIDs(including: liveDeck.id))
        let currentAncestors = Set(liveDeck.pathComponents.dropLast().reduce(into: [String]()) { names, component in
            names.append(names.last.map { $0 + "::" + component } ?? component)
        })
        return store.decks
            .filter { !$0.isFiltered && !movingIDs.contains($0.id) && !currentAncestors.contains($0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        HStack(spacing: 12) {
            if hasChildren {
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        do { try store.setDeckCollapsed(liveDeck, collapsed: !liveDeck.collapsed) }
                        catch { store.lastError = error.localizedDescription }
                    }
                } label: {
                    Image(systemName: liveDeck.collapsed ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.mist)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(GlassIconButtonStyle(tint: AppTheme.mist))
                .accessibilityLabel(liveDeck.collapsed ? "Expand deck" : "Collapse deck")
            } else {
                Image(systemName: liveDeck.isFiltered ? "line.3.horizontal.decrease.circle" : "rectangle.stack")
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 28, height: 28)
            }

            Button { onStudy(liveDeck) } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(liveDeck.displayName)
                            .font(AppTheme.deckFont)
                            .foregroundStyle(AppTheme.primaryText)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("deck.open.\(deck.name)")

            // Anki gear affordance (options) — also available in context menu.
            Button {
                onOptions(liveDeck)
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText.opacity(0.75))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(GlassIconButtonStyle(tint: AppTheme.accent))
            .accessibilityLabel("Opções do baralho")
            .accessibilityIdentifier("deck.options.\(deck.name)")
        }
        .padding(.leading, CGFloat(depth) * 14 + 14)
        .padding(.trailing, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .ankiGlass(tint: .white.opacity(0.08), interactive: true, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AppTheme.primaryText.opacity(0.10), lineWidth: 1)
        }
        .contextMenu {
            Button("Estudar", systemImage: "play.fill") { onStudy(liveDeck) }
            if liveDeck.isFiltered {
                Button("Recriar", systemImage: "arrow.clockwise") {
                    do { try FilteredDeckSupport.rebuild(liveDeck, store: store) }
                    catch { store.lastError = error.localizedDescription }
                }
                Button("Devolver cartões", systemImage: "arrow.uturn.backward") {
                    do { try FilteredDeckSupport.empty(liveDeck, store: store) }
                    catch { store.lastError = error.localizedDescription }
                }
            } else {
                Button("Estudo personalizado", systemImage: "slider.horizontal.3") { onCustomStudy(liveDeck) }
            }
            Button("Opções", systemImage: "gearshape") { onOptions(liveDeck) }
            Button("Renomear", systemImage: "pencil") { onRename(liveDeck) }
            if !liveDeck.isFiltered {
                Button("Adicionar subbaralho", systemImage: "folder.badge.plus") { onAddSubdeck(liveDeck) }
            }
            Menu("Mover para", systemImage: "folder") {
                if liveDeck.parentName != nil {
                    Button("Raiz", systemImage: "arrow.up.to.line") {
                        do { try store.reparentDeck(liveDeck, to: nil) }
                        catch { store.lastError = error.localizedDescription }
                    }
                }
                ForEach(moveTargets) { target in
                    Button(target.name) {
                        do { try store.reparentDeck(liveDeck, to: target) }
                        catch { store.lastError = error.localizedDescription }
                    }
                }
            }
            Button("Exportar .apkg", systemImage: "square.and.arrow.up") { onExport(liveDeck) }
            Divider()
            if liveDeck.id != 1 {
                Button("Apagar", systemImage: "trash", role: .destructive) { onDelete(liveDeck) }
            }
        }
        .draggable(String(liveDeck.id))
        .dropDestination(for: String.self) { values, _ in
            guard let rawID = values.first, let sourceID = Int64(rawID), let source = store.deck(id: sourceID) else { return false }
            do {
                try store.reparentDeck(source, to: liveDeck)
                return true
            } catch {
                store.lastError = error.localizedDescription
                return false
            }
        }
    }
}
