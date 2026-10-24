from hashlib import sha1
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time
import uuid
import zipfile


root = Path(__file__).resolve().parents[2]
source = root / "Tools/UITests/Fixtures/official.apkg"
destination = root / "Tools/UITests/Fixtures/study-flags.apkg"
destination.parent.mkdir(exist_ok=True)

with zipfile.ZipFile(source) as archive:
    files = {name: archive.read(name) for name in archive.namelist()}

with tempfile.TemporaryDirectory() as temporary:
    database_path = Path(temporary) / "collection.anki21"
    compressed_path = Path(temporary) / "collection.anki21b"
    subprocess.run(
        ["zstd", "-q", "-d", "-c"],
        input=files["collection.anki21b"],
        stdout=database_path.open("wb"),
        check=True,
    )

    connection = sqlite3.connect(database_path)
    connection.create_collation("unicase", lambda first, second: (first.casefold() > second.casefold()) - (first.casefold() < second.casefold()))
    connection.execute("update decks set name = ? where name = ?", ("UI Study Flags", "UI Imported"))
    note = connection.execute("select * from notes limit 1").fetchone()
    card = connection.execute("select * from cards limit 1").fetchone()
    connection.execute("delete from cards")
    connection.execute("delete from notes")
    note_columns = [column[1] for column in connection.execute("pragma table_info(notes)")]
    card_columns = [column[1] for column in connection.execute("pragma table_info(cards)")]
    note_values = dict(zip(note_columns, note))
    card_values = dict(zip(card_columns, card))
    first_id = max(
        connection.execute("select coalesce(max(id), 0) from notes").fetchone()[0],
        connection.execute("select coalesce(max(id), 0) from cards").fetchone()[0],
    ) + 1000
    now = int(time.time())

    for index in range(1, 11):
        note_id = first_id + index * 10
        card_id = note_id + 1
        front = f"M{index}"
        note_values.update({
            "id": note_id,
            "guid": uuid.uuid4().hex[:10],
            "mod": now,
            "usn": -1,
            "tags": "",
            "flds": f"{front}\x1fanswer {index}",
            "sfld": front,
            "csum": int(sha1(front.encode()).hexdigest()[:8], 16),
            "flags": 0,
            "data": "",
        })
        card_values.update({
            "id": card_id,
            "nid": note_id,
            "mod": now,
            "usn": -1,
            "type": 0,
            "queue": 0,
            "due": 100 + index,
            "ivl": 0,
            "factor": 0,
            "reps": 0,
            "lapses": 0,
            "left": 0,
            "odue": 0,
            "odid": 0,
            "flags": 0,
            "data": "{}",
        })
        connection.execute(
            f"insert into notes ({','.join(note_columns)}) values ({','.join('?' for _ in note_columns)})",
            [note_values[column] for column in note_columns],
        )
        connection.execute(
            f"insert into cards ({','.join(card_columns)}) values ({','.join('?' for _ in card_columns)})",
            [card_values[column] for column in card_columns],
        )

    connection.commit()
    connection.close()
    with compressed_path.open("wb") as output:
        subprocess.run(["zstd", "-q", "-c", str(database_path)], stdout=output, check=True)
    files["collection.anki21b"] = compressed_path.read_bytes()

with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for name, data in files.items():
        archive.writestr(name, data)
