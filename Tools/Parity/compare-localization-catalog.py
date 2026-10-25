import argparse
from datetime import date
import json
import re
import subprocess
from collections import defaultdict
from pathlib import Path


MESSAGE_PATTERN = re.compile(r"(?m)^([a-zA-Z0-9_-]+)\s*=\s*(.*?)(?=\n\S|\Z)", re.S)
FLUENT_VARIABLE_PATTERN = re.compile(r"\{\s*\$[a-zA-Z][a-zA-Z0-9_-]*\s*\}")
PLURAL_CATEGORIES = ("zero", "one", "two", "few", "many", "other")
PLURAL_MARKER = "\u2063"
PLURAL_CONTEXT_STRINGS = [
    ("%lld custom-study.cards", "custom-study.ftl", "custom-study-cards", "cartão", "cartões"),
    ("%lld custom-study.days", "custom-study.ftl", "custom-study-days", "dia", "dias"),
    ("%lld custom-study.cards-from-the-deck", "custom-study.ftl", "custom-study-cards-from-the-deck", "cartão do baralho", "cartões do baralho"),
]
OFFICIAL_LOCALES = [
    ("ar-SA", "ar"),
    ("be-BY", "be"),
    ("ca-ES", "ca"),
    ("cs-CZ", "cs"),
    ("fi-FI", "fi"),
    ("fr-FR", "fr"),
    ("de-DE", "de"),
    ("he-IL", "he"),
    ("ga-IE", "ga-IE"),
    ("it-IT", "it"),
    ("ja-JP", "ja"),
    ("ko-KR", "ko"),
    ("ml-IN", "ml"),
    ("or-OR", "or"),
    ("fa-IR", "fa"),
    ("pl-PL", "pl"),
    ("pt-BR", "pt-BR"),
    ("ro-RO", "ro"),
    ("ru-RU", "ru"),
    ("zh-CN", "zh-CN"),
    ("es-ES", "es"),
    ("zh-TW", "zh-TW"),
    ("tr-TR", "tr"),
    ("vi-VN", "vi"),
]
CONTEXT_STRINGS = [
    ("tab.decks", "Decks", "Baralhos", "mobile", "actions.ftl", "actions-decks-short"),
    ("Add Media", "Add Media", "Adicionar Mídia", "core", "editing.ftl", "editing-add-media"),
    ("Shared Deck List", "Shared Deck List", "Lista de baralhos compartilhados", "mobile", "decks.ftl", "decks-shared-deck-list"),
    ("From Photos", "From Photos", "De Fotos", "mobile", "editing.ftl", "editing-from-photos"),
    ("From Camera", "From Camera", "Da Câmera", "mobile", "editing.ftl", "editing-from-camera"),
    ("From File", "From File", "Do Arquivo", "mobile", "editing.ftl", "editing-from-file"),
    ("Draw", "Draw", "Desenhar", "mobile", "actions.ftl", "actions-draw"),
    ("Record Voice", "Record Voice", "Gravar Voz", "mobile", "actions.ftl", "actions-record-voice"),
    ("Max Image Size (Long Edge)", "Max Image Size (Long Edge)", "Tamanho Máximo da Imagem (Borda Longa)", "mobile", "preferences.ftl", "preferences-editing-max-image-size"),
    ("Resize When Pasting", "Resize When Pasting", "Redimensionar ao colar", "mobile", "preferences.ftl", "preferences-editing-resize-on-paste"),
    ("A note with the same first field already exists.", "A note with the same first field already exists.", "Uma anotação com o mesmo primeiro campo já existe.", "mobile", "urlscheme.ftl", "urlscheme-a-note-with-the-same-first"),
    ("Invalid profile name.", "Invalid profile name.", "Nome de perfil inválido.", "mobile", "urlscheme.ftl", "urlscheme-invalid-profile-name"),
    ("The provided note type does not exist.", "The provided note type does not exist.", "O tipo de nota fornecido não existe.", "mobile", "urlscheme.ftl", "urlscheme-the-provided-note-type-does-not"),
    ("The provided deck does not exist.", "The provided deck does not exist.", "O baralho fornecido não existe.", "mobile", "decks.ftl", "decks-the-provided-deck-does-not-exist"),
    ("The first field can not be blank.", "The first field can not be blank.", "O primeiro campo não pode ficar em branco.", "mobile", "urlscheme.ftl", "urlscheme-the-first-field-can-not-be"),
    ("decks.page.title", "Decks", "Baralhos", "core", "actions.ftl", "actions-decks"),
    ("browser.sidebar.decks", "Decks", "Baralhos", "core", "browsing.ftl", "browsing-sidebar-decks"),
    ("browser.column.deck", "Deck", "Baralho", "core", "card-stats.ftl", "card-stats-deck-name"),
    ("decks.deck.label", "Deck", "Baralho", "core", "decks.ftl", "decks-deck"),
    ("stats.deck.filter", "Deck", "Baralho", "core", "card-stats.ftl", "card-stats-deck-name"),
    ("stats.cards.label", "Cards", "Cartões", "core", "browsing.ftl", "browsing-cards"),
    ("stats.new-cards", "New", "Novos", "core", "statistics.ftl", "statistics-counts-new-cards"),
    ("decks.learn-count", "Learn", "Aprender", "core", "decks.ftl", "decks-learn-header"),
    ("browser.card-state.new", "New", "Novo", "core", "change-notetype.ftl", "change-notetype-new"),
    ("browser.card-state.learning", "Learning", "Aprendizagem", "core", "scheduling.ftl", "scheduling-learning"),
    ("Duplicar: %@", "Clone: %@", "Duplicar: %@", "core", "notetypes.ftl", "notetypes-clone"),
    ("mobile.scratchpad.name", "Scratchpad", "Caderno de Rascunhos", "mobile", "actions.ftl", "actions-scratchpad"),
    ("mobile.scratchpad.ignoresFingers", "Drawing Screen Ignores Fingers", "A tela de desenho ignora os dedos", "mobile", "preferences.ftl", "preferences-drawing-screen-ignores-fingers"),
    ("mobile.scratchpad.undoClearsAll", "Undo Clears All", "Desfazer Limpar Tudo", "mobile", "preferences.ftl", "preferences-undo-clears-all"),
    ("mobile.scratchpad.belowButtons", "Scratchpad Below Buttons", "Bloco de rascunho abaixo dos botões", "mobile", "preferences.ftl", "preferences-scratchpad-below-buttons"),
    ("mobile.preferences.toolsOverlayButton", "Tools Overlay Button", "Botão de sobreposição de Ferramentas", "mobile", "preferences.ftl", "preferences-tools-overlay-button"),
    ("stats.decks.count", "Decks", "Baralhos", "core", "actions.ftl", "actions-decks"),
    ("deck-options.new-order.random", "Random", "Aleatório", "core", "deck-config.ftl", "deck-config-new-insertion-order-random"),
    ("deck-options.sort-order.random", "Random", "Aleatório", "core", "deck-config.ftl", "deck-config-sort-order-random"),
    ("deck-options.filtered-order.random", "Random", "Aleatório", "core", "decks.ftl", "decks-random"),
    ("deck-options.gather-priority.deck", "Deck", "Baralho", "core", "deck-config.ftl", "deck-config-new-gather-priority-deck"),
    ("browser.cards-mode", "Cards", "Cartões", "core", "browsing.ftl", "browsing-cards"),
    ("settings.cards.section", "Cards", "Cartões", "core", "editing.ftl", "editing-cards"),
    ("browser.find-replace.fields", "Fields", "Campos", "core", "editing.ftl", "editing-fields"),
    ("editor.fields.section", "Fields", "Campos", "core", "editing.ftl", "editing-fields"),
    ("sync.cancel-full-sync", "Cancel", "Cancelar", "core", "sync.ftl", "sync-cancel-button"),
    ("study.edit", "Edit", "Editar", "core", "studying.ftl", "studying-edit"),
    ("note-types.preview.section", "Preview", "Pré-visualização", "core", "card-templates.ftl", "card-templates-preview-box"),
    ("deck-options.action", "Deck Options", "Opções do Baralho", "mobile", "decks.ftl", "decks-deck-options"),
    ("deck-options.title", "Deck Options", "Opções do Baralho", "core", "deck-config.ftl", "deck-config-title"),
    ("custom-study.select", "Select", "Selecionar", "core", "custom-study.ftl", "custom-study-select"),
    ("stats.collection.range", "collection", "coleção", "core", "statistics.ftl", "statistics-range-collection"),
    ("settings.collection.section", "collection", "coleção", "core", "exporting.ftl", "exporting-collection"),
    ("preferences.review.section", "Review", "Revisar", "core", "preferences.ftl", "preferences-review"),
    ("Horário de alerta", "Alert Time", "Horário de Alerta", "mobile", "preferences.ftl", "preferences-notifications-alert-time"),
    ("preferences.notifications.alertWhenDue", "Alert When Due", "Alertar quando houver cartões pendentes", "mobile", "preferences.ftl", "preferences-notifications-alert-when-due"),
    ("deck-options.save", "Save", "Salvar", "core", "deck-config.ftl", "deck-config-save-button"),
    ("deck-options.reviews.section", "Reviews", "Revisões", "core", "scheduling.ftl", "scheduling-reviews"),
    ("deck-options.fsrs.reviews", "Reviews", "Revisões", "core", "deck-config.ftl", "deck-config-fsrs-simulator-radio-count"),
    ("browser.review-count", "Reviews", "Revisões", "core", "card-stats.ftl", "card-stats-review-count"),
    ("stats.reviews.title", "Reviews", "Revisões", "core", "statistics.ftl", "statistics-reviews-title"),
    ("browser.card-state.review", "Review", "Revisão", "core", "browsing.ftl", "browsing-sidebar-card-state-review"),
    ("browser.actions", "Actions", "Ações", "mobile", "actions.ftl", "actions-actions"),
    ("study.more", "More", "Mais", "core", "studying.ftl", "studying-more"),
    ("browser.add-tags", "Add Tags...", "Adicionar Etiquetas...", "core", "browsing.ftl", "browsing-add-tags2"),
    ("browser.grade-now", "Grade Now", "Avaliar Agora", "core", "actions.ftl", "actions-grade-now"),
    ("study.create-copy", "Create Copy", "Criar Cópia", "core", "actions.ftl", "actions-create-copy"),
    ("profiles.delete", "Delete", "Excluir", "core", "actions.ftl", "actions-delete"),
    ("browser.find-replace", "Find and Replace", "Localizar e Substituir", "core", "browsing.ftl", "browsing-find-and-replace"),
    ("browser.rename-tag", "Rename Tag", "Renomear Etiqueta", "core", "actions.ftl", "actions-rename-tag"),
    ("browser.rename", "Rename", "Renomear", "core", "actions.ftl", "actions-rename"),
    ("browser.reposition-new", "Reposition New Cards", "Reposicionar Novos Cartões", "core", "browsing.ftl", "browsing-reposition-new-cards"),
    ("browser.save-current-search", "Save Current Search", "Salvar pesquisa atual", "core", "browsing.ftl", "browsing-sidebar-save-current-search"),
    ("browser.sort", "Sort:", "Ordenar:", "mobile", "browsing.ftl", "browsing-sort"),
    ("browser.question-column", "Question", "Pergunta", "core", "browsing.ftl", "browsing-question"),
    ("browser.field-label", "Field:", "Campo:", "core", "fields.ftl", "fields-field"),
]
APP_OWNED_STRINGS = [
    ("Allow access to add information?", "Allow access to add information?", "Permitir acesso às informações de adição?"),
    ("The requesting app will receive the profile, deck, and note type names via the clipboard.", "The requesting app will receive the profile, deck, and note type names via the clipboard.", "O app solicitante receberá os nomes dos perfis, baralhos e tipos de nota pelo clipboard."),
    ("An x-success URL must be provided.", "An x-success URL must be provided.", "A solicitação precisa informar o endereço x-success."),
    ("Unable to download media from the provided URL.", "Unable to download media from the provided URL.", "Não foi possível baixar a mídia da URL informada."),
    ("Edit Drawing", "Edit Drawing", "Editar desenho"),
]
CONTEXT_OVERRIDES = {
    "tab.decks": ("mobile", "actions.ftl", "actions-decks-short"),
    "Add Media": ("core", "editing.ftl", "editing-add-media"),
    "Shared Deck List": ("mobile", "decks.ftl", "decks-shared-deck-list"),
    "From Photos": ("mobile", "editing.ftl", "editing-from-photos"),
    "From Camera": ("mobile", "editing.ftl", "editing-from-camera"),
    "From File": ("mobile", "editing.ftl", "editing-from-file"),
    "Draw": ("mobile", "actions.ftl", "actions-draw"),
    "Max Image Size (Long Edge)": ("mobile", "preferences.ftl", "preferences-editing-max-image-size"),
    "Resize When Pasting": ("mobile", "preferences.ftl", "preferences-editing-resize-on-paste"),
    "A note with the same first field already exists.": ("mobile", "urlscheme.ftl", "urlscheme-a-note-with-the-same-first"),
    "Invalid profile name.": ("mobile", "urlscheme.ftl", "urlscheme-invalid-profile-name"),
    "The provided note type does not exist.": ("mobile", "urlscheme.ftl", "urlscheme-the-provided-note-type-does-not"),
    "The provided deck does not exist.": ("mobile", "decks.ftl", "decks-the-provided-deck-does-not-exist"),
    "The first field can not be blank.": ("mobile", "urlscheme.ftl", "urlscheme-the-first-field-can-not-be"),
    "decks.page.title": ("core", "actions.ftl", "actions-decks"),
    "browser.sidebar.decks": ("core", "browsing.ftl", "browsing-sidebar-decks"),
    "browser.column.deck": ("core", "card-stats.ftl", "card-stats-deck-name"),
    "decks.deck.label": ("core", "decks.ftl", "decks-deck"),
    "stats.deck.filter": ("core", "card-stats.ftl", "card-stats-deck-name"),
    "stats.cards.label": ("core", "browsing.ftl", "browsing-cards"),
    "stats.new-cards": ("core", "statistics.ftl", "statistics-counts-new-cards"),
    "decks.learn-count": ("core", "decks.ftl", "decks-learn-header"),
    "browser.card-state.new": ("core", "change-notetype.ftl", "change-notetype-new"),
    "browser.card-state.learning": ("core", "scheduling.ftl", "scheduling-learning"),
    "Duplicar: %@": ("core", "notetypes.ftl", "notetypes-clone"),
    "mobile.scratchpad.name": ("mobile", "actions.ftl", "actions-scratchpad"),
    "mobile.scratchpad.ignoresFingers": ("mobile", "preferences.ftl", "preferences-drawing-screen-ignores-fingers"),
    "mobile.scratchpad.undoClearsAll": ("mobile", "preferences.ftl", "preferences-undo-clears-all"),
    "mobile.scratchpad.belowButtons": ("mobile", "preferences.ftl", "preferences-scratchpad-below-buttons"),
    "mobile.preferences.toolsOverlayButton": ("mobile", "preferences.ftl", "preferences-tools-overlay-button"),
    "preferences.notifications.alertWhenDue": ("mobile", "preferences.ftl", "preferences-notifications-alert-when-due"),
    "stats.decks.count": ("core", "actions.ftl", "actions-decks"),
    "deck-options.new-order.random": ("core", "deck-config.ftl", "deck-config-new-insertion-order-random"),
    "deck-options.sort-order.random": ("core", "deck-config.ftl", "deck-config-sort-order-random"),
    "deck-options.filtered-order.random": ("core", "decks.ftl", "decks-random"),
    "deck-options.gather-priority.deck": ("core", "deck-config.ftl", "deck-config-new-gather-priority-deck"),
    "browser.cards-mode": ("core", "browsing.ftl", "browsing-cards"),
    "settings.cards.section": ("core", "editing.ftl", "editing-cards"),
    "browser.find-replace.fields": ("core", "editing.ftl", "editing-fields"),
    "editor.fields.section": ("core", "editing.ftl", "editing-fields"),
    "sync.cancel-full-sync": ("core", "sync.ftl", "sync-cancel-button"),
    "study.edit": ("core", "studying.ftl", "studying-edit"),
    "note-types.preview.section": ("core", "card-templates.ftl", "card-templates-preview-box"),
    "deck-options.action": ("mobile", "decks.ftl", "decks-deck-options"),
    "deck-options.title": ("core", "deck-config.ftl", "deck-config-title"),
    "custom-study.select": ("core", "custom-study.ftl", "custom-study-select"),
    "stats.collection.range": ("core", "statistics.ftl", "statistics-range-collection"),
    "settings.collection.section": ("core", "exporting.ftl", "exporting-collection"),
    "Adicionar": ("mobile", "actions.ftl", "actions-add-short"),
    "Aceitar": ("core", "custom-study.ftl", "custom-study-ok"),
    "Cancelar": ("core", "actions.ftl", "actions-cancel"),
    "Desfazer": ("mobile", "actions.ftl", "actions-undo"),
    "Descartar": ("core", "actions.ftl", "actions-discard"),
    "Descrição": ("core", "scheduling.ftl", "scheduling-description"),
    "Editar": ("mobile", "actions.ftl", "actions-edit-short"),
    "Hoje": ("core", "browsing.ftl", "browsing-today"),
    "Opções": ("core", "actions.ftl", "actions-options"),
    "Pré-visualização": ("core", "actions.ftl", "actions-preview"),
    "Selecionar": ("core", "actions.ftl", "actions-select"),
    "Texto": ("core", "editing.ftl", "editing-image-occlusion-text-tool"),
    "browser.card-state.review": ("core", "browsing.ftl", "browsing-sidebar-card-state-review"),
    "browser.review-count": ("core", "card-stats.ftl", "card-stats-review-count"),
    "deck-options.save": ("core", "deck-config.ftl", "deck-config-save-button"),
    "deck-options.reviews.section": ("core", "scheduling.ftl", "scheduling-reviews"),
    "deck-options.fsrs.reviews": ("core", "deck-config.ftl", "deck-config-fsrs-simulator-radio-count"),
    "browser.actions": ("mobile", "actions.ftl", "actions-actions"),
    "study.more": ("core", "studying.ftl", "studying-more"),
    "browser.add-tags": ("core", "browsing.ftl", "browsing-add-tags2"),
    "browser.grade-now": ("core", "actions.ftl", "actions-grade-now"),
    "study.create-copy": ("core", "actions.ftl", "actions-create-copy"),
    "profiles.delete": ("core", "actions.ftl", "actions-delete"),
    "browser.find-replace": ("core", "browsing.ftl", "browsing-find-and-replace"),
    "browser.rename-tag": ("core", "actions.ftl", "actions-rename-tag"),
    "browser.rename": ("core", "actions.ftl", "actions-rename"),
    "browser.reposition-new": ("core", "browsing.ftl", "browsing-reposition-new-cards"),
    "browser.save-current-search": ("core", "browsing.ftl", "browsing-sidebar-save-current-search"),
    "browser.sort": ("mobile", "browsing.ftl", "browsing-sort"),
    "browser.question-column": ("core", "browsing.ftl", "browsing-question"),
    "browser.field-label": ("core", "fields.ftl", "fields-field"),
    "Etiquetas": ("core", "browsing.ftl", "browsing-sidebar-tags"),
    "Jovem": ("core", "statistics.ftl", "statistics-counts-young-cards"),
    "Maduro": ("core", "statistics.ftl", "statistics-counts-mature-cards"),
    "Maduros": ("core", "statistics.ftl", "statistics-counts-mature-cards"),
    "Mudar tipo de nota": ("core", "browsing.ftl", "browsing-change-note-type"),
    "Mostrar lembrete": ("core", "deck-config.ftl", "deck-config-question-action-show-reminder"),
    "Painel": ("mobile", "actions.ftl", "actions-browse"),
    "Pré-visualizar": ("core", "actions.ftl", "actions-preview"),
    "Revisão": ("core", "scheduling.ftl", "scheduling-review"),
    "Revisões": ("core", "scheduling.ftl", "scheduling-reviews"),
    "stats.reviews.title": ("core", "statistics.ftl", "statistics-reviews-title"),
    "aprender": ("core", "decks.ftl", "decks-learn-header"),
    "novo": ("core", "statistics.ftl", "statistics-counts-new-cards"),
    "Salvar": ("core", "actions.ftl", "actions-save"),
    "Selecionar todos": ("mobile", "browsing.ftl", "browsing-select-all"),
    "Total de cartões": ("core", "statistics.ftl", "statistics-counts-total-cards"),
    "Intervalo": ("core", "browsing.ftl", "browsing-interval"),
}
UNMAPPED_CLASSIFICATIONS = {
    "Allow access to add information?": {
        "classification": "app-owned privacy prompt",
        "reference": "AnkiMobile documents user authorization before exposing profile, deck and note type names.",
        "evidence": "The iOS URL handler presents this confirmation before writing the custom pasteboard payload.",
    },
    "The requesting app will receive the profile, deck, and note type names via the clipboard.": {
        "classification": "app-owned privacy prompt",
        "reference": "AnkiMobile documents profile, deck and note type names in the consented pasteboard response.",
        "evidence": "The iOS URL handler presents this explanation before writing the custom pasteboard payload.",
    },
    "An x-success URL must be provided.": {
        "classification": "app-owned URL scheme error",
        "reference": "The public infoForAdding example requires x-success to return to the requesting app.",
        "evidence": "AnkiMobile URL scheme handling in RootView.swift.",
    },
    "Unable to download media from the provided URL.": {
        "classification": "app-owned URL scheme error",
        "reference": "AnkiMobile's public URL scheme documentation describes importing linked image and audio media but does not specify a download-error message.",
        "evidence": "AnkiMobile URL scheme handling in RootView.swift.",
    },
    "Edit Drawing": {
        "classification": "app-owned drawing editor title",
        "reference": "The drawing editor title is specific to the iOS PencilKit sheet.",
        "evidence": "RichFieldEditor presents NoteDrawingEditor for new or existing drawings.",
    },
    "Choose which input can draw, what Undo does and where the scratchpad appears during review.": {
        "classification": "app-owned helper copy",
        "reference": "The three controls use preferences-drawing-screen-ignores-fingers, preferences-undo-clears-all and preferences-scratchpad-below-buttons.",
        "evidence": "testStudyScratchpadPreferencesPersistAndApply",
    },
    "Error": {
        "classification": "generic alert title",
        "reference": "RootView.swift presents a generic error title and supplies the actual error as separate message text.",
        "evidence": "The title has no one-to-one Fluent message; error behavior is covered by the code-flow inventory.",
    },
    "Time to study": {
        "classification": "local notification copy",
        "reference": "AnkiMobile exposes preferences-notifications-alert-when-due; its notification title has no matching Fluent message.",
        "evidence": "testStudyReminderSettingsPersistAfterRelaunch",
    },
    "You have %d cards waiting to review.": {
        "classification": "local notification copy",
        "reference": "The body is generated by StudyReminderScheduler; the official Mobile FTL has no identical notification message.",
        "evidence": "testStudyReminderSettingsPersistAfterRelaunch",
    },
    "You have 1 card waiting to review.": {
        "classification": "local notification copy",
        "reference": "The singular body is generated by StudyReminderScheduler; the official Mobile FTL has no identical notification message.",
        "evidence": "testStudyReminderSettingsPersistAfterRelaunch",
    },
    "Invert Selection": {
        "classification": "browser action label",
        "reference": "The matching Desktop label is qt-accel-invert-selection; Mobile has no identical menu label.",
        "evidence": "testBrowserBulkMarkBuryAndFlagAndUndo",
    },
    "Reminder scheduled": {
        "classification": "app-owned notification status",
        "reference": "StudyReminderScheduler.hasPendingRequest supplies this local scheduling status.",
        "evidence": "testStudyReminderSettingsPersistAfterRelaunch",
    },
    "Show tools button on card": {
        "classification": "app-owned setting wording",
        "reference": "The setting corresponds to the official Mobile preference preferences-tools-overlay-button.",
        "evidence": "testStudyConfiguredTopBarActionAfterRelaunch",
    },
    "Show the tools icon over the card, or use the Tools action in the top bar.": {
        "classification": "app-owned helper copy",
        "reference": "This explains the official Tools Overlay Button option and the top-bar action in the AnkiOS layout.",
        "evidence": "testStudyConfiguredTopBarActionAfterRelaunch",
    },
    "Allow AnkiOS notifications in Settings to receive reminders.": {
        "classification": "app-owned permission guidance",
        "reference": "The copy is tailored to the AnkiOS notification permission and does not have an identical Mobile Fluent message.",
        "evidence": "testStudyReminderSettingsPersistAfterRelaunch",
    },
    "Move to the left": {
        "classification": "setting wording variant",
        "reference": "The option corresponds to preferences-tools-overlay-position with the preferences-left value.",
        "evidence": "testStudyConfiguredTopBarActionAfterRelaunch",
    },
    "Receive a daily reminder with the number of cards due.": {
        "classification": "app-owned helper copy",
        "reference": "This describes the local AnkiOS reminder behavior; no identical Mobile Fluent helper exists.",
        "evidence": "testStudyReminderSettingsPersistAfterRelaunch",
    },
    "Select Notes": {
        "classification": "browser action label",
        "reference": "The matching Desktop label is qt-accel-select-notes; Mobile has no identical menu label.",
        "evidence": "testBrowserBulkMarkBuryAndFlagAndUndo",
    },
    "day": {
        "classification": "app-owned compact chart unit",
        "reference": "StatsHomeView uses this standalone label for the one-day chart bucket; upstream statistics FTL exposes interval messages, not this standalone value.",
        "evidence": "testStatisticsPeriodsAndScope",
    },
}


def parse_messages(path):
    content = path.read_text(encoding="utf-8")
    messages = {}
    for match in MESSAGE_PATTERN.finditer(content):
        key, body = match.groups()
        lines = body.splitlines()
        continuations = [line for line in lines[1:] if line.strip() and not line.lstrip().startswith(".")]
        if continuations:
            continue
        value = lines[0].strip() if lines else ""
        if value:
            messages[key] = value
    return messages


def fluent_variants(path, message):
    if not path.exists():
        return None
    lines = path.read_text(encoding="utf-8").splitlines()
    start = next((index for index, line in enumerate(lines) if re.match(rf"^{re.escape(message)}\s*=", line)), None)
    if start is None:
        return None

    first_line = re.sub(rf"^{re.escape(message)}\s*=\s*", "", lines[start])
    body = [first_line]
    for line in lines[start + 1:]:
        if re.match(r"^[A-Za-z0-9_-]+\s*=", line):
            break
        body.append(line)

    variants = {}
    default = None
    for line in body:
        match = re.match(r"^\s*(\*)?\[([A-Za-z0-9_-]+)\]\s*(.*?)\s*$", line)
        if match:
            is_default, category, value = match.groups()
            variants[category] = value
            if is_default:
                default = category

    if variants:
        default = default or "other"
        return {"variants": variants, "default": default}

    static = " ".join(part.strip() for part in body if part.strip())
    if static.startswith("{") or not static:
        raise ValueError(f"Não foi possível interpretar a mensagem FTL {message} em {path}")
    return {"static": static}


def resolved_plural_values(record):
    if "static" in record:
        return {category: record["static"] for category in PLURAL_CATEGORIES}
    fallback = record["variants"].get(record["default"])
    if fallback is None:
        raise ValueError("Mensagem plural FTL sem variante padrão")
    return {
        category: record["variants"].get(category, fallback)
        for category in PLURAL_CATEGORIES
    }


def plural_localizations(strings, source_language, mobile_root, core_root):
    roots = {"mobile": mobile_root, "core": core_root}
    existing_locales = {
        locale
        for entry in strings.values()
        for locale in entry.get("localizations", {})
    }
    result = {}
    for locale in sorted(existing_locales | {source_language, "en-US", "en-GB"}):
        official_locale = next((ftl for catalog_locale, ftl in OFFICIAL_LOCALES if catalog_locale == locale), None)
        for key, filename, message, singular_key, plural_key in PLURAL_CONTEXT_STRINGS:
            root = core_root
            english_source = fluent_variants(root / "templates" / filename, message)
            if english_source is None:
                raise ValueError(f"Mensagem plural sem template FTL: {message}")

            record = None
            if locale in ("en-US", "en-GB"):
                record = english_source
            elif official_locale:
                record = fluent_variants(root / official_locale / filename, message)
            elif locale == source_language:
                source_identifier = locale.replace("-", "_")
                record = fluent_variants(root / source_identifier / filename, message)

            if record is None:
                if locale not in ("en-US", "en-GB") and locale not in {item[0] for item in OFFICIAL_LOCALES}:
                    existing_variants = (
                        strings.get(key, {})
                        .get("localizations", {})
                        .get(locale, {})
                        .get("variations", {})
                        .get("plural", {})
                    )
                    existing_values = {
                        category: existing_variants.get(category, {}).get("stringUnit", {}).get("value", "")
                        for category in PLURAL_CATEGORIES
                    }
                    if all(value.startswith(f"%lld{PLURAL_MARKER}") for value in existing_values.values()):
                        record_values = {
                            category: value.removeprefix(f"%lld{PLURAL_MARKER}")
                            for category, value in existing_values.items()
                        }
                    else:
                        singular = current_value(
                            singular_key,
                            strings.get(singular_key, {}),
                            locale,
                            source_language,
                        )
                        plural = current_value(
                            plural_key,
                            strings.get(plural_key, {}),
                            locale,
                            source_language,
                        )
                        record_values = {
                            category: (singular if category == "one" else plural)
                            or resolved_plural_values(english_source)[category]
                            for category in PLURAL_CATEGORIES
                        }
                else:
                    record_values = resolved_plural_values(english_source)
            else:
                record_values = resolved_plural_values(record)

            result.setdefault(key, {})[locale] = {
                "variations": {
                    "plural": {
                        category: {
                            "stringUnit": {
                                "state": "translated",
                                "value": f"%lld{PLURAL_MARKER}{record_values[category]}",
                            }
                        }
                        for category in PLURAL_CATEGORIES
                    }
                }
            }
    return result


def normalized_fluent_value(value):
    normalized = FLUENT_VARIABLE_PATTERN.sub("%@", value)
    if "{" in normalized or "}" in normalized:
        return None
    return normalized


def load_source_messages(root):
    by_english = defaultdict(list)
    for template in (root / "templates").glob("*.ftl"):
        for key, value in parse_messages(template).items():
            normalized = normalized_fluent_value(value)
            if normalized is not None:
                by_english[normalized].append((template.name, key))
    return by_english


def load_locale_messages(root, cache):
    cache_key = str(root.resolve())
    if cache_key not in cache:
        messages = {}
        for source in root.glob("*.ftl"):
            messages.update(parse_messages(source))
        cache[cache_key] = messages
    return cache[cache_key]


def current_value(key, entry, locale, source_language):
    unit = entry.get("localizations", {}).get(locale, {}).get("stringUnit", {})
    value = unit.get("value")
    if value is not None:
        return value
    if locale == source_language:
        return key
    return None


def upstream_values(references, roots, ftl_locale, caches):
    translations = set()
    for root, filename, message in references:
        root_index = roots.index(root)
        messages = load_locale_messages(root / ftl_locale, caches[root_index])
        value = messages.get(message)
        normalized = normalized_fluent_value(value) if value else None
        if normalized is not None:
            translations.add(normalized)
    return translations


def upstream_dynamic_count(references, roots, ftl_locale, caches):
    dynamic = 0
    for root, filename, message in references:
        root_index = roots.index(root)
        messages = load_locale_messages(root / ftl_locale, caches[root_index])
        value = messages.get(message)
        if value and "{" in value:
            dynamic += 1
    return dynamic


def context_references(key, entry, references, source_language, roots, caches):
    override = CONTEXT_OVERRIDES.get(key)
    if override:
        root_name, filename, message = override
        matching = [
            reference for reference in references
            if reference[0].name == root_name and reference[1:] == (filename, message)
        ]
        return (matching, True) if len(matching) == 1 else (references, False)

    source_value = current_value(key, entry, source_language, source_language)
    matching = []
    for root, filename, message in references:
        root_index = roots.index(root)
        source_messages = load_locale_messages(root / source_language, caches[root_index])
        template_value = source_messages.get(message)
        if template_value is not None and normalized_fluent_value(template_value) == source_value:
            matching.append((root, filename, message))
    return (matching, True) if len(matching) == 1 else (references, False)


def revision(path):
    try:
        return subprocess.check_output(
            ["git", "-C", str(path), "rev-parse", "HEAD"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--mobile-root", type=Path, required=True)
    parser.add_argument("--core-root", type=Path, required=True)
    parser.add_argument("--json-output", type=Path)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--add-contextual-strings", action="store_true")
    args = parser.parse_args()

    catalog = json.loads(args.catalog.read_text(encoding="utf-8"))
    source_language = catalog.get("sourceLanguage", "")
    strings = catalog.get("strings", {})
    roots = [args.mobile_root, args.core_root]
    added_contexts = 0
    if args.add_contextual_strings:
        root_by_name = {root.name: root for root in roots}
        existing_locales = {
            locale
            for entry in strings.values()
            for locale in entry.get("localizations", {})
        }
        for key, english, source_value, root_name, filename, message in CONTEXT_STRINGS:
            root = root_by_name[root_name]
            upstream_source_value = parse_messages(root / source_language / filename).get(message)
            template_value = parse_messages(root / "templates" / filename).get(message)
            if upstream_source_value is not None:
                upstream_source_value = normalized_fluent_value(upstream_source_value)
            if template_value is not None:
                template_value = normalized_fluent_value(template_value)
            if upstream_source_value != source_value or template_value != english:
                raise ValueError(f"Mensagem FTL inesperada para {key}: {template_value!r} / {upstream_source_value!r}")

            localizations = {
                "en-US": {"stringUnit": {"state": "translated", "value": english}}
            }
            if source_value != key:
                localizations[source_language] = {"stringUnit": {"state": "translated", "value": source_value}}
            for locale, ftl_locale in OFFICIAL_LOCALES:
                locale_file = root / ftl_locale / filename
                value = parse_messages(locale_file).get(message) if locale_file.exists() else None
                if value:
                    value = normalized_fluent_value(value)
                if value is not None:
                    localizations[locale] = {"stringUnit": {"state": "translated", "value": value}}
            for locale in existing_locales:
                localizations.setdefault(locale, {"stringUnit": {"state": "translated", "value": english}})
            if strings.get(key, {}).get("localizations") != localizations:
                strings[key] = {"localizations": localizations}
                added_contexts += 1
        added_app_owned_strings = 0
        for key, english, source_value in APP_OWNED_STRINGS:
            localizations = {
                "en-US": {"stringUnit": {"state": "translated", "value": english}},
                source_language: {"stringUnit": {"state": "translated", "value": source_value}},
            }
            for locale in existing_locales:
                localizations.setdefault(locale, {"stringUnit": {"state": "translated", "value": english}})
            if strings.get(key, {}).get("localizations") != localizations:
                strings[key] = {"localizations": localizations}
                added_app_owned_strings += 1
        generated_plural_strings = plural_localizations(
            strings,
            source_language,
            args.mobile_root,
            args.core_root,
        )
        added_plural_contexts = 0
        for key, localizations in generated_plural_strings.items():
            if strings.get(key, {}).get("localizations") != localizations:
                strings[key] = {"localizations": localizations}
                added_plural_contexts += 1
        catalog["strings"] = strings
        args.catalog.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    else:
        added_plural_contexts = 0

    plural_comparisons = []
    for key, filename, message, _, _ in PLURAL_CONTEXT_STRINGS:
        entry = strings.get(key, {})
        locale_results = []
        for locale, ftl_locale in OFFICIAL_LOCALES:
            expected_record = fluent_variants(args.core_root / ftl_locale / filename, message)
            if expected_record is None:
                expected_record = fluent_variants(args.core_root / "templates" / filename, message)
            expected = resolved_plural_values(expected_record)
            localization = entry.get("localizations", {}).get(locale, {})
            actual_variants = localization.get("variations", {}).get("plural", {})
            actual = {
                category: actual_variants.get(category, {}).get("stringUnit", {}).get("value", "")
                .removeprefix(f"%lld{PLURAL_MARKER}")
                for category in PLURAL_CATEGORIES
            }
            equal = sum(actual[category] == expected[category] for category in PLURAL_CATEGORIES)
            different = len(PLURAL_CATEGORIES) - equal
            locale_results.append({"locale": locale, "equalCategories": equal, "differentCategories": different})
        plural_comparisons.append({
            "key": key,
            "message": message,
            "equalCategories": sum(row["equalCategories"] for row in locale_results),
            "plannedCategories": len(PLURAL_CATEGORIES) * len(locale_results),
            "differentCategories": sum(row["differentCategories"] for row in locale_results),
            "locales": locale_results,
        })

    english_entries = []
    for key, entry in strings.items():
        english = entry.get("localizations", {}).get("en-US", {}).get("stringUnit", {}).get("value")
        if english:
            english_entries.append((key, entry, english))

    source_maps = [load_source_messages(root) for root in roots]
    matches = []
    for key, entry, english in english_entries:
        references = []
        for root, source_map in zip(roots, source_maps):
            references.extend((root, filename, message) for filename, message in source_map.get(english, []))
        if references:
            matches.append((key, entry, references))

    source_caches = [{}, {}]
    selected_references = {}
    context_resolved_entries = 0
    unresolved_context_messages = []
    for key, entry, references in matches:
        selected, resolved = context_references(
            key, entry, references, source_language, roots, source_caches
        )
        selected_references[key] = selected
        context_resolved_entries += int(resolved)
        if not resolved:
            english = entry.get("localizations", {}).get("en-US", {}).get("stringUnit", {}).get("value")
            unresolved_context_messages.append({
                "sourceKey": key,
                "english": english,
                "sourceValue": current_value(key, entry, source_language, source_language),
                "ftlReferences": sorted({f"{filename}:{message}" for _, filename, message in references}),
            })

    matched_keys = {key for key, _, _ in matches}
    unmapped_english_labels = [
        {"sourceKey": key, "english": english}
        for key, entry, english in english_entries
        if key not in matched_keys
    ]
    for label in unmapped_english_labels:
        label.update(UNMAPPED_CLASSIFICATIONS.get(label["english"], {}))

    import_counts = {}
    fallback_import_counts = {}
    if args.apply:
        caches = [{}, {}]
        for locale, ftl_locale in OFFICIAL_LOCALES:
            imported = 0
            fallback_imported = 0
            for key, entry, references in matches:
                selected = selected_references[key]
                translations = upstream_values(selected, roots, ftl_locale, caches)
                if len(translations) == 1:
                    value = next(iter(translations))
                elif not translations and len(selected) == 1 and upstream_dynamic_count(selected, roots, ftl_locale, caches) == 0:
                    value = entry.get("localizations", {}).get("en-US", {}).get("stringUnit", {}).get("value")
                    if not value:
                        continue
                    fallback_imported += 1
                else:
                    continue
                current = current_value(key, entry, locale, source_language)
                if current == value:
                    if not translations:
                        fallback_imported -= 1
                    continue
                entry.setdefault("localizations", {})[locale] = {
                    "stringUnit": {"state": "translated", "value": value}
                }
                if translations:
                    imported += 1
            import_counts[locale] = imported
            fallback_import_counts[locale] = fallback_imported
        args.catalog.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    catalog_locales = sorted({
        locale
        for entry in strings.values()
        for locale in entry.get("localizations", {})
    })
    results = []
    print("locale | iguais | diferentes | sem tradução | FTL ambíguo | sem valor upstream | FTL dinâmico | fallback igual | fallback difere")
    print("--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---:")

    for locale, ftl_locale in OFFICIAL_LOCALES:
        caches = [{}, {}]
        equal = different = missing = ambiguous = upstream_missing = upstream_dynamic = 0
        fallback_equal = fallback_different = 0
        for key, entry, references in matches:
            selected = selected_references[key]
            translations = upstream_values(selected, roots, ftl_locale, caches)
            if not translations:
                if upstream_dynamic_count(selected, roots, ftl_locale, caches):
                    upstream_dynamic += 1
                else:
                    upstream_missing += 1
                    if len(selected) == 1:
                        current = current_value(key, entry, locale, source_language)
                        english = entry.get("localizations", {}).get("en-US", {}).get("stringUnit", {}).get("value")
                        if current == english:
                            fallback_equal += 1
                        else:
                            fallback_different += 1
                continue
            if len(translations) > 1:
                ambiguous += 1
                continue
            current = current_value(key, entry, locale, source_language)
            if current is None:
                missing += 1
            elif current == next(iter(translations)):
                equal += 1
            else:
                different += 1
        result = {
            "locale": locale,
            "catalogLocalePresent": locale in catalog_locales,
            "equal": equal,
            "different": different,
            "missingTranslation": missing,
            "ambiguousUpstream": ambiguous,
            "upstreamMissing": upstream_missing,
            "upstreamDynamic": upstream_dynamic,
            "englishFallbackEqual": fallback_equal,
            "englishFallbackDifferent": fallback_different,
            "directMappings": len(matches),
        }
        results.append(result)
        print(f"{locale} | {equal} | {different} | {missing} | {ambiguous} | {upstream_missing} | {upstream_dynamic} | {fallback_equal} | {fallback_different}")

    report = {
        "generatedAt": date.today().isoformat(),
        "catalogKeys": len(strings),
        "englishMessages": len(english_entries),
        "directMappings": len(matches),
        "contextResolvedCatalogEntries": context_resolved_entries,
        "contextUnresolvedCatalogEntries": len(matches) - context_resolved_entries,
        "unresolvedContextMessages": unresolved_context_messages,
        "unmappedEnglishLabels": unmapped_english_labels,
        "unmappedEnglishMessages": len(english_entries) - len(matches),
        "classifiedUnmappedEnglishMessages": sum("classification" in label for label in unmapped_english_labels),
        "unclassifiedUnmappedEnglishLabels": [label for label in unmapped_english_labels if "classification" not in label],
        "catalogLocales": catalog_locales,
        "officialNonEnglishLocales": len(OFFICIAL_LOCALES),
        "officialLocalesPresent": sum(row["catalogLocalePresent"] for row in results),
        "importedByLocale": import_counts,
        "englishFallbacksImportedByLocale": fallback_import_counts,
        "mobileRevision": revision(args.mobile_root.parent),
        "coreRevision": revision(args.core_root.parent),
        "preferenceContextStringsAdded": added_contexts,
        "pluralContextStringsAdded": added_plural_contexts,
        "pluralContextComparisons": plural_comparisons,
        "contextOverrides": CONTEXT_OVERRIDES,
        "unambiguousComparisonTotals": {
            "equal": sum(row["equal"] for row in results if row["catalogLocalePresent"]),
            "different": sum(row["different"] for row in results if row["catalogLocalePresent"]),
            "missingTranslation": sum(row["missingTranslation"] for row in results if row["catalogLocalePresent"]),
            "ambiguousUpstream": sum(row["ambiguousUpstream"] for row in results if row["catalogLocalePresent"]),
            "upstreamMissing": sum(row["upstreamMissing"] for row in results if row["catalogLocalePresent"]),
            "upstreamDynamic": sum(row["upstreamDynamic"] for row in results if row["catalogLocalePresent"]),
            "englishFallbackEqual": sum(row["englishFallbackEqual"] for row in results if row["catalogLocalePresent"]),
            "englishFallbackDifferent": sum(row["englishFallbackDifferent"] for row in results if row["catalogLocalePresent"]),
        },
        "comparison": results,
    }
    if args.json_output:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print(f"Localizações no catálogo: {len(strings)}; mensagens en-US: {len(english_entries)}")
    print(f"Correspondência exata com FTL Mobile/Core: {len(matches)}/{len(english_entries)}; sem correspondência direta: {len(english_entries) - len(matches)}")
    print(f"Contextos resolvidos pelo texto-fonte: {context_resolved_entries}/{len(matches)} mensagens mapeadas")
    if args.add_contextual_strings:
        print(f"Chaves com contexto explícito adicionadas/atualizadas: {added_contexts}")
        print(f"Chaves próprias com fallback localizado adicionadas/atualizadas: {added_app_owned_strings}")
        print(f"Chaves plurais com formas FTL explícitas adicionadas/atualizadas: {added_plural_contexts}")
    plural_equal = sum(row["equalCategories"] for row in plural_comparisons)
    plural_planned = sum(row["plannedCategories"] for row in plural_comparisons)
    plural_different = sum(row["differentCategories"] for row in plural_comparisons)
    print(f"Formas plurais oficiais: {plural_equal}/{plural_planned} categorias idênticas em {len(PLURAL_CONTEXT_STRINGS)} mensagens; {plural_different} diferenças.")
    print(f"Idiomas não ingleses oficiais presentes no catálogo: {report['officialLocalesPresent']}/{report['officialNonEnglishLocales']}")
    if args.apply:
        print(f"Traduções oficializadas: {sum(import_counts.values())} entradas; somente correspondências estáticas não ambíguas.")
        print(f"Fallbacks para inglês importados: {sum(fallback_import_counts.values())} casos sem tradução upstream com contexto único.")
    if args.json_output:
        print(f"Relatório salvo em {args.json_output}")


if __name__ == "__main__":
    main()
