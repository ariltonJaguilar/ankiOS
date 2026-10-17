# Validação de paridade

Referência dos testes: Anki Desktop 26.9.3, biblioteca Python `anki==26.9.3`.
Os testes usam coleções descartáveis em `/tmp/ankios-parity`, sem abrir os perfis pessoais.

## Resultado em 17/10/2026

- Suíte completa: **22 grupos aprovados**, sem diferenças nas fixtures, saída 0.
- Compilação Debug macOS arm64: aprovada, sem assinatura.
- Compilação Debug iOS Simulator arm64 e x86_64: aprovada, sem assinatura.
- Instalação e abertura da compilação iOS no simulador isolado: aprovadas.
- A tela inicial de baralhos foi inspecionada visualmente no simulador.

Foram corrigidos o descarte de texto literal `{{...}}` nos campos, a reinterpretação
de `FrontSide` e a exibição de campos que o template não solicitava quando a pergunta
ficava vazia. Perguntas vazias e omissões Cloze ausentes agora exibem os avisos
correspondentes ao Anki. Os testes de renderização incluem essas regressões.

**Status de fechamento: pendente.** Não foram executados todos os fluxos interativos
nas duas plataformas, nem sincronização real com AnkiWeb/iCloud, testes em aparelhos
físicos ou uma distribuição Release assinada. Os critérios abaixo continuam necessários.

## Execução

```sh
python3 -m venv /tmp/ankios-parity/venv
/tmp/ankios-parity/venv/bin/pip install anki==26.9.3
zsh Tools/Parity/build-harness.sh
/tmp/ankios-parity/venv/bin/python -u Tools/Parity/oracle.py all
```

O harness compila sem otimização por padrão. Para testar uma compilação otimizada,
use `ANKIOS_PARITY_OPTIMIZATION=-O zsh Tools/Parity/build-harness.sh`.

## Cobertura automatizada

| Área | Verificações |
| --- | --- |
| Estudo | Virada do dia, contagens, estados SM-2, FSRS, passos vazios, sessão, avaliar agora |
| Navegador | Busca, operadores inválidos, suspensão, ocultação, reposicionamento, mover, esquecer, definir vencimento |
| Coleção | Baralhos hierárquicos, exclusão, desfazer/refazer, etiquetas, tipos de nota, cartões vazios |
| Templates | Filtros, entidades HTML, erros de sintaxe, conteúdo literal com chaves, perguntas vazias |
| Estatísticas | Retenção e agregações cobertas pelas fixtures |
| Intercâmbio | Pacotes Anki, baralho real, CSV, LaTeX, baralhos filtrados |
| Sincronização | Metadados locais das operações cobertas; não comprova sincronização com servidor |

Os horários de última revisão de “Avaliar agora” são validados dentro do intervalo
da operação, pois as duas implementações executam em momentos distintos. Os demais
dados do cartão e os estados de desfazer/refazer continuam sendo comparados.
Vencimentos das filas de aprendizagem em segundos aceitam até dois segundos de
diferença de relógio; vencimentos em dias continuam exigindo igualdade exata.

## Critérios de fechamento

Uma execução sem diferenças nas fixtures não certifica paridade integral.
O fechamento também exige validação interativa dos fluxos abaixo em macOS e iOS:

| Tela ou fluxo | Validação necessária nas duas plataformas |
| --- | --- |
| Baralhos e visão geral | Criar, renomear, mover, excluir, hierarquia, contagens e seleção |
| Estudo | Responder, editar, desfazer, atalhos, áudio, gravação, digitação e avanço automático |
| Opções e estudo personalizado | Presets, limites, FSRS, irmãos, filtros e reconstrução |
| Adicionar e editar | Campos ricos, HTML, mídia, etiquetas, duplicatas, campos fixos e oclusão de imagem |
| Tipos de nota | Campos, templates, CSS, prévia, alteração de tipo e preservação dos cartões |
| Navegador | Seleção, edição, busca, ordenação, operações em lote, exportação e prévia |
| Estatísticas | Períodos, escopo, gráficos e valores em coleções representativas |
| Ferramentas | Importar/exportar, verificar banco e mídia, backups e restauração |
| Preferências e perfis | Persistência, troca de perfil, aparência, idioma e acessibilidade |
| AnkiWeb | Login, envio/recebimento completo, sincronização incremental, mídia, conflito e cancelamento |
| iCloud | Conflito, recuperação e isolamento entre perfis |
| Integrações do sistema | Abrir pacotes, permissões, segundo plano, widget e múltiplas janelas |

Compatibilidade com extensões Python/Qt do Anki Desktop não é demonstrada por esta
suíte. A interface SwiftUI também precisa de validação própria; compilar não valida
interações, acessibilidade, reprodução de mídia ou comportamento em dispositivos.
