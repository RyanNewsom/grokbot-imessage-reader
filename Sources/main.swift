// imsg-helper — read-only iMessage reader (macOS 13+). System SQLite only; no network/send.
// Build: swiftc -O -o imsg-helper main.swift && codesign -s - --force imsg-helper
import Foundation
import SQLite3

private let defaultLimit = 200, recentPerThread = 5, maxThreads = 40
private let supportName = "imessage-helper"
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func emit(_ obj: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
          let s = String(data: d, encoding: .utf8) else { fputs("{\"ok\":false,\"error\":\"json\"}\n", stderr); exit(2) }
    print(s)
}
private func fail(_ m: String) -> Never { emit(["ok": false, "error": m]); exit(1) }
private func home() -> String { NSHomeDirectory() }
private func supportDir() -> URL {
    URL(fileURLWithPath: home()).appendingPathComponent("Library/Application Support/\(supportName)")
}
private func chatDB() -> String { home() + "/Library/Messages/chat.db" }
private func colText(_ s: OpaquePointer?, _ i: Int32) -> String {
    guard let c = sqlite3_column_text(s, i) else { return "" }
    return String(cString: c)
}

// typedstream attributedBody → plain text (0x01 0x2b … 0x86 0x84, length prefixes)
private func decodeSegment(_ seg: [UInt8]) -> String? {
    var cands: [[UInt8]] = []
    func afterLen(_ drop: Int, _ len: Int) {
        guard drop < seg.count else { return }
        var body = Array(seg.dropFirst(drop))
        if body.first == 0 { body = Array(body.dropFirst()) }
        if len > 0, body.count >= len { cands.append(Array(body.prefix(len))) }
        cands.append(body)
    }
    if !seg.isEmpty, seg[0] < 0x80 {
        afterLen(1, Int(seg[0]))
        if Int(seg[0]) == seg.count - 1 { cands.append(Array(seg.dropFirst())) }
    }
    if seg.count >= 2, seg[0] == 0x81 { afterLen(2, Int(seg[1])) }
    if seg.count >= 3, seg[0] == 0x82 {
        afterLen(3, (Int(seg[1]) << 8) | Int(seg[2]))
    }
    if cands.isEmpty { cands = [seg] }
    var best: String?
    for c in cands {
        guard let str = String(bytes: c, encoding: .utf8) else { continue }
        let t = str.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        if t.isEmpty || t.contains("\u{0}") || t.contains("NSDictionary") || t.contains("NSNumber") { continue }
        if best == nil || t.count > best!.count { best = t }
    }
    return best
}
private func decodeAttributedBody(_ data: Data) -> String? {
    let b = [UInt8](data)
    guard b.count > 8 else { return nil }
    var best = ""
    var i = 0
    while i + 1 < b.count {
        if b[i] == 0x01, b[i + 1] == 0x2B {
            let start = i + 2
            var end = start
            while end + 1 < b.count, !(b[end] == 0x86 && b[end + 1] == 0x84) { end += 1 }
            if end + 1 < b.count, end > start, let s = decodeSegment(Array(b[start..<end])), s.count > best.count {
                best = s
            }
            i = end + 2; continue
        }
        i += 1
    }
    if !best.isEmpty { return best }
    if let r = data.range(of: Data("NSString".utf8)) ?? data.range(of: Data("NSMutableString".utf8)),
       let plus = data[r.upperBound...].firstIndex(of: 0x2B),
       let s = decodeSegment([UInt8](data[data.index(after: plus)...])), !s.isEmpty { return s }
    return nil
}

private func appleISO(_ raw: Int64) -> String {
    let sec: TimeInterval = abs(raw) > 1_000_000_000_000 ? TimeInterval(raw) / 1e9 : TimeInterval(raw)
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime, .withTimeZone]
    fmt.timeZone = .current
    return fmt.string(from: Date(timeIntervalSinceReferenceDate: sec))
}
private func cutoffHours(_ h: Int) -> Int64 {
    Int64((Date().timeIntervalSinceReferenceDate - TimeInterval(h * 3600)) * 1e9)
}

private final class DB {
    let db: OpaquePointer?
    init(_ path: String) {
        var tmp: OpaquePointer?
        let uri = "file:\(path)?mode=ro"
        if sqlite3_open_v2(uri, &tmp, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) != SQLITE_OK {
            let e = tmp.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            tmp.map { _ = sqlite3_close($0) }
            fail("cannot open chat.db (grant Full Disk Access to imsg-helper.app?): \(e)")
        }
        db = tmp
        sqlite3_exec(db, "PRAGMA query_only=ON;", nil, nil, nil)
        sqlite3_busy_timeout(db, 3000)
    }
    deinit { if let db { sqlite3_close(db) } }
    func text(_ stmt: OpaquePointer?, textI: Int32, blobI: Int32) -> String {
        let t = colText(stmt, textI)
        if !t.isEmpty { return t }
        if sqlite3_column_type(stmt, blobI) == SQLITE_BLOB {
            let n = Int(sqlite3_column_bytes(stmt, blobI))
            if n > 0, let p = sqlite3_column_blob(stmt, blobI),
               let d = decodeAttributedBody(Data(bytes: p, count: n)) { return d }
        }
        return ""
    }
}

private struct Msg {
    var dateISO, text, sender, chatName, chatIdentifier: String
    var isFromMe: Bool; var attachmentCount: Int
    var dict: [String: Any] { [
        "date": dateISO, "text": text, "is_from_me": isFromMe, "sender": sender,
        "chat_name": chatName, "chat_identifier": chatIdentifier, "attachment_count": attachmentCount
    ] }
}

private let msgSelect = """
SELECT m.ROWID, m.date, m.text, m.attributedBody, m.is_from_me,
  COALESCE(h.id,''), COALESCE(NULLIF(c.display_name,''), c.chat_identifier, ''),
  COALESCE(c.chat_identifier,''),
  (SELECT COUNT(*) FROM message_attachment_join maj WHERE maj.message_id=m.ROWID)
FROM message m
JOIN chat_message_join cmj ON cmj.message_id=m.ROWID
JOIN chat c ON c.ROWID=cmj.chat_id
LEFT JOIN handle h ON h.ROWID=m.handle_id
"""

private func fetch(_ db: DB, _ sql: String, limit: Int, bind: (OpaquePointer?) -> Void) -> [Msg] {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db.db, sql, -1, &stmt, nil) == SQLITE_OK else {
        fail("sql: \(String(cString: sqlite3_errmsg(db.db)))")
    }
    defer { sqlite3_finalize(stmt) }
    bind(stmt)
    var out: [Msg] = []
    while sqlite3_step(stmt) == SQLITE_ROW, out.count < limit {
        let text = db.text(stmt, textI: 2, blobI: 3)
        let att = Int(sqlite3_column_int(stmt, 8))
        if text.isEmpty && att == 0 { continue }
        let fromMe = sqlite3_column_int(stmt, 4) != 0
        let sender = colText(stmt, 5)
        out.append(Msg(dateISO: appleISO(sqlite3_column_int64(stmt, 1)), text: text,
                       sender: fromMe ? "me" : sender, chatName: colText(stmt, 6),
                       chatIdentifier: colText(stmt, 7), isFromMe: fromMe, attachmentCount: att))
    }
    return out
}

private func cmdRecent(db: DB, hours: Int, limit: Int) -> [String: Any] {
    let cut = cutoffHours(hours)
    let tsql = """
    SELECT c.ROWID, COALESCE(NULLIF(c.display_name,''), c.chat_identifier), c.chat_identifier
    FROM message m JOIN chat_message_join cmj ON cmj.message_id=m.ROWID
    JOIN chat c ON c.ROWID=cmj.chat_id WHERE m.date>=? GROUP BY c.ROWID ORDER BY MAX(m.date) DESC LIMIT ?
    """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db.db, tsql, -1, &stmt, nil) == SQLITE_OK else {
        fail("sql: \(String(cString: sqlite3_errmsg(db.db)))")
    }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_int64(stmt, 1, cut); sqlite3_bind_int(stmt, 2, Int32(maxThreads))
    var ids: [(Int64, String, String)] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        ids.append((sqlite3_column_int64(stmt, 0), colText(stmt, 1), colText(stmt, 2)))
    }
    let per = max(1, min(recentPerThread, limit))
    var threads: [[String: Any]] = []
    for (cid, name, ident) in ids {
        let msgs = fetch(db, msgSelect + " WHERE c.ROWID=? AND m.date>=? ORDER BY m.date DESC LIMIT ?",
                         limit: per) { s in
            sqlite3_bind_int64(s, 1, cid); sqlite3_bind_int64(s, 2, cut); sqlite3_bind_int(s, 3, Int32(per))
        }
        threads.append(["chat_name": name, "chat_identifier": ident,
                        "messages": msgs.reversed().map(\.dict)])
    }
    return ["ok": true, "command": "recent", "hours": hours, "threads": threads]
}

private func cmdSearch(db: DB, query: String, days: Int, limit: Int) -> [String: Any] {
    let cut = cutoffHours(days * 24), q = query.lowercased(), scan = max(limit * 20, 2000)
    let cand = fetch(db, msgSelect + " WHERE m.date>=? ORDER BY m.date DESC LIMIT ?", limit: scan) { s in
        sqlite3_bind_int64(s, 1, cut); sqlite3_bind_int(s, 2, Int32(scan))
    }
    let hits = Array(cand.filter { $0.text.lowercased().contains(q) }.prefix(limit))
    return ["ok": true, "command": "search", "query": query, "days": days, "messages": hits.map(\.dict)]
}

private func cmdThread(db: DB, handle: String, days: Int, limit: Int) -> [String: Any] {
    let cut = cutoffHours(days * 24)
    let sql = msgSelect + """
     WHERE m.date>=? AND (h.id=? OR c.chat_identifier=? OR c.display_name=? OR EXISTS (
       SELECT 1 FROM chat_handle_join chj JOIN handle hh ON hh.ROWID=chj.handle_id
       WHERE chj.chat_id=c.ROWID AND hh.id=?)) ORDER BY m.date DESC LIMIT ?
    """
    let msgs = fetch(db, sql, limit: limit) { s in
        sqlite3_bind_int64(s, 1, cut)
        for i: Int32 in 2...5 { sqlite3_bind_text(s, i, handle, -1, SQLITE_TRANSIENT) }
        sqlite3_bind_int(s, 6, Int32(limit))
    }
    return ["ok": true, "command": "thread", "handle": handle, "days": days,
            "messages": msgs.reversed().map(\.dict)]
}

private func writeResponse(_ url: URL, _ obj: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? d.write(to: url, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

private func serve() {
    let dir = supportDir()
    let req = dir.appendingPathComponent("request.json")
    let res = dir.appendingPathComponent("response.json")
    guard let raw = try? Data(contentsOf: req),
          let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
        writeResponse(res, ["ok": false, "error": "missing or invalid request.json"]); exit(1)
    }
    try? FileManager.default.removeItem(at: req)
    let command = obj["command"] as? String ?? ""
    let limit = min(max(obj["limit"] as? Int ?? defaultLimit, 1), 500)
    let database = DB(obj["db"] as? String ?? chatDB())
    let result: [String: Any]
    switch command {
    case "recent":
        result = cmdRecent(db: database, hours: max(obj["hours"] as? Int ?? 24, 1), limit: limit)
    case "search":
        let q = obj["query"] as? String ?? ""
        result = q.isEmpty ? ["ok": false, "error": "search requires query"]
            : cmdSearch(db: database, query: q, days: max(obj["days"] as? Int ?? 30, 1), limit: limit)
    case "thread":
        let h = obj["handle"] as? String ?? ""
        result = h.isEmpty ? ["ok": false, "error": "thread requires handle"]
            : cmdThread(db: database, handle: h, days: max(obj["days"] as? Int ?? 30, 1), limit: limit)
    default:
        result = ["ok": false, "error": "unknown command: \(command)"]
    }
    writeResponse(res, result)
    if (result["ok"] as? Bool) != true { exit(1) }
}

private func usage() -> Never {
    fputs("""
    Usage:
      imsg-helper --serve
      imsg-helper recent --hours N [--limit N] [--db PATH]
      imsg-helper search --query TEXT --days N [--limit N] [--db PATH]
      imsg-helper thread --handle PHONE_OR_EMAIL_OR_NAME --days N [--limit N] [--db PATH]
    """, stderr)
    exit(2)
}

private func parseArgs(_ args: [String]) -> (String, [String: String]) {
    guard let cmd = args.first else { usage() }
    var opts: [String: String] = [:]; var i = 1; let a = Array(args)
    while i < a.count {
        guard a[i].hasPrefix("--"), i + 1 < a.count else { usage() }
        opts[String(a[i].dropFirst(2))] = a[i + 1]; i += 2
    }
    return (cmd, opts)
}

func main() {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty { usage() }
    if args[0] == "--serve" || args[0] == "serve" { serve(); return }
    let (cmd, opts) = parseArgs(args)
    let limit = min(max(Int(opts["limit"] ?? "") ?? defaultLimit, 1), 500)
    let database = DB(opts["db"] ?? chatDB())
    switch cmd {
    case "recent":
        emit(cmdRecent(db: database, hours: max(Int(opts["hours"] ?? "") ?? 24, 1), limit: limit))
    case "search":
        guard let q = opts["query"], !q.isEmpty else { fail("search requires --query") }
        emit(cmdSearch(db: database, query: q, days: max(Int(opts["days"] ?? "") ?? 30, 1), limit: limit))
    case "thread":
        guard let h = opts["handle"], !h.isEmpty else { fail("thread requires --handle") }
        emit(cmdThread(db: database, handle: h, days: max(Int(opts["days"] ?? "") ?? 30, 1), limit: limit))
    default: usage()
    }
}
main()
