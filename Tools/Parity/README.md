# Registro de paridade

Os relatórios em [STATUS.md](STATUS.md) e [`coverage.json`](coverage.json)
preservam evidências de versões anteriores. O produto atual compila somente
para iOS e iPadOS; os registros de macOS aqui são históricos e não indicam
suporte atual.

## Contagem e critérios

- Código: fluxos comparados com Anki Desktop 26.9.3 e `anki==26.9.3`.
- UI: 12 macrofluxos nesta rodada. `coverage.json` mantém estados e evidências
  independentes em `platforms.iOS` e `platforms.macOS`; o painel apresenta, para
  cada plataforma quantos dos 12 grupos já têm teste aprovado, seguidos dos
  completos, em andamento e não iniciados. “Iniciado” significa que ao menos
  um teste interativo do grupo passou naquela plataforma; “completo” exige
  evidência aprovada para todos os comportamentos listados. Uma pendência no
  macOS não reduz o avanço iOS, nem o inverso.
- XCTest iOS: 144 métodos únicos nesta rodada; reexecuções não aumentam o total.
- XCTest exclusivos do macOS: 2 métodos únicos, contabilizados separadamente.
- Evidência de UI macOS: 17 métodos únicos aprovados distribuídos em 7 grupos; o escopo continua fixo em 12 grupos e os métodos não mudam esse denominador. Uma tentativa de Estatísticas ficou bloqueada antes do primeiro caso por `LocalAuthentication -4`; ela não conta como falha funcional.
- Idioma: no iOS, o AnkiMobile segue o idioma por app escolhido nos Ajustes do iOS; no macOS, o Anki Desktop mantém a escolha em Preferências. O app preserva essa separação. O [manual do AnkiMobile](https://docs.ankiweb.net/ankimobile/interface-language) descreve a configuração do iOS, e a [página oficial da App Store](https://apps.apple.com/us/app/ankimobile-flashcards/id373493387) lista 25 idiomas. Todos os 24 idiomas não ingleses dessa lista agora têm entrada no catálogo; Malayalam foi acrescentado.
- A conferência textual usa os repositórios oficiais de traduções Mobile e Core, detalhados em [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Dos 336 textos ingleses estáticos do catálogo, 317 têm correspondência direta com contexto único nos repositórios oficiais Mobile/Core; as 7.319 traduções disponíveis coincidem exatamente nos 24 idiomas publicados. Os 289 fallbacks ingleses também coincidem com o comportamento do Anki, que acrescenta `en-US` como último bundle ([fonte](https://github.com/ankitects/anki/blob/main/rslib/i18n/src/lib.rs)). Não restam contextos ambíguos. As três mensagens plurais do Estudo Personalizado coincidem nas 432/432 variantes FTL. Os 19 rótulos restantes sem correspondência direta foram classificados por uso: texto auxiliar e notificações próprias, título genérico, ações de navegador presentes no Desktop e unidade compacta de gráfico. A lista e suas evidências ficam em `localization-comparison.json`; nenhum desses itens permanece como lacuna de fluxo interativo iOS. Os textos de permissão da câmera e do microfone usam um catálogo `InfoPlist.xcstrings` separado com as traduções oficiais disponíveis e fallback em inglês nos outros idiomas do app.
- A verificação do catálogo localizado usa o bundle iOS compilado e compara cada
  chave/idioma com `Localizable.xcstrings`; ela não substitui a comparação textual
  com o AnkiMobile.
- Um teste aprovado não é repetido sem mudança no app ou evidência contraditória.
- Um fluxo verificado só reabre se surgir diferença reproduzível ou comportamento
  distinto sem cobertura. Itens históricos permanecem em `history` no JSON.
- Sincronização AnkiWeb é exercitada contra o servidor local de teste; o status
  registra esse limite. A sincronização iCloud foi removida do app. O grupo de UI
  correspondente acompanha a ausência da integração em iOS e macOS; o harness
  diferencial antigo permanece fora dos targets do produto.

## Validação atual

Execute os testes de interface no simulador iOS com
`zsh Tools/UITests/run.sh ios <UUID do simulador>`. O painel de paridade é um
registro histórico e não é recalculado pelos testes atuais.

Para comparar novamente o catálogo com os repositórios oficiais clonados em `/private/tmp`:

```sh
python3 Tools/Parity/compare-localization-catalog.py \
  --catalog AnkiOS/Localization/Localizable.xcstrings \
  --mobile-root /private/tmp/ankimobile-ftl/mobile \
  --core-root /private/tmp/anki-core-i18n/core \
  --json-output Tools/Parity/localization-comparison.json
```

Use `--apply` somente para importar as traduções estáticas com correspondência única. Para conferir que o bundle carrega as traduções esperadas nos 56 idiomas:

```sh
mkdir -p /private/tmp/ankios-localization-module-cache
xcrun swiftc -swift-version 6 \
  -DANKIOS_IOS_LOCALIZATION_CHECK \
  -module-cache-path /private/tmp/ankios-localization-module-cache \
  AnkiOS/Localization/AnkiLanguage.swift \
  Tools/Parity/verify-localization-bundles.swift \
  -o /private/tmp/ankios-localization-check
/private/tmp/ankios-localization-check /path/to/AnkiOS.app \
  AnkiOS/Localization/Localizable.xcstrings
```

Referência: Anki Desktop 26.9.3. A compatibilidade com extensões Python/Qt do
Anki Desktop não está incluída como paridade demonstrada.
