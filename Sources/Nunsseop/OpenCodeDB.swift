import Foundation
import SQLite3

/// What Nunsseop reads of OpenCode's database, `~/.local/share/opencode/opencode.db`: the `session` table (id, directory, title,
/// parent_id, time_updated in milliseconds) and the `message` table, whose `data` is JSON (`role`, `modelID`, `tokens`).
/// Opened read-only with a short busy timeout, and never written to. A database that is missing, locked or of another shape
/// gives nothing. OpenCode's database is in WAL mode: reading it while OpenCode is closed leaves SQLite's own `-shm` and `-wal`
/// files beside it (empty, no data of the database changes).
enum OpenCodeDB {
    struct Session: Equatable {
        let id: String
        let directory: String
        let title: String?
        let updated: Date
    }

    static func url(home: URL) -> URL { home.appendingPathComponent(".local/share/opencode/opencode.db") }

    /// OpenCode names a session `New session - <time>` (`Child session - …` for a subagent's) until it has a real title.
    static func title(_ raw: String) -> String? {
        raw.hasPrefix("New session - ") || raw.hasPrefix("Child session - ") ? nil : AgentTranscript.cleanName(raw)
    }

    /// The sessions used since `cutoff`, newest first: not a subagent's (`parent_id`) and not archived.
    static func recent(home: URL, since cutoff: Date, limit: Int) -> [Session] {
        query(home: home, """
            SELECT id, directory, title, time_updated FROM session
            WHERE parent_id IS NULL AND time_archived IS NULL AND time_updated >= ?1 ORDER BY time_updated DESC LIMIT ?2
            """, [.int(Int64(cutoff.timeIntervalSince1970 * 1000)), .int(Int64(limit))]).compactMap { row in
            guard case .text(let id) = row[0], case .text(let directory) = row[1], case .int(let updated) = row[3] else { return nil }
            var title: String?
            if case .text(let raw) = row[2] { title = Self.title(raw) }
            return Session(id: id, directory: directory, title: title, updated: Date(timeIntervalSince1970: Double(updated) / 1000))
        }
    }

    /// The folder, name, and the model and context of the latest answer of one session. nil when it isn't in the database.
    static func transcript(session: String, home: URL) -> AgentTranscript? {
        let info = query(home: home, "SELECT directory, title FROM session WHERE id = ?1", [.text(session)])
        guard let row = info.first, case .text(let directory) = row[0] else { return nil }
        var result = AgentTranscript(cwd: directory)
        if case .text(let raw) = row[1] { result.name = title(raw) }
        // The model is the newest answer's. The context is the newest answer's that counts any: OpenCode writes `tokens` as zeros for a
        // message it has only begun and leaves them so when the request is aborted or fails, which must not erase the figure.
        let latest = query(home: home, """
            SELECT json_extract(data, '$.modelID') FROM message
            WHERE session_id = ?1 AND json_extract(data, '$.role') = 'assistant' AND json_extract(data, '$.tokens') IS NOT NULL
            ORDER BY time_created DESC LIMIT 1
            """, [.text(session)])
        if case .text(let model)? = latest.first?.first, !model.isEmpty { result.model = model }
        let counted = query(home: home, """
            SELECT coalesce(json_extract(data, '$.tokens.input'), 0) + coalesce(json_extract(data, '$.tokens.cache.read'), 0)
                   + coalesce(json_extract(data, '$.tokens.cache.write'), 0) AS context FROM message
            WHERE session_id = ?1 AND json_extract(data, '$.role') = 'assistant' AND context > 0
            ORDER BY time_created DESC LIMIT 1
            """, [.text(session)])
        if case .int(let context)? = counted.first?.first { result.tokens = Int(context) }
        return result
    }

    enum Value: Equatable {
        case int(Int64)
        case text(String)
        case null
    }

    private static func query(home: URL, _ sql: String, _ arguments: [Value]) -> [[Value]] {
        let path = url(home: home).path
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        sqlite3_busy_timeout(db, 300)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, argument) in arguments.enumerated() {
            switch argument {
            case .int(let value): sqlite3_bind_int64(statement, Int32(index + 1), value)
            case .text(let value): sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
            case .null: sqlite3_bind_null(statement, Int32(index + 1))
            }
        }
        var rows: [[Value]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: .int(sqlite3_column_int64(statement, column))
                case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(statement, column)))
                default: .null
                }
            })
        }
        return rows
    }
}
