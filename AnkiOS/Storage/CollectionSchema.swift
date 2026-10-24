import Foundation

enum CollectionSchema {
    static let createSQL = """
    CREATE TABLE IF NOT EXISTS col (
      id integer primary key,
      crt integer not null,
      mod integer not null,
      scm integer not null,
      ver integer not null,
      dty integer not null,
      usn integer not null,
      ls integer not null,
      conf text not null,
      models text not null,
      decks text not null,
      dconf text not null,
      tags text not null
    );

    CREATE TABLE IF NOT EXISTS notes (
      id integer primary key,
      guid text not null,
      mid integer not null,
      mod integer not null,
      usn integer not null,
      tags text not null,
      flds text not null,
      sfld integer not null,
      csum integer not null,
      flags integer not null,
      data text not null
    );

    CREATE TABLE IF NOT EXISTS cards (
      id integer primary key,
      nid integer not null,
      did integer not null,
      ord integer not null,
      mod integer not null,
      usn integer not null,
      type integer not null,
      queue integer not null,
      due integer not null,
      ivl integer not null,
      factor integer not null,
      reps integer not null,
      lapses integer not null,
      left integer not null,
      odue integer not null,
      odid integer not null,
      flags integer not null,
      data text not null
    );

    CREATE TABLE IF NOT EXISTS revlog (
      id integer primary key,
      cid integer not null,
      usn integer not null,
      ease integer not null,
      ivl integer not null,
      lastIvl integer not null,
      factor integer not null,
      time integer not null,
      type integer not null
    );

    CREATE TABLE IF NOT EXISTS graves (
      usn integer not null,
      oid integer not null,
      type integer not null
    );

    CREATE INDEX IF NOT EXISTS ix_notes_mid ON notes (mid);
    CREATE INDEX IF NOT EXISTS ix_notes_csum ON notes (csum);
    CREATE INDEX IF NOT EXISTS ix_cards_nid ON cards (nid);
    CREATE INDEX IF NOT EXISTS ix_cards_sched ON cards (did, queue, due);
    CREATE INDEX IF NOT EXISTS ix_cards_usn ON cards (usn);
    CREATE INDEX IF NOT EXISTS ix_notes_usn ON notes (usn);
    CREATE INDEX IF NOT EXISTS ix_revlog_cid ON revlog (cid);
    CREATE INDEX IF NOT EXISTS ix_revlog_usn ON revlog (usn);
    """

    static func migrateSortFieldAffinity(in db: SQLiteDatabase) throws {
        var affinity: String?
        try db.query("PRAGMA table_info(notes)") { statement in
            if SQLiteDatabase.text(statement, 1) == "sfld" {
                affinity = SQLiteDatabase.text(statement, 2).uppercased()
            }
        }
        guard let affinity, affinity != "INTEGER" else { return }

        var schemaObjects: [String] = []
        try db.query("""
            SELECT sql FROM sqlite_master
            WHERE tbl_name = 'notes' AND type IN ('index', 'trigger') AND sql IS NOT NULL
            ORDER BY type, name
        """) { statement in
            schemaObjects.append(SQLiteDatabase.text(statement, 0))
        }

        try db.exec("BEGIN IMMEDIATE;")
        do {
            try db.exec("""
                ALTER TABLE notes RENAME TO notes_sortfield_migration;
                CREATE TABLE notes (
                  id integer primary key,
                  guid text not null,
                  mid integer not null,
                  mod integer not null,
                  usn integer not null,
                  tags text not null,
                  flds text not null,
                  sfld integer not null,
                  csum integer not null,
                  flags integer not null,
                  data text not null
                );
                INSERT INTO notes SELECT * FROM notes_sortfield_migration;
                DROP TABLE notes_sortfield_migration;
                """)
            for sql in schemaObjects { try db.exec(sql) }
            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    static func collectionConfig(from db: SQLiteDatabase) throws -> [String: Any] {
        var values: [String: Any] = [:]
        if let raw = try db.scalarText("SELECT conf FROM col"),
           let decoded = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
            values = decoded
        }
        guard try hasConfigTable(in: db) else { return values }
        try db.query("SELECT key, val FROM config") { statement in
            let key = SQLiteDatabase.text(statement, 0)
            let data = SQLiteDatabase.blob(statement, 1)
            guard !key.isEmpty,
                  let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return }
            values[key] = decoded
        }
        return values
    }

    static func saveCollectionConfig(_ values: [String: Any], to db: SQLiteDatabase) throws {
        guard try hasConfigTable(in: db) else { return }

        var existing: [String: Data] = [:]
        try db.query("SELECT key, val FROM config") { statement in
            let key = SQLiteDatabase.text(statement, 0)
            if !key.isEmpty { existing[key] = SQLiteDatabase.blob(statement, 1) }
        }
        let columns = try configTableColumns(in: db)
        let hasSyncMetadata = columns.contains("usn") && columns.contains("mtime_secs")
        let now = Int64(Date().timeIntervalSince1970)

        for key in values.keys.sorted() {
            guard let value = values[key] else { continue }
            let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
            if let stored = existing[key],
               let decoded = try? JSONSerialization.jsonObject(with: stored, options: [.fragmentsAllowed]),
               let normalized = try? JSONSerialization.data(withJSONObject: decoded, options: [.fragmentsAllowed, .sortedKeys]),
               normalized == data {
                continue
            }
            if hasSyncMetadata {
                try db.run("INSERT OR REPLACE INTO config (key, usn, mtime_secs, val) VALUES (?, -1, ?, ?)") { statement in
                    try SQLiteDatabase.bindText(statement, 1, key)
                    SQLiteDatabase.bindInt64(statement, 2, now)
                    try SQLiteDatabase.bindBlob(statement, 3, data)
                }
            } else {
                try db.run("INSERT OR REPLACE INTO config (key, val) VALUES (?, ?)") { statement in
                    try SQLiteDatabase.bindText(statement, 1, key)
                    try SQLiteDatabase.bindBlob(statement, 2, data)
                }
            }
        }

        for key in existing.keys where values[key] == nil {
            try db.run("DELETE FROM config WHERE key = ?") { statement in
                try SQLiteDatabase.bindText(statement, 1, key)
            }
        }
    }

    private static func hasConfigTable(in db: SQLiteDatabase) throws -> Bool {
        try db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='config'") > 0
    }

    private static func configTableColumns(in db: SQLiteDatabase) throws -> Set<String> {
        var columns: Set<String> = []
        try db.query("PRAGMA table_info(config)") { statement in
            columns.insert(SQLiteDatabase.text(statement, 1))
        }
        return columns
    }

    static func emptyColJSON() -> (conf: String, models: String, decks: String, dconf: String, tags: String) {
        let now = Int64(Date().timeIntervalSince1970)
        let defaultDeck: [String: Any] = [
            "id": 1,
            "name": "Default",
            "mod": now,
            "usn": -1,
            "collapsed": false,
            "browserCollapsed": false,
            "desc": "",
            "dyn": 0,
            "conf": 1,
            "extendNew": 0,
            "extendRev": 0,
            "newToday": [0, 0],
            "revToday": [0, 0],
            "lrnToday": [0, 0],
            "timeToday": [0, 0]
        ]
        let basic = makeBasicNotetype(id: now, now: now)
        let conf: [String: Any] = [
            "activeDecks": [1],
            "curDeck": 1,
            "newSpread": 0,
            "collapseTime": 1200,
            "timeLim": 0,
            "estTimes": true,
            "dueCounts": true,
            "schedVer": 2,
            "sched2021": true,
            "nextPos": 1,
            "creationOffset": -TimeZone.current.secondsFromGMT(for: Date()) / 60,
            "rollover": 4
        ]
        let dconfObj = [
            "1": encodeJSONObject(defaultDconf(id: 1, now: now))
        ] as [String: Any]

        return (
            conf: encodeJSON(conf),
            models: encodeJSON([String(basic["id"] as! Int64): basic]),
            decks: encodeJSON(["1": defaultDeck]),
            dconf: encodeJSON(dconfObj),
            tags: "{}"
        )
    }

    static func makeBasicNotetype(id: Int64, now: Int64) -> [String: Any] {
        [
            "id": id,
            "name": "Basic",
            "type": 0,
            "mod": now,
            "usn": -1,
            "sortf": 0,
            "did": NSNull(),
            "tmpls": [[
                "name": "Card 1",
                "ord": 0,
                "qfmt": "{{Front}}",
                "afmt": "{{FrontSide}}<hr id=answer>{{Back}}",
                "bqfmt": "",
                "bafmt": "",
                "did": NSNull(),
                "bfont": "",
                "bsize": 0
            ]],
            "flds": [
                ["name": "Front", "ord": 0, "sticky": false, "rtl": false, "font": "Arial", "size": 20, "description": "", "plainText": false, "collapsed": false, "excludeFromSearch": false],
                ["name": "Back", "ord": 1, "sticky": false, "rtl": false, "font": "Arial", "size": 20, "description": "", "plainText": false, "collapsed": false, "excludeFromSearch": false]
            ],
            "css": AnkiNotetype.defaultCSS,
            "latexPre": AnkiNotetype.defaultLatexPre,
            "latexPost": AnkiNotetype.defaultLatexPost,
            "latexsvg": false,
            "tags": [],
            "vers": []
        ]
    }

    static func defaultDconf(id: Int64, now: Int64) -> [String: Any] {
        [
            "id": id,
            "name": "Default",
            "mod": now,
            "usn": -1,
            "maxTaken": 60,
            "autoplay": true,
            "timer": 0,
            "replayq": true,
            "new": [
                "delays": [1.0, 10.0],
                "ints": [1, 4],
                "initialFactor": 2500,
                "order": 1,
                "perDay": 20,
                "bury": false
            ],
            "rev": [
                "perDay": 200,
                "ease4": 1.3,
                "fuzz": 0.05,
                "minSpace": 1,
                "ivlFct": 1.0,
                "maxIvl": 36500,
                "bury": false,
                "hardFactor": 1.2
            ],
            "lapse": [
                "delays": [10.0],
                "mult": 0.0,
                "minInt": 1,
                "leechFails": 8,
                "leechAction": 0
            ],
            "dyn": false,
            "newMix": 0,
            "newPerDayMinimum": 0,
            "interdayLearningMix": 0,
            "reviewOrder": 0,
            "newSortOrder": 0,
            "newGatherPriority": 0,
            "buryInterdayLearning": false,
            "desiredRetention": 0.9,
            "historicalRetention": 0.9
        ]
    }

    static func encodeJSON(_ obj: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [])
        return String(data: data, encoding: .utf8)!
    }

    static func encodeJSONObject(_ obj: [String: Any]) -> [String: Any] { obj }
}
