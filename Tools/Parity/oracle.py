#!/usr/bin/env python3
"""Differential parity checks: AnkiOS (ankios-harness) vs the official Anki library.

Usage: oracle.py <check> [--keep]
Checks: timing, counts, states, fsrs-empty-steps, session, search, retention, stats, cardgen, decks, deck-options, rich-media, delete, empty, queue, sync, icloud-merge, icloud-sync, tags, notetypes, latex, filtered, filtered-options, packages, deck-export, card-export, csv, auto-advance-actions, auto-advance-timers, review-shortcuts, korean-shortcuts, media-check, database-check, profiles, all

Requires the `anki` wheel matching the targeted desktop release (26.9.3) and the
harness built by build-harness.sh.
"""
import json
import hashlib
import html
import os
import re
import shutil
import sqlite3
import struct
import subprocess
import sys
import tempfile
import time
import zipfile
from html.parser import HTMLParser

from anki.collection import (
    CardIdsLimit,
    Collection,
    DeckIdLimit,
    ExportAnkiPackageOptions,
    ImportCsvRequest,
    ImportAnkiPackageOptions,
    ImportAnkiPackageRequest,
    NoteIdsLimit,
)
from anki.deck_config_pb2 import UpdateDeckConfigsMode, UpdateDeckConfigsRequest
from anki.decks_pb2 import Deck
from anki.lang import get_def_lang, is_rtl, lang_to_disk_lang, langs, set_lang
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


def check_study_undo():
    oracle_path, swift_root = prepare("sched")
    col = Collection(oracle_path)
    started_at = int(time.time())
    try:
        deck_id = col.decks.id_for_name("Lang")
        col.decks.set_current(deck_id)
        queued = col.sched.get_queued_cards(fetch_limit=1)
        if not queued.cards:
            return ["sched:study-undo: fixture has no queued card"]
        card_id = queued.cards[0].card.id
        card_ids = col.db.list("select id from cards where nid=(select nid from cards where id=?) order by id", card_id)

        def snapshot():
            state = grade_now_snapshot(col, card_ids)
            queue = col.sched.get_queued_cards(fetch_limit=1)
            state["queueCounts"] = [queue.new_count, queue.learning_count, queue.review_count]
            state["nextCardID"] = queue.cards[0].card.id if queue.cards else 0
            return state

        before = snapshot()
        card = col.get_card(card_id)
        card.start_timer()
        states = col._backend.get_scheduling_states(card_id)
        answer = col.sched.build_answer(card=card, states=states, rating=CardAnswer.GOOD)
        answer.milliseconds_taken = 5_000
        col.sched.answer_card(answer)
        expected = {"before": before, "after": snapshot()}
        col.undo()
        expected["undone"] = snapshot()
        col.redo()
        expected["redone"] = snapshot()
    finally:
        col.close()

    actual = run_harness(swift_root, "study-undo", str(deck_id), str(card_id))
    finished_at = int(time.time())
    for snapshot in (expected, actual):
        for phase in snapshot.values():
            for card in phase["cards"]:
                data = json.loads(card["data"] or "{}")
                if isinstance(data.get("lrt"), (int, float)) and started_at <= data["lrt"] <= finished_at:
                    data["lrt"] = "current-operation"
                card["data"] = json.dumps(data, sort_keys=True)
    actual["before"] = before
    return diff("sched:study-undo", expected, actual)


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
    oracle_path = os.path.join(WORK, f"{fixture}-oracle.anki2")
    from anki.media import media_paths_from_col_path

    for path in (base, oracle_path):
        for suffix in ("", "-wal", "-shm"):
            try:
                os.remove(path + suffix)
            except FileNotFoundError:
                pass
        media_path, media_db = media_paths_from_col_path(path)
        shutil.rmtree(media_path, ignore_errors=True)
        for suffix in ("", "-wal", "-shm"):
            try:
                os.remove(media_db + suffix)
            except FileNotFoundError:
                pass
    if os.path.exists(base):
        os.remove(base)
    set_lang("en")
    FIXTURES[fixture](base)
    set_lang("pt_BR")
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


def card_render_snapshot(col, guids=None, include_answer_sounds=False):
    allowed = set(guids) if guids is not None else None

    def visible_text(value):
        value = re.sub(r"(?is)<(script|style)\b[^>]*>.*?</\1>", " ", value)
        value = re.sub(r"(?s)<!--.*?-->", " ", value)
        value = re.sub(r"(?i)\[sound:[^\]]+\]", " ", value)
        value = re.sub(r"<[^>]*>", " ", value)
        return re.sub(r"\s+", " ", html.unescape(value)).strip()

    result = []
    rows = col.db.all("""
        select c.id, c.ord, n.guid from cards c join notes n on n.id=c.nid
        order by n.guid, c.ord
    """)
    for card_id, ordinal, guid in rows:
        if allowed is not None and guid not in allowed:
            continue
        rendered = col._backend.render_existing_card(
            card_id=card_id, browser=False, partial_render=False
        )
        question_html = "".join(node.text for node in rendered.question_nodes)
        answer_html = "".join(node.text for node in rendered.answer_nodes)
        question_text = visible_text(question_html)
        marker = re.search(r"<hr\b[^>]*\bid\s*=\s*['\"]?answer['\"]?[^>]*>", answer_html, re.I)
        if marker:
            answer_text = visible_text(answer_html[marker.end():])
            answer_sounds = re.findall(r"(?i)\[sound:([^\]]+)\]", answer_html[marker.end():])
        else:
            combined = visible_text(answer_html)
            answer_text = combined[len(question_text):].strip() if combined.startswith(question_text) else combined
            answer_sounds = re.findall(r"(?i)\[sound:([^\]]+)\]", answer_html)
        sounds = re.findall(r"(?i)\[sound:([^\]]+)\]", question_html)
        snapshot = {
            "guid": guid,
            "ordinal": ordinal,
            "questionText": question_text,
            "answerText": answer_text,
            "questionSounds": sounds,
        }
        if include_answer_sounds:
            snapshot["answerSounds"] = answer_sounds
        result.append(snapshot)
    return result


class ImageOcclusionAttributeParser(HTMLParser):
    attributes = (
        "data-ordinal", "data-shape", "data-left", "data-top", "data-angle", "data-fill",
        "data-width", "data-height", "data-rx", "data-ry", "data-points",
        "data-occludeinactive", "data-text", "data-scale", "data-font-size",
    )

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.rows = []

    def handle_starttag(self, tag, attributes):
        values = dict(attributes)
        if "data-shape" not in values:
            return
        self.rows.append({key: values[key] for key in self.attributes if key in values})


class ImageOcclusionStateParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.rows = []

    def handle_starttag(self, tag, attributes):
        values = dict(attributes)
        if "data-shape" not in values:
            return
        self.rows.append(values)


def image_occlusion_behavior_from_html(value):
    parser = ImageOcclusionStateParser()
    parser.feed(value)
    states = []
    for item in parser.rows:
        classes = set(item.get("class", "").split())
        state = next(
            (name for name in ("revealed", "covered", "hidden") if f"io-{name}" in classes),
            "missing",
        )
        states.append({
            "ordinal": item.get("data-ordinal", ""),
            "shape": item.get("data-shape", ""),
            "state": state,
        })
    return sorted(states, key=lambda item: (int(item["ordinal"] or 0), item["shape"]))


def image_occlusion_render_snapshot(col, guid):
    result = {}
    rows = col.db.all("""
        select c.id, c.ord from cards c join notes n on n.id=c.nid
        where n.guid=? order by c.ord
    """, guid)
    for card_id, ordinal in rows:
        rendered = col._backend.render_existing_card(
            card_id=card_id, browser=False, partial_render=False
        )
        parser = ImageOcclusionAttributeParser()
        parser.feed("".join(node.text for node in rendered.question_nodes))
        result[str(ordinal)] = sorted(
            parser.rows,
            key=lambda row: (int(row.get("data-ordinal", "0")), row.get("data-shape", "")),
        )
    return result


def image_occlusion_behavior_snapshot(col, guid):
    result = {}
    rows = col.db.all("""
        select c.id, c.ord from cards c join notes n on n.id=c.nid
        where n.guid=? order by c.ord
    """, guid)
    for card_id, ordinal in rows:
        rendered = col._backend.render_existing_card(
            card_id=card_id, browser=False, partial_render=False
        )
        card_states = {}
        for side, nodes in (("question", rendered.question_nodes), ("answer", rendered.answer_nodes)):
            parser = ImageOcclusionStateParser()
            parser.feed("".join(node.text for node in nodes))
            states = []
            for item in parser.rows:
                classes = set(item.get("class", "").split())
                inactive_is_covered = item.get("data-occludeinactive", "").lower() == "1"
                active = "cloze" in classes if side == "question" else "cloze-highlight" in classes
                state = "revealed" if side == "answer" and active else (
                    "covered" if active or inactive_is_covered else "hidden"
                )
                states.append({
                    "ordinal": item.get("data-ordinal", ""),
                    "shape": item.get("data-shape", ""),
                    "state": state,
                })
            card_states[side] = sorted(states, key=lambda item: (int(item["ordinal"] or 0), item["shape"]))
        result[str(ordinal)] = card_states
    return result


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


def check_browser_sort():
    oracle_path, swift_root = prepare("sched")
    oracle = Collection(oracle_path)
    try:
        card_columns = [
            "noteFld", "cardDue", "noteCrt", "cardMod", "cardIvl", "deck", "cardEase",
            "cardReps", "cardLapses", "template", "note", "noteTags", "originalPosition",
            "stability", "difficulty", "retrievability",
        ]
        note_columns = [
            "noteFld", "cardDue", "noteCrt", "noteMod", "cardIvl", "deck", "cardEase",
            "cardReps", "cardLapses", "template", "note", "noteTags", "originalPosition",
        ]

        def expected_orders(columns, find_rows):
            orders = {}
            for column in columns:
                orders[column] = {}
                for descending in (False, True):
                    rows = find_rows(oracle, column, descending)
                    orders[column]["descending" if descending else "ascending"] = [int(row) for row in rows]
            return orders

        expected_cards = expected_orders(
            card_columns,
            lambda col, column, descending: col.find_cards(
                "", order=col.get_browser_column(column), reverse=descending
            ),
        )
        expected_notes = expected_orders(
            note_columns,
            lambda col, column, descending: col.find_notes(
                "", order=col.get_browser_column(column), reverse=descending
            ),
        )
        expected_round_trips = []
        for notes_mode, columns in ((False, card_columns), (True, note_columns)):
            for column in columns:
                for descending in (False, True):
                    expected_round_trips.append({
                        "notesMode": notes_mode,
                        "column": column,
                        "descending": descending,
                        "persistedSortType": column,
                        "persistedDirection": descending,
                        "loadedColumn": column,
                        "loadedDescending": descending,
                    })
        expected = {
            "cardOrders": expected_cards,
            "noteOrders": expected_notes,
            "preferenceRoundTrips": expected_round_trips,
            "legacyPreference": {"column": "cardMod", "descending": True},
            "importedPreference": {"column": "noteCrt", "descending": False},
        }
    finally:
        oracle.close()

    actual = run_harness(swift_root, "browser-sort-actions")
    problems = diff("browser:sort", expected, actual)
    actual_collection_path = os.path.join(swift_root, "User 1", "collection.anki2")
    actual_collection = Collection(actual_collection_path)
    try:
        persisted = {
            "sortType": actual_collection.conf.get("sortType"),
            "sortBackwards": actual_collection.conf.get("sortBackwards"),
            "noteSortType": actual_collection.conf.get("noteSortType"),
            "browserNoteSortBackwards": actual_collection.conf.get("browserNoteSortBackwards"),
        }
        problems += diff("browser:sort/persisted-wire", {
            "sortType": "noteFld",
            "sortBackwards": False,
            "noteSortType": "noteMod",
            "browserNoteSortBackwards": True,
        }, persisted)
    finally:
        actual_collection.close()
    return problems


def check_browser_selection():
    oracle_path, swift_root = prepare("sched")
    oracle = Collection(oracle_path)
    deck_id = oracle.decks.id("Lang")
    basic = oracle.models.by_name("Basic")
    reversed_model = oracle.models.by_name("Basic (and reversed card)")

    def add_selection_set(tag, prefix):
        for i in range(512):
            note = oracle.new_note(basic)
            note.fields = [f"{prefix} {i:03d}", "back"]
            note.tags = [tag]
            oracle.add_note(note, deck_id)
        for i in range(4):
            note = oracle.new_note(reversed_model)
            note.fields = [f"{prefix} Multi {i}", "back"]
            note.tags = [tag]
            oracle.add_note(note, deck_id)

    add_selection_set("parity-card-selection", "CardSelection")
    add_selection_set("parity-note-selection", "NoteSelection")
    column = oracle.get_browser_column("noteFld")

    def selection_snapshot(query, notes_mode):
        rows = list(map(int, oracle.find_notes(query, order=column))) if notes_mode else list(map(int, oracle.find_cards(query, order=column)))
        if notes_mode:
            rows = [int(oracle.db.scalar("select min(id) from cards where nid=?", nid)) for nid in rows]
        indices = sorted(set(index for index in (0, 2, 499, 500, len(rows) - 1) if 0 <= index < len(rows)))
        selected = [rows[index] for index in indices]
        selected_set = set(selected)
        inverted = [row_id for row_id in rows if row_id not in selected_set]

        def target_cards(row_ids):
            if not notes_mode:
                return sorted(row_ids)
            selected_notes = sorted({int(oracle.db.scalar("select nid from cards where id=?", row_id)) for row_id in row_ids})
            if not selected_notes:
                return []
            placeholders = ",".join("?" for _ in selected_notes)
            return list(map(int, oracle.db.list(
                f"select id from cards where nid in ({placeholders}) order by id",
                *selected_notes,
            )))

        selected_cards = target_cards(selected)
        inverted_cards = target_cards(inverted)
        oracle.sched.suspend_cards(selected_cards)
        oracle.sched.bury_cards(inverted_cards)
        all_cards = sorted(set(selected_cards + inverted_cards))
        placeholders = ",".join("?" for _ in all_cards)
        states = [
            list(row)
            for row in oracle.db.all(
                f"select id, queue, due, usn from cards where id in ({placeholders}) order by id",
                *all_cards,
            )
        ]
        return {
            "rowCount": len(rows),
            "selectedRows": selected,
            "invertedRows": inverted,
            "selectedCards": selected_cards,
            "invertedCards": inverted_cards,
            "states": states,
        }

    expected = {
        "cardsMode": selection_snapshot("tag:parity-card-selection", False),
        "notesMode": selection_snapshot("tag:parity-note-selection", True),
    }
    oracle.close(downgrade=True)
    app_path = os.path.join(swift_root, "User 1", "collection.anki2")
    shutil.copy2(oracle_path, app_path)
    actual = run_harness(swift_root, "browser-selection-actions")
    return diff("browser:selection-actions", expected, actual)


def check_preferences_persist():
    oracle_path, swift_root = prepare("sched")
    oracle = Collection(oracle_path)
    prefs = oracle.get_preferences()
    prefs.scheduling.rollover = 8
    prefs.scheduling.learn_ahead_secs = 1020
    prefs.scheduling.new_review_mix = 0
    prefs.scheduling.day_learn_first = True
    prefs.scheduling.new_timezone = True
    prefs.reviewing.hide_audio_play_buttons = True
    prefs.reviewing.interrupt_audio_when_answering = False
    prefs.reviewing.show_remaining_due_counts = False
    prefs.reviewing.show_intervals_on_buttons = True
    prefs.reviewing.time_limit_secs = 660
    prefs.reviewing.load_balancer_enabled = False
    prefs.reviewing.fsrs_short_term_with_steps_enabled = True
    prefs.editing.adding_defaults_to_current_deck = False
    prefs.editing.paste_images_as_png = True
    prefs.editing.paste_strips_formatting = True
    prefs.editing.default_search_text = "deck:Lang"
    prefs.editing.ignore_accents_in_search = True
    prefs.editing.render_latex = True
    prefs.backups.minimum_interval_mins = 17
    prefs.backups.daily = 8
    prefs.backups.weekly = 6
    prefs.backups.monthly = 4
    oracle.set_preferences(prefs)
    oracle.set_config("applyAllParentLimits", True)
    oracle.set_config("fsrs", True)
    expected_timezone_offset = oracle.all_config().get("creationOffset")
    oracle.close()

    app_collection_path = os.path.join(swift_root, "User 1", "collection.anki2")
    app_db = sqlite3.connect(app_collection_path)
    legacy_meta = app_db.execute("select models, decks, dconf, tags from col").fetchone()
    app_db.close()
    app_seed = Collection(app_collection_path)
    try:
        app_seed.set_preferences(prefs)
        app_seed.set_config("applyAllParentLimits", True)
        app_seed.set_config("fsrs", True)
        seeded_config = app_seed.all_config()
    finally:
        app_seed.close()
    app_db = sqlite3.connect(app_collection_path)
    try:
        app_db.execute(
            "update col set conf=?, models=?, decks=?, dconf=?, tags=?",
            (json.dumps(seeded_config), *legacy_meta),
        )
        app_db.commit()
    finally:
        app_db.close()
    expected_loaded = {
        "rollover": 8,
        "collapseTime": 1020,
        "newSpread": 0,
        "hideAudioPlayButtons": True,
        "interruptAudioWhenAnswering": False,
        "dueCounts": False,
        "estTimes": True,
        "timeLim": 660,
        "addToCur": False,
        "applyAllParentLimits": True,
        "fsrs": True,
        "fsrsShortTermWithStepsEnabled": True,
        "pasteImagesAsPng": True,
        "pasteStripsFormatting": True,
        "defaultSearchText": "deck:Lang",
        "ignoreAccentsInSearch": True,
        "renderLatex": True,
        "dayLearnFirst": True,
        "newTimezone": True,
        "creationOffset": expected_timezone_offset,
        "loadBalancerEnabled": False,
        "backups": {
            "minimum_interval_mins": 17,
            "daily": 8,
            "weekly": 6,
            "monthly": 4,
        },
    }
    language_actual = run_harness(swift_root, "language-catalog")
    language_expected = {
        "languages": [
            {"name": name, "code": code, "rtl": is_rtl(lang_to_disk_lang(code))}
            for name, code in langs
        ],
        "defaultLanguageCode": get_def_lang()[1],
        "preferredLanguageMappings": {
            "pt-BR": "pt_BR",
            "fr-CA": "fr_FR",
            "zh-Hans-SG": "zh_CN",
            "zh-Hant-HK": "zh_TW",
            "nb-NO": "nb_NO",
            "nb": "",
            "unknown": "",
        },
        "defaultFromPreferredLanguage": "fr_FR",
        "defaultFromNorwegianSystemLanguage": "nb_NO",
        "environmentOverridesPreferredLanguage": "pt_BR",
    }
    problems = diff("preferences:language-catalog", language_expected, language_actual)

    actual = run_harness(swift_root, "preferences-actions")
    problems += diff("preferences:load-from-anki-config", expected_loaded, actual.get("loaded", {}))

    expected_saved = {
        "rollover": 9,
        "collapseTime": 900,
        "newSpread": 2,
        "hideAudioPlayButtons": False,
        "interruptAudioWhenAnswering": True,
        "dueCounts": True,
        "estTimes": False,
        "timeLim": 900,
        "addToCur": False,
        "applyAllParentLimits": False,
        "fsrs": False,
        "fsrsShortTermWithStepsEnabled": False,
        "pasteImagesAsPng": False,
        "pasteStripsFormatting": False,
        "defaultSearchText": "deck:Math",
        "ignoreAccentsInSearch": False,
        "renderLatex": False,
        "dayLearnFirst": True,
        "newTimezone": False,
        "creationOffset": None,
        "loadBalancerEnabled": False,
        "backups": {
            "minimum_interval_mins": 23,
            "daily": 7,
            "weekly": 5,
            "monthly": 3,
        },
    }
    problems += diff("preferences:save-and-reload", expected_saved, actual.get("saved", {}))
    expected_reopened = dict(expected_saved)
    expected_reopened["newTimezone"] = True
    expected_reopened["creationOffset"] = expected_timezone_offset
    actual_reopened = run_harness(swift_root, "preferences-snapshot")
    problems += diff("preferences:reopen-v3-timezone", expected_reopened, actual_reopened)

    actual_path = os.path.join(swift_root, "User 1", "collection.anki2")
    saved = Collection(actual_path)
    try:
        saved_prefs = saved.get_preferences()
        saved_values = {
            "rollover": saved_prefs.scheduling.rollover,
            "collapseTime": saved_prefs.scheduling.learn_ahead_secs,
            "newSpread": saved_prefs.scheduling.new_review_mix,
            "hideAudioPlayButtons": saved_prefs.reviewing.hide_audio_play_buttons,
            "interruptAudioWhenAnswering": saved_prefs.reviewing.interrupt_audio_when_answering,
            "dueCounts": saved_prefs.reviewing.show_remaining_due_counts,
            "estTimes": saved_prefs.reviewing.show_intervals_on_buttons,
            "timeLim": saved_prefs.reviewing.time_limit_secs,
            "addToCur": saved_prefs.editing.adding_defaults_to_current_deck,
            "pasteImagesAsPng": saved_prefs.editing.paste_images_as_png,
            "pasteStripsFormatting": saved_prefs.editing.paste_strips_formatting,
            "defaultSearchText": saved_prefs.editing.default_search_text,
            "ignoreAccentsInSearch": saved_prefs.editing.ignore_accents_in_search,
            "renderLatex": saved_prefs.editing.render_latex,
            "dayLearnFirst": saved_prefs.scheduling.day_learn_first,
            "newTimezone": saved_prefs.scheduling.new_timezone,
            "loadBalancerEnabled": saved_prefs.reviewing.load_balancer_enabled,
            "backups": {
                "minimum_interval_mins": saved_prefs.backups.minimum_interval_mins,
                "daily": saved_prefs.backups.daily,
                "weekly": saved_prefs.backups.weekly,
                "monthly": saved_prefs.backups.monthly,
            },
        }
        problems += diff("preferences:anki-backend-readback", {
            key: expected_reopened[key] for key in saved_values
        }, saved_values)
        config = saved.all_config()
        problems += diff("preferences:legacy-key-migration", {
            "defaultSearchText": "deck:Math",
            "browserDefaultSearch": None,
            "fsrsShortTermWithStepsEnabled": False,
            "fsrsShortTermWithSteps": None,
            "creationOffset": expected_timezone_offset,
        }, {
            "defaultSearchText": config.get("defaultSearchText"),
            "browserDefaultSearch": config.get("browserDefaultSearch"),
            "fsrsShortTermWithStepsEnabled": config.get("fsrsShortTermWithStepsEnabled"),
            "fsrsShortTermWithSteps": config.get("fsrsShortTermWithSteps"),
            "creationOffset": config.get("creationOffset"),
        })
    finally:
        saved.close()
    return problems


def check_load_balancer():
    oracle_path, swift_root = prepare("sched")
    oracle = Collection(oracle_path)
    fixed_card_id = 123456789
    try:
        oracle.set_config("loadBalancerEnabled", True)
        oracle.decks.set_current(oracle.decks.id_for_name("Lang"))
        today = oracle.sched.today
        target = oracle.db.first("""
            select c.id, c.nid, c.did from cards c
            where c.type=2 and c.queue=2 and c.ivl>=21
              and exists(select 1 from cards sibling where sibling.nid=c.nid and sibling.id!=c.id)
            order by c.id limit 1
        """)
        if target is None:
            return ["load-balancer: fixture has no mature review card with a sibling"]
        original_card_id, target_note_id, target_deck_id = target
        sibling_card_id = oracle.db.scalar(
            "select id from cards where nid=? and id!=? and queue=2 order by ord limit 1",
            target_note_id, original_card_id,
        )
        if sibling_card_id is None:
            return ["load-balancer: fixture has no review sibling"]
        config_id = oracle.decks.get(target_deck_id)["conf"]
        config = oracle.decks.get_config(config_id)
        easy_days = [1, 0.5, 1, 1, 1, 0, 1]
        config["rev"]["bury"] = True
        config["easyDaysPercentages"] = easy_days
        oracle.decks.update_config(config)
        oracle.db.execute("update cards set id=? where id=?", fixed_card_id, original_card_id)
        oracle.db.execute("update revlog set cid=? where cid=?", fixed_card_id, original_card_id)
        oracle.db.execute("update cards set queue=-1 where queue in (0,1,3,4)")
        oracle.db.execute(
            "update cards set due=? where queue=2 and id not in (?, ?)",
            today + 70, fixed_card_id, sibling_card_id,
        )
        oracle.db.execute("update cards set due=? where id=?", today, fixed_card_id)
        oracle.db.execute("update cards set due=? where id=?", today + 55, sibling_card_id)
        queued = oracle.sched.get_queued_cards(fetch_limit=100)
        if not queued.cards or queued.cards[0].card.id != fixed_card_id:
            return ["load-balancer: deterministic review card is not at queue head"]
        expected = oracle_states(oracle, [fixed_card_id])[str(fixed_card_id)]
    finally:
        oracle.close()

    app_path = os.path.join(swift_root, "User 1", "collection.anki2")
    app_db = sqlite3.connect(app_path)
    try:
        conf = json.loads(app_db.execute("select conf from col").fetchone()[0])
        dconf = json.loads(app_db.execute("select dconf from col").fetchone()[0])
        conf["loadBalancerEnabled"] = True
        app_config = dconf[str(config_id)]
        app_config["rev"]["bury"] = True
        app_config["easyDaysPercentages"] = easy_days
        app_db.execute("update col set conf=?, dconf=?", (json.dumps(conf), json.dumps(dconf)))
        app_db.execute("update cards set id=? where id=?", (fixed_card_id, original_card_id))
        app_db.execute("update revlog set cid=? where cid=?", (fixed_card_id, original_card_id))
        app_db.execute("update cards set queue=-1 where queue in (0,1,3,4)")
        app_db.execute(
            "update cards set due=? where queue=2 and id not in (?, ?)",
            (today + 70, fixed_card_id, sibling_card_id),
        )
        app_db.execute("update cards set due=? where id=?", (today, fixed_card_id))
        app_db.execute("update cards set due=? where id=?", (today + 55, sibling_card_id))
        app_db.commit()
    finally:
        app_db.close()

    actual = run_harness(swift_root, "states-load-balanced", str(fixed_card_id))[str(fixed_card_id)]
    differences = {
        rating: {"anki": expected[rating]["ivl"], "ankios": actual[rating]["ivl"]}
        for rating in ("2", "3", "4")
        if expected[rating]["ivl"] != actual[rating]["ivl"]
    }
    return [f"load-balancer: intervalos diferentes após carregar a fila: {differences}"] if differences else []


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


def check_deck_options():
    problems = []
    oracle_path, swift_root = prepare("sched")
    oracle = Collection(oracle_path)
    try:
        deck_id = oracle.decks.id("Lang::ES", create=False)
        info = oracle.decks.get_deck_configs_for_update(deck_id)
        current = next(
            item.config for item in info.all_config
            if item.config.id == info.current_deck.config_id
        )
        config = type(current)()
        config.CopyFrom(current)
        config.id = 0
        config.name = "Parity preset"
        config.usn = -1
        config.config.learn_steps[:] = [1, 3, 7]
        config.config.new_per_day = 37
        config.config.new_per_day_minimum = 4
        config.config.bury_new = True
        config.config.reviews_per_day = 123
        config.config.easy_multiplier = 1.45
        config.config.bury_reviews = True
        config.config.relearn_steps[:] = [5, 60]
        config.config.leech_threshold = 6
        config.config.leech_action = 1
        config.config.disable_autoplay = True
        config.config.show_timer = True
        config.config.stop_timer_on_answer = True
        config.config.wait_for_audio = False
        config.config.bury_interday_learning = True
        config.config.desired_retention = 0.91
        config.config.easy_days_percentages[:] = [1, 0.5, 1, 1, 1, 0, 1]

        limits = info.current_deck.limits
        limits.new = 37
        limits.new_today = 11
        limits.new_today_active = True
        limits.review_today = 12
        limits.review_today_active = True
        oracle.decks.update_deck_configs(UpdateDeckConfigsRequest(
            target_deck_id=deck_id,
            configs=[config],
            mode=UpdateDeckConfigsMode.UPDATE_DECK_CONFIGS_MODE_NORMAL,
            limits=limits,
            new_cards_ignore_review_limit=True,
            fsrs=info.fsrs,
            apply_all_parent_limits=info.apply_all_parent_limits,
            fsrs_health_check=info.fsrs_health_check,
        ))

        assigned_deck = oracle.decks.get(deck_id)
        stored_config = oracle.decks.get_config(assigned_deck["conf"])
        stored_config["id"] = "new"
        stored_config["mod"] = "updated"
        assigned_deck["conf"] = "new"
        assigned_deck["mod"] = "updated"
        updated_info = oracle.decks.get_deck_configs_for_update(deck_id)
        expected = {
            "preset": stored_config,
            "deck": assigned_deck,
            "cards": [
                {
                    "id": cid,
                    "type": card_type,
                    "queue": queue,
                    "left": left,
                    "usn": usn,
                }
                for cid, card_type, queue, left, usn in oracle.db.all(
                    "select id, type, queue, left, usn from cards "
                    "where (did=? or (odid!=0 and odid=?)) and type in (1,3) order by id",
                    deck_id, deck_id,
                )
            ],
            "newCardsIgnoreReviewLimit": updated_info.new_cards_ignore_review_limit,
        }
    finally:
        oracle.close()

    actual = run_harness(swift_root, "deck-options")
    actual["preset"]["id"] = "new"
    actual["preset"]["mod"] = "updated"
    actual["deck"]["conf"] = "new"
    actual["deck"]["mod"] = "updated"
    actual["preset"].pop("historicalRetention", None)
    actual["preset"].get("rev", {}).pop("fuzz", None)
    actual["preset"].get("rev", {}).pop("minSpace", None)
    for deck in (expected["deck"], actual["deck"]):
        for key in [key for key, value in deck.items() if value is None]:
            deck.pop(key)
        if deck.get("md") is False:
            deck.pop("md")
    problems += diff("decks:options", expected, actual)
    return problems


def check_rich_media():
    from anki.media import media_paths_from_col_path

    oracle_path, swift_root = prepare("sched")
    source_dir = os.path.join(WORK, "rich-media-source")
    shutil.rmtree(source_dir, ignore_errors=True)
    os.makedirs(source_dir)
    image_path = os.path.join(source_dir, "parity-rich.png")
    audio_path = os.path.join(source_dir, "Parity-Voice.MP3")
    with open(image_path, "wb") as file:
        file.write(b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\x0bIDATx\x9cc`\x00\x02\x00\x00\x05\x00\x01\xa5\xf6E@\x00\x00\x00\x00IEND\xaeB`\x82")
    with open(audio_path, "wb") as file:
        file.write(b"parity audio bytes")

    oracle_media, _ = media_paths_from_col_path(oracle_path)
    swift_media = os.path.join(swift_root, "User 1", "collection.media")
    os.makedirs(oracle_media, exist_ok=True)
    os.makedirs(swift_media, exist_ok=True)
    existing_media = {
        "parity-rich.png": b"existing-image-bytes",
        "Parity-Voice.MP3": b"existing-audio-bytes",
    }
    for filename, data in existing_media.items():
        for directory in (oracle_media, swift_media):
            with open(os.path.join(directory, filename), "wb") as file:
                file.write(data)

    oracle = Collection(oracle_path)
    try:
        image_name = oracle.media.add_file(image_path)
        audio_name = oracle.media.add_file(audio_path)
        note_id = oracle.db.scalar(
            "select id from notes where mid=? order by id limit 1",
            oracle.models.by_name("Basic")["id"],
        )
        note = oracle.get_note(note_id)
        guid = note.guid
        note.fields[0] = f'<p class="clip">A&nbsp; &amp; <strong>árvore</strong></p><img src="{image_name}" alt="diagrama">[sound:{audio_name}]'
        note.fields[1] = f'<div data-kind="note">Resposta<br>rica &lt;ok&gt;</div><img src="{image_name}" alt="diagrama">[sound:{audio_name}]'
        oracle.update_note(note)
        stored = oracle.db.first("select flds, sfld, csum, tags, usn from notes where id=?", note_id)
        expected = {
            "fields": stored[0].split("\x1f"),
            "sfld": stored[1],
            "csum": stored[2],
            "tags": stored[3],
            "usn": stored[4],
            "mediaNames": [image_name, audio_name],
            "cards": [
                {"id": cid, "ord": ord, "queue": queue, "due": due, "usn": usn}
                for cid, ord, queue, due, usn in oracle.db.all(
                    "select id, ord, queue, due, usn from cards where nid=? order by ord",
                    note_id,
                )
            ],
        }
        expected_render = card_render_snapshot(oracle, [guid], include_answer_sounds=True)
    finally:
        oracle.close()

    actual = run_harness(swift_root, "rich-media-edit", guid, image_path, audio_path)
    problems = diff("notes:rich-media", expected, actual)
    expected_media = []
    for directory in (oracle_media,):
        for filename in sorted(os.listdir(directory)):
            path = os.path.join(directory, filename)
            if os.path.isfile(path):
                with open(path, "rb") as file:
                    expected_media.append({"name": filename, "sha1": hashlib.sha1(file.read()).hexdigest()})
    actual_media = []
    for filename in sorted(os.listdir(swift_media)):
        path = os.path.join(swift_media, filename)
        if os.path.isfile(path):
            with open(path, "rb") as file:
                actual_media.append({"name": filename, "sha1": hashlib.sha1(file.read()).hexdigest()})
    problems += diff("notes:rich-media/files", expected_media, actual_media)

    actual_render = [row for row in run_harness(swift_root, "render-cards") if row["guid"] == guid]
    render_keys = ("guid", "ordinal", "questionText", "answerText", "questionSounds", "answerSounds")
    expected_render = [{key: row[key] for key in render_keys} for row in expected_render]
    actual_render = [{key: row[key] for key in render_keys} for row in actual_render]
    problems += diff("notes:rich-media:render", expected_render, actual_render)
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
            + diff("templates:missing-cloze", expected_cloze, actual_cloze)
            + check_tts_render(oracle_path, swift_root))


def check_tts_render(oracle_path, swift_root):
    from anki.sound import SoundOrVideoTag, TTSTag

    cases = [
        [
            "[sound:q-before.mp3]{{tts en_US:Front}}[sound:q-after.mp3]",
            "{{FrontSide}}<hr id=answer>[sound:a-before.ogg]{{tts pt_BR voices=Luciana speed=0.8:Back}}[sound:a-after.ogg]",
            "<b>Spoken question – café &amp; tea</b>",
            "<p>Resposta falada</p>",
        ],
        [
            "[sound:q-block-before.mp3][anki:tts lang=fr_FR speed=1.1]{{Front}}[/anki:tts][sound:q-block-after.mp3]",
            "[sound:a-block-before.mp3][anki:tts lang=de_DE voices=Anna speed=0.9]{{Back}}[/anki:tts][sound:a-block-after.mp3]",
            "A second spoken question",
            "Deuxième réponse",
        ],
    ]
    oracle = Collection(oracle_path)
    try:
        model = oracle.models.by_name("Basic")
        expected = []
        for question, answer, front, back in cases:
            model["tmpls"][0]["qfmt"] = question
            model["tmpls"][0]["afmt"] = answer
            oracle.models.update(model)
            note = oracle.new_note(model)
            note.fields = [front, back]
            oracle.add_note(note, 1)
            card = oracle.get_card(oracle.db.scalar("select id from cards where nid=? order by ord limit 1", note.id))

            def playback_rows(tags):
                rows = []
                for tag in tags:
                    if isinstance(tag, SoundOrVideoTag):
                        rows.append({"kind": "file", "filename": tag.filename})
                    elif isinstance(tag, TTSTag):
                        text = re.sub(r"(?is)<(script|style)\b[^>]*>.*?</\1>", " ", tag.field_text)
                        text = re.sub(r"(?s)<[^>]*>", " ", text)
                        text = re.sub(r"\s+", " ", html.unescape(text)).strip()
                        rows.append({
                            "kind": "speech",
                            "language": tag.lang,
                            "speed": float(tag.speed),
                            "voices": tag.voices,
                            "text": text,
                        })
                return rows

            question_playback = playback_rows(card.question_av_tags())
            answer_playback = playback_rows(card.answer_av_tags())
            expected.append({
                "question": [{key: row[key] for key in ("language", "speed", "voices", "text")} for row in question_playback if row["kind"] == "speech"],
                "answer": [{key: row[key] for key in ("language", "speed", "voices", "text")} for row in answer_playback if row["kind"] == "speech"],
                "questionPlayback": question_playback,
                "answerPlayback": answer_playback,
            })
    finally:
        oracle.close()
    actual = run_harness(swift_root, "speech-render-batch", json.dumps(cases))
    return diff("study:tts", expected, actual)


def check_type_answer():
    oracle_path, swift_root = prepare("sched")
    cases = [
        ["type:Back", "Paris", "Paris"],
        ["type:Back", "Paris", "paris"],
        ["type:ci:Back", "Paris", "paris"],
        ["type:ci:Back", "Straße", "STRASSE"],
        ["type-nc:Back", "Ábaco", "abaco"],
        ["type:Back", "<b>A &amp; B</b>", "A & B"],
        ["type:Back", "one<br>two", "one two"],
        ["type:Back", "[sound:word.mp3]word", "word"],
        ["type:Back", "a🙂b", "a🙂"],
        ["type:Back", "ab", "ba"],
        ["type:cloze:Back", "{{c1::alpha}} {{c2::beta}}", "alpha"],
        ["type:cloze:Back", "{{c1::first::hint}} {{c2::second}}", "first"],
        ["type:Back", "&nbsp;A", "A"],
        ["type:Back", "A\u0301", "Á"],
        ["type:Back", "x<BR>y", "x y"],
        ["type:Back", "a<!--hidden-->b", "ab"],
        ["type:Back", "", ""],
    ]
    oracle = Collection(oracle_path)
    try:
        from anki.card_rendering_pb2 import CompareAnswerRequest
        from anki.generic_pb2 import String as GenericString

        expected = []
        for expression, source_expected, typed in cases:
            answer = source_expected
            if "cloze:" in expression:
                answer = oracle._backend.extract_cloze_for_typing(text=answer, ordinal=1)
            if ":ci:" in expression and (answer, typed) == ("Paris", "paris"):
                rendered = "<code id=typeans><span class=typeGood>Paris</span></code>"
            elif ":ci:" in expression and (answer, typed) == ("Straße", "STRASSE"):
                rendered = (
                    "<code id=typeans><span class=typeGood>STRA</span><span class=typeBad>SS</span>"
                    "<span class=typeGood>E</span><br><span id=typearrow>&darr;</span><br>"
                    "<span class=typeGood>Stra</span><span class=typeMissed>ß</span><span class=typeGood>e</span></code>"
                )
            else:
                request = CompareAnswerRequest(
                    expected=answer,
                    provided=typed,
                    combining="-nc" not in expression and ":nc:" not in expression,
                )
                response = GenericString()
                response.ParseFromString(oracle._backend.compare_answer_raw(request.SerializeToString()))
                rendered = response.val
            expected.append({
                "html": rendered,
                "matches": bool(typed)
                    and "class=typeBad" not in rendered
                    and "class=typeMissed" not in rendered,
            })
    finally:
        oracle.close()
    actual = run_harness(swift_root, "type-answer-render-batch", json.dumps(cases, ensure_ascii=False))
    return diff("study:typed-answer", expected, actual)


def check_auto_advance_actions():
    _, swift_root = prepare("sched")
    values = list(range(-7, 8))
    question_actions = ["showAnswer", "showReminder"]
    answer_actions = ["buryCard", "answerAgain", "answerGood", "answerHard", "showReminder"]

    def action(value, actions, fallback):
        index = value if value >= 0 else len(actions) + value
        return actions[index] if 0 <= index < len(actions) else fallback

    expected = [
        {
            "raw": value,
            "question": action(value, question_actions, "showAnswer"),
            "answer": action(value, answer_actions, "buryCard"),
        }
        for value in values
    ]
    actual = run_harness(swift_root, "auto-advance-actions", json.dumps(values))
    return diff("study:auto-advance-actions", expected, actual)


def check_auto_advance_timers():
    _, swift_root = prepare("sched")
    seconds = [0, -1, 0.0009, 0.0019, 0.9999, 1, 1.2349, 60.9999]
    expected = {
        "delays": [
            {
                "seconds": value,
                "milliseconds": int(value * 1000) if value > 0 else None,
            }
            for value in seconds
        ],
        "focus": [
            {"enabled": enabled, "focused": focused, "advance": enabled and focused}
            for enabled in [False, True]
            for focused in [False, True]
        ],
        "audioWait": [
            {
                "waitForAudio": wait_for_audio,
                "unfinished": unfinished,
                "skip": wait_for_audio and unfinished,
            }
            for wait_for_audio in [False, True]
            for unfinished in [False, True]
        ],
    }
    actual = run_harness(swift_root, "auto-advance-timers", json.dumps(seconds))
    return diff("study:auto-advance-timers", expected, actual)


def check_korean_shortcuts():
    _, swift_root = prepare("sched")
    expected = [
        {"key": "ㄷ", "modifiers": "none", "action": "edit"},
        {"key": "ㅡ", "modifiers": "none", "action": "contextMenu"},
        {"key": "ㄱ", "modifiers": "none", "action": "replayAudio"},
        {"key": "ㅜ", "modifiers": "controlOption", "action": "forgetCard"},
        {"key": "ㅍ", "modifiers": "none", "action": "replayOwnVoice"},
        {"key": "ㅍ", "modifiers": "shift", "action": "recordOwnVoice"},
        {"key": "ㅐ", "modifiers": "none", "action": "deckOptions"},
        {"key": "ㅑ", "modifiers": "none", "action": "cardInfo"},
        {"key": "ㅑ", "modifiers": "controlOption", "action": "previousCardInfo"},
        {"key": "ㅕ", "modifiers": "none", "action": "undo"},
    ]
    actual = run_harness(swift_root, "study-korean-shortcuts")
    return diff("study:korean-shortcuts", expected, actual)


def check_review_shortcuts():
    _, swift_root = prepare("sched")
    expected = [
        {"key": "e", "modifiers": "none", "action": "edit"},
        {"key": "space", "modifiers": "none", "action": "showAnswer"},
        {"key": "return", "modifiers": "none", "action": "showAnswer"},
        {"key": "enter", "modifiers": "none", "action": "showAnswer"},
        {"key": "m", "modifiers": "none", "action": "contextMenu"},
        {"key": "r", "modifiers": "none", "action": "replayAudio"},
        {"key": "F5", "modifiers": "none", "action": "replayAudio"},
    ]
    expected.extend(
        {"key": str(flag), "modifiers": "control", "action": f"setFlag{flag}"}
        for flag in range(1, 8)
    )
    expected += [
        {"key": "*", "modifiers": "none", "action": "mark"},
        {"key": "=", "modifiers": "none", "action": "buryNote"},
        {"key": "-", "modifiers": "none", "action": "buryCard"},
        {"key": "!", "modifiers": "none", "action": "suspendNote"},
        {"key": "@", "modifiers": "none", "action": "suspendCard"},
        {"key": "n", "modifiers": "controlOption", "action": "forgetCard"},
        {"key": "e", "modifiers": "controlOption", "action": "createCopy"},
        {"key": "backspace", "modifiers": "control", "action": "deleteNote"},
        {"key": "d", "modifiers": "controlShift", "action": "setDueDate"},
        {"key": "v", "modifiers": "none", "action": "replayOwnVoice"},
        {"key": "v", "modifiers": "shift", "action": "recordOwnVoice"},
        {"key": "o", "modifiers": "none", "action": "deckOptions"},
        {"key": "i", "modifiers": "none", "action": "cardInfo"},
        {"key": "i", "modifiers": "controlOption", "action": "previousCardInfo"},
        {"key": "u", "modifiers": "none", "action": "undo"},
        {"key": "5", "modifiers": "none", "action": "pauseAudio"},
        {"key": "6", "modifiers": "none", "action": "seekBackward"},
        {"key": "7", "modifiers": "none", "action": "seekForward"},
        {"key": "a", "modifiers": "shift", "action": "toggleAutoAdvance"},
    ]
    actual = run_harness(swift_root, "study-shortcuts")
    return diff("study:review-shortcuts", expected, actual)


def check_widget_grade():
    oracle_path, swift_root = prepare("sched")
    oracle = Collection(oracle_path)
    try:
        study_deck_id = oracle.decks.id_for_name("Lang")
        oracle.decks.set_current(study_deck_id)
        queued = oracle.sched.get_queued_cards(fetch_limit=1)
        if not queued.cards:
            return ["widget: fixture has no card in the selected study queue"]
        card_id = queued.cards[0].card.id
        card = oracle.get_card(card_id)
        card.start_timer()
        states = oracle._backend.get_scheduling_states(card_id)
        answer = oracle.sched.build_answer(card=card, states=states, rating=CardAnswer.GOOD)
        oracle.sched.answer_card(answer)
        after_queue = oracle.sched.get_queued_cards(fetch_limit=1)
        expected = {
            "beforeCardID": card_id,
            "revealedBeforeGrade": True,
            "revealedAfterGrade": False,
            "afterCardID": after_queue.cards[0].card.id if after_queue.cards else 0,
            "hasCard": bool(after_queue.cards),
            "queueHeadID": after_queue.cards[0].card.id if after_queue.cards else 0,
            "counts": [after_queue.new_count, after_queue.learning_count, after_queue.review_count],
        }
    finally:
        oracle.close()
    actual = run_harness(swift_root, "widget-grade", str(card_id), str(int(CardAnswer.GOOD) + 1), str(study_deck_id))
    return diff("widget:grade-and-refresh", expected, actual)


def check_media_check():
    oracle_path, swift_root = prepare("sched")
    with sqlite3.connect(oracle_path) as db:
        note_id = db.execute("select id from notes order by id limit 1").fetchone()[0]
        db.execute(
            "update notes set flds=? where id=?",
            ('<img src="USED.png"> [sound:missing.mp3] <a href="linked-missing.png">link</a> <div style="background:url(bg-missing.png)">\x1f<img src="_kept.png">', note_id),
        )
        models = json.loads(db.execute("select models from col").fetchone()[0])
        basic = next(model for model in models.values() if model["name"] == "Basic")
        basic["tmpls"][0]["qfmt"] += '<img src="template-missing.png">'
        db.execute("update col set models=?", (json.dumps(models),))

    swift_collection = os.path.join(swift_root, "User 1", "collection.anki2")
    shutil.copy2(oracle_path, swift_collection)
    oracle_media = oracle_path.removesuffix(".anki2") + ".media"
    swift_media = os.path.join(swift_root, "User 1", "collection.media")
    for media_path in (oracle_media, swift_media):
        os.makedirs(media_path, exist_ok=True)
        for filename in ("used.png", "_kept.png", "unused.png", "_orphan.png"):
            with open(os.path.join(media_path, filename), "wb") as media_file:
                media_file.write(filename.encode())

    col = Collection(oracle_path)
    try:
        response = col.media.check()
        expected = {
            "unused": sorted(response.unused),
            "missing": sorted(response.missing),
            "missingNoteIDs": sorted(response.missing_media_notes),
        }
    finally:
        col.close()
    actual = run_harness(swift_root, "media-check")
    return diff(f"tools:media-check/note-{note_id}", expected, actual)


def database_check_snapshot(col):
    db = col.db
    def rows(query):
        return [list(row) for row in db.all(query)]

    notetypes_by_id = {model["id"]: model["name"] for model in col.models.all()}
    notes = rows("select id, guid, mid, tags, flds, sfld, csum, flags, data from notes order by id")

    def stable_notetype_name(name):
        match = re.fullmatch(r"db-check-\d+-(\d+)(?:-\d+)?", name)
        return f"db-check-{match.group(1)}" if match else name

    for note in notes:
        name = notetypes_by_id.get(note[2], f"missing-{note[2]}")
        note[2] = stable_notetype_name(name)

    return {
        "deckNames": sorted(deck.name for deck in col.decks.all_names_and_ids()),
        "notetypeNames": sorted(stable_notetype_name(model["name"]) for model in col.models.all()),
        "nextPosition": int(col.conf.get("nextPos", 0)),
        "invalidIDs": int(db.scalar(
            "select (select count(*) from notes where id>?) + (select count(*) from cards where id>?) + (select count(*) from revlog where id>?)",
            int(time.time() * 1000) + 86_400_000,
            int(time.time() * 1000) + 86_400_000,
            int(time.time() * 1000) + 86_400_000,
        )),
        "notes": notes,
        "cards": rows("select id, nid, did, ord, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data from cards order by id"),
        "revlog": rows("select id, cid, ease, ivl, lastIvl, factor, time, type from revlog order by id"),
        "graves": rows("select usn, oid, type from graves order by oid, type"),
    }


def database_check_id_stable_snapshot(snapshot):
    note_guids = {note[0]: note[1] for note in snapshot["notes"]}
    card_refs = {}
    notes = []
    for note in snapshot["notes"]:
        notes.append(note[1:])
    cards = []
    for card in snapshot["cards"]:
        note_guid = note_guids.get(card[1], f"missing-{card[1]}")
        card_refs[card[0]] = (note_guid, card[3])
        cards.append([note_guid, card[2], card[3], *card[4:]])
    revlog = []
    for row in snapshot["revlog"]:
        note_guid, ordinal = card_refs.get(row[1], (f"missing-card-{row[1]}", -1))
        revlog.append([note_guid, ordinal, *row[2:]])
    stable = dict(snapshot)
    stable["notes"] = sorted(notes, key=lambda row: row[0])
    stable["cards"] = sorted(cards, key=lambda row: (row[0], row[2]))
    stable["revlog"] = sorted(revlog, key=lambda row: tuple(map(str, row)))
    return stable


def check_database_check():
    problems = []
    scenarios = [
        "clean", "orphan-card", "card-properties", "revlog-properties", "note-fields",
        "extra-note-fields", "missing-deck", "missing-deck-parent", "filtered-state",
        "missing-template", "duplicate-ord", "high-new-position", "missing-notetype", "invalid-ids", "invalid-utf8",
    ]
    for scenario in scenarios:
        oracle_path, swift_root = prepare("sched")
        swift_path = os.path.join(swift_root, "User 1", "collection.anki2")
        with sqlite3.connect(oracle_path) as db:
            if scenario == "orphan-card":
                source = db.execute("select * from cards order by id limit 1").fetchone()
                orphan = list(source)
                orphan[0] += 1_000_000
                orphan[1] = orphan[1] + 10_000_000
                db.execute("insert into cards values (" + ",".join("?" for _ in orphan) + ")", orphan)
            elif scenario == "card-properties":
                card_id = db.execute("select id from cards order by id limit 1").fetchone()[0]
                db.execute("update cards set ord=-3, ivl=2.5, odue=1.5, mod=mod+9999999999 where id=?", (card_id,))
            elif scenario == "revlog-properties":
                row = db.execute("select id from revlog order by id limit 1").fetchone()
                if row:
                    db.execute("update revlog set ivl=2.5, lastIvl=-1.5, time=-4.2, type=99 where id=?", row)
            elif scenario == "note-fields":
                row = db.execute("select id, flds from notes order by id limit 1").fetchone()
                fields = row[1].split("\x1f")
                db.execute("update notes set flds=? where id=?", (fields[0], row[0]))
            elif scenario == "extra-note-fields":
                row = db.execute("select id from notes order by id limit 1").fetchone()
                db.execute("update notes set flds=? where id=?", ("one\x1ftwo\x1fthree", row[0]))
            elif scenario == "missing-deck":
                card_id = db.execute("select id from cards order by id limit 1").fetchone()[0]
                db.execute("update cards set did=1234 where id=?", (card_id,))
            elif scenario == "missing-deck-parent":
                deck_data = json.loads(db.execute("select decks from col").fetchone()[0])
                parent_id = next(deck_id for deck_id, deck in deck_data.items() if deck["name"] == "Lang")
                del deck_data[parent_id]
                db.execute("update col set decks=?", (json.dumps(deck_data),))
            elif scenario == "filtered-state":
                card_id = db.execute("select id from cards order by id limit 1").fetchone()[0]
                db.execute("update cards set odid=1234, odue=6 where id=?", (card_id,))
            elif scenario == "missing-template":
                card_id = db.execute("select id from cards order by id limit 1").fetchone()[0]
                db.execute("update cards set ord=99 where id=?", (card_id,))
            elif scenario == "duplicate-ord":
                source = db.execute("select * from cards order by id limit 1").fetchone()
                duplicate = list(source)
                duplicate[0] += 1_000_000
                db.execute("insert into cards values (" + ",".join("?" for _ in duplicate) + ")", duplicate)
            elif scenario == "high-new-position":
                card_id = db.execute("select id from cards where type=0 and queue=0 order by id limit 1").fetchone()[0]
                db.execute("update cards set due=2000000 where id=?", (card_id,))
            elif scenario == "missing-notetype":
                note_id = db.execute("select id from notes order by id limit 1").fetchone()[0]
                db.execute("update notes set mid=987654321 where id=?", (note_id,))
            elif scenario == "invalid-ids":
                note_rows = db.execute("select id from notes order by id").fetchall()
                note_mapping = {row[0]: 1_000_000 + index for index, row in enumerate(note_rows)}
                for old_id, new_id in note_mapping.items():
                    db.execute("update notes set id=? where id=?", (new_id, old_id))
                    db.execute("update cards set nid=? where nid=?", (new_id, old_id))
                card_rows = db.execute("select id from cards order by id").fetchall()
                card_mapping = {row[0]: 2_000_000 + index for index, row in enumerate(card_rows)}
                for old_id, new_id in card_mapping.items():
                    db.execute("update cards set id=? where id=?", (new_id, old_id))
                    db.execute("update revlog set cid=? where cid=?", (new_id, old_id))
                revlog_rows = db.execute("select id from revlog order by id").fetchall()
                for index, (old_id,) in enumerate(revlog_rows):
                    db.execute("update revlog set id=? where id=?", (3_000_000 + index, old_id))
                card_id, note_id = db.execute(
                    "select cards.id, cards.nid from cards join revlog on revlog.cid=cards.id order by cards.id limit 1"
                ).fetchone()
                invalid_base = (int(time.time()) + 3 * 86_400) * 1000
                invalid_note_id = invalid_base + 1
                invalid_card_id = invalid_base + 2
                invalid_revlog_id = invalid_base + 3
                db.execute("update notes set id=? where id=?", (invalid_note_id, note_id))
                db.execute("update cards set nid=? where nid=?", (invalid_note_id, note_id))
                db.execute("update cards set id=? where id=?", (invalid_card_id, card_id))
                db.execute("update revlog set cid=? where cid=?", (invalid_card_id, card_id))
                db.execute("update revlog set id=? where id=(select min(id) from revlog where cid=?)", (invalid_revlog_id, invalid_card_id))
            elif scenario == "invalid-utf8":
                note_id = db.execute("select id from notes order by id limit 1").fetchone()[0]
                db.execute(
                    "update notes set flds=cast(? as text) where id=?",
                    (sqlite3.Binary(b"bad\xfffield\x1fback"), note_id),
                )
            db.commit()
        shutil.copy2(oracle_path, swift_path)

        col = Collection(oracle_path)
        try:
            col.fix_integrity()
            expected = database_check_snapshot(col)
        finally:
            col.close()

        actual = run_harness(swift_root, "database-check")
        for note in actual["notes"]:
            note[2] = re.sub(r"db-check-\d+-(\d+)(?:-\d+)?", r"db-check-\1", note[2])
        actual["notetypeNames"] = sorted(
            re.sub(r"db-check-\d+-(\d+)(?:-\d+)?", r"db-check-\1", name)
            for name in actual["notetypeNames"]
        )
        if scenario in {"invalid-ids", "missing-template"}:
            expected = database_check_id_stable_snapshot(expected)
            actual = database_check_id_stable_snapshot(actual)
        actual = {key: actual[key] for key in ("deckNames", "notetypeNames", "nextPosition", "invalidIDs", "notes", "cards", "revlog", "graves")}
        problems += diff(f"tools:database-check/{scenario}", expected, actual)
    return problems


def check_profiles():
    oracle_path, swift_root = prepare("sched")
    col = Collection(oracle_path)
    try:
        expected = {
            "appearedAfterCreate": True,
            "duplicateCreationRejected": True,
            "reservedNameRejected": True,
            "secondaryWasEmpty": True,
            "separateCollectionPath": True,
            "initialSecondaryPreferencesMatchPrimary": True,
            "secondaryNotesAfterAdd": 1,
            "secondaryCardsAfterAdd": 1,
            "renamePreservedCollection": True,
            "renamedPreferencesPersist": True,
            "primaryNotesBefore": col.db.scalar("select count(*) from notes"),
            "primaryCardsBefore": col.db.scalar("select count(*) from cards"),
            "primaryNotesAfter": col.db.scalar("select count(*) from notes"),
            "primaryCardsAfter": col.db.scalar("select count(*) from cards"),
            "keyboardPreferencesAreGlobal": True,
            "renamedNoteFields": "Profile sentinel\x1fisolated",
            "renamedCardsAfterSwitch": 1,
            "renamedPreferencesAfterSwitch": True,
            "deletedProfileDirectory": True,
            "activeProfileRestored": True,
            "remainingProfiles": ["User 1"],
        }
        actual = run_harness(swift_root, "profile-actions")
    finally:
        col.close()
    return diff("tools:profiles", expected, actual)


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


def filtered_options_from_deck(deck, include_name=True):
    result = {
        "terms": deck.get("terms", []),
        "reschedule": deck.get("resched", True),
        "previewDelay": deck.get("previewDelay", 0),
        "previewAgainSecs": deck.get("previewAgainSecs", 60),
        "previewHardSecs": deck.get("previewHardSecs", 600),
        "previewGoodSecs": deck.get("previewGoodSecs", 0),
    }
    if include_name:
        result["name"] = deck["name"]
    return result


def filtered_options_snapshot(col, deck_id):
    deck = col.decks.get(deck_id)
    return {
        "options": filtered_options_from_deck(deck),
        "cards": filtered_snapshot(col, deck_id),
        "isCurrentDeck": col.decks.get_current_id() == deck_id,
    }


def configure_filtered_deck(deck, *, name, terms, reschedule, again, hard, good, allow_empty=False):
    deck.name = name
    deck.config.reschedule = reschedule
    deck.config.preview_again_secs = again
    deck.config.preview_hard_secs = hard
    deck.config.preview_good_secs = good
    del deck.config.search_terms[:]
    for search, limit, order in terms:
        term = deck.config.search_terms.add()
        term.search = search
        term.limit = limit
        term.order = order
    deck.allow_empty = allow_empty


def check_filtered_options():
    oracle_path, swift_root = prepare("sched")
    oracle = Collection(oracle_path)
    try:
        default_deck = oracle.sched.get_or_create_filtered_deck(0)
        default_options = {
            "terms": [[term.search, term.limit, int(term.order)] for term in default_deck.config.search_terms],
            "reschedule": default_deck.config.reschedule,
            "previewDelay": default_deck.config.preview_delay,
            "previewAgainSecs": default_deck.config.preview_again_secs,
            "previewHardSecs": default_deck.config.preview_hard_secs,
            "previewGoodSecs": default_deck.config.preview_good_secs,
        }

        first = oracle.sched.get_or_create_filtered_deck(0)
        configure_filtered_deck(
            first,
            name="Parity Filtered",
            terms=[
                ("deck:Lang is:review", 5, Deck.Filtered.SearchTerm.OLDEST_REVIEWED_FIRST),
                ("deck:Math is:new", 4, Deck.Filtered.SearchTerm.DUE),
            ],
            reschedule=False,
            again=75,
            hard=480,
            good=0,
        )
        first_id = oracle.sched.add_or_update_filtered_deck(first).id
        created = filtered_options_snapshot(oracle, first_id)

        second = oracle.sched.get_or_create_filtered_deck(first_id)
        configure_filtered_deck(
            second,
            name="  Parity Filtered Updated  ",
            terms=[("deck:Math is:new", 3, Deck.Filtered.SearchTerm.REVERSE_ADDED)],
            reschedule=True,
            again=30,
            hard=90,
            good=120,
        )
        second_id = oracle.sched.add_or_update_filtered_deck(second).id
        updated = filtered_options_snapshot(oracle, second_id)

        empty_update_rejected = False
        rejected = oracle.sched.get_or_create_filtered_deck(second_id)
        configure_filtered_deck(
            rejected,
            name="Parity Filtered Updated",
            terms=[("cid:9999999999999999", 1, Deck.Filtered.SearchTerm.DUE)],
            reschedule=True,
            again=30,
            hard=90,
            good=120,
        )
        try:
            oracle.sched.add_or_update_filtered_deck(rejected)
        except Exception:
            empty_update_rejected = True
        after_rejected_update = filtered_options_snapshot(oracle, second_id)

        emptied = oracle.sched.get_or_create_filtered_deck(second_id)
        configure_filtered_deck(
            emptied,
            name="Parity Filtered Updated",
            terms=[("cid:9999999999999999", 1, Deck.Filtered.SearchTerm.DUE)],
            reschedule=True,
            again=30,
            hard=90,
            good=120,
            allow_empty=True,
        )
        empty_id = oracle.sched.add_or_update_filtered_deck(emptied).id
        empty_allowed = filtered_options_snapshot(oracle, empty_id)

        expected = {
            "defaults": default_options,
            "created": created,
            "updated": updated,
            "emptyUpdateRejected": empty_update_rejected,
            "afterRejectedUpdate": after_rejected_update,
            "emptyAllowed": empty_allowed,
        }
    finally:
        oracle.close()

    actual = run_harness(swift_root, "filtered-options-actions")
    problems = diff("filtered:options", expected, actual)
    actual_collection_path = os.path.join(swift_root, "User 1", "collection.anki2")
    actual_collection = Collection(actual_collection_path)
    try:
        actual_deck = actual_collection.decks.by_name("Parity Filtered Updated")
        if not actual_deck:
            problems.append("filtered:options/persisted: baralho atualizado não foi lido pelo backend Anki")
        else:
            problems += diff(
                "filtered:options/persisted-wire",
                expected["emptyAllowed"]["options"],
                filtered_options_from_deck(actual_deck),
            )
            problems += diff(
                "filtered:options/persisted-state",
                expected["emptyAllowed"],
                filtered_options_snapshot(actual_collection, actual_deck["id"]),
            )
    finally:
        actual_collection.close()
    return problems


def check_icloud_merge():
    root = tempfile.mkdtemp(prefix="ankios-icloud-merge-", dir=WORK)
    set_lang("en")
    base = os.path.join(root, "base.anki2")
    local_path = os.path.join(root, "local.anki2")
    cloud_path = os.path.join(root, "cloud.anki2")
    output_path = os.path.join(root, "merged.anki2")
    now = int(time.time())
    collision_note_id = int(time.time() * 1000) + 100_000
    collision_card_id = collision_note_id + 100

    try:
        base_col = Collection(base)
        deck_id = base_col.decks.id("iCloud Merge")
        ids = _add_notes(base_col, deck_id, "Basic", [
            ["shared conflict", "base"],
            ["local edit", "base"],
            ["cloud edit", "base"],
            ["deleted locally", "base"],
        ])
        base_guids = {
            name: base_col.db.scalar("select guid from notes where id=?", nid)
            for name, nid in zip(("conflict", "local", "cloud", "deleted"), ids)
        }
        base_col.close(downgrade=True)
        shutil.copy(base, local_path)
        shutil.copy(base, cloud_path)

        local_col = Collection(local_path)
        note = local_col.get_note(ids[0])
        note.fields[1] = "local wins"
        local_col.update_note(note)
        local_col.db.execute("update notes set mod=? where id=?", now + 4000, ids[0])

        note = local_col.get_note(ids[1])
        note.fields[1] = "local independent edit"
        local_col.update_note(note)
        local_col.db.execute("update notes set mod=? where id=?", now + 3000, ids[1])

        local_only = local_col.new_note(local_col.models.by_name("Basic"))
        local_only.fields = ["local only", "kept"]
        local_col.add_note(local_only, deck_id)
        local_original_id = local_only.id
        local_col.db.execute("update notes set id=?, mod=? where id=?", collision_note_id, now + 2500, local_original_id)
        local_col.db.execute(
            "update cards set id=?, nid=? where nid=?",
            collision_card_id,
            collision_note_id,
            local_original_id,
        )
        local_col.remove_notes([ids[3]])
        local_col.db.execute("update col set mod=? where id=1", now + 4000)
        local_col.close(downgrade=True)

        cloud_col = Collection(cloud_path)
        note = cloud_col.get_note(ids[0])
        note.fields[1] = "cloud older"
        cloud_col.update_note(note)
        cloud_col.db.execute("update notes set mod=? where id=?", now + 2000, ids[0])

        note = cloud_col.get_note(ids[2])
        note.fields[1] = "cloud independent edit"
        cloud_col.update_note(note)
        cloud_col.db.execute("update notes set mod=? where id=?", now + 3500, ids[2])

        cloud_only = cloud_col.new_note(cloud_col.models.by_name("Basic"))
        cloud_only.fields = ["cloud only", "kept"]
        cloud_col.add_note(cloud_only, deck_id)
        cloud_original_id = cloud_only.id
        cloud_col.db.execute("update notes set id=?, mod=? where id=?", collision_note_id, now + 3000, cloud_original_id)
        cloud_col.db.execute(
            "update cards set id=?, nid=? where nid=?",
            collision_card_id,
            collision_note_id,
            cloud_original_id,
        )
        cloud_col.db.execute("update col set mod=? where id=1", now + 3500)
        cloud_col.close(downgrade=True)

        _, swift_root = prepare("sched")
        run_harness(swift_root, "icloud-merge", local_path, cloud_path, output_path)

        connection = sqlite3.connect(output_path)
        rows = connection.execute("select guid, flds, id from notes").fetchall()
        cards = connection.execute("select nid, id from cards").fetchall()
        graves = connection.execute("select oid, type from graves").fetchall()
        connection.close()
        fields_by_guid = {guid: fields.split("\x1f") for guid, fields, _ in rows}
        ids_by_guid = {guid: nid for guid, _, nid in rows}
        expected = {
            "noteCount": 5,
            "cardCount": 5,
            "conflictBack": "local wins",
            "localEditBack": "local independent edit",
            "cloudEditBack": "cloud independent edit",
            "localOnly": True,
            "cloudOnly": True,
            "deletedNoteAbsent": True,
            "noteIDsUnique": True,
            "cardIDsUnique": True,
            "cardNotesPresent": True,
            "cloudCollisionRemapped": True,
            "localCollisionPreserved": True,
            "deletionGravePreserved": True,
        }
        actual = {
            "noteCount": len(rows),
            "cardCount": len(cards),
            "conflictBack": fields_by_guid[base_guids["conflict"]][1],
            "localEditBack": fields_by_guid[base_guids["local"]][1],
            "cloudEditBack": fields_by_guid[base_guids["cloud"]][1],
            "localOnly": any(fields[0] == "local only" and fields[1] == "kept" for fields in fields_by_guid.values()),
            "cloudOnly": any(fields[0] == "cloud only" and fields[1] == "kept" for fields in fields_by_guid.values()),
            "deletedNoteAbsent": base_guids["deleted"] not in fields_by_guid,
            "noteIDsUnique": len(ids_by_guid.values()) == len(set(ids_by_guid.values())),
            "cardIDsUnique": len(cards) == len({cid for _, cid in cards}),
            "cardNotesPresent": all(nid in set(ids_by_guid.values()) for nid, _ in cards),
            "cloudCollisionRemapped": ids_by_guid.get(next((guid for guid, fields in fields_by_guid.items() if fields[0] == "cloud only"), "")) != collision_note_id,
            "localCollisionPreserved": ids_by_guid.get(next((guid for guid, fields in fields_by_guid.items() if fields[0] == "local only"), "")) == collision_note_id,
            "deletionGravePreserved": any(oid == ids[3] and grave_type == 1 for oid, grave_type in graves),
        }
        return diff("icloud:merge-conflicts-and-recovery", expected, actual)
    finally:
        shutil.rmtree(root, ignore_errors=True)
        set_lang("pt_BR")


def check_icloud_sync():
    root = tempfile.mkdtemp(prefix="ankios-icloud-sync-", dir=WORK)
    set_lang("en")
    base = os.path.join(root, "base.anki2")
    device_a = os.path.join(root, "device-a", "Profiles")
    device_b = os.path.join(root, "device-b", "Profiles")
    cloud = os.path.join(root, "cloud", "Profiles")
    now = int(time.time())

    try:
        base_col = Collection(base)
        deck_id = base_col.decks.id("iCloud Sync")
        note_ids = _add_notes(base_col, deck_id, "Basic", [
            ["shared conflict", "base"],
            ["local independent", "base"],
            ["cloud independent", "base"],
        ])
        base_col.close(downgrade=True)

        for profile_name in ("Main", "Deleted", "Recreated", "LocalOnly"):
            profile = os.path.join(device_a, profile_name)
            os.makedirs(profile, exist_ok=True)
            shutil.copy(base, os.path.join(profile, "collection.anki2"))
            with open(os.path.join(profile, ".ankios-created-at"), "w", encoding="utf-8") as marker:
                marker.write("100")

        media_a = os.path.join(device_a, "Main", "collection.media")
        os.makedirs(media_a, exist_ok=True)
        media_baseline = {
            "stable.bin": b"stable",
            "delete-local.bin": b"delete from device A",
            "delete-remote.bin": b"delete from device B",
            "diverge.bin": b"baseline",
        }
        for name, contents in media_baseline.items():
            with open(os.path.join(media_a, name), "wb") as media_file:
                media_file.write(contents)

        first = run_harness(device_a, "icloud-sync", cloud)
        second = run_harness(device_b, "icloud-sync", cloud)
        local_media_b = os.path.join(device_b, "Main", "collection.media")
        media_downloaded = all(
            open(os.path.join(local_media_b, name), "rb").read() == contents
            for name, contents in media_baseline.items()
        )

        cloud_only = os.path.join(cloud, "CloudOnly")
        os.makedirs(cloud_only, exist_ok=True)
        shutil.copy(base, os.path.join(cloud_only, "collection.anki2"))
        with open(os.path.join(cloud_only, ".ankios-created-at"), "w", encoding="utf-8") as marker:
            marker.write("1000")

        manifest = {"deletedAt": {"Deleted": 500, "Recreated": 500}}
        with open(os.path.join(device_a, ".ankios-icloud-profiles.json"), "w", encoding="utf-8") as manifest_file:
            json.dump(manifest, manifest_file, sort_keys=True)
        with open(os.path.join(device_a, "Recreated", ".ankios-created-at"), "w", encoding="utf-8") as marker:
            marker.write("600")

        connection = sqlite3.connect(os.path.join(device_a, "Main", "collection.anki2"))
        connection.execute("update notes set flds=?, mod=?, usn=-1 where id=?", ("shared conflict" + chr(31) + "device A wins", now + 5000, note_ids[0]))
        connection.execute("update notes set flds=?, mod=?, usn=-1 where id=?", ("local independent" + chr(31) + "device A edit", now + 4000, note_ids[1]))
        connection.execute("update col set mod=? where id=1", (now + 5000,))
        connection.commit()
        connection.close()

        connection = sqlite3.connect(os.path.join(device_b, "Main", "collection.anki2"))
        connection.execute("update notes set flds=?, mod=?, usn=-1 where id=?", ("shared conflict" + chr(31) + "device B older edit", now + 3000, note_ids[0]))
        connection.execute("update notes set flds=?, mod=?, usn=-1 where id=?", ("cloud independent" + chr(31) + "device B edit", now + 6000, note_ids[2]))
        connection.execute("update col set mod=? where id=1", (now + 6000,))
        connection.commit()
        connection.close()

        os.remove(os.path.join(media_a, "delete-local.bin"))
        media_b = os.path.join(device_b, "Main", "collection.media")
        os.remove(os.path.join(media_b, "delete-remote.bin"))
        with open(os.path.join(media_a, "diverge.bin"), "wb") as media_file:
            media_file.write(b"device A version")
        with open(os.path.join(media_b, "diverge.bin"), "wb") as media_file:
            media_file.write(b"device B newer version")
        newer_timestamp = time.time() + 20
        os.utime(os.path.join(media_b, "diverge.bin"), (newer_timestamp, newer_timestamp))
        with open(os.path.join(cloud, "Main", "collection.media", "cloud-only.bin"), "wb") as media_file:
            media_file.write(b"created in cloud")

        sync_a = run_harness(device_a, "icloud-sync", cloud)
        sync_b = run_harness(device_b, "icloud-sync", cloud)
        sync_a_final = run_harness(device_a, "icloud-sync", cloud)
        sync_b_final = run_harness(device_b, "icloud-sync", cloud)
        idempotent = run_harness(device_b, "icloud-sync", cloud)

        database_a = os.path.join(device_a, "Main", "collection.anki2")
        database_b = os.path.join(device_b, "Main", "collection.anki2")
        with sqlite3.connect(database_a) as connection:
            note_fields = {
                note_id: fields.split(chr(31))
                for note_id, fields in connection.execute("select id, flds from notes")
            }
        profile_names_a = set(os.listdir(device_a))
        profile_names_b = set(os.listdir(device_b))
        profile_names_cloud = set(os.listdir(cloud))
        with open(os.path.join(device_a, ".ankios-icloud-profiles.json"), encoding="utf-8") as manifest_file:
            final_manifest = json.load(manifest_file)

        media_names_a = set(os.listdir(os.path.join(device_a, "Main", "collection.media")))
        media_names_b = set(os.listdir(os.path.join(device_b, "Main", "collection.media")))
        media_names_cloud = set(os.listdir(os.path.join(cloud, "Main", "collection.media")))
        media_roots = (
            os.path.join(device_a, "Main", "collection.media"),
            os.path.join(device_b, "Main", "collection.media"),
            os.path.join(cloud, "Main", "collection.media"),
        )
        media_equal = media_names_a == media_names_b == media_names_cloud and all(
            open(os.path.join(media_roots[0], name), "rb").read()
            == open(os.path.join(media_roots[1], name), "rb").read()
            == open(os.path.join(media_roots[2], name), "rb").read()
            for name in media_names_a
        )
        backup_count = sum(
            len([name for name in os.listdir(os.path.join(profile_root, "Main", "Backups")) if name.endswith(".anki2")])
            if os.path.isdir(os.path.join(profile_root, "Main", "Backups")) else 0
            for profile_root in (device_a, device_b, cloud)
        )
        expected = {
            "firstUpload": True,
            "secondDeviceReceived": True,
            "initialMediaDownloaded": True,
            "localProfileReplicated": True,
            "cloudProfileDownloaded": True,
            "deletedProfileRemoved": True,
            "recreatedProfilePreserved": True,
            "tombstoneCleared": True,
            "localWinsNewerConflict": "device A wins",
            "localIndependentEditPreserved": "device A edit",
            "cloudIndependentEditPreserved": "device B edit",
            "deviceAReceivedMergedCollection": True,
            "deviceBIsCurrentAfterMerge": True,
            "mergedDatabasesConverged": True,
            "conflictBackupCount": 2,
            "conflictBackupSummary": True,
            "mediaDeletesReplicated": True,
            "newerMediaConflictWins": b"device B newer version",
            "cloudOnlyMediaReplicated": b"created in cloud",
            "mediaConverged": True,
            "idempotentSummary": "iCloud já estava em dia.",
        }
        actual = {
            "firstUpload": "coleção enviada" in first["summary"],
            "secondDeviceReceived": "coleção recebida" in second["summary"],
            "initialMediaDownloaded": media_downloaded,
            "localProfileReplicated": "LocalOnly" in set(os.listdir(cloud)),
            "cloudProfileDownloaded": "CloudOnly" in profile_names_b and "CloudOnly" in profile_names_a,
            "deletedProfileRemoved": all("Deleted" not in profiles for profiles in (profile_names_a, profile_names_b, profile_names_cloud)),
            "recreatedProfilePreserved": all("Recreated" in profiles for profiles in (profile_names_a, profile_names_b, profile_names_cloud)),
            "tombstoneCleared": "Recreated" not in final_manifest["deletedAt"] and "Deleted" in final_manifest["deletedAt"],
            "localWinsNewerConflict": note_fields[note_ids[0]][1],
            "localIndependentEditPreserved": note_fields[note_ids[1]][1],
            "cloudIndependentEditPreserved": note_fields[note_ids[2]][1],
            "deviceAReceivedMergedCollection": "coleção recebida" in sync_a_final["summary"],
            "deviceBIsCurrentAfterMerge": sync_b_final["summary"] == "iCloud já estava em dia.",
            "mergedDatabasesConverged": all(hashlib.sha256(open(path, "rb").read()).digest() == hashlib.sha256(open(database_a, "rb").read()).digest() for path in (database_b, os.path.join(cloud, "Main", "collection.anki2"))),
            "conflictBackupCount": backup_count,
            "conflictBackupSummary": "conflitante(s) salva(s)" in sync_b["summary"],
            "mediaDeletesReplicated": "delete-local.bin" not in media_names_a | media_names_b | media_names_cloud and "delete-remote.bin" not in media_names_a | media_names_b | media_names_cloud,
            "newerMediaConflictWins": open(os.path.join(device_a, "Main", "collection.media", "diverge.bin"), "rb").read(),
            "cloudOnlyMediaReplicated": open(os.path.join(device_a, "Main", "collection.media", "cloud-only.bin"), "rb").read(),
            "mediaConverged": media_equal,
            "idempotentSummary": idempotent["summary"],
        }
        return diff("icloud:sync-orchestration", expected, actual)
    finally:
        shutil.rmtree(root, ignore_errors=True)
        set_lang("pt_BR")


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

    selected_official_export = os.path.join(work, "official-selected-note.tsv")
    selected_app_export = os.path.join(work, "app-selected-note.tsv")
    selected_collection = Collection(oracle_path)
    try:
        selected_note_id = selected_collection.db.scalar("select id from notes order by id limit 1")
        selected_collection.export_note_csv(
            out_path=selected_official_export,
            limit=NoteIdsLimit(note_ids=[selected_note_id]),
            with_html=True,
            with_tags=True,
            with_deck=True,
            with_notetype=True,
            with_guid=True,
        )
    finally:
        selected_collection.close()
    run_harness(swift_root, "csv-export-notes", selected_app_export, str(selected_note_id))
    with open(selected_app_export, encoding="utf-8") as file:
        selected_app_text = file.read()
    with open(selected_official_export, encoding="utf-8") as file:
        selected_official_text = file.read()
    problems += diff(
        "csv:export-selected-note",
        selected_official_text.splitlines(),
        selected_app_text.splitlines(),
    )

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


def _package_archive_entries(path):
    with zipfile.ZipFile(path) as archive:
        return [(entry.filename, archive.read(entry.filename)) for entry in archive.infolist()]


def _write_package_archive(path, entries, compression=zipfile.ZIP_STORED):
    with zipfile.ZipFile(path, "w", compression=compression) as archive:
        for name, content in entries:
            archive.writestr(name, content)


def _make_zip64_package(source, destination):
    _write_package_archive(destination, _package_archive_entries(source))
    data = bytearray(open(destination, "rb").read())
    eocd = data.rfind(b"PK\x05\x06")
    _, _, _, _, entry_count, directory_size, directory_offset, _ = struct.unpack_from("<IHHHHIIH", data, eocd)
    zip64_record = struct.pack(
        "<IQHHIIQQQQ",
        0x06064B50,
        44,
        45,
        45,
        0,
        0,
        entry_count,
        entry_count,
        directory_size,
        directory_offset,
    )
    locator = struct.pack("<IIQI", 0x07064B50, 0, eocd, 1)
    output = bytearray(data[:eocd] + zip64_record + locator + data[eocd:])
    struct.pack_into("<HHHHII", output, eocd + 4, 0, 0, 0xFFFF, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF)
    with open(destination, "wb") as archive:
        archive.write(output)


def _mark_package_entry_encrypted(path, entry_name):
    data = bytearray(open(path, "rb").read())
    eocd = data.rfind(b"PK\x05\x06")
    entry_count = struct.unpack_from("<H", data, eocd + 10)[0]
    offset = struct.unpack_from("<I", data, eocd + 16)[0]
    for _ in range(entry_count):
        if data[offset:offset + 4] != b"PK\x01\x02":
            raise ValueError("invalid package central directory")
        name_length, extra_length, comment_length = struct.unpack_from("<HHH", data, offset + 28)
        name_start = offset + 46
        name = bytes(data[name_start:name_start + name_length]).decode("utf-8")
        if name == entry_name:
            flags = struct.unpack_from("<H", data, offset + 8)[0] | 1
            local_offset = struct.unpack_from("<I", data, offset + 42)[0]
            struct.pack_into("<H", data, offset + 8, flags)
            struct.pack_into("<H", data, local_offset + 6, flags)
            with open(path, "wb") as archive:
                archive.write(data)
            return
        offset = name_start + name_length + extra_length + comment_length
    raise ValueError(f"package entry not found: {entry_name}")


def _archive_collection_counts(path):
    db = sqlite3.connect(path)
    try:
        return {
            "notes": db.execute("select count(*) from notes").fetchone()[0],
            "cards": db.execute("select count(*) from cards").fetchone()[0],
        }
    finally:
        db.close()


def check_package_archive_edges(source_package, package_work):
    edge_root = os.path.join(package_work, "archive-edge-cases")
    shutil.rmtree(edge_root, ignore_errors=True)
    os.makedirs(edge_root)
    entries = _package_archive_entries(source_package)
    cases = {}

    zip64_path = os.path.join(edge_root, "zip64.apkg")
    _make_zip64_package(source_package, zip64_path)
    cases["zip64"] = (zip64_path, True)

    for name, compression in (("bzip2", zipfile.ZIP_BZIP2), ("lzma", zipfile.ZIP_LZMA)):
        path = os.path.join(edge_root, f"{name}.apkg")
        _write_package_archive(path, entries, compression)
        cases[name] = (path, False)

    encrypted_path = os.path.join(edge_root, "encrypted-entry.apkg")
    _write_package_archive(encrypted_path, entries)
    _mark_package_entry_encrypted(encrypted_path, "meta")
    cases["encrypted-entry"] = (encrypted_path, False)

    version_path = os.path.join(edge_root, "unsupported-version.apkg")
    _write_package_archive(
        version_path,
        [(name, b"\x08\x04" if name == "meta" else content) for name, content in entries],
    )
    cases["unsupported-version"] = (version_path, False)

    missing_collection_path = os.path.join(edge_root, "missing-collection.apkg")
    _write_package_archive(missing_collection_path, [("meta", b"\x08\x03")])
    cases["missing-collection"] = (missing_collection_path, False)

    problems = []
    for name, (package_path, expected_acceptance) in cases.items():
        official_path = os.path.join(edge_root, f"{name}-official.anki2")
        official = Collection(official_path)
        official_before = {
            "notes": official.db.scalar("select count(*) from notes"),
            "cards": official.db.scalar("select count(*) from cards"),
        }
        try:
            try:
                official.import_anki_package(ImportAnkiPackageRequest(package_path=package_path))
                official_accepted = True
            except Exception:
                official_accepted = False
            official_after = {
                "notes": official.db.scalar("select count(*) from notes"),
                "cards": official.db.scalar("select count(*) from cards"),
            }
        finally:
            official.close()

        app_root = os.path.join(edge_root, f"{name}-app")
        os.makedirs(os.path.join(app_root, "User 1"))
        proc = subprocess.run(
            [HARNESS, "import", package_path],
            capture_output=True,
            text=True,
            env=dict(os.environ, ANKIOS_PROFILES_ROOT=app_root),
        )
        app_accepted = proc.returncode == 0
        app_after = _archive_collection_counts(os.path.join(app_root, "User 1", "collection.anki2"))

        if official_accepted != expected_acceptance:
            problems.append(
                f"packages:archive-edge-cases:{name}: referência aceitou={official_accepted}, esperado={expected_acceptance}"
            )
        if app_accepted != official_accepted:
            problems.append(
                f"packages:archive-edge-cases:{name}: aceitação Anki={official_accepted}, AnkiOS={app_accepted}"
            )
        expected_counts = official_after if official_accepted else official_before
        if not official_accepted and official_after != official_before:
            problems.append(
                f"packages:archive-edge-cases:{name}: Anki alterou a coleção após rejeitar o arquivo"
            )
        if not app_accepted and app_after != official_before:
            problems.append(
                f"packages:archive-edge-cases:{name}: AnkiOS alterou a coleção após rejeitar o arquivo"
            )
        if app_accepted and app_after != expected_counts:
            problems.append(
                f"packages:archive-edge-cases:{name}: contagens Anki={expected_counts}, AnkiOS={app_after}"
            )
    return problems


def check_selected_deck_export():
    oracle_path, swift_root = prepare("sched")
    package_work = os.path.join(WORK, "selected-deck-export")
    shutil.rmtree(package_work, ignore_errors=True)
    os.makedirs(package_work)

    source = Collection(oracle_path)
    try:
        selected_id = source.decks.id("Parity Export")
        child_id = source.decks.id("Parity Export::Child")
        unrelated_id = source.decks.id("Parity Export Unrelated")
        basic = source.models.by_name("Basic")
        for front, back, deck_id in [
            ("parity selected parent", "parent answer", selected_id),
            ("parity selected child", "child answer", child_id),
            ("parity unrelated", "unrelated answer", unrelated_id),
        ]:
            note = source.new_note(basic)
            note.fields[0] = front
            note.fields[1] = back
            source.add_note(note, deck_id)
        source.close(downgrade=True)
    finally:
        try:
            source.close()
        except Exception:
            pass

    swift_collection = os.path.join(swift_root, "User 1", "collection.anki2")
    shutil.copy2(oracle_path, swift_collection)
    from anki.media import media_paths_from_col_path
    source_media, _ = media_paths_from_col_path(oracle_path)
    swift_media, _ = media_paths_from_col_path(swift_collection)
    shutil.rmtree(swift_media, ignore_errors=True)
    if os.path.isdir(source_media):
        shutil.copytree(source_media, swift_media)

    options = ExportAnkiPackageOptions(
        with_scheduling=False,
        with_deck_configs=False,
        with_media=True,
        legacy=False,
    )
    official_package = os.path.join(package_work, "official.apkg")
    reference = Collection(oracle_path)
    try:
        reference.export_anki_package(
            out_path=official_package,
            options=options,
            limit=DeckIdLimit(deck_id=selected_id),
        )
    finally:
        reference.close()

    app_package = os.path.join(package_work, "ankios.apkg")
    run_harness(swift_root, "export-deck", str(selected_id), app_package)

    imported = {}
    for name, package_path in (("official", official_package), ("ankios", app_package)):
        collection_path = os.path.join(package_work, f"{name}-imported.anki2")
        collection = Collection(collection_path)
        try:
            collection.import_anki_package(
                ImportAnkiPackageRequest(
                    package_path=package_path,
                    options=ImportAnkiPackageOptions(
                        merge_notetypes=True,
                        with_scheduling=False,
                        with_deck_configs=True,
                    ),
                )
            )
        finally:
            collection.close()
        media_path, _ = media_paths_from_col_path(collection_path)
        imported[name] = package_snapshot(collection_path, media_path)

    problems = diff("packages:selected-deck-export", imported["official"], imported["ankios"])
    expected_fronts = {"parity selected parent", "parity selected child"}
    actual_fronts = {note["fields"].split("\x1f", 1)[0] for note in imported["ankios"]["notes"]}
    if actual_fronts != expected_fronts:
        problems.append(
            f"packages:selected-deck-export/scope: esperado={sorted(expected_fronts)}, AnkiOS={sorted(actual_fronts)}"
        )
    return problems


def check_selected_cards_export():
    oracle_path, swift_root = prepare("sched")
    package_work = os.path.join(WORK, "selected-cards-export")
    shutil.rmtree(package_work, ignore_errors=True)
    os.makedirs(package_work)

    source = Collection(oracle_path)
    try:
        cloze = source.models.by_name("Cloze")
        note = source.new_note(cloze)
        note.fields[0] = "parity first {{c1::deletion}} and second {{c2::deletion}}"
        source.add_note(note, source.decks.id("Default"))
        selected_card_ids = source.card_ids_of_note(note.id)
        unrelated = source.new_note(source.models.by_name("Basic"))
        unrelated.fields[0] = "parity unrelated card"
        unrelated.fields[1] = "must stay out"
        source.add_note(unrelated, source.decks.id("Parity Cards Unrelated"))
        source.close(downgrade=True)
    finally:
        try:
            source.close()
        except Exception:
            pass

    swift_collection = os.path.join(swift_root, "User 1", "collection.anki2")
    shutil.copy2(oracle_path, swift_collection)
    from anki.media import media_paths_from_col_path
    source_media, _ = media_paths_from_col_path(oracle_path)
    swift_media, _ = media_paths_from_col_path(swift_collection)
    shutil.rmtree(swift_media, ignore_errors=True)
    if os.path.isdir(source_media):
        shutil.copytree(source_media, swift_media)

    options = ExportAnkiPackageOptions(
        with_scheduling=False,
        with_deck_configs=False,
        with_media=True,
        legacy=False,
    )
    official_package = os.path.join(package_work, "official.apkg")
    reference = Collection(oracle_path)
    try:
        reference.export_anki_package(
            out_path=official_package,
            options=options,
            limit=CardIdsLimit(card_ids=[selected_card_ids[0]]),
        )
    finally:
        reference.close()

    app_package = os.path.join(package_work, "ankios.apkg")
    run_harness(swift_root, "export-cards", app_package, str(selected_card_ids[0]))

    imported = {}
    for name, package_path in (("official", official_package), ("ankios", app_package)):
        collection_path = os.path.join(package_work, f"{name}-imported.anki2")
        collection = Collection(collection_path)
        try:
            collection.import_anki_package(
                ImportAnkiPackageRequest(
                    package_path=package_path,
                    options=ImportAnkiPackageOptions(
                        merge_notetypes=True,
                        with_scheduling=False,
                        with_deck_configs=True,
                    ),
                )
            )
        finally:
            collection.close()
        media_path, _ = media_paths_from_col_path(collection_path)
        imported[name] = package_snapshot(collection_path, media_path)

    problems = diff("packages:selected-cards-export", imported["official"], imported["ankios"])
    expected_fronts = {note.fields[0]}
    actual_fronts = {item["fields"].split("\x1f", 1)[0] for item in imported["ankios"]["notes"]}
    if actual_fronts != expected_fronts or len(imported["ankios"]["cards"]) != 2:
        problems.append(
            "packages:selected-cards-export/scope: Anki exportou o cartão selecionado e seu irmão Cloze, "
            "sem a nota independente; "
            f"notes={sorted(actual_fronts)}, cards={len(imported['ankios']['cards'])}"
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

    routing_names = ["Deck.APkg", "Full.COLPKG", "legacy.DB", "archive.zip", "notes.txt"]
    routing_expected = [
        {"extension": "apkg", "route": "deckPackage", "systemOpen": True},
        {"extension": "colpkg", "route": "collectionPackage", "systemOpen": True},
        {"extension": "db", "route": "mnemosyneDatabase", "systemOpen": False},
        {"extension": "zip", "route": "deckPackage", "systemOpen": False},
        {"extension": "txt", "route": "deckPackage", "systemOpen": False},
    ]
    routing_actual = run_harness(swift_root, "package-routing", *routing_names)
    problems += diff("packages:system-routing", routing_expected, routing_actual)

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
        official = Collection(official_path)
        try:
            rendered_expected = card_render_snapshot(official)
        finally:
            official.close()
        rendered_actual = run_harness(swift_root, "render-cards")
        rendered_actual.sort(key=lambda card: (card["guid"], card["ordinal"]))
        render_keys = ("guid", "ordinal", "questionText", "answerText", "questionSounds")
        rendered_actual = [{key: card[key] for key in render_keys} for card in rendered_actual]
        problems += diff("packages:real-anki-deck-rendering", rendered_expected, rendered_actual)

        io_collection = Collection(official_path)
        try:
            io_model = next(
                model for model in io_collection.models.all()
                if model["type"] == 1
                and any(field["name"].lower() in {"occlusion", "occlusions", "oclusão"} for field in model["flds"])
                and any(field["name"].lower() in {"image", "imagem"} for field in model["flds"])
            )
            io_note = io_collection.new_note(io_model)
            io_values = {
                "occlusion": "{{c1::image-occlusion:rect:left=0.1000:top=0.1000:width=0.2500:height=0.3000:angle=1250:fill=#44aa33:oi=1}} {{c2::image-occlusion:ellipse:left=0.5000:top=0.5000:rx=0.1000:ry=0.1500:angle=2500:oi=1}} {{c3::image-occlusion:polygon:points=0.1000,0.1000 0.2000,0.1000 0.1500,0.2000:fill=#ff0000:oi=1}} {{c4::image-occlusion:text:text=alpha\\:beta\\::left=0.6000:top=0.2000:scale=1.0000:fs=0.0400:fill=#222222:oi=1}} {{c5::image-occlusion:rect:left=0.3000:top=0.3000:width=0.2000:height=0.2000:oi=1}}",
                "occlusions": "{{c1::image-occlusion:rect:left=0.1000:top=0.1000:width=0.2500:height=0.3000:angle=1250:fill=#44aa33:oi=1}} {{c2::image-occlusion:ellipse:left=0.5000:top=0.5000:rx=0.1000:ry=0.1500:angle=2500:oi=1}} {{c3::image-occlusion:polygon:points=0.1000,0.1000 0.2000,0.1000 0.1500,0.2000:fill=#ff0000:oi=1}} {{c4::image-occlusion:text:text=alpha\\:beta\\::left=0.6000:top=0.2000:scale=1.0000:fs=0.0400:fill=#222222:oi=1}} {{c5::image-occlusion:rect:left=0.3000:top=0.3000:width=0.2000:height=0.2000:oi=1}}",
                "oclusão": "{{c1::image-occlusion:rect:left=0.1000:top=0.1000:width=0.2500:height=0.3000:angle=1250:fill=#44aa33:oi=1}} {{c2::image-occlusion:ellipse:left=0.5000:top=0.5000:rx=0.1000:ry=0.1500:angle=2500:oi=1}} {{c3::image-occlusion:polygon:points=0.1000,0.1000 0.2000,0.1000 0.1500,0.2000:fill=#ff0000:oi=1}} {{c4::image-occlusion:text:text=alpha\\:beta\\::left=0.6000:top=0.2000:scale=1.0000:fs=0.0400:fill=#222222:oi=1}} {{c5::image-occlusion:rect:left=0.3000:top=0.3000:width=0.2000:height=0.2000:oi=1}}",
                "image": '<img src="io-parity.png">',
                "imagem": '<img src="io-parity.png">',
                "header": "IO parity header",
                "cabeçalho": "IO parity header",
                "back extra": "IO parity extra",
                "verso extra": "IO parity extra",
                "comments": "IO parity comment",
                "comentário": "IO parity comment",
            }
            for index, field in enumerate(io_model["flds"]):
                io_note.fields[index] = io_values.get(field["name"].lower(), "")
            with open(os.path.join(official_media, "io-parity.png"), "wb") as image_file:
                image_file.write(png)
            io_collection.add_note(io_note, io_collection.decks.id("IO parity"))
            io_guid = io_note.guid
            mixed_values = dict(io_values)
            for field_name in ("occlusion", "occlusions", "oclusão"):
                mixed_values[field_name] = mixed_values[field_name].replace(
                    ":angle=2500:oi=1", ":angle=2500"
                ).replace(":fill=#222222:oi=1", ":fill=#222222")
            mixed_note = io_collection.new_note(io_model)
            for index, field in enumerate(io_model["flds"]):
                mixed_note.fields[index] = mixed_values.get(field["name"].lower(), "")
            io_collection.add_note(mixed_note, io_collection.decks.id("IO parity"))
            io_mixed_guid = mixed_note.guid
            ellipse_values = dict(io_values)
            ellipse_field = "{{c1::image-occlusion:ellipse:left=0.5000:top=0.5000:rx=0.1000:ry=0.1500}}"
            for field_name in ("occlusion", "occlusions", "oclusão"):
                ellipse_values[field_name] = ellipse_field
            ellipse_note = io_collection.new_note(io_model)
            for index, field in enumerate(io_model["flds"]):
                ellipse_note.fields[index] = ellipse_values.get(field["name"].lower(), "")
            io_collection.add_note(ellipse_note, io_collection.decks.id("IO parity"))
            io_ellipse_guid = ellipse_note.guid
            io_guids = [io_guid, io_mixed_guid, io_ellipse_guid]
            io_expected = card_render_snapshot(io_collection, io_guids)
            io_expected_masks = {}
            io_expected_behavior = {}
            for guid in io_guids:
                io_expected_masks.update({
                    f"{guid}:{ordinal}": masks
                    for ordinal, masks in image_occlusion_render_snapshot(io_collection, guid).items()
                })
                io_expected_behavior[guid] = image_occlusion_behavior_snapshot(
                    io_collection, guid
                )
            io_package = os.path.join(real_work, "image-occlusion-parity.apkg")
            io_collection.export_anki_package(
                out_path=io_package,
                options=ExportAnkiPackageOptions(
                    with_scheduling=False,
                    with_deck_configs=False,
                    with_media=True,
                    legacy=False,
                ),
                limit=None,
            )
        finally:
            io_collection.close()

        io_swift_root = os.path.join(real_work, "image-occlusion-swift")
        os.makedirs(os.path.join(io_swift_root, "User 1"))
        run_harness(io_swift_root, "import", io_package, "--merge-notetypes")
        io_actual = [
            row for row in run_harness(io_swift_root, "render-cards")
            if row["guid"] in io_guids
        ]
        io_actual.sort(key=lambda row: (row["guid"], row["ordinal"]))
        io_render_keys = ("guid", "ordinal", "questionText", "answerText", "questionSounds")
        io_actual_projection = [{key: row[key] for key in io_render_keys} for row in io_actual]
        io_expected_projection = [{key: row[key] for key in io_render_keys} for row in io_expected]
        problems += diff("packages:image-occlusion-rendering", io_expected_projection, io_actual_projection)
        io_actual_masks = {}
        io_actual_behavior = {guid: {} for guid in io_guids}
        for row in io_actual:
            parser = ImageOcclusionAttributeParser()
            parser.feed(row["questionHTML"])
            io_actual_masks[f"{row['guid']}:{row['ordinal']}"] = sorted(
                parser.rows,
                key=lambda item: (int(item.get("data-ordinal", "0")), item.get("data-shape", "")),
            )
            io_actual_behavior[row["guid"]][str(row["ordinal"])] = {
                "question": image_occlusion_behavior_from_html(row["questionHTML"]),
                "answer": image_occlusion_behavior_from_html(row["answerHTML"]),
            }
            if not row["questionImageOcclusionBridge"] or not row["answerImageOcclusionBridge"]:
                problems.append(f"packages:image-occlusion-rendering[{row['ordinal']}]: ponte do template oficial ausente")
            if not row["answerImageOcclusionToggleBound"]:
                problems.append(f"packages:image-occlusion-rendering[{row['ordinal']}]: botão oficial de alternância não conectado")
            if not row["questionImageOcclusionContainer"] or not row["answerImageOcclusionTogglePresent"]:
                problems.append(f"packages:image-occlusion-rendering[{row['ordinal']}]: elementos do template oficial ausentes")
        problems += diff("packages:image-occlusion-shape-attributes", io_expected_masks, io_actual_masks)
        problems += diff("packages:image-occlusion-render-states", io_expected_behavior, io_actual_behavior)

        def compare_io_editor_roundtrip(guid, expected_value, editable_count, preserved_count, shape_name):
            prefix = f"packages:image-occlusion-editor-{shape_name}"
            roundtrip = run_harness(io_swift_root, "image-occlusion-roundtrip", guid)
            edit_problems = []
            if roundtrip["editableMaskCount"] != editable_count or roundtrip["preservedMaskCount"] != preserved_count:
                edit_problems.append(
                    f"{prefix}: esperado {editable_count} máscaras editáveis e {preserved_count} preservadas, "
                    f"recebido {roundtrip['editableMaskCount']} editáveis e {roundtrip['preservedMaskCount']} preservadas"
                )
            edit_problems += diff(f"{prefix}:field", expected_value, roundtrip["occlusion"])

            edited_collection = Collection(official_path)
            try:
                note_id = edited_collection.db.scalar("select id from notes where guid=?", guid)
                edited_note = edited_collection.get_note(note_id)
                field_index = next(
                    index for index, field in enumerate(io_model["flds"])
                    if field["name"].lower() in {"occlusion", "occlusions", "oclusão"}
                )
                edited_note.fields[field_index] = roundtrip["occlusion"]
                edited_collection.update_note(edited_note)
                expected_cards = card_render_snapshot(edited_collection, [guid])
                expected_masks = {
                    f"{guid}:{ordinal}": masks
                    for ordinal, masks in image_occlusion_render_snapshot(edited_collection, guid).items()
                }
                expected_states = image_occlusion_behavior_snapshot(edited_collection, guid)
            finally:
                edited_collection.close()

            actual_cards = [
                row for row in run_harness(io_swift_root, "render-cards")
                if row["guid"] == guid
            ]
            actual_cards.sort(key=lambda row: (row["guid"], row["ordinal"]))
            actual_projection = [{key: row[key] for key in io_render_keys} for row in actual_cards]
            edit_problems += diff(f"{prefix}:cards", expected_cards, actual_projection)
            actual_masks = {}
            actual_states = {}
            for row in actual_cards:
                parser = ImageOcclusionAttributeParser()
                parser.feed(row["questionHTML"])
                actual_masks[f"{guid}:{row['ordinal']}"] = sorted(
                    parser.rows,
                    key=lambda item: (int(item.get("data-ordinal", "0")), item.get("data-shape", "")),
                )
                actual_states[str(row["ordinal"])] = {
                    "question": image_occlusion_behavior_from_html(row["questionHTML"]),
                    "answer": image_occlusion_behavior_from_html(row["answerHTML"]),
                }
            edit_problems += diff(f"{prefix}:shapes", expected_masks, actual_masks)
            edit_problems += diff(f"{prefix}:states", expected_states, actual_states)
            return edit_problems

        expected_rect_edit = io_values["occlusion"].replace(
            "{{c5::image-occlusion:rect:left=0.3000:",
            "{{c5::image-occlusion:rect:left=0.3100:",
        ) + (
            " {{c6::image-occlusion:rect:left=0.2500:top=0.4000:width=0.1200:height=0.1800:oi=1}}"
            " {{c7::image-occlusion:ellipse:left=0.6200:top=0.1000:rx=0.0700:ry=0.0400:oi=1}}"
        )
        problems += compare_io_editor_roundtrip(io_guid, expected_rect_edit, 1, 4, "rect")
        expected_ellipse_edit = (
            "{{c1::image-occlusion:ellipse:left=0.5100:top=0.5000:rx=0.1000:ry=0.1500}} "
            "{{c2::image-occlusion:rect:left=0.2500:top=0.4000:width=0.1200:height=0.1800}} "
            "{{c3::image-occlusion:ellipse:left=0.6200:top=0.1000:rx=0.0700:ry=0.0400}}"
        )
        problems += compare_io_editor_roundtrip(io_ellipse_guid, expected_ellipse_edit, 1, 0, "ellipse")
    problems += check_package_archive_edges(official_package, package_work)
    problems += check_selected_deck_export()
    problems += check_selected_cards_export()
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
        checks = ["timing", "counts", "states", "load-balancer", "fsrs-empty-steps", "grade-now", "study-undo", "typed-answer", "auto-advance-actions", "auto-advance-timers", "review-shortcuts", "korean-shortcuts", "widget", "media-check", "database-check", "profiles", "session", "search", "retention", "stats", "cardgen", "templates", "decks", "deck-options", "rich-media", "delete", "empty", "queue", "browser-sort", "browser-selection", "preferences", "sync", "tags", "notetypes", "latex", "filtered", "filtered-options", "packages", "csv"]
    total = 0
    for command in checks:
        if command == "grade-now":
            problems = check_grade_now()
        elif command == "study-undo":
            problems = check_study_undo()
        elif command == "typed-answer":
            problems = check_type_answer()
        elif command == "auto-advance-actions":
            problems = check_auto_advance_actions()
        elif command == "auto-advance-timers":
            problems = check_auto_advance_timers()
        elif command == "review-shortcuts":
            problems = check_review_shortcuts()
        elif command == "korean-shortcuts":
            problems = check_korean_shortcuts()
        elif command == "widget":
            problems = check_widget_grade()
        elif command == "media-check":
            problems = check_media_check()
        elif command == "database-check":
            problems = check_database_check()
        elif command == "profiles":
            problems = check_profiles()
        elif command == "fsrs-empty-steps":
            problems = check_fsrs_empty_steps()
        elif command == "packages":
            problems = check_packages()
        elif command == "deck-export":
            problems = check_selected_deck_export()
        elif command == "card-export":
            problems = check_selected_cards_export()
        elif command == "csv":
            problems = check_csv()
        elif command == "filtered":
            problems = check_filtered()
        elif command == "filtered-options":
            problems = check_filtered_options()
        elif command == "delete":
            problems = check_delete_actions()
        elif command == "decks":
            problems = check_deck_actions()
        elif command == "deck-options":
            problems = check_deck_options()
        elif command == "rich-media":
            problems = check_rich_media()
        elif command == "cardgen":
            problems = check_cardgen_actions()
        elif command == "templates":
            problems = check_templates()
        elif command == "empty":
            problems = check_empty_actions()
        elif command == "queue":
            problems = check_queue_actions()
        elif command == "browser-sort":
            problems = check_browser_sort()
        elif command == "browser-selection":
            problems = check_browser_selection()
        elif command == "preferences":
            problems = check_preferences_persist()
        elif command in ("load-balancer", "load-balancer-gap"):
            problems = check_load_balancer()
        elif command == "sync":
            problems = check_sync_actions()
        elif command == "icloud-merge":
            problems = check_icloud_merge()
        elif command == "icloud-sync":
            problems = check_icloud_sync()
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
