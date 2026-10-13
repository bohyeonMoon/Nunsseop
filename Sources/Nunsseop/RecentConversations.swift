import Foundation

/// A conversation of one of the tools that isn't open, found in the tools' own session files, for the Agents tab.
struct RecentConversation: Identifiable, Equatable {
    let kind: AgentKind
    let session: String
    let cwd: String
    let modified: Date
    var name: String? = nil
    /// The last thing the user asked, cleaned for one line.
    var prompt: String? = nil

    var id: String { "\(kind.rawValue)|\(session)" }
    var folder: String { (cwd as NSString).lastPathComponent }
    var tool: String { AgentRow.toolName(kind.rawValue) }

    /// The session's name, else the last prompt, else the folder.
    var title: String { name ?? prompt ?? folder }

    /// The folder (unless it is the title), the tool and how long ago it was last used.
    func details(now: Date) -> [String] {
        var parts: [String] = []
        if folder.caseInsensitiveCompare(title) != .orderedSame { parts.append(folder) }
        parts.append(tool)
        if let elapsed = AgentRow.elapsed(since: modified, now: now) { parts.append(String(localized: "\(elapsed) ago")) }
        return parts
    }
}

/// Finds the conversations to resume: the most recently used ones of the last week that aren't open, from
/// `~/.claude/projects/<folder>/<id>.jsonl`, `~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl`, the pi family's session
/// folders (see `PiSessions`) and OpenCode's database (see `OpenCodeDB`). A value type, so a scan can run off the main thread
/// on a copy; what was read from a file is kept until its size or time changes.
struct RecentConversations {
    static let limit = 5
    static let window: TimeInterval = 7 * 86_400
    /// Folders of tools' scratch sessions, which aren't conversations anyone returns to.
    static let scratch = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
    private static let headWindow = AgentTranscript.headWindow
    private static let tailWindow = 256 << 10

    private struct Candidate {
        let kind: AgentKind
        let session: String
        /// nil for an OpenCode session, which is a row of its database.
        let url: URL?
        let modified: Date
        let size: Int
        var row: OpenCodeDB.Session? = nil
    }

    private struct Info {
        var cwd: String
        var prompt: String?
        /// The title in the header of a pi family file.
        var title: String? = nil
    }

    private struct Cached {
        var modified: Date
        var size: Int
        var info: Info?
        var scan = AgentNameScan()
        var scanned: (modified: Date, size: Int)?
    }

    private var cache: [String: Cached] = [:]
    private var codexNames = CodexSessionNames()

    /// - excluding: session ids that are open (any case).
    mutating func list(home: URL, excluding open: Set<String>, now: Date = .now, scratch: [String] = RecentConversations.scratch) -> [RecentConversation] {
        let cutoff = now.addingTimeInterval(-Self.window)
        let candidates = (Self.claudeFiles(home: home, since: cutoff) + Self.codexFiles(home: home, since: cutoff)
                          + Self.piFiles(home: home, since: cutoff) + Self.openCodeRows(home: home, since: cutoff))
            .sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.session < $1.session }
        let paths = Set(candidates.compactMap(\.url?.path))
        cache = cache.filter { paths.contains($0.key) }
        var found: [RecentConversation] = []
        for candidate in candidates where found.count < Self.limit {
            guard !open.contains(candidate.session.lowercased()) else { continue }
            if let row = candidate.row {
                guard Self.isResumableFolder(row.directory, scratch: scratch) else { continue }
                found.append(RecentConversation(kind: .opencode, session: row.id, cwd: row.directory, modified: row.updated, name: row.title))
                continue
            }
            guard let url = candidate.url else { continue }
            let path = url.path
            var entry = cache[path]
            if entry?.modified != candidate.modified || entry?.size != candidate.size {
                let info: Info?
                switch candidate.kind {
                case .claude: info = Self.claudeInfo(url)
                case .codex: info = Self.codexInfo(url)
                default: info = Self.piInfo(url)
                }
                entry = Cached(modified: candidate.modified, size: candidate.size, info: info,
                               scan: entry?.scan ?? AgentNameScan(family: candidate.kind.isPiFamily ? .pi : .claude),
                               scanned: entry?.scanned)
            }
            guard var kept = entry else { continue }
            defer { cache[path] = kept }
            guard let info = kept.info, Self.isResumableFolder(info.cwd, scratch: scratch) else { continue }
            var name: String?
            switch candidate.kind {
            case .codex:
                codexNames.refresh(home: home)
                name = codexNames.names[candidate.session]
            default:
                if kept.scanned?.modified != candidate.modified || kept.scanned?.size != candidate.size {
                    kept.scan.advance(url)
                    kept.scanned = (candidate.modified, candidate.size)
                }
                name = kept.scan.name ?? info.title
            }
            found.append(RecentConversation(kind: candidate.kind, session: candidate.session, cwd: info.cwd,
                                            modified: candidate.modified, name: name, prompt: info.prompt))
        }
        return found
    }

    /// An absolute folder that exists and isn't under a scratch folder.
    static func isResumableFolder(_ cwd: String, scratch: [String] = RecentConversations.scratch) -> Bool {
        guard Resume.isSafeFolder(cwd) else { return false }
        if scratch.contains(where: { cwd == $0 || cwd.hasPrefix($0 + "/") }) { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: Candidates

    private static let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]

    private static func children(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
    }

    private static func file(_ url: URL, _ kind: AgentKind, session: String, since cutoff: Date) -> Candidate? {
        guard Resume.isSafeSession(session), let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
              let modified = values.contentModificationDate, modified >= cutoff, let size = values.fileSize else { return nil }
        return Candidate(kind: kind, session: session, url: url, modified: modified, size: size)
    }

    /// The top level of each project folder only: subagents keep their files in subfolders.
    private static func claudeFiles(home: URL, since cutoff: Date) -> [Candidate] {
        children(home.appendingPathComponent(".claude/projects")).flatMap { folder in
            children(folder).compactMap { url in
                url.pathExtension == "jsonl" ? file(url, .claude, session: url.deletingPathExtension().lastPathComponent, since: cutoff) : nil
            }
        }
    }

    /// Every day folder: they are named for the day a session began, and a resumed one keeps appending to its file there.
    private static func codexFiles(home: URL, since cutoff: Date) -> [Candidate] {
        var candidates: [Candidate] = []
        for year in children(home.appendingPathComponent(".codex/sessions")) {
            for month in children(year) {
                for day in children(month) {
                    for url in children(day) {
                        // rollout-YYYY-MM-DDThh-mm-ss-<session>.jsonl
                        let name = url.lastPathComponent
                        let prefix = "rollout-".count + 19 + 1
                        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"), name.count > prefix + ".jsonl".count else { continue }
                        let session = String(name.dropFirst(prefix).dropLast(".jsonl".count))
                        if let candidate = file(url, .codex, session: session, since: cutoff) { candidates.append(candidate) }
                    }
                }
            }
        }
        return candidates
    }

    /// The top level of each session folder of the pi family's tools.
    private static func piFiles(home: URL, since cutoff: Date) -> [Candidate] {
        AgentKind.allCases.filter(\.isPiFamily).flatMap { kind in
            PiSessions.folders(kind, home: home).flatMap { folder in
                children(folder).compactMap { url in
                    PiSessions.sessionID(fileName: url.lastPathComponent).flatMap { file(url, kind, session: $0, since: cutoff) }
                }
            }
        }
    }

    /// More rows than `limit`: some are left out later (open, or in a scratch folder).
    private static func openCodeRows(home: URL, since cutoff: Date) -> [Candidate] {
        OpenCodeDB.recent(home: home, since: cutoff, limit: limit * 4).compactMap { row in
            Resume.isSafeSession(row.id) ? Candidate(kind: .opencode, session: row.id, url: nil, modified: row.updated, size: 0, row: row) : nil
        }
    }

    // MARK: Reading

    private static func read(_ url: URL, head: Bool) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: url), let end = try? handle.seekToEnd() else { return [] }
        defer { try? handle.close() }
        let length = UInt64(head ? headWindow : tailWindow)
        let start = head || end <= length ? 0 : end - length
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.read(upToCount: Int(min(length, end - start))) else { return [] }
        let marker = head ? nil : Data("\"last-prompt\"".utf8)
        return data.split(separator: 0x0A).compactMap { line in
            if let marker, Data(line).range(of: marker) == nil { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
        }
    }

    /// The folder the session began in, and its last prompt. Nothing for a session that was run by a program
    /// (`entrypoint` of the SDK), or has no prompt of the user's.
    private static func claudeInfo(_ url: URL) -> Info? {
        var cwd: String?
        var asked = false
        for object in read(url, head: true) where object["isSidechain"] as? Bool != true {
            if cwd == nil, let folder = object["cwd"] as? String, !folder.isEmpty { cwd = folder }
            if !asked, object["type"] as? String == "user" {
                if let entrypoint = object["entrypoint"] as? String, entrypoint.hasPrefix("sdk") { return nil }
                asked = true
            }
        }
        guard let cwd else { return nil }
        let prompt = read(url, head: false).last { $0["type"] as? String == "last-prompt" }
            .flatMap { $0["lastPrompt"] as? String }.flatMap(AgentTranscript.cleanName)
        guard asked || prompt != nil else { return nil }
        return Info(cwd: cwd, prompt: prompt)
    }

    /// The folder a pi family session began in and its title (omp's `title` line, else the header's). Nothing for a file without a prompt of the user's.
    private static func piInfo(_ url: URL) -> Info? {
        var cwd: String?, title: String?, current: String?
        var asked = false
        for object in read(url, head: true) {
            switch object["type"] as? String {
            case "session":
                cwd = (object["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                title = (object["title"] as? String).flatMap(AgentTranscript.cleanName)
            case "title":
                // omp's first line, rewritten as the title changes: newer than the header's.
                current = (object["title"] as? String).flatMap(AgentTranscript.cleanName)
            case "message":
                if (object["message"] as? [String: Any])?["role"] as? String == "user" { asked = true }
            default:
                break
            }
        }
        guard let cwd, asked, !PiSessions.isTeamWorker(folder: cwd) else { return nil }
        return Info(cwd: cwd, prompt: nil, title: current ?? title)
    }

    /// Only a session started from the `codex` command line (`source` is `cli`) is offered: the ones `codex exec`, the
    /// desktop app, editors and other programs start are not conversations to pick up in a terminal.
    private static func codexInfo(_ url: URL) -> Info? {
        guard let meta = read(url, head: true).first, meta["type"] as? String == "session_meta",
              let payload = meta["payload"] as? [String: Any], payload["source"] as? String == "cli",
              let cwd = payload["cwd"] as? String, !cwd.isEmpty else { return nil }
        return Info(cwd: cwd, prompt: nil)
    }
}
