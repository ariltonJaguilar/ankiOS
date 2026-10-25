# AnkiOS

iOS and iPadOS Anki-compatible study app with Liquid Glass UI.

## Open & run

```bash
open "/Users/ariltonaguilar/Desktop/Projetos/Anki/DeckExample/AnkiOS/AnkiOS.xcodeproj"
```

Pick an **iPhone** or **iPad** destination, then run the app.

The collection starts empty. Import your own deck from Ferramentas or the deck list.

## Navigation (Anki parity)

- **Baralhos** — deck list & study
- **Adicionar** — add notes
- **Painel** — browser with filters + editor
- **Estatísticas** — today / future / retention
- **Ferramentas** — import/export, options, tutorial

AnkiWeb sync uses the upstream Rust backend pinned in `AnkiOS/AnkiBackendBridge/Cargo.toml`.

## Requirements

- Xcode 27
- iOS 26 SDK
- Swift 6

The FSRS optimizer and simulator use the official `fsrs` 6.6.2 crate through the same Rust XCFramework as AnkiWeb sync.

AnkiWeb sync links the Anki Rust backend at the pinned revision in `Cargo.toml`. The upstream backend is licensed under AGPL-3.0-or-later; its license is included in `AnkiOS/AnkiBackendBridge/UPSTREAM-LICENSE.txt`.

To rebuild the backend XCFramework, install Rust with the `aarch64-apple-ios`, `aarch64-apple-ios-sim`, and `x86_64-apple-ios` targets, then run `AnkiOS/AnkiBackendBridge/build-xcframework.sh`.
