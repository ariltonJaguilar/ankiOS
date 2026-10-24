from pathlib import Path
import tempfile

from anki.collection import Collection, ExportAnkiPackageOptions
from anki.lang import set_lang


destination = Path(__file__).resolve().parent / "Fixtures" / "typed-answer.apkg"
destination.parent.mkdir(exist_ok=True)
set_lang("en")

with tempfile.TemporaryDirectory() as temporary:
    collection = Collection(f"{temporary}/collection.anki2")
    model = collection.models.by_name("Basic (type in the answer)")
    deck_id = collection.decks.id("UI Typed Answer")
    for front, back in [
        ("UI typed correct question", "Anki"),
        ("UI typed mismatch question", "Expected"),
    ]:
        note = collection.new_note(model)
        note.fields = [front, back]
        collection.add_note(note, deck_id)

    collection.export_anki_package(
        out_path=str(destination),
        options=ExportAnkiPackageOptions(
            with_scheduling=False,
            with_deck_configs=False,
            with_media=True,
            legacy=False,
        ),
        limit=None,
    )
    collection.close()
