"""Execute production discovery SQL against synthetic SQLite, never user storage."""
import json
import sqlite3
import sys

request = json.load(sys.stdin)
root = request["root"]
db = sqlite3.connect(":memory:")
db.row_factory = sqlite3.Row
db.executescript("""
create table session(id text primary key, directory text, path text, title text,
                     time_created integer, time_updated integer);
create table part(id text primary key, session_id text, time_created integer, data text);
""")
sessions = [
    ("parent", root + "/home", "Users/synthetic", "合成 parent", 1791388800000, 1791476000000),
    ("metadata", root + "/repo", root + "/repo", "合成 metadata", 1791388800000, 1791475199999),
    ("outside", root + "/other-repo", "", "範圍外", 1791475200000, 1791476000000),
]
if request["mode"] == "relative":
    sessions = [(str(i), p, p, "relative", 1791388800000, 1791475199999)
                for i, p in enumerate(["Users/synthetic", "C:repo", "\\repo", "/repo"])]
elif request["mode"] == "empty":
    sessions = []
elif request["mode"] == "diagnostics-metadata":
    sessions = [(key, directory, path, "synthetic", 1791388800000, 1791475199999)
                for key, directory, path in [
                    ("meta", root + "/repo/../repo", root + "/repo"),
                    ("aggregate", root + "/home", root + "/home"),
                    ("missing", root + "/missing", root + "/missing"),
                    ("relative", "relative/repo", "C:repo"),
                    ("invalid", root + "/\0bad", None),
                    ("empty", None, " "),
                ]]
elif request["mode"] == "unsafe-home-expansion":
    sessions = [("home", request["home"], None, "synthetic", 1791388800000, 1791475199999),
                ("meta", root + "/repo", None, "synthetic", 1791388800000, 1791475199999)]
db.executemany("insert into session values(?,?,?,?,?,?)", sessions)

def part(key, path, time=1791388800000, session="parent", tool="bash"):
    data = json.dumps({"type": "tool", "tool": tool, "state": {"input": {
        "workdir": path, "command": "ignored-command-with-unrelated-path"}},
        "output": "ignored-output"})
    return (key, session, time, data)

parts = [part("01", root + "/repo"), part("02", root + "/repo", 1791475199999),
         part("03", root + "/other-repo", 1791475200000),
         part("04", root + "/other-repo", 1791388799999),
         part("05", root + "/other-repo", session="outside"),
         part("06", root + "/other-repo", tool="unknown"),
         part("07", "relative/repo"), part("08", "C:repo"), part("09", "\\repo"),
         part("10", root + "/repo/deleted-worktree"),
         part("11", root + "/" + "x" * 4096), part("12", 123),
         ("13", "parent", 1791388800000, "{bad-json"),
         part("14", root + "/repo", session="metadata")]
if request["mode"] == "cap":
    parts = [part(f"{i:05}", root + "/repo", 1791388800000 + i) for i in range(2049)]
    parts[-1] = part("02048", root + "/other-repo", 1791388802048)
elif request["mode"] in ("diagnostics-metadata", "unsafe-home-expansion"):
    parts = []
elif request["mode"] in ("supplement-singleton", "supplement-array"):
    parts = [part("01", root + "/repo")]
elif request["mode"] == "supplement-empty":
    parts = []
elif request["mode"] == "diagnostics-workdir":
    parts = [part("01", root + "/repo"), part("02", root + "/repo/../repo"),
             part("03", root + "/repo", session="metadata"),
             part("04", root + "/missing"), part("05", root + "/missing"),
             part("06", root + "/home"), part("07", "relative/repo"),
             part("08", "C:repo"), part("09", root + "/another-missing"), part("10", " ")]
db.executemany("insert into part values(?,?,?,?)", parts)
rows = [dict(row) for row in db.execute(request["sql"])]
if request["mode"] == "supplement-singleton" and "join session" in request["sql"]:
    print(json.dumps(rows[0], ensure_ascii=False))
else:
    print(json.dumps(rows, ensure_ascii=False))
