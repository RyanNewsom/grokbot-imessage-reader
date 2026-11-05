// imsg-helper — read-only iMessage reader (macOS 13+). System SQLite only; no network/send.
// Resolves contact names from the local Contacts DB (read-only) and enforces a user-edited blocklist.
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
private var serveResponseURL: URL?
private func fail(_ m: String) -> Never {
    if let u = serveResponseURL { writeResponse(u, ["ok": false, "error": m]) } else { emit(["ok": false, "error": m]) }
    exit(1)
}
private func writeResponse(_ url: URL, _ obj: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? d.write(to: url, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}
private func home() -> String { NSHomeDirectory() }
private func supportDir() -> URL {
    URL(fileURLWithPath: home()).appendingPathComponent("Library/Application Support/\(supportName)")
}
private func chatDB() -> String { home() + "/Library/Messages/chat.db" }
private func blocklistPath() -> String { supportDir().appendingPathComponent("blocked.txt").path }
private func addressBookRoot() -> String { home() + "/Library/Application Support/AddressBook" }
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

// MARK: - Handle keys (phones: last 10 digits; emails: lowercased)

private func isPhoneLike(_ s: String) -> Bool {
    let allowed = CharacterSet(charactersIn: "0123456789+-(). ")
    return !s.isEmpty && s.unicodeScalars.allSatisfy { allowed.contains($0) }
}
private func handleKey(_ raw: String) -> String? {
    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.contains("@") { return "e:" + t.lowercased() }
    var digits = ""
    for u in t.unicodeScalars where CharacterSet.decimalDigits.contains(u) { digits.unicodeScalars.append(u) }
    if isPhoneLike(t), digits.count >= 10 { return "p:" + String(digits.suffix(10)) }
    return nil
}
private func norm(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
}

// MARK: - Contacts (read-only SQLite on AddressBook-v22.abcddb)

private struct ContactRecord {
    var display: String; var names: Set<String>; var first: String; var keys: Set<String>
}

private final class Contacts {
    var records: [ContactRecord] = []
    var nameByKey: [String: String] = [:]
    var warning: String?
    var sourcesRead = 0

    init(root: String) {
        var paths = [root + "/AddressBook-v22.abcddb"]
        let srcDir = root + "/Sources"
        if let subs = try? FileManager.default.contentsOfDirectory(atPath: srcDir) {
            for s in subs.sorted() { paths.append("\(srcDir)/\(s)/AddressBook-v22.abcddb") }
        }
        var problems: [String] = []
        for p in paths where FileManager.default.fileExists(atPath: p) || p == paths[0] {
            if let e = load(p) { problems.append(e) } else { sourcesRead += 1 }
        }
        if sourcesRead == 0 {
            warning = "contacts unavailable; sender_name/chat_contact_name are null (\(problems.first ?? "no AddressBook database found"))"
        } else if !problems.isEmpty {
            warning = "some contact sources could not be read (\(problems.count)); names may be incomplete"
        }
        for r in records.sorted(by: { $0.display < $1.display }) {
            for k in r.keys where nameByKey[k] == nil { nameByKey[k] = r.display }
        }
    }

    private func columns(_ db: OpaquePointer?, _ table: String) -> Set<String> {
        var stmt: OpaquePointer?; var out = Set<String>()
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { out.insert(colText(stmt, 1).uppercased()) }
        return out
    }

    /// Returns an error string, or nil on success.
    private func load(_ path: String) -> String? {
        var db: OpaquePointer?
        let uri = "file:\(path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            let e = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            db.map { _ = sqlite3_close($0) }
            return "cannot open contacts db: \(e)"
        }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "PRAGMA query_only=ON;", nil, nil, nil)
        sqlite3_busy_timeout(db, 3000)
        let need: [String: Set<String>] = [
            "ZABCDRECORD": ["Z_PK", "ZFIRSTNAME", "ZLASTNAME", "ZORGANIZATION", "ZNICKNAME"],
            "ZABCDPHONENUMBER": ["ZOWNER", "ZFULLNUMBER"],
            "ZABCDEMAILADDRESS": ["ZOWNER", "ZADDRESS"],
        ]
        for (t, cols) in need where !cols.isSubset(of: columns(db, t)) {
            return "unexpected contacts schema (\(t))"
        }
        var recs: [Int64: ContactRecord] = [:]
        func each(_ sql: String, _ body: (OpaquePointer?) -> Void) -> Bool {
            var s: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(s) }
            while sqlite3_step(s) == SQLITE_ROW { body(s) }
            return true
        }
        let okR = each("SELECT Z_PK, ZFIRSTNAME, ZLASTNAME, ZORGANIZATION, ZNICKNAME FROM ZABCDRECORD") { s in
            let f = colText(s, 1).trimmingCharacters(in: .whitespaces)
            let l = colText(s, 2).trimmingCharacters(in: .whitespaces)
            let o = colText(s, 3).trimmingCharacters(in: .whitespaces)
            let n = colText(s, 4).trimmingCharacters(in: .whitespaces)
            let full = [f, l].filter { !$0.isEmpty }.joined(separator: " ")
            let display = !full.isEmpty ? full : (!n.isEmpty ? n : o)
            guard !display.isEmpty else { return }
            let names = Set([full, n, o].filter { !$0.isEmpty }.map(norm))
            recs[sqlite3_column_int64(s, 0)] = ContactRecord(display: display, names: names, first: norm(f), keys: [])
        }
        let okP = each("SELECT ZOWNER, ZFULLNUMBER FROM ZABCDPHONENUMBER WHERE ZFULLNUMBER IS NOT NULL") { s in
            if let k = handleKey(colText(s, 1)) { recs[sqlite3_column_int64(s, 0)]?.keys.insert(k) }
        }
        let okE = each("SELECT ZOWNER, ZADDRESS FROM ZABCDEMAILADDRESS WHERE ZADDRESS IS NOT NULL") { s in
            if let k = handleKey(colText(s, 1)) { recs[sqlite3_column_int64(s, 0)]?.keys.insert(k) }
        }
        guard okR, okP, okE else { return "contacts query failed: \(String(cString: sqlite3_errmsg(db)))" }
        records.append(contentsOf: recs.values.filter { !$0.keys.isEmpty })
        return nil
    }

    func name(for handle: String) -> String? { handleKey(handle).flatMap { nameByKey[$0] } }

    /// Contacts whose full name / nickname / organization equals `q` (case-insensitive). With
    /// `allowFirst`, falls back to first-name matches. Records sharing a handle are merged
    /// (the same person synced from several accounts).
    func clusters(named q: String, allowFirst: Bool) -> [(name: String, keys: Set<String>)] {
        let n = norm(q)
        guard !n.isEmpty else { return [] }
        var hits = records.filter { $0.names.contains(n) }
        if hits.isEmpty && allowFirst { hits = records.filter { $0.first == n } }
        var out: [(name: String, keys: Set<String>)] = []
        for r in hits.sorted(by: { $0.display < $1.display }) {
            var merged = (name: r.display, keys: r.keys)
            out.removeAll { c in
                if c.keys.isDisjoint(with: merged.keys) { return false }
                merged.keys.formUnion(c.keys); merged.name = min(merged.name, c.name); return true
            }
            out.append(merged)
        }
        return out.sorted { $0.name < $1.name }
    }
}

// MARK: - Blocklist (user-edited file; the helper never writes it)

private struct Blocklist {
    var path: String
    var exists = false
    var entries = 0
    var raw: Set<String> = []   // normalized entries (chat ids, group names, contact names, handles)
    var keys: Set<String> = []  // handle keys, including handles of blocked contact names
    var unresolvedNames = 0

    init(path: String, contacts: Contacts?) {
        self.path = path
        guard FileManager.default.fileExists(atPath: path) else { return }
        exists = true
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            fail("blocklist exists but cannot be read; refusing to return messages: \(path)")
        }
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            entries += 1
            raw.insert(norm(t))
            if let k = handleKey(t) { keys.insert(k); continue }
            if let c = contacts {
                let cl = c.clusters(named: t, allowFirst: false)
                for x in cl { keys.formUnion(x.keys) }
                if cl.isEmpty && c.sourcesRead == 0 { unresolvedNames += 1 }
            }
        }
    }
    func chatBlocked(ident: String, name: String) -> Bool {
        if raw.contains(norm(ident)) || raw.contains(norm(name)) { return true }
        if let k = handleKey(ident), keys.contains(k) { return true }
        return false
    }
    func handleBlocked(_ h: String) -> Bool {
        if raw.contains(norm(h)) { return true }
        if let k = handleKey(h), keys.contains(k) { return true }
        return false
    }
}

private final class Ctx {
    let db: DB; let contacts: Contacts; let block: Blocklist
    var blocked = 0
    init(db: DB, contacts: Contacts, block: Blocklist) { self.db = db; self.contacts = contacts; self.block = block }
    func finish(_ r: [String: Any]) -> [String: Any] {
        var out = r
        out["blocked_count"] = blocked
        var warns: [String] = []
        if let w = contacts.warning { warns.append(w) }
        if block.unresolvedNames > 0 {
            warns.append("\(block.unresolvedNames) blocklist name entr\(block.unresolvedNames == 1 ? "y" : "ies") could not be matched to contacts; only exact chat/group-name matches are blocked for them")
        }
        if !warns.isEmpty { out["warning"] = warns.joined(separator: "; ") }
        return out
    }
}

// MARK: - Messages

private struct Msg {
    var dateISO, text, sender, chatName, chatIdentifier: String
    var senderName, chatContactName: String?
    var isFromMe: Bool; var attachmentCount: Int
    var dict: [String: Any] { [
        "date": dateISO, "text": text, "is_from_me": isFromMe, "sender": sender,
        "sender_name": senderName ?? NSNull(), "chat_contact_name": chatContactName ?? NSNull(),
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

private func prepare(_ ctx: Ctx, _ sql: String) -> OpaquePointer? {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(ctx.db.db, sql, -1, &stmt, nil) == SQLITE_OK else {
        fail("sql: \(String(cString: sqlite3_errmsg(ctx.db.db)))")
    }
    return stmt
}

/// Blocked chats/senders are dropped here, before any message text is decoded.
private func fetch(_ ctx: Ctx, _ sql: String, limit: Int, bind: (OpaquePointer?) -> Void) -> [Msg] {
    let stmt = prepare(ctx, sql)
    defer { sqlite3_finalize(stmt) }
    bind(stmt)
    var out: [Msg] = []
    while out.count < limit, sqlite3_step(stmt) == SQLITE_ROW {
        let fromMe = sqlite3_column_int(stmt, 4) != 0
        let sender = colText(stmt, 5), chatName = colText(stmt, 6), ident = colText(stmt, 7)
        if ctx.block.chatBlocked(ident: ident, name: chatName) || (!fromMe && ctx.block.handleBlocked(sender)) {
            ctx.blocked += 1; continue
        }
        let text = ctx.db.text(stmt, textI: 2, blobI: 3)
        let att = Int(sqlite3_column_int(stmt, 8))
        if text.isEmpty && att == 0 { continue }
        out.append(Msg(dateISO: appleISO(sqlite3_column_int64(stmt, 1)), text: text,
                       sender: fromMe ? "me" : sender, chatName: chatName, chatIdentifier: ident,
                       senderName: fromMe ? nil : ctx.contacts.name(for: sender),
                       chatContactName: ctx.contacts.name(for: ident),
                       isFromMe: fromMe, attachmentCount: att))
    }
    return out
}

private func cmdRecent(_ ctx: Ctx, hours: Int, limit: Int) -> [String: Any] {
    let cut = cutoffHours(hours)
    let tsql = """
    SELECT c.ROWID, COALESCE(NULLIF(c.display_name,''), c.chat_identifier), c.chat_identifier, COUNT(*)
    FROM message m JOIN chat_message_join cmj ON cmj.message_id=m.ROWID
    JOIN chat c ON c.ROWID=cmj.chat_id WHERE m.date>=? GROUP BY c.ROWID ORDER BY MAX(m.date) DESC LIMIT ?
    """
    let stmt = prepare(ctx, tsql)
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_int64(stmt, 1, cut); sqlite3_bind_int(stmt, 2, Int32(maxThreads + 200))
    var ids: [(Int64, String, String)] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        let name = colText(stmt, 1), ident = colText(stmt, 2)
        if ctx.block.chatBlocked(ident: ident, name: name) { ctx.blocked += Int(sqlite3_column_int(stmt, 3)); continue }
        ids.append((sqlite3_column_int64(stmt, 0), name, ident))
    }
    let per = max(1, min(recentPerThread, limit))
    var threads: [[String: Any]] = []
    for (cid, name, ident) in ids where threads.count < maxThreads {
        let msgs = fetch(ctx, msgSelect + " WHERE c.ROWID=? AND m.date>=? ORDER BY m.date DESC LIMIT ?",
                         limit: per) { s in
            sqlite3_bind_int64(s, 1, cid); sqlite3_bind_int64(s, 2, cut); sqlite3_bind_int(s, 3, Int32(per * 20))
        }
        if msgs.isEmpty { continue }
        threads.append(["chat_name": name, "chat_identifier": ident,
                        "chat_contact_name": ctx.contacts.name(for: ident) ?? NSNull(),
                        "messages": msgs.reversed().map(\.dict)])
    }
    return ctx.finish(["ok": true, "command": "recent", "hours": hours, "threads": threads])
}

private func cmdSearch(_ ctx: Ctx, query: String, days: Int, limit: Int) -> [String: Any] {
    let cut = cutoffHours(days * 24), q = query.lowercased(), scan = max(limit * 20, 2000)
    let cand = fetch(ctx, msgSelect + " WHERE m.date>=? ORDER BY m.date DESC LIMIT ?", limit: scan) { s in
        sqlite3_bind_int64(s, 1, cut); sqlite3_bind_int(s, 2, Int32(scan))
    }
    let hits = Array(cand.filter { $0.text.lowercased().contains(q) }.prefix(limit))
    return ctx.finish(["ok": true, "command": "search", "query": query, "days": days, "messages": hits.map(\.dict)])
}

private func blockedError(_ ctx: Ctx) -> [String: Any] {
    ctx.finish(["ok": false, "command": "thread", "blocked": true,
                "error": "this chat is blocked by the user's blocklist; no content returned"])
}

private func cmdThread(_ ctx: Ctx, handle: String, days: Int, limit: Int) -> [String: Any] {
    let cut = cutoffHours(days * 24)
    if ctx.block.handleBlocked(handle) { return blockedError(ctx) }

    // Chats matched directly by identifier or group name.
    var directChat = false
    let cs = prepare(ctx, "SELECT COALESCE(NULLIF(display_name,''), chat_identifier), chat_identifier FROM chat WHERE chat_identifier=?1 OR display_name=?1 COLLATE NOCASE")
    sqlite3_bind_text(cs, 1, handle, -1, SQLITE_TRANSIENT)
    while sqlite3_step(cs) == SQLITE_ROW {
        directChat = true
        if ctx.block.chatBlocked(ident: colText(cs, 1), name: colText(cs, 0)) { sqlite3_finalize(cs); return blockedError(ctx) }
    }
    sqlite3_finalize(cs)

    // Map every Messages handle to its key.
    var handlesByKey: [String: [String]] = [:]
    let hs = prepare(ctx, "SELECT DISTINCT id FROM handle")
    while sqlite3_step(hs) == SQLITE_ROW {
        let id = colText(hs, 0)
        if let k = handleKey(id) { handlesByKey[k, default: []].append(id) }
    }
    sqlite3_finalize(hs)

    var hset: Set<String> = [handle]
    var resolvedName: String?
    if let k = handleKey(handle) {
        hset.formUnion(handlesByKey[k] ?? [])
    } else if !directChat {
        let cl = ctx.contacts.clusters(named: handle, allowFirst: true)
        var usable: [(name: String, handles: [String])] = []
        var blockedClusters = 0
        for c in cl {
            let hh = c.keys.flatMap { handlesByKey[$0] ?? [] }.filter { !ctx.block.handleBlocked($0) }.sorted()
            if c.keys.contains(where: { ctx.block.keys.contains($0) }) && hh.isEmpty { blockedClusters += 1; continue }
            if !hh.isEmpty { usable.append((c.name, hh)) }
        }
        if usable.isEmpty && blockedClusters > 0 { return blockedError(ctx) }
        if usable.count > 1 {
            return ctx.finish(["ok": false, "command": "thread", "ambiguous": true,
                               "error": "contact name '\(handle)' matches \(usable.count) contacts; retry with one of the candidate handles",
                               "candidates": usable.map { ["name": $0.name, "handles": $0.handles] }])
        }
        if let u = usable.first { hset = Set(u.handles); resolvedName = u.name }
    }

    let hs2 = Array(hset).sorted()
    let ph = hs2.map { _ in "?" }.joined(separator: ",")
    let sql = msgSelect + """
     WHERE m.date>=? AND (h.id IN (\(ph)) OR c.chat_identifier IN (\(ph)) OR c.display_name=? COLLATE NOCASE OR EXISTS (
       SELECT 1 FROM chat_handle_join chj JOIN handle hh ON hh.ROWID=chj.handle_id
       WHERE chj.chat_id=c.ROWID AND hh.id IN (\(ph)))) ORDER BY m.date DESC LIMIT ?
    """
    let msgs = fetch(ctx, sql, limit: limit) { s in
        var i: Int32 = 1
        sqlite3_bind_int64(s, i, cut); i += 1
        for _ in 0..<2 { for h in hs2 { sqlite3_bind_text(s, i, h, -1, SQLITE_TRANSIENT); i += 1 } }
        sqlite3_bind_text(s, i, handle, -1, SQLITE_TRANSIENT); i += 1
        for h in hs2 { sqlite3_bind_text(s, i, h, -1, SQLITE_TRANSIENT); i += 1 }
        sqlite3_bind_int(s, i, Int32(limit * 5 + 500))
    }
    var r: [String: Any] = ["ok": true, "command": "thread", "handle": handle, "days": days,
                            "messages": msgs.reversed().map(\.dict)]
    if let n = resolvedName { r["resolved_contact_name"] = n; r["resolved_handles"] = hs2 }
    return ctx.finish(r)
}

private func cmdBlocklist(_ path: String) -> [String: Any] {
    let b = Blocklist(path: path, contacts: nil)
    return ["ok": true, "command": "blocklist", "path": b.path, "exists": b.exists, "entries": b.entries,
            "note": "This file is edited only by the user. The helper has no command to add or remove entries."]
}

// MARK: - Entry points

private struct Paths { var db: String; var contactsRoot: String; var blocklist: String }

private func run(_ command: String, _ get: (String) -> String?, _ paths: Paths) -> [String: Any] {
    let limit = min(max(Int(get("limit") ?? "") ?? defaultLimit, 1), 500)
    if command == "blocklist" { return cmdBlocklist(paths.blocklist) }
    guard ["recent", "search", "thread"].contains(command) else { return ["ok": false, "error": "unknown command: \(command)"] }
    let db = DB(paths.db)
    let contacts = Contacts(root: paths.contactsRoot)
    let ctx = Ctx(db: db, contacts: contacts, block: Blocklist(path: paths.blocklist, contacts: contacts))
    switch command {
    case "recent":
        return cmdRecent(ctx, hours: max(Int(get("hours") ?? "") ?? 24, 1), limit: limit)
    case "search":
        guard let q = get("query"), !q.isEmpty else { return ["ok": false, "error": "search requires query"] }
        return cmdSearch(ctx, query: q, days: max(Int(get("days") ?? "") ?? 30, 1), limit: limit)
    default:
        guard let h = get("handle"), !h.isEmpty else { return ["ok": false, "error": "thread requires handle"] }
        return cmdThread(ctx, handle: h, days: max(Int(get("days") ?? "") ?? 30, 1), limit: limit)
    }
}

private func serve() {
    let dir = supportDir()
    let req = dir.appendingPathComponent("request.json")
    let res = dir.appendingPathComponent("response.json")
    serveResponseURL = res
    guard let raw = try? Data(contentsOf: req),
          let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
        writeResponse(res, ["ok": false, "error": "missing or invalid request.json"]); exit(1)
    }
    try? FileManager.default.removeItem(at: req)
    // Requests can never choose the blocklist or contacts location.
    let paths = Paths(db: obj["db"] as? String ?? chatDB(), contactsRoot: addressBookRoot(), blocklist: blocklistPath())
    let result = run(obj["command"] as? String ?? "", { k in
        if let s = obj[k] as? String { return s }
        if let n = obj[k] as? Int { return String(n) }
        return nil
    }, paths)
    writeResponse(res, result)
    if (result["ok"] as? Bool) != true { exit(1) }
}

private func usage() -> Never {
    fputs("""
    Usage:
      imsg-helper --serve
      imsg-helper recent --hours N [--limit N] [--db PATH]
      imsg-helper search --query TEXT --days N [--limit N] [--db PATH]
      imsg-helper thread --handle PHONE_EMAIL_CHAT_OR_CONTACT_NAME --days N [--limit N] [--db PATH]
      imsg-helper blocklist
    Testing only (require --db pointing at a non-default database):
      --contacts-root DIR   AddressBook-style folder
      --blocklist PATH      blocklist file
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
    var paths = Paths(db: opts["db"] ?? chatDB(), contactsRoot: addressBookRoot(), blocklist: blocklistPath())
    if opts["contacts-root"] != nil || opts["blocklist"] != nil {
        // Overrides exist for tests against fake data; they never apply to the real chat.db.
        guard let d = opts["db"], (d as NSString).standardizingPath != (chatDB() as NSString).standardizingPath else {
            fail("--contacts-root/--blocklist are only allowed with --db pointing at a test database")
        }
        if let c = opts["contacts-root"] { paths.contactsRoot = c }
        if let b = opts["blocklist"] { paths.blocklist = b }
    }
    let result = run(cmd, { opts[$0] }, paths)
    emit(result)
    if (result["ok"] as? Bool) != true { exit(1) }
}
main()
