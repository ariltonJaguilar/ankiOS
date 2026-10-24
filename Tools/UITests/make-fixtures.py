from pathlib import Path
import math
import random
import shutil
import struct
import tempfile
import time
import wave
import zlib

from anki.collection import Collection, DeckIdLimit, ExportAnkiPackageOptions
from anki.lang import set_lang
from anki.media import media_paths_from_col_path


root = Path(__file__).resolve().parents[2]
destination = Path(__file__).resolve().parent / "Fixtures"
destination.mkdir(exist_ok=True)
set_lang("en")


def sync_cancel_image(dominant_channel):
    width = 512
    height = 512
    image_random = random.Random(18_406 + dominant_channel)
    rows = bytearray()
    for _ in range(height):
        rows.append(0)
        for _ in range(width):
            pixel = [image_random.randrange(24) for _ in range(3)]
            pixel[dominant_channel] = 255
            rows.extend(pixel)

    def chunk(name, data):
        return struct.pack(">I", len(data)) + name + data + struct.pack(">I", zlib.crc32(name + data) & 0xffffffff)

    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows, 0)) + chunk(b"IEND", b"")


with tempfile.TemporaryDirectory() as temporary:
    collection_path = str(Path(temporary) / "collection.anki2")
    collection = Collection(collection_path)
    deck = collection.decks.id("UI Imported")
    note = collection.new_note(collection.models.by_name("Basic"))
    note.fields = ["UI imported question", 'UI imported answer <img src="ui-image.png"><br>[sound:ui-tone.wav]<br><img src="sync-cancel.png">']
    collection.add_note(note, deck)
    media, _ = media_paths_from_col_path(collection_path)
    Path(media).mkdir(exist_ok=True)
    shutil.copy(root / "AnkiOS/Assets.xcassets/AppIcon.appiconset/AppIcon-32.png", Path(media) / "ui-image.png")
    image_path = Path(media) / "sync-cancel.png"
    image_path.write_bytes(sync_cancel_image(0))
    with wave.open(str(Path(media) / "ui-tone.wav"), "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(8_000)
        frames = (
            struct.pack("<h", int(8_000 * math.sin(2 * math.pi * 440 * sample / 8_000)))
            for sample in range(8_000 * 30)
        )
        audio.writeframes(b"".join(frames))
    export_options = ExportAnkiPackageOptions(
        with_scheduling=True, with_deck_configs=True, with_media=True, legacy=False,
    )
    collection.export_anki_package(
        out_path=str(destination / "official.apkg"),
        options=export_options,
        limit=None,
    )
    image_path.write_bytes(sync_cancel_image(2))
    collection.export_anki_package(
        out_path=str(destination / "official-conflict.apkg"),
        options=export_options,
        limit=None,
    )

    occlusion_model = collection.models.new("Image Occlusion")
    occlusion_model["type"] = 1
    for field_name in ["Occlusion", "Image", "Header", "Back Extra", "Comments"]:
        collection.models.add_field(occlusion_model, collection.models.new_field(field_name))
    occlusion_template = collection.models.new_template("Image Occlusion")
    occlusion_template["qfmt"] = "{{#Header}}<div>{{Header}}</div>{{/Header}}{{cloze:Occlusion}}{{Image}}"
    occlusion_template["afmt"] = "{{#Header}}<div>{{Header}}</div>{{/Header}}{{cloze:Occlusion}}{{Image}}<hr id=answer>{{#Back Extra}}<div>{{Back Extra}}</div>{{/Back Extra}}"
    collection.models.add_template(occlusion_model, occlusion_template)
    collection.models.add(occlusion_model)
    occlusion_note = collection.new_note(occlusion_model)
    occlusion_note.fields = [
        "{{c1::image-occlusion:rect:left=0.3000:top=0.3000:width=0.4000:height=0.4000:oi=1}}",
        '<img src="occlusion.png">',
        "UI occlusion header",
        "UI occlusion answer",
        "",
    ]
    collection.add_note(occlusion_note, collection.decks.id("UI Occlusion"))
    media, _ = media_paths_from_col_path(collection_path)
    Path(media, "occlusion.png").write_bytes(sync_cancel_image(2))
    collection.export_anki_package(
        out_path=str(destination / "occlusion.apkg"),
        options=export_options,
        limit=None,
    )

    optimizer_deck = collection.decks.id("UI FSRS Optimizer")
    optimizer_card_ids = []
    for index in range(4):
        optimizer_note = collection.new_note(collection.models.by_name("Basic"))
        optimizer_note.fields = [f"FSRS optimizer question {index + 1}", f"FSRS optimizer answer {index + 1}"]
        collection.add_note(optimizer_note, optimizer_deck)
        optimizer_card_ids.extend(card.id for card in optimizer_note.cards())

    now_ms = int(time.time() * 1000)
    for card_index, card_id in enumerate(optimizer_card_ids):
        previous_interval = 0
        for review_index, ease in enumerate([3, 4, 3, 2, 3, 4, 3, 3, 2, 4, 3]):
            review_id = now_ms - (30 - review_index * 2) * 86_400_000 + card_index * 1000
            interval = max(1, (review_index + 1) * 2)
            collection.db.execute(
                "insert into revlog values(?,?,?,?,?,?,?,?,?)",
                review_id,
                card_id,
                -1,
                ease,
                interval,
                previous_interval,
                2500,
                6000,
                0 if review_index == 0 else 1,
            )
            previous_interval = interval

    collection.export_anki_package(
        out_path=str(destination / "fsrs-optimizer.apkg"),
        options=export_options,
        limit=DeckIdLimit(optimizer_deck),
    )

    stats_deck = collection.decks.id("UI Stats Review Types")
    stats_reviews = [(0, 3, 1, 0), (1, 3, 21, 20), (1, 3, 30, 21), (2, 3, 1, 10), (3, 3, 0, 0)]
    now_ms = int(time.time() * 1000) - 60_000
    for index, review in enumerate(stats_reviews):
        note = collection.new_note(collection.models.by_name("Basic"))
        note.fields = [f"Stats review question {index + 1}", f"Stats review answer {index + 1}"]
        collection.add_note(note, stats_deck)
        card_id = note.cards()[0].id
        review_type, ease, interval, previous_interval = review
        collection.db.execute(
            "insert into revlog values(?,?,?,?,?,?,?,?,?)",
            now_ms + index * 1000,
            card_id,
            -1,
            ease,
            interval,
            previous_interval,
            2500,
            6000,
            review_type,
        )

    collection.export_anki_package(
        out_path=str(destination / "stats-review-types.apkg"),
        options=export_options,
        limit=DeckIdLimit(stats_deck),
    )
    collection.close()
