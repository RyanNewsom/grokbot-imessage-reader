#!/usr/bin/env python3
"""Synthetic chat.db + attributedBody decoder tests (mirrors Sources/main.swift)."""
import json
import os
import sqlite3
import struct
import tempfile
import time
import unittest
from datetime import datetime, timezone
from pathlib import Path

APPLE_EPOCH = 978307200  # 2001-01-01 UTC as unix

def apple_ns_now(offset_hours=0):
    # nanoseconds since 2001-01-01
    unix = time.time() + offset_hours * 3600
    return int((unix - APPLE_EPOCH) * 1_000_000_000)

def make_attributed_body(text: str, long_prefix=False) -> bytes:
    """Build a minimal typedstream-ish blob with 0x01 0x2b … 0x86 0x84 around text."""
    payload = text.encode("utf-8")
    if long_prefix and len(payload) >= 128:
        # 0x81 NN length (1-byte follow) — NN = length
        inner = bytes([0x81, len(payload) & 0xFF, 0x00]) + payload
    elif len(payload) < 128:
        inner = bytes([len(payload), 0x00]) + payload
    else:
        inner = bytes([0x81, len(payload) & 0xFF, 0x00]) + payload
    # header noise + markers
    return b"\x04\x0bstreamtyped" + b"NSString\x00" + bytes([0x01, 0x2B]) + inner + bytes([0x86, 0x84])

def decode_segment(seg: bytes):
    cands = []
    def after_len(drop, length):
        if drop >= len(seg):
            return
        body = seg[drop:]
        if body[:1] == b"\x00":
            body = body[1:]
        if length > 0 and len(body) >= length:
            cands.append(body[:length])
        cands.append(body)
    if seg and seg[0] < 0x80:
        after_len(1, seg[0])
        if seg[0] == len(seg) - 1:
            cands.append(seg[1:])
    if len(seg) >= 2 and seg[0] == 0x81:
        after_len(2, seg[1])
    if len(seg) >= 3 and seg[0] == 0x82:
        after_len(3, (seg[1] << 8) | seg[2])
    if not cands:
        cands = [seg]
    best = None
    for c in cands:
        try:
            raw = c.decode("utf-8")
        except UnicodeDecodeError:
            continue
        # Mirror Swift CharacterSet.controlCharacters trim
        t = raw.strip("".join(chr(i) for i in range(32)) + "\x7f")
        if "\x00" in t or not t or "NSDictionary" in t or "NSNumber" in t:
            continue
        if best is None or len(t) > len(best):
            best = t
    return best

def decode_attributed_body(data: bytes):
    if not data or len(data) < 8:
        return None
    best = ""
    i = 0
    while i + 1 < len(data):
        if data[i] == 0x01 and data[i + 1] == 0x2B:
            start = i + 2
            end = start
            while end + 1 < len(data) and not (data[end] == 0x86 and data[end + 1] == 0x84):
                end += 1
            if end + 1 < len(data) and end > start:
                s = decode_segment(data[start:end])
                if s and len(s) > len(best):
                    best = s
            i = end + 2
            continue
        i += 1
    return best or None

def message_text(text, attributed):
    if text:
        return text
    if attributed:
        return decode_attributed_body(attributed) or ""
    return ""

SCHEMA = """
CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT);
CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT, service_name TEXT);
CREATE TABLE message (
  ROWID INTEGER PRIMARY KEY,
  guid TEXT,
  text TEXT,
  attributedBody BLOB,
  handle_id INTEGER,
  date INTEGER,
  is_from_me INTEGER,
  service TEXT
);
CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, filename TEXT);
"""

MSG_SELECT = """
SELECT m.ROWID, m.date, m.text, m.attributedBody, m.is_from_me,
  COALESCE(h.id,''), COALESCE(NULLIF(c.display_name,''), c.chat_identifier, ''),
  COALESCE(c.chat_identifier,''),
  (SELECT COUNT(*) FROM message_attachment_join maj WHERE maj.message_id=m.ROWID)
FROM message m
JOIN chat_message_join cmj ON cmj.message_id=m.ROWID
JOIN chat c ON c.ROWID=cmj.chat_id
LEFT JOIN handle h ON h.ROWID=m.handle_id
"""

class TestHelper(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        self.tmp.close()
        self.db = sqlite3.connect(self.tmp.name)
        self.db.executescript(SCHEMA)
        # handles
        self.db.execute("INSERT INTO handle VALUES (1, '+15551110001', 'iMessage')")
        self.db.execute("INSERT INTO handle VALUES (2, 'friend@example.com', 'iMessage')")
        # chats
        self.db.execute("INSERT INTO chat VALUES (1, '+15551110001', '', 'iMessage')")
        self.db.execute("INSERT INTO chat VALUES (2, 'chat123group', 'Family Group', 'iMessage')")
        self.db.execute("INSERT INTO chat_handle_join VALUES (1, 1)")
        self.db.execute("INSERT INTO chat_handle_join VALUES (2, 1)")
        self.db.execute("INSERT INTO chat_handle_join VALUES (2, 2)")
        # messages: plain text, attributed-only, old (outside window)
        d_recent = apple_ns_now(-1)
        d_old = apple_ns_now(-48)
        body = make_attributed_body("secret dinner plans")
        self.db.execute(
            "INSERT INTO message VALUES (1,'g1','Hello from phone',NULL,1,?,?, 'iMessage')",
            (d_recent, 0),
        )
        self.db.execute(
            "INSERT INTO message VALUES (2,'g2',NULL,?,1,?,?, 'iMessage')",
            (body, d_recent + 1000, 1),
        )
        self.db.execute(
            "INSERT INTO message VALUES (3,'g3','old news',NULL,1,?,?, 'iMessage')",
            (d_old, 0),
        )
        self.db.execute(
            "INSERT INTO message VALUES (4,'g4','group hi',NULL,2,?,?, 'iMessage')",
            (d_recent + 2000, 0),
        )
        self.db.execute("INSERT INTO chat_message_join VALUES (1, 1)")
        self.db.execute("INSERT INTO chat_message_join VALUES (1, 2)")
        self.db.execute("INSERT INTO chat_message_join VALUES (1, 3)")
        self.db.execute("INSERT INTO chat_message_join VALUES (2, 4)")
        # attachment on msg 1
        self.db.execute("INSERT INTO attachment VALUES (1, '/tmp/x.jpg')")
        self.db.execute("INSERT INTO message_attachment_join VALUES (1, 1)")
        self.db.commit()

    def tearDown(self):
        self.db.close()
        os.unlink(self.tmp.name)

    def test_decode_short(self):
        blob = make_attributed_body("hello world")
        self.assertEqual(decode_attributed_body(blob), "hello world")

    def test_decode_long(self):
        text = "x" * 140
        blob = make_attributed_body(text, long_prefix=True)
        self.assertEqual(decode_attributed_body(blob), text)

    def test_recent_threads(self):
        cut = apple_ns_now(-6)
        rows = self.db.execute(
            """
            SELECT c.ROWID, COALESCE(NULLIF(c.display_name,''), c.chat_identifier), c.chat_identifier
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id=m.ROWID
            JOIN chat c ON c.ROWID=cmj.chat_id
            WHERE m.date>=? GROUP BY c.ROWID ORDER BY MAX(m.date) DESC
            """,
            (cut,),
        ).fetchall()
        ids = {r[0] for r in rows}
        self.assertEqual(ids, {1, 2})
        # old-only would exclude chat if only old msgs — chat 1 still has recent

    def test_message_text_and_attachments(self):
        cut = apple_ns_now(-6)
        rows = self.db.execute(MSG_SELECT + " WHERE m.date>=? ORDER BY m.date DESC", (cut,)).fetchall()
        texts = []
        for r in rows:
            texts.append(message_text(r[2], r[3]))
            if r[0] == 1:
                self.assertEqual(r[8], 1)  # attachment_count
        self.assertIn("Hello from phone", texts)
        self.assertIn("secret dinner plans", texts)
        self.assertIn("group hi", texts)
        self.assertNotIn("old news", texts)

    def test_search(self):
        cut = apple_ns_now(-24)
        rows = self.db.execute(MSG_SELECT + " WHERE m.date>=?", (cut,)).fetchall()
        hits = [message_text(r[2], r[3]) for r in rows if "dinner" in message_text(r[2], r[3]).lower()]
        self.assertEqual(hits, ["secret dinner plans"])

    def test_thread_by_handle(self):
        cut = apple_ns_now(-24)
        handle = "+15551110001"
        sql = MSG_SELECT + """
         WHERE m.date>=? AND (h.id=? OR c.chat_identifier=? OR c.display_name=? OR EXISTS (
           SELECT 1 FROM chat_handle_join chj JOIN handle hh ON hh.ROWID=chj.handle_id
           WHERE chj.chat_id=c.ROWID AND hh.id=?)) ORDER BY m.date DESC
        """
        rows = self.db.execute(sql, (cut, handle, handle, handle, handle)).fetchall()
        # 1:1 chat msgs + group (handle is participant)
        ids = {r[0] for r in rows}
        self.assertTrue({1, 2, 4}.issubset(ids))
        self.assertNotIn(3, ids)  # old

    def test_thread_by_group_name(self):
        cut = apple_ns_now(-24)
        name = "Family Group"
        sql = MSG_SELECT + " WHERE m.date>=? AND (c.display_name=? OR c.chat_identifier=?) "
        rows = self.db.execute(sql, (cut, name, name)).fetchall()
        self.assertEqual([r[0] for r in rows], [4])

    def test_readonly_uri(self):
        uri = f"file:{self.tmp.name}?mode=ro"
        c = sqlite3.connect(uri, uri=True)
        c.execute("PRAGMA query_only=ON")
        n = c.execute("SELECT COUNT(*) FROM message").fetchone()[0]
        self.assertEqual(n, 4)
        with self.assertRaises(sqlite3.Error):
            c.execute("INSERT INTO message (ROWID) VALUES (99)")
        c.close()


# ---------------------------------------------------------------------------
# Integration tests: compile Sources/main.swift and run it against fake data.
# All numbers are +1555 fakes and all names are made up.
# ---------------------------------------------------------------------------
import shutil
import subprocess

REPO = Path(__file__).resolve().parent.parent
AB_SCHEMA = """
CREATE TABLE ZABCDRECORD (Z_PK INTEGER PRIMARY KEY, ZFIRSTNAME TEXT, ZLASTNAME TEXT, ZORGANIZATION TEXT, ZNICKNAME TEXT);
CREATE TABLE ZABCDPHONENUMBER (Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER, ZFULLNUMBER TEXT);
CREATE TABLE ZABCDEMAILADDRESS (Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER, ZADDRESS TEXT);
"""

def make_addressbook(path, records):
    """records: list of (first, last, org, nick, [phones], [emails])"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    c = sqlite3.connect(path)
    c.executescript(AB_SCHEMA)
    for pk, (f, l, o, n, phones, emails) in enumerate(records, start=1):
        c.execute("INSERT INTO ZABCDRECORD VALUES (?,?,?,?,?)", (pk, f, l, o, n))
        for ph in phones:
            c.execute("INSERT INTO ZABCDPHONENUMBER (ZOWNER, ZFULLNUMBER) VALUES (?,?)", (pk, ph))
        for em in emails:
            c.execute("INSERT INTO ZABCDEMAILADDRESS (ZOWNER, ZADDRESS) VALUES (?,?)", (pk, em))
    c.commit()
    c.close()

@unittest.skipUnless(shutil.which("swiftc"), "swiftc not available")
class TestSwiftBinary(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = tempfile.mkdtemp(prefix="imsg-test-")
        cls.bin = os.path.join(cls.work, "imsg-helper")
        subprocess.run(["swiftc", "-O", "-o", cls.bin, str(REPO / "Sources/main.swift")], check=True)
        # Fake chat.db
        cls.chat = os.path.join(cls.work, "chat.db")
        db = sqlite3.connect(cls.chat)
        db.executescript(SCHEMA)
        handles = ["+15551110001", "friend@example.com", "+15551110002", "+15551110003", "+15551110004"]
        for i, h in enumerate(handles, start=1):
            db.execute("INSERT INTO handle VALUES (?,?, 'iMessage')", (i, h))
        chats = [(1, "+15551110001", ""), (2, "chat123group", "Family Group"), (3, "+15551110002", ""),
                 (4, "+15551110003", ""), (5, "+15551110004", "")]
        for cid, ident, name in chats:
            db.execute("INSERT INTO chat VALUES (?,?,?, 'iMessage')", (cid, ident, name))
        for cid, hid in [(1, 1), (2, 1), (2, 2), (3, 3), (4, 4), (5, 5)]:
            db.execute("INSERT INTO chat_handle_join VALUES (?,?)", (cid, hid))
        now = apple_ns_now(-1)
        msgs = [  # (rowid, chat, handle, text, from_me)
            (1, 1, 1, "alpha one-on-one", 0),
            (2, 1, 1, "alpha reply", 1),
            (3, 2, 1, "group from alpha", 0),
            (4, 2, 2, "group from friend zebra", 0),
            (5, 3, 3, "unknown sender zebra", 0),
            (6, 4, 4, "sam one", 0),
            (7, 5, 5, "sam two", 0),
        ]
        for rid, cid, hid, text, me in msgs:
            db.execute("INSERT INTO message VALUES (?,?,?,NULL,?,?,?, 'iMessage')",
                       (rid, f"g{rid}", text, hid, now + rid * 1000, me))
            db.execute("INSERT INTO chat_message_join VALUES (?,?)", (cid, rid))
        db.commit()
        db.close()
        # Fake Contacts: main DB + one synced source with a duplicate record
        cls.ab = os.path.join(cls.work, "AddressBook")
        make_addressbook(os.path.join(cls.ab, "AddressBook-v22.abcddb"), [
            ("Alex", "Fake", "", "", ["(555) 111-0001"], []),
            ("Pat", "Example", "", "", [], ["FRIEND@Example.com"]),
            ("Sam", "Test", "", "", ["555.111.0003"], []),
            ("Sam", "Test", "", "", ["+1 555 111 0004"], []),
        ])
        make_addressbook(os.path.join(cls.ab, "Sources", "FAKE-SOURCE", "AddressBook-v22.abcddb"), [
            ("Alex", "Fake", "", "Al", ["+15551110001"], []),
        ])

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.work, ignore_errors=True)

    def run_bin(self, *args, blocklist="", contacts=None):
        bl = os.path.join(self.work, "blocked.txt")
        with open(bl, "w") as f:
            f.write("# comment line\n" + blocklist)
        cmd = [self.bin, *args, "--db", self.chat, "--contacts-root", contacts or self.ab, "--blocklist", bl]
        p = subprocess.run(cmd, capture_output=True, text=True)
        return json.loads(p.stdout), p.stdout

    def all_msgs(self, out):
        if "threads" in out:
            return [m for t in out["threads"] for m in t["messages"]]
        return out.get("messages", [])

    def test_names_resolved(self):
        out, _ = self.run_bin("recent", "--hours", "6")
        self.assertTrue(out["ok"])
        self.assertEqual(out["blocked_count"], 0)
        self.assertNotIn("warning", out)
        by_text = {m["text"]: m for m in self.all_msgs(out)}
        self.assertEqual(by_text["alpha one-on-one"]["sender_name"], "Alex Fake")
        self.assertEqual(by_text["alpha one-on-one"]["chat_contact_name"], "Alex Fake")
        self.assertIsNone(by_text["alpha reply"]["sender_name"])  # from me
        self.assertEqual(by_text["group from friend zebra"]["sender_name"], "Pat Example")  # email, case-insensitive
        self.assertIsNone(by_text["group from friend zebra"]["chat_contact_name"])  # group chat
        self.assertIsNone(by_text["unknown sender zebra"]["sender_name"])
        t = {t["chat_identifier"]: t for t in out["threads"]}
        self.assertEqual(t["+15551110001"]["chat_contact_name"], "Alex Fake")
        self.assertIsNone(t["+15551110002"]["chat_contact_name"])

    def test_thread_by_contact_name(self):
        for q in ["Alex Fake", "alex fake", "Al", "Alex"]:
            out, _ = self.run_bin("thread", "--handle", q, "--days", "2")
            self.assertTrue(out["ok"], q)
            self.assertEqual(out["resolved_handles"], ["+15551110001"])
            texts = {m["text"] for m in out["messages"]}
            self.assertTrue({"alpha one-on-one", "alpha reply", "group from alpha"} <= texts, q)

    def test_thread_by_formatted_phone(self):
        out, _ = self.run_bin("thread", "--handle", "(555) 111-0001", "--days", "2")
        self.assertTrue(out["ok"])
        self.assertIn("alpha one-on-one", {m["text"] for m in out["messages"]})

    def test_thread_ambiguous_name(self):
        out, raw = self.run_bin("thread", "--handle", "Sam Test", "--days", "2")
        self.assertFalse(out["ok"])
        self.assertTrue(out["ambiguous"])
        handles = sorted(h for c in out["candidates"] for h in c["handles"])
        self.assertEqual(handles, ["+15551110003", "+15551110004"])
        self.assertNotIn("sam one", raw)

    def test_contacts_unreadable_warns(self):
        out, _ = self.run_bin("recent", "--hours", "6", contacts=os.path.join(self.work, "missing"))
        self.assertTrue(out["ok"])
        self.assertIn("contacts unavailable", out["warning"])
        self.assertTrue(all(m["sender_name"] is None for m in self.all_msgs(out)))

    def test_block_phone_any_format(self):
        out, raw = self.run_bin("recent", "--hours", "6", blocklist="(555) 111-0002\n")
        self.assertEqual(out["blocked_count"], 1)
        self.assertNotIn("+15551110002", raw)
        self.assertNotIn("unknown sender", raw)
        out, raw = self.run_bin("search", "--query", "zebra", "--days", "2", blocklist="555-111-0002\n")
        self.assertEqual([m["text"] for m in out["messages"]], ["group from friend zebra"])
        self.assertNotIn("unknown sender", raw)
        out, raw = self.run_bin("thread", "--handle", "+15551110002", "--days", "2", blocklist="5551110002\n")
        self.assertFalse(out["ok"])
        self.assertTrue(out["blocked"])
        self.assertNotIn("messages", out)
        self.assertNotIn("unknown sender", raw)

    def test_block_group_name_and_identifier(self):
        for entry in ["family group", "chat123group"]:
            out, raw = self.run_bin("recent", "--hours", "6", blocklist=entry + "\n")
            self.assertNotIn("group from", raw, entry)
            self.assertEqual(out["blocked_count"], 2, entry)
            for q in ["Family Group", "chat123group"]:
                out, raw = self.run_bin("thread", "--handle", q, "--days", "2", blocklist=entry + "\n")
                self.assertFalse(out["ok"], (entry, q))
                self.assertNotIn("group from", raw)

    def test_block_contact_name_and_email(self):
        for entry in ["Pat Example", "friend@EXAMPLE.com"]:
            out, raw = self.run_bin("recent", "--hours", "6", blocklist=entry + "\n")
            self.assertNotIn("friend", raw.replace("Family Group", ""), entry)
            self.assertIn("group from alpha", raw)  # rest of the group survives
            self.assertEqual(out["blocked_count"], 1)
        out, raw = self.run_bin("thread", "--handle", "Alex Fake", "--days", "2", blocklist="Alex Fake\n")
        self.assertFalse(out["ok"])
        self.assertTrue(out["blocked"])
        self.assertNotIn("alpha", raw)
        out, raw = self.run_bin("thread", "--handle", "+15551110001", "--days", "2", blocklist="Alex Fake\n")
        self.assertFalse(out["ok"])
        self.assertNotIn("alpha", raw)

    def test_blocklist_command(self):
        out, raw = self.run_bin("blocklist", blocklist="# another comment\n\n+15551110002\nFamily Group\n")
        self.assertTrue(out["ok"])
        self.assertEqual(out["entries"], 2)
        self.assertNotIn("Family Group", raw)  # entries themselves are never echoed

    def test_overrides_need_test_db(self):
        p = subprocess.run([self.bin, "recent", "--blocklist", "/dev/null"], capture_output=True, text=True)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("only allowed with --db", p.stdout)

if __name__ == "__main__":
    unittest.main(verbosity=2)
