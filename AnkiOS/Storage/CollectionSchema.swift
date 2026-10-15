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
      sfld text not null,
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
    CREATE INDEX IF NOT EXISTS ix_cards_nid ON cards (nid);
    CREATE INDEX IF NOT EXISTS ix_cards_sched ON cards (did, queue, due);
    CREATE INDEX IF NOT EXISTS ix_cards_usn ON cards (usn);
    CREATE INDEX IF NOT EXISTS ix_notes_usn ON notes (usn);
    CREATE INDEX IF NOT EXISTS ix_revlog_cid ON revlog (cid);
    CREATE INDEX IF NOT EXISTS ix_revlog_usn ON revlog (usn);
    """

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
            "dayLearnFirst": false,
            "schedVer": 2,
            "creationOffset": -180,
            "rollday": 4,
            "scheduler": "sm2"
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
            "latexPre": "",
            "latexPost": "",
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
            "desiredRetention": 0.9
        ]
    }

    static func encodeJSON(_ obj: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [])
        return String(data: data, encoding: .utf8)!
    }

    static func encodeJSONObject(_ obj: [String: Any]) -> [String: Any] { obj }
}
