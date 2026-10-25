import SwiftUI

struct AnkiTutorialView: View {
    @EnvironmentObject private var store: CollectionStore
    var onFinish: () -> Void

    @State private var page = 0

    private var pages: [TutorialPage] {
        [
            TutorialPage(
                icon: "rectangle.stack.fill",
                title: "O que é um baralho?",
                body: "Um baralho é uma pasta de cartões (pergunta + resposta).\n\nNa lista, cada linha é um baralho. Os números à direita são:\n• Azul = Novo (ainda não viu)\n• Vermelho = Aprender (repetindo hoje)\n• Verde = Revisar (voltou depois de dias)\n\nToque numa linha para abrir o resumo e estudar."
            ),
            TutorialPage(
                icon: "books.vertical",
                title: "Crie ou encontre baralhos",
                body: "Você pode começar de dois jeitos:\n\n• Crie o seu: em Baralhos, toque no ícone de pasta com +. Depois, use Adicionar para criar cartões nele.\n\n• Use um pronto: toque em ••• (Mais ações) → Lista de baralhos compartilhados, escolha um e toque em Download. O AnkiOS importa o pacote automaticamente."
            ),
            TutorialPage(
                icon: "star.circle.fill",
                title: "Qual é o seu baralho principal?",
                body: "É o baralho que você quer estudar agora — em geral o primeiro da lista com cartões a fazer.\n\nToque nele para ver o resumo (novos, aprender, revisar) e depois em Estudar.\n\nDica: estudar um baralho-pai também inclui os sub-baralhos (as linhas indentadas)."
            ),
            TutorialPage(
                icon: "hand.tap.fill",
                title: "Como estudar um cartão",
                body: "1. Abra o baralho principal\n2. Toque em Estudar\n3. Tente lembrar a resposta\n4. Toque em Mostrar resposta\n5. Escolha:\n\n• De novo — errou (volta logo)\n• Difícil — lembrou com esforço\n• Bom — acertou (o mais comum)\n• Fácil — fácil demais\n\nO Anki usa isso para decidir quando o cartão volta."
            ),
            TutorialPage(
                icon: "sidebar.left",
                title: "Painel, ocultar e desocultar",
                body: "A aba Painel mostra todos os cartões.\n\n• Ocultar (bury) = some da fila só por hoje\n• Suspender = some até você dessuspender\n\nPara desocultar:\n1. Abra Painel\n2. No filtro Estado, toque em Oculto\n3. Selecione o cartão\n4. Toque em Desocultar\n\nO mesmo vale para Suspenso → Dessuspender."
            ),
            TutorialPage(
                icon: "brain.head.profile",
                title: "Rotina simples",
                body: "Todo dia: abra AnkiOS → toque no baralho que quer estudar → estude até zerar os números.\n\nPouco todo dia > muito de uma vez. Quando terminar o tutorial, a lista de baralhos aparece — escolha o que tiver cartões a fazer."
            )
        ]
    }

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Pular") { finish() }
                        .buttonStyle(GlassButtonStyle(tint: .white, prominent: false, tintStrength: 0.14))
                        .padding(.trailing, 16)
                        .padding(.top, 8)
                }

                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                        tutorialCard(item)
                            .tag(index)
                            .padding(.horizontal, 20)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                Button {
                    if page < pages.count - 1 {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            page += 1
                        }
                    } else {
                        finish()
                    }
                } label: {
                    Text(page < pages.count - 1 ? "Continuar" : "Ir para os baralhos")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle(tint: AppTheme.accent, prominent: true, tintStrength: 0.4))
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
        }
    }

    private func tutorialCard(_ item: TutorialPage) -> some View {
        VStack(spacing: 22) {
            Spacer(minLength: 12)
            Image(systemName: item.icon)
                .font(.system(size: 52))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 108, height: 108)
                .background(AppTheme.accent.opacity(0.12), in: .circle)

            Text(item.title)
                .font(AppTheme.titleFont)
                .foregroundStyle(AppTheme.primaryText)
                .multilineTextAlignment(.center)

            Text(item.body)
                .font(.body)
                .foregroundStyle(AppTheme.primaryText.opacity(0.88))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .ankiGlass(tint: .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))

            Spacer()
        }
    }

    private func finish() {
        TutorialGate.markSeen()
        onFinish()
    }
}

private struct TutorialPage {
    let icon: String
    let title: String
    let body: String
}

enum TutorialGate {
    private static let key = "ankios.hasSeenStudyTutorial"

    private static var defaults: UserDefaults {
        SharedProfiles.uiTestSession == nil ? .standard : SharedProfiles.defaults
    }

    static var hasSeen: Bool {
        defaults.bool(forKey: key)
    }

    static func markSeen() {
        defaults.set(true, forKey: key)
    }

    static func resetForDebug() {
        defaults.removeObject(forKey: key)
    }

    @MainActor
    static func shouldPresent(store: CollectionStore) -> Bool {
        guard !hasSeen else { return false }
        #if DEBUG
        if SharedProfiles.uiTestSession != nil {
            return store.hasStudyContent
        }
        #endif
        return true
    }
}
