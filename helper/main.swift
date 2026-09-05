// rime-translate-helper
//
// Local companion daemon for the rime-translate Rime plugin.
//  - serves GET /lookup?q=<chinese>  on 127.0.0.1 (offline SQLite first,
//    Cloudflare Workers AI as async fallback)
//  - exports a "hot cache" TSV consumed by the lua filter so the common
//    path needs no IPC at all
//
// Data layout under ~/Library/Application Support/rime-translate/:
//   ecdict.db     offline dictionary (built by scripts/build_dict.py)
//   config.json   {"account_id": "...", "api_token": "...", "model": "..."}
// Hot cache: ~/Library/Rime/rime_translate_cache.tsv

import Foundation
import Network
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

let defaultModel = "@cf/meta/llama-3.3-70b-instruct-fp8-fast"
let hotCacheTopN = 30000

func appSupportDir() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("rime-translate", isDirectory: true)
}

func rimeDir() -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent("Library/Rime", isDirectory: true)
}

struct AIConfig {
    var accountID = ""
    var apiToken = ""
    var model = defaultModel
    var timeoutSeconds: Double = 15

    // chat-style models need the messages API instead of text/source_lang
    var chatStyle: Bool { !model.contains("m2m100") }

    static func load(_ url: URL) -> AIConfig? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["account_id"] as? String, !id.isEmpty,
              let token = obj["api_token"] as? String, !token.isEmpty
        else { return nil }
        var c = AIConfig()
        c.accountID = id
        c.apiToken = token
        if let m = obj["model"] as? String, !m.isEmpty { c.model = m }
        if let t = obj["timeout_seconds"] as? Double, t > 0 { c.timeoutSeconds = t }
        return c
    }
}

final class Dict {
    private var db: OpaquePointer?
    private var dbRO: OpaquePointer?   // separate read-only conn for exports,
                                       // so big scans never block lookups
    private let queue = DispatchQueue(label: "rime-translate.dict")
    private(set) var aiConfig: AIConfig?
    // prepared statements reused across lookups (all access serialized on queue)
    private var stmtDict: OpaquePointer?
    private var stmtCache: OpaquePointer?
    private var stmtInsert: OpaquePointer?

    init(path: String, configURL: URL) throws {
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) != SQLITE_OK {
            throw NSError(domain: "dict", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cannot open \(path)"])
        }
        if sqlite3_open_v2(path, &dbRO, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            dbRO = nil
        }
        queue.sync {
            sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA cache_size=-32000;", nil, nil, nil)
            sqlite3_exec(db, """
                CREATE TABLE IF NOT EXISTS zh_en (
                    zh TEXT PRIMARY KEY, en TEXT NOT NULL,
                    score REAL NOT NULL DEFAULT 0, zh_freq INTEGER NOT NULL DEFAULT 0
                ) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS ai_cache (
                    zh TEXT PRIMARY KEY, en TEXT NOT NULL, created_at INTEGER NOT NULL
                );
                """, nil, nil, nil)
            var d: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT en FROM zh_en WHERE zh = ?1", -1, &d, nil)
            stmtDict = d
            var c: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT en FROM ai_cache WHERE zh = ?1", -1, &c, nil)
            stmtCache = c
            var i: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO ai_cache VALUES (?1, ?2, ?3)", -1, &i, nil)
            stmtInsert = i
        }
        sqlite3_exec(db, "PRAGMA busy_timeout=3000;", nil, nil, nil)
        if dbRO != nil {
            sqlite3_exec(dbRO!, "PRAGMA busy_timeout=5000;", nil, nil, nil)
        }
        // load AI config synchronously so the startup note is accurate
        queue.sync { self.aiConfig = AIConfig.load(configURL) }
    }

    func reloadConfig(_ url: URL) {
        queue.async { self.aiConfig = AIConfig.load(url) }
    }

    private func query(_ stmt: OpaquePointer?, bind zh: String) -> String? {
        guard let stmt = stmt else { return nil }
        // one prepared stmt per query type: serialize its full lifecycle
        return queue.sync {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            sqlite3_bind_text(stmt, 1, zh, -1, SQLITE_TRANSIENT)
            defer { sqlite3_reset(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else {
                return nil
            }
            return String(cString: c)
        }
    }

    func lookupDict(_ zh: String) -> String? {
        query(stmtDict, bind: zh)
    }

    func lookupCache(_ zh: String) -> String? {
        query(stmtCache, bind: zh)
    }

    func insertCache(_ zh: String, _ en: String) {
        queue.sync {
            guard let stmt = stmtInsert else { return }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            sqlite3_bind_text(stmt, 1, zh, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, en, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 3, Int64(Date().timeIntervalSince1970))
            _ = sqlite3_step(stmt)
        }
    }

    /// Top phrases for the hot cache file. Uses the read-only connection so
    /// a long scan never blocks candidate lookups.
    func topPhrases(_ n: Int) -> [(zh: String, en: String)] {
        guard let db = dbRO else { return [] }
        var out: [(String, String)] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT zh, en FROM zh_en ORDER BY zh_freq DESC, score DESC LIMIT ?1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(stmt, 1, Int32(n))
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((String(cString: sqlite3_column_text(stmt, 0)),
                        String(cString: sqlite3_column_text(stmt, 1))))
        }
        return out
    }

    func allCached() -> [(zh: String, en: String)] {
        guard let db = dbRO else { return [] }
        var out: [(String, String)] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT zh, en FROM ai_cache", -1, &stmt, nil) == SQLITE_OK else { return [] }
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((String(cString: sqlite3_column_text(stmt, 0)),
                        String(cString: sqlite3_column_text(stmt, 1))))
        }
        return out
    }
}

// MARK: - Cloudflare Workers AI

/// Cleans AI/model output before it is stored or exported:
/// the hot cache is a one-translation-per-line TSV, so any newline would
/// corrupt the file for the lua reader; stray quotes/numbering from chat
/// models ("1. apple") would render verbatim in candidates.
func sanitizeAI(_ s: String) -> String {
    var t = s
    // strip common chat-model decorations: leading "1. "/"1. "/"- "
    while let r = t.range(of: #"^\s*(?:[-•*]|\d+[.、)])\s*"#, options: .regularExpression) {
        t.removeSubrange(r)
    }
    t = t.replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
    // collapse runs of spaces left by the newline swap
    while t.contains("  ") {
        t = t.replacingOccurrences(of: "  ", with: " ")
    }
    return t.trimmingCharacters(in: .whitespaces)
}

func translateWithAI(_ text: String, cfg: AIConfig) async -> String? {
    let urlStr = "https://api.cloudflare.com/client/v4/accounts/\(cfg.accountID)/ai/run/\(cfg.model)"
    guard let url = URL(string: urlStr) else { return nil }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("Bearer \(cfg.apiToken)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = cfg.timeoutSeconds
    let body: [String: Any]
    if cfg.chatStyle {
        // instruct/chat models (llama, qwen, kimi...): messages API
        body = ["messages": [
            ["role": "system",
             "content": "Translate the Chinese word or phrase to English. Reply with up to 3 English translations separated by | , nothing else."],
            ["role": "user", "content": text],
        ], "max_tokens": 40]
    } else {
        // dedicated translation models (m2m100...)
        body = ["text": text, "source_lang": "chinese", "target_lang": "english"]
    }
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)

    guard let (data, resp) = try? await URLSession.shared.data(for: req),
          (resp as? HTTPURLResponse)?.statusCode == 200,
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          (obj["success"] as? Bool) != false,
          let result = obj["result"]
    else { return nil }

    func pick(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty else { return nil }
        return t
    }
    // chat models: result.choices[0].message.content
    if let dict = result as? [String: Any],
       let choices = dict["choices"] as? [[String: Any]],
       let msg = choices.first?["message"] as? [String: Any],
       let content = pick(msg["content"] as? String) {
        return sanitizeAI(content)
    }
    // translation models: result.translated_text (string or array)
    if let dict = result as? [String: Any] {
        if let one = pick(dict["translated_text"] as? String) { return sanitizeAI(one) }
        if let r = pick(dict["response"] as? String) { return sanitizeAI(r) }
    }
    if let arr = result as? [[String: Any]] {
        let parts = arr.compactMap { $0["translated_text"] as? String }
        if let joined = pick(parts.joined(separator: " ")) { return sanitizeAI(joined) }
    }
    return nil
}

// MARK: - Hot cache export
//
// The lua filter reloads its cache whenever the data changes. Rewriting the
// full multi-MB TSV on every learned word forces the filter into a full
// re-read on the typing path, so updates follow a base+delta protocol:
//   rime_translate_cache.tsv      base snapshot, "#rev=<n>" header
//   rime_translate_cache.delta    append-only entries added since the base
//   rime_translate_cache.meta     "base=<rev> delta_off=<bytes> rev=<rev>"
// The filter re-reads the base only when meta's base rev changes; otherwise
// it merges the few new delta bytes. Legacy filters that only watch the
// TSV's #rev header keep working unchanged.

let hotBaseURL = rimeDir().appendingPathComponent("rime_translate_cache.tsv")
let hotDeltaURL = rimeDir().appendingPathComponent("rime_translate_cache.delta")
let hotMetaURL = rimeDir().appendingPathComponent("rime_translate_cache.meta")

// only touched on exportQueue
var hotBaseRev = 0
var hotDeltaOff: UInt64 = 0
var hotDeltaLines = 0

func atomicWrite(_ text: String, to url: URL) {
    let tmp = url.appendingPathExtension("tmp")
    if (try? text.write(to: tmp, atomically: true, encoding: .utf8)) != nil {
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}

func writeHotMeta(rev: Int) {
    atomicWrite("base=\(hotBaseRev) delta_off=\(hotDeltaOff) rev=\(rev)\n", to: hotMetaURL)
}

func hotTsvEntry(_ zh: String, _ en: String) -> String? {
    guard !zh.contains("\t"), !en.contains("\t"),
          !en.contains("\n"), !en.contains("\r"),
          zh.utf8.count <= 48 else { return nil }
    return "\(zh)\t\(truncated(en))"
}

func exportHotCache(_ dict: Dict) {
    let dir = rimeDir()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let rev = Int(Date().timeIntervalSince1970 * 1000)
    var lines: [String] = ["#rev=\(rev)"]
    let cached = dict.allCached()
    for p in dict.topPhrases(hotCacheTopN * 3) {
        guard isCommonCJK(p.zh), let e = hotTsvEntry(p.zh, p.en) else { continue }
        lines.append(e)
        if lines.count >= hotCacheTopN + cached.count { break }
    }
    // ai results LAST: the filter's loader overwrites duplicates as it reads,
    // so curated/learned translations win over raw dictionary noise
    for p in cached {
        if let e = hotTsvEntry(p.zh, p.en) { lines.append(e) }
    }
    let tmp = hotBaseURL.appendingPathExtension("tmp")
    if (try? lines.joined(separator: "\n").appendLine().write(to: tmp, atomically: true, encoding: .utf8)) != nil {
        _ = try? FileManager.default.replaceItemAt(hotBaseURL, withItemAt: tmp)
    }
    atomicWrite("", to: hotDeltaURL)
    hotBaseRev = rev
    hotDeltaOff = 0
    hotDeltaLines = 0
    writeHotMeta(rev: rev)
}

/// Incremental update: append new entries to the delta file, then publish
/// the new offset via meta. The filter sees meta change and merges exactly
/// those bytes -- no full re-read. The delta write completes before the
/// meta write, so a filter that observes meta.off can always read the data.
/// Once the delta has grown past 2000 lines the base is rebuilt so a fresh
/// session never has to replay an ever-growing delta.
func appendHotDelta(_ dict: Dict, _ entries: [(zh: String, en: String)]) {
    let rev = Int(Date().timeIntervalSince1970 * 1000)
    var chunk = ""
    for p in entries {
        if let e = hotTsvEntry(p.zh, p.en) { chunk += e + "\n" }
    }
    guard !chunk.isEmpty else { return }
    if !FileManager.default.fileExists(atPath: hotDeltaURL.path) {
        atomicWrite("", to: hotDeltaURL)
    }
    guard let fh = try? FileHandle(forWritingTo: hotDeltaURL) else { return }
    defer { try? fh.close() }
    let data = Data(chunk.utf8)
    _ = try? fh.seekToEnd()
    try? fh.write(contentsOf: data)
    hotDeltaOff += UInt64(data.count)
    writeHotMeta(rev: rev)
    hotDeltaLines += chunk.filter { $0 == "\n" }.count
    if hotDeltaLines > 2000 {
        exportHotCache(dict)
    }
}

// MARK: - async request pipeline

// MARK: - Hot cache helpers

func isCommonCJK(_ s: String) -> Bool {
    // restrict hot-cache entries to the URO basic block so rare
    // extension-A characters don't crowd out everyday words
    return s.unicodeScalars.allSatisfy { ($0.value >= 0x4E00 && $0.value <= 0x9FA5) }
}

func truncated(_ en: String) -> String {
    // lua renders at most max_entries_vertical (5); keep a small margin
    let parts = en.split(separator: "|", maxSplits: 7)
    return parts.joined(separator: "|")
}

extension String {
    func appendLine() -> String { self + "\n" }
}

// MARK: - async request pipeline
//
// The lua filter never spawns processes while typing: on a hot-cache miss it
// just appends the word to rime_translate_requests.txt (a plain file append).
// A single async task drains that file every second -- answering from SQLite
// or Cloudflare AI -- then re-exports the hot cache with a bumped #rev header
// that the filter notices cheaply (reads one line) and reloads.

let requestsURL = rimeDir().appendingPathComponent("rime_translate_requests.txt")
let requestsOldURL = rimeDir().appendingPathComponent("rime_translate_requests.txt.old")
var requestsOffset: UInt64 = 0
// zh -> retry-eligible time. Failures (network blips, CF limits) get a
// 10-minute backoff instead of being blacklisted forever.
var attempted: [String: Date] = [:]

/// One AI translate attempt: on success pin it into ai_cache and log.
/// Split out so drainOnce can run several of these concurrently.
func translateAttempt(_ zh: String, dict: Dict) async -> (String, String?) {
    guard let cfg = dict.aiConfig else { return (zh, nil) }
    guard let en = await translateWithAI(zh, cfg: cfg) else { return (zh, nil) }
    dict.insertCache(zh, en)
    NSLog("ai: %@ -> %@", zh, en)
    return (zh, en)
}
let exportQueue = DispatchQueue(label: "rime-translate.export")

func doExportHotCache(_ dict: Dict) {
    exportQueue.sync { exportHotCache(dict) }
}

func doAppendHotDelta(_ dict: Dict, _ entries: [(zh: String, en: String)]) {
    exportQueue.sync { appendHotDelta(dict, entries) }
}

/// Returns the entries learned/found during this drain so the caller can
/// push them into the hot cache incrementally.
func drainOnce(_ dict: Dict) async -> [(zh: String, en: String)] {
    // Consume the request file by byte offset and NEVER truncate it:
    // lua appends with plain open("a") while we read, so the old
    // atomic-replace-to-empty used to silently drop every append that
    // landed on the old inode between our read and the swap.
    guard let fh = try? FileHandle(forReadingFrom: requestsURL) else {
        requestsOffset = 0
        return []
    }
    defer { try? fh.close() }
    let size = ((try? FileManager.default.attributesOfItem(atPath: requestsURL.path))?[.size] as? UInt64) ?? 0
    if size <= requestsOffset { return [] }
    try? fh.seek(toOffset: requestsOffset)
    let chunk = fh.readDataToEndOfFile()
    // only consume up to the last complete line; a torn tail line
    // (lua mid-append) stays pending for the next pass
    guard !chunk.isEmpty, let lastNL = chunk.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
    let complete = chunk[chunk.startIndex...lastNL]
    requestsOffset += UInt64(complete.count)
    let raw = String(decoding: complete, as: UTF8.self)

    var learned: [(zh: String, en: String)] = []
    var aiWords: [String] = []
    for word in raw.split(separator: "\n") {
        let zh = String(word).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !zh.isEmpty, zh.utf8.count <= 120 else { continue }
        if let expiry = attempted[zh], expiry > Date() { continue }

        if let en = dict.lookupDict(zh) {
            // dict hit outside the top-30k hot cache: pin it into
            // ai_cache so it lands in the exported hot cache too
            dict.insertCache(zh, en)
            learned.append((zh, en))
        } else if let en = dict.lookupCache(zh) {
            learned.append((zh, en))
        } else if dict.aiConfig != nil {
            aiWords.append(zh)
        }
    }
    // AI misses translate concurrently (bounded) -- a batch of cold words
    // finishes in the time of the slowest call instead of the sum
    if !aiWords.isEmpty {
        let maxConcurrent = 3
        var idx = 0
        await withTaskGroup(of: (String, String?).self) { group in
            for _ in 0..<min(maxConcurrent, aiWords.count) {
                let zh = aiWords[idx]; idx += 1
                group.addTask { await translateAttempt(zh, dict: dict) }
            }
            for await (zh, en) in group {
                if let en = en {
                    learned.append((zh, en))
                } else {
                    // retry eligible in 10 minutes (network blips, CF limits)
                    attempted[zh] = Date().addingTimeInterval(600)
                }
                if idx < aiWords.count {
                    let next = aiWords[idx]; idx += 1
                    group.addTask { await translateAttempt(next, dict: dict) }
                }
            }
        }
    }
    // the file only ever grows; roll it over once it passes 4 MB (checked
    // right after a full drain, so our offset covers everything). Appends
    // landing between the read and the rename would be stranded in the old
    // inode -- a once-per-megabytes microsecond window we accept.
    if requestsOffset > 4_000_000 {
        try? FileManager.default.removeItem(at: requestsOldURL)
        try? FileManager.default.moveItem(at: requestsURL, to: requestsOldURL)
        requestsOffset = 0
    }
    return learned
}

func drainLoop(_ dict: Dict) -> Task<Void, Never> {
    return Task.detached(priority: .utility) {
        while !Task.isCancelled {
            let learned = await drainOnce(dict)
            if learned.isEmpty {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            // small batches: append to the delta file so the filter merges
            // just those bytes instead of re-reading the whole base; the
            // exporter itself rolls over to a full rebuild periodically
            doAppendHotDelta(dict, learned)
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }
}

// MARK: - HTTP server

func percentDecode(_ s: String) -> String {
    s.removingPercentEncoding ?? s
}

func jsonResponse(_ conn: NWConnection, code: Int, body: String) {
    let reason = code == 200 ? "OK" : (code == 400 ? "Bad Request" : "Not Found")
    let head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
    conn.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in
        conn.cancel()
    })
}

func handleRequest(_ data: Data, dict: Dict, pending: NegativeCache, conn: NWConnection) {
    guard let req = String(data: data, encoding: .utf8),
          let firstLine = req.split(separator: "\r\n", maxSplits: 1).first else {
        return jsonResponse(conn, code: 400, body: "{}")
    }
    let parts = firstLine.split(separator: " ")
    guard parts.count >= 2 else { return jsonResponse(conn, code: 400, body: "{}") }
    let target = String(parts[1])
    let path = target.split(separator: "?", maxSplits: 1).map(String.init)[0]

    switch path {
    case "/health":
        let hasDict = dict.lookupDict("苹果") != nil || dict.topPhrases(1).count > 0
        let ai = dict.aiConfig != nil
        return jsonResponse(conn, code: 200,
            body: "{\"status\":\"ok\",\"dict\":\(hasDict),\"ai\":\(ai)}")

    case "/lookup":
        guard let qStart = target.range(of: "?q=") else {
            return jsonResponse(conn, code: 400, body: "{\"error\":\"missing q\"}")
        }
        let raw = String(target[qStart.upperBound...])
        let q = percentDecode(raw.split(separator: "&").map(String.init)[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, q.utf8.count <= 120 else {
            return jsonResponse(conn, code: 200, body: "{\"q\":\"\(escapeJSON(q))\",\"en\":\"\",\"source\":\"none\"}")
        }

        if let cached = dict.lookupCache(q) {
            return jsonResponse(conn, code: 200,
                body: "{\"q\":\"\(escapeJSON(q))\",\"en\":\"\(escapeJSON(cached))\",\"source\":\"ai\"}")
        }
        if let en = dict.lookupDict(q) {
            return jsonResponse(conn, code: 200,
                body: "{\"q\":\"\(escapeJSON(q))\",\"en\":\"\(escapeJSON(en))\",\"source\":\"dict\"}")
        }
        maybeTranslate(q, dict: dict, pending: pending)
        return jsonResponse(conn, code: 200,
            body: "{\"q\":\"\(escapeJSON(q))\",\"en\":\"\",\"source\":\"pending\"}")

    default:
        return jsonResponse(conn, code: 404, body: "{\"error\":\"not found\"}")
    }
}

func escapeJSON(_ s: String) -> String {
    var out = ""
    for c in s.unicodeScalars {
        switch c {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if c.value < 0x20 { out += String(format: "\\u%04x", c.value) }
            else { out.unicodeScalars.append(c) }
        }
    }
    return out
}

/// Avoids hammering the AI endpoint for words nobody re-checks.
final class NegativeCache {
    private var seen: Set<String> = []
    private let lock = NSLock()
    func mark(_ w: String) {
        lock.lock(); seen.insert(w); lock.unlock()
    }
    func contains(_ w: String) -> Bool {
        lock.lock(); let v = seen.contains(w); lock.unlock()
        return v
    }
}

func maybeTranslate(_ q: String, dict: Dict, pending: NegativeCache) {
    guard let cfg = dict.aiConfig, !pending.contains(q) else { return }
    pending.mark(q)
    Task.detached(priority: .utility) {
        if let en = await translateWithAI(q, cfg: cfg) {
            dict.insertCache(q, en)
            // HTTP path is debug-only; delta-append keeps it consistent
            doAppendHotDelta(dict, [(q, en)])
        }
    }
}

// MARK: - main

var dbPath = appSupportDir().appendingPathComponent("ecdict.db").path
var port: UInt16 = 61899
var configPath = appSupportDir().appendingPathComponent("config.json").path

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    switch args[0] {
    case "--db": dbPath = args[1]; args.removeFirst(2)
    case "--port": port = UInt16(args[1]) ?? port; args.removeFirst(2)
    case "--config": configPath = args[1]; args.removeFirst(2)
    default: args.removeFirst()
    }
}

try? FileManager.default.createDirectory(atPath: appSupportDir().path, withIntermediateDirectories: true)

let configURL = URL(fileURLWithPath: configPath)
let dict: Dict
do {
    dict = try Dict(path: dbPath, configURL: configURL)
} catch {
    fputs("fatal: \(error.localizedDescription)\n", stderr)
    exit(1)
}
if dict.aiConfig == nil {
    fputs("note: no AI config at \(configPath); running offline-only\n", stderr)
}
if dict.topPhrases(1).isEmpty {
    fputs("warning: dictionary appears empty (\(dbPath))\n", stderr)
}

let pending = NegativeCache()

// start serving BEFORE the heavy initial export so restarts are instant
let params = NWParameters.tcp
params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
let listener = try NWListener(using: params)
listener.newConnectionHandler = { (conn: NWConnection) in
    conn.start(queue: .global(qos: .userInitiated))
    conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, error in
        if let data = data, error == nil {
            handleRequest(data, dict: dict, pending: pending, conn: conn)
        } else {
            conn.cancel()
        }
    }
}
listener.stateUpdateHandler = { (state: NWListener.State) in
    switch state {
    case .ready:
        print("rime-translate-helper listening on 127.0.0.1:\(port), db=\(dbPath)")
    case .failed(let err):
        fputs("listener failed: \(err)\n", stderr)
        exit(1)
    default: break
    }
}
listener.start(queue: .main)

// background startup: initial base export, THEN the drain loop -- delta
// appends must never run before a base snapshot exists
Task.detached(priority: .utility) {
    doExportHotCache(dict)
    _ = drainLoop(dict)
}

let configFD = open(configPath, O_EVTONLY)
if configFD >= 0 {
    let configWatch = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: configFD,
        eventMask: [.write, .delete],
        queue: .global(qos: .utility))
    configWatch.setEventHandler { dict.reloadConfig(configURL) }
    configWatch.resume()
}

signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }

dispatchMain()
