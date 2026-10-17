import SwiftUI

/// Anki's Custom Study dialog: six radios, one spinner, then a tag screen for the last mode.
struct CustomStudyView: View {
    let deck: AnkiDeck
    var onSessionCreated: (AnkiDeck) -> Void = { _ in }

    @EnvironmentObject private var store: CollectionStore
    @Environment(\.dismiss) private var dismiss

    @State private var mode: CustomStudyMode = .extendNew
    @State private var cramKind: CramKind = .new
    @State private var amount = 0
    @State private var availability = CustomStudyAvailability.empty
    @State private var showTags = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let title = availabilityTitle {
                            Text(title)
                                .font(.headline)
                                .foregroundStyle(AppTheme.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(CustomStudyMode.allCases) { item in
                                Button {
                                    select(item)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: mode == item ? "largecircle.fill.circle" : "circle")
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(mode == item ? AppTheme.accent : AppTheme.primaryText.opacity(0.7))
                                        Text(item.title)
                                            .font(.body)
                                            .foregroundStyle(AppTheme.primaryText)
                                            .multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(GlassButtonStyle(tint: mode == item ? AppTheme.accent : .white, prominent: false, tintStrength: 0.16, expands: true))
                            }
                        }
                        .padding(16)

                        GlassInset {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(mode.leadingText)
                                    .foregroundStyle(AppTheme.primaryText.opacity(0.92))
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 10) {
                                    TextField("0", value: amountBinding, format: .number.grouping(.never))
                                        .textFieldStyle(.plain)
                                        .multilineTextAlignment(.trailing)
                                        .font(.title3.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(AppTheme.primaryText)
                                        .frame(width: 88)
                                        #if os(iOS)
                                        .keyboardType(.numbersAndPunctuation)
                                        #endif
                                        .glassField(cornerRadius: 10)
                                    Stepper("", value: amountBinding, in: mode.range)
                                        .labelsHidden()
                                        .fixedSize()
                                }
                                Text(mode.trailingText(amount: amount))
                                    .foregroundStyle(AppTheme.primaryText.opacity(0.92))
                            }
                        }

                        if mode == .cram {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(CramKind.allCases) { item in
                                    Button {
                                        cramKind = item
                                    } label: {
                                        HStack {
                                            Text(item.title)
                                                .foregroundStyle(AppTheme.primaryText)
                                                .multilineTextAlignment(.leading)
                                            Spacer(minLength: 0)
                                            if cramKind == item {
                                                Image(systemName: "checkmark")
                                                    .foregroundStyle(AppTheme.accent)
                                            }
                                        }
                                        .padding(.vertical, 8)
                                        .padding(.horizontal, 4)
                                    }
                                    .buttonStyle(GlassButtonStyle(tint: cramKind == item ? AppTheme.accent : .white, prominent: false, tintStrength: 0.16, expands: true))
                                }
                            }
                            .padding(12)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Estudo Personalizado")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode == .cram ? "Escolha etiquetas." : "Aceitar") {
                        accept()
                    }
                    .disabled(!canAccept)
                }
            }
            .onAppear {
                do {
                    availability = try store.customStudyAvailability(for: deck.id)
                    select(.extendNew)
                } catch {
                    failure = error.localizedDescription
                }
            }
            .sheet(isPresented: $showTags) {
                SelectiveStudyView(
                    tags: availability.tags,
                    initialInclude: savedTags("inc"),
                    initialExclude: savedTags("exc")
                ) { include, exclude in
                    try buildCram(include: include, exclude: exclude)
                }
                .environmentObject(store)
            }
            .alert("Estudo Personalizado", isPresented: failurePresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
        }
    }

    private var failurePresented: Binding<Bool> {
        Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
    }

    private var canAccept: Bool {
        switch mode {
        case .extendNew, .extendRev:
            true
        default:
            availability.totalCards > 0
        }
    }

    private var availabilityTitle: String? {
        switch mode {
        case .extendNew:
            "Cartões novos disponíveis: \(countWithChildren(availability.newOwn, children: availability.newChildren))"
        case .extendRev:
            "Cartões de revisão disponíveis: \(countWithChildren(availability.reviewOwn, children: availability.reviewChildren))"
        default:
            nil
        }
    }

    private func countWithChildren(_ own: Int, children: Int) -> String {
        children > 0 ? "\(own) (\(children) em sub-baralhos)" : "\(own)"
    }

    private var amountBinding: Binding<Int> {
        Binding(
            get: { amount },
            set: { amount = min(max($0, mode.range.lowerBound), mode.range.upperBound) }
        )
    }

    /// Anki pre-fills the limit spinners with the deck's last `extendNew`/`extendRev`.
    private func select(_ item: CustomStudyMode) {
        mode = item
        let live = store.deck(id: deck.id) ?? deck
        let value: Int
        switch item {
        case .extendNew: value = live.extendNew
        case .extendRev: value = live.extendRev
        case .forgot, .ahead, .preview: value = 1
        case .cram: value = 100
        }
        amount = min(max(value, item.range.lowerBound), item.range.upperBound)
    }

    private func accept() {
        switch mode {
        case .extendNew:
            applyLimit(newDelta: amount, reviewDelta: 0)
        case .extendRev:
            applyLimit(newDelta: 0, reviewDelta: amount)
        case .forgot:
            build(
                query: "rated:\(amount):1 \(quotedDeck)",
                limit: 99_999,
                reschedule: false,
                order: "random"
            )
        case .ahead:
            build(
                query: "prop:due<=\(amount) \(quotedDeck)",
                limit: 99_999,
                reschedule: true,
                order: "due"
            )
        case .preview:
            build(
                query: "is:new added:\(amount) \(quotedDeck)",
                limit: 99_999,
                reschedule: false,
                order: "added"
            )
        case .cram:
            showTags = true
        }
    }

    private var quotedDeck: String {
        let escaped = deck.name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "deck:\"\(escaped)\""
    }

    private func applyLimit(newDelta: Int, reviewDelta: Int) {
        do {
            try store.extendTodayLimit(deckID: deck.id, newDelta: newDelta, reviewDelta: reviewDelta)
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }

    private func build(query: String, limit: Int, reschedule: Bool, order: String, include: String? = nil, exclude: String? = nil) {
        do {
            try finishSession(query: query, limit: limit, reschedule: reschedule, order: order, include: include, exclude: exclude)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func finishSession(query: String, limit: Int, reschedule: Bool, order: String, include: String?, exclude: String?) throws {
        let session = try store.buildCustomStudySession(
            query: query,
            limit: limit,
            reschedule: reschedule,
            order: order,
            includeTags: include,
            excludeTags: exclude
        )
        onSessionCreated(session)
        dismiss()
    }

    private func buildCram(include: Set<String>, exclude: Set<String>) throws {
        let includeText = include.sorted().joined(separator: " ")
        let excludeText = exclude.sorted().joined(separator: " ")
        let query: String
        switch cramKind {
        case .new:
            query = "is:new \(quotedDeck)"
        case .due:
            query = "is:due \(quotedDeck)"
        case .studiedRandom:
            query = "-is:new \(quotedDeck)"
        case .allRandom:
            query = quotedDeck
        }
        let session = try store.buildCustomStudySession(
            query: query,
            limit: amount,
            reschedule: cramKind.reschedule,
            order: cramKind.order,
            includeTags: includeText.isEmpty ? nil : includeText,
            excludeTags: excludeText.isEmpty ? nil : excludeText
        )
        rememberTags(include: includeText, exclude: excludeText)
        onSessionCreated(session)
        dismiss()
    }

    /// rslib `DeckConfigKey::CustomStudyIncludeTags/ExcludeTags.for_deck`.
    private func tagsKey(_ kind: String) -> String {
        "_deck_\(deck.id)_customStudy\(kind == "inc" ? "Include" : "Exclude")Tags"
    }

    private func savedTags(_ kind: String) -> Set<String> {
        if let tags = store.conf[tagsKey(kind)] as? [String] { return Set(tags) }
        let legacy = (store.conf["ankios.cs.\(kind).\(deck.id)"] as? String) ?? ""
        return Set(AnkiTag.split(legacy))
    }

    private func rememberTags(include: String, exclude: String) {
        var conf = store.conf
        conf[tagsKey("inc")] = AnkiTag.split(include)
        conf[tagsKey("exc")] = AnkiTag.split(exclude)
        conf.removeValue(forKey: "ankios.cs.inc.\(deck.id)")
        conf.removeValue(forKey: "ankios.cs.exc.\(deck.id)")
        do { try store.saveConf(conf) }
        catch { store.lastError = error.localizedDescription }
    }

}

enum CustomStudyMode: String, CaseIterable, Identifiable {
    case extendNew
    case extendRev
    case forgot
    case ahead
    case preview
    case cram

    var id: String { rawValue }

    var title: String {
        switch self {
        case .extendNew: "Aumentar o limite de cartões novos por hoje"
        case .extendRev: "Aumentar o limite de cartões a revisar hoje"
        case .forgot: "Revisar os cartões esquecidos"
        case .ahead: "Antecipar a revisão"
        case .preview: "Visualizar cartões novos"
        case .cram: "Estudar pelo status do cartão ou etiqueta"
        }
    }

    var leadingText: String {
        switch self {
        case .extendNew: "Aumentar o limite de cartões novos de hoje em"
        case .extendRev: "Aumentar o limite de cartões a revisar hoje em"
        case .forgot: "Revisar os cartões esquecidos nos últimos"
        case .ahead: "Antecipar a revisão dos próximos"
        case .preview: "Visualizar cartões novos criados por último"
        case .cram: "Selecionar"
        }
    }

    func trailingText(amount: Int) -> String {
        switch self {
        case .extendNew, .extendRev:
            "cartões"
        case .forgot, .ahead, .preview:
            amount == 1 ? "dia" : "dias"
        case .cram:
            "cartões do baralho"
        }
    }

    var range: ClosedRange<Int> {
        switch self {
        case .extendNew, .extendRev: -99_999...99_999
        case .forgot: 1...30
        case .ahead, .preview, .cram: 1...99_999
        }
    }
}

enum CramKind: String, CaseIterable, Identifiable {
    case new
    case due
    case studiedRandom
    case allRandom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .new: "Somente cartões novos."
        case .due: "Apenas cartões pendentes."
        case .studiedRandom: "Todos os cartões estudados em ordem aleatória"
        case .allRandom: "Todos os cartões em ordem aleatória (não reagendar)"
        }
    }

    var reschedule: Bool {
        self != .allRandom
    }

    var order: String {
        switch self {
        case .new: "added"
        case .due: "due"
        case .studiedRandom, .allRandom: "random"
        }
    }
}

/// Anki's Selective Study window: an include checkbox and two tag lists.
private struct SelectiveStudyView: View {
    let tags: [String]
    let initialInclude: Set<String>
    let initialExclude: Set<String>
    var onAccept: (Set<String>, Set<String>) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var requireOne: Bool
    @State private var include: Set<String>
    @State private var exclude: Set<String>
    @State private var failure: String?

    init(
        tags: [String],
        initialInclude: Set<String>,
        initialExclude: Set<String>,
        onAccept: @escaping (Set<String>, Set<String>) throws -> Void
    ) {
        self.tags = tags
        self.initialInclude = initialInclude
        self.initialExclude = initialExclude
        self.onAccept = onAccept
        _requireOne = State(initialValue: !initialInclude.isEmpty)
        _include = State(initialValue: initialInclude)
        _exclude = State(initialValue: initialExclude)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Toggle(isOn: $requireOne) {
                            Text("Deve ter pelo menos uma dessas etiquetas:")
                                .foregroundStyle(AppTheme.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .tint(AppTheme.accent)
                        tagList(selected: include, enabled: requireOne, toggle: toggleInclude)
                        Text("Excluir cartões com as etiquetas:")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(AppTheme.primaryText)
                        tagList(selected: exclude, enabled: true, toggle: toggleExclude)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Estudo Seletivo")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { accept() }
                }
            }
            .alert("Estudo Seletivo", isPresented: failurePresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
        }
    }

    private var failurePresented: Binding<Bool> {
        Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
    }

    private var chosenInclude: Set<String> {
        requireOne ? include.intersection(Set(tags)) : []
    }

    private var chosenExclude: Set<String> {
        exclude.intersection(Set(tags))
    }

    private func accept() {
        let chosen = chosenInclude
        if chosen.count + chosenExclude.count > 100 {
            failure = "No máximo 100 etiquetas podem ser selecionadas. Listando as etiquetas que você quer em vez das que você não quer geralmente é mais simples, e não há necessidade de selecionar etiquetas filhas se você selecionou uma etiqueta pai."
            return
        }
        do {
            try onAccept(chosen, chosenExclude)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func tagList(selected: Set<String>, enabled: Bool, toggle: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(tags, id: \.self) { tag in
                Button {
                    toggle(tag)
                } label: {
                    HStack {
                        Image(systemName: selected.contains(tag) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(selected.contains(tag) ? AppTheme.accent : AppTheme.primaryText.opacity(0.55))
                        Text(tag.replacingOccurrences(of: "_", with: " "))
                            .foregroundStyle(AppTheme.primaryText)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(GlassChipButtonStyle())
                .disabled(!enabled)
            }
        }
        .padding(tags.isEmpty ? 8 : 14)
        .ankiGlass(tint: .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .opacity(enabled ? 1 : 0.45)
    }

    private func toggleInclude(_ tag: String) {
        if include.contains(tag) { include.remove(tag) } else { include.insert(tag) }
    }

    private func toggleExclude(_ tag: String) {
        if exclude.contains(tag) { exclude.remove(tag) } else { exclude.insert(tag) }
    }
}
