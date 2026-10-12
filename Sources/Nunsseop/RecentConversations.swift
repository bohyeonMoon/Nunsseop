import Foundation

/// A Claude Code or Codex conversation that isn't open, found in the tools' own session files, for the Agents tab.
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
/// `~/.claude/projects/<folder>/<id>.jsonl` and `~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl`. A value type, so
/// a scan can run off the main thread on a copy; what was read from a file is kept until its size or time changes.
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
        let url: URL
        let modified: Date
        let size: Int
    }

    private struct Info {
        var cwd: String
        var prompt: String?
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
        let candidates = (Self.claudeFiles(home: home, since: cutoff) + Self.codexFiles(home: home, since: cutoff))
            .sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.session < $1.session }
        let paths = Set(candidates.map(\.url.path))
        cache = cache.filter { paths.contains($0.key) }
        var found: [RecentConversation] = []
        for candidate in candidates where found.count < Self.limit {
            guard !open.contains(candidate.session.lowercased()) else { continue }
            let path = candidate.url.path
            var entry = cache[path]
            if entry?.modified != candidate.modified || entry?.size != candidate.size {
                let info = candidate.kind == .claude ? Self.claudeInfo(candidate.url) : Self.codexInfo(candidate.url)
                entry = Cached(modified: candidate.modified, size: candidate.size, info: info,
                               scan: entry?.scan ?? AgentNameScan(), scanned: entry?.scanned)
            }
            guard var kept = entry else { continue }
            defer { cache[path] = kept }
            guard let info = kept.info, Self.isResumableFolder(info.cwd, scratch: scratch) else { continue }
            var name: String?
            switch candidate.kind {
            case .claude:
                if kept.scanned?.modified != candidate.modified || kept.scanned?.size != candidate.size {
                    kept.scan.advance(candidate.url)
                    kept.scanned = (candidate.modified, candidate.size)
                }
                name = kept.scan.name
            case .codex:
                codexNames.refresh(home: home)
                name = codexNames.names[candidate.session]
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

    /// Only a session started from the `codex` command line (`source` is `cli`) is offered: the ones `codex exec`, the
    /// desktop app, editors and other programs start are not conversations to pick up in a terminal.
    private static func codexInfo(_ url: URL) -> Info? {
        guard let meta = read(url, head: true).first, meta["type"] as? String == "session_meta",
              let payload = meta["payload"] as? [String: Any], payload["source"] as? String == "cli",
              let cwd = payload["cwd"] as? String, !cwd.isEmpty else { return nil }
        return Info(cwd: cwd, prompt: nil)
    }
}
