from pathlib import Path
import tempfile

from anki.collection import Collection
from anki.lang import set_lang


destination = Path(__file__).resolve().parent / "Fixtures" / "restore.colpkg"
destination.parent.mkdir(exist_ok=True)
set_lang("en")

with tempfile.TemporaryDirectory() as temporary:
    collection = Collection(f"{temporary}/collection.anki2")
    deck_id = collection.decks.id("UI Restore")
    note = collection.new_note(collection.models.by_name("Basic"))
    note.fields = ["UI restored collection", "UI restored package content"]
    collection.add_note(note, deck_id)
    collection.export_collection_package(
        out_path=str(destination),
        include_media=True,
        legacy=False,
    )
