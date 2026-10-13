import Foundation

/// pi and the tools built on it (omp, omo) keep one JSONL file per session, and so does gjc, in a layout of the same shape:
/// `~/.<tool>/agent/sessions/<folder>/<time>_<id>.jsonl`, where `<time>` is `2026-10-10T15-01-07-867Z` and the folder is
/// the working directory in some encoding that is not read here (the header's `cwd` says it).
enum PiSessions {
    private static let timeLength = 24
    private static let suffix = ".jsonl"

    /// Where a tool keeps its session folders; nil for a tool that isn't in the family.
    static func root(_ kind: AgentKind, home: URL) -> URL? {
        kind.isPiFamily ? home.appendingPathComponent(".\(kind.rawValue)/agent/sessions", isDirectory: true) : nil
    }

    /// Whether a folder is one of `gjc team`'s worker worktrees (`<repo>/.gjc/_session-<lead>/state/team/<n>/worktrees/worker-<k>`),
    /// whose sessions are a team's subagents, not conversations anyone opens.
    static func isTeamWorker(folder: String) -> Bool { folder.contains("/.gjc/_session-") }

    /// The id in a session file's name, `<time>_<id>.jsonl`; nil for any other name or an id that isn't a safe one.
    static func sessionID(fileName: String) -> String? {
        guard fileName.hasSuffix(suffix), fileName.count > timeLength + 1 + suffix.count else { return nil }
        let scalars = Array(fileName)
        guard scalars[timeLength] == "_", scalars[timeLength - 1] == "Z", scalars[10] == "T" else { return nil }
        let id = String(fileName.dropFirst(timeLength + 1).dropLast(suffix.count))
        return Resume.isSafeSession(id) ? id : nil
    }

    static func sessionID(path: String) -> String? { sessionID(fileName: (path as NSString).lastPathComponent) }

    /// The tool whose session folder holds a session file; nil for a path in none.
    static func owner(ofPath path: String) -> AgentKind? {
        AgentKind.allCases.first { $0.isPiFamily && path.contains("/.\($0.rawValue)/agent/sessions/") }
    }

    /// The folders under the tool's root.
    static func folders(_ kind: AgentKind, home: URL) -> [URL] {
        guard let root = root(kind, home: home) else { return [] }
        return (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
    }

    /// The session's file: the newest one named for it in any of the tool's folders.
    static func locate(_ kind: AgentKind, session: String, home: URL) -> URL? {
        let files = FileManager.default
        let matches = folders(kind, home: home).compactMap { folder -> URL? in
            let names = (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.first { sessionID(fileName: $0) == session }.map { folder.appendingPathComponent($0) }
        }
        func modified(_ url: URL) -> Date { (try? files.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast }
        return matches.max { modified($0) < modified($1) }
    }
}
