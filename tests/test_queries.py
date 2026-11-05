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

if __name__ == "__main__":
    unittest.main(verbosity=2)
