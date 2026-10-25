# AnkiOS

O AnkiOS é um app nativo para iPhone e iPad para criar, organizar e estudar cartões de memória. Ele mantém uma coleção local e oferece compatibilidade com formatos e recursos do Anki, incluindo baralhos `.apkg`, notas em CSV, agendamento de revisões e sincronização opcional com o AnkiWeb.

## O que o app oferece

- **Baralhos e estudo:** acompanhe cartões novos, em aprendizagem e em revisão; estude com os botões de resposta e opções do agendador.
- **Criação e edição:** adicione notas, edite cartões e campos, gerencie tipos de nota e use recursos de mídia e oclusão de imagem.
- **Importação e exportação:** importe e exporte pacotes `.apkg`; importe e exporte notas em CSV.
- **Baralhos compartilhados:** encontre baralhos publicados no AnkiWeb e importe os pacotes escolhidos.
- **Estatísticas e navegador:** consulte o histórico de estudo e métricas da coleção, pesquise cartões e edite notas no navegador.
- **Agendamento:** use o algoritmo SM-2 ou FSRS, configure opções de baralho e otimize parâmetros FSRS com o histórico de revisões.
- **Sincronização:** conecte uma conta AnkiWeb para sincronizar a coleção e a mídia entre clientes compatíveis. O login do app é usado para sincronização.

## Organização do projeto

- `AnkiOS/App` — inicialização do app e navegação principal.
- `AnkiOS/Features` — telas de baralhos, estudo, edição, navegador, estatísticas, tutorial e configurações.
- `AnkiOS/Storage` — coleção SQLite, operações sobre cartões e integração de sincronização AnkiWeb.
- `AnkiOS/Import` e `AnkiOS/Export` — leitura e geração de arquivos de coleção, CSV e mídia.
- `AnkiOS/Scheduling` — filas de estudo e lógica de agendamento SM-2/FSRS.
- `AnkiOS/Rendering` e `AnkiOS/Media` — apresentação dos cartões e tratamento de mídia.
- `AnkiOS/Localization` — catálogos de strings localizados do app.
- `AnkiOS/AnkiBackendBridge` — interface e XCFramework Rust do backend Anki usado na sincronização.
- `AnkiOS/FSRSBridge` — bridge Rust que expõe ao app as rotinas de otimização e simulação do crate FSRS.
- `AnkiWidget` — extensão de widget para iOS.
- `Tools/UITests` — testes de interface, fixtures e servidores locais usados pelos testes.
- `Tools/Parity` — critérios e evidências de compatibilidade e localização.

O app é implementado em SwiftUI e Swift 6. A coleção é armazenada localmente em SQLite. O backend Rust upstream do Anki é fixado em uma revisão específica no arquivo `AnkiOS/AnkiBackendBridge/Cargo.toml`. O crate oficial `fsrs` é usado pelo agendador e pela bridge Rust para otimização e simulação, mantendo esses cálculos ligados à implementação upstream.

## Requisitos

- macOS com Xcode 27 e SDK do iOS 26.
- Swift 6, incluído no Xcode.
- Para executar em um iPhone ou iPad físico, uma equipe de assinatura Apple configurada no projeto.

O app e o widget são direcionados a iOS/iPadOS. Não há target de produto para macOS.

## Abrir e executar

Abra `AnkiOS.xcodeproj` no Xcode, selecione o scheme **AnkiOS** e escolha um simulador de iPhone ou iPad ou um dispositivo conectado. A primeira execução começa com uma coleção local vazia; importe um pacote ou crie notas para começar.

Também é possível compilar para iOS pelo Terminal:

```sh
xcodebuild \
  -project AnkiOS.xcodeproj \
  -scheme AnkiOS \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Para um dispositivo físico, abra o projeto no Xcode e configure a assinatura antes de instalar.

## Testes de interface

Os testes de interface usam um simulador iOS disponível. Liste os simuladores e copie o UUID desejado:

```sh
xcrun simctl list devices available
```

Depois execute:

```sh
zsh Tools/UITests/run.sh ios <UUID-do-simulador>
```

O script prepara os dados de teste necessários para fluxos de importação, mídia e coleção. Para rodar um método específico, passe o filtro de teste após o UUID, conforme os nomes em `Tools/UITests/AnkiOSUITests.swift`.

## Backend e licenças

O backend Rust upstream do Anki está sob a licença AGPL-3.0-or-later; a licença está incluída em `AnkiOS/AnkiBackendBridge/UPSTREAM-LICENSE.txt`. O projeto também incorpora dependências e avisos de terceiros, descritos em `Tools/Parity/THIRD_PARTY_NOTICES.md` e nos arquivos de licença junto aos componentes correspondentes.

Para reconstruir o XCFramework do backend, instale Rust e os targets `aarch64-apple-ios`, `aarch64-apple-ios-sim` e `x86_64-apple-ios`, depois execute:

```sh
AnkiOS/AnkiBackendBridge/build-xcframework.sh
```

O script baixa e compila as dependências Rust fixadas no manifesto. O artefato gerado substitui `AnkiOS/AnkiBackendBridge/AnkiBackend.xcframework`.
