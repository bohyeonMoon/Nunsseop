import Foundation
import SQLite3
@testable import Nunsseop

/// Session files of pi, omp, omo and gjc in the shape the tools write them (read off real files; every word is made up).
enum PiFixture {
    static func line(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)) ?? Data(), as: UTF8.self)
    }

    /// `2026-10-10T15-01-07-867Z`
    static func stamp(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS'Z'"
        return format.string(from: date)
    }

    static func id(_ n: Int) -> String { String(format: "01a12655-029b-786a-b1ff-%012d", n) }

    /// omo and pi: `modelId`; omp and gjc put a title in the header.
    static func header(id: String, cwd: String, title: String? = nil) -> String {
        var object: [String: Any] = ["type": "session", "version": 3, "id": id, "timestamp": "2026-10-10T15:01:07.867Z", "cwd": cwd]
        if let title { object["title"] = title; object["titleSource"] = "auto" }
        return line(object)
    }

    /// omp's first line.
    static func titleLine(_ title: String) -> String { line(["type": "title", "v": 1, "title": title, "source": "auto", "updatedAt": "x", "pad": ""]) }

    static func modelChange(modelId: String, provider: String = "anthropic") -> String {
        line(["type": "model_change", "id": "m1", "parentId": NSNull(), "provider": provider, "modelId": modelId])
    }

    /// omp and gjc: `provider/model`.
    static func modelChange(model: String) -> String { line(["type": "model_change", "id": "m1", "parentId": NSNull(), "model": model]) }

    static func user(_ text: String = "hello") -> String {
        line(["type": "message", "id": "u1", "parentId": "m1", "message": ["role": "user", "content": [["type": "text", "text": text]]]])
    }

    static func assistant(model: String, input: Int = 2, output: Int = 100, cacheRead: Int = 0, cacheWrite: Int = 0) -> String {
        line(["type": "message", "id": "a1", "parentId": "u1", "message": [
            "role": "assistant", "model": model, "provider": "anthropic", "stopReason": "stop", "content": [],
            "usage": ["input": input, "output": output, "cacheRead": cacheRead, "cacheWrite": cacheWrite,
                      "totalTokens": input + output + cacheRead + cacheWrite]]])
    }

    static func sessionInfo(_ name: String) -> String { line(["type": "session_info", "id": "s1", "parentId": "a1", "name": name]) }
    static func titleChange(_ title: String) -> String { line(["type": "title_change", "id": "t1", "parentId": "a1", "source": "auto", "title": title]) }

    /// Writes `.<kind>/agent/sessions/<folder>/<time>_<id>.jsonl` under `home`, last modified `ago` seconds before `now`.
    @discardableResult
    static func write(_ lines: [String], kind: AgentKind, home: URL, id: String, ago: TimeInterval = 600, now: Date,
                      folder: String = "--Users-me-work--") throws -> URL {
        let url = home.appendingPathComponent(".\(kind.rawValue)/agent/sessions/\(folder)/\(stamp(now.addingTimeInterval(-ago - 60)))_\(id).jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-ago)], ofItemAtPath: url.path)
        return url
    }
}

/// OpenCode's database with the columns of `session` and `message` Nunsseop reads, and the ones it is told to leave alone.
enum OpenCodeFixture {
    struct Session {
        var id: String
        var directory: String
        var title = "New session - 2026-10-10T00:00:00.000Z"
        var parent: String? = nil
        var updated: Date
        var archived: Date? = nil
    }

    struct Answer {
        var session: String
        var created: Date
        var model: String = "gpt-5.5"
        var input = 500
        var read = 80_000
        var write = 0
    }

    static func id(_ n: Int) -> String { "ses_" + String(format: "%026d", n) }

    /// `wal`: in write-ahead mode, as OpenCode's real database is.
    static func create(home: URL, sessions: [Session], answers: [Answer] = [], wal: Bool = false) throws {
        let url = OpenCodeDB.url(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw POSIXError(.EIO) }
        if wal { try run(db, "PRAGMA journal_mode=WAL;") }
        try run(db, """
            CREATE TABLE session (id text PRIMARY KEY, project_id text NOT NULL, parent_id text, slug text NOT NULL, directory text NOT NULL,
              title text NOT NULL, version text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, time_archived integer);
            CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL,
              data text NOT NULL);
            """)
        func millis(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
        for session in sessions {
            let archived = session.archived.map { String(millis($0)) } ?? "NULL"
            let parent = session.parent.map { "'\($0)'" } ?? "NULL"
            try run(db, """
                INSERT INTO session VALUES ('\(session.id)', 'p', \(parent), 'slug', '\(session.directory)', '\(session.title)', '1', \
                \(millis(session.updated)), \(millis(session.updated)), \(archived));
                """)
        }
        try insert(answers, into: db)
    }

    /// More answers in a database made by `create`.
    static func add(_ answers: [Answer], home: URL) throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(OpenCodeDB.url(home: home).path, &db) == SQLITE_OK else { throw POSIXError(.EIO) }
        try insert(answers, into: db)
    }

    /// A second connection that holds the write lock, with a message written and not yet committed, until it is closed.
    static func holdWriteLock(home: URL, session: String) throws -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open(OpenCodeDB.url(home: home).path, &db) == SQLITE_OK else { throw POSIXError(.EIO) }
        try run(db, "BEGIN IMMEDIATE;")
        try insert([Answer(session: session, created: Date(), model: "uncommitted", input: 1, read: 1, write: 1)], into: db)
        return db
    }

    private static func insert(_ answers: [Answer], into db: OpaquePointer?) throws {
        func millis(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
        for answer in answers {
            let name = UUID().uuidString
            let data = PiFixture.line(["role": "assistant", "modelID": answer.model, "providerID": "openai",
                                       "tokens": ["total": 1, "input": answer.input, "output": 5, "reasoning": 0,
                                                  "cache": ["read": answer.read, "write": answer.write]]])
            try run(db, "INSERT INTO message VALUES ('msg-\(name)', '\(answer.session)', \(millis(answer.created)), \(millis(answer.created)), '\(data)');")
            let user = PiFixture.line(["role": "user", "time": ["created": 1]])
            try run(db, "INSERT INTO message VALUES ('usr-\(name)', '\(answer.session)', \(millis(answer.created) - 1), 0, '\(user)');")
        }
    }

    private static func run(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw POSIXError(.EIO) }
    }
}

/// Text kept in files beside the tests (`Tests/Goldens`), so a change to what is put in other tools' folders shows in review. Run the
/// tests with `UPDATE_GOLDENS=1` to write the current text.
enum Golden {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Goldens")

    /// Whether `text` is the golden `name`; a missing file or `UPDATE_GOLDENS` writes it (and says so, by failing the check).
    static func matches(_ text: String, named name: String) -> Bool {
        let url = folder.appendingPathComponent(name)
        if ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] == "1" {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url)
        }
        return (try? String(contentsOf: url, encoding: .utf8)) == text
    }
}
