# Avisos de terceiros

O código original do AnkiOS é © 2026 Arilton Aguilar e contribuidores e está licenciado sob a GNU Affero General Public License, versão 3 ou, a critério de cada destinatário, qualquer versão posterior. O texto integral está em [LICENSE](LICENSE) e é incluído no app.

O AnkiOS é um app independente para iOS/iPadOS que integra o backend Rust do Anki e acrescenta um cliente, interface e bridges próprios. Ele não é o app oficial do Anki e não é afiliado nem endossado pela Ankitects. As adaptações do AnkiOS estão registradas no histórico deste repositório; esta versão foi atualizada em 25 de outubro de 2026.

Os componentes de terceiros mantêm seus próprios titulares de direitos autorais e licenças:

| Componente | Licença e origem |
| --- | --- |
| Backend Rust do Anki | AGPL-3.0-or-later; revisão [`c3139c607373c99c81854d61f1ddc45e4606343c`](https://github.com/ankitects/anki/tree/c3139c607373c99c81854d61f1ddc45e4606343c). Avisos upstream em `AnkiOS/AnkiBackendBridge/UPSTREAM-LICENSE.txt`. |
| FSRS | BSD-3-Clause; crate oficial versão 6.6.2, de Open Spaced Repetition. Texto em `AnkiOS/FSRSBridge/LICENSE`. |
| Zstandard | BSD; código e texto da licença em `AnkiOS/Import/ZstdNative/`. |
| MathJax | Apache-2.0; texto em `AnkiOS/Resources/MathJax/LICENSE`. |
| Traduções do Anki | Traduções estáticas com correspondência única, sob BSD-3-Clause e domínio público conforme os repositórios oficiais; detalhes e revisões em [`Tools/Parity/THIRD_PARTY_NOTICES.md`](Tools/Parity/THIRD_PARTY_NOTICES.md). |
| Dependências Rust | Versões, expressões SPDX, origem, manifestos e textos de licença publicados pelos pacotes estão em [`Tools/Legal/rust-crate-licenses.csv`](Tools/Legal/rust-crate-licenses.csv) e `AnkiOS/Resources/Licenses/RustCrateLicenses.txt`. |

O inventário Rust é gerado a partir de `AnkiOS/AnkiBackendBridge/Cargo.lock` e `AnkiOS/FSRSBridge/Cargo.lock` por `python3 Tools/Legal/generate-rust-license-notices.py`. Ele inclui os grafos de dependências fixados pelo Cargo, inclusive pacotes específicos de outras plataformas e ferramentas de compilação que podem não entrar no binário iOS. Os arquivos de licença que os pacotes publicam são reproduzidos no inventário; pacotes sem arquivo próprio permanecem identificados pela expressão SPDX e pelo endereço de origem no CSV.

O nome e as marcas Anki e AnkiWeb pertencem aos respectivos titulares.
