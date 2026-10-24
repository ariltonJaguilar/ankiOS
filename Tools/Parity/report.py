import json
from collections import defaultdict
from pathlib import Path
import re

root = Path(__file__).resolve().parent
data = json.loads((root / "coverage.json").read_text())
code = data["codeFlows"]
ui = data["uiFlows"]
labels = {"verified": "Aprovado", "partial": "Parcial", "pending": "Pendente"}


def percentage(value):
    return f"{value:.1f}".replace(".", ",")


def localized_integer(value):
    return f"{value:,}".replace(",", ".")


def translation_is_explicit(entry, locale):
    localization = entry.get("localizations", {}).get(locale, {})
    if localization.get("stringUnit", {}).get("state") == "translated":
        return True
    return any(
        unit.get("stringUnit", {}).get("state") == "translated"
        for variation in localization.get("variations", {}).values()
        for unit in variation.values()
    )


def summary(rows, key="status"):
    counts = {name: sum(row.get(key) == name for row in rows) for name in labels}
    total = len(rows)
    percent = counts["verified"] * 100 / total if total else 0
    return counts, total, percent


code_counts, code_total, code_percent = summary(code)
code_partial_label = "parcial" if code_counts["partial"] == 1 else "parciais"
ios_ui = [flow | flow["platforms"]["iOS"] for flow in ui]
mac_ui = [flow | flow["platforms"]["macOS"] for flow in ui]
ios_ui_counts, ios_ui_total, ios_ui_percent = summary(ios_ui)
mac_ui_counts, mac_ui_total, mac_ui_percent = summary(mac_ui)
ios_ui_partial_label = "parcial" if ios_ui_counts["partial"] == 1 else "parciais"
mac_ui_partial_label = "parcial" if mac_ui_counts["partial"] == 1 else "parciais"
ios_ui_exercised = ios_ui_counts["verified"] + ios_ui_counts["partial"]
mac_ui_exercised = mac_ui_counts["verified"] + mac_ui_counts["partial"]
ios_ui_exercised_percent = ios_ui_exercised * 100 / ios_ui_total if ios_ui_total else 0
mac_ui_exercised_percent = mac_ui_exercised * 100 / mac_ui_total if mac_ui_total else 0
ios_progress = data["iosTestProgress"]
ios_validation_state = data.get("iosValidationState", {})
last_ios_ui_test = data.get("lastUITestRun", {})
last_ios_ui_test_note = last_ios_ui_test.get("note", "sem resultado registrado").rstrip(".")
ios_pause_reason = ios_validation_state.get("reason", "não informado").rstrip(".")
ios_run_status = (
    "pausada a pedido do usuário"
    if ios_validation_state.get("status") == "paused"
    else "teste em execução"
    if ios_validation_state.get("activeRun")
    else "retomada; sem teste em execução neste momento"
)
ios_build_validation = data.get("iosBuildValidation", {})
ios_manual_audit = data.get("iosManualAudit", {})
ios_manual_requirements = ios_manual_audit.get("knownGaps", [])
ios_manual_gaps = sum(item.get("status") == "gap" for item in ios_manual_requirements)
ios_manual_partial = sum(item.get("status") == "partially_verified" for item in ios_manual_requirements)
ios_manual_unverified_contracts = sum(item.get("status") == "contract_unverified" for item in ios_manual_requirements)
ios_manual_pending_validation = sum(item.get("status") == "implemented_waiting_ui_validation" for item in ios_manual_requirements)
ios_manual_gap_label = "diferença" if ios_manual_gaps == 1 else "diferenças"
ios_manual_contract_label = "contrato sem confirmação" if ios_manual_unverified_contracts == 1 else "contratos sem confirmação"
ios_manual_pending_label = "alteração aguardando" if ios_manual_pending_validation == 1 else "alterações aguardando"
mac_progress = data.get("macTestProgress", {})
mac_ui_attempt = data.get("macUITestAttempt", {})
mac_ui_test_methods = {
    method.strip()
    for flow in ui
    for method in flow["platforms"]["macOS"].get("evidence", "").split(";")
    if method.strip() and method.strip() != "—"
}
string_catalog = json.loads((root.parent.parent / "AnkiOS/Localization/Localizable.xcstrings").read_text())
string_key_count = len(string_catalog.get("strings", {}))
language_source = string_catalog.get("sourceLanguage", "desconhecido")
language_source = {"pt-BR": "Português Brasileiro", "en": "Inglês"}.get(language_source, language_source)
language_source_file = (root.parent.parent / "AnkiOS/Localization/AnkiLanguage.swift").read_text()
desktop_languages = len(re.findall(r'AnkiLanguage\(name:', language_source_file))
en_us_count = sum(
    translation_is_explicit(entry, "en-US")
    for entry in string_catalog.get("strings", {}).values()
)
locale_translation_counts = {
    locale: sum(
        translation_is_explicit(entry, locale)
        for entry in string_catalog.get("strings", {}).values()
    )
    for locale in {
        locale
        for entry in string_catalog.get("strings", {}).values()
        for locale in entry.get("localizations", {})
    }
}
compiled_locales = len(locale_translation_counts)
lowest_locale, lowest_locale_count = min(locale_translation_counts.items(), key=lambda item: item[1])
highest_locale, highest_locale_count = max(locale_translation_counts.items(), key=lambda item: item[1])
current_sweep = data.get("currentUISweep", {})
localization_check = data.get("localizationBundleCheck", {})
localization_comparison_path = root / "localization-comparison.json"
localization_comparison = json.loads(localization_comparison_path.read_text()) if localization_comparison_path.exists() else {}
official_locale_rows = [row for row in localization_comparison.get("comparison", []) if row.get("catalogLocalePresent")]
unambiguous_equal = sum(row.get("equal", 0) for row in official_locale_rows)
unambiguous_different = sum(row.get("different", 0) for row in official_locale_rows)
ambiguous_contexts = sum(row.get("ambiguousUpstream", 0) for row in official_locale_rows)
untranslated_upstream = sum(row.get("upstreamMissing", 0) for row in official_locale_rows)
english_fallback_equal = sum(row.get("englishFallbackEqual", 0) for row in official_locale_rows)
english_fallback_different = sum(row.get("englishFallbackDifferent", 0) for row in official_locale_rows)
english_fallback_checked = english_fallback_equal + english_fallback_different
english_fallback_context_unresolved = max(0, untranslated_upstream - english_fallback_checked)
plural_comparison_rows = localization_comparison.get("pluralContextComparisons", [])
plural_equal = sum(row.get("equalCategories", 0) for row in plural_comparison_rows)
plural_planned = sum(row.get("plannedCategories", 0) for row in plural_comparison_rows)
plural_different = sum(row.get("differentCategories", 0) for row in plural_comparison_rows)
official_locales_present = localization_comparison.get("officialLocalesPresent", 0)
official_locales_total = localization_comparison.get("officialNonEnglishLocales", 0)
unmapped_english = localization_comparison.get("unmappedEnglishMessages", 0)
unmapped_classified = localization_comparison.get("classifiedUnmappedEnglishMessages", 0)
unmapped_unclassified = len(localization_comparison.get("unclassifiedUnmappedEnglishLabels", []))
context_resolved = localization_comparison.get("contextResolvedCatalogEntries", 0)
context_unresolved = localization_comparison.get("contextUnresolvedCatalogEntries", 0)
areas = defaultdict(list)
for flow in code:
    areas[flow["area"]].append(flow)

lines = [
    "# Painel de paridade",
    "",
    f"Referência: {data['reference']}. Inventário atualizado por `report.py`; última execução diferencial registrada: {data['lastDifferentialRun']['date']}.",
    "",
    "## Progresso",
    "",
    f"- Código comparado com o Anki: **{code_counts['verified']}/{code_total} fluxos aprovados ({percentage(code_percent)}%)**; {code_counts['partial']} {code_partial_label} e {code_counts['pending']} pendentes.",
    f"- UI iOS (placar independente): **{ios_ui_exercised}/{ios_ui_total} macrofluxos iniciados com teste aprovado ({percentage(ios_ui_exercised_percent)}%)**; {ios_ui_counts['verified']} completos, {ios_ui_counts['partial']} em andamento e {ios_ui_counts['pending']} não iniciados.",
    f"- UI macOS (placar independente): **{mac_ui_exercised}/{mac_ui_total} macrofluxos iniciados com teste aprovado ({percentage(mac_ui_exercised_percent)}%)**; {mac_ui_counts['verified']} completos, {mac_ui_counts['partial']} em andamento e {mac_ui_counts['pending']} não iniciados.",
    f"- Catálogo de interface: **{string_key_count} chaves**, idioma-fonte {language_source}, {compiled_locales} localizações compiladas; o seletor de idioma do macOS contém {desktop_languages} opções. Traduções explícitas variam de {lowest_locale_count}/{string_key_count} ({lowest_locale}) a {highest_locale_count}/{string_key_count} ({highest_locale}); inglês tem {en_us_count}/{string_key_count}.",
    f"- Recursos de localização do app iOS: **{localized_integer(localization_check.get('passed', 0))}/{localized_integer(localization_check.get('planned', 0))} combinações chave/idioma verificadas**; esse ensaio confere o carregamento do catálogo, não compara traduções com o AnkiMobile.",
    f"- Traduções iOS publicadas pelo AnkiMobile: **{official_locales_present}/{official_locales_total} idiomas não ingleses no catálogo**; {localized_integer(unambiguous_equal)}/{localized_integer(unambiguous_equal + unambiguous_different)} textos estáticos com fonte única coincidem exatamente. O texto-fonte resolveu o contexto de {context_resolved}/{localization_comparison.get('directMappings', 0)} mensagens; restam {context_unresolved} mensagens ambíguas ({localized_integer(ambiguous_contexts)} pares locale/contexto). Dos casos sem tradução upstream, {localized_integer(english_fallback_equal)}/{localized_integer(english_fallback_checked)} fallbacks em inglês coincidem; {localized_integer(english_fallback_context_unresolved)} ainda não permitem escolher contexto. Há {unmapped_english} rótulos sem mapeamento FTL direto; {unmapped_classified} estão classificados e {unmapped_unclassified} seguem sem classificação.",
    f"- Plurais do Estudo Personalizado: **{localized_integer(plural_equal)}/{localized_integer(plural_planned)} variantes oficiais coincidem** em {len(plural_comparison_rows)} mensagens FTL (cartões, dias e cartões do baralho).",
    f"- XCTest iOS (inventário acumulado): **{ios_progress['passed']}/{ios_progress['planned']} métodos distintos aprovados**; isso registra aprovações históricas e retestes direcionados, não uma nova varredura completa após as mudanças recentes. Último reteste: {last_ios_ui_test_note}.",
    f"- Validação XCTest iOS: **{ios_run_status}**; estado: {ios_pause_reason}.",
    f"- Build iOS sem testes: **{ios_build_validation.get('statusLabel', 'sem resultado registrado')}**; {ios_build_validation.get('summary', '')}",
    f"- Auditoria iOS do manual oficial: **{len(ios_manual_requirements)} requisitos conferidos**, {ios_manual_gaps} {ios_manual_gap_label} de implementação, {ios_manual_partial} parciais, {ios_manual_unverified_contracts} {ios_manual_contract_label} e {ios_manual_pending_validation} {ios_manual_pending_label} validação UI; auditoria em andamento.",
    f"- XCTest exclusivos do macOS: **{mac_progress.get('passed', 0)}/{mac_progress.get('planned', 0)} métodos aprovados**; este inventário não se soma ao denominador iOS.",
    f"- Evidência XCTest dos macrofluxos macOS: **{len(mac_ui_test_methods)} métodos únicos aprovados** nas 7 áreas já iniciadas; esses métodos são evidência para os {len(ui)} grupos, não um denominador variável.",
    f"- Varredura completa iOS: **{current_sweep.get('passed', 0)}/{current_sweep.get('planned', ios_progress['planned'])} métodos distintos aprovados no ciclo completo registrado**; as mudanças posteriores receberam retestes direcionados, sem nova varredura integral. As {current_sweep.get('retries', 0)} tentativas repetidas e {current_sweep.get('abortedExecutions', 0)} interrupções são histórico, não testes pendentes.",
    f"  Escopo: {ios_progress['scope']}",
    f"- Última suíte diferencial registrada: **{data['lastDifferentialRun']['passedSuites']}/{data['lastDifferentialRun']['passedSuites'] + data['lastDifferentialRun']['failedSuites']} grupos aprovados** contra Anki 26.9.3 ({data['lastDifferentialRun']['date']}); {data['lastDifferentialRun'].get('note', '')}",
    "- A contagem de iOS e macOS é independente. A etapa atual fecha iOS; o trabalho já validado no macOS permanece visível no placar macOS.",
    "",
    "## UI iOS",
    "",
    f"Placar iOS independente: **{ios_ui_exercised}/{ios_ui_total} grupos iniciados com teste aprovado ({percentage(ios_ui_exercised_percent)}%)**; {ios_ui_counts['verified']}/{ios_ui_total} completos ({percentage(ios_ui_percent)}%), {ios_ui_counts['partial']} em andamento e {ios_ui_counts['pending']} não iniciados. Iniciado significa que ao menos um teste interativo do grupo passou no iOS; completo exige evidência aprovada para todos os comportamentos listados. Isso não afirma que todas as telas foram comparadas lado a lado com o Anki original. A trilha histórica está em `coverage.json`; os totais são fixos e uma aprovação não é reaberta sem mudança ou evidência contraditória.",
    "",
    "| Área | Estado | Evidência | Próximo passo |",
    "| --- | --- | --- | --- |",
]
for flow in ui:
    platform = flow["platforms"]["iOS"]
    next_step = platform.get("next", "—") if platform["status"] in {"partial", "pending"} else "—"
    evidence = platform.get("evidence", "sem evidência registrada")
    ios_label = {"verified": "Completo", "partial": "Em progresso", "pending": "Não iniciado"}.get(platform["status"], "Não iniciado")
    lines.append(f"| {flow['area']} | {ios_label} | {evidence} (`{platform.get('testEvidence', '')}`) | {next_step} |")

lines.extend([
    "",
    "## UI macOS",
    "",
    f"Placar macOS independente: **{mac_ui_exercised}/{mac_ui_total} grupos iniciados com teste aprovado ({percentage(mac_ui_exercised_percent)}%)**; {mac_ui_counts['verified']}/{mac_ui_total} completos ({percentage(mac_ui_percent)}%), {mac_ui_counts['partial']} em andamento e {mac_ui_counts['pending']} não iniciados. O escopo fica fixo nesses 12 grupos; métodos XCTest são evidência e não aumentam o denominador. Um grupo completo exige evidência aprovada para todos os comportamentos listados.",
    "",
    "| Área | Estado | Evidência aprovada |",
    "| --- | --- | --- |",
])
if mac_ui_attempt.get("outcome") == "blocked-before-test":
    lines.extend([
        "",
        f"Última tentativa macOS: `{mac_ui_attempt.get('scope', '—')}`; {mac_ui_attempt.get('casesExecuted', 0)} casos iniciados em {mac_ui_attempt.get('environmentRetries', 0)} tentativas por bloqueio de ambiente. {mac_ui_attempt.get('reason', '')}",
    ])
for flow in ui:
    platform = flow["platforms"]["macOS"]
    mac_label = {"verified": "Completo", "partial": "Em progresso", "pending": "Não iniciado"}.get(platform["status"], "Não iniciado")
    lines.append(f"| {flow['area']} | {mac_label} | {platform.get('evidence', '—')} |")

lines.extend([
    "",
    "## Critérios para fechar a etapa iOS",
    "",
    f"1. Os {code_total} fluxos de código ativos estão aprovados contra a mesma versão de referência; a comparação cobre a lógica e não substitui a validação interativa das interfaces.",
    f"2. Os {len(ui)} macrofluxos iOS mantêm estado e evidência independentes por plataforma. O comparativo registra {context_resolved}/{localization_comparison.get('directMappings', 0)} mensagens com contexto resolvido, {localized_integer(unambiguous_equal)}/{localized_integer(unambiguous_equal + unambiguous_different)} traduções estáticas coincidentes e {unmapped_classified}/{unmapped_english} rótulos sem mapeamento FTL direto classificados; {unmapped_unclassified} seguem sem classificação. A sincronização iCloud foi removida do produto e suas verificações de ausência aguardam reteste.",
    f"3. O inventário XCTest permanece fixo em {ios_progress['planned']} métodos iOS; {ios_progress['passed']}/{ios_progress['planned']} estão aprovados para o código atual. Só se repetem casos afetados por mudanças ou por uma diferença observada.",
    "4. Ao cumprir esses três itens, a etapa iOS fecha. A revisão macOS é uma fase separada e não deve zerar o placar iOS.",
])

lines.extend([
    "",
    "## Resumo por área de código",
    "",
    "| Área | Aprovados | Total | Progresso |",
    "| --- | ---: | ---: | ---: |",
])
for area, flows in areas.items():
    counts, total, percent = summary(flows)
    lines.append(f"| {area} | {counts['verified']} | {total} | {percentage(percent)}% |")

lines.extend([
    "",
    "## Fluxos de código",
    "",
    "| Área | Fluxo | Estado | Evidência ou próximo passo |",
    "| --- | --- | --- | --- |",
])
for area, flows in areas.items():
    for flow in flows:
        lines.append(f"| {area} | {flow['flow']} | {labels[flow['status']]} | `{flow['check']}` |")

lines.extend([
    "",
    "## Atualizar o painel",
    "",
    "1. Execute a comparação diferencial: `/tmp/ankios-parity/venv/bin/python -u Tools/Parity/oracle.py all`.",
    "2. Registre uma mudança real de estado ou uma nova cobertura em `coverage.json` e gere este painel com `python3 Tools/Parity/report.py`.",
    "3. Não repita métodos aprovados sem mudança de código ou evidência contraditória. Repetições e diagnósticos não alteram o inventário fixo.",
    "4. Cada grupo mantém estados independentes para iOS e macOS. Um grupo pode concluir em uma plataforma enquanto segue parcial ou pendente na outra.",
    "",
    "A compatibilidade com extensões Python/Qt do Anki Desktop não está incluída como paridade demonstrada.",
])

(root / "STATUS.md").write_text("\n".join(lines) + "\n")
print(f"Código: {code_counts['verified']}/{code_total}. UI iOS independente: {ios_ui_exercised}/{ios_ui_total} iniciados com teste aprovado ({percentage(ios_ui_exercised_percent)}%); {ios_ui_counts['verified']} completos, {ios_ui_counts['partial']} em andamento e {ios_ui_counts['pending']} não iniciados; XCTest {ios_progress['passed']}/{ios_progress['planned']}. UI macOS independente: {mac_ui_exercised}/{mac_ui_total} iniciados com teste aprovado ({percentage(mac_ui_exercised_percent)}%); {mac_ui_counts['verified']} completos, {mac_ui_counts['partial']} em andamento e {mac_ui_counts['pending']} não iniciados; XCTest exclusivo {mac_progress.get('passed', 0)}/{mac_progress.get('planned', 0)}.")
