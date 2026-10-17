from pathlib import Path
import shutil
import tempfile

from anki.collection import Collection, ExportAnkiPackageOptions
from anki.lang import set_lang
from anki.media import media_paths_from_col_path


root = Path(__file__).resolve().parents[2]
destination = Path(__file__).resolve().parent / "Fixtures"
destination.mkdir(exist_ok=True)
set_lang("en")
with tempfile.TemporaryDirectory() as temporary:
    collection_path = str(Path(temporary) / "collection.anki2")
    collection = Collection(collection_path)
    deck = collection.decks.id("UI Imported")
    note = collection.new_note(collection.models.by_name("Basic"))
    note.fields = ["UI imported question", 'UI imported answer <img src="ui-image.png">']
    collection.add_note(note, deck)
    media, _ = media_paths_from_col_path(collection_path)
    Path(media).mkdir(exist_ok=True)
    shutil.copy(root / "AnkiOS/Assets.xcassets/AppIcon.appiconset/AppIcon-32.png", Path(media) / "ui-image.png")
    collection.export_anki_package(
        out_path=str(destination / "official.apkg"),
        options=ExportAnkiPackageOptions(
            with_scheduling=True, with_deck_configs=True, with_media=True, legacy=False,
        ),
        limit=None,
    )
    collection.close()
