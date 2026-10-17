#!/usr/bin/env python3
"""Differential parity checks: AnkiOS (ankios-harness) vs the official Anki library.

Usage: oracle.py <check> [--keep]
Checks: timing, counts, states, fsrs-empty-steps, session, search, retention, stats, cardgen, decks, delete, empty, queue, sync, tags, notetypes, latex, filtered, packages, csv, all

Requires the `anki` wheel matching the targeted desktop release (26.9.3) and the
harness built by build-harness.sh.
"""
import json
import hashlib
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time

from anki.collection import (
    Collection,
    ExportAnkiPackageOptions,
    ImportCsvRequest,
    ImportAnkiPackageOptions,
    ImportAnkiPackageRequest,
)
from anki.deck_config_pb2 import UpdateDeckConfigsMode, UpdateDeckConfigsRequest
from anki.lang import set_lang
from anki.scheduler_pb2 import CardAnswer
from anki.stats import CollectionStats

HARNESS = os.environ.get("ANKIOS_HARNESS", "/tmp/ankios-parity/build/ankios-harness")
WORK = os.environ.get("ANKIOS_PARITY_WORK", "/tmp/ankios-parity/work")

RATINGS = [CardAnswer.AGAIN, CardAnswer.HARD, CardAnswer.GOOD, CardAnswer.EASY]


# --------------------------------------------------------------------------- fixtures

def _add_notes(col, deck_id, notetype, rows):
    model = col.models.by_name(notetype)
    ids = []
    for fields in rows:
        note = col.new_note(model)
        for i, value in enumerate(fields):
            note.fields[i] = value
        col.add_note(note, deck_id)
        ids.append(note.id)
    return ids


def _set_card(col, cid, **values):
    cols = ", ".join(f"{k}=?" for k in values)
    col.db.execute(f"update cards set {cols} where id=?", *values.values(), cid)


def build_sched_fixture(path):
    """Deck tree with two presets and cards in every scheduling state."""
    col = Collection(path)
    now = int(time.time())
    today = col.sched.today

    names = ["Lang", "Lang::JP", "Lang::JP::Kana", "Lang::ES", "Math"]
    dids = {name: col.decks.id(name) for name in names}

    intensive = col.decks.add_config_returning_id("Intensive")
    conf = col.decks.get_config(intensive)
    conf["new"]["delays"] = [1, 5, 30, 1440]
    conf["new"]["ints"] = [3, 5, 0]
    conf["new"]["initialFactor"] = 2300
    conf["new"]["perDay"] = 6
    conf["rev"]["perDay"] = 12
    conf["rev"]["ease4"] = 1.4
    conf["rev"]["ivlFct"] = 0.9
    conf["rev"]["maxIvl"] = 365
    conf["rev"]["hardFactor"] = 1.1
    conf["lapse"]["delays"] = [10, 1440]
    conf["lapse"]["mult"] = 0.2
    conf["lapse"]["minInt"] = 2
    conf["lapse"]["leechFails"] = 4
    col.decks.update_config(conf)
    for name in ["Lang::JP", "Lang::JP::Kana"]:
        deck = col.decks.get(dids[name])
        deck["conf"] = intensive
        col.decks.save(deck)

    default = col.decks.get_config(1)
    default["new"]["perDay"] = 9
    default["rev"]["perDay"] = 25
    col.decks.update_config(default)

    rows = lambda prefix, n: [[f"{prefix} front {i}", f"{prefix} back {i}"] for i in range(n)]
    for name, count in [("Lang", 6), ("Lang::JP", 14), ("Lang::JP::Kana", 18), ("Lang::ES", 16), ("Math", 12)]:
        _add_notes(col, dids[name], "Basic", rows(name, count))
    _add_notes(col, dids["Lang::ES"], "Basic (and reversed card)", rows("ES rev", 6))
    _add_notes(col, dids["Math"], "Cloze", [[f"{{{{c1::{i}}}}} + {{{{c2::{i + 1}}}}} = {{{{c3::{2 * i + 1}}}}}", ""] for i in range(4)])
    _add_notes(col, 1, "Basic", rows("Default", 5))

    states = [
        dict(type=2, queue=2, ivl=1, due=today, factor=2500, reps=3, lapses=0, left=0),
        dict(type=2, queue=2, ivl=3, due=today - 1, factor=2500, reps=4, lapses=0, left=0),
        dict(type=2, queue=2, ivl=10, due=today - 5, factor=2800, reps=6, lapses=1, left=0),
        dict(type=2, queue=2, ivl=45, due=today - 30, factor=1300, reps=9, lapses=5, left=0),
        dict(type=2, queue=2, ivl=200, due=today - 2, factor=2650, reps=12, lapses=0, left=0),
        dict(type=2, queue=2, ivl=20, due=today + 4, factor=2500, reps=5, lapses=0, left=0),
        dict(type=1, queue=1, ivl=0, due=now - 120, factor=0, reps=1, lapses=0, left=2),
        dict(type=1, queue=1, ivl=0, due=now + 300, factor=0, reps=2, lapses=0, left=1),
        dict(type=1, queue=1, ivl=0, due=now + 4000, factor=0, reps=1, lapses=0, left=3),
        dict(type=1, queue=3, ivl=0, due=today, factor=0, reps=3, lapses=0, left=1),
        dict(type=1, queue=3, ivl=0, due=today - 2, factor=0, reps=3, lapses=0, left=1),
        dict(type=3, queue=1, ivl=10, due=now - 30, factor=2300, reps=8, lapses=2, left=1),
        dict(type=3, queue=1, ivl=4, due=now + 600, factor=2100, reps=8, lapses=3, left=2),
        dict(type=3, queue=3, ivl=6, due=today, factor=2000, reps=9, lapses=3, left=1),
        dict(type=2, queue=-2, ivl=5, due=today, factor=2500, reps=3, lapses=0, left=0),
        dict(type=0, queue=-3, ivl=0, due=0, factor=0, reps=0, lapses=0, left=0),
        dict(type=2, queue=-1, ivl=8, due=today - 1, factor=2500, reps=3, lapses=0, left=0),
    ]
    for name in names + ["Default"]:
        did = 1 if name == "Default" else dids[name]
        cids = col.db.list("select id from cards where did=? order by id", did)
        # leave the first half new, give the rest the listed states (offset per deck)
        offset = names.index(name) if name in names else 0
        for i, cid in enumerate(cids[len(cids) // 3:]):
            state = dict(states[(i + offset) % len(states)])
            if state["type"] == 0:
                state["due"] = 1_000 + i
            _set_card(col, cid, **state)

    # some study already done today in a couple of decks
    for name, new_today, rev_today in [("Lang::JP", 2, 3), ("Lang::ES", 1, 0)]:
        deck = col.decks.get(dids[name])
        deck["newToday"] = [today, new_today]
        deck["revToday"] = [today, rev_today]
        col.decks.save(deck)

    first_note_id = col.db.scalar("select id from notes where mid=? order by id limit 1", col.models.by_name("Basic")["id"])
    note = col.get_note(first_note_id)
    note.fields[1] = "Über"
    note.tags = ["animal", "animal::mammal", "leech"]
    col.update_note(note)

    suspended = col.db.list("select id from cards where queue=-1 order by id")
    day_start = (col.sched.day_cutoff - 86_400) * 1000
    col.db.execute(
        "insert into revlog values(?,?,?,?,?,?,?,?,?)",
        day_start + 1, suspended[0], -1, 3, 1, 1, 2500, 5000, 2,
    )
    col.db.execute(
        "insert into revlog values(?,?,?,?,?,?,?,?,?)",
        day_start + 2, suspended[1], -1, 0, 0, 0, 0, 5000, 4,
    )
    retention_day = 86_400_000
    retention_rows = [
        (day_start + 100, suspended[0], -1, 1, 4, 20, 2300, 5000, 1),
        (day_start + 200, suspended[1], -1, 3, 30, 21, 2500, 5000, 1),
        (day_start + 300, suspended[0], -1, 4, -60, -86_400, 0, 5000, 0),
        (day_start + 400, suspended[1], -1, 4, -60, 0, 0, 5000, 0),
        (day_start + 500, suspended[0], -1, 3, 30, 30, 0, 5000, 3),
        (day_start + 600, suspended[1], -1, 2, 3, 20, 2300, 5000, 3),
        (day_start + 700, suspended[0], -1, 1, 1, 21, 2500, 5000, 2),
        (day_start - retention_day + 100, suspended[1], -1, 3, 4, 10, 2500, 5000, 1),
        (day_start - retention_day * 6 + 100, suspended[0], -1, 2, 4, 21, 2500, 5000, 1),
        (day_start - retention_day * 25 + 100, suspended[1], -1, 1, 4, 20, 2300, 5000, 1),
        (day_start - retention_day * 200 + 100, suspended[0], -1, 3, 40, 40, 2500, 5000, 1),
        (day_start - retention_day * 400 + 100, suspended[1], -1, 1, 2, 30, 2300, 5000, 1),
    ]
    col.db.executemany("insert into revlog values(?,?,?,?,?,?,?,?,?)", retention_rows)
    custom_card = col.get_card(col.db.scalar("select id from cards order by id limit 1"))
    custom_card.custom_data = '{"v":"reschedule","d":7}'
    col.update_card(custom_card)

    col.close(downgrade=True)


FIXTURES = {"sched": build_sched_fixture}


# --------------------------------------------------------------------------- oracle side

def oracle_timing(col):
    return {"days": col.sched.today, "nextDayAt": col.sched.day_cutoff}


def oracle_counts(col):
    out = {}

    def walk(node):
        if node.deck_id:
            out[str(node.deck_id)] = [node.new_count, node.learn_count, node.review_count]
        for child in node.children:
            walk(child)

    walk(col.sched.deck_due_tree())
    return out


def oracle_retention(col):
    stats = col._backend.graphs(search="", days=0).true_retention
    periods = [stats.today, stats.yesterday, stats.week, stats.month, stats.year, stats.all_time]
    return [
        {
            "youngPass": period.young_passed,
            "youngFail": period.young_failed,
            "maturePass": period.mature_passed,
            "matureFail": period.mature_failed,
        }
        for period in periods
    ]


def oracle_stats(col):
    stats = CollectionStats(col)
    stats.wholeCollection = True
    future_due = col._backend.graphs(search="", days=0).future_due
    today_start = (col.sched.day_cutoff - 86_400) * 1000
    today = col.db.first(
        """
        select count(), coalesce(sum(time), 0),
            sum(case when ease=1 then 1 else 0 end),
            sum(case when type=0 then 1 else 0 end),
            sum(case when type=1 then 1 else 0 end),
            sum(case when type=2 then 1 else 0 end),
            sum(case when type=3 then 1 else 0 end)
        from revlog where type != 4 and id > ?
        """,
        today_start,
    )
    mature = col.db.first(
        """
        select sum(case when ease=1 then 0 else 1 end), count()
        from revlog where lastIvl >= 21 and id > ?
        """,
        today_start,
    )

    def review_points(buckets, chunk_days, period_type):
        stats.type = period_type
        rows = stats._done(buckets, chunk_days)
        points = [
            {"offset": offset, "learn": 0, "young": 0, "mature": 0, "relearn": 0, "filtered": 0, "timeMS": 0}
            for offset in range(buckets)
        ]
        for row in rows:
            offset = -row[0]
            if not 0 <= offset < buckets:
                continue
            points[offset] = {
                "offset": offset,
                "learn": row[1] or 0,
                "young": row[2] or 0,
                "mature": row[3] or 0,
                "relearn": row[4] or 0,
                "filtered": row[5] or 0,
                "timeMS": round(sum(value or 0 for value in row[6:11]) * (60_000 if chunk_days == 1 and buckets == 31 else 3_600_000)),
            }
        return points

    review_month = review_points(31, 1, 0)
    review_year = review_points(52, 7, 1)
    stats.type = 0

    def added_points(buckets, chunk_days):
        points = {str(offset): 0 for offset in range(buckets)}
        for day, count in stats._added(buckets, chunk_days):
            offset = -day
            if str(offset) in points:
                points[str(offset)] += count
        return points

    month_buttons = [{"category": name, "again": 0, "hard": 0, "good": 0, "easy": 0}
                     for name in ["Aprender", "Jovem", "Maduro"]]
    for category, ease, count in stats._eases():
        if 1 <= ease <= 4:
            target = month_buttons[category]
            target[["again", "hard", "good", "easy"][ease - 1]] += count

    interval_rows, chunk_days = stats._ivls()
    interval_counts = interval_rows[0]
    interval_card_count, average_interval, longest_interval = interval_rows[1:]
    return {
        "today": {
            "reviews": today[0] or 0,
            "timeMS": today[1] or 0,
            "failed": today[2] or 0,
            "learning": today[3] or 0,
            "review": today[4] or 0,
            "relearning": today[5] or 0,
            "filtered": today[6] or 0,
            "matureCorrect": mature[0] or 0,
            "matureTotal": mature[1] or 0,
        },
        "collection": {
            "notes": col.db.scalar("select count(distinct nid) from cards"),
            "cards": col.db.scalar("select count() from cards"),
        },
        "reviewHistoryDays": stats._deckAge("review"),
        "reviewMonth": review_month,
        "reviewYear": review_year,
        "addedMonth": added_points(31, 1),
        "addedYear": added_points(52, 7),
        "dueMonth": {str(day): young + mature for day, young, mature in stats._due(0, 31, 1)},
        "futureDueForecast": {
            "dueByDay": {str(day): count for day, count in future_due.future_due.items()},
            "dailyLoad": future_due.daily_load,
            "hasBacklog": future_due.have_backlog,
        },
        "intervalMonth": {
            "points": [{"bucket": bucket, "count": count} for bucket, count in interval_counts],
            "averageDays": average_interval if average_interval is not None else -1,
            "longestDays": longest_interval if longest_interval is not None else -1,
            "totalCards": interval_card_count,
        },
        "buttonsMonth": month_buttons,
    }


def card_state(col, cid, now):
    row = col.db.first(
        "select type, queue, due, ivl, factor, reps, lapses, left, odue, odid, did from cards where id=?", cid
    )
    keys = ["type", "queue", "due", "ivl", "factor", "reps", "lapses", "left", "odue", "odid", "did"]
    state = dict(zip(keys, row))
    if state["queue"] in (1, 4):
        state["due"] -= now
    return state


SESSION_RATINGS = [CardAnswer.GOOD, CardAnswer.GOOD, CardAnswer.AGAIN, CardAnswer.HARD,
                   CardAnswer.EASY, CardAnswer.GOOD, CardAnswer.AGAIN, CardAnswer.GOOD,
                   CardAnswer.HARD, CardAnswer.GOOD]


def oracle_session(col, deck_name="Lang", limit=20):
    did = col.decks.id_for_name(deck_name)
    col.decks.set_current(did)
    steps = []
    for i in range(limit):
        queued = col.sched.get_queued_cards(fetch_limit=1)
        counts = [queued.new_count, queued.learning_count, queued.review_count]
        if not queued.cards:
            steps.append({"id": 0, "counts": counts, "rating": 0})
            break
        cid = queued.cards[0].card.id
        rating = SESSION_RATINGS[i % len(SESSION_RATINGS)]
        card = col.get_card(cid)
        card.start_timer()
        states = col._backend.get_scheduling_states(cid)
        col.sched.answer_card(col.sched.build_answer(card=card, states=states, rating=rating))
        steps.append({"id": cid, "counts": counts, "rating": rating + 1})
    queued = col.sched.get_queued_cards(fetch_limit=1)
    return {
        "deck": did,
        "steps": steps,
        "finalCounts": [queued.new_count, queued.learning_count, queued.review_count],
    }


def oracle_states(col, card_ids=None):
    out = {}
    card_ids = card_ids or col.db.list("select id from cards where queue >= 0 order by id")
    for cid in card_ids:
        states = col._backend.get_scheduling_states(cid)
        entry = {"labels": list(col.sched.describe_next_states(states))}
        for rating in RATINGS:
            card = col.get_card(cid)
            card.start_timer()
            answer = col.sched.build_answer(card=card, states=states, rating=rating)
            col.sched.answer_card(answer)
            now = int(time.time())
            state = card_state(col, cid, now)
            rev = col.db.first("select ivl, lastIvl, factor from revlog where cid=? order by id desc limit 1", cid)
            state["revlogIvl"], state["revlogLastIvl"], state["revlogFactor"] = rev
            entry[str(rating + 1)] = state
            col.undo()
        out[str(cid)] = entry
    return out


def grade_now_snapshot(col, card_ids):
    cards = []
    revlogs = []
    note_ids = set()
    for cid in card_ids:
        row = col.db.first(
            "select type, queue, due, ivl, factor, reps, lapses, left, odue, odid, did, flags, data from cards where id=?",
            cid,
        )
        if row is None:
            continue
        keys = ["type", "queue", "due", "ivl", "factor", "reps", "lapses", "left", "odue", "odid", "did", "flags", "data"]
        cards.append({"id": cid, **dict(zip(keys, row))})
        note_ids.add(col.db.scalar("select nid from cards where id=?", cid))
        rev = col.db.first(
            "select ease, ivl, lastIvl, factor, time, type from revlog where cid=? order by id desc limit 1",
            cid,
        )
        if rev:
            revlogs.append({"cid": cid, **dict(zip(["ease", "ivl", "lastIvl", "factor", "time", "type"], rev))})
    notes = []
    for nid in sorted(note_ids):
        tags = col.db.scalar("select tags from notes where id=?", nid)
        notes.append({"id": nid, "tags": tags})
    decks = []
    for deck in sorted(col.decks.all(), key=lambda item: item["id"]):
        decks.append({
            "id": deck["id"],
            "newToday": deck.get("newToday", [0, 0]),
            "revToday": deck.get("revToday", [0, 0]),
            "lrnToday": deck.get("lrnToday", [0, 0]),
            "timeToday": deck.get("timeToday", [0, 0]),
        })
    return {"cards": cards, "revlogs": revlogs, "notes": notes, "decks": decks}


def check_grade_now():
    oracle_path, swift_root = prepare("sched")
    col = Collection(oracle_path)
    started_at = int(time.time())
    try:
        siblings = col.db.first("""
            select c1.id, c2.id from cards c1
            join cards c2 on c2.nid=c1.nid and c2.id>c1.id
            where c1.queue>=0 and c2.queue>=0
            order by c1.id limit 1
        """)
        card_ids = list(siblings) if siblings else col.db.list(
            "select id from cards where queue>=0 order by id limit 2"
        )
        rating = CardAnswer.GOOD
        col._backend.grade_now(card_ids=card_ids, rating=rating)
        expected = {
            "after": grade_now_snapshot(col, card_ids),
        }
        col.undo()
        expected["undone"] = grade_now_snapshot(col, card_ids)
        col.redo()
        expected["redone"] = grade_now_snapshot(col, card_ids)
    finally:
        col.close()
    actual = run_harness(swift_root, "grade-now", ",".join(map(str, card_ids)), str(rating + 1))
    finished_at = int(time.time())
    for snapshot in (expected, actual):
        for phase in snapshot.values():
            for card in phase["cards"]:
                data = json.loads(card["data"] or "{}")
                if isinstance(data.get("lrt"), (int, float)) and started_at <= data["lrt"] <= finished_at:
                    data["lrt"] = "current-operation"
                card["data"] = json.dumps(data, sort_keys=True)
    return diff("sched:grade-now", expected, actual)


def check_fsrs_empty_steps():
    oracle_path, swift_root = prepare("sched")
    col = Collection(oracle_path)
    try:
        info = col.decks.get_deck_configs_for_update(1)
        configs = []
        for item in info.all_config:
            config = item.config
            if config.id == 1:
                del config.config.learn_steps[:]
                del config.config.relearn_steps[:]
                del config.config.fsrs_params_6[:]
                config.config.fsrs_params_6.extend([
                    0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194,
                    0.001, 1.8722, 0.1666, 0.796, 1.4835, 0.0614, 0.2629,
                    1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658, 0.1542,
                ])
            configs.append(config)
        col.decks.update_deck_configs(
            UpdateDeckConfigsRequest(
                target_deck_id=1,
                configs=configs,
                mode=UpdateDeckConfigsMode.UPDATE_DECK_CONFIGS_MODE_NORMAL,
                fsrs=True,
            )
        )
        card_ids = [
            col.db.scalar("select id from cards where did=1 and type=0 and queue=0 order by id limit 1"),
            col.db.scalar("select id from cards where did=1 and type=2 and queue=2 order by id limit 1"),
        ]
        expected = oracle_states(col, card_ids)
    finally:
        col.close()

    swift_path = os.path.join(swift_root, "User 1", "collection.anki2")
    db = sqlite3.connect(swift_path)
    try:
        conf, dconf = db.execute("select conf, dconf from col").fetchone()
        conf = json.loads(conf)
        dconf = json.loads(dconf)
        conf["fsrs"] = True
        default = dconf["1"]
        default["new"]["delays"] = []
        default["lapse"]["delays"] = []
        default["fsrsParams6"] = [
            0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194,
            0.001, 1.8722, 0.1666, 0.796, 1.4835, 0.0614, 0.2629,
            1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658, 0.1542,
        ]
        db.execute("update col set conf=?, dconf=?", (json.dumps(conf), json.dumps(dconf)))
        db.commit()
    finally:
        db.close()

    actual = run_harness(swift_root, "states", *map(str, card_ids))
    return diff("sched:fsrs-empty-steps", expected, actual)


# --------------------------------------------------------------------------- runner

def prepare(fixture):
    os.makedirs(WORK, exist_ok=True)
    base = os.path.join(WORK, f"{fixture}.anki2")
    if os.path.exists(base):
        os.remove(base)
    set_lang("en")
    FIXTURES[fixture](base)
    set_lang("pt_BR")
    oracle_path = os.path.join(WORK, f"{fixture}-oracle.anki2")
    shutil.copy(base, oracle_path)
    swift_root = os.path.join(WORK, f"{fixture}-swift")
    shutil.rmtree(swift_root, ignore_errors=True)
    os.makedirs(os.path.join(swift_root, "User 1"))
    shutil.copy(base, os.path.join(swift_root, "User 1", "collection.anki2"))
    return oracle_path, swift_root


def run_harness(root, *args):
    env = dict(os.environ, ANKIOS_PROFILES_ROOT=root)
    proc = subprocess.run([HARNESS, *args], capture_output=True, text=True, env=env)
    if proc.returncode != 0:
        raise SystemExit(f"harness {args} failed: {proc.stderr}")
    return json.loads(proc.stdout)


def diff(name, expected, actual, path=""):
    problems = []
    if isinstance(expected, dict) and isinstance(actual, dict):
        for key in sorted(set(expected) | set(actual)):
            if key not in actual:
                problems.append(f"{name}{path}/{key}: missing in AnkiOS (anki={expected[key]!r})")
            elif key not in expected:
                problems.append(f"{name}{path}/{key}: extra in AnkiOS ({actual[key]!r})")
            elif (key == "due" and expected.get("queue") in (1, 4)
                  and actual.get("queue") == expected["queue"]
                  and isinstance(expected[key], int) and isinstance(actual[key], int)
                  and abs(expected[key] - actual[key]) <= 2):
                continue
            else:
                problems += diff(name, expected[key], actual[key], f"{path}/{key}")
    elif isinstance(expected, list) and isinstance(actual, list):
        if len(expected) != len(actual):
            problems.append(f"{name}{path}: list length anki={len(expected)} ankios={len(actual)}")
        else:
            for i, (e, a) in enumerate(zip(expected, actual)):
                problems += diff(name, e, a, f"{path}[{i}]")
    elif expected != actual:
        comparable_timestamps = (
            isinstance(expected, int)
            and isinstance(actual, int)
            and expected > 1_000_000_000
            and actual > 1_000_000_000
            and abs(expected - actual) <= 2
        )
        if not (path.endswith("/mod") and comparable_timestamps):
            problems.append(f"{name}{path}: anki={expected!r} ankios={actual!r}")
    return problems


def search_queries(col):
    basic_id = col.models.by_name("Basic")["id"]
    note_id = col.db.scalar("select id from notes where mid=? order by id limit 1", basic_id)
    card_id = col.db.scalar("select id from cards where nid=? order by id limit 1", note_id)
    deck_id = col.decks.id("Lang")
    return [
        "Lang", "deck:Lang", "deck:Lang::JP", "deck:Math", "deck:filtered",
        "deck:current", 'deck:"Lang::JP"', "deck:Lang -deck:Lang::*", "preset:Default",
        "is:new", "is:learn", "is:review", "is:due", "is:suspended",
        "is:buried", "is:buried-sibling", "is:buried-manually",
        "flag:0", "prop:pos<=100", "prop:ivl>10", "prop:due>=0",
        "prop:due=-1", "prop:due>=1", "prop:due<=-1", "prop:reps>=3",
        "prop:lapses>=2", "prop:ease<2.5", "prop:rated=0", "prop:rated=-1",
        "prop:resched=0", "prop:cdn:d>5", "prop:cds:v=reschedule",
        "added:7", "edited:7", "introduced:7", "rated:1", "rated:1:3",
        "resched:1", "note:Basic", "card:1", "card:2", f"nid:{note_id}",
        f"cid:{card_id}", f"did:{deck_id}", f"mid:{basic_id}",
        "tag:none", "tag:leech", "tag:animal", "tag:animal::mammal",
        "tag:ani*", "tag:*", "tag:re:^animal$", 'Front:"Lang front 0"',
        "Front:Lang", "Front:lang", "Front:Lang*", "Front:_*", "Front:*",
        'Front:re:^Lang front 0$',
        'field:Front:"Lang front 0"', "Front:*front*", "w:Lang", "nc:Lang",
        'Missing:"Lang front 0"', 'F*:"Lang front 0"', '*:"Lang front 0"',
        "w:Lang*", "nc:uber", "sc:1", "re:Lang.*back", "sc:Lang",
        '"Lang front 0"', "Lang front 0", "-Lang", "Lang or Math",
        r"Link\:Target",
        "Lang (front or back)", "deck:Lang or deck:Math", "is:learn -is:review",
        "is:review -is:learn", "prop:s>1", "prop:d<5", "prop:r<0.9",
        "has-cd:v", f'has-cd:v nid:{note_id}', f'dupe:{basic_id},"Lang front 0"',
        "Front:Exact", "Front:*Exact*", "Front:Trim", "Front:*Trim*",
    ]


def prepare_field_search_cases(col, swift_root):
    basic_id = col.models.by_name("Basic")["id"]
    note_ids = col.db.list("select id from notes where mid=? order by id limit 2 offset 2", basic_id)
    app_path = os.path.join(swift_root, "User 1", "collection.anki2")
    with sqlite3.connect(app_path) as app_db:
        for note_id, value in zip(note_ids, ["<b>Exact</b>", " Trim "]):
            note = col.get_note(note_id)
            note.fields[0] = value
            if note_id == note_ids[0]:
                note.fields[1] = "Link:Target"
            col.update_note(note)

            fields = app_db.execute("select flds from notes where id=?", (note_id,)).fetchone()[0].split("\x1f")
            fields[0] = value
            if note_id == note_ids[0]:
                fields[1] = "Link:Target"
            app_db.execute(
                "update notes set flds=?, sfld=? where id=?",
                ("\x1f".join(fields), value, note_id),
            )


INVALID_SEARCH_QUERIES = [
    "is:old", "is:leech", "is:marked", "flag:red", "(", ")", "(is:new", "is:new)",
    "is:new OR", "OR is:new", "is:new AND", "()", '""', '"unclosed', ":value", "-:value",
]


def package_snapshot(path, media_path):
    db = sqlite3.connect(path)
    try:
        tables = {row[0] for row in db.execute("select name from sqlite_master where type='table'")}
        if "decks" in tables:
            deck_names = {
                int(deck_id): "Default" if int(deck_id) == 1 else name.replace("\x1f", "::")
                for deck_id, name in db.execute("select id, name from decks")
            }
        else:
            deck_data = json.loads(db.execute("select decks from col").fetchone()[0] or "{}")
            deck_names = {
                int(deck_id): "Default" if int(deck_id) == 1 else deck.get("name", "")
                for deck_id, deck in deck_data.items()
            }
        notes = [
            {"fields": fields, "tags": tags}
            for fields, tags in db.execute("select flds, tags from notes")
        ]
        cards = [
            {
                "fields": fields,
                "ord": ord,
                "type": type,
                "queue": queue,
                "due": due,
                "ivl": ivl,
                "factor": factor,
                "reps": reps,
                "lapses": lapses,
                "left": left,
                "flags": flags,
                "data": data,
                "deck": deck_names.get(did, str(did)),
                "odue": odue,
                "odid": odid,
            }
            for fields, ord, type, queue, due, ivl, factor, reps, lapses, left, flags, data, did, odue, odid in db.execute(
                """select n.flds, c.ord, c.type, c.queue, c.due, c.ivl, c.factor,
                          c.reps, c.lapses, c.left, c.flags, c.data, c.did, c.odue, c.odid
                   from cards c join notes n on n.id=c.nid"""
            )
        ]
        notes.sort(key=lambda item: (item["fields"], item["tags"]))
        cards.sort(key=lambda item: (item["fields"], item["ord"]))
        media = []
        if os.path.isdir(media_path):
            for filename in sorted(os.listdir(media_path)):
                full_path = os.path.join(media_path, filename)
                if os.path.isfile(full_path):
                    with open(full_path, "rb") as file:
                        media.append({"name": filename, "sha256": hashlib.sha256(file.read()).hexdigest()})
        return {"notes": notes, "cards": cards, "media": media}
    finally:
        db.close()


def _set_package_content(col, kind, value, mod):
    if kind == "notes":
        note_id, guid = col.db.first("select id, guid from notes order by id limit 1")
        note = col.get_note(note_id)
        note.fields[1] = value
        col.update_note(note)
        col.db.execute("update notes set mod=? where id=?", mod, note_id)
        return guid
    model = col.models.by_name("Basic")
    model["css"] = value
    model["mod"] = mod
    col.models.update(model, preserve_usn=True)
    return model["id"]


def _package_content(path, kind, key):
    db = sqlite3.connect(path)
    try:
        if kind == "notes":
            fields = db.execute("select flds from notes where guid=?", (key,)).fetchone()[0]
            return fields.split("\x1f")[1]
        row = db.execute("select models from col").fetchone()
        models = json.loads(row[0] or "{}") if row else {}
        if str(key) in models:
            return models[str(key)]["css"]
    finally:
        db.close()
    col = Collection(path)
    try:
        return col.models.by_name("Basic")["css"]
    finally:
        col.close()


def check_package_update_conditions():
    oracle_path, _ = prepare("sched")
    package_work = os.path.join(WORK, "package-update-conditions")
    shutil.rmtree(package_work, ignore_errors=True)
    os.makedirs(package_work)
    problems = []
    scenarios = [
        ("ifNewer", 200, 100, True),
        ("always", 100, 200, True),
        ("never", 200, 100, False),
    ]
    condition_field = ImportAnkiPackageOptions.DESCRIPTOR.fields_by_name["update_notes"]
    condition_values = {
        "ifNewer": condition_field.enum_type.values_by_name["IMPORT_ANKI_PACKAGE_UPDATE_CONDITION_IF_NEWER"].number,
        "always": condition_field.enum_type.values_by_name["IMPORT_ANKI_PACKAGE_UPDATE_CONDITION_ALWAYS"].number,
        "never": condition_field.enum_type.values_by_name["IMPORT_ANKI_PACKAGE_UPDATE_CONDITION_NEVER"].number,
    }
    for kind, option in [("notes", "--update-notes"), ("notetypes", "--update-notetypes")]:
        for condition, source_mod, destination_mod, should_update in scenarios:
            case = f"{kind}-{condition}"
            source_path = os.path.join(package_work, f"{case}-source.anki2")
            shutil.copy2(oracle_path, source_path)
            source = Collection(source_path)
            source_value = f"package {case}"
            key = _set_package_content(source, kind, source_value, source_mod)
            source.close(downgrade=True)

            package_path = os.path.join(package_work, f"{case}.apkg")
            source = Collection(source_path)
            try:
                source.export_anki_package(
                    out_path=package_path,
                    options=ExportAnkiPackageOptions(
                        with_scheduling=False,
                        with_deck_configs=False,
                        with_media=False,
                        legacy=False,
                    ),
                    limit=None,
                )
            finally:
                source.close()

            destination_path = os.path.join(package_work, f"{case}-destination.anki2")
            shutil.copy2(oracle_path, destination_path)
            destination = Collection(destination_path)
            destination_value = f"collection {case}"
            destination_key = _set_package_content(destination, kind, destination_value, destination_mod)
            destination.close(downgrade=True)
            if destination_key != key:
                problems.append(f"package-update/{case}: fixture keys do not match")
                continue

            official_path = os.path.join(package_work, f"{case}-official.anki2")
            shutil.copy2(destination_path, official_path)
            official = Collection(official_path)
            try:
                options = ImportAnkiPackageOptions(
                    merge_notetypes=True,
                    update_notes=condition_values[condition] if kind == "notes" else condition_values["ifNewer"],
                    update_notetypes=condition_values[condition] if kind == "notetypes" else condition_values["ifNewer"],
                )
                official.import_anki_package(ImportAnkiPackageRequest(package_path=package_path, options=options))
            finally:
                official.close()

            swift_root = os.path.join(package_work, f"{case}-swift")
            os.makedirs(os.path.join(swift_root, "User 1"))
            swift_path = os.path.join(swift_root, "User 1", "collection.anki2")
            shutil.copy2(destination_path, swift_path)
            run_harness(
                swift_root,
                "import",
                package_path,
                "--merge-notetypes",
                f"{option}={condition}",
            )

            official_result = _package_content(official_path, kind, key)
            swift_result = _package_content(swift_path, kind, key)
            expected = source_value if should_update else destination_value
            if official_result != expected:
                problems.append(f"package-update/{case}: Anki result={official_result!r}, expected={expected!r}")
            if swift_result != expected:
                problems.append(f"package-update/{case}: AnkiOS result={swift_result!r}, expected={expected!r}")
            if official_result != swift_result:
                problems.append(f"package-update/{case}: Anki={official_result!r}, AnkiOS={swift_result!r}")
    return problems


def check_package_notetype_conditions_without_merge():
    oracle_path, _ = prepare("sched")
    package_work = os.path.join(WORK, "package-notetype-no-merge")
    shutil.rmtree(package_work, ignore_errors=True)
    os.makedirs(package_work)
    condition_field = ImportAnkiPackageOptions.DESCRIPTOR.fields_by_name["update_notetypes"]
    condition_values = {
        "ifNewer": condition_field.enum_type.values_by_name["IMPORT_ANKI_PACKAGE_UPDATE_CONDITION_IF_NEWER"].number,
        "always": condition_field.enum_type.values_by_name["IMPORT_ANKI_PACKAGE_UPDATE_CONDITION_ALWAYS"].number,
        "never": condition_field.enum_type.values_by_name["IMPORT_ANKI_PACKAGE_UPDATE_CONDITION_NEVER"].number,
    }
    scenarios = [
        ("ifNewer", 200, 100, True),
        ("always", 100, 200, True),
        ("never", 200, 100, False),
    ]
    problems = []
    for condition, source_mod, destination_mod, should_update in scenarios:
        case = f"notetype-no-merge-{condition}"
        source_path = os.path.join(package_work, f"{case}-source.anki2")
        shutil.copy2(oracle_path, source_path)
        source = Collection(source_path)
        source_value = f"package {case}"
        key = _set_package_content(source, "notetypes", source_value, source_mod)
        source.close(downgrade=True)

        package_path = os.path.join(package_work, f"{case}.apkg")
        source = Collection(source_path)
        try:
            source.export_anki_package(
                out_path=package_path,
                options=ExportAnkiPackageOptions(
                    with_scheduling=False,
                    with_deck_configs=False,
                    with_media=False,
                    legacy=False,
                ),
                limit=None,
            )
        finally:
            source.close()

        destination_path = os.path.join(package_work, f"{case}-destination.anki2")
        shutil.copy2(oracle_path, destination_path)
        destination = Collection(destination_path)
        destination_value = f"collection {case}"
        destination_key = _set_package_content(destination, "notetypes", destination_value, destination_mod)
        destination.close(downgrade=True)
        if destination_key != key:
            problems.append(f"package-update/{case}: fixture keys do not match")
            continue

        official_path = os.path.join(package_work, f"{case}-official.anki2")
        shutil.copy2(destination_path, official_path)
        official = Collection(official_path)
        try:
            official.import_anki_package(
                ImportAnkiPackageRequest(
                    package_path=package_path,
                    options=ImportAnkiPackageOptions(update_notetypes=condition_values[condition]),
                )
            )
        finally:
            official.close()

        swift_root = os.path.join(package_work, f"{case}-swift")
        os.makedirs(os.path.join(swift_root, "User 1"))
        swift_path = os.path.join(swift_root, "User 1", "collection.anki2")
        shutil.copy2(destination_path, swift_path)
        run_harness(swift_root, "import", package_path, f"--update-notetypes={condition}")

        official_result = _package_content(official_path, "notetypes", key)
        swift_result = _package_content(swift_path, "notetypes", key)
        expected = source_value if should_update else destination_value
        if official_result != expected:
            problems.append(f"package-update/{case}: Anki result={official_result!r}, expected={expected!r}")
        if swift_result != expected:
            problems.append(f"package-update/{case}: AnkiOS result={swift_result!r}, expected={expected!r}")
        if official_result != swift_result:
            problems.append(f"package-update/{case}: Anki={official_result!r}, AnkiOS={swift_result!r}")
    return problems


def check_package_schema_merge():
    oracle_path, _ = prepare("sched")
    package_work = os.path.join(WORK, "package-schema-merge")
    shutil.rmtree(package_work, ignore_errors=True)
    os.makedirs(package_work)
    source_path = os.path.join(package_work, "source.anki2")
    shutil.copy2(oracle_path, source_path)
    source = Collection(source_path)
    notetype_id = source.models.by_name("Basic")["id"]
    note_id, guid = source.db.first("select id, guid from notes where mid=? order by id limit 1", notetype_id)
    model = source.models.by_name("Basic")
    source.models.add_field(model, source.models.new_field("Extra"))
    model["mod"] = int(time.time()) + 100
    source.models.update(model, preserve_usn=True)
    note = source.get_note(note_id)
    note.fields[2] = "package field"
    source.update_note(note)
    source.db.execute("update notes set mod=? where id=?", int(time.time()) + 100, note_id)
    source.close(downgrade=True)

    package_path = os.path.join(package_work, "schema-merge.apkg")
    source = Collection(source_path)
    try:
        source.export_anki_package(
            out_path=package_path,
            options=ExportAnkiPackageOptions(
                with_scheduling=False,
                with_deck_configs=False,
                with_media=False,
                legacy=False,
            ),
            limit=None,
        )
    finally:
        source.close()

    official_path = os.path.join(package_work, "official.anki2")
    shutil.copy2(oracle_path, official_path)
    official = Collection(official_path)
    try:
        official.import_anki_package(
            ImportAnkiPackageRequest(
                package_path=package_path,
                options=ImportAnkiPackageOptions(merge_notetypes=True),
            )
        )
    finally:
        official.close()

    swift_root = os.path.join(package_work, "swift")
    os.makedirs(os.path.join(swift_root, "User 1"))
    swift_path = os.path.join(swift_root, "User 1", "collection.anki2")
    shutil.copy2(oracle_path, swift_path)
    run_harness(swift_root, "import", package_path, "--merge-notetypes")

    def official_snapshot(path):
        col = Collection(path)
        try:
            model = col.models.by_name("Basic")
            note_id = col.db.scalar("select id from notes where guid=?", guid)
            note = col.get_note(note_id)
            card_ords = col.db.list("select ord from cards where nid=? order by ord", note_id)
            return {"fields": [field["name"] for field in model["flds"]], "note": note.fields, "cardOrds": card_ords}
        finally:
            col.close()

    def swift_snapshot(path):
        db = sqlite3.connect(path)
        try:
            models = json.loads(db.execute("select models from col").fetchone()[0] or "{}")
            note_id, mid, fields = db.execute("select id, mid, flds from notes where guid=?", (guid,)).fetchone()
            model = models[str(mid)]
            note_fields = fields.split("\x1f")
            card_ords = [row[0] for row in db.execute("select ord from cards where nid=? order by ord", (note_id,))]
            return {
                "fields": [field["name"] for field in sorted(model["flds"], key=lambda item: item.get("ord", 0))],
                "note": note_fields,
                "cardOrds": card_ords,
            }
        finally:
            db.close()

    expected = {"fields": ["Front", "Back", "Extra"], "note": ["Lang front 0", "Über", "package field"], "cardOrds": [0]}
    official_result = official_snapshot(official_path)
    swift_result = swift_snapshot(swift_path)
    problems = diff("package-schema-merge:Anki", expected, official_result)
    problems += diff("package-schema-merge:AnkiOS", expected, swift_result)
    problems += diff("package-schema-merge", official_result, swift_result)

    official_no_merge_path = os.path.join(package_work, "official-no-merge.anki2")
    shutil.copy2(oracle_path, official_no_merge_path)
    official = Collection(official_no_merge_path)
    try:
        official.import_anki_package(
            ImportAnkiPackageRequest(package_path=package_path, options=ImportAnkiPackageOptions())
        )
    finally:
        official.close()

    swift_no_merge_root = os.path.join(package_work, "swift-no-merge")
    os.makedirs(os.path.join(swift_no_merge_root, "User 1"))
    swift_no_merge_path = os.path.join(swift_no_merge_root, "User 1", "collection.anki2")
    shutil.copy2(oracle_path, swift_no_merge_path)
    run_harness(swift_no_merge_root, "import", package_path)

    def official_no_merge_snapshot(path):
        col = Collection(path)
        try:
            note_id = col.db.scalar("select id from notes where guid=?", guid)
            note = col.get_note(note_id)
            return {
                "notetypes": sorted(model["name"] for model in col.models.all()),
                "notes": col.db.scalar("select count(*) from notes"),
                "cards": col.db.scalar("select count(*) from cards"),
                "note": note.fields,
            }
        finally:
            col.close()

    def swift_no_merge_snapshot(path):
        db = sqlite3.connect(path)
        try:
            models = json.loads(db.execute("select models from col").fetchone()[0] or "{}")
            note_id, fields = db.execute("select id, flds from notes where guid=?", (guid,)).fetchone()
            return {
                "notetypes": sorted(model["name"] for model in models.values()),
                "notes": db.execute("select count(*) from notes").fetchone()[0],
                "cards": db.execute("select count(*) from cards").fetchone()[0],
                "note": fields.split("\x1f"),
            }
        finally:
            db.close()

    official_no_merge = official_no_merge_snapshot(official_no_merge_path)
    swift_no_merge = swift_no_merge_snapshot(swift_no_merge_path)
    problems += diff("package-schema-no-merge", official_no_merge, swift_no_merge)
    return problems


def csv_collection_snapshot(path):
    db = sqlite3.connect(path)
    try:
        tables = {row[0] for row in db.execute("select name from sqlite_master where type='table'")}
        if "decks" in tables:
            deck_names = {
                int(deck_id): name.replace("\x1f", "::")
                for deck_id, name in db.execute("select id, name from decks")
            }
        else:
            deck_data = json.loads(db.execute("select decks from col").fetchone()[0] or "{}")
            deck_names = {int(deck_id): deck.get("name", "") for deck_id, deck in deck_data.items()}
        notes = sorted(db.execute("select flds, tags, usn from notes").fetchall())
        cards = sorted(
            (fields, deck_names.get(did, str(did)))
            for fields, did in db.execute("select n.flds, c.did from cards c join notes n on n.id=c.nid")
        )
        return {"notes": notes, "cards": cards}
    finally:
        db.close()


def filtered_snapshot(col, filtered_id, card_ids=None):
    if card_ids is None:
        rows = col.db.all("""
        select id, type, queue, due, ivl, odue, did, ord, usn
            from cards where odid != 0 order by due, id
        """)
    elif card_ids:
        placeholders = ",".join("?" for _ in card_ids)
        rows = col.db.all(f"""
        select id, type, queue, due, ivl, odue, did, ord, usn
            from cards where id in ({placeholders}) order by id
        """, *card_ids)
    else:
        rows = []
    return [
        {
            "id": cid,
            "type": card_type,
            "queue": queue,
            "due": due,
            "ivl": ivl,
            "odue": odue,
            "deck": "filtered" if did == filtered_id else col.decks.name(did),
            "templateDeck": col.decks.name(col.db.scalar("select case when odid != 0 then odid else did end from cards where id=?", cid)),
            "ord": ord,
            "usn": usn,
        }
        for cid, card_type, queue, due, ivl, odue, did, ord, usn in rows
    ]


def check_queue_actions():
    problems = []
    for action in ("suspend", "bury", "unbury", "unsuspend"):
        oracle_path, swift_root = prepare("sched")
        oracle = Collection(oracle_path)
        try:
            ids = [oracle.db.scalar("select id from cards where queue=? order by id limit 1", queue) for queue in (0, -1, -2, -3)]
            placeholders = ",".join("?" for _ in ids)
            oracle.db.execute(f"update cards set usn=42 where id in ({placeholders})", *ids)
            if action == "suspend":
                oracle.sched.suspend_cards(ids)
            elif action == "bury":
                oracle.sched.bury_cards(ids)
            elif action == "unbury":
                oracle.sched.unbury_cards(ids)
            else:
                oracle.sched.unsuspend_cards(ids)
            expected_rows = oracle.db.all(
                f"select id, queue, usn from cards where id in ({placeholders}) order by id",
                *ids,
            )
            expected = [{"id": cid, "queue": queue, "usn": usn} for cid, queue, usn in expected_rows]
        finally:
            oracle.close()
        actual = run_harness(swift_root, "queue-actions", action)
        problems += diff(f"queue:{action}", expected, actual)
    return problems


def check_delete_actions():
    oracle_path, swift_root = prepare("sched")
    oracle = Collection(oracle_path)
    try:
        nid = oracle.db.scalar("""
            select n.id from notes n
            join cards c on c.nid=n.id
            join revlog r on r.cid=c.id
            order by n.id limit 1
        """)
        cids = oracle.db.list("select id from cards where nid=? order by id", nid)
        placeholders = ",".join("?" for _ in cids)

        def snapshot():
            note_keys = ["id", "guid", "mid", "mod", "usn", "tags", "flds", "sfld", "csum", "flags", "data"]
            card_keys = ["id", "nid", "did", "ord", "mod", "usn", "type", "queue", "due", "ivl", "factor", "reps", "lapses", "left", "odue", "odid", "flags", "data"]
            revlog_keys = ["id", "cid", "usn", "ease", "ivl", "lastIvl", "factor", "time", "type"]
            notes = [dict(zip(note_keys, row)) for row in oracle.db.all(
                "select id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data from notes where id=?", nid
            )]
            cards = [dict(zip(card_keys, row)) for row in oracle.db.all(
                "select id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data from cards where nid=? order by id", nid
            )]
            if cids:
                graves = [dict(zip(["usn", "oid", "type"], row)) for row in oracle.db.all(
                    f"select usn, oid, type from graves where (type=0 and oid in ({placeholders})) or (type=1 and oid=?) order by type, oid, usn",
                    *cids, nid,
                )]
                revlog = [dict(zip(revlog_keys, row)) for row in oracle.db.all(
                    f"select id, cid, usn, ease, ivl, lastIvl, factor, time, type from revlog where cid in ({placeholders}) order by id",
                    *cids,
                )]
            else:
                graves, revlog = [], []
            return {"notes": notes, "cards": cards, "graves": graves, "revlog": revlog}

        before = snapshot()
        oracle.remove_notes([nid])
        deleted = snapshot()
    finally:
        oracle.close()
    actual = run_harness(swift_root, "delete-actions")
    expected = {"before": before, "deleted": deleted, "undone": before, "redone": deleted}
    return diff("delete", expected, actual)


def check_deck_actions():
    problems = []
    oracle_path, swift_root = prepare("sched")
    oracle = Collection(oracle_path)
    try:
        deck_id = oracle.decks.id("Lang::ES", create=False)
        model = oracle.models.by_name("Basic (and reversed card)")
        note = oracle.new_note(model)
        note.guid = "parity-insertion-order"
        note.fields = ["Insertion order front", "Insertion order back"]
        oracle.add_note(note, deck_id)
        oracle.db.execute(
            "update cards set usn=42 where (did=? or (odid!=0 and odid=?)) and type=0",
            deck_id, deck_id,
        )
        config_id = oracle.decks.get(deck_id)["conf"]
        for order in (1, 0):
            config = next(
                item.config for item in oracle.decks.get_deck_configs_for_update(deck_id).all_config
                if item.config.id == config_id
            )
            config.config.new_card_insert_order = order
            oracle.decks.update_deck_configs(UpdateDeckConfigsRequest(
                target_deck_id=deck_id,
                configs=[config],
                mode=UpdateDeckConfigsMode.UPDATE_DECK_CONFIGS_MODE_NORMAL,
                fsrs=False,
            ))
        expected = {"cards": [
            {
                "guid": guid,
                "ord": ord,
                "did": did,
                "odid": odid,
                "queue": queue,
                "due": due,
                "odue": odue,
                "usn": usn,
            }
            for guid, ord, did, odid, queue, due, odue, usn in oracle.db.all(
                "select n.guid, c.ord, c.did, c.odid, c.queue, c.due, c.odue, c.usn "
                "from cards c join notes n on n.id=c.nid "
                "where (c.did=? or (c.odid!=0 and c.odid=?)) and c.type=0 order by n.guid, c.ord",
                deck_id, deck_id,
            )
        ]}
    finally:
        oracle.close()
    actual = run_harness(swift_root, "deck-actions", "insertion-order")
    problems += diff("decks:insertion-order", expected, actual)

    create_cases = [
        ("create", "New::Leaf"),
        ("create-normalized", "lANG::New::::Leaf"),
        ("create-existing", "lang::jp"),
        ("create-parented", "Lang::New::Leaf"),
    ]
    for action, new_name in create_cases:
        oracle_path, swift_root = prepare("sched")
        oracle = Collection(oracle_path)
        try:
            dids = oracle.db.list("select id from decks order by id")
            original_ids = set(dids)
            for index, did in enumerate(dids):
                oracle.db.execute("update decks set mtime_secs=? where id=?", 700 + index, did)

            def deck_snapshot():
                rows = []
                for deck in sorted(oracle.decks.all(), key=lambda item: item["id"]):
                    rows.append({
                        "id": deck["id"] if deck["id"] in original_ids else f"new:{deck['name']}",
                        "name": deck["name"],
                        "mod": "updated" if deck["mod"] > 1_000_000_000 else deck["mod"],
                        "usn": deck["usn"],
                    })
                return rows

            create_before = deck_snapshot()
            oracle.decks.id(new_name)
            create_after = deck_snapshot()
            if create_after != create_before:
                oracle.undo()
                create_undone = deck_snapshot()
                oracle.redo()
                create_redone = deck_snapshot()
            else:
                create_undone = create_after
                create_redone = create_after
            create_expected = {
                "before": create_before,
                "after": create_after,
                "undone": create_undone,
                "redone": create_redone,
            }
        finally:
            oracle.close()
        create_actual = run_harness(swift_root, "deck-actions", action)
        problems += diff(f"decks:{action}", create_expected, create_actual)

    reparent_cases = ["reparent-sibling", "reparent-root", "reparent-collision", "reparent-descendant"]
    for action in reparent_cases:
        oracle_path, swift_root = prepare("sched")
        oracle = Collection(oracle_path)
        try:
            original_ids = set(oracle.db.list("select id from decks order by id"))
            if action == "reparent-collision":
                oracle.decks.id("Lang::ES::JP")
            dids = oracle.db.list("select id from decks order by id")
            for index, did in enumerate(dids):
                oracle.db.execute("update decks set mtime_secs=? where id=?", 700 + index, did)

            def deck_snapshot():
                rows = []
                for deck in sorted(oracle.decks.all(), key=lambda item: item["id"]):
                    rows.append({
                        "id": deck["id"] if deck["id"] in original_ids else f"new:{deck['name']}",
                        "name": deck["name"],
                        "mod": "updated" if deck["mod"] > 1_000_000_000 else deck["mod"],
                        "usn": deck["usn"],
                    })
                return rows

            reparent_before = deck_snapshot()
            source_name = "Lang" if action == "reparent-descendant" else "Lang::JP"
            source_id = oracle.decks.id(source_name, create=False)
            target_id = 0 if action == "reparent-root" else oracle.decks.id("Lang::ES", create=False)
            oracle.decks.reparent([source_id], target_id)
            reparent_after = deck_snapshot()
            if reparent_after != reparent_before:
                oracle.undo()
                reparent_undone = deck_snapshot()
                oracle.redo()
                reparent_redone = deck_snapshot()
            else:
                reparent_undone = reparent_after
                reparent_redone = reparent_after
            reparent_expected = {
                "before": reparent_before,
                "after": reparent_after,
                "undone": reparent_undone,
                "redone": reparent_redone,
            }
        finally:
            oracle.close()
        reparent_actual = run_harness(swift_root, "deck-actions", action)
        problems += diff(f"decks:{action}", reparent_expected, reparent_actual)

    rename_cases = [
        ("rename", "Lang::JP", "Lang::Japanese"),
        ("rename-conflict", "Lang::JP", "Lang::ES"),
        ("rename-normalized", "Lang::JP", "lANG::New::::Leaf"),
        ("rename-nested", "Lang::JP", "Lang::JP::Kana::Leaf"),
        ("rename-root", "Lang", "Lang::Archive"),
        ("rename-case", "Lang::JP", "lang::jP"),
    ]
    for action, target_name, new_name in rename_cases:
        oracle_path, swift_root = prepare("sched")
        oracle = Collection(oracle_path)
        try:
            dids = oracle.db.list("select id from decks order by id")
            original_ids = set(dids)
            for index, did in enumerate(dids):
                oracle.db.execute("update decks set mtime_secs=? where id=?", 700 + index, did)

            def deck_snapshot():
                rows = []
                for deck in sorted(oracle.decks.all(), key=lambda item: item["id"]):
                    rows.append({
                        "id": deck["id"] if deck["id"] in original_ids else f"new:{deck['name']}",
                        "name": deck["name"],
                        "mod": "updated" if deck["mod"] > 1_000_000_000 else deck["mod"],
                        "usn": deck["usn"],
                    })
                return rows

            rename_before = deck_snapshot()
            oracle.decks.rename(oracle.decks.id(target_name), new_name)
            rename_after = deck_snapshot()
            oracle.undo()
            rename_undone = deck_snapshot()
            oracle.redo()
            rename_redone = deck_snapshot()
            rename_expected = {
                "before": rename_before,
                "after": rename_after,
                "undone": rename_undone,
                "redone": rename_redone,
            }
        finally:
            oracle.close()
        rename_actual = run_harness(swift_root, "deck-actions", action)
        problems += diff(f"decks:{action}", rename_expected, rename_actual)

    oracle_path, swift_root = prepare("sched")
    oracle = Collection(oracle_path)
    try:
        parent_id = oracle.decks.id("Lang::JP")
        child_id = oracle.decks.id("Lang::JP::Kana")
        math_id = oracle.decks.id("Math")
        basic = oracle.models.by_name("Basic")
        reversed_model = oracle.models.by_name("Basic (and reversed card)")
        parent_note = oracle.new_note(basic)
        parent_note.guid = "parity-deck-parent"
        parent_note.fields = ["Deck delete parent", "parent"]
        oracle.add_note(parent_note, parent_id)
        shared_note = oracle.new_note(reversed_model)
        shared_note.guid = "parity-deck-shared"
        shared_note.fields = ["Deck delete shared", "shared"]
        oracle.add_note(shared_note, child_id)
        oracle.db.execute("update notes set mod=401, usn=40 where guid like 'parity-deck-%'")
        oracle.db.execute(
            "update cards set mod=402, usn=41 where nid in (select id from notes where guid like 'parity-deck-%')"
        )
        oracle.db.execute(
            "update cards set did=?, mod=987, usn=42 where nid=? and ord=1",
            math_id,
            shared_note.id,
        )
        deck_names = {deck["id"]: deck["name"] for deck in oracle.decks.all()}
        note_names = dict(oracle.db.all("select id, guid from notes"))
        card_names = {
            cid: f"{guid}#{ord}"
            for cid, guid, ord in oracle.db.all(
                "select c.id, n.guid, c.ord from cards c join notes n on n.id=c.nid"
            )
        }
        prior_graves = set(oracle.db.all("select usn, oid, type from graves"))

        def snapshot():
            notes = [
                {"guid": guid, "mid": mid, "mod": mod, "usn": usn, "tags": tags, "flds": flds, "sfld": sfld, "csum": csum}
                for guid, mid, mod, usn, tags, flds, sfld, csum in oracle.db.all(
                    "select guid, mid, mod, usn, tags, flds, sfld, csum from notes where guid like 'parity-deck-%' order by guid"
                )
            ]
            cards = [
                {
                    "guid": guid,
                    "ord": ord,
                    "deck": deck_names.get(did, ""),
                    "type": card_type,
                    "queue": queue,
                    "due": due,
                    "ivl": ivl,
                    "mod": mod,
                    "usn": usn,
                }
                for guid, ord, did, card_type, queue, due, ivl, mod, usn in oracle.db.all(
                    """
                    select n.guid, c.ord, c.did, c.type, c.queue, c.due, c.ivl, c.mod, c.usn
                    from cards c join notes n on n.id=c.nid
                    where n.guid like 'parity-deck-%'
                    order by n.guid, c.ord
                    """
                )
            ]
            decks = [
                {"id": deck["id"], "name": deck["name"], "mod": deck["mod"], "usn": deck["usn"]}
                for deck in sorted(oracle.decks.all(), key=lambda item: item["id"])
            ]
            new_graves = []
            for usn, oid, kind in oracle.db.all("select usn, oid, type from graves order by type, oid, usn"):
                if (usn, oid, kind) in prior_graves:
                    continue
                subject = {0: card_names, 1: note_names, 2: deck_names}.get(kind, {}).get(oid, "")
                new_graves.append({"usn": usn, "type": kind, "subject": subject})
            return {"decks": decks, "notes": notes, "cards": cards, "newGraves": new_graves}

        delete_before = snapshot()
        oracle.decks.remove([parent_id])
        delete_after = snapshot()
        oracle.undo()
        delete_undone = snapshot()
        oracle.redo()
        delete_redone = snapshot()
        delete_expected = {
            "before": delete_before,
            "after": delete_after,
            "undone": delete_undone,
            "redone": delete_redone,
        }
    finally:
        oracle.close()
    delete_actual = run_harness(swift_root, "deck-actions", "delete")
    problems += diff("decks:delete", delete_expected, delete_actual)

    oracle_path, swift_root = prepare("sched")
    oracle = Collection(oracle_path)
    try:
        parent_id = oracle.decks.id("Lang::JP")
        filtered_id = oracle.decks.new_filtered("ParityFiltered")
        target_id = 9_000_000_000_000_000
        oracle.db.execute("update decks set id=?, mtime_secs=401, usn=-1 where id=?", target_id, filtered_id)
        basic = oracle.models.by_name("Basic")
        note = oracle.new_note(basic)
        note.guid = "parity-deck-filtered"
        note.fields = ["Filtered deck card", "back"]
        oracle.add_note(note, parent_id)
        card_id = oracle.db.scalar("select id from cards where nid=?", note.id)
        oracle.db.execute(
            "update cards set did=?, odid=?, odue=due, due=-100000, mod=402, usn=41 where id=?",
            target_id,
            parent_id,
            card_id,
        )
        deck_names = {deck["id"]: deck["name"] for deck in oracle.decks.all()}

        def filtered_snapshot():
            decks = [
                {"id": deck["id"], "name": deck["name"], "mod": deck["mod"], "usn": deck["usn"]}
                for deck in sorted(oracle.decks.all(), key=lambda item: item["id"])
            ]
            note_exists = oracle.db.scalar("select count(*) from notes where id=?", note.id) != 0
            did, odid, odue, due, card_type, queue, mod, usn = oracle.db.first(
                "select did, odid, odue, due, type, queue, mod, usn from cards where id=?", card_id
            )
            card = {
                "deck": deck_names.get(did, ""),
                "odid": odid,
                "odue": odue,
                "due": due,
                "type": card_type,
                "queue": queue,
                "mod": mod,
                "usn": usn,
            }
            graves = [
                {"usn": usn, "type": kind, "subject": "parity-deck-filtered#0" if kind == 0 else "ParityFiltered"}
                for usn, oid, kind in oracle.db.all(
                    """
                    select usn, oid, type from graves
                    where (type=0 and oid=?) or (type=2 and oid=?)
                    order by type, oid, usn
                    """,
                    card_id,
                    target_id,
                )
            ]
            return {"decks": decks, "noteExists": note_exists, "card": card, "graves": graves}

        filtered_before = filtered_snapshot()
        oracle.decks.remove([target_id])
        filtered_after = filtered_snapshot()
        oracle.undo()
        filtered_undone = filtered_snapshot()
        oracle.redo()
        filtered_redone = filtered_snapshot()
        filtered_expected = {
            "before": filtered_before,
            "after": filtered_after,
            "undone": filtered_undone,
            "redone": filtered_redone,
        }
    finally:
        oracle.close()
    filtered_actual = run_harness(swift_root, "deck-actions", "filtered-delete")
    problems += diff("decks:filtered-delete", filtered_expected, filtered_actual)
    return problems


def check_empty_actions():
    oracle_path, swift_root = prepare("sched")
    oracle = Collection(oracle_path)
    try:
        mid = oracle.models.by_name("Basic")["id"]
        nid = oracle.db.scalar(
            "select n.id from notes n join cards c on c.nid=n.id where n.mid=? and c.queue=0 order by n.id limit 1",
            mid,
        )
        cids = oracle.db.list("select id from cards where nid=? order by id", nid)
        note = oracle.get_note(nid)
        note.fields[0] = ""
        oracle.update_note(note)
        before_cards = oracle.db.scalar("select count(*) from cards")
        report = oracle.get_empty_cards()
        empty_cids = [cid for item in report.notes for cid in item.card_ids]
        if empty_cids:
            oracle.remove_cards_and_orphaned_notes(empty_cids)
        placeholders = ",".join("?" for _ in cids)
        expected = {
            "removed": before_cards - oracle.db.scalar("select count(*) from cards"),
            "noteExists": oracle.db.scalar("select count(*) from notes where id=?", nid) != 0,
            "cards": oracle.db.list("select id from cards where nid=? order by id", nid),
            "graves": [dict(zip(["usn", "oid", "type"], row)) for row in oracle.db.all(
                f"select usn, oid, type from graves where (type=0 and oid in ({placeholders})) or (type=1 and oid=?) order by type, oid, usn",
                *cids, nid,
            )],
            "revlogIDs": oracle.db.list(
                f"select id from revlog where cid in ({placeholders}) order by id", *cids
            ),
        }
    finally:
        oracle.close()
    actual = run_harness(swift_root, "empty-actions")
    return diff("empty", expected, actual)


def check_cardgen_actions():
    oracle_path, swift_root = prepare("sched")
    oracle = Collection(oracle_path)
    try:
        model = oracle.models.by_name("Basic")
        templates = [
            ("Deck special", "{{Deck}}"),
            ("Tags special", "{{Tags}}"),
            ("Conditional", "{{#Front}}{{Front}}{{/Front}}"),
            ("Negated", "{{^Back}}{{Front}}{{/Back}}"),
        ]
        for name, qfmt in templates:
            template = oracle.models.new_template(name)
            template["qfmt"] = qfmt
            template["afmt"] = "{{FrontSide}}"
            oracle.models.add_template(model, template)
        oracle.models.update(model)
        expected = []
        cases = [
            ("parity-special-no-tags", ["", ""], []),
            ("parity-special-with-tags", ["", ""], ["parity"]),
            ("parity-conditional-front", ["front", ""], []),
            ("parity-conditional-both", ["front", "back"], []),
        ]
        for guid, fields, tags in cases:
            note = oracle.new_note(model)
            note.guid = guid
            note.fields = fields
            note.tags = tags
            oracle.add_note(note, 1)
            expected.append({
                "tags": " ".join(tags),
                "ords": oracle.db.list("select ord from cards where nid=? order by ord", note.id),
            })
    finally:
        oracle.close()
    actual = run_harness(swift_root, "cardgen-actions")
    return diff("cardgen", expected, actual)


def check_templates():
    oracle_path, swift_root = prepare("sched")
    cases = [
        ("parityUnknown:Front", "<b>Parity front</b>"),
        ("parityUnknown:text:Front", "<b>Parity front</b>"),
        ("Missing", "not present"),
        ("text:Missing", "not present"),
        ("#Missing}}content{{/Missing", "value"),
        ("#Front}}content{{/Back", "value"),
        ("/Missing", "value"),
        ("#Front}}content", "value"),
        ("text:Front", "A &amp; B &nbsp; &#x1f642;"),
        ("text:Front", "&copy; &eacute; &mdash;"),
        ("text:Front", "&apos;"),
        ("text:Front", "&NotEqualTilde; &amp;"),
        ("text:Front", "&amp"),
        ("text:Front", "R&D"),
        ("text:Front", "A&#169; B"),
        ("text:Front", "A&#x110000; B"),
        ("text:Front", "A&#xD800; B"),
        ("text:Front", "A<!-- hidden -->B"),
        ("text:Front", "A<script>hidden()</script>B"),
        ("text:Front", "A<style>.hidden { display: none }</style>B"),
        ("Front", "Literal {{Back}} and {{Missing}}"),
        ("Front", "{{#Back}}literal{{/Back}}"),
        ("Front", "{{type:Back}}"),
        ("Front", "{{cloze:Back}}"),
        ("Front", "{{FrontSide}}"),
    ]
    import html.entities

    cases.extend(("text:Front", f"&{name};") for name in sorted(html.entities.name2codepoint))
    from anki.utils import to_json_bytes

    oracle = Collection(oracle_path)
    face_templates = [
        "",
        "{{#Back}}{{Front}}{{/Back}}",
        "<script>window.cardReady=true;</script>",
        '<video src="clip.mp4"></video>',
    ]
    try:
        model = oracle.models.by_name("Basic")
        expected = []
        for expression, value in cases:
            note = oracle.new_note(model)
            note.fields[0] = value
            template = dict(model["tmpls"][0])
            template["qfmt"] = "{{" + expression + "}}"
            template["afmt"] = ""
            try:
                rendered = oracle._backend.render_uncommitted_card_legacy(
                    note=note._to_backend_note(),
                    card_ord=0,
                    template=to_json_bytes(template),
                    fill_empty=False,
                    partial_render=False,
                )
                expected.append("".join(node.text for node in rendered.question_nodes))
            except Exception as error:
                expected.append(str(error))
        expected_faces = []
        for question in face_templates:
            note = oracle.new_note(model)
            note.fields = ["PARITY_HIDDEN_FIELD", ""]
            template = dict(model["tmpls"][0], qfmt=question, afmt="")
            rendered = oracle._backend.render_uncommitted_card_legacy(
                note=note._to_backend_note(), card_ord=0,
                template=to_json_bytes(template), fill_empty=False, partial_render=False,
            )
            expected_faces.append("".join(node.text for node in rendered.question_nodes))
        cloze_model = oracle.models.by_name("Cloze")
        cloze_note = oracle.new_note(cloze_model)
        cloze_note.fields = ["PARITY_HIDDEN_FIELD", ""]
        cloze_template = dict(cloze_model["tmpls"][0], qfmt="{{cloze:Text}}", afmt="")
        cloze_rendered = oracle._backend.render_uncommitted_card_legacy(
            note=cloze_note._to_backend_note(), card_ord=0,
            template=to_json_bytes(cloze_template), fill_empty=False, partial_render=False,
        )
        expected_cloze = ["".join(node.text for node in cloze_rendered.question_nodes)]
    finally:
        oracle.close()
    actual = run_harness(swift_root, "template-render-batch", json.dumps(cases))
    actual_faces = run_harness(swift_root, "card-render-batch", json.dumps(face_templates))
    actual_cloze = run_harness(swift_root, "cloze-render-batch", json.dumps(["{{cloze:Text}}"] ))
    return (diff("templates", expected, actual)
            + diff("templates:card-faces", expected_faces, actual_faces)
            + diff("templates:missing-cloze", expected_cloze, actual_cloze))


def check_filtered():
    scenarios = [
        ("deck:Lang is:new", 10, "due", True, "", 20, "due"),
        ("deck:Math is:new", 12, "added", True, "", 20, "due"),
        ("deck:Lang is:review", 12, "ivlDesc", False, "", 20, "due"),
        ("deck:Lang is:review", 30, "ivl", True, "", 20, "due"),
        ("deck:Lang is:review", 30, "latest", True, "", 20, "due"),
        ("deck:Lang is:learn", 20, "oldest", True, "", 20, "due"),
        ("deck:Math is:review", 12, "lapses", True, "", 20, "due"),
        ("deck:Lang is:new", 5, "due", True, "is:new", 10, "latest"),
        ("deck:Lang is:new", 500, "random", True, "", 20, "due"),
    ]
    order_ids = {
        "oldest": 0,
        "random": 1,
        "ivl": 2,
        "ivlDesc": 3,
        "lapses": 4,
        "added": 5,
        "due": 6,
        "latest": 7,
        "retrievability": 8,
        "retrievabilityDesc": 9,
        "relative": 10,
    }
    problems = []
    for index, (search, limit, order, reschedule, search2, limit2, order2) in enumerate(scenarios):
        repeat_rebuild = index != 3 and order != "oldest"
        oracle_path, swift_root = prepare("sched")
        oracle = Collection(oracle_path)
        try:
            oracle.db.execute("update cards set usn=43")
            deck_id = oracle.decks.new_filtered("Parity")
            deck = oracle.decks.get(deck_id)
            deck["terms"] = [[search, limit, order_ids[order]]]
            if search2:
                deck["terms"].append([search2, limit2, order_ids[order2]])
            deck["resched"] = reschedule
            oracle.decks.save(deck)
            oracle.sched.rebuild_filtered_deck(deck_id)
            if repeat_rebuild:
                oracle.sched.empty_filtered_deck(deck_id)
                oracle.db.execute("update cards set mod=43")
                oracle.sched.rebuild_filtered_deck(deck_id)
            filled = filtered_snapshot(oracle, deck_id)
            selected_ids = [row["id"] for row in filled]
            oracle.sched.empty_filtered_deck(deck_id)
            emptied = filtered_snapshot(oracle, deck_id, selected_ids)
            expected = {"filled": filled, "emptied": emptied}
        finally:
            oracle.close()

        args = ["filtered-rebuild", search, str(limit), order]
        if repeat_rebuild:
            args.append("--repeat-rebuild")
        if not reschedule:
            args.append("--no-reschedule")
        if search2:
            args.extend([f"--second-search={search2}", f"--second-limit={limit2}", f"--second-order={order2}"])
        actual = run_harness(swift_root, *args)
        expected["emptied"].sort(key=lambda row: row["id"])
        actual["emptied"].sort(key=lambda row: row["id"])
        if order == "random":
            for key in ("filled", "emptied"):
                expected[key] = [{name: value for name, value in row.items() if name != "due"} for row in expected[key]]
                actual[key] = [{name: value for name, value in row.items() if name != "due"} for row in actual[key]]
                expected[key].sort(key=lambda row: row["id"])
                actual[key].sort(key=lambda row: row["id"])
        problems += diff(f"filtered:{index}:{order}", expected, actual)
    return problems


def check_sync_actions():
    problems = []
    for action in ("set-due", "reset", "reposition", "reposition-siblings", "reposition-mixed", "reposition-suspended", "move"):
        oracle_path, swift_root = prepare("sched")
        oracle = Collection(oracle_path)
        try:
            oracle.db.execute("update cards set usn=43")
            if action == "set-due":
                cid = oracle.db.scalar("select id from cards where queue=0 order by id limit 1")
                oracle.sched.set_due_date([cid], "4")
            elif action == "reset":
                cid = oracle.db.scalar("select id from cards where queue=2 order by id limit 1")
                oracle.sched.schedule_cards_as_new([cid], restore_position=True)
            elif action == "reposition-siblings":
                ids = oracle.db.list("""
                    select id from cards
                    where nid=(
                        select nid from cards group by nid having count(*)>=2 order by nid limit 1
                    )
                    order by id limit 2
                """)
                oracle.db.execute(f"update cards set type=0, queue=0 where id in ({','.join('?' for _ in ids)})", *ids)
                oracle.sched.reposition_new_cards(ids, starting_from=5, step_size=2, randomize=False, shift_existing=False)
            elif action == "reposition-mixed":
                ids = [
                    oracle.db.scalar("select id from cards where queue=0 order by id limit 1"),
                    oracle.db.scalar("select id from cards where queue=2 order by id limit 1"),
                ]
                oracle.sched.reposition_new_cards(ids, starting_from=5, step_size=2, randomize=False, shift_existing=True)
            elif action == "reposition-suspended":
                cid = oracle.db.scalar("select id from cards where queue=0 order by id limit 1")
                oracle.db.execute("update cards set queue=-1 where id=?", cid)
                oracle.sched.reposition_new_cards([cid], starting_from=5, step_size=2, randomize=False, shift_existing=False)
            elif action == "reposition":
                cid = oracle.db.scalar("select id from cards where queue=0 order by due desc, id limit 1")
                oracle.sched.reposition_new_cards([cid], starting_from=5, step_size=2, randomize=False, shift_existing=True)
            else:
                cid = oracle.db.scalar("select id from cards order by id limit 1")
                oracle.set_deck([cid], oracle.decks.id("Lang::ES"))
            expected = [
                {"id": cid, "did": did, "type": card_type, "queue": queue, "due": due, "usn": usn}
                for cid, did, card_type, queue, due, usn in oracle.db.all(
                    "select id, did, type, queue, due, usn from cards where usn=-1 order by id"
                )
            ]
        finally:
            oracle.close()
        actual = run_harness(swift_root, "sync-actions", action)
        problems += diff(f"sync:{action}", expected, actual)
    return problems


def check_tag_actions():
    problems = []
    for action in ("add-existing", "add-new", "remove-missing", "remove-parent", "replace-missing", "replace-parent"):
        oracle_path, swift_root = prepare("sched")
        oracle = Collection(oracle_path)
        try:
            nid = oracle.db.scalar("select id from notes where tags like '%animal%' order by id limit 1")
            oracle.db.execute("update notes set usn=42 where id=?", nid)
            if action == "add-existing":
                oracle.tags.bulk_add([nid], "animal")
            elif action == "add-new":
                oracle.tags.bulk_add([nid], "newTag child::tag")
            elif action == "remove-missing":
                oracle.tags.bulk_remove([nid], "unknown")
            elif action == "remove-parent":
                oracle.tags.bulk_remove([nid], "animal")
            elif action == "replace-missing":
                oracle.tags.find_and_replace([nid], "unknown", "pet", regex=False, match_case=False)
            else:
                oracle.tags.find_and_replace([nid], "animal", "pet", regex=False, match_case=False)
            tags, usn = oracle.db.first("select tags, usn from notes where id=?", nid)
            expected = {"tags": tags, "usn": usn}
        finally:
            oracle.close()
        actual = run_harness(swift_root, "tag-actions", action)
        problems += diff(f"tags:{action}", expected, actual)
    return problems


def check_notetype_actions():
    problems = []
    for action in ("add-basic-reverse", "basic-reverse", "reverse-basic", "basic-cloze", "cloze-basic"):
        oracle_path, swift_root = prepare("sched")
        oracle = Collection(oracle_path)
        original_card_ids = []
        try:
            if action == "add-basic-reverse":
                target = oracle.models.by_name("Basic (and reversed card)")
                note = oracle.new_note(target)
                note.fields[0] = "Parity front"
                note.fields[1] = "Parity back"
                oracle.add_note(note, 1)
                nid = note.id
            else:
                if action == "basic-reverse":
                    source_name, target_name = "Basic", "Basic (and reversed card)"
                elif action == "reverse-basic":
                    source_name, target_name = "Basic (and reversed card)", "Basic"
                elif action == "basic-cloze":
                    source_name, target_name = "Basic", "Cloze"
                else:
                    source_name, target_name = "Cloze", "Basic"
                source = oracle.models.by_name(source_name)
                target = oracle.models.by_name(target_name)
                if action == "cloze-basic":
                    note = oracle.new_note(source)
                    note.guid = "parity-cloze-type"
                    note.fields[0] = "{{c1::one}} {{c2::two}}"
                    note.fields[1] = "extra"
                    oracle.add_note(note, oracle.decks.id("Math"))
                    nid = note.id
                else:
                    nid = oracle.db.scalar("select id from notes where mid=? order by id limit 1", source["id"])
                oracle.db.execute("update notes set usn=42 where id=?", nid)
                oracle.db.execute("update cards set usn=43 where nid=?", nid)
                original_card_ids = oracle.db.list("select id from cards where nid=? order by id", nid)
                request = oracle.models.change_notetype_info(
                    old_notetype_id=source["id"], new_notetype_id=target["id"]
                ).input
                request.note_ids.append(nid)
                oracle.models.change_notetype_of_notes(request)
            mid, fields, tags, note_usn = oracle.db.first(
                "select mid, flds, tags, usn from notes where id=?", nid
            )
            cards = [
                {"ord": ord, "type": card_type, "queue": queue, "due": due, "ivl": ivl,
                 "factor": factor, "reps": reps, "lapses": lapses, "usn": usn}
                for ord, card_type, queue, due, ivl, factor, reps, lapses, usn in oracle.db.all(
                    "select ord,type,queue,due,ivl,factor,reps,lapses,usn from cards where nid=? order by ord", nid
                )
            ]
            if original_card_ids:
                placeholders = ",".join("?" for _ in original_card_ids)
                removed = oracle.db.scalar(
                    f"select count(*) from graves where type=0 and oid in ({placeholders})", *original_card_ids
                )
            else:
                removed = 0
            expected = {
                "note": {"mid": mid, "fields": fields, "tags": tags, "usn": note_usn},
                "cards": cards,
                "removedCards": removed,
            }
        finally:
            oracle.close()
        actual = run_harness(swift_root, "notetype-actions", action)
        problems += diff(f"notetype:{action}", expected, actual)

    oracle_path, swift_root = prepare("sched")
    oracle = Collection(oracle_path)
    try:
        model = oracle.models.by_name("Basic")
        nid = oracle.db.scalar(
            "select n.id from notes n join cards c on c.nid=n.id where n.mid=? and c.queue=0 order by n.id limit 1",
            model["id"],
        )
        template = oracle.models.new_template("Parity added card")
        template["qfmt"] = "{{Back}}"
        template["afmt"] = "{{FrontSide}}"
        oracle.models.add_template(model, template)
        oracle.models.update(model)
        expected = [
            {"ord": ord, "did": did, "type": card_type, "queue": queue, "due": due, "usn": usn}
            for ord, did, card_type, queue, due, usn in oracle.db.all(
                "select ord, did, type, queue, due, usn from cards where nid=? order by ord", nid
            )
        ]
    finally:
        oracle.close()
    actual = run_harness(swift_root, "notetype-schema-actions")
    problems += diff("notetype:add-template", expected, actual)
    return problems


def check_notetype_delete_actions():
    oracle_path, swift_root = prepare("sched")
    oracle = Collection(oracle_path)
    try:
        notetype = oracle.models.by_name("Basic (and reversed card)")
        note_ids = oracle.db.list("select id from notes where mid=? order by id", notetype["id"])
        card_ids = oracle.db.list(
            f"select id from cards where nid in ({','.join('?' for _ in note_ids)}) order by id",
            *note_ids,
        )
        revlog_id = oracle.db.scalar("select coalesce(max(id), 0) + 1 from revlog")
        oracle.db.execute(
            "insert into revlog values(?,?,?,?,?,?,?,?,?)",
            revlog_id, card_ids[0], -1, 3, 3, 1, 2500, 6000, 1,
        )
        oracle.set_config("curModel", notetype["id"])
        oracle.set_aux_notetype_config(notetype["id"], "lastDeckAddedTo", 1)

        def snapshot():
            models = oracle.models.all()
            current_id = oracle.get_config("curModel")
            current_name = next((model["name"] for model in models if model["id"] == current_id), None)
            card_placeholders = ",".join("?" for _ in card_ids)
            note_placeholders = ",".join("?" for _ in note_ids)
            return {
                "notetypes": sorted(model["name"] for model in models),
                "notes": oracle.db.scalar("select count(*) from notes where mid=?", notetype["id"]),
                "cards": oracle.db.scalar(
                    f"select count(*) from cards where nid in ({note_placeholders})", *note_ids
                ),
                "noteGraves": oracle.db.scalar(
                    f"select count(*) from graves where type=1 and oid in ({note_placeholders})", *note_ids
                ),
                "cardGraves": oracle.db.scalar(
                    f"select count(*) from graves where type=0 and oid in ({card_placeholders})", *card_ids
                ),
                "revlogs": oracle.db.scalar(
                    f"select count(*) from revlog where cid in ({card_placeholders})", *card_ids
                ),
                "currentModel": current_name,
                "auxiliaryConfigPresent": oracle.get_aux_notetype_config(
                    notetype["id"], "lastDeckAddedTo", default=None
                ) is not None,
                "rememberedDeckPresent": oracle.get_aux_notetype_config(
                    notetype["id"], "lastDeckAddedTo", default=None
                ) is not None,
            }

        before = snapshot()
        oracle.models.remove(notetype["id"])
        after = snapshot()
        oracle.undo()
        undone = snapshot()
        oracle.redo()
        redone = snapshot()
        expected = {"before": before, "after": after, "undone": undone, "redone": redone}
    finally:
        oracle.close()
    actual = run_harness(swift_root, "notetype-delete-actions")
    return diff("notetype:delete", expected, actual)


def check_latex_extraction():
    oracle_path, swift_root = prepare("sched")
    oracle = Collection(oracle_path)
    cases = [
        ("a[latex]one<br>and<div>two[/latex]b", False, False),
        ("[$]<b>hello</b>&nbsp; world[/$]", True, False),
        ("[$$]math &amp; stuff[/$$]", False, False),
        ("[LATEX]\u03b1 &lt; \u03b2[/LATEX]", False, False),
        ("No LaTeX here", False, False),
        ("[$]x + {{c1::2}}[/$]", False, True),
    ]
    problems = []
    try:
        for index, (source, svg, expand_clozes) in enumerate(cases):
            output = oracle._backend.extract_latex(
                text=source, svg=svg, expand_clozes=expand_clozes
            )
            expected = {
                "html": output.text,
                "assets": [
                    {"filename": item.filename, "body": item.latex_body}
                    for item in output.latex
                ],
            }
            args = ["latex-extract", source]
            if svg:
                args.append("--svg")
            if expand_clozes:
                args.append("--expand-clozes")
            actual = run_harness(swift_root, *args)
            problems += diff(f"latex:{index}", expected, actual)
    finally:
        oracle.close()
    return problems


def check_csv():
    oracle_path, swift_root = prepare("sched")
    app_base_path = os.path.join(WORK, "sched.anki2")
    work = os.path.join(WORK, "csv")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    app_export = os.path.join(work, "app-notes.tsv")
    run_harness(swift_root, "csv-export", app_export)
    official_export = os.path.join(work, "official-notes.tsv")
    official = Collection(oracle_path)
    try:
        official.export_note_csv(
            out_path=official_export,
            limit=None,
            with_html=True,
            with_tags=True,
            with_deck=True,
            with_notetype=True,
            with_guid=True,
        )
    finally:
        official.close()
    with open(app_export, encoding="utf-8") as file:
        app_text = file.read()
    with open(official_export, encoding="utf-8") as file:
        official_text = file.read()
    problems = diff("csv:export", official_text.splitlines(), app_text.splitlines())

    csv_path = os.path.join(work, "import.csv")
    with open(csv_path, "w", encoding="utf-8", newline="") as file:
        file.write(
            "#separator:comma\n"
            "#deck:Lang\n"
            "#notetype:Basic\n"
            "#tags:globalTag\n"
            "#columns:Front,Back,Tags\n"
            '"Lang front 0","CSV, updated","rowTag"\n'
            '"CSV new","new, value","newTag"\n'
        )
    scenarios = [("update", 0), ("ignore", 1), ("importAsNew", 2)]
    for policy, official_resolution in scenarios:
        case = f"csv-{policy}"
        official_path = os.path.join(work, f"{case}-official.anki2")
        shutil.copy2(oracle_path, official_path)
        official = Collection(official_path)
        try:
            official.db.execute("update notes set usn=42")
            metadata = official.get_csv_metadata(csv_path, None)
            metadata.dupe_resolution = official_resolution
            metadata.match_scope = 0
            official.import_csv(ImportCsvRequest(path=csv_path, metadata=metadata))
        finally:
            official.close()

        case_root = os.path.join(work, f"{case}-swift")
        os.makedirs(os.path.join(case_root, "User 1"))
        swift_path = os.path.join(case_root, "User 1", "collection.anki2")
        shutil.copy2(app_base_path, swift_path)
        swift_db = sqlite3.connect(swift_path)
        try:
            swift_db.execute("update notes set usn=42")
            swift_db.commit()
        finally:
            swift_db.close()
        result = run_harness(case_root, "csv-import", csv_path, f"--policy={policy}")
        official_snapshot = csv_collection_snapshot(official_path)
        swift_snapshot = csv_collection_snapshot(swift_path)
        problems += diff(f"csv:{policy}", official_snapshot, swift_snapshot)
        if result["notes"] != len(swift_snapshot["notes"]) or result["cards"] != len(swift_snapshot["cards"]):
            problems.append(f"csv:{policy}: harness counts do not match the imported collection")

    normalized_csv = os.path.join(work, "normalized-deck.csv")
    with open(normalized_csv, "w", encoding="utf-8", newline="") as file:
        file.write(
            "#separator:comma\n"
            "#deck:lANG::New::::Leaf\n"
            "#notetype:Basic\n"
            "#columns:Front,Back\n"
            '"CSV normalized deck","nested import"\n'
        )
    official_path = os.path.join(work, "csv-normalized-official.anki2")
    shutil.copy2(oracle_path, official_path)
    official = Collection(official_path)
    try:
        metadata = official.get_csv_metadata(normalized_csv, None)
        metadata.dupe_resolution = 0
        metadata.match_scope = 0
        official.import_csv(ImportCsvRequest(path=normalized_csv, metadata=metadata))
    finally:
        official.close()
    case_root = os.path.join(work, "csv-normalized-swift")
    os.makedirs(os.path.join(case_root, "User 1"))
    swift_path = os.path.join(case_root, "User 1", "collection.anki2")
    shutil.copy2(app_base_path, swift_path)
    run_harness(case_root, "csv-import", normalized_csv)
    problems += diff(
        "csv:normalized-deck",
        csv_collection_snapshot(official_path),
        csv_collection_snapshot(swift_path),
    )
    return problems


def check_packages():
    oracle_path, swift_root = prepare("sched")
    package_work = os.path.join(WORK, "packages")
    shutil.rmtree(package_work, ignore_errors=True)
    os.makedirs(package_work)
    from anki.media import media_paths_from_col_path

    oracle_media, _ = media_paths_from_col_path(oracle_path)
    os.makedirs(oracle_media, exist_ok=True)
    png = b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\x0bIDATx\x9cc`\x00\x02\x00\x00\x05\x00\x01\xa5\xf6E@\x00\x00\x00\x00IEND\xaeB`\x82"
    with open(os.path.join(oracle_media, "parity.png"), "wb") as file:
        file.write(png)
    source = Collection(oracle_path)
    try:
        note = source.new_note(source.models.by_name("Basic"))
        note.fields[0] = 'media parity <img src="parity.png">'
        note.fields[1] = "media parity"
        source.add_note(note, source.decks.id("Lang"))
        existing_new = source.db.scalar("select id from cards where type=0 and queue=0 order by id limit 1")
        first_review = source.db.scalar("select id from cards where queue=2 order by id limit 1")
        source.db.execute("update cards set flags=3 where id=?", existing_new)
        source.db.execute(
            "update cards set flags=5, data=? where id=?",
            '{"cd":"{\\"v\\":\\"reschedule\\",\\"d\\":7}"}',
            first_review,
        )
    finally:
        source.close(downgrade=True)
    swift_collection = os.path.join(swift_root, "User 1", "collection.anki2")
    shutil.copy2(oracle_path, swift_collection)
    swift_media = os.path.join(swift_root, "User 1", "collection.media")
    shutil.rmtree(swift_media, ignore_errors=True)
    shutil.copytree(oracle_media, swift_media)

    app_package = os.path.join(package_work, "app-export.apkg")
    run_harness(swift_root, "export", app_package, "--scheduling", "--presets")

    app_export_imported_path = os.path.join(package_work, "app-export-imported.anki2")
    app_export_imported = Collection(app_export_imported_path)
    try:
        app_export_imported.import_anki_package(
            ImportAnkiPackageRequest(
                package_path=app_package,
                options=ImportAnkiPackageOptions(
                    merge_notetypes=True,
                    with_scheduling=True,
                    with_deck_configs=True,
                ),
            )
        )
    finally:
        app_export_imported.close()

    official_package = os.path.join(package_work, "official-export.apkg")
    source = Collection(oracle_path)
    try:
        source.export_anki_package(
            out_path=official_package,
            options=ExportAnkiPackageOptions(
                with_scheduling=True,
                with_deck_configs=True,
                with_media=True,
                legacy=False,
            ),
            limit=None,
        )
    finally:
        source.close()

    swift_import_root = os.path.join(package_work, "official-import-swift")
    os.makedirs(os.path.join(swift_import_root, "User 1"))
    run_harness(
        swift_import_root,
        "import",
        official_package,
        "--scheduling",
        "--presets",
        "--merge-notetypes",
    )
    swift_import_path = os.path.join(swift_import_root, "User 1", "collection.anki2")

    expected = package_snapshot(oracle_path, oracle_media)
    from anki.media import media_paths_from_col_path
    app_export_media, _ = media_paths_from_col_path(app_export_imported_path)
    app_to_official = package_snapshot(app_export_imported_path, app_export_media)
    app_import_media = os.path.join(swift_import_root, "User 1", "collection.media")
    official_to_app = package_snapshot(swift_import_path, app_import_media)

    app_default_package = os.path.join(package_work, "app-default-export.apkg")
    run_harness(swift_root, "export", app_default_package, "--no-media")
    app_default_import_path = os.path.join(package_work, "app-default-imported.anki2")
    app_default_import = Collection(app_default_import_path)
    try:
        app_default_import.import_anki_package(
            ImportAnkiPackageRequest(
                package_path=app_default_package,
                options=ImportAnkiPackageOptions(
                    merge_notetypes=True,
                    with_scheduling=True,
                    with_deck_configs=True,
                ),
            )
        )
    finally:
        app_default_import.close()
    source = Collection(oracle_path)
    official_default_package = os.path.join(package_work, "official-default-export.apkg")
    try:
        source.export_anki_package(
            out_path=official_default_package,
            options=ExportAnkiPackageOptions(
                with_scheduling=False,
                with_deck_configs=False,
                with_media=False,
                legacy=False,
            ),
            limit=None,
        )
    finally:
        source.close()
    official_default_import_path = os.path.join(package_work, "official-default-imported.anki2")
    official_default_import = Collection(official_default_import_path)
    try:
        official_default_import.import_anki_package(
            ImportAnkiPackageRequest(
                package_path=official_default_package,
                options=ImportAnkiPackageOptions(
                    merge_notetypes=True,
                    with_scheduling=True,
                    with_deck_configs=True,
                ),
            )
        )
    finally:
        official_default_import.close()
    default_app_media, _ = media_paths_from_col_path(app_default_import_path)
    default_official_media, _ = media_paths_from_col_path(official_default_import_path)
    app_default_snapshot = package_snapshot(app_default_import_path, default_app_media)
    official_default_snapshot = package_snapshot(official_default_import_path, default_official_media)

    official_colpkg = os.path.join(package_work, "official-export.colpkg")
    source = Collection(oracle_path)
    source.export_collection_package(out_path=official_colpkg, include_media=True, legacy=False)
    source.close()
    colpkg_import_root = os.path.join(package_work, "colpkg-import-swift")
    os.makedirs(os.path.join(colpkg_import_root, "User 1"))
    run_harness(colpkg_import_root, "import", official_colpkg)
    colpkg_import_path = os.path.join(colpkg_import_root, "User 1", "collection.anki2")
    colpkg_import_media = os.path.join(colpkg_import_root, "User 1", "collection.media")
    official_colpkg_to_app = package_snapshot(colpkg_import_path, colpkg_import_media)
    problems = diff("packages:app-to-official", expected, app_to_official)
    problems += diff("packages:official-to-app", expected, official_to_app)
    problems += diff("packages:default-export", official_default_snapshot, app_default_snapshot)
    problems += diff("packages:colpkg-to-app", expected, official_colpkg_to_app)

    backup_result = run_harness(swift_root, "backup")
    backup_restore_path = os.path.join(package_work, "automatic-backup-restored.anki2")
    restored = Collection(backup_restore_path)
    backup_media, backup_media_db = media_paths_from_col_path(restored.path)
    try:
        restored.close()
        restored._backend.import_collection_package(
            col_path=restored.path,
            backup_path=backup_result["path"],
            media_folder=backup_media,
            media_db=backup_media_db,
        )
        restored.reopen()
    finally:
        restored.close()
    automatic_backup = package_snapshot(backup_restore_path, backup_media)
    expected_backup = dict(expected)
    expected_backup["media"] = []
    problems += diff("packages:automatic-backup", expected_backup, automatic_backup)
    problems += check_package_update_conditions()
    problems += check_package_notetype_conditions_without_merge()
    problems += check_package_schema_merge()

    real_package = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "Learn_Hiragana.apkg"))
    if os.path.isfile(real_package):
        real_work = os.path.join(WORK, "real-anki-deck")
        shutil.rmtree(real_work, ignore_errors=True)
        os.makedirs(real_work)
        official_path = os.path.join(real_work, "official.anki2")
        official = Collection(official_path)
        try:
            official.import_anki_package(
                ImportAnkiPackageRequest(
                    package_path=real_package,
                    options=ImportAnkiPackageOptions(),
                )
            )
        finally:
            official.close()
        official_media, _ = media_paths_from_col_path(official_path)

        swift_root = os.path.join(real_work, "ankios")
        os.makedirs(os.path.join(swift_root, "User 1"))
        run_harness(swift_root, "import", real_package)
        swift_path = os.path.join(swift_root, "User 1", "collection.anki2")
        swift_media = os.path.join(swift_root, "User 1", "collection.media")
        problems += diff(
            "packages:real-anki-deck",
            package_snapshot(official_path, official_media),
            package_snapshot(swift_path, swift_media),
        )
    return problems


def check(fixture, command):
    oracle_path, swift_root = prepare(fixture)
    col = Collection(oracle_path)
    try:
        if command == "search":
            prepare_field_search_cases(col, swift_root)
            queries = search_queries(col)
            expected = {query: sorted(col.find_cards(query)) for query in queries}
            actual = run_harness(swift_root, "search-batch", json.dumps(queries))
            for query in INVALID_SEARCH_QUERIES:
                try:
                    col.find_cards(query)
                    expected_invalid = False
                except Exception:
                    expected_invalid = True
                proc = subprocess.run(
                    [HARNESS, "search", query],
                    capture_output=True,
                    text=True,
                    env=dict(os.environ, ANKIOS_PROFILES_ROOT=swift_root),
                )
                if (proc.returncode != 0) != expected_invalid:
                    return [f"{fixture}:search/{query}: invalidez do operador diverge do Anki"]
        else:
            actual = run_harness(swift_root, command)
            expected = {
                "timing": oracle_timing,
                "counts": oracle_counts,
                "states": oracle_states,
                "session": oracle_session,
                "retention": oracle_retention,
                "stats": oracle_stats,
            }[command](col)
    finally:
        col.close()
    return diff(f"{fixture}:{command}", expected, actual)


def main():
    set_lang("pt_BR")
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    checks = args or ["all"]
    if checks == ["all"]:
        checks = ["timing", "counts", "states", "fsrs-empty-steps", "grade-now", "session", "search", "retention", "stats", "cardgen", "templates", "decks", "delete", "empty", "queue", "sync", "tags", "notetypes", "latex", "filtered", "packages", "csv"]
    total = 0
    for command in checks:
        if command == "grade-now":
            problems = check_grade_now()
        elif command == "fsrs-empty-steps":
            problems = check_fsrs_empty_steps()
        elif command == "packages":
            problems = check_packages()
        elif command == "csv":
            problems = check_csv()
        elif command == "filtered":
            problems = check_filtered()
        elif command == "delete":
            problems = check_delete_actions()
        elif command == "decks":
            problems = check_deck_actions()
        elif command == "cardgen":
            problems = check_cardgen_actions()
        elif command == "templates":
            problems = check_templates()
        elif command == "empty":
            problems = check_empty_actions()
        elif command == "queue":
            problems = check_queue_actions()
        elif command == "sync":
            problems = check_sync_actions()
        elif command == "tags":
            problems = check_tag_actions()
        elif command == "notetypes":
            problems = check_notetype_actions() + check_notetype_delete_actions()
        elif command == "latex":
            problems = check_latex_extraction()
        else:
            problems = check("sched", command)
        total += len(problems)
        print(f"== {command}: {'OK' if not problems else f'{len(problems)} differences'}")
        for p in problems[:200]:
            print("  " + p)
    sys.exit(1 if total else 0)


if __name__ == "__main__":
    main()
