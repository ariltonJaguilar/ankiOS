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
                                .foregroundStyle(.white)
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
                                            .foregroundStyle(mode == item ? AppTheme.accent : .white.opacity(0.7))
                                        Text(item.title)
                                            .font(.body)
                                            .foregroundStyle(.white)
                                            .multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                        .glassEffect(.regular.tint(.white.opacity(0.08)), in: .rect(cornerRadius: 16))

                        GlassInset {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(mode.leadingText)
                                    .foregroundStyle(.white.opacity(0.92))
                                    .fixedSize(horizontal: false, vertical: true)
                                Stepper(value: $amount, in: mode.range) {
                                    Text("\(amount)")
                                        .font(.title3.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(.white)
                                        .frame(minWidth: 64, alignment: .leading)
                                }
                                Text(mode.trailingText(amount: amount))
                                    .foregroundStyle(.white.opacity(0.92))
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
                                                .foregroundStyle(.white)
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
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(12)
                            .glassEffect(.regular.tint(.white.opacity(0.08)), in: .rect(cornerRadius: 16))
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
                availability = (try? store.customStudyAvailability(for: deck.id)) ?? .empty
                select(.extendNew)
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
            if availability.newChildren > 0 {
                "Novos cartões disponíveis: \(availability.newOwn) em subdecks"
            } else {
                "Novos cartões disponíveis: \(availability.newOwn)"
            }
        case .extendRev:
            "Cartões disponíveis para revisão:"
        default:
            nil
        }
    }

    private func select(_ item: CustomStudyMode) {
        mode = item
        let fallback: Int
        let key: String?
        switch item {
        case .extendNew:
            fallback = 0
            key = "ankios.cs.new.\(deck.id)"
        case .extendRev:
            fallback = 0
            key = "ankios.cs.rev.\(deck.id)"
        case .forgot, .ahead, .preview:
            fallback = 1
            key = nil
        case .cram:
            fallback = 100
            key = nil
        }
        let remembered = key.flatMap { confInt($0) } ?? fallback
        amount = min(max(remembered, item.range.lowerBound), item.range.upperBound)
    }

    private func accept() {
        switch mode {
        case .extendNew:
            applyLimit(newDelta: amount, reviewDelta: 0, memoryKey: "new")
        case .extendRev:
            applyLimit(newDelta: 0, reviewDelta: amount, memoryKey: "rev")
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

    private func applyLimit(newDelta: Int, reviewDelta: Int, memoryKey: String) {
        if max(newDelta, reviewDelta) > 0 {
            remember(memoryKey, max(newDelta, reviewDelta))
        }
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

    private func savedTags(_ kind: String) -> Set<String> {
        let value = store.conf["ankios.cs.\(kind).\(deck.id)"]
        let raw = (value as? String) ?? ""
        return Set(raw.split(separator: " ").map(String.init).filter { !$0.isEmpty })
    }

    private func rememberTags(include: String, exclude: String) {
        var conf = store.conf
        conf["ankios.cs.inc.\(deck.id)"] = include
        conf["ankios.cs.exc.\(deck.id)"] = exclude
        try? store.saveConf(conf)
    }

    private func remember(_ kind: String, _ value: Int) {
        var conf = store.conf
        conf["ankios.cs.\(kind).\(deck.id)"] = value
        try? store.saveConf(conf)
    }

    private func confInt(_ key: String) -> Int? {
        let value = store.conf[key]
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        if let number = value as? Double { return Int(number) }
        return nil
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
            amount == 1 ? "day" : "days"
        case .cram:
            "cartões do baralho"
        }
    }

    var range: ClosedRange<Int> {
        switch self {
        case .extendNew, .extendRev: -9_999...9_999
        case .forgot: 1...30
        case .ahead, .preview, .cram: 1...9_999
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
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .tint(AppTheme.accent)
                        tagList(selected: include, enabled: requireOne, toggle: toggleInclude)
                        Text("Excluir cartões com as etiquetas:")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
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
                            .foregroundStyle(selected.contains(tag) ? AppTheme.accent : .white.opacity(0.55))
                        Text(tag.replacingOccurrences(of: "_", with: " "))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
            }
        }
        .padding(tags.isEmpty ? 8 : 14)
        .glassEffect(.regular.tint(.white.opacity(0.08)), in: .rect(cornerRadius: 14))
        .opacity(enabled ? 1 : 0.45)
    }

    private func toggleInclude(_ tag: String) {
        if include.contains(tag) { include.remove(tag) } else { include.insert(tag) }
    }

    private func toggleExclude(_ tag: String) {
        if exclude.contains(tag) { exclude.remove(tag) } else { exclude.insert(tag) }
    }
}
