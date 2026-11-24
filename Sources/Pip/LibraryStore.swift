import Foundation
import SQLite3

struct CategoryCount: Hashable, Identifiable {
    var category: String
    var subcategory: String
    var count: Int
    var id: String { category + "›" + subcategory }
}

struct Passage: Identifiable {
    var transcriptID: Int64
    var title: String
    var path: String
    var text: String
    var id: String { "\(transcriptID)-\(text.hashValue)" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Local SQLite library at ~/Library/Application Support/Pip/library.sqlite.
/// Full-text search (FTS5) over whole transcripts and over ~1,200-character chunks for Q&A.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var records: [TranscriptRecord] = []
    @Published private(set) var categories: [CategoryCount] = []

    var youtubeFolders: [YouTubeFolder] { YouTubeFolder.sections(for: records) }

    private var db: OpaquePointer?

    init(url: URL = Prefs.supportDirectory.appendingPathComponent("library.sqlite")) {
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            print("Doggo could not open the library at \(url.path)")
            return
        }
        sqlite3_busy_timeout(db, 2000)
        exec("""
        PRAGMA foreign_keys = ON;
        CREATE TABLE IF NOT EXISTS transcripts(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at REAL NOT NULL,
            category TEXT NOT NULL,
            subcategory TEXT NOT NULL,
            data TEXT NOT NULL,
            raw TEXT NOT NULL
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS transcripts_fts USING fts5(title, summary, body);
        CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(body, transcript_id UNINDEXED);
        CREATE TABLE IF NOT EXISTS transcript_highlights(
            id TEXT PRIMARY KEY,
            transcript_id INTEGER NOT NULL REFERENCES transcripts(id) ON DELETE CASCADE,
            part TEXT NOT NULL,
            location INTEGER NOT NULL,
            length INTEGER NOT NULL,
            text TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS highlights_transcript ON transcript_highlights(transcript_id);
        """)
        reload()
    }

    deinit { sqlite3_close(db) }

    // MARK: - Reading

    func reload() {
        var out: [TranscriptRecord] = []
        query("SELECT id, created_at, data FROM transcripts ORDER BY created_at DESC") { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            let created = sqlite3_column_double(stmt, 1)
            guard let json = LibraryStore.text(stmt, 2),
                  var r = try? JSONDecoder().decode(TranscriptRecord.self, from: Data(json.utf8)) else { return }
            r.id = id
            r.createdAt = Date(timeIntervalSince1970: created)
            out.append(r)
        }
        records = out

        var cats: [CategoryCount] = []
        query("SELECT category, subcategory, COUNT(*) FROM transcripts GROUP BY category, subcategory ORDER BY category, subcategory") { stmt in
            cats.append(CategoryCount(category: LibraryStore.text(stmt, 0) ?? "",
                                      subcategory: LibraryStore.text(stmt, 1) ?? "",
                                      count: Int(sqlite3_column_int(stmt, 2))))
        }
        categories = cats
    }

    func rawText(for id: Int64) -> String {
        var raw = ""
        query("SELECT raw FROM transcripts WHERE id = ?", bind: [.int(id)]) { stmt in
            raw = LibraryStore.text(stmt, 0) ?? ""
        }
        return raw
    }

    // MARK: - Writing

    func insert(_ record: TranscriptRecord) -> Int64? {
        guard let data = try? JSONEncoder().encode(record) else { return nil }
        var id: Int64 = 0
        let saved = transaction {
            guard run("INSERT INTO transcripts(created_at, category, subcategory, data, raw) VALUES (?, ?, ?, ?, ?)",
                      bind: [.double(record.createdAt.timeIntervalSince1970), .text(record.category),
                             .text(record.subcategory), .text(String(decoding: data, as: UTF8.self)),
                             .text(record.rawText)]) else { return false }
            id = sqlite3_last_insert_rowid(db)
            return indexDocument(id: id, record: record, body: record.rawText)
                && Self.chunk(record.rawText).allSatisfy {
                    run("INSERT INTO chunks_fts(body, transcript_id) VALUES (?, ?)", bind: [.text($0), .int(id)])
                }
        }
        guard saved else { return nil }
        reload()
        return id
    }

    @discardableResult
    func update(_ record: TranscriptRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        let id = record.id
        guard transaction({
            run("UPDATE transcripts SET category = ?, subcategory = ?, data = ? WHERE id = ?",
                bind: [.text(record.category), .text(record.subcategory),
                       .text(String(decoding: data, as: UTF8.self)), .int(id)])
                && sqlite3_changes(db) == 1
                && run("DELETE FROM transcripts_fts WHERE rowid = ?", bind: [.int(id)])
                && indexDocument(id: id, record: record, body: rawText(for: id))
        }) else { return false }
        reload()
        return true
    }

    @discardableResult
    func delete(id: Int64) -> Bool {
        guard transaction({
            run("DELETE FROM transcripts WHERE id = ?", bind: [.int(id)])
                && run("DELETE FROM transcripts_fts WHERE rowid = ?", bind: [.int(id)])
                && run("DELETE FROM chunks_fts WHERE transcript_id = ?", bind: [.int(id)])
        }) else { return false }
        reload()
        return true
    }

    func highlights(for transcriptID: Int64) -> [TranscriptHighlight] {
        var result: [TranscriptHighlight] = []
        query("""
            SELECT id, part, location, length, text FROM transcript_highlights
            WHERE transcript_id = ? ORDER BY part, location
            """, bind: [.int(transcriptID)]) { stmt in
            guard let id = Self.text(stmt, 0).flatMap(UUID.init(uuidString:)),
                  let part = Self.text(stmt, 1).flatMap(TranscriptText.init(rawValue:)),
                  let text = Self.text(stmt, 4) else { return }
            let location = Int(sqlite3_column_int64(stmt, 2))
            let length = Int(sqlite3_column_int64(stmt, 3))
            guard location >= 0, length > 0, location < Int.max - length else { return }
            result.append(TranscriptHighlight(id: id, part: part, range: NSRange(location: location, length: length), text: text))
        }
        return result
    }

    func addHighlight(_ highlight: TranscriptHighlight, to transcriptID: Int64) -> Bool {
        run("INSERT INTO transcript_highlights VALUES (?, ?, ?, ?, ?, ?)",
            bind: [.text(highlight.id.uuidString), .int(transcriptID), .text(highlight.part.rawValue),
                   .int(Int64(highlight.range.location)), .int(Int64(highlight.range.length)), .text(highlight.text)])
    }

    func removeHighlight(_ id: UUID) -> Bool {
        run("DELETE FROM transcript_highlights WHERE id = ?", bind: [.text(id.uuidString)])
    }

    private func indexDocument(id: Int64, record: TranscriptRecord, body: String) -> Bool {
        let channel = record.folder.kind == .youtube ? record.folder.channel?.name : nil
        let title = [record.title, channel].compactMap { $0 }.joined(separator: "\n")
        return run("INSERT INTO transcripts_fts(rowid, title, summary, body) VALUES (?, ?, ?, ?)",
                   bind: [.int(id), .text(title), .text(record.summary), .text(body)])
    }

    /// Splits text into ~1,200-character pieces on sentence boundaries.
    static func chunk(_ text: String, size: Int = 1200) -> [String] {
        var chunks: [String] = []
        var current = ""
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sub, _, _, _ in
            guard let s = sub else { return }
            if current.count + s.count > size, !current.isEmpty {
                chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            }
            current += s
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return chunks
    }

    // MARK: - Search

    private static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "about", "what", "which", "who",
        "how", "why", "when", "is", "are", "was", "were", "do", "does", "did", "i", "me", "my", "have",
        "has", "had", "saved", "say", "said", "tell", "with", "that", "this", "it", "any", "anything", "be"
    ]

    /// Turns a natural-language question into an FTS5 query: meaningful words, prefix-matched, OR'd.
    static func ftsQuery(_ question: String) -> String? {
        let words = question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopwords.contains($0) }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " OR ")
    }

    func searchIDs(_ text: String) -> [Int64] {
        guard let q = LibraryStore.ftsQuery(text) else { return [] }
        var ids: [Int64] = []
        // Scope matches to the current fields, including when opening an older index.
        query("SELECT rowid FROM transcripts_fts WHERE transcripts_fts MATCH ? ORDER BY bm25(transcripts_fts, 5.0, 3.0, 1.0, 1.0) LIMIT 50",
              bind: [.text("{title summary body}: (\(q))")]) { stmt in ids.append(sqlite3_column_int64(stmt, 0)) }
        return ids
    }

    func passages(for question: String, limit: Int = 8) -> [Passage] {
        guard let q = LibraryStore.ftsQuery(question) else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var out: [Passage] = []
        query("SELECT transcript_id, body FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY rank LIMIT ?",
              bind: [.text(q), .int(Int64(limit))]) { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            guard let r = byID[id] else { return }
            out.append(Passage(transcriptID: id, title: r.title, path: r.path, text: LibraryStore.text(stmt, 1) ?? ""))
        }
        return out
    }

    // MARK: - SQLite plumbing

    enum Value {
        case int(Int64), double(Double), text(String)
    }

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK, let err {
            print("Doggo SQLite: \(String(cString: err))")
            sqlite3_free(err)
        }
    }

    private func prepare(_ sql: String, bind: [Value]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("Doggo SQLite prepare: \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        for (i, v) in bind.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .int(let n): sqlite3_bind_int64(stmt, idx, n)
            case .double(let d): sqlite3_bind_double(stmt, idx, d)
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            }
        }
        return stmt
    }

    @discardableResult
    private func run(_ sql: String, bind: [Value] = []) -> Bool {
        guard let stmt = prepare(sql, bind: bind) else { return false }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) != SQLITE_DONE {
            print("Doggo SQLite step: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }

    private func transaction(_ work: () -> Bool) -> Bool {
        guard run("BEGIN IMMEDIATE") else { return false }
        if work(), run("COMMIT") { return true }
        run("ROLLBACK")
        return false
    }

    private func query(_ sql: String, bind: [Value] = [], row: (OpaquePointer) -> Void) {
        guard let stmt = prepare(sql, bind: bind) else { return }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
        sqlite3_finalize(stmt)
    }

    private static func text(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: c)
    }
}
